# App Review Notes — Image Asset Manager (macOS)

Paste the relevant parts into **App Store Connect → App Review Information → Notes**. This
file holds the *instructions* (the entitlement explanation and verification steps) so they
are reusable for every future review.

> **SECURITY — never commit real keys.** This repo is public. The real API keys go **only**
> into the App Store Connect Notes field, never into this file. The placeholders below must
> stay as placeholders in anything committed or pushed. Keep the live keys in your password
> manager / App Store Connect, not here.

---

## Sample API keys (for the reviewer)

The reviewer enters these in the app's **Settings** window (⌘,) to exercise image
generation and prompt refinement. Provide the live values **in the App Store Connect Notes
field** — do not paste them into this file:

- **Nano Banana / Google AI Studio key** (image generation): `<<INSERT IN APP STORE CONNECT — NOT HERE>>`
- **Anthropic Claude key** (prompt refinement): `<<INSERT IN APP STORE CONNECT — NOT HERE>>`

Both keys have spend caps set and will be rotated after approval — if a future review
reports them as invalid, request fresh keys via Resolution Center.

---

## Why the app uses `com.apple.security.network.server`

The app includes a **local MCP (Model Context Protocol) server** so that Claude Code and
other MCP clients running **on the same Mac** can query the asset library and trigger
image generation. This is a core feature of the product, not background networking.

Key facts:

- The server binds **loopback only** — `127.0.0.1:47821`. It is reachable solely from
  this Mac and **never accepts connections from outside the machine**. There is no remote
  or LAN exposure.
- It is **user-controllable** and its state is fully visible in the app.

### How to verify the functionality in-app (no external tools needed)

1. Open the app and go to **Settings** (⌘,).
2. Find the **"Claude Code Integration (MCP Server)"** section.
3. The server is **enabled by default**; the status row shows **"Running on
   127.0.0.1:47821"** with a green indicator. (This status is driven by the live network
   listener — it only reads "Running" if the `network.server` entitlement allowed the
   socket to bind.)
4. Press **"Test Connection"**. The app makes a request to the running server and shows a
   green tick with the server's `{"status":"ok"}` response — demonstrating the entitlement
   doing real work, entirely within the app.
5. Each request appears in the **Recent Activity** list beneath the button.
6. The **"Enable local MCP server"** toggle starts/stops the server on demand; the status
   row and Test Connection result update accordingly.

The `network.server` entitlement is therefore required and exercised by demonstrable,
user-facing functionality.

---

## Other entitlements (for completeness)

- `com.apple.security.network.client` — outbound HTTPS to the Google and Anthropic APIs.
- `com.apple.security.files.user-selected.read-write` — the user picks the library folder
  via an open panel (Settings → Library Location).
- iCloud container entitlements — the default library location is the app's iCloud Drive
  container.
