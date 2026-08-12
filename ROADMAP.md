# Pawl — Build Plan

Target: full feature parity with Vibeyard, built fresh.
Reference scope: 27 feature areas, ~36,400 lines of non-test TypeScript, 258 files.

**Ground rule:** features and functional values (dimensions, colours, timings,
behaviour) are matched freely — they aren't copyrightable. Their components, CSS
and icon artwork are never copied, because that would pull their MIT licence and
copyright notice permanently into this repo.

Status key: `[x]` done · `[~]` in progress · `[ ]` not started

---

## Phase 1 — Foundation `[x]`

Everything else sits on this.

- [x] Electron 41 + React 19 + TypeScript, electron-vite
- [x] `PtyManager` — process ownership, scrollback replay across tab switches
- [x] Provider layer — Claude / Codex / Gemini detection, login-shell PATH
- [x] Sidebar (projects → sessions), tab bar, status dots, empty state
- [x] Design tokens, dark + light, self-hosted open-licensed fonts
- [x] JSON store, atomic writes, projects + window bounds persist
- [x] CSP from main process — strict in prod, dev-permissive
- [x] Visual verification pass — screenshotted running, a live Claude session
      inside it, status dots and light/dark both confirmed by eye

## Phase 2 — Session intelligence

Turns a terminal multiplexer into something that understands agents.

- [x] **Status detection** — classifies working / waiting / needs-input /
      exited from output, in the main process so it works for unrendered tabs.
      12 tests; verified against a real PTY.
- [x] **Provider picker** — per-session choice, per-project default, global default
- [x] **Session resume** — `claude --continue`, `codex resume --last`
- [x] **Preferences modal** — theme, default provider, notifications, restore-on-launch
- [x] **Live re-theming** — terminals recolour without restart
- [x] **Desktop notifications + sounds** on completion / input needed
- [x] **Session titles** — derive from the task rather than the folder name
- [x] **Unread indicators** — output arrived on a background tab

## Phase 3 — Cost, context and telemetry

Claude Code writes JSONL transcripts under `~/.claude/projects/`. That is the
data source for all of this — no scraping of terminal output.

- [x] **Transcript watcher** — tail the JSONL per session
- [x] **Cost tracking** — spend per session / project / day
- [x] **Token + context-window monitoring** with a bloat warning
- [x] **Session inspector** (⌘⇧I) — timeline, cost breakdown, tool-usage stats
- [ ] **Deep session search** across past transcripts
- [ ] **Smart alerts** — missing tools, context bloat, session health

## Phase 4 — Project workspace

- [x] **Git status watcher** + git panel (branch, dirty files, diff view)
- [x] **File tree** + file viewer with syntax highlighting
- [x] **Quick open** (⌘P) and command palette (⌘K)
- [x] **GitHub integration** via `gh` — PRs, issues, discussions, unread badges
- [x] **AI Readiness score** — does the project have CLAUDE.md, tests, lint,
      typecheck, a clean git state — with one-click fixes
- [ ] **Ignore file** (`.pawlignore`) honoured by tree, search and watchers

## Phase 5 — Dashboard and board

- [x] **Customisable project overview** — drag-and-drop widget grid (gridstack)
- [x] **Widgets** — AI Readiness, Kanban, Sessions, Team, Provider Tools, GitHub
- [x] **Kanban board** — per project, drag-drop, search, tag filter
- [ ] **Board ↔ session link** — a card spawns or resumes a session; the card
      moves to Done when that session completes

## Phase 6 — Multi-session power features

- [x] **Swarm mode** — grid view of every running session (⌘\)
- [x] **Split panes** with focus routing
- [ ] **Multiple Claude profiles** — isolated `CLAUDE_CONFIG_DIR` per profile so
      work and personal logins never mix; per-session / per-project / global default
- [ ] **Full keymap** + shortcut reference sheet

## Phase 7 — Integrations

- [ ] **Hooks** installed into each provider's settings, namespaced `pawl-hook`
      so they never collide with Vibeyard's on the same machine
- [ ] **MCP client** + inspector, add/edit servers
- [ ] **Embedded browser tab** — load a URL, inspect elements, send the selector
      and text back to the agent as context
- [ ] **Chrome import** — pull existing config

## Phase 8 — Ship

- [ ] **P2P session sharing** — WebRTC, PIN auth, read-only / read-write
- [ ] **Auto-updater** pointed at our own releases
- [ ] **i18n** + locale files
- [ ] **Packaging** — dmg, code signing, notarisation
- [ ] Icon and brand assets (original, not theirs)

---

## Sequencing logic

Phase 2 before 3 because status detection is what the inspector visualises.
Phase 3 before 5 because the dashboard widgets display cost and readiness data.
Phase 6 after 4 because split panes need the file tree and git panel to be
worth splitting to. Phase 8 last — sharing and updates only matter once there
is something worth sharing and updating.

## Open questions for Asad

- Final name (currently `Pawl`, isolated in `src/shared/brand.ts`)
- Whether to publish, and if so whether to credit Vibeyard as prior art
- Whether P2P sharing is wanted at all — it is the single biggest feature and
  the only one needing infrastructure

## Tracked follow-ups

- **Chunked JSONL reader is duplicated three times** — `transcript.ts`,
  `session-insights.ts` and `session-search.ts` each carry their own 4MB +
  StringDecoder read loop. Flagged by the search agent, which could not fix it
  (that wave was create-only). Should be lifted into one `streamLines` helper.
  Not urgent: all three are tested and working, and refactoring them carries
  regression risk for no user-facing gain.
- **Escape-to-close on modals is unconfirmed** — the code is correct, but
  synthetic keypresses were not delivered during testing, so it needs a real
  human keypress to verify.
