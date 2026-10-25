/**
 * Offline fallback — reads index.json from LIBRARY_PATH.
 * Only read-only tools are supported in fallback mode.
 */

import fs from 'fs';
import path from 'path';

const OFFLINE_TOOLS = new Set([
  'search_assets',
  'get_asset',
  'list_projects',
  'search_prompts',
  'get_spend',
  'list_tags',
]);

export function isOfflineTool(name) {
  return OFFLINE_TOOLS.has(name);
}

// The v8 backfill mapping (AppDatabase.swift), for records with no media_type of their own:
// App Store 1.0.x rewrites index.json without the field.
const MEDIA_TYPES_BY_EXTENSION = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  heic: 'image/heic',
  svg: 'image/svg+xml',
};

function withMediaType(asset) {
  if (asset.media_type || typeof asset.filename !== 'string') return asset;
  const type = MEDIA_TYPES_BY_EXTENSION[path.extname(asset.filename).slice(1).toLowerCase()];
  return type ? { ...asset, media_type: type } : asset;
}

function loadIndex(libraryPath) {
  const indexPath = path.join(libraryPath, 'index.json');
  if (!fs.existsSync(indexPath)) {
    throw new Error(`index.json not found at ${indexPath}. Start the app at least once to generate it.`);
  }
  return JSON.parse(fs.readFileSync(indexPath, 'utf8')).map(withMediaType);
}

// Tools that cannot work from index.json. Checked before the index is read, so the reason given is
// the real one (the app is not running), not "index.json not found".
const APP_ONLY_MESSAGES = {
  generate: 'Generating needs the Image Asset Manager app: it holds the provider keys and writes the library. Start the app and try again.',
  generate_image: 'Generating needs the Image Asset Manager app: it holds the provider keys and writes the library. Start the app and try again.',
  list_generation_options: 'What can be generated, and at what cost, is known only to the running Image Asset Manager app (it holds the provider keys and the live model list). Start the app and try again.',
};

export function callFallbackTool(name, args, libraryPath) {
  if (Object.hasOwn(APP_ONLY_MESSAGES, name)) {
    throw new Error(`Tool '${name}' is not available in offline mode. ${APP_ONLY_MESSAGES[name]}`);
  }
  const assets = loadIndex(libraryPath);

  switch (name) {
    case 'search_assets':
      return searchAssets(assets, args);

    case 'get_asset': {
      const asset = assets.find(a => a.id === args.id);
      if (!asset) throw new Error(`Asset not found: ${args.id}`);
      return asset;
    }

    case 'list_projects': {
      // index.json holds each asset's project IDs and names, so a project with no assets, its
      // client and its description are known only to the app.
      const byID = new Map();
      for (const a of assets) {
        const ids = Array.isArray(a.projectIDs) ? a.projectIDs : (a.projectID ? [a.projectID] : []);
        ids.forEach((id, i) => {
          const entry = byID.get(id) ?? { id, name: a.projectNames?.[i] ?? null, asset_count: 0, last_used_at: null };
          entry.asset_count += 1;
          if (a.createdAt && (!entry.last_used_at || a.createdAt > entry.last_used_at)) entry.last_used_at = a.createdAt;
          byID.set(id, entry);
        });
      }
      return [...byID.values()];
    }

    case 'list_tags': {
      const counts = new Map();
      for (const a of assets) for (const t of a.tags ?? []) counts.set(t, (counts.get(t) ?? 0) + 1);
      return {
        tags: [...counts].map(([name, count]) => ({ name, count }))
          .sort((x, y) => y.count - x.count || x.name.localeCompare(y.name)),
        note: 'Offline mode — tags on no asset are known only to the app.',
      };
    }

    case 'search_prompts':
      // prompts are not in index.json — return empty with a note
      return { note: 'Prompt search requires the app to be running.', results: [] };

    case 'get_spend': {
      const filtered = assets.filter(a => {
        if (args.date_from && a.createdAt < args.date_from) return false;
        if (args.date_to && a.createdAt >= args.date_to) return false;
        return true;
      });
      const total = filtered.reduce((sum, a) => sum + (a.estimatedCost || 0), 0);
      return {
        totalEstimated: total,
        totalActual: 0,
        generationCount: filtered.length,
        avgCostPerGeneration: filtered.length > 0 ? total / filtered.length : 0,
        note: 'Offline mode — actual costs and project filters unavailable without the app.',
      };
    }

    default:
      throw new Error(`Tool '${name}' is not available in offline mode. Start the Image Asset Manager app.`);
  }
}

function searchAssets(assets, args) {
  let results = assets;

  if (args.query) {
    const q = args.query.toLowerCase();
    results = results.filter(a =>
      (a.prompt || '').toLowerCase().includes(q) ||
      (a.filename || '').toLowerCase().includes(q)
    );
  }
  if (args.tags?.length) {
    results = results.filter(a =>
      args.tags.every(t => (a.tags || []).includes(t))
    );
  }
  const projectFilters = [];
  if (args.project) projectFilters.push(args.project);
  if (Array.isArray(args.projects)) projectFilters.push(...args.projects);
  if (projectFilters.length) {
    results = results.filter(a => {
      const ids = Array.isArray(a.projectIDs) ? a.projectIDs : (a.projectID ? [a.projectID] : []);
      const names = Array.isArray(a.projectNames) ? a.projectNames : [];
      return projectFilters.some(p => ids.includes(p) || names.includes(p));
    });
  }
  if (args.provider) {
    results = results.filter(a => a.providerID === args.provider);
  }
  if (args.aspect_ratio) {
    results = results.filter(a => a.aspectRatio === args.aspect_ratio);
  }
  if (args.date_from) {
    results = results.filter(a => a.createdAt >= args.date_from);
  }
  if (args.date_to) {
    results = results.filter(a => a.createdAt < args.date_to);
  }

  const limit = args.limit ?? 50;
  return results.slice(0, limit);
}
