# WIRING — lane `mcp-machines` (0.16.0)

Machines, servers, paired devices and GitHub, as MCP tools. Everything lives in new
files under `src/main/deck-control/`; `src/main/index.ts` needs **one import and
three one-line edits**. Nothing else in the forbidden files changes.

## 1. `src/main/index.ts`

**a. Import** (with the other `./deck-control/…` imports, or beside
`import { serverTools } from './servers/tools'` at line ~92):

```ts
import { machineArea } from './deck-control/machine-area'
```

**b. In `send()`** (line ~405), as the **first** line of the body — before the
`quitting`/`rendererAlive` early return, because a tool needs the push even when no
window is open:

```ts
function send(channel: string, ...args: unknown[]): boolean {
  machineArea.tap.pushed(channel, args)
  if (quitting || !rendererAlive) return false
  …
```

**c. In `registerIpc()`** (line ~2232), immediately **after** the `traceIpc(...)`
line and before any `ipcMain.handle`:

```ts
  traceIpc(ipcMain, { enabled: () => storedValue(TRACE_SETTING) === true })
  // Keep every handler registered below reachable in-process, for the machines,
  // servers, devices and GitHub tools. See deck-control/channel-tap.ts.
  machineArea.tap.attach(ipcMain)
```

**d. In `extraTools`** (line ~4823), directly after the `serverTools` line:

```ts
      ...(servers === null ? [] : serverTools({ room: servers.room, grants: servers.grants })),
      ...machineArea.tools({ servers, userData: () => app.getPath('userData') }),
```

That is the whole wiring. `servers` is the module-level `ServersIpc | null`; when it
is null the four server-room tools are left out and the rest still load.

## 2. What the four edits do

- **The tap** (`channel-tap.ts`) wraps `ipcMain.handle`/`ipcMain.on` the way
  `ipc-trace.ts` already does, and keeps each handler in a Map — the headless
  `ChannelDesk` idea, beside Electron instead of instead of it. A tool calls
  `machines:connect` and runs the button's own code. No module's internals were
  exported and nothing was re-implemented.
- **`send()`** tells the tap about every main→window push, so a tool can wait for
  the push it is owed (the new session's id after `machines:create`, the far
  copilot's reply) instead of polling.
- **The watch** (`machine-watch.ts`, created with the area at module load) keeps a
  headless-terminal screen per remote session something here is attached to, sized
  from the window's own `machines:attach`/`machines:resize` calls, and the far
  copilot's conversation. Module-level so it hears the first attach.

## 3. Tools added (all `index`ed — behind `tools.describe`; zero advertised)

| Tool | Tier | Covers |
|---|---|---|
| `machines.look` | read | machine list + link state + sessions; one machine's host, logins, GitHub; one remote session's screen, controls, login, plan/context usage (never the 725 MB `refresh`) |
| `machines.session` | act → alter | start (returns the new id), send, keys, stop, rename, set control, switch-login, watch. `alter` for a session the copilot did not start; permission-mode and switch-login always `alter` |
| `machines.copilot` | act | read / say (optional wait for the answer) / start the far copilot |
| `machines.ports` | act | list / refresh / open-here / close-here / open-there |
| `machines.upload` | act → alter | send a file (alter), cancel (act). Refuses `~/.ssh`, `~/.aws`, `~/.gnupg`, keychains, userData… before any dialog |
| `machines.manage` | alter | pair, show-code, cancel-code, connect, disconnect, rename, forget, allow-windows, restart-host, stop-host, sign-in, sign-out, github-connect/cancel/disconnect. **`pair` drops the credential and guest private key the handler returns.** |
| `servers.details` | read | setup, host, ports, folder, start-in, grant, keys (names only), preview, shells, one shell's screen/controls/login |
| `servers.ports` | act | open-here, close-here, disconnect (`servers:close`), cancel-setup, cancel-host |
| `servers.manage` | alter | add (keyPath / `choose` / password — key read in place, never returned; password + passphrase redacted from the log), rename, forget, revoke, set-start-in, allow-windows, upload, install/sign-in/sign-out/remove agent, install/pair/link/remove host |
| `servers.shell` | alter (always) | open, type, keys, set, close — see §5 |
| `remote.status` | read | remote access on/relay, devices + kind + folders/logins/sessions/windows grants, connections, offered sessions, keep-awake, confinement; Tailscale only when asked, labelled optional |
| `remote.manage` | alter | start, stop, show-code, cancel-code, approve, revoke, set-folders/accounts/sessions/windows, disconnect, stop-tunnel, keep-awake |
| `github.look` | read | repo, overview/refresh (clears the cache first), sign-in status (a waiting device code is stripped) |
| `github.connect` | alter | connect (returns the github.com code), wait (≤2 min per call), cancel, disconnect |

`servers.look`, `servers.logs`, `servers.control` (`servers/tools.ts`) are unchanged
and still pinned at three by `no-run-tool.test.ts`.

**Catalogue cost:** +1,546 characters, **~442 estimated tokens** on every turn (14
index lines in the `tools.describe` description), no advertised tool added.
`catalogue-cost.test.ts`'s `shipped()` now includes the area (one line) so the
budget measures it; its pinned bound (`chars < 23,000`) still holds with this lane
alone — it will need the integrator's eye once all lanes are in.

## 4. Who may call them — one function to widen

Every tool in the area calls `hereOnly(caller)` (`area-shared.ts`) in its precheck:
**`caller.kind !== 'local'` is refused before any dialog**, the same line
`servers.control` already draws (surface.ts: a remote caller's effect may never
exceed what its own protocol frames permit, and a phone has no frame for reaching
other machines, servers or grants). **If lane `mcp-door`'s named access keys should
reach these tools, widen `hereOnly` — that one function — deliberately.** As
written, an outside AI on a non-`local` caller kind is refused for this whole area.

## 5. The server terminal (decision recorded)

`servers.shell` exists. It reverses `SERVERS-DESIGN.md` §6.1's "no `servers.run`"
for the terminal only, on these terms (pinned by `server-room-tools.test.ts`):
`alter` every call with no `escalate` and no grant ever consulted; the full line in
the dialog, anything over 1,000 characters refused before it; one line per call
(`sanitizeSendText`); local caller only; the description says it runs with the
account's full power and cannot be undone. Comments updated in
`servers/tools.ts`, `servers/setup.ts`, `servers/ipc.ts` and a dated note added to
`SERVERS-DESIGN.md` §6.1. A terminal a tool opens is **not drawn in the window**
(the renderer only draws shells it opened) — its screen is readable through
`servers.details about:"shell"`. Worth a renderer follow-up if Asad wants to watch.

## 6. Small additive change outside deck-control

`src/main/servers/ipc.ts` — `ServersIpc` gains `openShells()` and
`shellScreen(shellId)` (the existing per-shell shadow terminal, not a second one).
Purely additive; `servers/ipc.test.ts` unaffected.

## 7. Headless host — not wired (Mac-only release)

Per the owner's scope change, no `src/headless/*` wiring. For later: the headless
`ChannelDesk` already holds the same handlers, so `machineTools`/`remoteTools`
could take `channelCall(desk)` with a push hook on the headless broadcast.

## 8. Possible overlaps with other lanes

- `area-shared.ts` has a small named-key table (`NAMED_KEYS`). If `mcp-sessions`
  ships a `sessions.keys` table, keep one and point the other at it.
- `channel-tap.ts` is generic. If another lane built its own way to reach handlers
  in-process, keep one tap (`machineArea.tap` can be shared); two taps stacked on
  `ipcMain` also work, they just both observe.
