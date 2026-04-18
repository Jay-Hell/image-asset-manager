# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Image Asset Manager** — A macOS-primary / iPad-companion SwiftUI app for AI image generation, asset management, and consulting workflow integration. Integrates with iCloud Drive for storage, Obsidian for vault sync, and exposes a local MCP server for Claude Code. iPhone is explicitly out of scope for v1.

Full specification: Obsidian vault → `Asset Management Tool/Asset Management Tool - Specification v0.4`

## Repository Layout

```
image-asset-manager/
  ImageAssetManager/
    ImageAssetManager.xcodeproj/        ← Xcode project
    ImageAssetManager/                  ← Universal app target (macOS + iPadOS)
      App/                              ← Entry point, AppDelegate (#if os(macOS))
      Features/                         ← Generation, Library, Prompts, Collections,
                                          Variants, Spend, Refinement
      Shared/                           ← Components, Extensions, Theme
      Resources/                        ← Assets.xcassets
      ImageAssetManagerCore/            ← Embedded Swift package (NOT in a top-level Packages/)
        Sources/ImageAssetManagerCore/
          Database/                     ← AppDatabase (GRDB), LibrarySetup, migrations
          Providers/                    ← ImageProvider protocol, NanaBananaProvider,
                                          ProviderRegistry, ProviderError
          Models/                       ← Swift model types (GRDB-conformant)
          Export/                       ← IndexExporter (atomic JSON export)
          Security/                     ← KeychainService
        Tests/ImageAssetManagerCoreTests/
    ImageAssetManagerTests/             ← App-level tests
```

## Architecture

### Layer Responsibilities

- **ImageAssetManagerCore** — all business logic, data access (GRDB), provider abstraction, API clients. No SwiftUI imports. Swift 6 language mode; use `Sendable`, actors, and `async/await` throughout.
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

### Database

`AppDatabase` is a `final class: Sendable` wrapping GRDB's `DatabaseQueue`. Schema is managed via `DatabaseMigrator` (currently one migration: `v1_initial_schema`). Add future schema changes as new named migrations — never modify `v1_initial_schema`.

`IndexExporter.export(from:to:assetsBaseURL:)` is the single call site for writing `index.json`. It writes atomically via a `.tmp` file + `FileManager.replaceItemAt`. Call it after every DB write.

### Provider Abstraction

Every provider implements `ImageProvider: Sendable`. Adding a provider requires one new struct; zero changes elsewhere. `ProviderRegistry` is an actor — always access providers through it, never instantiate directly.

`GenerationParams.additionalParams` is `[String: Any]` (marked `@unchecked Sendable`) for provider-specific knobs. `ReferenceInput` carries base64 image data, role (`styleAnchor`/`subjectAnchor`), and optional weight.

### Platform Strategy

- macOS: full three-panel layout (Source Panel 220pt | Content Grid | Inspector 280pt), NSToolbar, Swift Charts, MCP server, export presets, full spend dashboard.
- iPad: two-column `NavigationSplitView`; scoped feature set (library, generation, prompts, collections, variants, read-only spend).
- Use `#if os(macOS)` for platform-specific code. Never add iPhone layout code.

## Key Conventions

- **IDs**: UUID strings throughout (stored as `TEXT` in SQLite).
- **Dates**: ISO 8601 strings in SQLite and JSON.
- **index.json**: written atomically after every SQLite write via `IndexExporter`.
- **Accent colour**: SwiftUI `.indigo` exclusively — no secondary accents.
- **Typography**: SF Pro throughout; `SF Mono` for all prompt text areas.
- **Exported images** are never written to `assets/` — the library holds originals only.
- **Obsidian writes**: the app never writes to Obsidian directly; Claude Code is the intermediary via the MCP server + Obsidian Local REST API.
- **Testing**: uses Swift Testing (`@Test`, `#expect`) — not XCTest.

### Semantic Colour Tokens (`Color+App.swift`)

Never use raw hex in views — always use these tokens:

| Token | Dark | Light |
|---|---|---|
| `Color.appBackground` | `#1C1C1E` | `#F2F2F7` |
| `Color.appSurface` | `#2C2C2E` | `#FFFFFF` |
| `Color.appSurfaceRaised` | `#3A3A3C` | `#F2F2F7` |
| `Color.appBorder` | `#48484A` | `#C6C6C8` |
| `Color.appTextPrimary` | `#FFFFFF` | `#000000` |
| `Color.appTextSecondary` | `#8E8E93` | `#8E8E93` |
| `Color.appAccent` | `.indigo` (system) | `.indigo` (system) |
| `Color.imageMatte` | `#141414` | `#E5E5EA` |

Images are always displayed against `Color.imageMatte` — never on white or coloured backgrounds.

### Component Standards

- **Thumbnail grid**: adaptive columns, min 160pt cell width, 4pt gap; no labels below thumbnails by default
- **Thumbnail selection**: 2pt indigo ring, no fill overlay
- **Provider chip**: 10pt SF Pro Medium, `appSurface` bg, 6pt padding, 4pt corner radius, top-left with 6pt inset
- **Variant filmstrip**: horizontal scroll row, 80pt thumbnail height, sequence numbers
- **Panels**: 1pt `appBorder` divider; header labels 11pt SF Pro Medium `appTextSecondary` uppercase; collapse animation 200ms
- **Action buttons**: 28pt height macOS / 44pt iPad; secondary style except primary action (indigo filled)

### Keychain Identifiers

Service name: `com.yourapp.imageassetmanager`

| Key | Account |
|---|---|
| Nano Banana API key | `nano_banana_api_key` |
| Anthropic API key | `anthropic_api_key` |

### Technology Stack

| Layer | Technology |
|---|---|
| Language | Swift 6.0 (strict concurrency) |
| UI | SwiftUI — macOS primary, iPad companion |
| Database | SQLite via GRDB 7.x |
| Keychain | Swift Security framework |
| iCloud Sync | iCloud Drive via FileManager |
| Charts | Swift Charts (macOS only in v1) |
| Image Processing | Core Graphics |
| MCP Server | Swift MCP SDK or lightweight Node.js (macOS only) |
| Provider API | URLSession async/await |
| Anthropic API | URLSession async/await (prompt refinement) |
| Testing | Swift Testing (`@Test`, `#expect`) |

## Common Commands

```bash
# Build (macOS)
xcodebuild -project ImageAssetManager/ImageAssetManager.xcodeproj \
  -scheme ImageAssetManager -destination 'platform=macOS' build

# Build (iPad simulator)
xcodebuild -project ImageAssetManager/ImageAssetManager.xcodeproj \
  -scheme ImageAssetManager \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build

# Run all Core package tests
swift test --package-path ImageAssetManager/ImageAssetManager/ImageAssetManagerCore

# Run a single test
swift test --package-path ImageAssetManager/ImageAssetManager/ImageAssetManagerCore \
  --filter TestSuiteName/testMethodName
```

## Build Phases

| Phase | Branch | Status | Objective |
|-------|--------|--------|-----------|
| 0 | `develop` | ✓ Done | Xcode project scaffold, iCloud entitlement, GRDB, full schema, IndexExporter, ImageProvider protocol, NanaBananaProvider |
| 1 | `feature/phase-1-foundation` | — | (merged into Phase 0 on develop) |
| 2 | `feature/phase-2-nano-banana` | — | (merged into Phase 0 on develop) |
| 3 | `feature/phase-3-generation-panel` | Next | Generation Panel UI (macOS + iPad) |
| 4 | `feature/phase-4-library-browser` | — | Library browser, collections, Inspector panel |
| 5 | `feature/phase-5-prompt-library` | — | Prompt library with vault markdown mirror |
| 6 | `feature/phase-6-export-presets` | — | Export presets (Core Graphics resize, no library pollution) |
| 7 | `feature/phase-7-spend-dashboard` | — | Spend dashboard (Swift Charts on macOS, read-only on iPad) |
| 8 | `feature/phase-8-mcp-server` | — | Local MCP server on localhost:47821 |
| 9 | `feature/phase-9-visual-polish` | — | Aperture/Lightroom quality bar, accessibility |
| 10 | `feature/phase-10-prompt-refinement` | — | Claude Prompt Refinement Assistant (Anthropic API, saved history) |
| 11 | `feature/phase-11-library-refinements` | — | Configurable library location, import move/copy, multi-select hide/delete, generate from prompt |

### Branching Strategy

- `main` — tagged releases only
- `develop` — integration branch; all phases merge here first
- `feature/phase-N-description` — one branch per phase

```bash
# Start a phase
git checkout develop && git checkout -b feature/phase-N-description

# Merge when complete and tested
git checkout develop && git merge feature/phase-N-description
```

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
