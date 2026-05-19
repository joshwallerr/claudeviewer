# Claude Viewer

A native macOS menu bar app that shows the live status of every running Claude Code session on your machine, plus your claude.ai usage limit, at a glance.

```
●●⚪⚪🟠   (left: inactive, middle: waiting for you, right: working)
```

- Pulsing orange dot — Claude is thinking or running a tool
- Solid white dot — session is idle, waiting for your input
- Dimmed white dot — session has been idle for more than 2 hours

Click the dots to open a popover listing each session by its AI-generated title, its repo, status, and current context window usage, plus an orange progress bar for your 5-hour claude.ai limit with the time until reset.

## Features

- Watches `~/.claude/sessions/` in real time via filesystem events — no polling overhead
- Reads each session's JSONL transcript to extract context usage and the title Claude auto-generated for it
- Hides sessions that have never been interacted with (just opened, or freshly `/clear`ed)
- Sorts: working first, then waiting-on-you, then stale, with the most recently active at the top
- Polls `claude.ai/api/organizations/<id>/usage` every 5 minutes (and on popover open) for your 5-hour limit
- "Launch at login" via `SMAppService`

## Install

Requires macOS 13+ and the Swift toolchain (`xcode-select --install`).

```sh
git clone <this repo>
cd claude-viewer
./scripts/build-app.sh
open ~/Applications/ClaudeViewer.app
```

The script builds and installs the `.app` bundle to `~/Applications/` atomically (no stray copies).

## Setup: usage limits

Open the popover → click the gear icon → pick the browser you're already signed in to claude.ai with. The app pulls the `sessionKey` cookie out of the browser's local cookie store (Chromium-based browsers only — Brave, Chrome, Arc, Edge) and stores it at `~/Library/Application Support/ClaudeViewer/session-key` (mode 0600).

macOS will ask for keychain access **once** to read your browser's encryption key. Click "Always Allow".

If you don't use a Chromium browser, the settings sheet's "Other sign-in methods" disclosure offers:

- An embedded WebView sign-in (note: Google SSO often blocks embedded browsers; use email login inside it)
- Manual paste of the `sessionKey` from DevTools

## How it works

| Surface | Source |
| --- | --- |
| Dots in menu bar | `~/.claude/sessions/<pid>.json` heartbeat files — one per running `claude` process. `status` field is `busy`/`idle`/`shell`, mapped to working/idle. |
| Session title | Latest `ai-title` (or `custom-title`/`agent-name`) entry in `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` |
| Context % | Sum of `input_tokens + cache_creation + cache_read` from the latest assistant message in that JSONL. The denominator (200K vs 1M) is auto-detected by checking whether any session has ever exceeded 200K. |
| 5-hour limit | `GET https://claude.ai/api/organizations/<org_id>/usage` with the `sessionKey` cookie |
| Brave/Chrome cookie | AES-128-CBC, key derived via PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 iters, 16-byte key, 16-space IV) — Chromium's standard recipe |

## Caveats

- `claude.ai/api/...` is **not** a public Anthropic API. They could change or rate-limit it. The app degrades gracefully — limits row shows an error, everything else keeps working.
- Cookie expiry: claude.ai sets a long-lived `sessionKey`, but log-outs / password changes / cookie clears will invalidate it. Re-import from the browser when that happens.
- Local-only: the app never sends anything to a server I control. The only network call is to `claude.ai` with your own cookie.
