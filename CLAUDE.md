# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Image Asset Manager** — A macOS-primary / iPad-companion SwiftUI app for AI image generation, asset management, and consulting workflow integration. Integrates with iCloud Drive for storage, Obsidian for vault sync, and exposes a local MCP server for Claude Code. iPhone is explicitly out of scope for v1.

Full specification: Obsidian vault → `Asset Management Tool/Asset Management Tool - Specification v0.4`

## Architecture

### Repository Layout

```
image-asset-manager/
  ImageAssetManager/               ← Universal app target (macOS + iPadOS)
    App/                           ← Entry point, AppDelegate (#if os(macOS))
    Features/                      ← Generation, Library, Prompts, Collections,
                                     Variants, Spend, Refinement
    Shared/                        ← Components, Extensions, Theme
    Resources/                     ← Assets.xcassets
  Packages/
    ImageAssetManagerCore/         ← Shared Swift package (GRDB dependency here only)
      Sources/ImageAssetManagerCore/
        Database/                  ← Schema, migrations, IndexExporter
        Providers/                 ← ImageProvider protocol + NanaBananaProvider
        Models/                    ← Swift model types
        Export/                    ← ImageExporter (Core Graphics)
        Refinement/                ← PromptRefinementSession (Anthropic API)
      Tests/ImageAssetManagerCoreTests/
```

### Layer Responsibilities

- **ImageAssetManagerCore** — all business logic, data access (GRDB), provider abstraction, API clients. No SwiftUI imports.
- **ImageAssetManager app target** — SwiftUI views only; imports Core for all logic.
- **MCP server** — runs on localhost:47821 when macOS app is open; exposes read/write tools over the SQLite library. Falls back to `index.json` when app is closed.

### Storage (iCloud Drive — not CloudKit)

```
~/Library/Mobile Documents/iCloud~com~[org]~ImageAssetManager/Documents/
  assets/          ← original image files ({uuid}.png/jpg/webp)
  library.db       ← SQLite via GRDB
  index.json       ← atomic full-library export; written after every DB write
  providers.json   ← provider config + cost models (no secrets)
  prompts/         ← prompt library markdown files ({uuid}.md)
```

API keys are stored in Keychain only — never in iCloud, providers.json, or code.

### Provider Abstraction

Every image generation provider implements the `ImageProvider` protocol. Adding a new provider requires one new struct with zero changes elsewhere. `ProviderRegistry.shared` is the single source of truth — never instantiate providers directly.

### Platform Strategy

- macOS: full three-panel layout (Source Panel 220pt | Content Grid | Inspector 280pt), NSToolbar, Swift Charts, MCP server, export presets, full spend dashboard.
- iPad: two-column NavigationSplitView; scoped feature set (library, generation, prompts, collections, variants, read-only spend). No three-column layout.
- Use `#if os(macOS)` for platform-specific code. Never add iPhone layout code.

## Key Conventions

- **IDs**: UUID strings throughout (stored as `TEXT` in SQLite).
- **Dates**: ISO 8601 strings in SQLite and JSON.
- **index.json**: must be written atomically (write to temp, then replace) after every SQLite write. `IndexExporter.export(from:to:)` is the single call site.
- **Accent colour**: SwiftUI `.indigo` exclusively — no secondary accents.
- **Semantic colour tokens**: defined in `Color+App.swift`. Use `Color.appBackground`, `Color.appSurface`, `Color.imageMatte`, etc. — never raw hex in views.
- **Typography**: SF Pro throughout; `SF Mono` for all prompt text areas.
- **Exported images** are never written to `assets/` — the library holds originals only.
- **Obsidian writes**: the app never writes to Obsidian directly; Claude Code is the intermediary via the MCP server + Obsidian Local REST API.

## Build Phases

| Phase | Branch | Objective |
|-------|--------|-----------|
| 0 | — | Xcode project scaffold, GitHub repo, iCloud entitlement, GRDB |
| 1 | `feature/phase-1-foundation` | SQLite schema, GRDB setup, IndexExporter, ImageProvider protocol |
| 2 | `feature/phase-2-nano-banana` | NanaBananaProvider (first concrete provider, reference image support) |
| 3 | `feature/phase-3-generation-panel` | Generation Panel UI (macOS + iPad) |
| 4 | `feature/phase-4-library-browser` | Library browser, collections, Inspector panel |
| 5 | `feature/phase-5-prompt-library` | Prompt library with vault markdown mirror |
| 6 | `feature/phase-6-export-presets` | Export presets (Core Graphics resize, no library pollution) |
| 7 | `feature/phase-7-spend-dashboard` | Spend dashboard (Swift Charts on macOS, read-only on iPad) |
| 8 | `feature/phase-8-mcp-server` | Local MCP server on localhost:47821 |
| 9 | `feature/phase-9-visual-polish` | Aperture/Lightroom quality bar, accessibility |
| 10 | `feature/phase-10-prompt-refinement` | Claude Prompt Refinement Assistant (Anthropic API, saved history) |

### Branching Strategy

- `main` — tagged releases only
- `develop` — integration branch; all phases merge here first
- `feature/phase-N-description` — one branch per phase

```bash
# Start a phase
git checkout -b feature/phase-N-description

# Merge when complete and tested
git checkout develop && git merge feature/phase-N-description
```

## Current Status

**Phase 0 — scaffold not yet started.** The Xcode project, Swift package, and all source files remain to be created. Build commands below will work once the Xcode project exists.

## Common Commands

```bash
# Build (macOS)
xcodebuild -scheme ImageAssetManager -destination 'platform=macOS' build

# Build (iPad simulator)
xcodebuild -scheme ImageAssetManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build

# Run tests (Core package)
swift test --package-path Packages/ImageAssetManagerCore

# Run a single test
swift test --package-path Packages/ImageAssetManagerCore --filter TestSuiteName/testMethodName
```

## Phase 0 Checklist

Tasks required before Phase 1 can begin:

- [ ] Create Xcode project (`ImageAssetManager.xcodeproj`) targeting macOS 14+ and iPadOS 17+
- [ ] Add `Packages/ImageAssetManagerCore` as a local Swift package
- [ ] Configure iCloud Drive entitlement (`com.apple.developer.ubiquity-container-identifiers`)
- [ ] Add GRDB as a dependency in `ImageAssetManagerCore/Package.swift`
- [ ] Set bundle ID and iCloud container ID (resolves `[org]` placeholder below)
- [ ] Push initial scaffold to `develop`

## MCP Server Config (add to Claude Code settings after Phase 8)

Replace `[org]` with the actual reverse-DNS org segment used in the iCloud container ID.

```json
{
  "mcpServers": {
    "image-asset-manager": {
      "command": "npx",
      "args": ["image-asset-manager-mcp"],
      "env": {
        "LIBRARY_PATH": "~/Library/Mobile Documents/iCloud~com~[org]~ImageAssetManager/Documents"
      }
    }
  }
}
```
