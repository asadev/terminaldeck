# Windows paid relay lifecycle — source handoff, 18 November 2026

Branch `fix/windows-paid-reach-20261118`, based on frozen browser B `cf7c47bba9f223bad2d29a79be66bdda4f2542cf`. No changes to that B commit. No build, test run, SSH, PC/app launch, credentials read, live request, push, merge or release occurred in this lane. The parent's one focused run remains required. `git diff --check` is clean.

## Implemented

1. `RemoteService.CloudServicesAllowed` is an injectable `Func<bool>`, default **true**. It has no dependency on the subscription types missing from the B branch. The parent must supply the existing `Cloud.Snapshot.Subscription.AllowsCloudServices` projection, which handles off/old/unavailable as before, and paid/gift as allowed.
2. Explicit Start, ShowCode, OpenWeb and host restart refuse while blocked. The new `StartAtLaunchAsync` quietly retains the app's existing automatic-start intent and leaves local initialization running when the account is known unpaid. Receiver transport cannot start while blocked. Stop remains available.
3. `ReconcileCloudServicesAsync` serializes through the existing `lifecycleGate`. On loss, it cancels the rendezvous and relay runs, closes relay-originated direct links, withdraws TURN logins, ends relay channels, unregisters the relay trust-change listener and clears only transient host-key copies. It retains a running loopback LocalWebHost, its hub/application and local clients. It does not stop local sessions, keepers, WhatsApp, direct SSH owners or unrelated LAN services.
4. Relay-only phone, Receiver and MCP adapters check the current predicate on each message/publish. This closes the event-to-teardown gap. Disconnect cleanup still reaches the real owner. Phone refusal uses its existing error frame; MCP refusal uses its existing encoded HTTP 402 envelope. No new server protocol, grant, approval flow, trust rule or credential store was added. The same hub's localhost route bypasses this relay adapter.
5. On regain, only retained phone-host intent or currently enabled Receiver sources restart. A blocked new Start does not become future consent. An explicit Stop while blocked prevents phone-host restoration. No enabled choice, trusted device, saved caller, credential, key file or Receiver source was deleted or reset.

Addresses/capabilities (`McpAddress`, `ReachCard`, `PushRelay`, link status/send/video and HostFacts.running) stop advertising Cloud reach immediately when the predicate is false. Default-true/off still forwards the existing protocol bytes and leaves an already-correct host alone.

## Required parent wiring

These call sites were intentionally **not edited** because the parent owns AppRuntime, the subscription join, CloudSnapshot/McpDoor/catalogue and the wider C inventory.

| Location at B base | Required join |
|---|---|
| `AppRuntime.CloudSubscription.cs` supplied by C, `InitializeCloudSubscription` | Before any transport startup: `Remote.CloudServicesAllowed = () => Cloud.Snapshot.Subscription.AllowsCloudServices`. Reconcile on `Cloud.Changed` using the existing runtime error/log/event pattern. Unsubscribe that handler on dispose. Do not create a polling loop. |
| `AppRuntime.cs:117`, automatic initialization only | Replace `await Remote.StartAsync()` with `await Remote.StartAtLaunchAsync()`. Keep explicit UI/MCP Start actions calling `StartAsync`; those must refuse rather than silently enable when unpaid. |
| `AppRuntime.cs:200`, `RemoteToolsEnabled` | Project `remoteTools && Cloud.Snapshot.Subscription.AllowsCloudServices`. Keep the raw `remoteTools` preference/intent; do **not** call `SetRemoteToolsAsync(false)` merely on a lapse, because that resets intent and revokes/deletes saved caller files. |
| `AppRuntime.cs:201`, `SetRemoteToolsAsync` | Before an explicit enable, use the same subscription projection/refusal. Explicit disable remains allowed. |
| `AppRuntime.cs:235`, `ConnectCaller`, and live predicate at `:248` | Guard only `relay == true` / `p.Relay`, through the projected RemoteToolsEnabled/current subscription. Local AI app callers keep working. |
| `McpDoor.cs:122`, `AllowsRelay` | Add the parent's injectable current relay admission check here too; preserve normal local Authenticate/Call authorization. Every existing relay token must be rechecked, even when it was issued earlier. Relay adapters in this change are defense in depth, not a substitute for this door check. |
| `AppRuntime.CloudReach.cs:45`, `FollowCloudForReachAsync` | The current early return compares only account/device identity. Include subscription permission in lifecycle identity/decisions. On loss stop the Reach coordinator and outgoing account channels without changing `Gate.Settings().Enabled` or device trust; on regain resume only that saved choice. Do not sign out or remove devices to implement a lapse. |
| `OtherComputersService.PairAsync/ConnectAsync` and its reconnect/browser routes | These are relay transports, even though the product calls them “other computers.” Gate new relay connections and end their live subscriptions/channels on loss while retaining saved peers and enabled intent. Do not reuse an irreversible service Dispose if it prevents regain. This is a separate owner from RemoteService and was not edited here. |
| Already-open relay session/screen/control views and outgoing ReachGuest owners | Parent must remove/disable their Cloud-only controls and reject stale actions; preserve local and direct-SSH choices and models. Incoming relay phone controls are fenced here at their transport boundary. |

The subscription change handler should await/catch `Remote.ReconcileCloudServicesAsync()` through the existing runtime lifecycle. The predicate takes effect immediately; reconciliation closes live transports without changing persisted settings. Do not turn service unavailability into unpaid: use `AllowsCloudServices`, not raw `Entitled`.

The existing boot behavior starts the phone host automatically. `StartAtLaunchAsync` preserves that behavior as existing launch intent. This code adds no new persisted phone-host preference; a manual host Stop remains a runtime choice, as at the base.

## Inventory coverage and remaining C ownership

Inputs read: `PAYMENTS-DESIGN.md`; C commits `6f429b9` + `a4d4735`; merged Mac `RESULT.md` section mac-pay, including the complete 41-anchor/16-category inventory. The Mac inventory is an input, not Windows runtime evidence.

| Paid-place category | This lane | Parent/other C owners must cover |
|---|---|---|
| PhoneAndWebReach / Pairing | Incoming runtime start/restart/code/open-web, addresses, relay-originated direct link lifetime, Receiver relay | UI rows/commands, account Reach and outgoing other-computer paths |
| AiAppsInternet / CloudTools | Relay MCP framing and transport-level request refusal | RemoteToolsEnabled, ConnectCaller, McpDoor admission, discovery/stale calls and UI offers |
| OtherComputerSessions / SessionMove / RemoteMachineChoices | Incoming relay application frames only | Outgoing coordinators, machines/pickers, session/screen lifecycle and move actions |
| SidebarCloud / SettingsCloud / Devices / FileManager | No UI edits | Existing C presentation/navigation fences |
| SyncSwitches / SavedPasswords / PhonesCopy | No Cloud sync/data owner edits | Existing C snapshot/sync/recovery/phone-copy fences |
| ProjectCloudActions / ArtifactCloudActions | No project/artifact edits | Cloud-only actions/previews/removal; retain local artifact and GitHub actions |

This is **not** a blanket local feature gate, and does not claim all 41 Windows counterparts are complete by itself. The parent owns the consolidated C inventory. Direct SSH servers, local terminal/chat/Coding AI functions, local GitHub actions, WhatsApp and unrelated LAN work were not modified.

## Focused tests for the parent — not run here

Project: `windows/tests/TerminalDeck.Core.Tests/TerminalDeck.Core.Tests.csproj`.

Class: `TerminalDeck.Core.Tests.Remote.CloudRelayLifecycleTests` — **9 test methods**:

- Default/off behavior does not restart an already-correct host.
- Known-unpaid boot stays stopped; later access resumes existing startup intent.
- Lapse stops once; explicit Stop prevents later phone restoration.
- A blocked new Start does not become future consent.
- Receiver-only intent is read again, including a disable during lapse.
- Loss during an asynchronous stop cannot start a replacement relay.
- Relay phone frames/push are blocked while the same hub's local route and disconnect cleanup still work.
- Receiver frame/publisher checks block an already-established callback after loss, and still disconnect.
- MCP loss returns the existing 402 envelope without invoking the real MCP door.

Also include the C owner's existing `CloudSubscriptionTests` when running its chosen project/classes once, to prove the real off/on/paid/gift/none/lapsed mapping. No whole suite is requested.

## Limits

Only source and pure fixtures are supplied. This lane did not prove native WebSocket disconnection timing, running loopback continuity or regain against an actual account/service. It cannot retroactively undo a phone action already completed before the predicate changed; existing cancellation/disconnect owners handle work still in progress. A previously running loopback web host is intentionally retained as local access; a **new** OpenWeb action is refused while blocked. Saved credentials/trust/preferences remain in place. Parent integration and the focused test/Windows compile must pass before any release claim.
