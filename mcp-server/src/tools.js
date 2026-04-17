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
        project:      { type: 'string',  description: 'Filter by project name' },
        collection:   { type: 'string',  description: 'Filter by collection name' },
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
    name: 'list_collections',
    description: 'List collections, optionally filtered by project ID.',
    inputSchema: {
      type: 'object',
      properties: {
        project_id: { type: 'string', description: 'Filter to collections belonging to this project ID' },
      },
    },
  },
  {
    name: 'get_collection',
    description: 'Get collection details including the ordered list of assets it contains.',
    inputSchema: {
      type: 'object',
      required: ['id'],
      properties: {
        id: { type: 'string', description: 'Collection UUID' },
      },
    },
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
];
