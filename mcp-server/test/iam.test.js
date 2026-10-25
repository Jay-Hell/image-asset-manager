// The `iam` command (release 1.2, R2-3): argument parsing, prompts-json lookup, exit codes and output
// shape. The client is a fake and the output streams are buffers: no test opens the app or a socket.
// Run: node --test "mcp-server/test/*.test.js"

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  run, parseArgs, lookupPrompt, importArguments, UsageError, HELP, OPTION_NAMES,
  EXIT_OK, EXIT_FAILED, EXIT_USAGE,
} from '../src/iam.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);

function buffer() {
  const b = { text: '', write(s) { b.text += s; return true; } };
  return b;
}

/** A fake client: `answers[tool]` is a value or a function of the arguments; it records every call. */
function fakeClient({ answers = {}, startFails = null } = {}) {
  const c = { started: 0, calls: [] };
  c.ensureAppRunning = async () => { c.started += 1; if (startFails) throw new Error(startFails); return { launched: false }; };
  c.callAppTool = async (name, args) => {
    c.calls.push({ name, args });
    const a = answers[name];
    if (a instanceof Error) throw a;
    return typeof a === 'function' ? a(args) : a;
  };
  return c;
}

async function iam(argv, { client = fakeClient(), ...rest } = {}) {
  const stdout = buffer(), stderr = buffer();
  const code = await run(argv, { client, stdout, stderr, ...rest });
  const lines = stdout.text.split('\n').filter(l => l.startsWith('{'));
  return { code, client, stdout: stdout.text, stderr: stderr.text, json: lines.map(l => JSON.parse(l)) };
}

function tmp() {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'iam-test-')));
}

// ---- parsing ---------------------------------------------------------------------------------

test('parseArgs reads every generate option, with a repeated --tag and the --opt=value form', () => {
  const p = parseArgs(['generate', '--prompt', 'a glass cube', '--quality', 'pro', '--aspect=16:9',
    '--project', 'Labs', '--tag', 'a', '--tag', 'b', '--family', 'cubes', '--out', '/x']);
  assert.deepEqual(
    { c: p.command, prompt: p.prompt, q: p.quality, a: p.aspect, pr: p.project, t: p.tags, f: p.family, o: p.out },
    { c: 'generate', prompt: 'a glass cube', q: 'pro', a: '16:9', pr: 'Labs', t: ['a', 'b'], f: 'cubes', o: '/x' });
});

test('parseArgs takes several files and options in any order for import', () => {
  const p = parseArgs(['import', '--project', 'P', 'a.png', '--tag', 't', 'b.png']);
  assert.deepEqual(p.files, ['a.png', 'b.png']);
  assert.deepEqual(p.tags, ['t']);
});

test('parseArgs refuses what is a usage error, each with a message naming it', () => {
  const bad = [
    [[], /No command/],
    [['frobnicate'], /Unknown command 'frobnicate'/],
    [['generate'], /needs --prompt/],
    [['generate', '--prompt', 'x', '--quality', 'ultra'], /--quality must be one of/],
    [['generate', '--prompt', 'x', '--bogus', '1'], /Unknown option --bogus/],
    [['generate', '--prompt'], /--prompt needs a value/],
    [['generate', '--prompt', 'x', '--prompt', 'y'], /more than once/],
    [['generate', '--prompt', 'x', '--family', 'f'], /--family needs --project/],
    [['generate', '--prompt', 'x', '--cost-usd', '1'], /does not apply to 'generate'/],
    [['generate', '--prompt', 'x', 'stray'], /Unexpected argument 'stray'/],
    [['projects', '--tag', 'x'], /does not apply to 'projects'/],
    [['import', '--project', 'P'], /at least one file/],
    [['import', 'a.png'], /needs --project/],
    [['import', 'a.png', '--project', 'P', '--prompt', 'x', '--prompts-json', 'p.json'], /not both/],
    [['import', 'a.png', '--project', 'P', '--key', 'k'], /--key needs --prompts-json/],
    [['import', 'a.png', '--project', 'P', '--cost-usd', '1', '--cost-gbp', '1'], /not both/],
    [['import', 'a.png', '--project', 'P', '--cost-usd', 'abc'], /--cost-usd must be a number/],
    [['import', 'a.png', '--project', 'P', '--cost-gbp', '-1'], /--cost-gbp must be a number/],
  ];
  for (const [argv, message] of bad) {
    assert.throws(() => parseArgs(argv), e => e instanceof UsageError && message.test(e.message), JSON.stringify(argv));
  }
});

test('parseArgs accepts the boundary cases that look like the refused ones', () => {
  assert.equal(parseArgs(['import', 'a.png', '--project', 'P', '--cost-usd', '0']).costUsd, '0');
  assert.equal(parseArgs(['generate', '--prompt', 'x', '--project', 'P', '--family', 'f']).family, 'f');
  assert.equal(parseArgs(['import', 'a.png', '--project', 'P', '--prompts-json', 'p.json', '--key', 'k']).key, 'k');
  assert.equal(parseArgs(['--help']).help, true);
  assert.equal(parseArgs(['generate', '-h']).help, true);
});

test('--help lists every option the parser knows, and the commands', () => {
  for (const name of OPTION_NAMES.filter(n => n.length > 1)) {
    assert.ok(HELP.includes(`--${name}`), `--${name} is missing from --help`);
  }
  for (const word of ['generate', 'import', 'projects', 'tags']) assert.ok(HELP.includes(`iam ${word}`));
});

// ---- prompts-json ----------------------------------------------------------------------------

test('lookupPrompt finds an object entry or a bare string, and fails clearly on the rest', () => {
  const table = { a: { prompt: 'cat', aspect: '1:1' }, b: 'dog', c: { aspect: '1:1' } };
  assert.equal(lookupPrompt(table, 'a'), 'cat');
  assert.equal(lookupPrompt(table, 'b'), 'dog');
  assert.throws(() => lookupPrompt(table, 'zzz'), /no entry 'zzz'/);
  assert.throws(() => lookupPrompt(table, 'c'), /has no prompt/);
  assert.throws(() => lookupPrompt(table, 'toString'), /no entry 'toString'/);
  assert.throws(() => lookupPrompt([], '0'), /no entry/);
});

test('importArguments: --key wins, else the file name without its extension; --prompt is used as given', () => {
  const table = { hero: { prompt: 'from key' }, shot: { prompt: 'from stem' } };
  const base = { project: 'P', tags: [] };
  assert.equal(importArguments({ ...base, promptsJson: 'p', key: 'hero' }, '/x/shot.png', table).prompt, 'from key');
  assert.equal(importArguments({ ...base, promptsJson: 'p' }, '/x/shot.png', table).prompt, 'from stem');
  assert.equal(importArguments({ ...base, prompt: 'literal' }, '/x/shot.png', undefined).prompt, 'literal');
  assert.equal('prompt' in importArguments(base, '/x/shot.png', undefined), false);
});

test('--cost-usd goes as dollars (the app converts); --cost-gbp goes as pounds', () => {
  const base = { project: 'P', tags: [] };
  const usd = importArguments({ ...base, costUsd: '0.04' }, '/x/a.png');
  assert.equal(usd.actual_cost_usd, 0.04);
  assert.equal('actual_cost_gbp' in usd, false);
  const gbp = importArguments({ ...base, costGbp: '0.05' }, '/x/a.png');
  assert.equal(gbp.actual_cost_gbp, 0.05);
  assert.equal('actual_cost_usd' in gbp, false);
  assert.equal(importArguments({ ...base, costUsd: '0' }, '/x/a.png').actual_cost_usd, 0);
  const none = importArguments(base, '/x/a.png');
  assert.equal('actual_cost_gbp' in none || 'actual_cost_usd' in none, false, 'unknown cost is left out, never 0');
});

// ---- the real copy, against a real folder ----------------------------------------------------

test('generate --out never replaces a file already in the folder: that file fails, exit 1, the others carry on', async () => {
  const lib = path.join(tmp(), 'assets'), dest = tmp();
  fs.mkdirSync(lib);
  fs.writeFileSync(path.join(lib, 'a1.png'), 'library one');
  fs.writeFileSync(path.join(lib, 'a2.png'), 'library two');
  fs.writeFileSync(path.join(dest, 'a1.png'), 'mine, keep me');
  const answers = { generate: { generated: [{ asset_id: 'A1', file_path: path.join(lib, 'a1.png') }, { asset_id: 'A2', file_path: path.join(lib, 'a2.png') }] } };
  const r = await iam(['generate', '--prompt', 'p', '--out', dest], { client: fakeClient({ answers }) });
  assert.equal(r.code, EXIT_FAILED);
  assert.equal(fs.readFileSync(path.join(dest, 'a1.png'), 'utf8'), 'mine, keep me');
  assert.equal(fs.readFileSync(path.join(dest, 'a2.png'), 'utf8'), 'library two');
  assert.match(r.stderr, /a1\.png.*already there/);
  assert.equal('copied_to' in r.json[0].generated[0], false);
  assert.equal(r.json[0].generated[1].copied_to, path.join(dest, 'a2.png'));
});

test('generate --out inside the library folder is refused and nothing is written there', async () => {
  const lib = path.join(tmp(), 'assets');
  fs.mkdirSync(path.join(lib, 'sub'), { recursive: true });
  fs.writeFileSync(path.join(lib, 'a1.png'), 'library one');
  const answers = { generate: { generated: [{ asset_id: 'A1', file_path: path.join(lib, 'a1.png') }] } };
  for (const out of [lib, path.join(lib, 'sub'), path.join(lib, 'new', 'deeper'), path.join(lib, 'sub', '..')]) {
    const r = await iam(['generate', '--prompt', 'p', '--out', out], { client: fakeClient({ answers }) });
    assert.equal(r.code, EXIT_FAILED, out);
    assert.match(r.stderr, /inside the library folder/);
    assert.equal('copied_to' in r.json[0].generated[0], false);
  }
  assert.deepEqual(fs.readdirSync(lib).sort(), ['a1.png', 'sub'], 'nothing new in the library');
  // The pair: a sibling folder whose name merely starts the same is outside, and is copied to.
  const sibling = `${lib}-copy`;
  const ok = await iam(['generate', '--prompt', 'p', '--out', sibling], { client: fakeClient({ answers }) });
  assert.equal(ok.code, EXIT_OK);
  assert.equal(fs.readFileSync(path.join(sibling, 'a1.png'), 'utf8'), 'library one');
});

test('generate --out through a link into the library is refused', async () => {
  const root = tmp(), lib = path.join(root, 'assets');
  fs.mkdirSync(lib);
  fs.writeFileSync(path.join(lib, 'a1.png'), 'library one');
  fs.symlinkSync(lib, path.join(root, 'shortcut'));
  const answers = { generate: { generated: [{ asset_id: 'A1', file_path: path.join(lib, 'a1.png') }] } };
  const r = await iam(['generate', '--prompt', 'p', '--out', path.join(root, 'shortcut')], { client: fakeClient({ answers }) });
  assert.equal(r.code, EXIT_FAILED);
  assert.deepEqual(fs.readdirSync(lib), ['a1.png']);
});

// ---- run: output shape, exit codes, what leaves the process ---------------------------------

test('usage errors exit 2, say why on stderr, print nothing on stdout and never start the app', async () => {
  const r = await iam(['generate']);
  assert.equal(r.code, EXIT_USAGE);
  assert.match(r.stderr, /needs --prompt/);
  assert.equal(r.stdout, '');
  assert.equal(r.client.started, 0);
});

test('--help exits 0, prints the help on stdout and never starts the app', async () => {
  const r = await iam(['--help']);
  assert.equal(r.code, EXIT_OK);
  assert.equal(r.stdout, HELP);
  assert.equal(r.client.started, 0);
});

test('generate sends the mapped arguments and prints ids and paths as JSON', async () => {
  const client = fakeClient({ answers: { generate: {
    generated: [{ asset_id: 'A1', file_path: '/lib/a1.png', model_used: 'm', estimated_cost_gbp: 0.1 }, { asset_id: 'A2', file_path: '/lib/a2.png' }],
    cost: { actual_gbp: 0.2 }, notes: ['n'], resolved: { model: 'secret-model' },
  } } });
  const r = await iam(['generate', '--prompt', 'p', '--quality', 'fast', '--aspect', '16:9', '--project', 'Labs',
    '--model', 'openrouter:google/gemini-2.5-flash-image', '--tag', 't1', '--tag', 't2', '--family', 'fam'], { client });
  assert.equal(r.code, EXIT_OK);
  assert.deepEqual(client.calls, [{ name: 'generate', args: {
    prompt: 'p', quality: 'fast', aspect_ratio: '16:9', model: 'openrouter:google/gemini-2.5-flash-image',
    project: 'Labs', tags: ['t1', 't2'], variant_family: 'fam' } }]);
  assert.deepEqual(r.json, [{
    generated: [{ asset_id: 'A1', file_path: '/lib/a1.png' }, { asset_id: 'A2', file_path: '/lib/a2.png' }],
    cost: { actual_gbp: 0.2 }, notes: ['n'] }]);
});

test('generate sends only what was given', async () => {
  const client = fakeClient({ answers: { generate: { generated: [{ asset_id: 'A', file_path: '/f' }] } } });
  await iam(['generate', '--prompt', 'p'], { client });
  assert.deepEqual(client.calls[0].args, { prompt: 'p' });
});

test('generate --out copies each image to the folder and reports where; a copy that fails exits 1', async () => {
  const answers = { generate: { generated: [{ asset_id: 'A1', file_path: '/lib/a1.png' }, { asset_id: 'A2', file_path: '/lib/a2.png' }] } };
  const copied = [];
  const ok = await iam(['generate', '--prompt', 'p', '--out', '/dest'], {
    client: fakeClient({ answers }), copy: (from, dir) => { copied.push([from, dir]); return `${dir}/${path.basename(from)}`; } });
  assert.equal(ok.code, EXIT_OK);
  assert.deepEqual(copied, [['/lib/a1.png', '/dest'], ['/lib/a2.png', '/dest']]);
  assert.deepEqual(ok.json[0].generated.map(g => g.copied_to), ['/dest/a1.png', '/dest/a2.png']);

  const bad = await iam(['generate', '--prompt', 'p', '--out', '/dest'], {
    client: fakeClient({ answers }), copy: from => { if (from.endsWith('a2.png')) throw new Error('EACCES'); return '/dest/a1.png'; } });
  assert.equal(bad.code, EXIT_FAILED);
  assert.match(bad.stderr, /could not copy \/lib\/a2\.png to \/dest: EACCES/);
  assert.equal(bad.json[0].generated[0].copied_to, '/dest/a1.png');
});

test('generate without --out copies nothing', async () => {
  let copies = 0;
  const r = await iam(['generate', '--prompt', 'p'], {
    client: fakeClient({ answers: { generate: { generated: [{ asset_id: 'A', file_path: '/f' }] } } }), copy: () => { copies += 1; } });
  assert.equal(copies, 0);
  assert.equal('copied_to' in r.json[0].generated[0], false);
});

test('generate: an app error, or an answer with no images, exits 1 with the reason on stderr', async () => {
  const refused = await iam(['generate', '--prompt', 'p', '--project', 'Nope'], {
    client: fakeClient({ answers: { generate: new Error("No project named 'Nope'. Projects: Labs") } }) });
  assert.equal(refused.code, EXIT_FAILED);
  assert.match(refused.stderr, /No project named 'Nope'/);
  assert.equal(refused.stdout, '');
  const empty = await iam(['generate', '--prompt', 'p'], { client: fakeClient({ answers: { generate: { generated: [] } } }) });
  assert.equal(empty.code, EXIT_FAILED);
});

test('an app that cannot be started exits 1, names the reason, and no tool is called', async () => {
  const client = fakeClient({ startFails: 'Image Asset Manager was opened but did not answer within 30 s' });
  const r = await iam(['projects'], { client });
  assert.equal(r.code, EXIT_FAILED);
  assert.match(r.stderr, /did not answer within 30 s/);
  assert.deepEqual(client.calls, []);
});

test('projects and tags call list_projects and list_tags and print the answer as one JSON line', async () => {
  const client = fakeClient({ answers: { list_projects: { projects: [{ name: 'Labs' }] }, list_tags: { tags: [{ name: 'x', count: 2 }] } } });
  const p = await iam(['projects'], { client });
  const t = await iam(['tags'], { client });
  assert.deepEqual(client.calls.map(c => c.name), ['list_projects', 'list_tags']);
  assert.deepEqual(p.json, [{ projects: [{ name: 'Labs' }] }]);
  assert.deepEqual(t.json, [{ tags: [{ name: 'x', count: 2 }] }]);
  assert.equal(p.code + t.code, 0);
});

test('import sends the bytes and metadata the proxy prepares, and prints one JSON line per file', async () => {
  const dir = tmp();
  const a = path.join(dir, 'one.png'), b = path.join(dir, 'two.png');
  fs.writeFileSync(a, PNG); fs.writeFileSync(b, PNG);
  const prompts = path.join(dir, 'prompts.json');
  fs.writeFileSync(prompts, JSON.stringify({ one: { prompt: 'first', aspect: '1:1' }, two: { prompt: 'second' } }));
  const client = fakeClient({ answers: { import_asset: args => ({ asset_id: `id-${args.prompt}`, duplicate: args.prompt === 'second' }) } });
  const r = await iam(['import', a, b, '--project', 'Ionic Test', '--prompts-json', prompts, '--provider', 'openrouter',
    '--model', 'google/gemini-2.5-flash-image', '--cost-usd', '0.04', '--tag', 'film'], { client });
  assert.equal(r.code, EXIT_OK);
  assert.deepEqual(r.json, [{ file: a, asset_id: 'id-first', status: 'new' }, { file: b, asset_id: 'id-second', status: 'duplicate' }]);
  assert.equal(client.calls.length, 2);
  const sent = client.calls[0].args;
  assert.equal(sent.path, undefined, 'the app never sees a path');
  assert.equal(sent.data_base64, PNG.toString('base64'));
  assert.equal(sent.media_type, 'image/png');
  assert.equal(sent.original_filename, 'one.png');
  assert.deepEqual(
    { prompt: sent.prompt, project: sent.project, provider: sent.provider, model: sent.model, cost: sent.actual_cost_usd, tags: sent.tags },
    { prompt: 'first', project: 'Ionic Test', provider: 'openrouter', model: 'google/gemini-2.5-flash-image', cost: 0.04, tags: ['film'] });
  assert.equal('actual_cost_gbp' in sent, false, 'dollars go as dollars: the app converts');
});

test('import: one bad file exits 1 but the others are still imported; each file gets its line', async () => {
  const dir = tmp();
  const good = path.join(dir, 'good.png'), notImage = path.join(dir, 'bad.png'), missing = path.join(dir, 'missing.png');
  fs.writeFileSync(good, PNG); fs.writeFileSync(notImage, 'not a png');
  const client = fakeClient({ answers: { import_asset: { asset_id: 'G', duplicate: false } } });
  const r = await iam(['import', notImage, good, missing, '--project', 'P'], { client });
  assert.equal(r.code, EXIT_FAILED);
  assert.equal(client.calls.length, 1);
  assert.equal(r.json.length, 3);
  assert.match(r.json[0].error, /content is/);
  assert.deepEqual(r.json[1], { file: good, asset_id: 'G', status: 'new' });
  assert.match(r.json[2].error, /Cannot read/);
  assert.match(r.stderr, /missing\.png/);
});

test('import: an app refusal for one file exits 1 and is reported against that file', async () => {
  const dir = tmp();
  const f = path.join(dir, 'a.png');
  fs.writeFileSync(f, PNG);
  const r = await iam(['import', f, '--project', 'Nope'], { client: fakeClient({ answers: { import_asset: new Error("No project named 'Nope'") } }) });
  assert.equal(r.code, EXIT_FAILED);
  assert.deepEqual(r.json, [{ file: f, error: "No project named 'Nope'" }]);
});

test('import: a missing prompts-json key fails that file only; an unreadable prompts file fails before the app starts', async () => {
  const dir = tmp();
  const known = path.join(dir, 'known.png'), unknown = path.join(dir, 'unknown.png');
  fs.writeFileSync(known, PNG); fs.writeFileSync(unknown, PNG);
  const prompts = path.join(dir, 'p.json');
  fs.writeFileSync(prompts, JSON.stringify({ known: { prompt: 'k' } }));
  const client = fakeClient({ answers: { import_asset: { asset_id: 'K', duplicate: false } } });
  const r = await iam(['import', known, unknown, '--project', 'P', '--prompts-json', prompts], { client });
  assert.equal(r.code, EXIT_FAILED);
  assert.equal(client.calls.length, 1);
  assert.match(r.json[1].error, /no entry 'unknown'/);

  const c2 = fakeClient();
  const gone = await iam(['import', known, '--project', 'P', '--prompts-json', path.join(dir, 'nope.json')], { client: c2 });
  assert.equal(gone.code, EXIT_FAILED);
  assert.match(gone.stderr, /cannot read the prompts file/);
  assert.equal(c2.started, 0);
});

test('import: --key applies one prompt to every file; --prompt applies the literal text', async () => {
  const dir = tmp();
  const f = path.join(dir, 'x.png');
  fs.writeFileSync(f, PNG);
  const prompts = path.join(dir, 'p.json');
  fs.writeFileSync(prompts, JSON.stringify({ chosen: { prompt: 'chosen prompt' } }));
  const client = fakeClient({ answers: { import_asset: { asset_id: 'X', duplicate: false } } });
  await iam(['import', f, '--project', 'P', '--prompts-json', prompts, '--key', 'chosen'], { client });
  await iam(['import', f, '--project', 'P', '--prompt', 'literal'], { client });
  assert.deepEqual(client.calls.map(c => c.args.prompt), ['chosen prompt', 'literal']);
});

test('iam holds no secret: its source reads no token file, key or environment variable', () => {
  const source = fs.readFileSync(path.join(HERE, '..', 'src', 'iam.js'), 'utf8');
  const code = source.split('\n').filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n');
  assert.doesNotMatch(code, /process\.env|mcp-token|Authorization|Bearer|API_KEY|apiKey/);
});

// ---- the bin entry, without reaching the app -------------------------------------------------

test('bin/iam.js: --help exits 0 and a usage error exits 2 (neither reaches the app)', () => {
  const bin = path.join(HERE, '..', 'bin', 'iam.js');
  const help = spawnSync(process.execPath, [bin, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /iam generate --prompt/);
  const bad = spawnSync(process.execPath, [bin, 'generate'], { encoding: 'utf8' });
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /needs --prompt/);
});

test('package.json has the iam bin entry and the file is executable', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'package.json'), 'utf8'));
  assert.equal(pkg.bin.iam, './bin/iam.js');
  fs.accessSync(path.join(HERE, '..', 'bin', 'iam.js'), fs.constants.X_OK);
});
