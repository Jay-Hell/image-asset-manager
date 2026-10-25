// The proxy's client for the app: opening it when it is not running (Q4), and one retry after a 401.
// The launcher, the clock, the sleep and fetch are all fakes: no test opens the real app or a socket.
// Run: node --test "mcp-server/test/*.test.js"

import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as appClient from '../src/appClient.js';

const { createAppClient, LAUNCH_TIMEOUT_MS, LAUNCH_POLL_MS } = appClient;

const T0 = 1_000_000;
const APP = '/Applications/ImageAssetManager.app';
// Before a launch, /health is tried three times, 750 ms apart: the launch happens 1.5 s after T0.
const L = T0 + 1500;

/**
 * A fake world: a clock moved only by sleep, /health that answers while `up(clock)` holds and
 * reports `reported` as its body, and a token file date.
 */
function world({
  up = () => false, tokenAt = () => null, launchFails = false,
  reported = { status: 'ok', bundle_path: APP, version: '1.2.0', build: '6' }, appPath,
} = {}) {
  const w = { clock: T0, launches: 0, launchedWith: [], healthChecks: 0, sleeps: [] };
  w.client = createAppClient({
    now: () => w.clock,
    sleep: async ms => { w.sleeps.push(ms); w.clock += ms; },
    launch: async path => {
      w.launches += 1;
      w.launchedWith.push(path);
      if (launchFails) throw new Error('LSOpenURLsWithRole() failed');
    },
    tokenModifiedAt: () => tokenAt(w.clock),
    readToken: () => 'tok',
    fetchImpl: async url => {
      assert.ok(url.endsWith('/health'), `unexpected request to ${url}`);
      w.healthChecks += 1;
      if (!up(w.clock)) throw new TypeError('fetch failed: ECONNREFUSED');
      return { ok: true, status: 200, json: async () => reported };
    },
    ...(appPath ? { appPath } : {}),
  });
  return w;
}

test('the limits are the ones the briefs name: 30 s, checked every 500 ms; three tries 750 ms apart; launched by path', () => {
  assert.equal(LAUNCH_TIMEOUT_MS, 30_000);
  assert.equal(LAUNCH_POLL_MS, 500);
  assert.equal(appClient.HEALTH_TRIES, 3);
  assert.equal(appClient.HEALTH_RETRY_MS, 750);
  assert.equal(appClient.DEFAULT_APP_PATH, APP);
});

test('the app is opened by its path, /Applications unless the development variable names another', async () => {
  assert.equal(appClient.appPathFromEnv({}), APP);
  assert.equal(appClient.appPathFromEnv({ IMAGE_ASSET_MANAGER_APP_PATH: '' }), APP);
  assert.equal(appClient.appPathFromEnv({ IMAGE_ASSET_MANAGER_APP_PATH: '/Users/dev/Build/ImageAssetManager.app' }),
    '/Users/dev/Build/ImageAssetManager.app');
  // The command that leaves the process: `open <path>`, never `open -b <bundle ID>`.
  const ran = [];
  await appClient.openApp(APP, (file, args, done) => { ran.push([file, args]); done(null); });
  assert.deepEqual(ran, [['open', [APP]]]);

  // And the client hands the launcher its path: the default, or the one it was given.
  const w = world({ up: c => c >= L + 500, tokenAt: () => L + 100 });
  await w.client.ensureAppRunning();
  assert.deepEqual(w.launchedWith, [APP]);
  const dev = '/tmp/dd/Build/Products/Debug/ImageAssetManager.app';
  const d = world({ up: c => c >= L + 500, tokenAt: () => L + 100, appPath: dev, reported: { status: 'ok', bundle_path: dev } });
  await d.client.ensureAppRunning();
  assert.deepEqual(d.launchedWith, [dev]);
});

test('an app that is running is not opened again, and is used as it is, wherever it runs from', async () => {
  const w = world({ up: () => true, reported: { status: 'ok', bundle_path: '/Users/x/DerivedData/ImageAssetManager.app' } });
  assert.deepEqual(await w.client.ensureAppRunning(), { launched: false });
  assert.equal(w.launches, 0);
  assert.equal(w.healthChecks, 1);
  assert.deepEqual(w.sleeps, []);
});

test('a brief miss on /health is tried again, three tries over 1.5 s, before the app is opened', async () => {
  // Misses at T0, answers at T0 + 750: the second try finds it, and nothing is opened.
  const blip = world({ up: c => c >= T0 + 750 });
  assert.deepEqual(await blip.client.ensureAppRunning(), { launched: false });
  assert.equal(blip.launches, 0);
  assert.equal(blip.healthChecks, 2);
  assert.deepEqual(blip.sleeps, [750]);
  // The third try, at T0 + 1500, is the last that counts as running.
  const late = world({ up: c => c >= T0 + 1500 });
  assert.deepEqual(await late.client.ensureAppRunning(), { launched: false });
  assert.equal(late.healthChecks, 3);
  // The pair: three misses, and it is opened.
  const down = world({ up: c => c > L, tokenAt: () => L + 1 });
  assert.equal((await down.client.ensureAppRunning()).launched, true);
  assert.equal(down.launches, 1);
  assert.deepEqual(down.sleeps.slice(0, 3), [750, 750, 500]);
});

test('an app that is not running is opened, and the call waits for /health and a token newer than the launch', async () => {
  // /health answers 1.5 s after the launch, but the token file is the last run's until 4 s, when the
  // new listener writes it. Worked by hand: the call returns at the first poll on or after 4 s.
  const w = world({ up: c => c >= L + 1500, tokenAt: clock => (clock >= L + 4000 ? L + 3900 : L - 60_000) });
  const result = await w.client.ensureAppRunning();
  assert.deepEqual(result, { launched: true, waitedMs: 4000 });
  assert.equal(w.launches, 1);
  assert.deepEqual(w.sleeps, [750, 750, ...Array(8).fill(500)]);
  assert.equal(w.healthChecks, 3 + 8);

  // The pair: with a fresh token as soon as /health answers, the call goes on at 1.5 s.
  const fresh = world({ up: c => c >= L + 1500, tokenAt: () => L + 1200 });
  assert.deepEqual(await fresh.client.ensureAppRunning(), { launched: true, waitedMs: 1500 });
});

test('a launched app that reports another path fails, naming both paths, and no tool call is sent', async () => {
  const other = '/Users/john/Library/Developer/Xcode/DerivedData/IAM/Build/Products/Debug/ImageAssetManager.app';
  const w = world({ up: c => c >= L + 1000, tokenAt: () => L + 900,
    reported: { status: 'ok', bundle_path: other, version: '1.2.0', build: '7' } });
  await assert.rejects(w.client.ensureAppRunning(), error =>
    error.message.includes(APP) && error.message.includes(other) && /1\.2\.0 \(7\)/.test(error.message));
  // Only /health was asked (the fake refuses anything else), and it stopped at the first answer.
  assert.equal(w.healthChecks, 3 + 2);

  // An app that reports no path at all (a build before 1.2) is refused the same way.
  const old = world({ up: c => c >= L + 1000, tokenAt: () => L + 900, reported: { status: 'ok' } });
  await assert.rejects(old.client.ensureAppRunning(), error =>
    error.message.includes(APP) && /reported no path/.test(error.message));

  // The pair: the path it launched, even written with a trailing slash, goes on.
  const same = world({ up: c => c >= L + 1000, tokenAt: () => L + 900, reported: { status: 'ok', bundle_path: `${APP}/` } });
  assert.deepEqual(await same.client.ensureAppRunning(), { launched: true, waitedMs: 1000 });
});

test('an app that never answers fails after 30 s, saying so, having polled every 500 ms', async () => {
  const w = world();
  await assert.rejects(w.client.ensureAppRunning(), error =>
    /did not answer with a new token within 30 s/.test(error.message) && /every 500 ms/.test(error.message));
  assert.equal(w.launches, 1);
  // Worked by hand: two 750 ms waits between the three tries, then polls at 0.5 s, 1 s, … 30 s
  // after the launch: 60 sleeps of 500 ms, and 1.5 s + 30 s has passed, no more.
  assert.deepEqual(w.sleeps.slice(0, 2), [750, 750]);
  assert.equal(w.sleeps.length, 2 + 60);
  assert.ok(w.sleeps.slice(2).every(ms => ms === 500));
  assert.equal(w.clock - T0, 1500 + 30_000);
  assert.equal(w.healthChecks, 3 + 60);
});

test('an app that answers with only the old token is still a failure at 30 s', async () => {
  const w = world({ up: c => c >= L + 500, tokenAt: () => L - 1 });
  await assert.rejects(w.client.ensureAppRunning(), /within 30 s/);
  assert.equal(w.clock - L, 30_000);
});

test('an app that cannot be opened fails at once, naming the command', async () => {
  const w = world({ launchFails: true });
  await assert.rejects(w.client.ensureAppRunning(),
    /could not be opened \(open \/Applications\/ImageAssetManager\.app\): LSOpenURLsWithRole/);
  assert.deepEqual(w.sleeps, [750, 750]);
});

/** A fake /tool endpoint that answers with the statuses given, in turn, and records what was sent. */
function toolServer(statuses, tokens) {
  const sent = [];
  let reads = 0;
  const client = createAppClient({
    readToken: () => tokens[Math.min(reads++, tokens.length - 1)],
    fetchImpl: async (url, init) => {
      sent.push({ url, authorization: init.headers.Authorization, body: JSON.parse(init.body) });
      const status = statuses[Math.min(sent.length - 1, statuses.length - 1)];
      return { ok: status === 200, status, json: async () => ({ result: { asset_id: 'A1' } }) };
    },
  });
  return { client, sent, reads: () => reads };
}

test('after a 401 the token is read again once and the call is retried with it', async () => {
  const s = toolServer([401, 200], ['stale-token', 'fresh-token']);
  assert.deepEqual(await s.client.callAppTool('list_tags', {}), { asset_id: 'A1' });
  assert.deepEqual(s.sent.map(r => r.authorization), ['Bearer stale-token', 'Bearer fresh-token']);
  assert.deepEqual(s.sent[1].body, { name: 'list_tags', arguments: {} });
  assert.equal(s.reads(), 2);
});

test('a second 401 is reported and there is no third try; a first-time success reads the token once', async () => {
  const twice = toolServer([401, 401, 200], ['a', 'b', 'c']);
  await assert.rejects(twice.client.callAppTool('list_tags', {}), /HTTP 401: it refused the MCP token twice/);
  assert.equal(twice.sent.length, 2);
  // The pair: no 401, no second read and no second request.
  const ok = toolServer([200], ['a']);
  await ok.client.callAppTool('list_tags', {});
  assert.equal(ok.sent.length, 1);
  assert.equal(ok.reads(), 1);
  // And any other failure is not retried.
  const failing = toolServer([500], ['a']);
  await assert.rejects(failing.client.callAppTool('list_tags', {}), /HTTP 500/);
  assert.equal(failing.sent.length, 1);
});
