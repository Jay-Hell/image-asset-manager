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

import { ensureAppRunning, callAppTool } from './appClient.js';
import { isOfflineTool, callFallbackTool } from './fallback.js';
import { TOOLS, prepareImportArgs } from './tools.js';

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
  { name: 'image-asset-manager', version: '1.1.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: given = {} } = request.params;
  let args = given;

  // import_asset: the file is read and checked here, before the app is asked for anything. The app
  // receives the bytes and never the path (it is sandboxed and cannot read it).
  if (name === 'import_asset') {
    try {
      args = prepareImportArgs(given);
    } catch (error) {
      return { content: [{ type: 'text', text: error.message }], isError: true };
    }
  }

  let result;

  // Opens the app if it is not running and waits (at most 30 s) for it to answer with a new token.
  let launchError = null;
  try {
    await ensureAppRunning();
  } catch (error) {
    launchError = error;
  }

  if (!launchError) {
    // App is running — forward to localhost:47821
    result = await callAppTool(name, args);
  } else if (isOfflineTool(name)) {
    // App offline — use index.json fallback for read-only tools
    result = callFallbackTool(name, args, libraryPath);
  } else {
    return {
      content: [{
        type: 'text',
        text: `Tool '${name}' requires the Image Asset Manager app to be running. ${launchError.message}`,
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
