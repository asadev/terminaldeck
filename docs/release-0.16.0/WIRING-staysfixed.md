# WIRING — Stays Fixed inside Terminal Deck (lane `staysfixed-in-deck`, 0.16.5)

Stays Fixed (the owner's own regression safety net, npm `staysfixed`, MIT) is
built into the app: a **Stays Fixed** page under **Project** in the sidebar,
`fixed.*` tools for Hoot and outside AI apps, and its MCP server handed to every
agent session started in a set-up project. Everything is new files except the
small edits listed under "Already committed". Five things need the integrator,
because they are in files lanes may not edit.

## 1. `package.json` — the dependency (pinned, exact)

```sh
npm install staysfixed@0.15.0 --save-exact
```

which writes this into `dependencies` (and the matching lines into
`package-lock.json`):

```json
"staysfixed": "0.15.0"
```

Exact, not `^0.15.0`. The app reads files the engine writes
(`.staysfixed/v2/last-check.json`) and imports two of its modules by path for
progress (`src/v2/check.js`, `src/v2/run.js`); `src/shared/stays-fixed.ts`
holds the same version and the page says so in a sentence if they ever differ.
It pulls three packages and **no browser**: `playwright-core` 1.63.0 (13 MB),
`pngjs` 7.0.0, `pixelmatch` 7.2.0 — about 18 MB with Stays Fixed itself. Then
`npm install` (it is pure JavaScript; nothing to rebuild).

## 2. `src/main/index.ts` — four insertions

**Imports**, beside `import { deviceTools } from './deck-control/device-tools'`:

```ts
import { fixedTools } from './deck-control/fixed-tools'
import { createStaysFixed, fixedToolDeps, registerStaysFixedIpc } from './staysfixed/ipc'
```

**The one instance**, on the line immediately before `const core = createHostCore({`:

```ts
/*
 * Stays Fixed — one instance for the page, the tools and the session launcher,
 * so one check per project holds whoever asks. See `staysfixed/ipc.ts`.
 */
const staysFixed = createStaysFixed(send)
```

**The session launcher**, inside the `createHostCore({ … })` options (anywhere
at the top level of that object; beside `sessionTools` reads best):

```ts
  /*
   * Stays Fixed's MCP server for agent sessions started in a project that is
   * set up with "Give agents Stays Fixed" on — Claude Code, Codex and Gemini,
   * each on its own command line or environment, written into none of their
   * own settings files. `staysfixed/agents.ts` has how each one takes it.
   */
  projectTools: { launch: (provider, cwd) => staysFixed.agentLaunch(provider, cwd) },
```

**The channels**, immediately after `registerDevicesIpc(ipcMain)`:

```ts
  registerStaysFixedIpc(ipcMain, staysFixed)
```

**The tools**, as the last entry of `extraTools`, after the
`sessionsLaneTools(...)` spread (the `])),` that follows
`deckControl: () => deckControl,`):

```ts
      /*
       * A project's Stays Fixed page, as tools: status, set up, check, results,
       * stop, mark good (always asks the owner), and the agents' switch.
       */
      ...fixedTools(fixedToolDeps(staysFixed)),
```

`assembled-catalogue.fixture.ts` already lists `fixedTools` in that position.

## 3. `src/preload/index.ts` — nine methods

After the Simulators block (after `onDeviceClosed`), before `/* ---- links -- */`:

```ts
  /* ------------------------------------------------------- stays fixed -- */

  /**
   * A project's Stays Fixed page — `src/main/staysfixed/ipc.ts` has every
   * channel and what it answers. `staysfixed:changed` carries only the folder;
   * the page asks for the status again, so there is one shape of the truth.
   */
  staysFixedStatus: (projectPath: string): Promise<unknown> => ipcRenderer.invoke('staysfixed:status', projectPath),
  staysFixedReadiness: (projectPath: string, refresh: boolean): Promise<unknown> =>
    ipcRenderer.invoke('staysfixed:readiness', projectPath, refresh),
  staysFixedSetup: (projectPath: string): Promise<unknown> => ipcRenderer.invoke('staysfixed:setup', projectPath),
  staysFixedCheck: (projectPath: string): Promise<unknown> => ipcRenderer.invoke('staysfixed:check', projectPath),
  staysFixedStop: (projectPath: string): Promise<unknown> => ipcRenderer.invoke('staysfixed:stop', projectPath),
  staysFixedResults: (projectPath: string, full: boolean): Promise<unknown> =>
    ipcRenderer.invoke('staysfixed:results', projectPath, full),
  staysFixedMarkGood: (projectPath: string, anyway: boolean): Promise<unknown> =>
    ipcRenderer.invoke('staysfixed:mark-good', projectPath, anyway),
  staysFixedAgents: (projectPath: string, on: boolean): Promise<unknown> =>
    ipcRenderer.invoke('staysfixed:agents', projectPath, on),
  onStaysFixedChanged: (cb: (projectPath: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, projectPath: string) => cb(projectPath)
    ipcRenderer.on('staysfixed:changed', handler)
    return () => ipcRenderer.off('staysfixed:changed', handler)
  },
```

Nothing in `shared/types.ts` (`DeckApi`): the page reaches these through its own
`StaysFixedBridge` (`renderer/staysfixed/bridge.ts`), the pattern the AI apps
pane uses, and `preload/contract.test.ts` matches the two.

**Until sections 2 and 3 are applied, three tests fail, and each is that
test noticing the wiring is missing:** `deck-control/actions/actions.test.ts`
(the eight `staysfixed:*` channels are *stale* — the table is ahead of the
preload), `preload/contract.test.ts` (`StaysFixedBridge` names nine methods the
preload does not expose yet) and `reachable.test.ts` (the eight new main-process
modules are not imported by `index.ts` yet). With both sections applied in this
worktree all three pass, together with the rest of `deck-control/`, `shell/`,
`features/`, `preload/` and the host-core suites (104 files, 1,722 tests);
the wiring was then reverted so this branch touches no forbidden file.

## 4. `electron-builder.yml` — already committed in this lane

Four folders are added to `asarUnpack`:

```yaml
  - '**/node_modules/staysfixed/**'
  - '**/node_modules/playwright-core/**'
  - '**/node_modules/pngjs/**'
  - '**/node_modules/pixelmatch/**'
```

Why each, exactly:

- **`staysfixed`** — its command line is an ES module that this app's
  executable runs *by path* as Node (`ELECTRON_RUN_AS_NODE=1`). Node's ESM
  loader cannot load a module out of an asar archive. It also hands its own
  files to other programs: a JavaScript file to macOS's `osascript` (native Mac
  checks), its export probe to a child Node, a driver script over ssh — none of
  which can read inside an archive. `engine.ts` refuses a copy found only inside
  `app.asar` with a sentence naming the missing packaging step.
- **`playwright-core`** — it starts browsers and reads its own files by path;
  and Node resolves `import 'playwright-core'` from the *unpacked* staysfixed by
  walking up `app.asar.unpacked/node_modules`, which never looks inside the
  archive. Left packed, every website check would fail to find its driver.
- **`pngjs`, `pixelmatch`** — the same resolution rule: imported by the
  unpacked staysfixed, so they must sit beside it in `app.asar.unpacked`.

No fuse change is needed: the app already relies on `ELECTRON_RUN_AS_NODE`
(WSL bridge) and does not flip the `RunAsNode` fuse.

## 5. Headless host (`src/headless/`) — optional, not wired

The headless host runs the same `createHostCore` and could pass the same
`projectTools` seam, but it has no window to show the page and no userData
folder layout the shim relies on yet. Leaving it unwired is safe: an absent
seam launches every session exactly as before. To wire it later: build a
`StaysFixedService` with the host's data folder, `locateEngine({ resourcesPath:
null, appPath: <host package root> })`, `executable: process.execPath` (plain
Node there, so the shim is unnecessary but harmless), and pass
`projectTools: { launch: (p, cwd) => service.agentLaunch(p, cwd) }`; add
`...fixedTools(fixedToolDeps(service))` to `src/headless/copilot.ts`'s
DeckControl so a phone's Hoot gets the tools too. The headless package's own
`package.json` would need `staysfixed` as well.

## Already committed in this lane (not forbidden files)

- `src/main/host-core.ts` — the `projectTools` seam on `HostCoreOptions` and
  its three uses in `startSession` (gate, `composed`, `profileEnv`). Absent seam
  = no change to any launch. Pinned by `host-core.project-tools.test.ts`.
- `src/renderer/shell/panels.ts` — `'staysfixed'` in `PanelId` and its row,
  last in the Project run; `PanelView.tsx` — the page, below the project gate,
  and in `SCOPED_PANELS`; `HelpPanel.tsx` — its line in "The views".
- `src/main/deck-control/describe-tool.ts` — `fixed` under the `sessions` area
  (projects, files, git… "and Stays Fixed checks").
- `src/main/deck-control/actions/index.ts` — the `fixed` table;
  `coverage-tool.test.ts` — the area list now includes it.
- `.harness/stub.ts` — spreads `.harness/staysfixed-stub.ts`.

## Not routed through the notification queue — on purpose

The brief asked for check results to reach whoever ran the check through the
door lane's `notifications` queue "if that fits cleanly". It does not:
`NotificationEvent` is a *session* event (a `sessionId`, and three session
types that `mcp-events.ts` maps one-to-one onto ChatGPT event names, with a
schema enum and a loader that drops any other type). A check is not a session,
and a fourth type would change three of that lane's files and the event names
ChatGPT subscribes to. Instead the result reaches its caller the long-poll
way, which is the same mechanism `notifications.wait` uses: `fixed.check`
waits up to 45 s (max 120, inside the relay's 150 s), and `fixed.results` with
`wait` collects a check that outlasted the call. Hoot gets the answer as the
tool result. An agent session gets it from Stays Fixed's own `staysfixed_check`
reply. The page gets every step and the end through `staysfixed:changed`.

## Proof (what was run, and where)

All on the Mac mini, 2026-10-04, against the real `staysfixed` 0.15.0.

1. **Automated, real engine** — `src/main/staysfixed/service.test.ts` runs the
   owner's whole loop on a fresh two-file git project: set up → first check
   ("nothing to compare against yet") → mark good → change `toFixed(2)` to
   `toFixed(1)` → check shows **exactly one** difference, `Total: 10.00` →
   `Total: 10.0`, flagged as money → mark good refused for it → mark good
   anyway → check clean → agents' switch on/off. 9/9 pass (~24 s).
   `engine.test.ts` runs the preload, the Node shim, the picture-keeping hook,
   the guards reader and the check script for real (15/15).
2. **Harness** — `?sf=notsetup|nogit|unavailable|clean|differences|running`,
   built from the captured engine JSON through the real reader, light and dark,
   every button pressed through (set up → check → mark → refused → anyway →
   full report).
3. **Scratch Electron** — this worktree's `npm run build`, the wiring above
   applied locally (and reverted before commit), launched with its own
   `--user-data-dir` and driven over the DevTools port: Stays Fixed row →
   Set up → Run check → Mark good → regression → only that difference →
   refused → anyway → clean → Full report, in 55 s. Killed at once (process
   group SIGTERM/SIGKILL; none left). `~/.claude/settings.json`,
   `~/.codex/hooks.json`, `~/.codex/config.toml` sha256 identical before and
   after; `~/.gemini/settings.json` does not exist on this Mac.
   *Do not* run a scratch copy with `HOME` pointed elsewhere: tried first, the
   app hung before drawing a window (the keychain lives under the real home).
4. **Packaged app** — `electron-builder --mac dir:arm64 -c.mac.identity=-`
   (ad-hoc signed, hardened runtime, the app's own entitlements;
   `codesign --verify --deep --strict` passes; there is no Developer ID
   Application identity on the Mac mini, so a Developer-ID-signed run was not
   possible here). The four folders are in `app.asar.unpacked/node_modules`.
   The whole loop ran again through `Terminal Deck.app/Contents/MacOS/Terminal
   Deck` as Node, with a stranger's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`, no
   Node anywhere) — the project's own `node ./greet.js` ran on the app's Node
   through the shim — with identical results. The agents' MCP server was then
   started from the packaged app exactly as a session's config says: it
   answered `initialize` (`staysfixed` 0.15.0), listed its seven tools, and ran
   `staysfixed_check`. The release folder was deleted afterwards.

## For Stays Fixed itself (a note, not a change here)

`staysfixed init`'s `.gitignore` lines leave `check-log.json`,
`escalations.json`, `references.json` and `reference-log.json` under
`.staysfixed/v2/` untracked, so the first check makes the working tree dirty
and every build after it is named "1.0.0 with uncommitted changes" (seen in the
page's "Good build:" line). Whether those files are meant to be committed is
Stays Fixed's call; recorded here for its own repository, not worked around.
