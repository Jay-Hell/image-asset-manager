/** Tool definitions (name, description, inputSchema) for ListTools response.
 *
 * Descriptions name no model and state no price: both change, and a description cannot be
 * kept current. An agent learns what can be made, and at what cost, from list_generation_options.
 * (mcp-server/test/tools.test.js holds this to account.)
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Shared by the `tags` field of `generate`, `generate_image` and `import_asset` (release 1.2 §2.5).
const REUSE_TAGS =
  'Call list_tags first and reuse an existing tag wherever one fits, spelt as it is listed; make a new tag only for something none of them describes. ' +
  'Tags describe what is in the image. Which piece of work it belongs to is a project, not a tag. Unknown tags are created.';

// Shared by `generate` and its alias `generate_image`.
const GENERATE_PROPERTIES = {
  prompt: {
    description:
      'Natural-language prompt OR a structured JSON object. Canonical keys honoured in Subject → Context → Style order: ' +
      'subject, context, action, setting, style, composition, lighting, mood, camera, color_palette/palette, details, extra. ' +
      'Arbitrary keys are flattened too. Generation-engine keys like seed/steps/sampler/cfg_scale are ignored.',
    oneOf: [
      { type: 'string' },
      { type: 'object' },
    ],
  },
  quality: {
    type: 'string',
    enum: ['fast', 'standard', 'pro', 'with_references', 'auto'],
    description:
      'Quality tier; the app chooses the provider and model for it. "auto" is standard, and when references are attached it picks a tier that accepts them. ' +
      '"with_references" is standard plus require: ["references"]. ' +
      'If references are attached but the tier cannot take them, the server reroutes to one that can and says so in the response. ' +
      'Use list_generation_options to see what each tier resolves to and what it costs.',
  },
  require: {
    type: 'array',
    items: { type: 'string', enum: ['references', 'transparent_background', 'seed'] },
    description: 'Capabilities the model must have. If none can, the error names the tiers or models that can.',
  },
  model: {
    type: 'string',
    description:
      'Optional: a specific model as "provider:model", overriding the tier. Take the name from list_generation_options (include_all). ' +
      'The cost limits and the capability check still apply.',
  },
  count: {
    type: 'integer',
    minimum: 1,
    description:
      'Number of images to generate in this call (default 1). Capped by max_images. The batch stops early, and the response says how many were made, ' +
      'if actual spend so far plus the next estimate would pass max_cost_gbp.',
  },
  aspect_ratio: {
    type: 'string',
    description:
      'Output aspect ratio: "square" (default), "landscape", "portrait", or a ratio such as "4:3". ' +
      'Checked against the resolved model; an unsupported ratio is refused with the list the model supports.',
  },
  resolution: {
    type: 'string',
    enum: ['1K', '2K', '4K'],
    description: 'Optional output size. Refused if the resolved model does not offer it.',
  },
  project: {
    type: 'string',
    description:
      'Project name or UUID (shorthand — use `projects` for multiple). When provided, the project\'s active reference set is loaded automatically, and the generated asset(s) are assigned to this project. ' +
      'The project must already exist: an unknown one is refused, and the error lists the projects there are. Make a new one with create_project.',
  },
  projects: {
    type: 'array',
    items: { type: 'string' },
    description:
      'Additional project names or UUIDs. The first entry — or `project` if set — becomes the primary; references scoping follows the primary.',
  },
  references: {
    type: 'array',
    description: 'Specific asset IDs to use as references, alongside any from the project. Merged and truncated to the resolved model\'s reference limit.',
    items: {
      type: 'object',
      required: ['asset_id'],
      properties: {
        asset_id: { type: 'string', description: 'UUID of an existing library asset to use as a reference image' },
        role:     { type: 'string', enum: ['style_anchor', 'subject_anchor'], description: 'How the reference is used (default subject_anchor)' },
      },
    },
  },
  negative_prompt: {
    type: 'string',
    description: 'Things to avoid — inlined into the prompt as "Avoid: …". No provider takes a native negative-prompt field.',
  },
  tags: {
    type: 'array',
    items: { type: 'string' },
    description: 'Tags to apply to the generated asset(s). ' + REUSE_TAGS,
  },
  variant_family: {
    type: 'string',
    description: 'Variant family name to add the generated asset(s) to. Requires `project` to be set. Created if it doesn\'t exist.',
  },
  max_images: {
    type: 'integer',
    minimum: 1,
    description: 'Maximum images the call may produce (the app has a default and a ceiling). count must be ≤ max_images.',
  },
  max_cost_gbp: {
    type: 'number',
    minimum: 0,
    description: 'Maximum spend in GBP for this call (the app has a default and a ceiling). The call is rejected up front if count × the estimate would exceed this.',
  },
};

const GENERATE_RESPONSE =
  'Returns generated assets (id, file path, media_type, model used, estimated and actual cost), `resolved` (provider, model, tier, and why if it was not the first choice), ' +
  '`cost` (estimated and actual in GBP, and whether the actual came from the provider), `batch` (requested, made) and notes.';

export const TOOLS = [
  {
    name: 'search_assets',
    description: 'Search the asset library by full-text query and/or filters. Returns matching asset summaries with file paths.',
    inputSchema: {
      type: 'object',
      properties: {
        query:        { type: 'string',  description: 'Full-text search across prompt and filename' },
        tags:         { type: 'array',   items: { type: 'string' }, description: 'Filter to assets that have ALL of these tags' },
        project:      { type: 'string',  description: 'Filter by project name (shorthand — use `projects` for multiple)' },
        projects:     { type: 'array',   items: { type: 'string' }, description: 'Filter to assets that belong to ANY of these projects (by name)' },
        provider:     { type: 'string',  description: 'Filter by the provider ID recorded on the asset (as returned by get_asset)' },
        aspect_ratio: { type: 'string',  description: 'Filter by aspect ratio (e.g. "16:9")' },
        date_from:    { type: 'string',  description: 'ISO 8601 date lower bound (inclusive), e.g. "2024-01-01"' },
        date_to:      { type: 'string',  description: 'ISO 8601 date upper bound (exclusive)' },
        limit:        { type: 'integer', description: 'Maximum results (default 50)' },
      },
    },
  },
  {
    name: 'get_asset',
    description: 'Get full metadata for a single asset by ID, including tags, references used, and usage history.',
    inputSchema: {
      type: 'object',
      required: ['id'],
      properties: {
        id: { type: 'string', description: 'Asset UUID' },
      },
    },
  },
  {
    name: 'get_asset_lineage',
    description: 'Return the reference chain for an asset — which other assets were used as style or subject anchors during generation.',
    inputSchema: {
      type: 'object',
      required: ['id'],
      properties: {
        id: { type: 'string', description: 'Asset UUID' },
      },
    },
  },
  {
    name: 'list_projects',
    description:
      'List all projects in the library, each with its client, description, asset count and last-used date (the latest an asset in it was made or imported). ' +
      'Use these names with generate, import_asset and file_assets; make a new project with create_project.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'search_prompts',
    description: 'Search the prompt library by text and/or sector. Requires the app to be running.',
    inputSchema: {
      type: 'object',
      properties: {
        query:  { type: 'string', description: 'Full-text search across title and body' },
        sector: { type: 'string', description: 'Filter by sector (e.g. "transport", "healthcare")' },
      },
    },
  },
  {
    name: 'get_prompt',
    description: 'Get a full prompt record including body, negative prompt, and linked assets. Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['id'],
      properties: {
        id: { type: 'string', description: 'Prompt UUID' },
      },
    },
  },
  {
    name: 'get_spend',
    description: 'Get spend summary totals, optionally scoped to a project and/or date range.',
    inputSchema: {
      type: 'object',
      properties: {
        project:   { type: 'string', description: 'Filter by project name' },
        date_from: { type: 'string', description: 'ISO 8601 date lower bound (inclusive)' },
        date_to:   { type: 'string', description: 'ISO 8601 date upper bound (exclusive)' },
        include_external: {
          type: 'boolean',
          description: 'Include costs recorded by import_asset for images made outside the app (default true). Pass false for the app\'s own spend only.',
        },
      },
    },
  },
  {
    name: 'mark_asset_used',
    description: 'Record that an asset was used in a deliverable. Updates index.json. Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['id', 'used_in'],
      properties: {
        id:      { type: 'string', description: 'Asset UUID' },
        used_in: { type: 'string', description: 'Name of the document or deliverable where the asset was used' },
      },
    },
  },
  {
    name: 'upload_asset',
    description:
      'Upload an asset\'s image bytes from the library to a URL that a receiving system has already minted — currently the Deliverable Orchestration portal\'s artefact asset flow. ' +
      'The app reads the file and performs the PUT itself, so the bytes never pass through this conversation; only a receipt (size, content type, HTTP status) comes back. ' +
      'The destination is restricted to known Ionic upload hosts over HTTPS — an arbitrary URL will be refused. ' +
      'Get `upload_url` from the receiving system first (for DO: artefact_asset_upload_url), then call its finalise step afterwards. ' +
      'Does not record usage — call mark_asset_used separately if the asset has landed in a deliverable. ' +
      'Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['id', 'upload_url'],
      properties: {
        id:         { type: 'string', description: 'Asset UUID to upload' },
        upload_url: { type: 'string', description: 'HTTPS upload target minted by the receiving system. Must be an allowed Ionic upload host.' },
      },
    },
  },
  {
    name: 'list_generation_options',
    description:
      'List what the app can make right now: the media types, the quality tiers and what each resolves to, capabilities, cost estimates in GBP, and which providers are configured. ' +
      'This is the only place model names and prices appear. Pass include_all to add every model the app can reach, each with its estimate, for use as `model` in generate. ' +
      'Requires the app to be running.',
    inputSchema: {
      type: 'object',
      properties: {
        include_all: { type: 'boolean', description: 'Also list every discoverable model, not just what the tiers resolve to (default false).' },
      },
    },
  },
  {
    name: 'generate',
    description:
      'Generate one or more images (or vector graphics) and save them as library assets. Say what you want — media, quality, capabilities, budget — and the app picks the provider and model. ' +
      'Prompt accepts either a plain string or a structured JSON object (Subject/Context/Style shape recommended; arbitrary keys are flattened to prose). ' +
      'media "video" and "audio" are not yet supported. Call list_generation_options first to see the tiers and what they cost. ' +
      'The app applies default budget caps per call; raise them within the app\'s ceiling with max_images / max_cost_gbp. ' +
      'File the result to a project (list_projects) and reuse existing tags (list_tags) rather than inventing new ones. ' +
      GENERATE_RESPONSE + ' Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['prompt'],
      properties: {
        media: {
          type: 'string',
          enum: ['image', 'vector', 'video', 'audio'],
          description: 'What to make (default "image"). "vector" returns SVG. "video" and "audio" return "not yet supported".',
        },
        ...GENERATE_PROPERTIES,
      },
    },
  },
  {
    name: 'generate_image',
    description:
      'Alias for generate with media "image", kept for existing callers: the same inputs resolve the same way. Prefer generate. ' +
      'Generates one or more images and saves them as library assets. ' +
      'Prompt accepts either a plain string or a structured JSON object (Subject/Context/Style shape recommended; arbitrary keys are flattened to prose). ' +
      GENERATE_RESPONSE + ' Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['prompt'],
      properties: { ...GENERATE_PROPERTIES },
    },
  },
  {
    name: 'create_client',
    description:
      'Create a client (the organisation projects are done for). Names are unique ignoring case: if one already exists it is returned unchanged, with created: false, never duplicated. ' +
      'Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['name'],
      properties: {
        name: { type: 'string', description: 'Client name, as it should appear in the library' },
      },
    },
  },
  {
    name: 'create_project',
    description:
      'Create a project, optionally for a client. Names are unique ignoring case: if one already exists it is returned unchanged, with created: false, never duplicated. ' +
      'This is the only way to make a project: generate and import_asset refuse a project that does not exist. Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['name'],
      properties: {
        name:        { type: 'string', description: 'Project name' },
        client:      { type: 'string', description: 'Client name or UUID. It must exist already (create_client); an unknown one is refused with the list of clients.' },
        description: { type: 'string', description: 'What the project is, in a sentence' },
      },
    },
  },
  {
    name: 'file_assets',
    description:
      'File existing assets to a project. mode "add" (default) keeps each asset\'s other projects; "move" replaces them all with this one, which becomes the primary. ' +
      'Returns a result per asset ID: an ID that matches no asset is reported as unknown, never skipped silently. Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['asset_ids', 'project'],
      properties: {
        asset_ids: { type: 'array', items: { type: 'string' }, description: 'Asset UUIDs to file' },
        project:   { type: 'string', description: 'Project name or UUID. It must exist (create_project).' },
        mode:      { type: 'string', enum: ['add', 'move'], description: '"add" keeps the asset\'s other projects (default); "move" replaces them.' },
        primary:   { type: 'boolean', description: 'With mode "add", make this the asset\'s primary project (default false; an asset with no primary gets it anyway). "move" always makes it the primary.' },
      },
    },
  },
  {
    name: 'import_asset',
    description:
      'Import an image file made outside the app (for example by a script calling a provider directly) into the library, with its prompt, provider, model, cost, project(s), tags and variant family. ' +
      'Give the file\'s absolute path: this proxy reads the file and sends the bytes, because the app is sandboxed. ' +
      'Only png, jpg, jpeg, webp, heic and svg are accepted, checked by content as well as by name, up to 25 MB; a link to a file outside its own folder is refused. ' +
      'If the same image (same SHA-256) is already in the library it is not stored again: the existing asset ID comes back, with the projects and tags given added to it. ' +
      'File it to a project and reuse existing tags (list_tags) rather than inventing new ones. Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['path'],
      properties: {
        path:            { type: 'string', description: 'Absolute path of the image file (a leading ~/ is your home folder)' },
        prompt:          { type: 'string', description: 'The prompt the image was made from' },
        provider:        { type: 'string', description: 'Who made it, as a provider ID such as those get_asset reports (default "imported")' },
        model:           { type: 'string', description: 'The model ID that made it, as the provider names it (default "imported")' },
        actual_cost_gbp: { type: 'number', minimum: 0, description: 'What it cost, in pounds, if known. Recorded as spend marked external. Leave it out when unknown: it is then recorded as unknown, never as zero.' },
        actual_cost_usd: { type: 'number', minimum: 0, description: 'What it cost, in dollars, if known; the app converts it to pounds at its own rate. Use this or actual_cost_gbp, not both.' },
        created_at:      { type: 'string', description: 'When the image was made, ISO 8601. Default: the file\'s modification time. The import time is recorded separately.' },
        project:         { type: 'string', description: 'Project name or UUID (primary). It must exist (create_project).' },
        projects:        { type: 'array', items: { type: 'string' }, description: 'More project names or UUIDs; the first is the primary when `project` is not given' },
        tags:            { type: 'array', items: { type: 'string' }, description: REUSE_TAGS },
        variant_family:  { type: 'string', description: 'Variant family to add it to; created if it does not exist. Default: one named from the prompt or filename.' },
      },
    },
  },
  {
    name: 'list_tags',
    description:
      'List every tag in the library with how many assets carry it, most used first. Check it before tagging, and reuse a tag that fits. Requires the app to be running.',
    inputSchema: { type: 'object', properties: {} },
  },
];

// ---------------------------------------------------------------------------
// import_asset: the proxy reads the file, because the sandboxed app cannot.
// ---------------------------------------------------------------------------

/** The largest file import_asset sends (25 MB, as the app's LibraryTools.maxImportBytes). */
export const IMPORT_MAX_BYTES = 25 * 1024 * 1024;

/** Extension → the MIME type the file's content must be. */
const IMPORT_TYPES = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  heic: 'image/heic',
  svg: 'image/svg+xml',
};

const HEIC_BRANDS = new Set(['heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'hevm', 'hevs']);

/** An `<svg>` root after any BOM, XML declaration, comments and doctype. */
function isSVG(buf) {
  let text = buf.subarray(0, 4096).toString('utf8');
  if (text.includes('\u0000')) return false;
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  text = text.trimStart();
  for (;;) {
    const close = text.startsWith('<?') ? '?>' : text.startsWith('<!--') ? '-->' : /^<!doctype/i.test(text) ? '>' : null;
    if (!close) break;
    const end = text.indexOf(close);
    if (end < 0) return false;
    text = text.slice(end + close.length).trimStart();
  }
  return /^<svg[\s>/]/.test(text);
}

/** What the bytes are, by their signature: the same five types the app's MediaType sniffs. */
export function sniffMediaType(buf) {
  const ascii = (start, end) => buf.subarray(start, end).toString('latin1');
  if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length >= 12 && ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP') return 'image/webp';
  if (buf.length >= 12 && ascii(4, 8) === 'ftyp') {
    const end = Math.min(buf.readUInt32BE(0), buf.length, 64);
    const brands = [ascii(8, 12)];
    for (let offset = 16; offset + 4 <= end; offset += 4) brands.push(ascii(offset, offset + 4));
    if (brands.some(b => HEIC_BRANDS.has(b))) return 'image/heic';
  }
  if (isSVG(buf)) return 'image/svg+xml';
  return null;
}

/**
 * Turn the agent's import_asset arguments into what the app receives: the file's bytes (base64)
 * with `media_type`, `original_filename` and `file_modified_at`, and never the path. Throws, saying
 * why, for a relative or unreadable path, a link whose target lies outside the given file's folder,
 * an extension not on the list, content that is not what the extension says, or a file over 25 MB.
 */
export function prepareImportArgs(args) {
  const { path: given, data_base64, media_type, original_filename, file_modified_at, ...rest } = args ?? {};
  if (typeof given !== 'string' || !given.trim()) {
    throw new Error('import_asset needs `path`: the absolute path of the image file to import.');
  }
  let absolute = given.trim();
  if (absolute === '~' || absolute.startsWith('~/')) absolute = path.join(os.homedir(), absolute.slice(1));
  if (!path.isAbsolute(absolute)) {
    throw new Error(`import_asset needs an absolute path; '${given}' is relative.`);
  }

  // The real path, links resolved, must lie inside the real folder the caller named.
  let folder, real;
  try {
    folder = fs.realpathSync(path.dirname(absolute));
    real = fs.realpathSync(absolute);
  } catch (error) {
    throw new Error(`Cannot read '${given}': ${error.code ?? error.message}`);
  }
  const inside = path.relative(folder, real);
  if (!inside || inside.split(path.sep)[0] === '..' || path.isAbsolute(inside)) {
    throw new Error(`'${given}' is a link to a file outside its own folder (${path.dirname(absolute)}); import the file itself.`);
  }

  const extension = path.extname(real).slice(1).toLowerCase();
  const expected = IMPORT_TYPES[extension];
  if (!expected) {
    throw new Error(`'${path.basename(real)}' is not an image import_asset accepts: only ${Object.keys(IMPORT_TYPES).join(', ')}.`);
  }

  // Only a regular file, checked with lstat before it is opened: opening a FIFO or a device
  // blocks, and this runs on the proxy's only thread.
  let linkStat;
  try {
    linkStat = fs.lstatSync(real);
  } catch (error) {
    throw new Error(`Cannot read '${given}': ${error.code ?? error.message}`);
  }
  if (!linkStat.isFile()) throw new Error(`'${given}' is not a regular file.`);

  // Opened without following a link, and non-blocking in case a FIFO was swapped in since the
  // lstat, so the file read is the one checked above; the cap is applied to what is actually read,
  // not only to what stat said.
  let fd;
  try {
    fd = fs.openSync(real, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0) | (fs.constants.O_NONBLOCK ?? 0));
  } catch (error) {
    throw new Error(`Cannot read '${given}': ${error.code ?? error.message}`);
  }
  let data, stat;
  try {
    stat = fs.fstatSync(fd);
    // The descriptor must be a regular file, and the same one lstat saw, before anything is read.
    if (!stat.isFile() || stat.dev !== linkStat.dev || stat.ino !== linkStat.ino) {
      throw new Error(`'${given}' is not a regular file.`);
    }
    if (stat.size > IMPORT_MAX_BYTES) {
      throw new Error(`'${path.basename(real)}' is ${stat.size} bytes, over the ${IMPORT_MAX_BYTES}-byte (25 MB) import limit.`);
    }
    const buffer = Buffer.alloc(IMPORT_MAX_BYTES + 1);
    let length = 0, read;
    while (length < buffer.length && (read = fs.readSync(fd, buffer, length, buffer.length - length, null)) > 0) length += read;
    if (length > IMPORT_MAX_BYTES) {
      throw new Error(`'${path.basename(real)}' grew past the ${IMPORT_MAX_BYTES}-byte (25 MB) import limit while it was read.`);
    }
    data = buffer.subarray(0, length);
  } finally {
    fs.closeSync(fd);
  }
  if (data.length === 0) throw new Error(`'${given}' is empty.`);

  const actual = sniffMediaType(data);
  if (actual !== expected) {
    throw new Error(
      `'${path.basename(real)}' is named as ${expected} but its content is ${actual ?? 'not an image import_asset accepts'}; nothing was sent.`);
  }

  return {
    ...rest,
    data_base64: data.toString('base64'),
    media_type: actual,
    original_filename: path.basename(absolute),
    file_modified_at: stat.mtime.toISOString(),
  };
}
