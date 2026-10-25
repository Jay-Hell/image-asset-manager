/**
 * HTTP client for the in-app MCP server running on localhost:47821.
 * Throws if the app is not running (ECONNREFUSED).
 *
 * When the app is not running, `ensureAppRunning` opens it by path (`open /Applications/ImageAssetManager.app`),
 * waits for it to answer with a new token (release 1.2, Q4) and checks that the copy answering is the
 * one it opened. The launcher, the clock, the sleep and
 * `fetch` are injected through `createAppClient`, so tests never open the real app.
 */

import { execFile } from 'node:child_process';
import { readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const APP_URL = 'http://127.0.0.1:47821';
const DEFAULT_TIMEOUT_MS = 8000;

/**
 * The copy of the app the proxy opens, by path. Never by bundle ID: LaunchServices would pick
 * whichever registered copy has the highest version, which can be a DerivedData or scratch build of
 * a branch under review, and it would then migrate the live library.
 */
export const DEFAULT_APP_PATH = '/Applications/ImageAssetManager.app';
/** Overrides the path, for tests and development only. */
export const APP_PATH_ENV = 'IMAGE_ASSET_MANAGER_APP_PATH';
/** How long a launch may take before the call fails, and how often /health is asked meanwhile. */
export const LAUNCH_TIMEOUT_MS = 30_000;
export const LAUNCH_POLL_MS = 500;
/** Before the app is opened, /health is tried this many times, this far apart (about 1.5 s in all). */
export const HEALTH_TRIES = 3;
export const HEALTH_RETRY_MS = 750;

export function appPathFromEnv(env = process.env) {
  return env[APP_PATH_ENV] || DEFAULT_APP_PATH;
}

// The app mints a fresh bearer token on every launch and writes it (0600) to
// its Application Support dir once its listener is ready. The app is SANDBOXED, so that resolves
// inside its container — the plain ~/Library path is kept as a fallback in case the
// sandbox is ever dropped. Read per call, not at startup, so an app restart
// mid-session just works.
const TOKEN_PATHS = process.env.MCP_TOKEN_PATH
  ? [process.env.MCP_TOKEN_PATH]
  : [
      join(homedir(), 'Library', 'Containers', 'Ionic.ImageAssetManager', 'Data',
           'Library', 'Application Support', 'ImageAssetManager', 'mcp-token'),
      join(homedir(), 'Library', 'Application Support', 'ImageAssetManager', 'mcp-token'),
    ];

function readTokenFile() {
  for (const path of TOKEN_PATHS) {
    try {
      return readFileSync(path, 'utf8').trim();
    } catch {
      // try the next candidate
    }
  }
  return null;
}

/** When the token file was last written (ms since the epoch), or null if there is none. */
function tokenFileModifiedAt() {
  for (const path of TOKEN_PATHS) {
    try {
      return statSync(path).mtimeMs;
    } catch {
      // try the next candidate
    }
  }
  return null;
}

/** Opens the app bundle at `appPath` (`open <path>`). `run` is execFile, injected for the tests. */
export function openApp(appPath, run = execFile) {
  return new Promise((resolve, reject) => {
    run('open', [appPath], error => (error ? reject(error) : resolve()));
  });
}

/** Whether the bundle path /health reported is the one launched, ignoring a trailing slash and links. */
function isSameBundle(reported, launched) {
  if (typeof reported !== 'string' || !reported) return false;
  const trim = p => p.replace(/\/+$/, '');
  const accepted = new Set([trim(launched)]);
  try {
    accepted.add(trim(realpathSync(launched)));
  } catch {
    // not on this disk: compare as written
  }
  return accepted.has(trim(reported));
}

// Tools that legitimately outlast a database read. Without an entry here the proxy aborts while the
// app carries on working — the caller sees a failure, but the side effect still happens, which is
// the worst of both. `generate_image` has always needed this: a provider round trip for up to 20
// images was never going to finish inside 8 seconds.
const TOOL_TIMEOUTS_MS = {
  upload_asset: 180_000,
  generate: 300_000,
  generate_image: 300_000,
  // May fetch OpenRouter's model list on demand (20 s) before it answers.
  list_generation_options: 60_000,
  // Up to 25 MB written into the library (which may be iCloud), then index.json.
  import_asset: 60_000,
};

export { TOOL_TIMEOUTS_MS };

export function createAppClient({
  fetchImpl = (...a) => fetch(...a),
  readToken = readTokenFile,
  tokenModifiedAt = tokenFileModifiedAt,
  launch = openApp,
  now = () => Date.now(),
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  appURL = APP_URL,
  appPath = appPathFromEnv(),
} = {}) {
  /** What /health answered ({status, bundle_path, version, build}), or null if it did not. */
  async function health() {
    try {
      const res = await fetchImpl(`${appURL}/health`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!res.ok) return null;
      try {
        return (await res.json()) ?? {};
      } catch {
        return {};
      }
    } catch {
      return null;
    }
  }

  async function isAppRunning() {
    return (await health()) !== null;
  }

  /**
   * Resolves once the app answers /health. An app already running is used as it is: someone started
   * it deliberately. Otherwise, after three tries 750 ms apart, opens the copy at `appPath`; polls
   * every 500 ms for at most 30 s until /health answers and the token file is newer than the launch;
   * then checks /health reports the path launched, and throws, naming both, if it does not.
   */
  async function ensureAppRunning() {
    for (let attempt = 1; attempt <= HEALTH_TRIES; attempt += 1) {
      if (await isAppRunning()) return { launched: false };
      if (attempt < HEALTH_TRIES) await sleep(HEALTH_RETRY_MS);
    }
    const launchedAt = now();
    try {
      await launch(appPath);
    } catch (error) {
      throw new Error(
        `Image Asset Manager is not running and could not be opened (open ${appPath}): ${error.message}`);
    }
    const deadline = launchedAt + LAUNCH_TIMEOUT_MS;
    while (now() < deadline) {
      await sleep(LAUNCH_POLL_MS);
      const answered = await health();
      if (answered === null) continue;
      // The copy answering must be the one opened, before any token or tool call is sent. A copy that
      // reports no path is a build before 1.2 (the store's 1.1.0 until 1.2 ships); it is accepted,
      // because the proxy has just opened the copy at appPath by path. A reported path must match.
      const legacy = answered.bundle_path === undefined || answered.bundle_path === null;
      if (!legacy && !isSameBundle(answered.bundle_path, appPath)) {
        const version = answered.version ? ` ${answered.version}${answered.build ? ` (${answered.build})` : ''}` : '';
        const which = answered.bundle_path
          ? `the copy answering is ${answered.bundle_path}${version}`
          : `the copy answering reported no path${version} (a build older than 1.2)`;
        throw new Error(
          `Image Asset Manager was opened from ${appPath}, but ${which}. No tool call was sent. ` +
          'Quit that copy, then try again.');
      }
      const written = tokenModifiedAt();
      // A token older than the launch is the last run's: the new listener has not published yet.
      if (written !== null && written > launchedAt) return { launched: true, waitedMs: now() - launchedAt };
    }
    throw new Error(
      `Image Asset Manager was opened but did not answer with a new token within ${LAUNCH_TIMEOUT_MS / 1000} s ` +
      `(checked every ${LAUNCH_POLL_MS} ms). Check the app has opened its library, then try again.`);
  }

  async function callAppTool(name, args) {
    const post = token => {
      const headers = { 'Content-Type': 'application/json' };
      if (token) headers.Authorization = `Bearer ${token}`;
      return fetchImpl(`${appURL}/tool`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ name, arguments: args }),
        signal: AbortSignal.timeout(TOOL_TIMEOUTS_MS[name] ?? DEFAULT_TIMEOUT_MS),
      });
    };

    let res = await post(readToken());
    if (res.status === 401) {
      // The app refuses a token before it runs the tool, so a retry cannot repeat a side effect.
      // The file may have been rewritten since it was read (an app restart): read it once more.
      res = await post(readToken());
      if (res.status === 401) {
        throw new Error(
          'App server returned HTTP 401: it refused the MCP token twice, the second time after re-reading the token file. ' +
          'Another copy of the app may have written it; quit the extra copy, or relaunch the app.');
      }
    }

    if (!res.ok) {
      throw new Error(`App server returned HTTP ${res.status}`);
    }

    const json = await res.json();
    if (json.error) throw new Error(json.error);
    return json.result;
  }

  return { isAppRunning, ensureAppRunning, callAppTool };
}

const defaultClient = createAppClient();
export const { isAppRunning, ensureAppRunning, callAppTool } = defaultClient;
