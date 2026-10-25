// The proxy's client for the app: opening it when it is not running (Q4), and one retry after a 401.
// The launcher, the clock, the sleep and fetch are all fakes: no test opens the real app or a socket.
// Run: node --test "mcp-server/test/*.test.js"

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAppClient, LAUNCH_TIMEOUT_MS, LAUNCH_POLL_MS, APP_BUNDLE_ID } from '../src/appClient.js';

const T0 = 1_000_000;

/** A fake world: a clock moved only by sleep, /health that answers from `upAt`, a token file date. */
function world({ upAt = Infinity, tokenAt = () => null, launchFails = false } = {}) {
  const w = { clock: T0, launches: 0, healthChecks: 0, sleeps: [] };
  w.client = createAppClient({
    now: () => w.clock,
    sleep: async ms => { w.sleeps.push(ms); w.clock += ms; },
    launch: async () => {
      w.launches += 1;
      if (launchFails) throw new Error('LSOpenURLsWithRole() failed');
    },
    tokenModifiedAt: () => tokenAt(w.clock),
    readToken: () => 'tok',
    fetchImpl: async url => {
      assert.ok(url.endsWith('/health'), `unexpected request to ${url}`);
      w.healthChecks += 1;
      if (w.clock < upAt) throw new TypeError('fetch failed: ECONNREFUSED');
      return { ok: true, status: 200 };
    },
  });
  return w;
}

test('the limits are the ones the brief names: 30 s, checked every 500 ms, by bundle ID', () => {
  assert.equal(LAUNCH_TIMEOUT_MS, 30_000);
  assert.equal(LAUNCH_POLL_MS, 500);
  assert.equal(APP_BUNDLE_ID, 'Ionic.ImageAssetManager');
});

test('an app that is running is not opened again', async () => {
  const w = world({ upAt: 0 });
  assert.deepEqual(await w.client.ensureAppRunning(), { launched: false });
  assert.equal(w.launches, 0);
  assert.equal(w.healthChecks, 1);
});

test('an app that is not running is opened, and the call waits for /health and a token newer than the launch', async () => {
  // /health answers 1.5 s after the launch, but the token file is the last run's until 4 s, when the
  // new listener writes it. Worked by hand: the call returns at the first poll on or after 4 s.
  const w = world({ upAt: T0 + 1500, tokenAt: clock => (clock >= T0 + 4000 ? T0 + 3900 : T0 - 60_000) });
  const result = await w.client.ensureAppRunning();
  assert.deepEqual(result, { launched: true, waitedMs: 4000 });
  assert.equal(w.launches, 1);
  assert.deepEqual(w.sleeps, Array(8).fill(500));
  assert.equal(w.healthChecks, 1 + 8);

  // The pair: with a fresh token as soon as /health answers, the call goes on at 1.5 s.
  const fresh = world({ upAt: T0 + 1500, tokenAt: () => T0 + 1200 });
  assert.deepEqual(await fresh.client.ensureAppRunning(), { launched: true, waitedMs: 1500 });
});

test('an app that never answers fails after 30 s, saying so, having polled every 500 ms', async () => {
  const w = world();
  await assert.rejects(w.client.ensureAppRunning(), error =>
    /did not answer with a new token within 30 s/.test(error.message) && /every 500 ms/.test(error.message));
  assert.equal(w.launches, 1);
  // Worked by hand: polls at 0.5 s, 1 s, … 30 s is 60 sleeps of 500 ms, and 30 s has passed, no more.
  assert.equal(w.sleeps.length, 60);
  assert.ok(w.sleeps.every(ms => ms === 500));
  assert.equal(w.clock - T0, 30_000);
  assert.equal(w.healthChecks, 1 + 60);
});

test('an app that answers with only the old token is still a failure at 30 s', async () => {
  const w = world({ upAt: T0 + 500, tokenAt: () => T0 - 1 });
  await assert.rejects(w.client.ensureAppRunning(), /within 30 s/);
  assert.equal(w.clock - T0, 30_000);
});

test('an app that cannot be opened fails at once, naming the command', async () => {
  const w = world({ launchFails: true });
  await assert.rejects(w.client.ensureAppRunning(), /could not be opened \(open -b Ionic\.ImageAssetManager\): LSOpenURLsWithRole/);
  assert.equal(w.sleeps.length, 0);
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
