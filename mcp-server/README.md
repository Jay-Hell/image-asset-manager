# image-asset-manager-mcp

MCP server for Image Asset Manager. Exposes the asset library as tools that
Claude Code can call directly.

## How it works

**When the macOS app is running** — every tool call is forwarded to the
in-app HTTP server on `localhost:47821`. All 10 tools are available including
writes (`mark_asset_used`).

**When the app is closed** — the server falls back to reading `index.json`
from `LIBRARY_PATH`. Read-only tools (`search_assets`, `get_asset`,
`list_projects`, `list_collections`, `get_collection`, `get_spend`) return
data from the last-exported snapshot. Write tools and prompt tools return an
error message explaining that the app must be started.

## Setup

### 1. Install dependencies

```bash
cd mcp-server
npm install
```

### 2. Register in Claude Code

Add the following to your Claude Code MCP settings
(`~/Library/Application Support/Claude/claude_desktop_config.json` or via
`claude mcp add`):

```json
{
  "mcpServers": {
    "image-asset-manager": {
      "command": "node",
      "args": ["/path/to/Image-asset-manager/mcp-server/src/index.js"],
      "env": {
        "LIBRARY_PATH": "/Users/yourname/Library/Mobile Documents/iCloud~Ionic~ImageAssetManager/Documents"
      }
    }
  }
}
```

Replace `/path/to/Image-asset-manager` with the actual repo path and
`yourname` with your macOS username. The iCloud container segment
(`iCloud~Ionic~ImageAssetManager`) matches the container ID configured in
the app's entitlements.

### 3. Verify

With the app running:

```bash
# Quick smoke test — should return {"status":"ok"}
curl http://localhost:47821/health
```

## Available tools

| Tool | Requires app | Description |
|---|---|---|
| `search_assets` | No | Full-text + filter search across the library |
| `get_asset` | No | Full metadata for a single asset |
| `get_asset_lineage` | Yes | Reference chain (which assets influenced this one) |
| `list_projects` | No | All projects |
| `list_collections` | No | Collections, optionally filtered by project |
| `get_collection` | No | Collection detail with asset list |
| `search_prompts` | Yes | Full-text search of the prompt library |
| `get_prompt` | Yes | Full prompt with linked assets |
| `get_spend` | No | Spend summary, optional project/date filter |
| `mark_asset_used` | Yes | Record usage + updates index.json |

## Development

```bash
# Run directly (set LIBRARY_PATH first)
LIBRARY_PATH="~/Library/Mobile Documents/..." node src/index.js
```
