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

**Never copy from the reference.** `/Users/apple/Projects/_reference/vibeyard-ref`
is a competitor's MIT-licensed app kept for reference only, deliberately outside
this repo. Reading it to learn *what* a feature does or *what values* it uses
(sizes, timings, thresholds) is fine — those are not copyrightable. Copying its
code, components, CSS blocks or assets is not, because that pulls its licence and
copyright notice permanently into this repo. Write every line here.

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
