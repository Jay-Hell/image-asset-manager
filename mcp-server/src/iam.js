/**
 * `iam`: the Image Asset Manager command line (release 1.2, R2-3).
 *
 *   iam generate --prompt … [--quality fast|standard|pro] [--aspect 16:9] [--project …] [--tag …]… [--family …] [--out <dir>]
 *   iam import <file>… --project … [--prompt … | --prompts-json <file> [--key <id>]] [--provider …] [--model …]
 *                      [--cost-usd … | --cost-gbp …] [--tag …]… [--family …]
 *   iam projects
 *   iam tags
 *
 * It goes through the same client as the MCP proxy (`createAppClient`), so it opens the app by path
 * when it is not running (Q4) and holds no API key: the app holds the keys. The client, the output
 * streams and the file copy are injected, so no test opens the app.
 *
 * Exit codes: 0 every file succeeded, 1 any failed, 2 a usage error. Errors go to stderr.
 */

import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import { createAppClient } from './appClient.js';
import { prepareImportArgs } from './tools.js';

/**
 * Dollars to pounds for --cost-usd. The app owns this rate (`Currency.usdToGBP`, Core); a node test
 * reads that file and fails if the two differ.
 */
export const USD_TO_GBP = 0.79;

export const EXIT_OK = 0;
export const EXIT_FAILED = 1;
export const EXIT_USAGE = 2;

export class UsageError extends Error {}

export const HELP = `iam: generate and import images through Image Asset Manager (the app holds the keys).

Usage:
  iam generate --prompt <text> [options]
  iam import <file>... --project <name> [options]
  iam projects
  iam tags

generate options:
  --prompt <text>        What to make (required)
  --quality <tier>       fast, standard, pro, auto or with_references (default: the app's choice)
  --aspect <ratio>       square, landscape, portrait or a ratio such as 16:9
  --model <provider:model>  A specific model, such as openrouter:google/gemini-2.5-flash-image
                         (overrides --quality; take the name from list_generation_options)
  --project <name>       File the result to this project (it must exist)
  --tag <tag>            A tag to apply; repeat for more
  --family <name>        Variant family to add the result to (needs --project)
  --out <dir>            Also copy each generated image into this folder
  Prints {"generated":[{"asset_id","file_path"}],…} as JSON.

import options (one JSON line per file: file, asset_id, status new|duplicate):
  --project <name>       Project to file to (required; it must exist)
  --prompt <text>        The prompt the image was made from
  --prompts-json <file>  A JSON file of {id: {prompt, …}} (or {id: "prompt"}); the prompt is looked up
                         by --key, or by each file's name without its extension
  --key <id>             The key to look up in --prompts-json
  --provider <id>        Who made it (default: imported)
  --model <id>           The model that made it (default: imported)
  --cost-usd <n>         What each file cost, in dollars (converted to pounds at ${USD_TO_GBP})
  --cost-gbp <n>         What each file cost, in pounds
  --tag <tag>            A tag to apply; repeat for more
  --family <name>        Variant family to add it to

projects                 List projects (JSON)
tags                     List tags with their counts (JSON)

Other:
  -h, --help             Show this help

Exit codes: 0 every file succeeded, 1 any failed, 2 usage error.
`;

// Option name -> [key, takes a value, repeatable]
const OPTIONS = {
  prompt: ['prompt', true, false],
  quality: ['quality', true, false],
  aspect: ['aspect', true, false],
  project: ['project', true, false],
  tag: ['tags', true, true],
  family: ['family', true, false],
  out: ['out', true, false],
  'prompts-json': ['promptsJson', true, false],
  key: ['key', true, false],
  provider: ['provider', true, false],
  model: ['model', true, false],
  'cost-usd': ['costUsd', true, false],
  'cost-gbp': ['costGbp', true, false],
  help: ['help', false, false],
  h: ['help', false, false],
};

export const OPTION_NAMES = Object.keys(OPTIONS);

const ALLOWED = {
  generate: ['prompt', 'quality', 'aspect', 'model', 'project', 'tags', 'family', 'out'],
  import: ['project', 'prompt', 'promptsJson', 'key', 'provider', 'model', 'costUsd', 'costGbp', 'tags', 'family'],
  projects: [],
  tags: [],
};

const QUALITIES = ['fast', 'standard', 'pro', 'auto', 'with_references'];

/** Parses argv (without node and the script). Throws UsageError. */
export function parseArgs(argv) {
  const parsed = { command: null, files: [], tags: [], help: false };
  const seen = new Set();
  let onlyFiles = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (onlyFiles || !arg.startsWith('-') || arg === '-') {
      if (parsed.command === null) parsed.command = arg;
      else parsed.files.push(arg);
      continue;
    }
    if (arg === '--') { onlyFiles = true; continue; }
    const match = /^--?([^=]+)(?:=(.*))?$/.exec(arg);
    const spec = match && OPTIONS[match[1]];
    if (!spec) throw new UsageError(`Unknown option ${arg.split('=')[0]}`);
    const [key, takesValue, repeatable] = spec;
    if (!takesValue) { parsed[key] = true; continue; }
    let value = match[2];
    if (value === undefined) {
      value = argv[i + 1];
      if (value === undefined) throw new UsageError(`${arg} needs a value`);
      i += 1;
    }
    if (repeatable) parsed[key].push(value);
    else {
      if (seen.has(key)) throw new UsageError(`--${match[1]} given more than once`);
      parsed[key] = value;
    }
    seen.add(key);
  }
  if (parsed.help) return parsed;

  const { command } = parsed;
  if (!command) throw new UsageError('No command given (generate, import, projects or tags)');
  if (!(command in ALLOWED)) throw new UsageError(`Unknown command '${command}'`);
  for (const key of [...seen]) {
    if (!ALLOWED[command].includes(key)) {
      const name = Object.keys(OPTIONS).find(n => OPTIONS[n][0] === key);
      throw new UsageError(`--${name} does not apply to '${command}'`);
    }
  }
  if (command !== 'import' && parsed.files.length) {
    throw new UsageError(`Unexpected argument '${parsed.files[0]}'`);
  }

  if (command === 'generate') {
    if (!parsed.prompt || !parsed.prompt.trim()) throw new UsageError('generate needs --prompt');
    if (parsed.quality !== undefined && !QUALITIES.includes(parsed.quality)) {
      throw new UsageError(`--quality must be one of ${QUALITIES.join(', ')}`);
    }
    if (parsed.family && !parsed.project) throw new UsageError('--family needs --project');
  }
  if (command === 'import') {
    if (!parsed.files.length) throw new UsageError('import needs at least one file');
    if (!parsed.project) throw new UsageError('import needs --project');
    if (parsed.prompt !== undefined && parsed.promptsJson !== undefined) {
      throw new UsageError('Give --prompt or --prompts-json, not both');
    }
    if (parsed.key !== undefined && parsed.promptsJson === undefined) {
      throw new UsageError('--key needs --prompts-json');
    }
    if (parsed.costUsd !== undefined && parsed.costGbp !== undefined) {
      throw new UsageError('Give --cost-usd or --cost-gbp, not both');
    }
    for (const [flag, value] of [['--cost-usd', parsed.costUsd], ['--cost-gbp', parsed.costGbp]]) {
      if (value === undefined) continue;
      const n = Number(value);
      if (value.trim() === '' || !Number.isFinite(n) || n < 0) {
        throw new UsageError(`${flag} must be a number, zero or more`);
      }
    }
  }
  return parsed;
}

/** The prompt for one file from a prompts-json document: `{id: {prompt}}` or `{id: "text"}`. */
export function lookupPrompt(table, key) {
  if (!table || typeof table !== 'object' || Array.isArray(table) || !Object.hasOwn(table, key)) {
    throw new Error(`no entry '${key}' in the prompts file`);
  }
  const entry = table[key];
  const prompt = typeof entry === 'string' ? entry : entry?.prompt;
  if (typeof prompt !== 'string' || !prompt.trim()) throw new Error(`entry '${key}' in the prompts file has no prompt`);
  return prompt;
}

/** What `import_asset` is sent for one file (before the proxy's file reading adds the bytes). */
export function importArguments(parsed, file, table) {
  const args = { path: file, project: parsed.project };
  if (parsed.promptsJson !== undefined) {
    args.prompt = lookupPrompt(table, parsed.key ?? basename(file, extname(file)));
  } else if (parsed.prompt !== undefined) {
    args.prompt = parsed.prompt;
  }
  if (parsed.provider !== undefined) args.provider = parsed.provider;
  if (parsed.model !== undefined) args.model = parsed.model;
  if (parsed.costGbp !== undefined) args.actual_cost_gbp = Number(parsed.costGbp);
  if (parsed.costUsd !== undefined) args.actual_cost_gbp = Math.round(Number(parsed.costUsd) * USD_TO_GBP * 1e6) / 1e6;
  if (parsed.tags.length) args.tags = parsed.tags;
  if (parsed.family !== undefined) args.variant_family = parsed.family;
  return args;
}

/** What `generate` is sent. */
export function generateArguments(parsed) {
  const args = { prompt: parsed.prompt };
  if (parsed.quality !== undefined) args.quality = parsed.quality;
  if (parsed.aspect !== undefined) args.aspect_ratio = parsed.aspect;
  if (parsed.model !== undefined) args.model = parsed.model;
  if (parsed.project !== undefined) args.project = parsed.project;
  if (parsed.tags.length) args.tags = parsed.tags;
  if (parsed.family !== undefined) args.variant_family = parsed.family;
  return args;
}

/**
 * Runs the command. Returns the exit code. `client` needs `ensureAppRunning` and `callAppTool`;
 * `prepare` is the proxy's import preparation; `copy` and `readText` are the file effects.
 */
export async function run(argv, {
  client = createAppClient(),
  prepare = prepareImportArgs,
  stdout = process.stdout,
  stderr = process.stderr,
  copy = (from, dir) => { mkdirSync(dir, { recursive: true }); const to = join(dir, basename(from)); copyFileSync(from, to); return to; },
  readText = file => readFileSync(file, 'utf8'),
} = {}) {
  const out = line => stdout.write(`${line}\n`);
  const err = line => stderr.write(`${line}\n`);

  let parsed;
  try {
    parsed = parseArgs(argv);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    err(`iam: ${error.message}`);
    err("Run 'iam --help' for the options.");
    return EXIT_USAGE;
  }
  if (parsed.help) { stdout.write(HELP); return EXIT_OK; }

  // Anything that can fail before the app is asked is checked first: a bad prompts file should not open the app.
  let table;
  if (parsed.command === 'import' && parsed.promptsJson !== undefined) {
    try {
      table = JSON.parse(readText(parsed.promptsJson));
    } catch (error) {
      err(`iam: cannot read the prompts file '${parsed.promptsJson}': ${error.message}`);
      return EXIT_FAILED;
    }
  }

  try {
    await client.ensureAppRunning();
  } catch (error) {
    err(`iam: ${error.message}`);
    return EXIT_FAILED;
  }

  try {
    switch (parsed.command) {
      case 'projects':
      case 'tags': {
        const result = await client.callAppTool(parsed.command === 'projects' ? 'list_projects' : 'list_tags', {});
        out(JSON.stringify(result));
        return EXIT_OK;
      }
      case 'generate': {
        const result = await client.callAppTool('generate', generateArguments(parsed));
        const generated = (result?.generated ?? []).map(g => ({ asset_id: g.asset_id, file_path: g.file_path }));
        let status = EXIT_OK;
        if (parsed.out !== undefined) {
          for (const item of generated) {
            try {
              item.copied_to = copy(item.file_path, parsed.out);
            } catch (error) {
              err(`iam: could not copy ${item.file_path} to ${parsed.out}: ${error.message}`);
              status = EXIT_FAILED;
            }
          }
        }
        out(JSON.stringify({ generated, cost: result?.cost ?? null, notes: result?.notes ?? [] }));
        if (generated.length === 0) { err('iam: the app returned no images'); status = EXIT_FAILED; }
        return status;
      }
      default: { // import
        let status = EXIT_OK;
        for (const file of parsed.files) {
          try {
            const sent = prepare(importArguments(parsed, file, table));
            const result = await client.callAppTool('import_asset', sent);
            out(JSON.stringify({ file, asset_id: result.asset_id, status: result.duplicate ? 'duplicate' : 'new' }));
          } catch (error) {
            err(`iam: ${file}: ${error.message}`);
            out(JSON.stringify({ file, error: error.message }));
            status = EXIT_FAILED;
          }
        }
        return status;
      }
    }
  } catch (error) {
    err(`iam: ${error.message}`);
    return EXIT_FAILED;
  }
}
