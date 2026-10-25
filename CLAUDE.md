# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Image Asset Manager** — A SwiftUI app for AI image generation (Google Gemini direct and OpenRouter), asset management, and consulting workflow integration. Integrates with iCloud Drive for storage and exposes a local MCP server for Claude Code. **The App Store release is macOS only.** The iPad code is kept compiling (the census builds it) but is not shipped. iPhone is out of scope.

Specs, in `/Users/johnlivingston/IonicConsulting/1. Project Work/Ionic/Image Asset Manager/`: current is `Image Asset Manager — Providers, Catalogue and MCP Specification v0.3.md` (release 1; build-pass reviews in `Build — Release 1/`). The original app spec (v0.6) is in the same folder; superseded versions are under `_Superseded/`.

## Repository Layout

```
image-asset-manager/
  ImageAssetManager/
    ImageAssetManager.xcodeproj/        ← Xcode project
    ImageAssetManager/                  ← Universal app target (macOS + iPadOS)
      App/                              ← ImageAssetManagerApp, AppEnvironment,
                                          MCPServer (NWListener, macOS only),
                                          MCPServer+Generate (transport only: hands generation
                                          tools to Core's GenerateTools; the budget ceiling)
      Features/                         ← Generation, Library, Prompts, Export,
                                          Spend, Settings, ContentView
      Shared/                           ← Components (KeychainKeyEditor, LocalImage),
                                          Theme
      Resources/                        ← Assets.xcassets
      Info.plist                        ← target Info.plist (most keys generated via
                                          INFOPLIST_KEY_* build settings, see pbxproj)
      PrivacyInfo.xcprivacy             ← App Store privacy manifest (declares
                                          UserDefaults under reason CA92.1; no tracking,
                                          no collected data)
      ImageAssetManagerCore/            ← Embedded Swift package (NOT in a top-level Packages/)
        Sources/ImageAssetManagerCore/
          Currency.swift                ← USD→GBP conversion (single source of truth)
          DataHash.swift                ← Data.sha256 extension
          Database/                     ← AppDatabase + per-feature query extensions,
                                          LibrarySetup, migrations, Resolvers
          Generation/                   ← GenerationService (actor), GenerationPolicy
                                          (budget/routing), PromptFlattener,
                                          PreparedGeneration + GenerationPlanner (resolve + gate,
                                          panel and MCP), GenerateTools (MCP generate /
                                          generate_image / list_generation_options)
          Library/                      ← LibraryMigrationService (actor), ImportNaming,
                                          LibraryTools (MCP project/filing/import/tag tools)
          Catalogue/                    ← Catalogue (schema + bounds), CatalogueStore
                                          (sources, refresh), ModelResolver, JSONValue
          Resources/models.json         ← bundled copy of catalogue/v1/models.json
          Providers/                    ← ImageProvider protocol, NanaBananaProvider
                                          (catalogue-driven), ProviderRegistry,
                                          ProviderError
          Network/                      ← AnthropicClient (URLSession, catalogue-driven),
                                          MCPToken (token published on .ready, refusal logging)
          Refinement/                   ← PromptRefinementSession
          Models/                       ← Swift model types (GRDB-conformant)
          Export/                       ← IndexExporter (atomic JSON export)
          Security/                     ← KeychainService
        Tests/ImageAssetManagerCoreTests/
    ImageAssetManagerTests/             ← App-level tests
  catalogue/v1/models.json              ← the model catalogue (served from the `catalogue` branch)
  scripts/census.sh                     ← Core + app tests, iPad build, node --check, node tests
  scripts/dev-library.sh                ← copy the library for a DEBUG build's IAM_LIBRARY
  mcp-server/                           ← Node.js MCP proxy (repo root, not in Xcode project)
    src/                                ← index.js, appClient.js, fallback.js, tools.js
```

## Architecture

### Layer Responsibilities

- **ImageAssetManagerCore** — all business logic, data access (GRDB), provider abstraction, API clients. No SwiftUI imports. Swift 6 language mode; use `Sendable`, actors, and `async/await` throughout.
- **ImageAssetManager app target** — SwiftUI views only; imports Core for all logic. `AppEnvironment` (`@Observable`, in `App/AppEnvironment.swift`) is the single source of truth — created once in `ImageAssetManagerApp.swift` and injected via `.environment(env)` into both the main `WindowGroup` and the macOS `Settings` scene. Holds a `libraryRevision: Int` counter that view-models watch via `.task(id: env.libraryRevision)` to force a rebuild after destructive operations (library location change, clear library).
- **MCP server** — two-tier setup:
  - **Swift HTTP server** (`App/MCPServer.swift` + `App/MCPServer+Generate.swift`, macOS only) — `NWListener` on `127.0.0.1:47821`, started from `ImageAssetManagerApp.startMCPServer()` when the app launches. Reads via `AppDatabase+MCPQueries.swift`; the generation tools are request-to-result code in Core (`GenerateTools`), where the tests drive it, so the app target keeps only transport. `database` and `libraryURL` are internal (not private) so extension files can see them.
  - **Node.js proxy** (`mcp-server/` at repo root) — what Claude Code actually connects to. Forwards every tool call to the Swift server when running; when the app is closed, read-only tools fall back to reading `index.json` via `mcp-server/src/fallback.js`. Write tools (`generate`, `generate_image`, `list_generation_options`, `mark_asset_used`, prompt tools) return a "requires the app to be running" error (`fallback.js` gives the generation tools their own wording, checked before `index.json` is read).

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
  Backups/         ← library-<UTC>.db, taken before any pending migration; newest five kept
```

API keys are stored in Keychain only — never in iCloud, providers.json, or code.

**Sandbox entitlements** (`ImageAssetManager.entitlements`) — all four are required, don't remove any:

- `com.apple.security.files.user-selected.read-write` — pick a library location via `NSOpenPanel` and retain access via the security-scoped bookmark. **Also mirrored by the `ENABLE_USER_SELECTED_FILES = readwrite` build setting in `project.pbxproj` (Debug + Release)** — both must agree, and the build setting overrides the entitlement file at sign time. If migration suddenly fails with a permissions error, check the build setting hasn't reverted to `readonly`.
- `com.apple.security.network.client` — outbound HTTPS to Google AI Studio, openrouter.ai, api.anthropic.com and the catalogue host. Without this, every URLSession call returns the misleading `NSURLErrorCannotFindHost` ("server not found").
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
- `v4_variants_nullable_project_and_backfill` — makes `variants.project_id` nullable (orphan assets can now have families) and backfills a solo variant family for every existing asset. Enforces the invariant: **every asset belongs to a variant family of at least one member.** Live creation paths (in-app generation, MCP `generate_image`, import) all funnel through `AppDatabase.attachToVariantFamily(...)` which derives a default family name from the prompt (preferred) or filename when the caller passes no explicit name. The default-name helper `defaultVariantFamilyName(prompt:filename:)` caps at **80 characters and trims to the last whitespace boundary** before the cap (filename fallback uses the basename without extension); preserve that behaviour when touching the helper — over-long family names break the Source Panel layout. `fetchVariantFamilies` filters to families with >1 member, so singletons are invisible bookkeeping — they surface only once a sibling is added.
- `v5_clients_table_and_project_client_id` — `clients(id, name UNIQUE, created_at)`, plus `projects.client_id` FK (`ON DELETE RESTRICT`). Backfills a Client per distinct non-empty `projects.client_name`. `client_name` column is retained but no longer used (v10); code reads via `projects.client_id`. Managed in Settings (`ClientsSettingsSection` / `ProjectsSettingsSection`).
- `v6_asset_projects_join_and_backfill` — `asset_projects(asset_id, project_id, is_primary)` composite-key join. Backfills one primary row per existing `assets.project_id`. **`assets.project_id` is kept as a transitional "primary project" mirror** (first entry of the asset's project set). `searchAssets(projectIDs:)` filters via the join table; `setProjectsForAsset(...)` replaces an asset's set and updates the mirror. MCP `search_assets` and `generate_image` accept both a singular `project` string (shorthand) and a `projects` array — caller's first entry is the primary. `IndexExporter` emits both `project_id` (primary) and `project_ids` / `project_names` arrays so the Node fallback can filter offline.
- `v7_drop_collections` — drops the `collections` table and the `assets.collection_id` column (SQLite table-rebuild pattern). Collections were unreachable from the UI in practice (no creation path) and overlapped conceptually with projects + tags + variants. The metadata model is now **client → project(s) + tags + variant family**, nothing else.
- `v8_asset_media_type` — `assets.media_type` (MIME), backfilled from the extension by a frozen SQL `CASE`. **Nullable with no default on purpose:** App Store 1.0.x knows only v1–v7 (`AppDatabase.appStore1_0Migrator()`) and inserts assets without the column. Read it through `Asset.effectiveMediaType` / `mediaKind` (`image` | `vector`), which fall back to the extension. `MigrationV8Tests` proves the 1.0.x migrator still opens, reads and writes a v8 library.
- `v9_refused_spend` — `refused_spend` table (charges for images the library refused to store) plus the `spend_entries` view (`spend_log` UNION ALL `refused_spend`), which the spend aggregates read. Additive: App Store 1.0.x ignores both.
- `v10_client_ids_and_external_spend` (release 1.2) — every project with a `client_name` and no `client_id` gets the client of that name (trimmed, case-insensitive), created once if missing; a `client_id` already set stands. `client_name` is then neither read nor written (`Project` has no such property) but the column stays, because App Store 1.0.x/1.1.0 still write it. Adds `projects.description`, `spend_log.source` (NULL = the app's own, `external` = an import's reported cost), rebuilds `spend_entries` with `source`, and indexes `assets.file_hash`. `MigrationV10Tests` runs it on a v9 library built by `makeMigrator().migrate(_:upTo: "v9_refused_spend")`, checks the backup reads as v9, and that the 1.0.x migrator still opens and writes a v10 library.

**Backup before migrating.** `AppDatabase.init` copies an existing library with a pending migration to `Backups/library-<UTC>.db` through SQLite's backup API (`LibraryBackup`), keeping the newest five. Rotation never deletes the backup just taken (later-named files from clock skew can't push it out), and hidden `.library-*.db.partial*` files from a killed backup are swept before and after each one. A failed backup throws before `migrate`. `Backups/` is not in `LibraryMigrationService`'s item list, so backups stay behind on a location change.

**Opening a library.** Launch and location change both go through `LibraryOpener.open(at:)`, never `LibrarySetup` + `AppDatabase` directly. It refuses (`LibraryOpenError`, nothing written, no backup, no migration) when `library.db` is an iCloud placeholder (`.library.db.icloud`), is reported not current, or is missing beside existing assets or a non-empty `index.json` — any of which would otherwise look like a fresh library and get an empty v8 database that conflicts with the real one. It starts the download; the app shows the reason and a Try Again button rather than crashing.

Query logic is split by feature into extension files — add new queries in the matching extension rather than the core file:

- `AppDatabase+Queries.swift` — general-purpose asset/project CRUD
- `AppDatabase+LibraryQueries.swift` — library browser lookups
- `AppDatabase+PromptQueries.swift` — prompt library
- `AppDatabase+ExportQueries.swift` — export presets
- `AppDatabase+SpendQueries.swift` — spend dashboard aggregates
- `AppDatabase+RefinementQueries.swift` — Claude prompt refinement history
- `AppDatabase+MCPQueries.swift` — shapes reads for the MCP server
- `AppDatabase+Resolvers.swift` — `findProject(idOrName:)` for the name-or-UUID input accepted by `generate_image`

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

`NanaBananaProvider` (Google Gemini direct; provider ID `nano_banana` is stored on existing assets, so it stays) has **no model IDs in code**. Every model is an entry in the model catalogue, and every request goes to `:generateContent` with the model ID in the path. The Imagen `:predict` path is gone. The negative prompt is inlined as `"\n\nAvoid: {negative}"`.

### Model catalogue

`catalogue/v1/models.json` (repo root) is the one source file: tier → ordered routes (`fast`/`standard`/`pro` for `image`, plus `vector`; routes name `nano_banana` or `openrouter`), model entries (`aspectRatios`, `maxReferenceImages`, `imageSizes`, prices, a `body` merged *under* the app-owned request fields), `retired` models (display names for old assets, `replacedBy` for project defaults) and the prompt-`refinement` entry. A copy is bundled as `Core/Sources/.../Resources/models.json`; **a test fails if the two differ, so copy the repo file over the bundled one after every edit and raise `revision`.**

- `Catalogue.parse` validates (`Catalogue/Catalogue.swift`): schemaVersion 1, size cap, model IDs `^[a-z0-9][a-z0-9.-]{1,63}$` (one `/` allowed except for `nano_banana`, whose IDs go in a URL path), prices in (0, $1.00], headers allow-listed to `anthropic-version`/`anthropic-beta` (beta values to `server-side-fallback-2026-07-01`), and `body` keys allow-listed per `api` (Gemini: `generationConfig.imageConfig.imageSize` and `generationConfig.responseModalities` only; refinement: `max_tokens` 1…8192, `output_config.effort` low/medium/high, `fallbacks: "default"`). A model entry with any other body key is skipped; a refinement entry with one, or with another beta value, refuses the whole file. Model IDs may carry no whitespace or control character (`\A…\z` anchors). A bad model entry is skipped and the rest load; a file that leaves an image tier with no usable route is refused whole.
- `CatalogueStore` (`.shared`) picks the source: local override (macOS Settings → "Load catalogue from file…", shown with an OVERRIDE badge) > remote cache or bundled, whichever has the higher `revision`. The remote URL is compiled in: `https://raw.githubusercontent.com/Jay-Hell/image-asset-manager/catalogue/catalogue/v1/models.json` (the repo must stay public and keep its name). Refresh: launch, every 24 h, on demand, and one forced refresh per minute at most when a model answers 404. ETag-conditional; a failed fetch changes nothing. Cache: `Application Support/ImageAssetManagerCatalogue/`, never the library.
- `ModelResolver.resolve` (pure, `Catalogue/ModelResolver.swift`) turns media + quality + required capabilities + optional explicit model + configured providers into a `Resolution` (provider, model, `imageSize`, reference cap, estimate, note). The MCP handler and the panel (`resolveSelection`) both call it; neither picks a model. The panel goes through `PreparedGeneration.prepare` (Core): resolve once, run `checkBudget` (20 images / £2.50, as the MCP) on the estimate before any provider call, and hold the result; confirm records from it (`recording(_:)`) and never re-resolves. `GenerationParams.budget` carries the gate to the provider: a 404 retry re-resolves from the request (new size, new price), re-checks the budget, and reports `GeneratedImage.modelUsed`/`estimatedCostGBP`, which `GenerationService` stores. An explicit model on two tiers takes the first in tier order (fast, standard, pro). `with_references` = `standard` + `references`; `auto` = `standard`.
- **OpenRouter (pass B).** `OpenRouterProvider` (`openrouter`, request shape `openrouter.images`): `POST https://openrouter.ai/api/v1/images`, Bearer key, model ID in the body. It sends only the parameters the model's live record lists (`aspect_ratio`, `resolution`, `n`, `output_format`, `input_references` as base64); an unlisted value is rejected with the list. `OpenRouterModelStore` (`.shared`) holds the public `GET /images/models` list (launch, 24 h, one forced refresh a minute on a 404; cache beside the catalogue cache; a failed or empty fetch never replaces a good cache) plus learnt per-image prices (`/endpoints` records, then the first real `usage.cost`). The resolver takes `live:`; capabilities for OpenRouter models come from the live record, and `Resolution.estimateSource` says where the price came from. `ModelResolver.resolveAll` returns every usable route; `RouteExecutor` walks them and falls back on exactly three conditions (no key, 404, 402), each once per request, re-checking the budget at the next route's price; anything else is reported. `GenerationService` stores output through `AssetStore` (SVG as SVG) and records `GeneratedImage.providerUsed`. The `openrouter.images` catalogue body allow-list is `resolution` and `output_format` only. References go as `{"type":"image_url","image_url":{"url":"data:<sniffed MIME>;base64,…"}}` (OpenRouter's published shape); the `/key` response fields are unproven until an authenticated call (spec §10). **Usable on this install:** `CatalogueStore` (given `configuredProviders`; `.shared` reads the Keychain) refuses a fetched or override file unless every image tier has a route whose provider is compiled and has a key here (no key at all: judged on its own terms); `ProviderKeyChange.refresh()` runs from Settings on a key save/remove. **Live list:** a failed fetch with no cache retries after 1, 5, 30 min, then 24 h; `refreshIfNotLoaded()` fetches on demand (MCP, one a minute). **Every paid call is recorded exactly once.** `GenerationService.call` writes a `refused_spend` row (reason "not kept", ID = the `Generated.chargeID`) the moment a paid image exists, before the caller sees it (`v9_refused_spend`; the `spend_entries` view unions it with `spend_log` for every spend total). `record` (Keep) swaps it for the asset and a `spend_log` row in one transaction (`AppDatabase.keepCharge`); the asset ID and the spend row's ID are the charge ID, so a second Keep, after a failed one too, finds the asset and writes nothing. Discard, a second Generate and quitting leave the "not kept" row, so the spend counts. A refused image (`outputRefused`) updates that row's reason; a 200 with a cost and no image (`ProviderError.chargedNoImage`) writes a "no image returned" row at the actual cost and throws `outputRefused`.
- **Publishing a catalogue revision** (a model change needs no app release; merging code never changes live models): edit `catalogue/v1/models.json` on a feature branch, raise `revision`, copy it over the bundled `models.json`, run the Core tests, merge. Then, as a separate deliberate step, put the same file at `catalogue/v1/models.json` on the `catalogue` branch and push that branch. Retiring a model is the same edit: set `retired` + `replacedBy`. Check the raw URL serves the new `revision` before saying it is live.

### Prompt refinement

`AnthropicClient` reads model, headers and body from the catalogue's `refinement` entry; the app owns `model`, `system`, `messages`. `anthropic-version` is compiled (`2026-10-21`). `temperature`/`top_p`/`top_k` are never sent. The reply is the first `text` block; `refusal` and `max_tokens` stop reasons have their own errors; `PendingRefinement.modelUsed` is the response's `model`.

### Generation Pipeline

`GenerationService` (`Generation/GenerationService.swift`, actor) owns the write pipeline: provider call → disk write → Asset/SpendLog/tags/refs/variant DB rows → `index.json` export. Shared by the MCP generation tools and the in-app `GenerationViewModel` (`call` at Generate, `record` at Keep; `generate` = both) so the two cannot drift.

Policy decisions are pulled out into `GenerationPolicy` (pure, testable, no DB/IO dependencies):

- `checkBudget(count:unitCost:limits:)` — throws `BudgetViolation` when either the image count or the projected cost exceeds the limits. Defaults: 20 images / £2.50.
- `mergeReferences(project:explicit:maxReferences:)` — combines project active refs with explicit asset IDs, caps at the resolved model's `maxReferenceImages` (from the catalogue), project refs take precedence when over-cap.
- `Quality` — the caller-facing names (`fast`/`standard`/`pro`/`with_references`/`auto`). Which model each means is `ModelResolver`'s decision.

`PromptFlattener` accepts either a plain string or `[String: Any]` and emits Subject-Context-Style-ordered prose. Canonical keys (`subject`, `context`, `action`, `setting`, `style`, `composition`, `lighting`, `mood`, `camera`, `palette`, `details`, `extra`) are emitted in order; arbitrary keys are flattened with title-cased labels; non-prompt keys (`seed`, `steps`, `sampler`, `cfg_scale`, etc.) are dropped. Image models take prose in a single string, not native JSON, so structured prompts are flattened before sending.

### MCP Tools

The Swift server exposes **17 tools**. Tool names live in both `App/MCPServer.swift` (Swift dispatch via `callTool(name:args:)`) and `mcp-server/src/tools.js` (Node schema) — keep them in sync (`mcp-server/test/tools.test.js` reads both and fails if they differ; it also holds each `GenerateTools` and `LibraryTools` tool's schema fields to the `args["…"]` keys the Swift reads, per `// MARK: - tool: <name>` section in `LibraryTools.swift`).

**Read-only** (work offline via `index.json` fallback too): `search_assets`, `get_asset`, `get_asset_lineage`, `list_projects`, `get_spend`, `list_tags` (offline: counts and last-used from `index.json`; no client, description or empty projects).

**Write / app-required**: `search_prompts`, `get_prompt`, `mark_asset_used`, `generate`, `generate_image`, `list_generation_options`, `upload_asset`, `create_client`, `create_project`, `file_assets`, `import_asset`.

**Library tools (release 1.2)** — request to result in Core, `Library/LibraryTools.swift`; the app's `MCPServer+Library.swift` is transport only.
- `create_client` (name) and `create_project` (name, optional client, description): names unique ignoring case and trimmed; a clash returns the existing record unchanged with `created: false`. Settings adds through the same `createClient`/`createProject` and says so on a clash; `renameProject` throws `ProjectError.nameInUse` for another project's name in any case. An unknown client is refused with the list of clients. `list_projects` returns `id, name, description, client {id, name} | null, asset_count, last_used_at` (the latest `created_at`/`imported_at` of its assets), `created_at`.
- **Q1:** `generate`, `import_asset` and `file_assets` refuse an unknown project before anything is sent or stored (`AppDatabase.unknownProjectError`, listing the projects). `findProject` matches UUID, then exact name, then the name in any case.
- `file_assets` (asset_ids, project, `mode` add|move, `primary`): one transaction. `move` replaces every link and is always the primary; `add` keeps the others, `primary: true` moves the primary, an asset with none gets this one. `assets.project_id` is set from the `is_primary` row every time (`mirrorPrimaryProject`). Each touched asset's variant family is then filed where its members are (`fileVariantFamily`): `variants.project_id` = the members' primary when every member has the same one, else NULL, so a family split across projects shows in the whole library and under neither project. Unknown IDs come back per ID (`unknown`, `results[].status`), never skipped.
- `import_asset`: the **proxy** (`prepareImportArgs`, `tools.js`) takes an absolute path (`~/` expanded), resolves it with `realpath` and refuses a link whose target is outside the given file's own folder, allows `png jpg jpeg webp heic svg` by the real file's extension **and** its magic bytes (the two must agree), refuses anything but a regular file by `lstat` before opening (a FIFO or device would block the proxy), opens with `O_NOFOLLOW | O_NONBLOCK` and checks `fstat` is a regular file with the same device and inode before reading, caps at 25 MB (26,214,400 bytes) on what is read, and sends `data_base64`, `media_type`, `original_filename`, `file_modified_at` in place of `path`. The app never sees a path. The **app** re-checks the cap, stores through `AssetStore.store` (bytes sniffed against `media_type`; SVG stored as delivered and previewed sanitised, as pass C), records prompt/provider/model (default `imported`), project(s), tags and variant family (default named from the prompt or `original_filename`). `created_at` = caller's ISO 8601, else the file's mtime, else now; `imported_at` = now (Q3). A duplicate SHA-256 (`assets_file_hash` index, re-checked inside the insert transaction) is not stored: the existing ID comes back with the given projects (`mergeProjects`, primary unchanged) and tags merged, and a variant family attached if it has none (a retry after a failed follow-up write); nothing else is rewritten and no spend is written. **Q2:** a known `actual_cost_gbp` (or `actual_cost_usd`, converted by the app at `catalogue.fx`, the rate it uses for OpenRouter's actual cost; both together are refused) writes a `spend_log` row with `source = 'external'`, estimated = actual, dated `created_at`; an unknown cost writes no spend row and leaves both cost columns NULL, never 0.
- `get_spend` takes `include_external` (default true); the dashboard queries (`fetchSpendSummary`, `fetchDailySpend`, `fetchSpendByProvider`, `fetchSpendByProject`, `fetchTopAssetsBySpend`) take `includeExternal:` likewise. NULL `source` is the app's own (every older row, and every row an older build writes).
- `list_tags`: every tag with its asset count, most used first. The `tags` field of `generate`/`generate_image`/`import_asset` and the `generate` and `import_asset` descriptions tell agents to reuse existing tags (`REUSE_TAGS`, `tools.js`).

**App pass (release 1.2, R2-2).** The logic is in Core, the views are thin.
- **Sidebar** (`SourcePanelView`): All Assets, **Unfiled** (`SourceSelection.unfiled`, `searchAssets(projectIDs: [])`), then one section per client (its grid is `searchAssets(clientID:)`, the join the client count uses, never a project list: an empty list means Unfiled) (`SidebarGrouping.groups`: clients and their projects by name ignoring case, projects with no client last), "New client…"/"New project…" sheets through `createClient`/`createProject` (a clash shows `NameClash` text, which Settings uses too). Counts are `fetchSidebarCounts(showHidden:)` (distinct assets; a client's count counts an asset in two of its projects once; hidden left out unless Show Hidden); `LibraryViewModel.loadSidebarData` reloads them after every filing, import, delete, generation, hide and unhide. Tag counts (`fetchTagsWithCounts(showHidden:)`) follow the same hidden rule. Client, project and tag-rename names clash ignoring case in any script ("Écran"/"écran"): `NameMatch` compares in Swift, because SQLite's `LOWER` folds A–Z only. Filing errors show in a "Filing Failed" alert.
- **Filing** from the grid: "Add to project…" / "Move to project…" (multi-select bar and the cell's context menu, which acts on the whole selection when the cell is ticked) call `LibraryViewModel.file` → `fileAssets` (`primary: false`), so the family rule applies. The old `bulkAddProject` is no longer reached from the grid.
- **Tag manager** (`TagManagerView`, a sheet from the sidebar's Tags "Manage…"): `Library/TagManagement.swift` — `fetchTagRows`, `renameTag` (refuses another tag's name in any case; its own name in another case is fine), `mergeTags(ids:into:)` (target must be among ids; links move, duplicates collapse), `deleteTag` (links go, assets never). Delete confirms in the page. Tag names stay case-sensitive unique in the schema; only rename refuses a case clash.
- **Thumbnails** (`Library/ThumbnailCache.swift`, `ThumbnailImage`): 512 px longest side, PNG in `Caches/Thumbnails` (app container, never the library), keyed `<assetID>/<assetID>-<fileHash>-512.png` (key characters limited to letters, digits, `-`, `_`); a new hash drops that asset's older entry, listing only that asset's folder. `sweepIfDue` (from the library browser, detached) removes deleted assets' folders and stale files at most once a day (`.last-sweep` marker); it removes only key-named folders and `.png` files. Raster by ImageIO, SVG via `AssetPreview` (sanitised). Inspector, references and prompts still use `LocalImage` (1024 px, uncached).
- **Spend dashboard** has an "Include external spend" toggle (on by default) → `includeExternal:` on the four queries.
- `findProject` throws `ProjectError.ambiguousName` (naming both, with IDs) when a name matches two projects differing only in case and none exactly; `mergeProjects` files the variant family.

**Manage clients and projects (release 1.2, R2-6).**
- **Core:** `deleteClient` no longer refuses: the client's projects get `client_id` NULL and the client goes in one transaction (returns how many; `ClientError.hasAssignedProjects` is gone). `deleteProject` keeps the images: it unlinks the project, gives an asset whose primary it was another of its projects as primary (first by name ignoring case, then ID) or none, mirrors `assets.project_id`, and **nulls `variants.project_id` for families filed under it before the delete** (that column cascades, and would take the family and its members) then refiles each affected family by its members. `assetCount(projectID:)` / `projectCount(clientID:)` feed the confirmations. `renameClientReportingClash` / `renameProjectReportingClash` turn a name clash into `NameClashError` carrying the creating text (`NameClash.client/project`, naming the holder as stored); the sidebar and Settings both use them.
- **Selection:** `GridSelection` (Core, pure): `click(_:_:order:)` plain / ⌘ / ⇧ (range from the anchor, in grid order, replacing the selection; the anchor stays), `selectAll`, `clear`, `actedOn(id)` (the whole selection when the image is in it, else that image). `LibraryViewModel.selection` holds it and `selectedAssetIDs` is a view of it, so iPad Select mode is unchanged. macOS: a click (grid cell or filmstrip member) reads `NSEvent.modifierFlags`; one image selected shows in the inspector, several show "N images selected"; ⌘A and Esc are `onKeyPress` on the grid, which has focus after a click. **Order** is `LibraryViewModel.displayedOrder`: each filmstrip's members, then the standalone cells, as on screen; ⌘A and ⇧-range use it. `selectAsset` (macOS, not in Select mode) puts the image in `selection` too, so the highlight and inspector agree whatever calls it (promote, Keep, a reselect); a selection already exactly that image keeps its anchor. **`loadAssets` ends by pruning** `selection` and `selectedAssetID` to `displayedOrder` (a search, hide, delete or move out of the viewed project takes images off the screen), and the macOS inspector follows (the one image left, else none).
- **Sidebar:** right-click a client (header or "All X" row): Rename…, Delete…; a project: Rename…, Move to client ▸, Delete…. Sheets, not system dialogs; Delete names the project count or image count. Drag: `SidebarDrag` (`.images([id])` / `.project(id)`, `Transferable`; **each kind has its own content type**, images `.json`, a project `.plainText`, and each target's `onDrop(of:)` and `SidebarDropDelegate.accepts` list only the kind it takes, so a project onto a project or images onto a client validate nothing: no highlight, no badge) and `SidebarDropDelegate` (highlight, `.copy` proposal for an add, `.move` with ⌥ or for a project onto a client). A project onto a client header moves it, onto "No client" detaches it; images onto a project add. **⌥-drop** (`LibraryViewModel.dropImages` → Core `moveAssets(assetIDs:from:to:)`) adds them to the target and removes them from the viewed project only; their other projects stay, and the target becomes the primary if the viewed one was. Viewing anything but a project (All Assets, Unfiled, a client, a tag) it is a plain add. One transaction, `repairPrimary` and `fileVariantFamily` as `fileAssets` (the family is refiled by its members). The grid's menu "Move to project…" is still `FilingMode.move` (replaces every link). The "No client" group exists only while a project has none.
- **Delete confirmation** is shared: `DeleteTarget` (the wording) and `DeleteConfirmSheet` (`Features/Library/DeleteConfirmation.swift`) serve the sidebar and Settings' Clients and Projects sections, which confirm in the window before `deleteClient`/`deleteProject`.
- **Refresh:** every `LibraryViewModel` edit ends in `refreshAfterWrite` (it also writes `index.json`). Every write by anyone also reaches every open window: `AppDatabase.libraryChanges()` (GRDB `DatabaseRegionObservation` of `clients`, `projects`, `asset_projects`, `variants`; one event per committing transaction, bursts collapse) feeds `LibraryViewModel.observeLibraryChanges()` (run by `ContentView`'s `.task`, so a second window, Settings and the MCP's `create_client`/`create_project`/`file_assets` all refresh the sidebar and grid) and the Settings sections' `.task`. There is no manual revision bump any more (`libraryEditRevision`, `libraryEdited()` and `reloadAfterExternalEdit()` are gone). `loadSidebarData` falls back to All Assets when the viewed client or project is gone. A write to other tables alone (tags, assets) does not announce; those paths refresh themselves.
- Not provable without the app: the copy badge and highlight on a drag (and that the two content types keep a project row's drag and the list's own selection apart), ⌘/⇧-click modifiers, ⌘A/Esc focus, the sheets.

**App not running (Q4).** `appClient.ensureAppRunning` (called by `index.js` for every tool, reads included, after the import guard): an app already answering `/health` is used as it is. Otherwise `/health` is tried three times 750 ms apart (`HEALTH_TRIES`, `HEALTH_RETRY_MS`), then the proxy opens the app **by path**, `open /Applications/ImageAssetManager.app` (`DEFAULT_APP_PATH`; `IMAGE_ASSET_MANAGER_APP_PATH` overrides it, for tests and development only), never by bundle ID: LaunchServices would pick the highest-versioned registered copy, which can be a DerivedData or scratch build that then migrates the live library. It polls `/health` every 500 ms (`LAUNCH_POLL_MS`) for at most 30 s (`LAUNCH_TIMEOUT_MS`); once it answers, its `bundle_path` must be the path launched (a trailing slash or a link aside), or the call fails naming both paths, before any token or tool call is sent; and it goes on only once the token file's mtime is newer than the launch. `/health` returns `{status, bundle_path, version, build}` (`MCPHealth`, Core) and never the token; an app older than 1.2 (the store's 1.1.0 until 1.2 ships) reports no path, and is accepted after a launch by path; a reported path that differs is refused. On timeout the error names the 30 s limit; a read-only tool then falls back to `index.json`, any other tool fails with that message. `createAppClient` injects the launcher, app path, clock, sleep and `fetch`: no test opens the app.

**One server per process.** Every window's `.task` calls `startMCPServer`, which goes through `ImageAssetManagerDelegate.mcpServers` (`MCPServerOwner`, Core): the first call makes and starts the server, every later one (Cmd-N, the Dock after the last window closed) starts nothing. The owner is tested in Core; the `.task` and delegate wiring cannot be without launching the app.

**Token (the 23 Oct 401).** `MCPTokenPublisher` (Core, `Network/MCPToken.swift`) mints the token and writes `mcp-token` (0600, atomic) only on the listener's first `.ready`, so a second instance that cannot bind never overwrites it; under a test host it is nil and `MCPServer.start` returns without listening. A refused `/tool` call is logged through `os_log` (subsystem `Ionic.ImageAssetManager`, category `MCPServer`) by `MCPAuth.refusalMessage`, which gives the reason and the supplied token's length, never either token. On a 401 the proxy re-reads the token file once and retries; a second 401 is reported, and no other status is retried.

**Tool descriptions name no model and state no price** (spec T21; a node test holds `tools.js` to it). An agent learns model names and prices from `list_generation_options` only.

**Per-tool timeouts.** `appClient.js` defaults to 8 s but consults `TOOL_TIMEOUTS_MS` first — `upload_asset` 180 s, `generate` and `generate_image` 300 s, `list_generation_options` 60 s (it may fetch OpenRouter's model list), `import_asset` 60 s (up to 25 MB written into the library). Any tool outlasting a database read needs an entry; without one the proxy aborts while the app carries on, so the caller sees a failure whose side effect still happened.

**`iam` command line (R2-3)** — `mcp-server/bin/iam.js` (a shim; the code is `src/iam.js`, `bin` entry `iam` in `package.json`) for scripts that need an image made or filed without an API key of their own, because the app holds the keys. It is built on `createAppClient`: `ensureAppRunning` first (so it opens the app by path, as the proxy does, Q4), then `callAppTool`. `iam generate --prompt … [--quality] [--aspect] [--model provider:model] [--project] [--tag]… [--family] [--out dir]` prints `{generated:[{asset_id,file_path,copied_to?}],cost,notes}`; `iam import <file>… --project … [--prompt | --prompts-json f [--key id]] [--provider] [--model] [--cost-usd | --cost-gbp] [--tag]… [--family]` runs the proxy's `prepareImportArgs` on each file then `import_asset`, printing one JSON line per file (`{file, asset_id, status: new|duplicate}` or `{file, error}`); `iam projects`, `iam tags`. Without `--key` the prompts-json key is the file's name without its extension. `--cost-usd` is converted at `USD_TO_GBP` (0.79), which a test holds equal to `Currency.usdToGBP` in Core. Exit 0 all succeeded, 1 any failed, 2 usage; errors on stderr; it reads no token or key itself. `--help` lists every option. **Install** (not done by a build; the main session does it): `cd mcp-server && npm link`, or `ln -s "$PWD/bin/iam.js" ~/.local/bin/iam`. Tests: `mcp-server/test/iam.test.js` (fake client, no app).

`upload_asset` sends one asset's bytes to a URL a receiving system has already minted (Deliverable Orchestration's `artefact_asset_upload_url`), so image bytes never enter the calling model's context — only a receipt returns. The app performs the PUT rather than the Node proxy for two reasons: the proxy runs as a child of Claude Code and is refused at `open()` by macOS TCC on the iCloud container, and only the app knows the live library location (`LIBRARY_PATH` is an offline fallback and can be stale). Logic lives in `ImageAssetManagerCore/Network/AssetUploader.swift` — HTTPS only, no credentials in the URL, default port only, and an allowlist of `portal.ionicconsulting.co.uk` plus the `.r2.cloudflarestorage.com` suffix (leading dot deliberate — it forces a label boundary, so `notr2.cloudflarestorage.com` fails). The destination is validated **before** the file is read: the caller is a model that may have just read untrusted text, so an unguarded version of this tool is an exfiltration primitive. 10 MB cap mirrors the portal's `MAX_ASSET_BYTES`. An SVG (by name or bytes) is sent as `SVGDocument.sanitisedForPreview`'s copy, never as stored, and one the sanitiser cannot read is refused (`svgNotSanitisable`); `ImageExporter.exportVector` writes the sanitised copy likewise (ruling 8). Usage is not recorded — `mark_asset_used` stays a separate call.

**`generate`** (`Generation/GenerateTools.swift`, Core) says what is wanted and the app picks the model. Inputs: `media` (`image` default, `vector`; `video`/`audio` answer "not yet supported"), `quality` (`fast`/`standard`/`pro`/`auto`/`with_references`), `require` (`references`, `transparent_background`, `seed`), `model` (`provider:model`, an explicit override), `aspect_ratio` (`square`/`landscape`/`portrait` or an exact ratio such as `4:3`, carried as `GenerationParams.ratio` and checked against the resolved model), `resolution`, plus prompt (string or JSON), optional project (name or UUID via `AppDatabase.findProject(idOrName:)`; `project` singular or `projects` array), tags, variant family, references (project active set + explicit asset IDs, capped at the resolved model's limit), `count`, and `max_images` / `max_cost_gbp` (clamped to the app ceiling). It calls `GenerationPlanner` (the same entry the panel uses): resolve once, gate, and, for an explicit OpenRouter model nothing prices, ask `OpenRouterModelStore.loadPrice` first. Returns `{ generated: [{asset_id, file_path, media_type, model_used, provider_used, estimated_cost_gbp, actual_cost_gbp, seed}], resolved: {provider, model, tier, reason}, cost: {estimated_gbp, actual_gbp, actual_from_provider}, batch: {requested, made, stopped_early}, total_cost_gbp, cost_breakdown, notes }`. `resolved` and the costs are the route that served (after a fallback, not route one); `reason` and `notes` carry the reroute and fallback notes. A batch stops when actual spend so far plus the next image would pass `max_cost_gbp` (T17), the next image priced at the larger of the estimate and what the last one really cost; each image's fallback and 404 re-checks run against the cap less what has been spent (`BudgetContext.spentGBP`, `remainingLimits`). If a later image fails after earlier ones were made, the made ones are returned with the reason in `notes`.

**`generate_image`** is `generate` with `media` forced to `image` (T18); the same code path, so the two cannot disagree. **`list_generation_options`** returns providers (with `configured`), per media the tiers with the model they resolve to, estimate (GBP), estimate source, capabilities and fallbacks, and the capability names; `include_all: true` adds every model (`ModelOptions.all`: catalogue plus the OpenRouter live list), each with `model` (the string to pass as `model`), estimate and capabilities. The panel's "Specific model…" picker reads the same `ModelOptions`.

Offline: `fallback.js` throws a specific "needs the app" error for the three generation tools before it reads `index.json`; any other non-offline tool takes its `default` branch.

**Panel and MCP are one path.** The panel's tier / specific-model pickers become a `PanelSelection`; `GenerationPlanner.prepare` resolves and gates (T19: same function, same estimate as the MCP for the same request); `GenerationService.call` runs the routes through `RouteExecutor` (fallback included) and holds the answer; Keep calls `GenerationService.record` (`AssetStore`, so `media_type` is set and a refused paid image is recorded as spend and shown). Both surfaces build their `GenerationService.Request` with `PreparedGeneration.request(...)`. The panel's Generate step is `PanelGeneration.run` (Core; the view model calls it and the tests drive it), and both surfaces take their usable providers from `ProviderAvailability.usable()` (compiled in and a key present), so neither offers a model the other cannot reach.

**Learnt OpenRouter prices** are keyed by model and size (`OpenRouterPrice.key`), floored at $0.005 an image whenever stored or read, and an observed cost counts for its own size only; the model-level `/endpoints` price serves any size.

**Provider error text** goes through `ProviderMessage.text(from:redacting:)` (Anthropic's, Google's and OpenRouter's JSON → `error.message`, whole up to 2,000 characters, the key replaced if echoed, and any `key=` value in a URL query). Every provider passes its own key. The panel shows errors with `ErrorMessageText`: wrapped, selectable, never one clipped line.

### Platform Strategy

- macOS: full three-panel layout (Source Panel 220pt | Content Grid | Inspector 280pt), NSToolbar, Swift Charts, MCP server, export presets, full spend dashboard.
- iPad: two-column `NavigationSplitView`; scoped feature set (library, generation, prompts, variants, read-only spend). Kept compiling, not shipped: the App Store release is macOS only.
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
| OpenRouter API key | `com.Ionic.ImageAssetManager` (`OpenRouterProvider.keychainService`) | `openrouter_api_key` |
| Anthropic API key | `com.yourapp.imageassetmanager` (`SettingsView.service`) | `anthropic_api_key` |

### Technology Stack

| Layer | Technology |
|---|---|
| Language | Swift 6.0 (strict concurrency) |
| UI | SwiftUI — macOS shipped, iPad kept compiling |
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

# Core tests on the iPad simulator (package as a workspace). Known reds there: the three
# SVGPreview render cases (WebKit, see below) and three NanaBananaProvider key tests.
xcodebuild test -workspace ImageAssetManager/ImageAssetManager/ImageAssetManagerCore \
  -scheme ImageAssetManagerCore -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

**Census** (run before calling a pass done; it fails on a zero or lower-than-floor count): `MIN_CORE=412 MIN_APP=11 MIN_NODE=59 scripts/census.sh`. Floors are the last green counts; raise them when tests are added.

**macOS app tests launch the app as their host.** Under XCTest (`TestHostIsolation.isTestHost`, from the variables XCTest sets) `AppEnvironment.make()` opens a fresh library under the temporary directory and never reads the bookmark, UserDefaults or iCloud; the window shows no library UI and the MCP listener does not start. `ImageAssetManagerTests` asserts the library the host actually opened is inside the temporary directory. Keep that test, and keep anything new at launch behind `isTestHost`.

**Looking at the screens on a copy (DEBUG only).** A development build shares John's container (same bundle ID), so launching one plainly opens and migrates the live library. Make a copy with `scripts/dev-library.sh <dest>` (SQLite backup API, source opened read-only, `immutable=1` when it has no `-wal`; `IAM_SOURCE` names another source; dest inside `~/Library/Containers/Ionic.ImageAssetManager/Data/` or the sandbox refuses it) and launch with the command it prints (`-IAM_LIBRARY <dest>`; the `IAM_LIBRARY` environment variable works too). `DebugLibrary` (Core, `#if DEBUG`, absent from Release) refuses a folder that overlaps the live iCloud container, the saved bookmark or `_url` location, or `Application Support/ImageAssetManager`, or whose `library.db` is the live file; an unreadable saved location, an empty value or two values also refuse, and the window shows why — never the live library. While active: no MCP server or token, no `persistBookmark`, location change refused, catalogue and thumbnail caches in `<copy>/DebugCaches/`, title "DEBUG LIBRARY: <path>". `scripts/test-dev-library.py` tests the script on a temporary library. Never run the script against the live library from an agent.

**No test touches the real Keychain.** Providers and `AnthropicClient` take an injected API-key closure; tests pass a fake. Keep it that way: a test that stores or deletes a real item can wipe John's key.

**Content, not names.** `AssetStore.store` sniffs the bytes (`MediaType(sniffing:)`: PNG/JPEG/WebP/HEIC signatures, SVG root) and refuses a MIME label that disagrees, before writing anything. Previews go through `AssetPreview.render(contentsOf:)`, which chooses the renderer from the bytes: SVG always via the sanitiser, rasters via ImageIO, anything else not at all. Reference images sent to Gemini carry their sniffed MIME type.

**SVG preview** (`SVGPreview`) always renders a sanitised copy (`SVGDocument.sanitisedForPreview`), capped at 10 MB. The sanitiser is an allow-list: static drawing elements, geometry and presentation attributes, `style` filtered to presentation properties, CSS functions limited to colour, transform and fragment `url(#…)`, no CSS escapes, no foreign namespaces. macOS uses `NSImage`; on iPadOS `UIImage(data:)` returns nil for SVG, so WebKit draws it as an `<img>` with JavaScript off. WebKit does not complete loads in the package test host on the simulator, so the iPad path is only provable inside an app.

**MCP proxy tests:** `node --test "mcp-server/test/*.test.js"` (Node 24+ does not take a directory). `scripts/census.sh` runs them (`MIN_NODE`).

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

`LIBRARY_PATH` is only used in offline fallback mode (reads `index.json` directly). When the macOS app is running, every tool call is forwarded to `http://127.0.0.1:47821` and the live library location resolved from `AppEnvironment` is used regardless of `LIBRARY_PATH`. Smoke test with `curl http://localhost:47821/health` → `{"build":…,"bundle_path":"/Applications/ImageAssetManager.app","status":"ok","version":…}`.

If the server isn't listening, check the Xcode console for a `[MCPServer]` error (typically an entitlement issue — see Sandbox entitlements above).
