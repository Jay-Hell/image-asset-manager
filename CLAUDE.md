# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Image Asset Manager** — A macOS-primary / iPad-companion SwiftUI app for AI image generation, asset management, and consulting workflow integration. Integrates with iCloud Drive for storage, Obsidian for vault sync, and exposes a local MCP server for Claude Code. iPhone is explicitly out of scope for v1.

Full specification: `/Users/johnlivingston/IonicConsulting/Asset Management Tool/Asset Management Tool - Specification v0.6.md` (working revision). Previous: `v0.5.md` → `v0.4.md`.

## Repository Layout

```
image-asset-manager/
  ImageAssetManager/
    ImageAssetManager.xcodeproj/        ← Xcode project
    ImageAssetManager/                  ← Universal app target (macOS + iPadOS)
      App/                              ← ImageAssetManagerApp, AppEnvironment,
                                          MCPServer (NWListener, macOS only),
                                          MCPServer+Generate (generate_image handler)
      Features/                         ← Generation, Library, Prompts, Export,
                                          Spend, Settings, ContentView
      Shared/                           ← Components (KeychainKeyEditor, LocalImage),
                                          Theme
      Resources/                        ← Assets.xcassets
      ImageAssetManagerCore/            ← Embedded Swift package (NOT in a top-level Packages/)
        Sources/ImageAssetManagerCore/
          Currency.swift                ← USD→GBP conversion (single source of truth)
          DataHash.swift                ← Data.sha256 extension
          Database/                     ← AppDatabase + per-feature query extensions,
                                          LibrarySetup, migrations, Resolvers
          Generation/                   ← GenerationService (actor), GenerationPolicy
                                          (budget/routing), PromptFlattener
          Library/                      ← LibraryMigrationService (actor), ImportNaming
          Providers/                    ← ImageProvider protocol, NanaBananaProvider
                                          (4-model catalogue), ProviderRegistry,
                                          ProviderError
          Network/                      ← AnthropicClient (URLSession)
          Refinement/                   ← PromptRefinementSession
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
- **ImageAssetManager app target** — SwiftUI views only; imports Core for all logic. `AppEnvironment` (`@Observable`, in `App/AppEnvironment.swift`) is the single source of truth — created once in `ImageAssetManagerApp.swift` and injected via `.environment(env)` into both the main `WindowGroup` and the macOS `Settings` scene. Holds a `libraryRevision: Int` counter that view-models watch via `.task(id: env.libraryRevision)` to force a rebuild after destructive operations (library location change, clear library).
- **MCP server** — two-tier setup:
  - **Swift HTTP server** (`App/MCPServer.swift` + `App/MCPServer+Generate.swift`, macOS only) — `NWListener` on `127.0.0.1:47821`, started from `ImageAssetManagerApp.startMCPServer()` when the app launches. Reads via `AppDatabase+MCPQueries.swift`, writes via `GenerationService` for image generation. `database` and `libraryURL` are internal (not private) so extension files can see them.
  - **Node.js proxy** (`mcp-server/` at repo root) — what Claude Code actually connects to. Forwards every tool call to the Swift server when running; when the app is closed, read-only tools fall back to reading `index.json` via `mcp-server/src/fallback.js`. Write tools (`generate_image`, `mark_asset_used`, prompt tools) return a "requires the app to be running" error.

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

**Sandbox entitlements** (`ImageAssetManager.entitlements`) — all four are required, don't remove any:

- `com.apple.security.files.user-selected.read-write` — pick a library location via `NSOpenPanel` and retain access via the security-scoped bookmark.
- `com.apple.security.network.client` — outbound HTTPS to Google AI Studio and api.anthropic.com. Without this, every URLSession call returns the misleading `NSURLErrorCannotFindHost` ("server not found").
- `com.apple.security.network.server` — bind the MCP `NWListener` on loopback. Without this, `NWListener(using:)` fails silently and `curl localhost:47821/health` can't connect.
- iCloud container entitlements (`iCloud.Ionic.ImageAssetManager`) — default library location.

### Import File Naming

`ImportNaming` (`Library/ImportNaming.swift`) is the enum the import flow uses to derive stored filenames inside `assets/`:

- `preserveOriginal` — keep the source stem; append `_N` on collision.
- `prependDate` — `YYYY-MM-DD_{stem}.{ext}`; append `_N` on collision.
- `dateAndIndex` — `YYYY-MM-DD_NNN.{ext}` (zero-padded 3-digit index per import batch).

All strategies dedupe via an in-flight `usedFilenames: Set<String>` passed by reference so one batch import produces unique names without hitting the disk repeatedly. The last-used strategy is persisted in `UserDefaults`.

### Database

`AppDatabase` (`Database/AppDatabase.swift`) is a `final class: Sendable` wrapping GRDB's `DatabaseQueue` in WAL mode. Schema is managed via `DatabaseMigrator`; migrations are **append-only** — never edit an existing one. Current migrations:

- `v1_initial_schema`
- `v2_export_presets`
- `v3_asset_hidden_column`
- `v4_variants_nullable_project_and_backfill` — makes `variants.project_id` nullable (orphan assets can now have families) and backfills a solo variant family for every existing asset. Enforces the invariant: **every asset belongs to a variant family of at least one member.** Live creation paths (in-app generation, MCP `generate_image`, import) all funnel through `AppDatabase.attachToVariantFamily(...)` which derives a default family name from the prompt (preferred) or filename when the caller passes no explicit name. `fetchVariantFamilies` filters to families with >1 member, so singletons are invisible bookkeeping — they surface only once a sibling is added.
- `v5_clients_table_and_project_client_id` — `clients(id, name UNIQUE, created_at)`, plus `projects.client_id` FK (`ON DELETE RESTRICT`). Backfills a Client per distinct non-empty `projects.client_name`. `client_name` column is retained but deprecated; new code reads via `projects.client_id`. Managed in Settings (`ClientsSettingsSection` / `ProjectsSettingsSection`).
- `v6_asset_projects_join_and_backfill` — `asset_projects(asset_id, project_id, is_primary)` composite-key join. Backfills one primary row per existing `assets.project_id`. **`assets.project_id` is kept as a transitional "primary project" mirror** (first entry of the asset's project set). `searchAssets(projectIDs:)` filters via the join table; `setProjectsForAsset(...)` replaces an asset's set and updates the mirror. MCP `search_assets` and `generate_image` accept both a singular `project` string (shorthand) and a `projects` array — caller's first entry is the primary. `IndexExporter` emits both `project_id` (primary) and `project_ids` / `project_names` arrays so the Node fallback can filter offline.

Query logic is split by feature into extension files — add new queries in the matching extension rather than the core file:

- `AppDatabase+Queries.swift` — general-purpose asset/project/collection CRUD
- `AppDatabase+LibraryQueries.swift` — library browser lookups
- `AppDatabase+PromptQueries.swift` — prompt library
- `AppDatabase+ExportQueries.swift` — export presets
- `AppDatabase+SpendQueries.swift` — spend dashboard aggregates
- `AppDatabase+RefinementQueries.swift` — Claude prompt refinement history
- `AppDatabase+MCPQueries.swift` — shapes reads for the MCP server
- `AppDatabase+Resolvers.swift` — `findProject(idOrName:)` / `findCollection(idOrName:projectID:)` for the name-or-UUID input accepted by `generate_image`

`AppDatabase.checkpoint()` flushes the WAL into the main `.db` file and **must be called before moving or copying the library** (see `AppEnvironment.changeLibraryLocation`). It uses `barrierWriteWithoutTransaction` so it can't run inside a transaction.

`AppDatabase.clearAllData()` wipes all user tables in FK-safe order but **preserves `providers` and `export_presets`** (seed/configuration data). Drives the Settings → Danger Zone → Clear Library action via `AppEnvironment.clearLibrary(deleteFiles:)`.

`IndexExporter.export(from:to:assetsBaseURL:)` is the single call site for writing `index.json`. It writes atomically via a `.tmp` file + `FileManager.replaceItemAt`. Call it after every DB write.

### Library Migration

`LibraryMigrationService` (`Library/LibraryMigrationService.swift`, actor) owns the change-library-location flow. Important behaviours:

- **Uses `copyItem` for both move and copy modes**, then `removeItem` on the source for move. Doing it this way (rather than `moveItem`) works reliably across volume boundaries and triggers iCloud downloads on demand.
- Runs a **write-access preflight** (writes and deletes a probe file at the destination) before touching any library file; throws `MigrationError.destinationNotWritable` if that fails.
- Migrates the full set: `library.db`, `library.db-shm`, `library.db-wal`, `index.json`, `providers.json`, `assets/`, `prompts/`. The WAL sidecars must be included even though `checkpoint()` was called — SQLite can recreate them before the migration runs.
- Caller must `AppDatabase.checkpoint()` first and re-initialise `AppDatabase` against the new path afterwards (handled by `AppEnvironment.changeLibraryLocation`).

### Provider Abstraction

Every provider implements `ImageProvider: Sendable`. Adding a provider requires one new struct; zero changes elsewhere. `ProviderRegistry` is an actor — always access providers through it, never instantiate directly.

`GenerationParams.additionalParams` is `[String: Any]` (marked `@unchecked Sendable`) for provider-specific knobs. `ReferenceInput` carries base64 image data, role (`styleAnchor`/`subjectAnchor`), and optional weight.

`NanaBananaProvider` exposes **four model tiers** across two Google endpoints (`:predict` for Imagen 4, `:generateContent` for Gemini), dispatched internally by model ID prefix. All IDs live in `NanaBananaProvider.ModelID` so the October 2026 Gemini deprecation bump touches one place:

| `ModelID` constant | Endpoint | Refs |
|---|---|---|
| `imagenFast` / `imagenStandard` / `imagenUltra` | `:predict` | No (Imagen 4 on this API is text-only) |
| `geminiWithRefs` | `:generateContent` | Yes (up to 3 via `inlineData` parts) |

Only `supportsReferences(modelID:)` returns true for `geminiWithRefs` — Imagen tiers are text-only, so the negative prompt is inlined as `"\n\nAvoid: {negative}"` rather than sent as a separate parameter.

### Generation Pipeline

`GenerationService` (`Generation/GenerationService.swift`, actor) owns the write pipeline: provider call → disk write → Asset/SpendLog/tags/refs/variant DB rows → `index.json` export. Shared by the MCP `generate_image` tool today and (planned) the in-app `GenerationViewModel.confirmGeneration()` to eliminate code drift.

Policy decisions are pulled out into `GenerationPolicy` (pure, testable, no DB/IO dependencies):

- `checkBudget(count:unitCost:limits:)` — throws `BudgetViolation` when either the image count or the projected cost exceeds the limits. Defaults: 20 images / £2.50.
- `mergeReferences(project:explicit:maxReferences:)` — combines project active refs with explicit asset IDs, caps at 3 (provider max), project refs take precedence when over-cap.
- `chooseModel(quality:hasReferences:)` — maps `"fast"`/`"standard"`/`"pro"`/`"with_references"`/`"auto"` + ref-presence to a concrete model ID, flagging `autoRouted: true` when the caller's pick can't use refs and we fall back to Gemini.

`PromptFlattener` accepts either a plain string or `[String: Any]` and emits Subject-Context-Style-ordered prose. Canonical keys (`subject`, `context`, `action`, `setting`, `style`, `composition`, `lighting`, `mood`, `camera`, `palette`, `details`, `extra`) are emitted in order; arbitrary keys are flattened with title-cased labels; non-prompt keys (`seed`, `steps`, `sampler`, `cfg_scale`, etc.) are dropped. Research found neither Imagen 4 nor Gemini 2.5 Flash Image has a native JSON input — both want prose in a single string.

### MCP Tools

The Swift server exposes **11 tools**. Tool names live in both `App/MCPServer.swift` (Swift dispatch via `callTool(name:args:)`) and `mcp-server/src/tools.js` (Node schema) — keep them in sync.

**Read-only** (work offline via `index.json` fallback too): `search_assets`, `get_asset`, `get_asset_lineage`, `list_projects`, `list_collections`, `get_collection`, `get_spend`.

**Write / app-required**: `search_prompts`, `get_prompt`, `mark_asset_used`, `generate_image`.

`generate_image` takes prompt (string or JSON), quality tier, optional project/collection (name or UUID via `AppDatabase.findProject(idOrName:)` / `findCollection(idOrName:projectID:)`), tags, variant family, optional references (project active set + explicit asset IDs merged and capped at 3), and optional `max_images` / `max_cost_gbp` overrides. Returns `{ generated: [{asset_id, file_path, model_used, estimated_cost_gbp, seed}], total_cost_gbp, cost_breakdown, notes }`. Offline: `fallback.js` short-circuits non-offline tools via its `else` branch — no per-tool entry needed.

### Platform Strategy

- macOS: full three-panel layout (Source Panel 220pt | Content Grid | Inspector 280pt), NSToolbar, Swift Charts, MCP server, export presets, full spend dashboard.
- iPad: two-column `NavigationSplitView`; scoped feature set (library, generation, prompts, collections, variants, read-only spend).
- Use `#if os(macOS)` for platform-specific code. Never add iPhone layout code.

## Key Conventions

- **IDs**: UUID strings throughout (stored as `TEXT` in SQLite).
- **Dates**: ISO 8601 strings in SQLite and JSON.
- **Currency**: **GBP everywhere** — DB columns (`estimated_cost`, `actual_cost`), model `costPerImage`, UI displays, chart axes. Provider prices published in USD (Google, Anthropic) are converted at the provider boundary via `Currency.gbp(fromUSD:)` (`ImageAssetManagerCore/Currency.swift`). Update `Currency.usdToGBP` when the FX rate drifts; do not introduce ad-hoc conversions elsewhere.
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

Register the Node.js proxy at user scope so it's available from any project on this Mac:

```bash
claude mcp add image-asset-manager \
  --scope user \
  --env LIBRARY_PATH="$HOME/Library/Mobile Documents/iCloud~Ionic~ImageAssetManager/Documents" \
  -- node /absolute/path/to/Image-asset-manager/mcp-server/src/index.js
```

`LIBRARY_PATH` is only used in offline fallback mode (reads `index.json` directly). When the macOS app is running, every tool call is forwarded to `http://127.0.0.1:47821` and the live library location resolved from `AppEnvironment` is used regardless of `LIBRARY_PATH`. Smoke test with `curl http://localhost:47821/health` → `{"status":"ok"}`.

If the server isn't listening, check the Xcode console for a `[MCPServer]` error (typically an entitlement issue — see Sandbox entitlements above).
