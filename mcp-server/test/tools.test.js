// Tool definitions: descriptions teach no model names and no prices (spec v0.3 T21), and the
// names here match the names the Swift server dispatches on.
// Run: node --test mcp-server/test/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { TOOLS } from '../src/tools.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const readRepo = rel => fs.readFileSync(path.join(here, '../..', rel), 'utf8');

// Model and vendor names an agent must learn from list_generation_options, not from a description,
// so that renaming a model never leaves a stale claim in a tool's text. The list is built from what
// the app can actually reach, never typed in: the catalogue's model IDs and display names (live and
// retired), and the recorded OpenRouter list's vendors and model families. A new model in either
// file is a new banned word.
const GENERIC_WORDS = new Set([
  // Words in a model's name that say what it is, not who made it; tool text may use them.
  'image', 'images', 'flash', 'lite', 'fast', 'draft', 'standard', 'final', 'generate', 'ultra', 'pro',
  'preview', 'turbo', 'vector', 'mini', 'large', 'small', 'max', 'plus',
]);

export function bannedNames() {
  const catalogue = JSON.parse(readRepo('catalogue/v1/models.json'));
  const live = JSON.parse(readRepo(
    'ImageAssetManager/ImageAssetManager/ImageAssetManagerCore/Tests/Fixtures/openrouter/images_models.json'));
  const tiers = new Set(Object.values(catalogue.media).flatMap(m => Object.keys(m.tiers ?? {})));
  const names = new Set();
  const addTokens = text => {
    for (const token of text.toLowerCase().split(/[^a-z]+/)) {
      if (token.length >= 3 && !GENERIC_WORDS.has(token) && !tiers.has(token)) names.add(token);
    }
  };
  const models = Object.values(catalogue.models).flat();
  for (const m of [...models, ...catalogue.retired]) { addTokens(m.id); addTokens(m.displayName ?? ''); }
  for (const m of live.data) {
    const [vendor, rest] = m.id.split('/');
    names.add(vendor.toLowerCase());                              // "black-forest-labs", "x-ai"
    names.add(m.name.split(':')[0].trim().toLowerCase());          // "Black Forest Labs", "xAI"
    addTokens(rest.split(/[-._]/)[0]);                             // the family: "flux", "seedream", "gpt"
  }
  names.delete('');
  return [...names];
}

const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
/** A whole-word, case-insensitive match for any of the names; a space, dash or underscore inside one matches any of them. */
export function namesPattern(names) {
  const parts = names.map(n => escape(n).replace(/(?:\\?[ _-])+/g, '[ _-]?'));
  return new RegExp(`(?<![a-z0-9])(?:${parts.join('|')})(?![a-z0-9])`, 'i');
}
const MODEL_NAMES = namesPattern(bannedNames());
// A price: a currency symbol, a currency word with an amount, or a decimal amount.
const PRICES = /[£$€]|\b\d+\.\d{2,}\b|\bGBP\s*\d|\b\d+(\.\d+)?\s*(GBP|USD|pence|cents)\b/i;

/** Every string in a tool definition that a model reads: the description and every property description. */
function descriptions(value, out = []) {
  if (Array.isArray(value)) {
    value.forEach(v => descriptions(v, out));
  } else if (value && typeof value === 'object') {
    for (const [key, v] of Object.entries(value)) {
      if (key === 'description' && typeof v === 'string') out.push(v);
      else descriptions(v, out);
    }
  }
  return out;
}

/** The descriptions that break the rule, with why. */
export function findForbidden(tools) {
  const found = [];
  for (const tool of tools) {
    for (const text of [tool.description, ...descriptions(tool.inputSchema)]) {
      if (MODEL_NAMES.test(text)) found.push(`${tool.name}: names a model or vendor: ${text.match(MODEL_NAMES)[0]}`);
      if (PRICES.test(text)) found.push(`${tool.name}: states a price: ${text.match(PRICES)[0]}`);
    }
  }
  return found;
}

test('T21: no tool description names a model or states a price', () => {
  assert.deepEqual(findForbidden(TOOLS), []);
});

test('T21: the check itself flags a model name and a price (the pair that must flip)', () => {
  const planted = TOOLS.map(t => t.name === 'generate'
    ? { ...t, description: `${t.description} Pro uses Gemini at about £0.05.` }
    : t);
  const found = findForbidden(planted);
  assert.equal(found.length, 2);
  assert.match(found[0], /generate: names a model or vendor: Gemini/);
  assert.match(found[1], /generate: states a price: £/);
  // And in a property description, not only the tool's own.
  const nested = [{ name: 'x', description: 'ok', inputSchema: { properties: { q: { description: 'costs $2' } } } }];
  assert.equal(findForbidden(nested).length, 1);
});

test('T21: the banned names come from the catalogue and the OpenRouter list, so a new model is caught', () => {
  const names = bannedNames();
  // From the catalogue (live and retired models) and from the recorded OpenRouter list.
  for (const expected of ['gemini', 'imagen', 'banana', 'recraft', 'flux', 'seedream', 'qwen', 'black-forest-labs', 'openai', 'google']) {
    assert.ok(names.includes(expected), `${expected} should be derived`);
  }
  // None of these was in the hand-typed list this replaces: only the files know them.
  const plant = word => findForbidden([{ name: 'x', description: `Uses ${word} for this.`, inputSchema: {} }]);
  for (const word of ['Seedream', 'Qwen', 'Krea', 'Riverflow', 'Grok', 'Sourceful']) {
    assert.equal(plant(word).length, 1, `${word} should be flagged`);
  }
  // The pair that must hold: ordinary words, and the tier names, are not names.
  assert.deepEqual(plant('a fast, standard or pro tier'), []);
  // A name added to the catalogue becomes banned: the pattern is built from the list it is given.
  const grown = namesPattern([...names, 'zorblax']);
  assert.ok(grown.test('made with Zorblax'));
  assert.ok(!MODEL_NAMES.test('made with Zorblax'));
});

test('the generation tools are defined, and generate_image stays as the alias', () => {
  const names = TOOLS.map(t => t.name);
  for (const name of ['generate', 'list_generation_options', 'generate_image']) {
    assert.ok(names.includes(name), `${name} missing`);
  }
  assert.equal(new Set(names).size, names.length, 'duplicate tool name');
  const generate = TOOLS.find(t => t.name === 'generate').inputSchema.properties;
  for (const field of ['media', 'quality', 'require', 'model', 'aspect_ratio', 'resolution', 'max_cost_gbp']) {
    assert.ok(field in generate, `generate.${field} missing`);
  }
  assert.deepEqual(generate.media.enum, ['image', 'vector', 'video', 'audio']);
  assert.ok('include_all' in TOOLS.find(t => t.name === 'list_generation_options').inputSchema.properties);
});

/** The keys read as `args["…"]` in a stretch of Swift source. */
function argKeys(source) {
  return [...new Set([...source.matchAll(/\bargs\["([a-z_]+)"\]/g)].map(m => m[1]))].sort();
}

test('the generation schemas and the Swift GenerateTools dispatch agree on tool names and fields', () => {
  const swift = readRepo('ImageAssetManager/ImageAssetManager/ImageAssetManagerCore/Sources/ImageAssetManagerCore/Generation/GenerateTools.swift');
  // Tool names: the toolNames set, the call switch and the schema all say the same three.
  const declared = [...swift.match(/static let toolNames: Set<String> = \[([^\]]*)\]/)[1].matchAll(/"([a-z_]+)"/g)].map(m => m[1]).sort();
  const dispatched = [...swift.slice(swift.indexOf('public func call('), swift.indexOf('// MARK: - generate'))
    .matchAll(/case "([a-z_]+)":/g)].map(m => m[1]).sort();
  const schemas = ['generate', 'generate_image', 'list_generation_options'];
  assert.deepEqual(declared, [...schemas].sort());
  assert.deepEqual(dispatched, [...schemas].sort());
  for (const name of schemas) assert.ok(TOOLS.some(t => t.name === name), `${name} has no schema`);

  // Fields: what Swift reads from `args` is exactly what the schema offers, per tool.
  const listStart = swift.indexOf('private func listOptions');
  const listEnd = swift.indexOf('private static let providerRows');
  assert.ok(listStart > 0 && listEnd > listStart, 'could not find listOptions in GenerateTools.swift');
  const listKeys = argKeys(swift.slice(listStart, listEnd));
  const generateKeys = argKeys(swift.slice(0, listStart) + swift.slice(listEnd));
  const props = name => Object.keys(TOOLS.find(t => t.name === name).inputSchema.properties).sort();
  assert.ok(generateKeys.length >= 16, `read only ${generateKeys.length} generate fields`);
  assert.deepEqual(props('generate'), generateKeys);
  assert.deepEqual(props('list_generation_options'), listKeys);
  // The alias offers the same fields, less `media`, which it forces.
  assert.deepEqual(props('generate_image'), generateKeys.filter(k => k !== 'media'));

  // Reference items: the keys Swift reads from each (`item["…"]`) are the keys the schema lists.
  const itemKeys = [...new Set([...swift.matchAll(/\bitem\["([a-z_]+)"\]/g)].map(m => m[1]))].sort();
  const refItems = TOOLS.find(t => t.name === 'generate').inputSchema.properties.references.items.properties;
  assert.deepEqual(Object.keys(refItems).sort(), itemKeys);
});

test('every tool here is dispatched by the Swift server, and every Swift case is a tool here', () => {
  const swift = fs.readFileSync(
    path.join(here, '../../ImageAssetManager/ImageAssetManager/App/MCPServer.swift'), 'utf8');
  const body = swift.slice(swift.indexOf('func callTool'));
  const cases = [...body.matchAll(/^\s*case ((?:"[a-z_]+"(?:,\s*)?)+):/gm)]
    .flatMap(m => [...m[1].matchAll(/"([a-z_]+)"/g)].map(x => x[1]));
  assert.ok(cases.length >= 10, `read only ${cases.length} cases from MCPServer.swift`);
  assert.deepEqual([...new Set(cases)].sort(), TOOLS.map(t => t.name).sort());
});
