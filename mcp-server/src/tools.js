/** Tool definitions (name, description, inputSchema) for ListTools response. */

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
        provider:     { type: 'string',  description: 'Filter by provider ID (e.g. "nano_banana")' },
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
    name: 'generate_image',
    description:
      'Generate one or more images via the Image Asset Manager\'s active provider, save them as library assets, and return their IDs + file paths. ' +
      'Prompt accepts either a plain string or a structured JSON object (Subject/Context/Style shape recommended; arbitrary keys are flattened to prose). ' +
      'Quality tiers: fast (~£0.016), standard (~£0.032), pro (~£0.047, text-only), with_references (~£0.031, only tier that accepts reference images). ' +
      'Default budget caps: 20 images and £2.50 per call — raise via max_images / max_cost_gbp. ' +
      'Requires the app to be running.',
    inputSchema: {
      type: 'object',
      required: ['prompt'],
      properties: {
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
            'Model tier. "auto" picks standard when no references, with_references when references are attached. ' +
            'If references are attached but you pick fast/standard/pro, the server auto-routes to with_references (only tier that accepts refs) and adds a note in the response.',
        },
        count: {
          type: 'integer',
          minimum: 1,
          description: 'Number of images to generate in this call (default 1). Capped by max_images.',
        },
        aspect_ratio: {
          type: 'string',
          enum: ['square', 'landscape', 'portrait'],
          description: 'Output aspect ratio (default "square"). Square = 1024×1024, landscape = 1792×1024, portrait = 1024×1792.',
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
          description: 'Specific asset IDs to use as references, alongside any from the project. Merged and truncated to 3 total.',
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
          description: 'Things to avoid — inlined into the prompt as "Avoid: …". Neither Imagen 4 nor Gemini 2.5 Flash Image supports a native negative-prompt API field.',
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
          description: 'Maximum images the call may produce (default 20). count must be ≤ max_images.',
        },
        max_cost_gbp: {
          type: 'number',
          minimum: 0,
          description: 'Maximum projected spend in GBP for this call (default 2.50). The call is rejected up front if count × unit_cost would exceed this.',
        },
      },
    },
  },
];
