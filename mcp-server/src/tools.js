/** Tool definitions (name, description, inputSchema) for ListTools response.
 *
 * Descriptions name no model and state no price: both change, and a description cannot be
 * kept current. An agent learns what can be made, and at what cost, from list_generation_options.
 * (mcp-server/test/tools.test.js holds this to account.)
 */

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
      'Project name or UUID (shorthand — use `projects` for multiple). When provided, the project\'s active reference set is loaded automatically, and the generated asset(s) are assigned to this project.',
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
    description: 'Tags to apply to the generated asset(s). Tags are created on demand if they don\'t exist.',
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
    description: 'List all projects in the library.',
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
];
