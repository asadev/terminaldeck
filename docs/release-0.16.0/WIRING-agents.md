# WIRING — lane `mcp-agents` (agents area of the MCP)

Branch `lane/0160-mcp-agents`. 58 tools for everything in
`src/main/deck-control/actions/agents.ts`, every one held behind
`tools.describe` (an `index` line each). All of them reach the app through the
one `DeckControl` as `extraTools`; nothing here is a second server.

## 1. `src/main/index.ts` — one import, one spread, one small lift

**Import** (beside the other deck-control imports, near line 148):

```ts
import { liveAgentsAreaTools } from './deck-control/agents-area-live'
```

**Lift the `providers:detect` body into a function** so the window and the
copilot's `agents.list` share it (today it is inline in the handler, ~line 2319).
Put this at module scope (anywhere after `core` and `wsl` exist, e.g. just above
`registerIpc`), and make the handler call it:

```ts
/**
 * Which agents are installed: the catalogue's, plus the ones somebody added.
 * Shared by `providers:detect` and the copilot's `agents.list`, so the picker and
 * the tool cannot disagree about what is startable.
 */
async function detectAllProviders(): Promise<Record<string, boolean>> {
  const builtin = await detectProviders(currentPlatform(), wsl.defaultTarget())
  const added = await Promise.all(
    core.agents.list().map(async (agent) => {
      const found = await lookupCommand(agent.command, currentPlatform())
      return [agent.id, found !== null] as const
    }),
  )
  return { ...builtin, ...Object.fromEntries(added) }
}
```

```ts
  ipcMain.handle('providers:detect', () => detectAllProviders())
```

**The spread** — at the end of the `extraTools: [ … ]` array passed to
`registerDeckControlIpc` (~line 4823, after the `serverTools(...)` line):

```ts
      /*
       * The agents area: agents and their controls, accounts, the agents' MCP
       * servers, hooks, routines, the app itself (about, logs, diagnostics,
       * updates, settings reset), setup and readiness, usage and cost, and
       * dictation. Every dep is the function the matching channel calls; see
       * `deck-control/agents-area-live.ts`.
       */
      ...liveAgentsAreaTools({
        agents: core.agents,
        controlAccess: core.controlAccess,
        routines: routines.api,
        updates: () => updates,
        describeSession: (id) => ptys.list().find((meta) => meta.id === id) ?? null,
        detectProviders: detectAllProviders,
        ipcMain,
      }),
```

Every name used there is already at module scope in `index.ts` (`core` ~817,
`ptys`/`wsl` ~1081, `routines` ~1130, `updates` ~592, `ipcMain` imported).
`agents-area-live.ts` imports Electron-side modules — **import it only from
`src/main/index.ts`**, never from `deck-control/index.ts` (the headless host
loads that one).

## 2. Optional, one line in `src/main/deck-control/control.ts`

`NOT_WHILE_DRIVING` already covers every `routines.*` tool by prefix. These
also change what the person is watching and are worth holding during a tour:

```ts
export const NOT_WHILE_DRIVING: readonly string[] = [
  'sessions.send',
  'sessions.start',
  'sessions.stop',
  'settings.write',
  'settings.reset',
  'agents.set_control',
  'accounts.sign_in',
  'updates.install',
  'tour.play',
  'routines.',
]
```

Left to the integrator because other lanes may add to the same list.

## 3. Headless host

None — this release is Mac only (coordinator, 2026-10-03).

## 4. Shared modules this lane changed (all additive or behaviour-preserving)

Where a channel's body was inline, it was lifted into a named export beside the
channel and the channel now calls it — so a click and a tool run the same code.

| File | Change |
|---|---|
| `src/main/mcp-client.ts` | exports `listMcpServers`, `editConfiguredMcpServer`, `mcpToolFile`, `connectMcpServer`, `disconnectMcpServer`, `mcpServerInventory`, `callMcpTool`; the `mcp:*` handlers call them |
| `src/main/cost-ipc.ts` | exports `readProjectCost`, `readSessionCost`, `listProjectTranscripts`; `cost:project/session/sessions` call them |
| `src/main/usage-ipc.ts` | exports `readSessionContext`; `usage:context` calls it |
| `src/main/voice.ts` | exports `saveCheckedVoiceKey`, `transcribeWithStoredKey`; `voice:save/transcribe` call them |
| `src/main/app-log-ipc.ts` | exports `recentLog`, `logStatus`, `openLogFolder`; `log:*` call them |
| `src/main/readiness.ts` | `FIX_IDS` exported (so `readiness.fix` accepts exactly what the channel does) |
| `src/main/redact.ts` | new `keepIdentity` option: secrets out, `/Users/<name>` paths left as they are (MCP args are read back and re-sent by `mcp.edit`) |
| `src/main/deck-control/catalogue.ts` | `requireKnownFolder` and `requireSession` exported; header paragraph on "routines and cost are absent" updated (they exist now) |
| `src/main/deck-control/actions/agents.ts` | every row decided; the six `nspeech:*` rows deleted (voice lane deletes the same six) |

**For the `accounts` lane:** every account operation goes through the
`accounts:` block in `agents-area-live.ts`, one closure per action. If a
signature moves, repoint it there. `list` rebuilds `profiles:list`'s private
`snapshot()` from exported pieces — if the rebuild exports a snapshot, point
`list` at it and delete those lines.

## 5. Catalogue budget

58 index lines, 4,479 characters, longest 89 → **+1,296 estimated tokens** on
the standing listing (built-ins + describe: 3,114 → 4,410; the full shipped
list ~5,844 → ~7,140, under the 8,000 ceiling on its own). With the other MCP
lanes adding their own index lines the shared token ceiling will need the
integrator's decision. `catalogue-cost.test.ts` measures a hand-written
`shipped()` list — add `agentsAreaTools(...)` to it when wiring (its own header
asks for exactly that); its pinned `cost.chars < 23_000` will then need moving
(~20,454 today + ~4,600 from this lane). Nothing advertised in full was added:
`agents-area.test.ts` pins that.

## 6. Tests

```
npx vitest run src/main/deck-control/agents-area.test.ts \
  src/main/deck-control/agents-area-control.test.ts \
  src/main/deck-control/{agent,account,mcp-server,hook,routine,app,setup,usage,voice}-tools.test.ts
```
