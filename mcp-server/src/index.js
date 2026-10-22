#!/usr/bin/env node
/**
 * image-asset-manager-mcp
 *
 * MCP stdio server. When the Image Asset Manager macOS app is running it
 * forwards every tool call to the in-app HTTP server on localhost:47821.
 * When the app is closed it falls back to reading index.json directly from
 * LIBRARY_PATH for read-only operations.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

import { isAppRunning, callAppTool } from './appClient.js';
import { isOfflineTool, callFallbackTool } from './fallback.js';
import { TOOLS } from './tools.js';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const libraryPath = process.env.LIBRARY_PATH;
if (!libraryPath) {
  process.stderr.write(
    '[image-asset-manager-mcp] ERROR: LIBRARY_PATH environment variable is not set.\n'
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = new Server(
  { name: 'image-asset-manager', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;

  let result;

  if (await isAppRunning()) {
    // App is running — forward to localhost:47821
    result = await callAppTool(name, args);
  } else if (isOfflineTool(name)) {
    // App offline — use index.json fallback for read-only tools
    result = callFallbackTool(name, args, libraryPath);
  } else {
    return {
      content: [{
        type: 'text',
        text: `Tool '${name}' requires the Image Asset Manager app to be running. ` +
              `Start the app and try again.`,
      }],
      isError: true,
    };
  }

  return {
    content: [{
      type: 'text',
      text: JSON.stringify(result, null, 2),
    }],
  };
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);
