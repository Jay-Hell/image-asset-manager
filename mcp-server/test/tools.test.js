// Tool definitions: descriptions teach no model names and no prices (spec v0.3 T21), and the
// names here match the names the Swift server dispatches on.
// Run: node --test mcp-server/test/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { TOOLS } from '../src/tools.js';

// Model and vendor names an agent must learn from list_generation_options, not from a description,
// so that renaming a model never leaves a stale claim in a tool's text.
const MODEL_NAMES = /gemini|imagen|nano[ _-]?banana|banana|flux|recraft|gpt|dall-?e|midjourney|stable[ -]?diffusion|openai|google|anthropic|claude|sonnet|black[ -]forest/i;
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

test('every tool here is dispatched by the Swift server, and every Swift case is a tool here', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const swift = fs.readFileSync(
    path.join(here, '../../ImageAssetManager/ImageAssetManager/App/MCPServer.swift'), 'utf8');
  const body = swift.slice(swift.indexOf('func callTool'));
  const cases = [...body.matchAll(/^\s*case ((?:"[a-z_]+"(?:,\s*)?)+):/gm)]
    .flatMap(m => [...m[1].matchAll(/"([a-z_]+)"/g)].map(x => x[1]));
  assert.ok(cases.length >= 10, `read only ${cases.length} cases from MCPServer.swift`);
  assert.deepEqual([...new Set(cases)].sort(), TOOLS.map(t => t.name).sort());
});
