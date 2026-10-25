// import_asset in the proxy (release 1.2 §2.3): the file is read and checked here, and only bytes and
// metadata leave for the app. Run: node --test "mcp-server/test/*.test.js"

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepareImportArgs, IMPORT_MAX_BYTES } from '../src/tools.js';

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]);
const SVG = Buffer.from('<?xml version="1.0"?>\n<!-- logo -->\n<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>');
// An ISO-BMFF ftyp box of 24 bytes: major brand mif1, compatible brands mif1 and heic.
const HEIC = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypmif1'), Buffer.from([0, 0, 0, 0]), Buffer.from('mif1heic')]);

function folder() {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'iam-import-')));
}
function write(dir, name, bytes) {
  const file = path.join(dir, name);
  fs.writeFileSync(file, bytes);
  return file;
}

test('the app is sent the bytes, the media type, the name and the file date, never the path', () => {
  const dir = folder();
  const file = write(dir, 'labs-hero.png', PNG);
  const modified = new Date('2026-10-23T18:40:12.345Z');
  fs.utimesSync(file, modified, modified);

  const sent = prepareImportArgs({ path: file, prompt: 'a glass lab', tags: ['hero'], project: 'Labs', data_base64: 'QUFBQQ==' });
  assert.deepEqual(Object.keys(sent).sort(),
    ['data_base64', 'file_modified_at', 'media_type', 'original_filename', 'project', 'prompt', 'tags']);
  assert.equal(Buffer.from(sent.data_base64, 'base64').equals(PNG), true);   // the file's bytes, not the caller's
  assert.equal(sent.media_type, 'image/png');
  assert.equal(sent.original_filename, 'labs-hero.png');
  assert.equal(sent.file_modified_at, '2026-10-23T18:40:12.345Z');
  assert.equal(sent.prompt, 'a glass lab');
  assert.ok(!JSON.stringify(sent).includes(dir), 'the path must not leave the proxy');
});

test('a link to a file outside its own folder is refused; a link within the folder is read', () => {
  const inside = folder();
  const outside = folder();
  const secret = write(outside, 'elsewhere.png', PNG);
  const escape = path.join(inside, 'innocent.png');
  fs.symlinkSync(secret, escape);
  assert.throws(() => prepareImportArgs({ path: escape }), /is a link to a file outside its own folder/);
  // Through a linked folder name too: ../ in the target.
  const relative = path.join(inside, 'relative.png');
  fs.symlinkSync(path.join('..', path.basename(outside), 'elsewhere.png'), relative);
  assert.throws(() => prepareImportArgs({ path: relative }), /outside its own folder/);

  // The pair: a link to a file in the same folder is fine, and its target's bytes are sent.
  const real = write(inside, 'real.png', PNG);
  const alias = path.join(inside, 'alias.png');
  fs.symlinkSync(real, alias);
  assert.equal(Buffer.from(prepareImportArgs({ path: alias }).data_base64, 'base64').equals(PNG), true);
});

test('content that is not what the extension says is refused, by its magic bytes', () => {
  const dir = folder();
  assert.throws(() => prepareImportArgs({ path: write(dir, 'photo.png', JPEG) }),
    /named as image\/png but its content is image\/jpeg/);
  assert.throws(() => prepareImportArgs({ path: write(dir, 'notes.svg', Buffer.from('just text')) }),
    /named as image\/svg\+xml but its content is not an image/);
  assert.throws(() => prepareImportArgs({ path: write(dir, 'x.webp', PNG) }), /named as image\/webp/);
  // The pair: each accepted type, named for what it is, goes through as that type.
  assert.equal(prepareImportArgs({ path: write(dir, 'a.jpg', JPEG) }).media_type, 'image/jpeg');
  assert.equal(prepareImportArgs({ path: write(dir, 'b.JPEG', JPEG) }).media_type, 'image/jpeg');
  assert.equal(prepareImportArgs({ path: write(dir, 'c.svg', SVG) }).media_type, 'image/svg+xml');
  assert.equal(prepareImportArgs({ path: write(dir, 'd.heic', HEIC) }).media_type, 'image/heic');
  const webp = Buffer.concat([Buffer.from('RIFF'), Buffer.from([4, 0, 0, 0]), Buffer.from('WEBPVP8 ')]);
  assert.equal(prepareImportArgs({ path: write(dir, 'e.webp', webp) }).media_type, 'image/webp');
});

test('only png, jpg, jpeg, webp, heic and svg are accepted by extension, whatever the content', () => {
  const dir = folder();
  for (const name of ['spinner.gif', 'scan.tiff', 'no-extension', 'image.png.txt']) {
    assert.throws(() => prepareImportArgs({ path: write(dir, name, PNG) }), /is not an image import_asset accepts/, name);
  }
});

test('a file over 25 MB is refused before it is read; one at exactly 25 MB is sent', () => {
  assert.equal(IMPORT_MAX_BYTES, 26_214_400);                 // 25 x 1024 x 1024
  const dir = folder();
  const over = write(dir, 'big.png', PNG);
  fs.truncateSync(over, IMPORT_MAX_BYTES + 1);
  assert.throws(() => prepareImportArgs({ path: over }), /is 26214401 bytes, over the 26214400-byte \(25 MB\) import limit/);
  const at = write(dir, 'limit.png', PNG);
  fs.truncateSync(at, IMPORT_MAX_BYTES);
  const sent = prepareImportArgs({ path: at });
  assert.equal(Buffer.from(sent.data_base64, 'base64').length, IMPORT_MAX_BYTES);
});

test('a relative, missing or empty path is refused with the reason', () => {
  const dir = folder();
  assert.throws(() => prepareImportArgs({ path: 'art/hero.png' }), /needs an absolute path/);
  assert.throws(() => prepareImportArgs({}), /needs `path`/);
  assert.throws(() => prepareImportArgs({ path: path.join(dir, 'missing.png') }), /Cannot read .*ENOENT/);
  assert.throws(() => prepareImportArgs({ path: write(dir, 'empty.png', Buffer.alloc(0)) }), /is empty/);
});

/** prepareImportArgs on `file` in a child process, killed after 3 s, so a guard that blocks cannot hang the runner. */
function importInChild(file) {
  const child = spawnSync(process.execPath, [fileURLToPath(new URL('./import-child.js', import.meta.url)), file],
    { timeout: 3000, encoding: 'utf8' });
  return { timedOut: child.error?.code === 'ETIMEDOUT' || child.signal !== null, out: child.stdout };
}

test('a FIFO named x.png is refused at once, and never opened; a regular file through the same path is read', () => {
  const dir = folder();
  const fifo = path.join(dir, 'x.png');
  execFileSync('mkfifo', [fifo]);
  const started = Date.now();
  const refused = importInChild(fifo);
  assert.equal(refused.timedOut, false, 'the guard blocked on the FIFO');
  assert.ok(Date.now() - started < 3000);
  assert.match(JSON.parse(refused.out).error, /'.*x\.png' is not a regular file/);
  // A directory with an image's name is refused the same way.
  fs.mkdirSync(path.join(dir, 'folder.png'));
  assert.throws(() => prepareImportArgs({ path: path.join(dir, 'folder.png') }), /is not a regular file/);

  // The pair: a regular PNG beside it goes through the same child.
  const sent = importInChild(write(dir, 'real.png', PNG));
  assert.equal(sent.timedOut, false);
  assert.deepEqual(JSON.parse(sent.out), { ok: true, media_type: 'image/png' });
});
