# CLAUDE.md — working in this repo

Terminal Deck is an Electron desktop app for running AI coding-agent sessions.
Read [ROADMAP.md](ROADMAP.md) before starting anything — it tracks all 8 phases.

## Run & verify

```bash
npm run dev        # Electron + Vite, hot reloads the renderer
npm test           # vitest
npm run typecheck  # both tsconfigs — run this before claiming anything works
```

Main-process changes need a dev restart; renderer changes hot reload.

**Never** run `npm run build` while `npm run dev` is serving — they share `out/`
and the build clobbers what dev is running.

## Ground rules

**Never copy from a reference implementation.** Reading another tool to learn
*what* a feature does, or *what values* it settled on (sizes, timings,
thresholds), is fine — those are facts, not expression, and not copyrightable.
Copying its code, components, CSS blocks or assets is not, because that pulls
its licence and copyright notice permanently into this repo, which is exactly
what building fresh was meant to avoid. Every line here is written here.
Specific references consulted are listed in `REFERENCES.local.md`, which is
gitignored and stays on this machine.

**The name lives in one place.** `src/shared/brand.ts`. Never hardcode "Terminal Deck"
anywhere else.

**Verify against real data.** This codebase has repeatedly been wrong in ways
only real data exposed — the prompt glyph is `❯` not `>`, one API request emits
many JSONL lines with the usage repeated, a GUI app cannot see `claude` on PATH.
If you can check an assumption against something real on this machine, do it
before writing code that depends on it.

**Compiling is not working.** Two bugs shipped clean typechecks and clean console
output while being visibly wrong on screen. If a change is visible, look at it.

## Architecture

| Path | Owns |
|---|---|
| `src/main/` | terminal processes, all IPC modules, persistence |
| `src/preload/` | the only renderer↔main bridge; no raw ipcRenderer escapes |
| `src/renderer/` | React UI |
| `src/shared/` | types + branding used by both sides |

Each main-process feature exports one `registerXIpc(ipcMain)` and is wired in
`src/main/index.ts`. Feature types stay in their own module and cross the bridge
as `unknown` — duplicating them in `shared/types.ts` lets the two drift apart.

### Working in parallel

When several agents work at once, none may edit `src/main/index.ts`,
`src/preload/index.ts`, `src/renderer/App.tsx`, `src/shared/types.ts`,
`package.json` or `ROADMAP.md`. Create new files only and hand back wiring
instructions. This has run twice with zero conflicts.

## Style

2-space indent, no semicolons, single quotes, strict TypeScript, no `any`.
Comments explain *why*, not *what*. Co-locate tests as `*.test.ts`.
Use the CSS variables in `src/renderer/styles/tokens.css` — never raw hex.

## Design

The UI follows **Apple's HIG**, in a warm palette. `src/renderer/styles/tokens.css`
is the whole system and is commented; read it before writing any CSS.

- Every size, colour, radius, spacing, duration and easing comes from a token.
  Type is `--t-*` (macOS scale), spacing is `--sp-*` (8pt with 4pt half-steps),
  motion is `var(--dur…) var(--ease…)`.
- **Separate with space, then with a tint, and only then with a line.** The user
  asked for this in those words: "a lot of separations is not a good idea, it's
  not Apple style." A list of rows needs no rule between rows; a section needs no
  `border-top`; a card is a fill with a radius, not an outline.
- The shell is **one sidebar and one toolbar**. `shell/Sidebar.tsx` lists what is
  open, the ten project views, and Settings in the bottom-left;
  `shell/WindowToolbar.tsx` names the current view and holds its actions. There
  is no icon rail, no panel drawer and no tab strip — those were four pieces of
  chrome answering one question.
- Every floating surface (dialog, popover, menu, tooltip) wears the same glass:
  `--material-bg*` + `--material-sheen` + `--material-filter`. Transparency alone
  is not glass; the sheen is what makes it read as glass over an empty area.
- One accent, `--accent`, for selection, focus and the single primary button.
  Data keeps its meaningful colours (`--status-*`, `--color-*`) — never neutralise
  a chart.
- Both themes are first-class. Never define a colour only inside `[data-theme='dark']`.

## Verifying the UI without Electron

`.harness/` mounts the real `App` in a plain browser with a stubbed preload:

```bash
npx vite --config .harness/vite.config.ts   # serves on :5199
```

This is the only thing that has reliably caught the real defects. Typecheck and
tests both passed while the browser panel rendered nothing, because the failures
were contract mismatches and runtime throws, not type errors.

**Keep `.harness/stub.ts` honest.** It must mirror the preload's actual shapes —
`on*` methods return an unsubscribe function, everything else a promise. A stub
that disagrees with the preload invents bugs that do not exist and hides ones
that do; that happened three times in one session.

## Testing native modules in a packaged build

`node-pty` rewrites its `spawn-helper` path with
`helperPath.replace('app.asar', 'app.asar.unpacked')`. So a smoke test must
`require()` it through **`app.asar/node_modules/node-pty`**, never through
`app.asar.unpacked/...` — the latter rewrites to `app.asar.unpacked.unpacked`,
which does not exist, and node-pty reports it as `posix_spawnp failed`. That
error means "wrong helper path", not "broken binary". Run the smoke test under
the packaged app's own Electron:

    ELECTRON_RUN_AS_NODE=1 "/Applications/Terminal Deck.app/Contents/MacOS/Terminal Deck" smoke.js

`electron-builder.yml` excludes `node_modules/node-pty/prebuilds/**`. That is
deliberate: the x86_64 slice in there made macOS 28 refuse the arm64 bundle.
`build/Release/{pty.node,spawn-helper}` are what actually ship, and they are
enough — verified spawning through the asar.

## Never touch the copy someone is working in

Asad runs Terminal Deck on his own machines. Those installs are **his working
environment**, not a test rig, and an agent that stops, overwrites or reconfigures
one has interrupted somebody's actual work.

This has already happened. On 2026-08-17 an agent was told to "build, install and
launch on his machine" to verify Windows, and it did exactly that — replacing the
copy on his office PC with an unsigned local build at 07:29, and killing the
running processes to attach a debugger. Both were reasonable readings of the
instruction. The instruction was wrong.

**The rule: a test build never shares an install path or a user-data directory
with a copy a person uses.**

- **Always pass `--user-data-dir`** pointing at a scratch directory. This is
  honoured — `userDataFlag()` in `src/main/user-data.ts` exists so that
  `pinUserData` cannot overwrite it. A separate userData means separate sessions,
  settings, profiles, machines, hooks and remote identity, so nothing you do can
  reach his.
- **Never install over an existing install.** Unpack or install to a scratch
  path. On Windows the installed copy lives at
  `%LOCALAPPDATA%\Programs\Terminal Deck\` and its data at
  `%APPDATA%\terminaldeck` — leave both alone.
- **Never `Stop-Process` / `pkill` a Terminal Deck he might be using.** Launch
  your own instance instead. `requestSingleInstanceLock()` only collapses copies
  that share a userData directory, so a distinct `--user-data-dir` starts a
  genuinely separate process and leaves his window untouched.
- The **hook endpoint** is a socket inside userData, and a live one is refused
  rather than stolen, so two instances with separate data directories do not
  fight over it. That is only true while the data directories differ.

If a verification genuinely cannot be done without touching his install — say so
and stop. Do not decide on his behalf that the interruption is worth it.
