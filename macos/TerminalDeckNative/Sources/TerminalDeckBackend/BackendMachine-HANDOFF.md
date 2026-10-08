# Native machine connections, panels and uploads

Evidence: 6 October 2026. Source written only. No build, test, app/process launch,
socket/relay call, credential read, live-data change, dependency install or release
was performed. Constructors are inert; `open`, `start` and operations are explicit.
This is not a claim of native Mac or whole-backend completion.

## Owned source and exclusions

Sixteen authored Swift files: `BackendMachineStore`, `BackendMachineCoordinator`,
`BackendMachineChannels`, `BackendMachineMCP`, `BackendMachineWindows`,
`BackendRemoteGuestChannel`, `BackendRemoteGuest`, `BackendRemoteGuestReach`,
`BackendRemoteGuestTunnelHost`, `BackendRemotePanels`,
`BackendRemotePanelArtifacts`, `BackendRemotePanelStore`,
`BackendRemotePanelReadiness`, `BackendRemotePanelMCP`,
`BackendUploadSend`, `BackendUploadReceive`.

Two more written source files and their existing test file were transferred by
remote-serve and merged into this lane: `BackendRemoteServeTransportTunnel.swift`,
`BackendRemoteServeTransportSocket.swift`, and
`BackendRemoteServeTransportTests.swift`. Eighteen source files total in the
machine/tunnel batch. Ten existing native tests remain written, zero run; only
their connection-ID fixture and drain join were adjusted. No test case was added.

| Product source | Native source coverage |
|---|---|
| `remote/machines/store.ts` | Existing `machines.json` and `{version:1,denied:[ids]}` off-switch schema; bounded records, per-machine X25519 keys/credential, public-only projections, atomic persistence, quarantine, lazy exclusive ownership |
| `remote/machines/{dial,guest,pair,rendezvous,ipc}.ts` | Real sealed initiator channel, six-digit scrypt rendezvous lookup, human-approved host welcome credential, key persistence, connection/retry/heartbeat state, attached session replay/input/output/status, correlated bounded requests, all 42 named channels and UI event shapes |
| `remote/machines/window-serve.ts` | Fresh durable grant check, authenticated machine/session identity, supplied positive tool list, actual attended/tier/binding dispatcher, screenshot-path refusal, bounded/truncated results; bidirectional holds, own sessions, calls/results |
| `localhost-reach.ts`, `remote/tunnel.ts` | Guest and host native loopback byte streams, IPv4/IPv6/alternate local-port ladder, idempotent open, truthful `ReachOpened`, ACK flow control, shared control-port denial, four host tunnels/64 per-connection/256 total stream budgets, flush-before-close and five-second bounded linger |
| `remote/uploads.ts`, `remote/machines/upload-send.ts` | 24 KiB streaming and 256 KiB ACK window, size/source-change checks, SHA256 receipts, per-connection receiver, fresh destination authorization, anchored descriptors, no-overwrite final commit, partial cleanup and cancellation |
| `remote/panels/{contract,artifacts,store,readiness,mcp}.ts` | Four real provider projections/actions, offered-action rechecks and redraw; exact artifact viewer row-ID/token/scope grammar and preview door; storefront departments/search/chips; readiness score/agent/fix projection; MCP config forms/key-only env projection and actual optional shared pool/writers |
| `deck-control/machine-tools.ts` | Six existing tool identities: `machines.look`, `machines.session`, `machines.copilot`, `machines.ports`, `machines.upload`, `machines.manage`; local-only gate, actual consent/tier/started-session ownership callbacks, native registry calls, event-driven start/port waits, measured typing/key implementation reused |

**No ownership or implementation of `src/main/servers/` (SSH Servers) or
`src/main/devices/` (Device Hub).** No phone, Linux/server, account/session,
browser, usage/cost/insights or shared entrypoint edits.

## Exact integration sequence

1. Keep Node's existing machine/remote writers active until the whole native
   facade is installed. Do not open these actors on the production data folder
   while the old Node `MachineStore`/remote trust owners still write it. The
   native lock cannot restrain a legacy writer that never takes that lock.
2. Use the same remote storage directory as the current host. Construct
   `BackendMachineStore(directory:)`, then `BackendMachineCoordinator(store:,
   registry:,localName:,relayURL:,uploadAuthorize:,ownPorts:,windows:,
   pairingBlocked:,tunnelsDropped:)`. The `BackendDevOwnPorts` must be the
   same process-wide instance used by port discovery and control endpoints.
3. `uploadAuthorize` must implement the actual source file/credential/private
   userData boundary, not merely “path exists”. Incoming
   `BackendUploadReceive(destination:)` must reconsult current trust/folder
   grants for `context.deviceID` on every call and return an authorized native
   destination. Neither request fields nor claimed capabilities grant access.
4. Optional `BackendMachineWindowServices` needs the real native browser
   dispatcher and its source positive tool list. Its caller carries the
   authenticated machine ID, remote session ID, read/act/alter tiers and an
   actual attended answer. Resolve the `<machineID,sessionID>` binding there.
   Supply actual held/own-session/received-hold/result callbacks; capabilities
   are independently advertised only for supplied directions. Call
   `coordinator.announceWindows(id)` after binding changes and
   `announceSessions()` after local session-list changes.
5. Register `BackendMachineChannels.register(registry:coordinator:localHost:)`
   and retain its handle for channel ownership. Wire native registry pushes to
   the app UI: `machines:state`; `{machineId,sessionId,data,replay}` output;
   `{machineId,progress}` uploads; `{machineId,state|chat|github}` peer pushes.
   A source `machines:create` takes `(id,cwd,provider)`. Management mutations
   answer with `MachinesView`; reach answers `{ok,url,port,localPort,sameNumber}`.
6. After callbacks/observers exist, explicitly
   `try await coordinator.open(connectSaved: true)`. Saved pairings reconnect
   at startup, not only when their screen is opened. `pairingBlocked` should
   describe the actual local host/relay state; `tunnelsDropped` must update the
   browser's tunnel ledger when a link disappears.
7. Register incoming features on the actual `BackendRemoteHost`: receiver
   `feature()`, tunnel-host `feature()`, and supplied panel-registry `feature()`.
   `BackendRemoteGuestTunnelHost` is now the compatibility facade over the one
   `BackendRemoteServeTransport` connection-hub owner. The transferred native
   socket/port protocols are the active host implementation; the previous
   direct-Network source is retained privately during the ownership freeze and
   is never constructed by the facade. The facade needs the real port scanner, fresh trusted
   authorization and a **connection-specific** native `push(UUID,message)`.
   The host currently has a private `send`; integration must expose a guarded
   send method that throws for a closed connection, not a silent no-op.
   Alternatively supply `BackendRemoteServeTransportNativePorts` with its
   mandatory `currentContext` resolver (actual still-live connection + current
   trust/grants), shared discovery/own-ports and dev-server owner. The port
   provider rechecks authority without launching an OS scan for every chunk.
   Register `BackendRemoteServeTransportChannels` against `facade.transport`
   to preserve the actual `remote:tunnel:stop` desktop channel and tunnel rows.
8. Wire **each connection UUID closing**, rather than only a device's last
   connection closing, to `uploads.close(connectionID:)` and
   `tunnels.close(connectionID:)`. Add a host close callback or diff the actual
   connection snapshots. Root also retains the single ordered PTY lifecycle
   owner/event fanout; this lane never spawns local replacement PTYs.
9. Panels: register only actually supplied domains. Artifacts uses the existing
   `BackendArtifactsIndex`/`BackendArtifactsPreview` and approved transcript
   scope; readiness has a concrete
   `BackendRemotePanelReadiness.provider(service: BackendReadinessService)`
   adapter. Store and MCP require their real native catalogue/config writers
   and shared pool. Optional absent writers remove their buttons. Derive write
   contexts from current stored grants and actual consent: the existing
   `BackendRemoteHostContext.rpcContext` is read-only and must not be promoted
   using frame-authored capabilities.
10. MCP: `BackendMachineMCP.register(server:registry:watch:access:)` uses the
    actual `BackendNativeMCPServer`. `BackendMachineMCPWatch` requires the
    actual native remote-screen/conversation collector (the source
    `machine-watch.ts` assembly dependency); do not replace it with empty
    closures or raw ANSI pretending to be a rendered screen. Access supplies
    the existing native consent/action log and persistent started-session
    ownership, keyed exactly `machine:<machineID>:<sessionID>`. Machine tools
    are local only and never give a remote caller another hop through this app.

## Cancellation and shutdown

Cancellation tears down pending pairing/lookup sockets, correlated requests,
upload waiters/remote partials, pending listener/dial operations and registry
event subscriptions. A dropped link clears remote sessions, ports and assistant
state; actual host pushes rebuild them on welcome. Browser tasks are bounded
and cancelled with the link. Tunnel FINs drain queued bytes; lingering sockets
remain in the resource budget and are cancelled on stop.

At app quit call `coordinator.stop()`, receiver `stop()`, tunnel-host `stop()` and
the actual watcher/panel-domain shutdowns before removing registry owners.
Host disconnect callbacks must remain installed through that drain. Saved
credentials are never sent in UI/MCP projections.

## Remaining evidence and dependencies

No native machine facade or app/engine composition was wired by this lane.
Real browser bindings/dispatcher, MCP watch collector/consent ownership,
Store/MCP catalogue services, per-connection host push/cleanup and authenticated
write-context composition remain required dependencies. Existing native
readiness, filesystem, artifact, dev-port and session services are reused.

Peer frames currently enforce the closed server tag/required-field map and
explicit session, symmetric window/net, port, upload/tunnel validation. Full
optional nested projection of unrelated Hoot/account/usage/GitHub server frames
is not duplicated here; their actual typed domain codecs must remain the
source of truth at composition. Malformed required fields fail the link.

The single combined gate still needs compilation, source-contract fixtures,
Linux/phone interoperability, live native-loopback scratch transfers/tunnels,
permission revocation/cancellation and actual app UI/terminal inspection.
No runtime correctness, migration completion or release is claimed.

## Ownership freeze audit

The accepted keep/release audit is source-writing evidence, not a completion
claim. No new production module is started after this split. The temporary
tests-port assignment was stopped by Claude; all released test ports belong to
remote-serve. Released production modules belong to gaps. No released runtime
or test port was started during that temporary assignment.

KEEP — actual Swift writing had started:

- `src/main/remote/machines/store.ts`
- `src/main/remote/machines/dial.ts`
- `src/main/remote/machines/guest.ts`
- `src/main/remote/machines/pair.ts`
- `src/main/remote/machines/rendezvous.ts`
- `src/main/remote/machines/ipc.ts`
- `src/main/remote/machines/upload-send.ts`
- `src/main/remote/machines/window-serve.ts`
- `src/main/remote/panels/contract.ts`
- `src/main/remote/panels/artifacts.ts`
- `src/main/remote/panels/store.ts`
- `src/main/remote/panels/readiness.ts`
- `src/main/remote/panels/mcp.ts`
- `src/main/remote/uploads.ts`
- `src/main/updates/updater.ts` — `Sources/TerminalDeckNative/NativeAppUpdater.swift`
- `src/main/updates/fetch-update.ts` — `NativeUpdateFeed.swift` / `NativeUpdatePackage.swift`
- `src/main/updates/install-update.ts` — `NativeUpdatePackage.swift` / `scripts/native-standalone/install-update.sh`

RELEASE — no Swift writing started:

- `src/main/updates/manual-strategy.ts`
- `src/main/updates/update-error.ts`
- `src/main/updates/window-focus.ts`
- `src/main/machine-browser-desktop.ts`

RELEASED test ports (existing TS files left untouched/unported):

- `src/main/updates/update-error.test.ts`
- `src/main/updates/updater.test.ts`
- `src/main/updates/fetch-update.test.ts`
- `src/main/updates/install-update.test.ts`
- `src/main/machine-browser-desktop.test.ts`
- `src/main/remote/machines/window-serve.test.ts`
- `src/main/remote/machines/guest-close-verb.test.ts`
- `src/main/remote/machines/live.test.ts`
- `src/main/remote/machines/guest.test.ts`
- `src/main/remote/machines/reach-ipc.test.ts`
- `src/main/remote/machines/upload-send.test.ts`
- `src/main/remote/machines/transfer-live.test.ts`
- `src/main/remote/machines/published-code.test.ts`
- `src/main/remote/machines/rendezvous.test.ts`
- `src/main/remote/machines/ipc.test.ts`
- `src/main/remote/machines/store.test.ts`
- `src/main/remote/machines/pair.test.ts`
- `src/main/remote/panels/readiness.test.ts`
- `src/main/remote/panels/artifacts.test.ts`
- `src/main/remote/panels/mcp.test.ts`
- `src/main/remote/panels/store.test.ts`
- Adjacent `src/main/remote/uploads.test.ts` is also unported/unmodified.

The only retained test edits in this merge are to the explicitly transferred
`macos/TerminalDeckNative/Tests/TerminalDeckBackendTests/BackendRemoteServeTransportTests.swift`:
ten pre-existing cases preserved, authenticated connection UUID fixture shared
with the tested hub, and explicit flush-drain join before reusing the descriptor
budget. No tests/builds/runtime actions were run.

## Night completion: complete-suppliers machine registrar

6 October 2026 restart recovery: old Nash/Harvey workers were no longer live.
Main continued only the saved Nash registrar, as the single allowed executor;
no replacement worker, new dispatch, build, test or runtime operation occurred.

`BackendMachineRegistration.swift` is complete in source. Root call:
`try await BackendMachineRegistration.register(in: composition, dependencies: suppliedGraph)`.
Nil dependencies install nothing and leave Node ownership; incomplete or
conflicting suppliers throw unavailable before the root retains an area.

Required retained graph: coordinator, the same localHost/Host.endpoint,
authenticated bidirectional browser/window services, all four real panel
providers, upload receiver, merged tunnel owner, the composition's same
registry/own-port owner, and proof that machines/remote-serve Node ownership
has transferred. `requireSuppliers` validates actual authority in memory; it
must not probe or construct substitutes. Host supplies additive atomic install,
fresh currentContext, message authorization and connectionRows. MCP supplies
all six genuine definitions and matching policies, real authenticated caller
mapping, disconnect and (in shared mode) proof of the installed source owner.
No native-app identity is substituted for an agent or paired device.

The contribution returns `Installed.area`, invokes/sends/events, tool IDs,
definitions/policies/metadata and async start/stop/disconnect entry points.
It declares 43 invokes (the 42 machine invokes plus `remote:tunnel:stop`),
zero sends, six events, six MCP tools and thirteen host message tags. Exact
names are the static sets in BackendMachineRegistration.swift. Zero sends means
no send subscriptions are manufactured; the real host/activation leases are
retained by Runtime. Each contribution installs only its own registry handlers,
MCP tools and host hook lease. The root receives domains `["machines"]`, requires
retained remote-serve and the exclusive machines/remote-serve cutover, then
retains the area only after complete handler ownership is established.

Registration is inert beyond installation. Root calls `Installed.start()` only
after the whole graph and Node cutover are valid; its supplied activate closure
returns all store/link/watch consumer leases. Host callbacks refresh and verify
connection/device/key identity; native channel and MCP calls carry the genuine
TaskLocal caller context and invoke the supplied authority gate. Owned MCP
mode uses atomic replaceTools/removeTools; shared mode preserves deck-tools'
real contribution and validates its owner/descriptor proof.

On failed install, rollback removes only the registrar's leases, routes and
owned tools; it does not stop retained services that it has never activated.
Night cleanup completion now cancels AND awaits an in-flight activation,
closes any late consumer leases once, rejects start after concurrent stop,
and checks cancellation before committing an area or marking it active.
Stop tears down only services it activated and awaits the supplied deactivate.
Connection disconnect closes that connection's upload/tunnel state; machine
and MCP caller disconnect use the real coordinator/caller cleanup suppliers.

Integration owns tracked-root edits: supply this exact graph; keep the returned
Installed handle; retain its authentic policies/metadata; start explicitly;
fan out the declared events through the root; call the matching disconnect
methods and await stop before disposing shared services/Store. Missing actual
suppliers remain an integration dependency, never permissive defaults. All
released production modules and bulk test ports remain with their new owners.

Source reviewed only. Compilation and runtime behavior remain unverified;
only Claude O2 may build, and the combined test/visual gate is still pending.
