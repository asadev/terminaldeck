# WIRING — lane `mcp-sessions` (0.16.0)

Everything here goes in the two files this lane may not touch: `src/main/index.ts`
and `src/renderer/App.tsx`. Nothing in `preload`, `shared/types.ts` or `package.json`.
Headless host: **not wired** — the release is Mac-only (owner's scope change).

The lane's tools all come from one call, `sessionsLaneTools(parts)` in
`src/main/deck-control/sessions-lane.ts`. `parts` is only the things `index.ts`
holds; every other binding is inside that file, next to the module it calls.

---

## 1. `src/main/index.ts`

### 1a. Import

```ts
import { sessionsLaneTools } from './deck-control/sessions-lane'
```

### 1b. Hoist four things to module scope (they are needed after `registerIpc()` returns)

These are moves, not new behaviour: the handlers keep calling the same bodies.

**(i) The held-session retry and forget** — move the two handler bodies (around
`ipcMain.handle('session:held-retry', …)` and `'session:held-forget'`) into
module-level functions, and make the handlers call them:

```ts
/** Try a held session again, now. The body `session:held-retry` used to hold inline. */
async function retryHeld(key: unknown): Promise<HeldSession[]> {
  const held = typeof key === 'string' ? ledger.held.get(key) : null
  if (!held) return ledger.held.list()
  // … the existing body, unchanged, ending in:
  announceHeld()
  return ledger.held.list()
}

/** Stop holding one. The body `session:held-forget` used to hold inline. */
function forgetHeld(key: unknown): HeldSession[] {
  if (typeof key === 'string' && ledger.held.release(key)) announceHeld()
  return ledger.held.list()
}

// in registerIpc():
ipcMain.handle('session:held-retry', (_e, key: unknown) => retryHeld(key))
ipcMain.handle('session:held-forget', (_e, key: unknown) => forgetHeld(key))
```

(`HeldSession` is exported from `./session-held`.)

**(ii) The deferred account switch** — move `const pending = new PendingSwitches()`
out of `registerIpc()` to module scope (beside `sessionSwitch`), and the three
handler bodies with it:

```ts
const pending = new PendingSwitches()

async function armSwitchLater(sessionId: unknown, profileId: unknown) {
  const { plan } = await sessionSwitch.subject(sessionId, profileId)
  if (plan.refusal !== null || plan.to === null) {
    throw new Error(plan.refusal ?? 'This session cannot be switched.')
  }
  const armed = pending.arm({ sessionId: plan.sessionId, profileId: plan.to.id, accountName: plan.to.name, plan })
  return { sessionId: armed.sessionId, profileId: armed.profileId, note: armedNote(armed) }
}

function armedSwitches() {
  return pending.list().map((armed) => ({
    sessionId: armed.sessionId,
    profileId: armed.profileId,
    accountName: armed.accountName,
    note: armedNote(armed),
  }))
}

// in registerIpc(), the handlers become:
ipcMain.handle(SESSION_SWITCH_LATER_CHANNEL, (_e, sessionId: unknown, profileId: unknown) => armSwitchLater(sessionId, profileId))
ipcMain.handle(SESSION_SWITCH_CANCEL_CHANNEL, (_e, sessionId: unknown) => typeof sessionId === 'string' && pending.cancel(sessionId))
ipcMain.handle(SESSION_SWITCH_ARMED_CHANNEL, () => armedSwitches())
```

`fireSwitch` and the `session:write` / `session:kill` handlers keep using `pending`
exactly as now — it is the same object, one scope further out.

**(iii) The copilot's two deps objects** — the object literal passed to
`registerCopilotIpc(ipcMain, { … })` and the one passed to
`registerCopilotInspectIpc(ipcMain, { … })`. Give each a name and pass the name:

```ts
let copilotRuntimeDeps: CopilotRuntimeDeps | null = null   // module scope
let copilotInspectDeps: CopilotInspectDeps | null = null   // module scope

// in registerIpc():
copilotRuntimeDeps = { startSession: …, isAlive: …, /* the existing literal */ }
registerCopilotIpc(ipcMain, copilotRuntimeDeps)
copilotInspectDeps = { userData: …, home: …, revealInFileManager: … /* the existing literal */ }
registerCopilotInspectIpc(ipcMain, copilotInspectDeps)
```

(`CopilotRuntimeDeps` from `./copilot-session`, `CopilotInspectDeps` from `./copilot-inspect`.)

**(iv) The dev-server opener** — the `open` closure passed to
`registerDevServerIpc(ipcMain, { … open: … })`:

```ts
/** A plain shell in a folder, for a dev server. The opener `dev:server:start` uses. */
const openDevServerSession: SessionOpener = async (folder) => {
  const meta = await startSession({ cwd: folder, cols: 120, rows: 30, provider: 'shell' })
  return { ok: true, sessionId: meta.id }
}
// registerDevServerIpc(ipcMain, { …, open: openDevServerSession, … })
```

### 1c. The one `extraTools` entry

In `registerDeckControlIpc(ipcMain, { … extraTools: [ … ] })`, add (anywhere in
the list — after `serverTools` is fine):

```ts
      /*
       * The rest of driving a session, projects, files, the copilot's own
       * management and the window's clicks — lane mcp-sessions. Every binding is
       * in `deck-control/sessions-lane.ts`, beside the module it calls; what is
       * passed here is only what this file holds.
       */
      ...(copilotRuntimeDeps === null || copilotInspectDeps === null
        ? []
        : sessionsLaneTools({
            ptys,
            announceRenamed: (id, title) => {
              // What `session:rename` does after the rename, for a rename the
              // window did not make: the row, the devices, the dialled machines.
              send(SESSION_RENAMED_CHANNEL, id, title)
              remoteLayer?.server.sessionsChanged()
              machinesIpc?.announceSessions()
            },
            held: { list: () => ledger.held.list(), retry: retryHeld, forget: forgetHeld },
            sessionSwitch,
            laterSwitches: {
              later: (sessionId, profileId) => armSwitchLater(sessionId, profileId),
              cancel: (sessionId) => pending.cancel(sessionId),
              armed: () => armedSwitches(),
            },
            tellSwitched: (oldId, meta, accountName) =>
              send(SESSION_SWITCHED_CHANNEL, oldId, meta, switchedNote(accountName, false, '')),
            copilotDeps: copilotRuntimeDeps,
            copilotInspectDeps,
            devServers,
            devServerOpener: openDevServerSession,
            stageDir: () => join(app.getPath('downloads'), BRAND.name),
            home: () => wsl.home() ?? app.getPath('home'),
            window: () => mainWindow,
            deckControl: () => deckControl,
          })),
```

`SESSION_RENAMED_CHANNEL` is already imported from `./live-push`;
`SESSION_SWITCHED_CHANNEL` and `switchedNote` from `./switch-later` (add
`switchedNote` to that import if it is not there).

### 1d. Strongly recommended: route the copilot's typing through the window's typing path

`sessions.send` / `sessions.keys` write through `DeckSurface.writeToSession`, which
is `ptys.write` — so they skip what `session:write` does on the way: `ledger.touch`
and, more importantly, **`pending.observe`, which is where a deferred account
switch fires**. As wired today, `sessions.account {action:"later"}` followed by
`sessions.send` would never fire the switch. Fix: lift the `session:write` handler
body into a module-level function and hand deck-control a `ptys` whose `write` is it:

```ts
function typeIntoSession(id: string, data: string): void {
  ledger.touch(id)
  const action = pending.observe(id, data)
  if (action.kind === 'switch') {
    if (action.before !== '') ptys.write(id, action.before)
    void fireSwitch(action.armed, action.line, action.submit)   // fireSwitch moves to module scope with `pending`
    return
  }
  ptys.write(id, data)
}
// ipcMain.on('session:write', (_e, id: string, data: string) => typeIntoSession(id, data))

// registerDeckControlIpc(ipcMain, {
//   ptys: { list: () => ptys.list(), write: typeIntoSession, kill: (id) => ptys.kill(id),
//           screen: (id) => ptys.screen(id), scrollback: (id) => ptys.scrollback(id) },
//   …
```

The two-write send (text, gap, Enter) is exactly the shape `pending.observe` sees
from a person, so the switch fires on the Enter as it does for them.

---

## 2. `src/renderer/App.tsx`

Three imports beside the existing settings-schema import, and one block right after
`useEffect(() => window.deck.onMenuCommand((command) => void run(command)), [run])`.
**Verified in the harness** (real `App`, stubbed preload, headless Chromium): `list()`
returned 26 commands / 4 sessions / 11 sections; `run view.files` → toolbar title
"Files"; `run view.git` → "Source control"; `focus <id>` → back to "Session 1";
`settings agents` → Settings open at Coding AI; an unknown id → `ok:false`; no page errors.

```diff
-import { booleanSetting, numberSetting, stringSetting } from './settings/settings-schema'
+import { booleanSetting, numberSetting, sectionsFor, stringSetting } from './settings/settings-schema'
+import { publishUi, type UiHandlers } from './driving/ui-bridge'
+import { detectPlatform } from './platform'
```

```tsx
  useEffect(() => window.deck.onMenuCommand((command) => void run(command)), [run])

  /*
   * The window's own clicks, for an AI that is not in front of it — `ui.do` and
   * `ui.list` in `main/deck-control/ui-tools.ts`. One ref kept current on every
   * render and published once, so the bridge always reads this render's
   * commands; see `driving/ui-bridge.ts`.
   */
  const uiHandlers = useRef<UiHandlers | null>(null)
  uiHandlers.current = {
    commands: () => commands,
    run,
    sessions: () => sessions.map((session) => ({ id: session.id, title: session.title })),
    focusSession: (id) => openTabWindow(id),
    // The rail's own rule (`SettingsWindow.tsx`): this platform's sections, less
    // the ones whose feature is not installed.
    sections: () =>
      sectionsFor(detectPlatform())
        .filter((entry) => features.sectionOn(entry.id))
        .map((entry) => entry.id),
    openSettings: (section) => openSettings(section as SectionId),
    addProject: (path) => {
      addProject(path)
    },
  }
  useEffect(() => publishUi(() => uiHandlers.current), [])
```

---

## 3. Things the integrator should know

1. **Catalogue cost.** All 32 lane tools carry an `index` line; none is advertised in
   full, so the advertised tool count does not change. The lane adds
   **3,526 characters ≈ 1,010 estimated tokens** to `tools.describe`'s index
   (measured: built-ins alone 3,209 → 4,226 tokens). The shipped list was
   ~5,844 tokens, so this lane alone takes it to ~6,860 of 8,000; with three more
   tool lanes the index will pass the ceiling. That is the progressive-disclosure
   question for lane `mcp-door` (`tools.run`, or grouping the index by area) —
   not solved here, and no ceiling was raised.
2. **`sessions.send` bug fixed in `catalogue.ts`.** It wrote `text + '\r'` in one
   write — a paste to the agent CLIs, never submitted for a real prompt (the bug
   class of commit 4bde795). Now two writes with the measured 50ms gap, via
   `session-typing.ts` (which reuses `replayWrites`). Two expectations in
   `control.test.ts` were updated from one write to two.
3. **`sessions.start` takes `account`** (name or id, checked against `listProfiles`
   through a new optional `DeckSurface.accounts()`; unknown names refused with the
   list, because `resolveProfileId` silently falls back to the default). It also
   returns `sentAt` from `sessions.send` for `sessions.wait`.
4. **`NOT_WHILE_DRIVING`** (control.ts) gained `sessions.keys`, `sessions.rename`,
   `sessions.account`, `sessions.held`, `ui.do`, `copilot.run`.
5. **Small refactors outside new files**, each so a tool and a channel share one
   body: `deck-status.ts` now composes `deck-control:status` (index.ts handler
   calls it); `revealCopilotPlace` extracted from the `copilot:reveal` handler;
   `pathsOf` exported from `copilot-inspect.ts`; `copilotLayerPaths` exported from
   `copilot-session.ts`; `str/optStr/optInt/optBool/record`, `knownFolders`,
   `requireKnownFolder`, `requireSession` exported from `catalogue.ts`.
6. **`sessions.wait` cannot be cancelled by a client hang-up** — `ToolContext` does
   not carry the call's `AbortSignal`. It is bounded (default 40s, max 240s, under
   the server's 300s request timeout). Passing `signal` into `ToolContext` in
   `control.ts` would let it stop early; not done to keep out of mcp-door's way.
7. **`files.upload` is capped at 160 KB** because `server.ts`'s `MAX_BODY_BYTES` is
   256 KB. If mcp-door raises the body ceiling, raise `MAX_UPLOAD_BYTES` in
   `files-tools.ts` with it.
8. **Model choice at start** is not in `sessions.start`: the app has no model field
   on `CreateSessionInput`; the model is set after start through the agent
   controls (`agent:controls:*`, lane `mcp-agents`).
9. `actions.test.ts` "has decided every one" still fails on the **other** lanes'
   nulls; the sessions area has none (pinned by `sessions-lane.test.ts`).
