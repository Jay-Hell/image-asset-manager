/**
 * HTTP client for the in-app MCP server running on localhost:47821.
 * Throws if the app is not running (ECONNREFUSED).
 */

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const APP_URL = 'http://127.0.0.1:47821';
const DEFAULT_TIMEOUT_MS = 8000;

// The app mints a fresh bearer token on every launch and writes it here (0600).
// Read it per call, not at startup, so an app restart mid-session just works.
const TOKEN_PATH = process.env.MCP_TOKEN_PATH
  ?? join(homedir(), 'Library', 'Application Support', 'ImageAssetManager', 'mcp-token');

function readToken() {
  try {
    return readFileSync(TOKEN_PATH, 'utf8').trim();
  } catch {
    return null;
  }
}

// Tools that legitimately outlast a database read. Without an entry here the proxy aborts while the
// app carries on working — the caller sees a failure, but the side effect still happens, which is
// the worst of both. `generate_image` has always needed this: a provider round trip for up to 20
// images was never going to finish inside 8 seconds.
const TOOL_TIMEOUTS_MS = {
  upload_asset: 180_000,
  generate_image: 300_000,
};

export async function isAppRunning() {
  try {
    const res = await fetch(`${APP_URL}/health`, {
      signal: AbortSignal.timeout(2000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export async function callAppTool(name, args) {
  const headers = { 'Content-Type': 'application/json' };
  const token = readToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${APP_URL}/tool`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name, arguments: args }),
    signal: AbortSignal.timeout(TOOL_TIMEOUTS_MS[name] ?? DEFAULT_TIMEOUT_MS),
  });

  if (!res.ok) {
    throw new Error(`App server returned HTTP ${res.status}`);
  }

  const json = await res.json();
  if (json.error) throw new Error(json.error);
  return json.result;
}
