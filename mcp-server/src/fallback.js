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
  'list_collections',
  'get_collection',
  'search_prompts',
  'get_spend',
]);

export function isOfflineTool(name) {
  return OFFLINE_TOOLS.has(name);
}

function loadIndex(libraryPath) {
  const indexPath = path.join(libraryPath, 'index.json');
  if (!fs.existsSync(indexPath)) {
    throw new Error(`index.json not found at ${indexPath}. Start the app at least once to generate it.`);
  }
  return JSON.parse(fs.readFileSync(indexPath, 'utf8'));
}

export function callFallbackTool(name, args, libraryPath) {
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
      const seen = new Set();
      const projects = [];
      for (const a of assets) {
        if (a.projectID && !seen.has(a.projectID)) {
          seen.add(a.projectID);
          projects.push({ id: a.projectID });
        }
      }
      return projects;
    }

    case 'list_collections': {
      const seen = new Set();
      const cols = [];
      for (const a of assets) {
        if (a.collectionID && !seen.has(a.collectionID)) {
          if (!args.project_id || a.projectID === args.project_id) {
            seen.add(a.collectionID);
            cols.push({ id: a.collectionID, projectID: a.projectID });
          }
        }
      }
      return cols;
    }

    case 'get_collection': {
      const matching = assets.filter(a => a.collectionID === args.id);
      return { id: args.id, assets: matching };
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
