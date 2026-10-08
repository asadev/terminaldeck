# Servers setup, host and window operations handoff

Source evidence: 6 October 2026, 16:51 Dubai. Local source only. No build, test,
CLI probe, connection, credential access, app launch, live-data change, install,
commit or release was performed. This scoped worker created only its assigned
new files. Root owns `BackendServersIPC*`, `BackendServersCoordinator*` factories
and `macos/handoffs/servers-HANDOFF.md`.

## Source coverage

| Authoritative TypeScript module | Native files and operation owner |
| --- | --- |
| `servers/agent-signin.ts` | `BackendServersAgentSignin.swift`: shared version/environment/login shell snippets consumed by probe and setup |
| `servers/setup.ts` | `BackendServersSetup.swift`: `BackendServersSetupRules`, `BackendServersSetups`; `BackendServersSetupSupport.swift`: event tape and cancellation cleanup |
| `servers/setup-tunnel.ts` | `BackendServersSetupTunnel.swift`: real Network loopback listener and raw SSH duplex pump, same port on both ends |
| `servers/host-package.ts` | `BackendServersHostPackage.swift`: both bundled receipts required; packaged resources preferred; no registry substitution |
| `servers/host.ts` | `BackendServersHost.swift`: `BackendServersHosts`; `BackendServersHostRules.swift`: state/parser/refusals/consequences/version rule; `BackendServersHostScripts.swift`: probe, service/start/remove scripts |
| `servers/window-belong.ts` | `BackendServersWindowBelong.swift`: private per-shell hook config, settings, opener/poster scripts and remote context files |
| `servers/window-drive.ts` | `BackendServersWindowDrive.swift`: help/scout/wrapper/heredoc parsing/scripts and `BackendServersWindowDrives` |
| `servers/window-reach.ts` | `BackendServersWindowReach.swift`: proof before activation, separate control/hook endpoint shapes, exact refusal text; byte transport uses shared `BackendServersSSHReverse.swift` |

All eight assigned source modules have operation bodies. Eleven Swift source
files and three test files were created. `BackendServersSetupTests.swift` has 13
tests, `BackendServersHostTests.swift` has 11, and `BackendServersWindowTests.swift`
has 12: 36 written, 0 run. These consolidate the nonlive source tests into
contract groups for refusal thresholds, public-login metadata, scratch removal,
PTY sentinels, early pairing output, fingerprint mismatch, bounded retries,
package receipts, file schemas, server ownership and binding proof.

## Exact public APIs for root wiring

- `BackendServersAgentSignin.agentEnvProbe`, `.agentVersionAWK`,
  `.readAgentEnv(from:codexHome:geminiEnv:)`,
  `.signInSnippet(_:binary:state:account:codexHome:geminiEnv:)`,
  `.signInCases(agentVar:binary:state:account:codexHome:geminiEnv:)` are the
  single public login-shell snippets. Probe must call them, rather than carry
  another private copy.
- `BackendServersSetups(BackendServersSetupDependencies)` actor:
  `stateOf(_:agentId:)`, `install(_:agentId:shell:room:serverName:)`,
  `signIn(_:agentId:shell:binary:weInstalled:)`,
  `signOut(_:agentId:shell:binary:)`, `remove(_:agentId:binary:)`,
  `cancel(_:)`, `cancelAll()`. Operations return `BackendServersSetupState`;
  its `.wireValue` has exactly `serverId, agentId, step, line, detail, byHand,
  code, weInstalled, version`.
- `BackendServersSetupRules` supplies the source labels, install/signout
  consequences/refusals, install commands, row lookup and account line.
- `BackendServersHosts(BackendServersHostDependencies)` actor:
  `stateOf(_:)`, `look(_:)`, `install(_:shell:look:serverName:)`,
  `pairDevice(_:shell:command:done:)`, `link(_:shell:command:done:)`,
  `uninstall(_:look:alsoData:)`, `cancel(_:)`, `cancelAll()`, `forget(_:)`,
  `canLink`, `carriedPackage()`.
  Look throws the actual transport error. Other operations return
  `BackendServersHostState`. `.wireValue` is supplied on State, Look, Room and
  OnServer. `BackendServersHostRules` supplies host/reach/consequence/removal
  lines, room refusals, relay/host-id/address/channel parsers and numeric update
  comparison. `BackendServersHostPackage` has `tarball, installer, version`.
  `BackendServersHostPackages.find(version:resources:tree:exists:)` requires
  both receipts and `.noPackage` is the source absence sentence.
- `BackendServersWindowDrives(BackendServersWindowDriveDependencies)` actor:
  `arm(_:shellId:)`, `belonging(_:)`, `disarm(_:)`, `revoke(_:)`, `whyNot(_:)`,
  `stop()`. Arm returns `.armed(line:)` or `.refused(why:)` with `.wireValue`.
  Belonging exposes `map`, `opensInApp`, `.wireValue`.
- `BackendServersWindowReachRules.open(connection:local:runScript:)` returns
  `.opened(BackendServersWindowReach)` or `.refused(String)` and never throws.
  Local end is `.port(Int)` for control and `.socketPath(String)` for hooks.
  The returned reach has `port` and idempotent `close()`.

Register source channel names in root: `servers:setup:look/state/install/signin/
signout/remove/cancel`, `servers:host:look/state/install/pair/link/remove/cancel`;
broadcast SetupState on `servers:setup:changed` and HostState on
`servers:host:changed`. Setup call arguments are `(serverId, agentId, shellId)`;
host PTY calls are `(serverId, shellId)`. Root must read its shell registry and
verify the named server owns the shell before passing a handle. Never infer a
server from the shell-id text. Shell output/input/resize/close remains root's
existing shared transport registry responsibility.

## Actual dependency owners

1. **SSH/store/connection worker:** shared `BackendServersRunResult`,
   `BackendServersShell`, `BackendServersConnections`, `BackendServersConnection`,
   `BackendServersDuplex`, `BackendServersReverseForward`,
   `BackendServersReverseTarget`; Facts worker's shared AgentID/Fact/SigninState/
   InstallRoom/Facts. These are consumed directly, not duplicated.
2. **Root setup factory:** supply `runScript(serverId, script)` and
   `openTunnel(serverId, port)` using the real
   `BackendServersSetupTunnel.open(serverId:port:connections:)`. That factory
   retains its SSH pool reference until the tunnel closes. Supply a real
   system/default-browser opener only when available; absent uses the exact
   source by-hand path, with login left running and scratch/listener removed.
3. **Root host factory:** actual `runScript`, optional real SFTP `putFile`,
   actual carried package locator, optional real machine-code redemption and
   channel wait. `BackendServersHostLinkOutcome.linked` must contain the guest
   key's actual fingerprint, never a fingerprint read from host output.
   A missing redemption service uses the source phone-code fallback; missing
   package or SFTP refuses before upload. Linux/server Node remains untouched.
4. **Root window factory:** mutable `allowed(serverId)`, real Claude probe,
   shared commands/scripts, ref-counted separate control/hooks reaches. On
   creating a pooled lease, hold `connections.acquire(serverId)` before a
   temporary `withConnection` opens/proves it. On the last `letGo`, close the
   lease and `connections.release(serverId)`. Keep separate `(serverId, kind)`
   keys; a control reach must never serve the hook socket.
5. **Existing deck-tools leases:** `mint` returns the existing
   `BackendDeckToolsSessionsPreparedElsewhere`, using its async `started` and
   `drop` closures. No second caller table or token mint is implemented here.
   Mutable source grant is checked during prepare and before binding. Binding
   calls `started(shellId, serverId)`, so server windows have their actual
   server identity. Drop occurs before removing scratch or releasing reaches.
6. **Existing hook/context owners:** optional current hook token and remote
   documents/map composer. `BackendServersWindowRemoteContext` is a minimal
   data adapter (`pages`, `mapFor(remoteDirectory)`), not a second context
   implementation. If unavailable, no hooks/opener/map claim is emitted.

No direct browser-control implementation was duplicated. Browser verbs are the
existing Safari/WebKit MCP tools, narrowed through the existing elsewhere
session grant. Remote-machine pairing, trust, devices and machine tables stay
with their existing owners.

## Mac mappings and source boundaries

- The Mac controller still produces **Linux remote** installation, systemd
  user-service, lingering, Node runtime/host package, shell and POSIX scripts.
  Linux remote commands are necessary product behavior, not retired Mac code.
- Windows named-pipe local hook sockets are **not applicable on Mac**; the Mac
  endpoint accepts its real absolute UNIX socket. Windows/WSL service and
  desktop installation are **not applicable on Mac**. The remote Windows host
  install refusal remains the source sentence. No Windows/WSL branches in the
  assigned modules were silently represented as successful Mac operations.
- The raw `ssh2` reverse callback's `destPort` filter maps to one exclusive
  private sink per native system-SSH lease. No socket is served until the
  returned remote port is proved loopback with `ss`/`netstat`. Activation is
  denied for public/unknown binding; transport enforces 16 streams, waits for
  completed writes, preserves EOF and tears down channels on close. The
  `ssh2` zero-port cancellation compatibility workaround is not needed by the
  native ControlMaster's exact allocated-port cancellation request.
- Source ceilings remain setup install 10 minutes, device sign-in 16 minutes,
  redirect capture 20 seconds, host install 12 minutes, pairing-code wait
  30 seconds, fingerprint wait 45 seconds, approval wait 30 seconds,
  relay wait/channel wait 20 seconds, and exactly three automatic fresh codes.
  Device-code watch retains the source 64 KiB tail. Pairing tape remains
  flow-scoped without a newly invented byte cap.
- Automatic host linking never puts its spent code on broadcast state. Unknown
  phone fingerprints are never answered by the app. The program/runtime,
  user-service and optional data removal receipts retain the same schemas and
  guards; agent settings/logins/transcripts are never deleted by undoing install.
- Native cancellation also closes future tape waits, checks cancellation after
  awaited scratch/tunnel acquisition, listens to physical PTY EOF, and cleans scratch/listeners returned
  during cancellation. These close Swift async races without changing the
  source sign-in paths. Heredoc writes now fail on `cat` error, and arm checks
  the script's nonzero result, so a full disk cannot claim successful arming.

## Remaining integration and verification

Root factories/channel registration and the one final combined build/test/
visual gate remain. The raw Network listener and native system-SSH streams
have not been executed; callback/backpressure and actual vendor sign-in behavior
remain runtime checks for that gate. No real host package was searched outside
the workspace, uploaded, installed, started or paired in this task. There is no
claim that written source is reachable or verified in the app.
