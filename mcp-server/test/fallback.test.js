// Offline fallback: media_type survives an index.json that App Store 1.0.x rewrote without it.
// Run: node --test mcp-server/test/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { callFallbackTool } from '../src/fallback.js';

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

test('a stored media_type is never overridden by the extension', () => {
  const dir = libraryWith([{ id: 'x', filename: 'x.png', media_type: 'image/webp', createdAt: '2026-10-22T00:00:00Z' }]);
  assert.equal(callFallbackTool('get_asset', { id: 'x' }, dir).media_type, 'image/webp');
});
