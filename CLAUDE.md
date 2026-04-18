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
      App/                              ← ImageAssetManagerApp, AppEnvironment,
                                          MCPServer (Swift NWListener, macOS only)
      Features/                         ← Generation, Library, Prompts, Export,
                                          Spend, Settings, ContentView
      Shared/                           ← Components, Extensions, Theme
      Resources/                        ← Assets.xcassets
      ImageAssetManagerCore/            ← Embedded Swift package (NOT in a top-level Packages/)
        Sources/ImageAssetManagerCore/
          Database/                     ← AppDatabase + per-feature query extensions,
                                          LibrarySetup, migrations
          Providers/                    ← ImageProvider protocol, NanaBananaProvider,
                                          ProviderRegistry, ProviderError
          Models/                       ← Swift model types (GRDB-conformant)
          Export/                       ← IndexExporter (atomic JSON export)
          Security/                     ← KeychainService
        Tests/ImageAssetManagerCoreTests/
    ImageAssetManagerTests/             ← App-level tests
  mcp-server/                           ← Node.js MCP proxy (repo root, not in Xcode project)
    src/                                ← index.js, appClient.js, fallback.js, tools.js
```

## Architecture

### Layer Responsibilities

- **ImageAssetManagerCore** — all business logic, data access (GRDB), provider abstraction, API clients. No SwiftUI imports. Swift 6 language mode; use `Sendable`, actors, and `async/await` throughout.
- **ImageAssetManager app target** — SwiftUI views only; imports Core for all logic. `AppEnvironment` (`@Observable`, in `App/AppEnvironment.swift`) is the single source of truth — created once in `ImageAssetManagerApp.swift` and injected via `.environment(env)` into both the main `WindowGroup` and the macOS `Settings` scene.
- **MCP server** — two-tier setup:
  - **Swift HTTP server** (`App/MCPServer.swift`, macOS only) — `NWListener` on `127.0.0.1:47821`, started from `ImageAssetManagerApp.startMCPServer()` when the app launches. Holds direct `AppDatabase` access via `AppDatabase+MCPQueries.swift`.
  - **Node.js proxy** (`mcp-server/` at repo root) — what Claude Code actually connects to. Forwards every tool call to the Swift server when running; when the app is closed, read-only tools fall back to reading `index.json` via `mcp-server/src/fallback.js`. Write tools return an error.

### Storage

Library location is **user-configurable** as of Phase 11. `AppEnvironment.resolveLibraryURL()` resolves in this order:
1. Security-scoped bookmark persisted in `UserDefaults` (`libraryLocationBookmark`).
2. Non-sandbox URL string fallback.
3. Default iCloud container: `iCloud.Ionic.ImageAssetManager` → `Documents/`.
4. Final fallback: `~/Library/Application Support/ImageAssetManager/`.

Layout inside the container (created by `LibrarySetup.initialise(at:)`):

```
<library-root>/
  assets/          ← original image files ({uuid}.png/jpg/webp)
  library.db       ← SQLite via GRDB (WAL journal mode)
  index.json       ← atomic full-library export; written after every DB write
  providers.json   ← provider config + cost models (no secrets)
  prompts/         ← prompt library markdown files ({uuid}.md)
```

API keys are stored in Keychain only — never in iCloud, providers.json, or code.

### Database

`AppDatabase` (`Database/AppDatabase.swift`) is a `final class: Sendable` wrapping GRDB's `DatabaseQueue` in WAL mode. Schema is managed via `DatabaseMigrator`; migrations are **append-only** — never edit an existing one. Current migrations:

- `v1_initial_schema`
- `v2_export_presets`
- `v3_asset_hidden_column`

Query logic is split by feature into extension files — add new queries in the matching extension rather than the core file:

- `AppDatabase+Queries.swift` — general-purpose asset/project/collection CRUD
- `AppDatabase+LibraryQueries.swift` — library browser lookups
- `AppDatabase+PromptQueries.swift` — prompt library
- `AppDatabase+ExportQueries.swift` — export presets
- `AppDatabase+SpendQueries.swift` — spend dashboard aggregates
- `AppDatabase+RefinementQueries.swift` — Claude prompt refinement history
- `AppDatabase+MCPQueries.swift` — shapes reads for the MCP server

`AppDatabase.checkpoint()` flushes the WAL into the main `.db` file and **must be called before moving or copying the library** (see `AppEnvironment.changeLibraryLocation`). It uses `barrierWriteWithoutTransaction` so it can't run inside a transaction.

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

Two service names are currently in use in the codebase — this is drift, not by design. Unify to one (`com.Ionic.ImageAssetManager`) when making the next change that touches either call site.

| Key | Service (as used today) | Account |
|---|---|---|
| Nano Banana API key | `com.Ionic.ImageAssetManager` (`NanaBananaProvider.keychainService`) | `nano_banana_api_key` |
| Anthropic API key | `com.yourapp.imageassetmanager` (`SettingsView.service`) | `anthropic_api_key` |

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
| MCP Server | Swift `NWListener` HTTP server (macOS only) + Node.js proxy (`mcp-server/`) |
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

## Branching Strategy

- `main` — tagged releases only
- `develop` — integration branch; all phases merge here first
- `feature/phase-N-description` — one branch per phase

```bash
# Start a phase
git checkout develop && git checkout -b feature/phase-N-description

# Merge when complete and tested
git checkout develop && git merge feature/phase-N-description
```

## MCP Server Config

Register the Node.js proxy in Claude Code (point `command`/`args` at the local checkout; see `mcp-server/README.md` for the full walkthrough):

```json
{
  "mcpServers": {
    "image-asset-manager": {
      "command": "node",
      "args": ["/absolute/path/to/Image-asset-manager/mcp-server/src/index.js"],
      "env": {
        "LIBRARY_PATH": "~/Library/Mobile Documents/iCloud~Ionic~ImageAssetManager/Documents"
      }
    }
  }
}
```

`LIBRARY_PATH` is only used in offline fallback mode (reads `index.json` directly). When the macOS app is running, every tool call is forwarded to `http://127.0.0.1:47821` regardless of `LIBRARY_PATH`. Smoke test with `curl http://localhost:47821/health` → `{"status":"ok"}`.
