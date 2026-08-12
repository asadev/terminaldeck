# Pawl

A desktop workspace for running AI coding agents.

Run multiple Claude Code, Codex or Gemini sessions side by side, see at a glance
which ones are working and which are waiting on you, and know what they cost.

> **Name is provisional.** It lives in exactly one file — `src/shared/brand.ts` —
> so renaming is a single edit rather than a hunt.

---

## Why

Running agents in bare terminal tabs falls apart quickly. You lose track of which
session is mid-thought and which has been sitting on a question for ten minutes,
you have no idea what you have spent, and there is nothing between an agent and
your files when it decides to do something drastic.

## What works today

- **Multiple sessions per project**, each in its own terminal, with tabs and
  scrollback that survives switching away
- **Status at a glance** — every tab shows working / waiting / needs-input /
  exited, classified from what is actually rendered on the session's screen
- **Cost and context tracking** read from Claude Code's own transcripts, not
  scraped from the terminal
- **Session inspector** (`⌘⇧I`) — timeline, cost breakdown, tool usage, context meter
- **Git panel**, **file tree and viewer**, **quick open** and a command palette
- **Kanban board** and a **customisable dashboard** per project
- **GitHub panel** — open PRs and issues via the `gh` CLI
- **AI readiness score** with one-click fixes
- **Preferences** with live dark/light theming
- **Session resume** (`⌘⇧T`) — continue the project's last conversation

See [ROADMAP.md](ROADMAP.md) for what is still to come.

## Requirements

- macOS (Linux and Windows are not yet exercised)
- Node 22+
- At least one agent CLI installed and authenticated —
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Codex CLI or Gemini CLI

## Running it

```bash
npm install
npm run dev
```

Other commands:

```bash
npm test          # vitest
npm run typecheck # both tsconfigs
npm run build     # production bundle
```

## Shortcuts

| Action | Keys |
|---|---|
| Open a project | `⌘O` |
| New session | `⌘T` |
| Continue last session | `⌘⇧T` |
| Close session | `⌘W` |
| Jump to tab | `⌘1`–`⌘9` |
| Session inspector | `⌘⇧I` |
| Preferences | `⌘,` |

## How it is put together

```
src/
  main/       Electron main process — owns every terminal process,
              git/fs/search/cost/github/readiness IPC modules
  preload/    the only bridge between renderer and main
  renderer/   React UI — components, dashboard, board, layout
  shared/     types and branding shared across both sides
```

Two decisions worth knowing if you work on it:

**Session status is read from a headless terminal, not the output stream.**
Agent CLIs are full-screen apps that repaint by moving the cursor, so the tail of
the byte stream has no relationship to the bottom of the screen. Each session
feeds a background emulator and status is classified from its viewport.

**Sessions run with the login shell's PATH.** A GUI app on macOS inherits a
minimal PATH and genuinely cannot see `claude`, so it is resolved once by asking
the login shell.

## Licence

MIT — see [LICENSE](LICENSE).
