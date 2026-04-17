/**
 * HTTP client for the in-app MCP server running on localhost:47821.
 * Throws if the app is not running (ECONNREFUSED).
 */

const APP_URL = 'http://127.0.0.1:47821';
const TIMEOUT_MS = 8000;

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
  const res = await fetch(`${APP_URL}/tool`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, arguments: args }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });

  if (!res.ok) {
    throw new Error(`App server returned HTTP ${res.status}`);
  }

  const json = await res.json();
  if (json.error) throw new Error(json.error);
  return json.result;
}
