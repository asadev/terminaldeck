# Terminal Deck

A desktop workspace for running AI coding agents.

Run several Claude Code, Codex or Gemini sessions side by side, see at a glance
which ones are working and which are waiting on you, and know what they cost.

[terminaldeck.dev](https://terminaldeck.dev) — the site lives in its own
repository, `asadev/terminaldeck-site`, because it changes for its own reasons.
Its CI checks out this repo and fails any page describing a feature nothing
here can reach.

[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)
![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)

<!--
  SCREENSHOT PLACEHOLDER — add before publishing.
  Save a window shot to docs/screenshot.png and replace this comment with:
  ![Terminal Deck](docs/screenshot.png)
  Take it with two live sessions in different states so the status dots read,
  and take a second one in light mode for docs/screenshot-light.png.
-->

> **A screenshot goes here.** Not committed yet — see the comment in this file's
> source for what it should show.

---

## Why

Running agents in bare terminal tabs falls apart quickly. You lose track of which
session is mid-thought and which has been sitting on a question for ten minutes,
you have no idea what you have spent, and there is nothing between an agent and
your files when it decides to do something drastic.

## Status

**Alpha**, and honest about it. It runs and is used daily on macOS. Windows and
Linux are not exercised — some of the code is written for them, none of it is
tested there — and the mac build is unsigned.

If the [Releases](https://github.com/asadev/terminaldeck/releases) page is
empty, no version has been tagged yet; build from source in the meantime.

## Requirements

- **macOS 12 or later, on Apple silicon.** A release carries one artifact,
  `-arm64`. There is no Intel build and no universal binary: macOS 27 does not
  run on Intel Macs at all, so an Intel slice would serve only 2019-2020
  hardware frozen at macOS 26 — and it could not be tested on any machine here
- **Node 22 or newer** (CI runs 22 and 24)
- **At least one agent CLI**, installed and already authenticated:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Codex CLI or
  Gemini CLI
- Optional: [`gh`](https://cli.github.com) for the GitHub panel

Terminal Deck never handles your API keys or logins. It launches the CLI you
already have and inherits whatever authentication that CLI uses.

## Install

Download the `.dmg` from [Releases](https://github.com/asadev/terminaldeck/releases),
open it, and drag the app to Applications.

The build is **not signed or notarised** — that needs an Apple Developer
identity. macOS will refuse the first launch. Either right-click the app and
choose *Open*, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/Terminal Deck.app"
```

## Build from source

```bash
git clone https://github.com/asadev/terminaldeck.git
cd terminaldeck
npm install
npm run dev
```

`npm install` compiles two native modules (`node-pty` and `better-sqlite3`)
against Electron's ABI, so the first install takes a while.

To produce an installable app rather than run from source:

```bash
npm run dist:mac         # build + package a .dmg and .zip into release/
npm run pack:mac         # just the .app, no installer — faster for testing
```

`npm run dist:mac` produces four files in `release/`: a `.dmg` and a `.zip`,
each with a `.blockmap`. Named from the slug, so no download URL contains an
escaped space:

```
terminaldeck-0.1.0-arm64.dmg   114 MiB
terminaldeck-0.1.0-arm64.zip   114 MiB
```

…plus `latest-mac.yml`, the update manifest. `npm run release:check` verifies
the two agree before an upload.

[BUILDING.md](BUILDING.md) covers all of it: outputs, the icon, what signing
and notarisation would take, and what they cost.

Other commands:

```bash
npm test          # vitest
npm run typecheck # both tsconfigs
```

> **Never run `npm run build` while `npm run dev` is serving.** They share
> `out/`, and the build clobbers what dev is running.

## What it does

Everything listed here is built and working. For what is planned, see
[ROADMAP.md](ROADMAP.md).

### Sessions

- Multiple sessions per project, each its own terminal, with scrollback that
  survives switching tabs
- **Status at a glance** — working / waiting / needs-input / exited, classified
  from what is actually rendered on the session's screen
- Per-session provider choice, with per-project and global defaults
- **Session resume** — continue the project's last conversation
- Titles derived from the task rather than the folder name
- Unread markers when output arrives on a background tab
- Desktop notifications and sounds when a session finishes or needs you
- **Chat mode** — a message view over the same session, if you would rather type
  into a composer than a terminal

### Cost and context

Read from Claude Code's own JSONL transcripts, not scraped from terminal output.

- Spend per session, per project and per day
- Token and context-window tracking, with a warning before context bloat
- **Session inspector** — timeline, cost breakdown, tool usage, context meter
- Deep search across past transcripts
- Smart alerts for missing tools, context bloat and session health

### Project workspace

- Git panel — branch, dirty files, diffs
- File tree and viewer, quick open, command palette
- GitHub panel — PRs and issues through the `gh` CLI
- **AI readiness score** — whether a project has CLAUDE.md, tests, lint,
  typecheck and a clean git state, with one-click fixes
- `.deckignore`, honoured by the tree, search and watchers

### Layout

- Customisable per-project dashboard, drag-and-drop widget grid
- Kanban board per project; a card can spawn or resume a session, and moves to
  Done when that session completes
- **Swarm view** — every running session in one grid
- Split panes with focus routing
- Multiple agent profiles with isolated config directories, so work and personal
  logins never mix
- Live dark/light theming; terminals recolour without a restart

### Integrations

- **Embedded browser** — tabs, device emulation, per-tab isolation; inspect an
  element and send its selector and text back to the agent as context
- **MCP client and inspector** — add, edit and call servers
- **Hooks** installed into each provider's settings, namespaced so they never
  collide with another tool's hooks on the same machine
- Chrome cookie import
- Live dev-server port discovery

### When something breaks

Turn on **Settings → Advanced → Debug mode** to get a Debug panel with a live
IPC trace, the session process table, the app log, and a **support bundle**.

The bundle is what to attach to a bug report. It carries versions, detected
CLIs, which IPC modules registered, config paths and the recent log. Tokens, API
keys, authorization headers and your home directory are stripped in the main
process before it is handed to the UI — IPC *arguments* are never recorded at
all. Read it before you paste it anyway.

## Keyboard shortcuts

Generated from [`src/renderer/keymap.ts`](src/renderer/keymap.ts), which is the
single source of truth — the app matches keystrokes against that table and the
in-app sheet (`⌘/`) renders the same rows. If this list and that file disagree,
the file is right.

`⌘` is the primary modifier on macOS; elsewhere the same bindings use `Ctrl`.

### Anywhere

| Action | Keys |
|---|---|
| New session | `⌘T` |
| Resume the last session here | `⌘⇧T` |
| Close session | `⌘W` |
| Jump to a session tab | `⌘1`–`9` |
| Next session | `⌃⇥` |
| Previous session | `⌃⇧⇥` |
| Open a project | `⌘O` |
| Quick open a file | `⌘P` or `⌘⇧O` |
| Command palette | `⌘K` or `⌘⇧P` |
| Task board | `⌘⇧B` |
| Project dashboard | `⌘⇧D` |
| File tree | `⌘⇧E` |
| Git panel | `⌘⇧G` |
| Session inspector | `⌘⇧I` |
| Swarm view | `⌘\` |
| Toggle the sidebar | `⌘B` |
| Split right | `⌘D` |
| Split down | `⌘⇧S` |
| Close the pane | `⌘⇧W` |
| Preferences | `⌘,` |
| Keyboard shortcuts | `⌘/` |

### In a session

Claimed while a terminal has focus. Everything else reaches the agent.

| Action | Keys |
|---|---|
| Find in the terminal | `⌘F` |
| Clear the terminal | `⌘⇧K` |
| Copy the selection | `⌘⇧C` |
| Interrupt the agent | `⌃C` *(passes through)* |
| Stop what the agent is doing | `Esc` *(passes through)* |

### In a dialog

| Action | Keys |
|---|---|
| Close | `Esc` |
| Confirm | `⌘↩` |
| Next item | `↓` |
| Previous item | `↑` |

## How it is put together

```
src/
  main/       Electron main process — owns every terminal process, and the
              git / fs / search / cost / github / readiness / mcp IPC modules
  preload/    the only bridge between renderer and main
  renderer/   React UI — components, dashboard, board, browser, layout
  shared/     types and branding used by both sides
```

Each main-process feature exports one `registerXIpc(ipcMain)` and is wired in
`src/main/index.ts`. Feature types stay in their own module and cross the bridge
as `unknown`; duplicating them into `shared/types.ts` only lets the two sides
drift apart.

Three decisions worth knowing before you change anything:

**Session status is read from a headless terminal, not the output stream.**
Agent CLIs are full-screen applications that repaint by moving the cursor, so
the tail of the byte stream bears no relation to the bottom of the screen. Each
session feeds a background emulator, and status is classified from its viewport.

**Sessions run with the login shell's PATH.** A GUI app on macOS inherits a
minimal PATH and genuinely cannot see `claude`. The real PATH is resolved once
by asking the login shell.

**The product name lives in one file for application code** —
`src/shared/brand.ts`. Every module that shows the name imports `BRAND`; none
of them types it out. Three places outside it hold the literal because nothing
there can import TypeScript: `package.json` (`productName`),
`electron-builder.yml` (bundle name and the macOS folder-access prompts) and
`src/renderer/index.html` (the window title, which is on screen before React
mounts). Two CSS file headers mention it in a comment. Renaming means editing
those by hand, which is what the note at the top of `brand.ts` is for.

Note that `BRAND.name` is `'Deck'`, not `'Terminal Deck'` — the UI calls itself
Deck, the bundle is called Terminal Deck.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) —
it covers running the app, the house rules this codebase is strict about, and
how to propose a change. By taking part you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

Found a security problem? Do not open an issue — see [SECURITY.md](SECURITY.md).

## Licence

MIT — see [LICENSE](LICENSE).

Third-party dependencies and their licences are inventoried in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
