// Offline fallback: media_type survives an index.json that App Store 1.0.x rewrote without it.
// Run: node --test mcp-server/test/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { callFallbackTool } from '../src/fallback.js';
import { TOOL_TIMEOUTS_MS } from '../src/appClient.js';

function libraryWith(records) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'iam-fallback-'));
  fs.writeFileSync(path.join(dir, 'index.json'), JSON.stringify(records));
  return dir;
}

// Expected values worked by hand from the v8 backfill mapping.
const records = [
  { id: 'new', filename: 'logo.svg', media_type: 'image/svg+xml', createdAt: '2026-10-22T00:00:00Z' },
  { id: 'old-jpg', filename: 'IMPORTED_01.JPG', createdAt: '2026-10-22T00:00:00Z' },
  { id: 'old-svg', filename: 'mark.svg', createdAt: '2026-10-22T00:00:00Z' },
  { id: 'old-gif', filename: 'spinner.gif', createdAt: '2026-10-22T00:00:00Z' },
];

test('get_asset names the media type of a record written without one', () => {
  const dir = libraryWith(records);
  assert.equal(callFallbackTool('get_asset', { id: 'old-jpg' }, dir).media_type, 'image/jpeg');
  assert.equal(callFallbackTool('get_asset', { id: 'old-svg' }, dir).media_type, 'image/svg+xml');
});

test('search_assets carries media_type on every known type and leaves the unknown without', () => {
  const dir = libraryWith(records);
  const byID = Object.fromEntries(
    callFallbackTool('search_assets', {}, dir).map(a => [a.id, a.media_type])
  );
  assert.deepEqual(byID, {
    'new': 'image/svg+xml',
    'old-jpg': 'image/jpeg',
    'old-svg': 'image/svg+xml',
    'old-gif': undefined,
  });
});

test('the generation tools give a clear offline error, even when there is no index.json to read', () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'iam-fallback-empty-'));   // no index.json here
  for (const name of ['generate', 'generate_image', 'list_generation_options']) {
    assert.throws(
      () => callFallbackTool(name, { prompt: 'p' }, empty),
      error => error.message.includes(`'${name}' is not available in offline mode`)
        && error.message.includes('Start the app') && !error.message.includes('index.json')
    );
  }
  // The pair: a read-only tool is not turned away this way (it reaches the index, and says what is missing).
  assert.throws(() => callFallbackTool('search_assets', {}, empty), /index\.json not found/);
});

test('the generation tools have timeouts that outlast a database read', () => {
  assert.equal(TOOL_TIMEOUTS_MS.generate, 300_000);
  assert.equal(TOOL_TIMEOUTS_MS.generate_image, 300_000);
  assert.ok(TOOL_TIMEOUTS_MS.list_generation_options > 8_000);
});

test('offline, list_projects counts assets per project from index.json, and list_tags counts tags', () => {
  const dir = libraryWith([
    { id: 'a', filename: 'a.png', createdAt: '2026-09-24T10:00:00Z', projectIDs: ['p1', 'p2'], projectNames: ['ELEMENTS', 'Labs'], tags: ['film', 'hero'] },
    { id: 'b', filename: 'b.png', createdAt: '2026-10-23T10:00:00Z', projectIDs: ['p2'], projectNames: ['Labs'], tags: ['hero'] },
    { id: 'c', filename: 'c.png', createdAt: '2026-10-24T10:00:00Z', tags: [] },
  ]);
  assert.deepEqual(callFallbackTool('list_projects', {}, dir), [
    { id: 'p1', name: 'ELEMENTS', asset_count: 1, last_used_at: '2026-09-24T10:00:00Z' },
    { id: 'p2', name: 'Labs', asset_count: 2, last_used_at: '2026-10-23T10:00:00Z' },
  ]);
  assert.deepEqual(callFallbackTool('list_tags', {}, dir).tags, [{ name: 'hero', count: 2 }, { name: 'film', count: 1 }]);
});

test('a stored media_type is never overridden by the extension', () => {
  const dir = libraryWith([{ id: 'x', filename: 'x.png', media_type: 'image/webp', createdAt: '2026-10-22T00:00:00Z' }]);
  assert.equal(callFallbackTool('get_asset', { id: 'x' }, dir).media_type, 'image/webp');
});
