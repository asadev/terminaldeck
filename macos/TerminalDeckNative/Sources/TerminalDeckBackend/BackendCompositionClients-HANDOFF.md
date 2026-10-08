# Client composition integration handoff

Owner: integration / clients_wiring. Evidence refreshed 6 October 2026, 18:18 Dubai (14:18 UTC). Local source and read-only source review. No build, compiler invocation, tests, app launch, live-data/credential reads, network operations, installations, releases or git mutations.

## Delivered scope

| # | Work | Status | Evidence |
|---|---|---|---|
| 1 | Read fleet/integration/orchestration/plan/coverage plus clients aggregate and three detailed handoffs | 🟢 Done | Full documents read before implementation |
| 2 | One retained clients graph against the supplied registry, MCP server, Store and providers | 🟢 Written | `BackendCompositionClients.swift` |
| 3 | Real native file panels, plugin consent, knowledge share consent and Trash adapter | 🟢 Written | `TerminalDeckNative/NativeCompositionClients.swift` |
| 4 | Single shared backend test target | 🟢 Written | `Package.swift`, exactly one `TerminalDeckBackendTests` declaration |
| 5 | Concrete deck-core MCP provider with authenticated policy scope and actual filesystem authority | 🟢 Written | `BackendCompositionClientsMCP.swift` |
| 6 | Concrete held catalogue over existing core Registry/Describe | 🟢 Written | `BackendCompositionClientsCatalogue.swift` |
| 7 | Concrete matched-grant / ToolContextAuthority dispatcher and profile/session/task scope adapters | 🟢 Written | `BackendCompositionClientsAuthority.swift` |
| 8 | Manifest-gated retirement of the three assigned legacy consumers | 🟢 Written | `agents-area-live.ts`, `remote/panels/mcp.ts`, `store-install.ts`, new `NativeCompositionClientsOwnership.ts` |
| 9 | Exact cutover edits, supplier hookup and complete edit log | 🟢 Written | Ownership transfer continuation below |

Total 9: source written 9; in progress 0; blocked/waiting 0; queued 0. Runtime-verified items: 0. This scope is composition source delivery; it does not mean clients now own production domains. Parent root added an `installClients` wrapper and deliberately keeps the client domains on Node until direct consumers transfer together. Remaining full-graph/root hooks are named below and are not marked complete.

Initial scope edited only this worker's new `BackendCompositionClients*` / `NativeCompositionClients*` files and the assigned one test-target block. The continued parent assignment explicitly added three disjoint tracked TypeScript consumers; their exact edit log is below. Dirty preexisting Package.swift changes for helper/backend/Core were preserved.

## Exact hookup

`BackendCompositionClients.install(registry:mcpServer:stateStore:providers:dataRoot:home:inheritedEnvironment:ownerID:transferredDomains:dependencies:) async throws -> BackendCompositionClients` constructs the selected services once, registers their channels and retains the GitHub send subscription. `shutdown()` drains service owners and removes only its exact registrations; it does not close the shared registry, Store, providers or MCP server.

Parent root has `BackendCompositionRoot.installClients(transferredDomains:dependencies:)`. It supplies the existing authoritative Store and one registry/MCP/provider graph, assigns owner `native-composition:clients`, and retains the returned area. Callers must use that area's native UI owner context; plugins additionally check the exact ownerID. Do not provide a fabricated native UI context to keys, guests or MCP callers.

Before launching Mac Node, obtain the exact selected set from `availableDomains(dependencies:)`, transfer every direct consumer below, and give that set to Node's `TD_NATIVE_COMPOSITION_DOMAINS` gate and then `installClients`. Installing the graph does not itself transfer ownership. A selected domain lacking its required supplier refuses installation, and preexisting invoke/send collisions refuse before registration. Community requires `mcp-clients` in the same transfer.

`domains`, `invokeChannels`, `sendChannels` and `eventChannels` are nonisolated metadata. All eight selected subareas produce **48 invokes, 1 send and 4 event names**. Available default service subareas produce **33 invokes, 1 send and 2 event names**; missing Stays Fixed runtime/package explicitly refuses its unavailable operations.

| Domain ID | Factory / retained service | Invoke count | Additional routing |
|---|---|---:|---|
| `mcp-clients` | `BackendMcpClientChannels` / one service, pool, store and writer | 14 | `mcp:state` |
| `github` | `BackendGitHubChannels` / one service, cache and authenticator | 8 | `github:clear-cache` send retained |
| `custom-agents` | `BackendCustomAgentsChannels` / one atomic store | 3 | None |
| `community` | `BackendCommunityChannels` / actual supplied or signed native installer | 3 | None |
| `memory` | `BackendMemoryChannels` / one lazy actor | 7 | `memory:changed` |
| `knowledge` | one `BackendKnowledgeService` plus held MCP specs | 0 | Source task/Hoot adapters still required |
| `plugins` | `BackendPluginsChannels` / one host and live catalogue contributor | 5 | `plugins:changed` |
| `staysfixed` | `BackendStaysFixedChannels` / one actor and concrete runner | 8 | `staysfixed:changed` |

The complete literal invoke lists remain the factories' exported `names` / `channels` arrays; no second handwritten route list was introduced except the source's three community and custom-agent channels. Invoke/send results stay `NativeRPCValue`. Native calls should await the actor directly; do not impose Node's existing 30s silent-request timeout on `github:auth-await` or Stays Fixed's 20-minute check.

Native UI setup:

```swift
var deps = NativeCompositionClients.appKitDependencies(
    window: { NSApp.mainWindow }, report: report)
deps.storeConfiguration = .init(
    packaged: actualPackagedState,
    commandRunner: sharedCommandRunner,
    configuredBase: { nil })
// Source index.ts currently calls storeApiBase(process.env), with no saved
// setting override. nil here means that same explicit absence of an override.
// If a real configured choice is later introduced, supply its actual reader.
```

This creates no UI or services until invoked. Real panels use JSON selection and return nil only on user cancellation. Missing owner window throws unavailable. The AppKit plugin consent implementation retains default-no/Escape/two-minute/shutdown behavior. The plain Node path must be an absolute executable named `node`; passing the native app executable is rejected. Supply it from the validated bundled engine, never from a guessed installed app.

## Concrete suppliers and remaining named seams

`BackendCompositionClientsDependencies` carries optional operations. `pendingSuppliers(dependencies:)` returns concrete owner-labelled gaps without inventing success.

- **Community:** `StoreConfiguration(packaged:commandRunner:configuredBase:)` constructs existing `BackendOSStoreChannels.make`, verified source reusing signed cache/installer, measured providers, the exact planned target table and this graph's `mcpClients.writer`. A supplied `BackendCommunityStoreProviding` is also supported. It is never an unsigned fake shelf. Do not register `BackendOSStoreChannels.register` separately, since it registers the same three community channels.
- **MCP output schemas:** real `BackendMcpClientOutputValidating` remains a validation-owner supplier. Without it the pool refuses structured outputs whose tools advertise outputSchema. Native dialogs are concrete. No schema-valid stub was added.
- **Memory:** `BackendCompositionClientsMemoryEnvironment(profiles:userData:hootMemory:trash:hootActionLogger:)` uses the existing `BackendAccountProfileStore`, Claude then Codex list order, actual userData and supplied Hoot path. `store(for:)` uses explicit profileId or the provider's system ID and verifies matching provider. `NativeCompositionClients.memoryEnvironment(...)` supplies real Trash. Hoot logger remains explicitly optional and nonthrowing; no new profile store or guessed account directory is constructed. Until that environment exists, `memory` is not available for transfer.
- **Knowledge / memory MCP:** real `BackendKnowledgeToolAuthority` and new typed `BackendCompositionClientsLazyCatalogue` must come from deck-core/task/caller ownership. The catalogue protocol receives the seven held specifications, short index lines and area mapping and must install a real descriptor and authenticated role grants. Until both suppliers exist, these hidden tools are not registered. `grantToolNames(domains:authenticatedKind:machineID:)` uses the original factories' audience helpers and adds both describe names only when there are held tools. Kind `.local` means authenticated local Hoot, never an attended flag. The graph's owner-scoped atomic tool contribution reuses the original factory specifications, call logic and cancellation behavior. Descriptor removal and tool removal happen together during shutdown.
- **Knowledge tasks / Hoot:** once the full knowledge writer transfers, reuse `graph.knowledge` for `forBrief` and timestamped `noteTaskEvent`; the actual task review owner alone injects verified/rejected events. No tool can set verified status. Real task scope, known folders, Hoot paths and optional logger remain external suppliers. No knowledge actor is constructed when the knowledge domain remains on Node; plugins then need `pluginKnowledge` from the current reader owner or receive unavailable.
- **Plugins:** requires real `BackendPluginsCallerAuthority`, native consent and `pluginToolsChanged` (actual Hoot-only live grant updater) before it is available or `startAll` is called. Tasks, goals, notifications and current-owner knowledge reads are typed optional suppliers; absent operations preserve the host's `-32003` refusal. Projects come from the authoritative Store. All supplied local services are shared with that one host.
- **Plugin live tools:** shared server `replaceTools(ownerID:tools:)`, `removeTools(ownerID:)` and `setCatalogueRefresh(ownerID:refresh:)` were supplied by parent. The graph registers its own provider hook, scans/rehashes before catalogue reads, replaces only its own contribution, refreshes on host change and unregisters the hook before shutdown. The grant callback must update real local Hoot grants and retain their live permitted predicate, and must not recursively call the catalogue it is refreshing. Grant/catalogue failures are visible and retire this contribution. `refreshPluginTools()` and `pluginToolNames()` remain available to other real descriptor owners.
- **Stays Fixed:** package locator `staysFixedLocate` and `plainNodeExecutable` come from packaging. Use actual `BackendStaysFixedEngineFiles.locate` paths, with explicit bundled package override when needed. `graph.staysFixed.projectSource()` feeds the existing session launch serializer; do not create another serializer or write global agent configs. External staysfixed 0.15.0 and runtime:`node` plugins still need Node. Missing package/runtime is unavailable rather than simulated completion.
- **Git / remote:** use the same `graph.githubAuth` for internal token, scrub and HTTPS credential suppliers. Shutdown cancels auth without deleting credentials. Whole-machine panel channels remain local UI only. Remote grant/guest adapters must consume the same actor under their real authority.

## Exact Node consumer ownership audit

Disabling UI IPC registration alone does **not** transfer these domains. Parent received these source findings and keeps clients on Node by default pending a complete shared facade. Linux/server implementations must remain unchanged.

| Domain | Node consumer that must redirect or relinquish together | Concrete source evidence |
|---|---|---|
| MCP | Desktop invokes, direct deck-control agent/MCP tools, remote inspector pool and remote Store panel | `index.ts:4276` registerMcpIpc; `deck-control/agents-area-live.ts:181-190` direct exported readers/writers/pool operations (writes at 182-184/189), wired by `index.ts:5314`; `index.ts:3504` supplies module pool; `index.ts:3523-3525` supplies Store read/install/remove |
| MCP | Remote panel has its own direct writer defaults, even when no pool is supplied | `remote/server.ts:3966` constructs `mcpPanel`; `remote/panels/mcp.ts:373` config reader and `:513/:544/:565` direct add/edit/remove |
| MCP + community | Signed community installs/removals/rollback can still call Claude MCP writer directly | `store-install.ts:749` defaults add/remove; `:1040/:1095` MCP install branch; community registration `index.ts:4575-4576`; deck-control `browser-area-tools.ts:404-407` direct community view/install/remove and `community-tools.ts:215` writes |
| Custom agents | Node host owns another cached store; tools directly mutate it and launcher/provider readers use it | `host-core.ts:1318` new CustomAgentStore; `index.ts:2908` IPC; `deck-control/agents-area-live.ts:132-136` list/add/remove; `host-core.ts:3195` launch lookup and `index.ts:2738` detection read |
| GitHub | One Node host authenticator remains active after only panel registration is omitted | `host-core.ts:1348-1362` creates auth, global secret/token supplier and host access; `:1381` credential supplier; `index.ts:4025` panel; `remote/host-github.ts:97/:104/:108/:111` status/connect/cancel/disconnect; expiry-status path can delete stored credential |
| Stays Fixed | Node service, session project injection and fixed MCP tools share prefs/check state | `index.ts:898` create service; `:907` launcher agentLaunch; `:4321` IPC; `:5389` fixed tools using same service |
| Memory | Native memory channels cannot transfer while Node lazy service and scoped tools remain independent owners | `index.ts:4267` registerMemoryIpc; `:5391` scoped memory tools; Hoot also has direct note writes/deletes in `copilot-inspect.ts:369/:425/:781`, owned by Hoot lane |
| Knowledge | Node task/deck-control graph creates and consumes project records independently | `deck-control/index.ts:751` createKnowledge; `:822/:831` knowledge/goal tools; `:861` TaskEngine provider; `tasks/task-engine.ts:948` briefs and `:1078` event ingestion; `tasks/goal-tools.ts:82` briefs |
| Plugins | Node deck-control starts a host and exposes live contributions independently of native settings | `index.ts:5193` plugin startup deps; `deck-control/index.ts:836` liveTools and `:1128-1159` startPlugins/services; `:1220` stop |

Read-only MCP inventory consumers in `host-core.ts` and `tasks/agent-inventory.ts` need no write authority, but must use current configuration and not a second inspector pool. Node custom-agent reads need a shared facade or cache invalidation after native edits. The shared Mac facade should route these direct exported operations to the actual supplied native actors while preserving each original dispatch/remote authority; do not mint `.nativeApp` for a key or guest. Alternatively keep the entire affected domain on Node until all those callers move.

## Additional core suppliers requested by parent

`graph.mcpProvider(surface:filesystem:authority:)` constructs `BackendCompositionClientsMCPProvider`, a concrete `BackendDeckCoreEventsMCPProvider` using **the retained graph's same client configuration/service/writer/pool/store**. It delegates actual list/add/edit/remove/inventory/disconnect/call/Store/install/export operations, reuses add/remove validators, and supplies the original source pure edit/install resolvers because their ports currently expose those only inside mutation methods.

Required real `BackendCompositionClientsMCPContextAuthority` supplies `revalidate(context, tool:)` against the current authenticated caller table and `filesystemContext(context)` for the real filesystem grant provider. No fallback authority exists. The adapter:

- `knownFolder` preserves saved projects/live session cwd/task workspaces via the original `BackendDeckCoreCatalogueBuiltins` method, then canonical key/device/session folder grants. Empty device/session roots never become the owner home. A remote worker cannot ask this computer's configuration as if local.
- `policies()` wraps original mcpPolicies with a task-local capability containing exact provider/tool/authenticated context, including synchronous prechecks and async run. It preserves the original schemas, tiers, summaries, audience, argument redaction, consent escalation, budgets and action logging. Contextless operations called outside these wrapped policies fail unavailable; a concurrent caller cannot inherit another call's global "current identity".
- Actual operations revalidate the live caller, authorize supplied project paths with `BackendFilesystemAuthority`, revalidate after that await and observe cancellation through the existing cancellable helper. Nonlocal callers cannot project to `.nativeApp` or `.internalEngine`; even Hoot never projects to the app window. Whole-machine/user-scope approval stays with the real supplied caller/dispatcher authority.

Core now supplies `BackendDeckCoreRuntime.start(suppliedMCPPolicies:)` and `BackendDeckCoreRegistration.Providers(mcpPolicies:)` (observed in source 18:18 Dubai). Parent must pass `try provider.policies()` through that supplied argument. The provider wrapper now preserves and awaits the source `precheckAsync`, and rechecks the authenticated grant before consent. This worker did not edit core-owned files. Registering raw provider policies would return clear unavailable, not bypass authentication.

`BackendCompositionClientsDeckCatalogue(baseMetadata:updateCallerGrants:report:)` is now the concrete `BackendCompositionClientsLazyCatalogue` supplier. It stores only this area's owner-scoped original seven metadata rows and source titles, validates aliases with **the existing `BackendDeckCoreCatalogueRegistry`**, and exposes:

- `metadata()` for `BackendDeckCoreRuntime.start(liveMetadata:)`.
- `registry()` combining the actual core/descriptor metadata supplied by its owner with client rows.
- `wireListing(context:)` and `describe(arguments:context:)`, both requiring an actual credential-resolved `BackendDeckCoreSecurityCallContext`, using original audience/grant filtering, 20-name/12-inline limits, identical denied/nonexistent responses and full-spec fallback when describe is not granted.

The constructor requires the real base metadata reader and `updateCallerGrants` callback; there is no always-allow or guessed caller fallback. Use graph `grantToolNames` to union only the source-admitted authenticated Hoot/local worker tools with their existing grants and live predicates. Core Registry is immutable and RuntimeMetadata is private, so integration must use the existing `liveMetadata` hook; this adapter does not mutate the core registry or register another descriptor/server. Supplying policies/handlers to the actual central gate remains the core bundle owner's job.

## Ownership transfer continuation (parent assignment)

`BackendCompositionClientsSecurityAuthority` is the concrete supplier for **BackendKnowledgeToolAuthority, BackendPluginsCallerAuthority and BackendCompositionClientsMCPContextAuthority**. Required construction uses the actual `BackendDeckCoreToolContextAuthority`, native `BackendPTYManager`, existing `BackendAccountProfileStore`, actual core CatalogueSurface and optional actual `BackendTaskStore`. It creates no alternate session/profile/task/configuration store.

- `withAuthenticatedGrant(grant:cancellation:current:operation:)` carries the grant already matched by the native server/table/key door through that exchange's actual request cancellation. It verifies current caller identity, tiers, positive names, attendance provenance, folder grants and cancellation before operations. The optional `current` resolver rechecks an actual credential-table grant when its registration can be replaced.
- `withAuthenticatedCredential(authorization:table:cancellation:operation:)` matches and rechecks the same actual `BackendDeckCoreSecurityCallerTable` on each operation. Credentials remain private in the call closure and are not UI values, output or log text. Direct native routines must use this overload with the actual unattended config credential; they cannot construct a local caller from an attended flag.
- `caller(native)` resolves the exact per-call context via existing ToolContextAuthority, then fresh matched grant identity. Worker sessions resolve only their actual manager row and matching Claude/Codex profile. Task scope comes from real `tasks.bySession`, retaining task/project, agent-only assignee, goal and conversation metadata. Unknown sessions and revoked callers refuse.
- `filesystemAuthority()` and `filesystemContext(context)` are concrete current-grant projections. Every projected context is scoped `.pairedDevice`, including Hoot, with an owner/request UUID bound to this exchange's private grant scope. None is `.nativeApp` or an unrestricted owner engine. Roots come from actual open projects/live cwd/task workspaces, current key folder grants, current device grants or the local session's explicit project grant; empty grants never become the owner home.
- `bundles(graph:)` supplies original memory/knowledge specifications and source title/index/audience metadata plus real policies to the central control. `policy.run` enters a private task-local dispatch proof and invokes the original handler through existing ToolContextAuthority. The handler's `authorize` proves exact tool/arguments/tier/callID and revalidates the current credential. It does not recursively call the dispatcher, duplicate consent/logging or pretend a gate succeeded.
- `configure(_:catalogue:)` supplies the three actual authority protocols and the concrete catalogue holder; plugin refresh callbacks build real live policies/metadata from the approved manifest and the same host registrations. Feed `livePolicies()` / `liveMetadata()` to core startup, and refresh the graph before core catalogue reads. Plugin failures and teardown retire both the MCP contribution and core snapshots.
- `enrichedGrant(base:context:)` unions only role/tier-admitted current held/plugin names and describe aliases with a supplied existing native grant. It preserves base attendance, tiers, projectRoot and its real permitted callback, and adds a recheck of the same source credential identity/cancellation. It never derives Hoot/key/session/device roles from wire arguments. The graph's existing static grant helpers remain the planned-registration path for a newly prepared session whose token is not bound yet; root must retain its actual session/project permitted callback.

### Exact root/core hookup still required

1. **Authenticated source call hook:** `BackendDeckCoreSecurityServer.exchange`, current `tools/call` branch at `:309`, calls `control.call(...)` after matching the actual grant and creating `scope`. Wrap that call, preserving every existing options field, as:

   ```swift
   let called = await clientAuthority.withAuthenticatedGrant(
       grant: grant, cancellation: scope) {
       await control.call(name: name, arguments: message["params"]["arguments"],
           options: .init(caller: caller, attended: grant.attended,
               granted: grant.tools, cancellation: scope))
   }
   ```

   This one exchange path serves loopback and relay. For replaceable table registrations carry the real table/authorization resolver via `current`, or use `withAuthenticatedCredential` in their native in-process dispatcher. Do not wrap an arbitrary Node/page request with a manufactured grant. Until this real hook exists, the new client tools refuse missing matched context.

2. **Actual policies/metadata:** construct one authority from actual session/profile/project state owners; set its concrete catalogue's `updateCallerGrants` callback to `try authority.replaceLazyMetadata(rows)`; configure deps; install the graph after ownership transfer; obtain `try authority.bundles(graph:)`, `try graph.mcpProvider(surface:filesystem:authority:)` and `try provider.policies()`. Pass bundles through core `contributions`, MCP policies through `Providers.mcpPolicies`, and the authority's live plugin metadata/policies through the existing readers. Avoid counting fixed bundle metadata twice in `liveMetadata`.
3. **Core pre-list:** `SecurityServer.exchange` `tools/list` currently lists `control.tools()` at `:302`. The core/root owner must `try await graph.refreshPluginTools()` before that source listing, keeping its failure as a visible unavailable/error. The generic shared BackendNativeMCPServer hook is already installed, but it does not refresh a separate core transport's list implicitly.
4. **Native controls remain app-only:** root supplies actual native window/profile/Hoot paths, real Trash/log callbacks and Node/package paths as before. Whole-machine UI channels never become the authority transport for agent/device requests.
5. **Node index gates before startup:** source `index.ts` currently gates only `tailnet` in the inspected registration sections. Root must gate the following with its actual `nativeCompositionOwns` manifest and preserve Linux/server behavior:

   | Domain | Current index operation requiring retirement or actual native supplier |
   |---|---|
   | `mcp-clients` | `registerMcpIpc` `:4277`; do not supply module pool at `:3505`; remote Store servers direct callbacks at `:3524-3526` must call `requireNodeClientOwner('mcp-clients')` before exported Node view/install/remove or be replaced by a real native remote-grant adapter. No private local-UI bridge proxy. |
   | `custom-agents` | `registerCustomAgentsIpc` `:2909`; launcher/provider readers of `core.agents` need actual native snapshot/relookup, not the Node store's cached snapshot after native edits. Its source construction is inert, but a UI registration still provides a second writer. |
   | `community` | `installCommunityStore` / `registerCommunityIpc` `:4576-4577`; old direct tool consumers now hit the gated installer, but startup registration/cache owner must also retire. |
   | `memory` | `registerMemoryIpc` `:4268` and Node `memoryTools({currentMemory,...})` `:5392`; Hoot's direct memory edit channels stay a Hoot-owner cutover dependency. |
   | `staysfixed` | Module service at `:899`, projectTools `:908`, `registerStaysFixedIpc` `:4322`, fixed tools `:5390` must share graph actor/projectSource or retire together. |
   | `github` | `registerGitHubIpc` `:4026`; host-core's actual auth constructor/remote host access remain direct writer consumers. The native auth actor must replace all of them before this domain selects. |
   | `plugins` | Omit Node plugin startup deps at `:5194` after the real native host/policy/consent lifecycle exists. |
   | `knowledge` | Node deck-control's internal createKnowledge/TaskEngine/goal tools/plugins reader must use the same native actor or retire with native tasks/core. Removing UI handlers alone cannot transfer its event writer. |

6. **Selection remains conservative:** emit those domains into `TD_NATIVE_COMPOSITION_ROUTES` only when the actual complete retained graph is installed and all direct consumers transfer/retire. No gate changes environment variables or selects a native owner itself. Defaults remain on Node, as requested by parent.

### Complete continuation edit log

Every handed-off or existing-source edit in this worker's continued scope is listed here. No core Runtime/Server/Types/Control/LiveSurface/Builtins, root/index/bridge source, Node-removal file or validator was edited.

| File | Exact edit / purpose |
|---|---|
| New `src/main/NativeCompositionClientsOwnership.ts` | Calls the actual manifest's `nativeCompositionOwns` for only MCP/custom-agent/community domains. Shared clear legacy-caller refusal and generic guard; normal non-Mac/unselected calls run unchanged. No authority proxy or ownership-setting side effect. |
| Existing `src/main/deck-control/agents-area-live.ts` | Guards 10 direct MCP operations and custom-agent list/add/remove against their selected native owners. Existing summaries/schema/policy dispatch remains the source's own. No local UI credential borrowed. |
| Existing `src/main/remote/panels/mcp.ts` | Guards config reads and all performs; read/act returns the source PanelPayload with explicit refusal note and no live actions/rows when native owns. Never constructs a second native or Node pool to satisfy a selected request. |
| Existing `src/main/store-install.ts` | Community view returns `ok:false`; install/remove refuse before ledger/cache/config writes; installed() refuses instead of returning a fake list. MCP catalogue items/server-ledger removals refuse when MCP owns even if community remains Node. Guards Claude writer and Codex/Gemini server install/undo paths before those commands. Remaining Node skill/instruction/routine installs retain original behavior while community owns them. |
| Owned `BackendCompositionClientsMCP.swift` | Rewrapped source policies now preserve/await original `precheckAsync` and revalidate actual matched context before consent. |
| Owned `BackendCompositionClientsCatalogue.swift` | Exposes one reusable original client metadata factory for concrete source bundles; validation/title/audience remains shared with holder install. |
| Owned `BackendCompositionClients.swift` | Adds live plugin registration/policy callback, feeds it the same host/tool contribution, withdraws policies/grants on change failure and drains it at close. Unrelated MCP owners stay intact. |
| New `BackendCompositionClientsAuthority.swift` | Concrete credential/table/call-context authority, real profile/session/task/filesystem scopes, held client bundles, dynamic plugin policies and permitted-preserving enriched grants, as above. |

No original handed-off `BackendMcpClient*`, `BackendMemory*`, `BackendKnowledge*`, `BackendPlugins*`, `BackendGitHub*`, `BackendStaysFixed*` or original UI client file was edited in this continuation. In particular **BackendMcpClientJSONSchemaValidator remains hands-off and untouched**. Compatibility requests for BackendNativeProviders / BackendProjectToolComposition still belong to their owners.

## Tracked compatibility edits still requested from their owners

No existing worker backend file was edited by this worker.

1. `BackendNativeProviders.customAgents()` (`:153`): replace its independent parser with `BackendCustomAgentsRules.parseAgents` under the original 256Ki UTF-16 file limit, take the first32 valid rows, and map id/command/args/resumeArgs. Keep real executable relookup at session launch. Current bytes/Character/total-row rejection differs from the source.
2. `BackendStaysFixedProjectSource.resolve` in `BackendProjectToolComposition.swift`: retain the bounded read, but unreadable/invalid preferences fall back to empty projects; explicit agents:false stays off and setup remains required.
3. Gemini malformed/oversized system-defaults handling in that same existing launch composition must omit project injection and preserve the base launch, while reporting the missing capability. Never silently replace administrator defaults.
4. Shared root/bridge: only migrate client domains when every direct consumer in the audit transfers; preserve all exact channel/send/event names and native long-call completion. Root has the shared graph wrapper, but source composition is not production activation.

## Static checks and safe next action

Read source signatures for factories, actors, profile/Store/registry/MCP owners and installer. Confirmed shared root's `installClients` call matches the new install signature. `git diff --check` for the assigned Package.swift change returned clean; counted one BackendTests target. This is read-only source validation, not compilation. No new tests were run or claimed.

Parent integrates actual suppliers and Mac-only direct-consumer ownership gates, asks worker owners for the three compatibility corrections, then runs the single final combined build/test/functional/visual gate after all areas are ready. No production domain, credential, live app or Node removal was verified here.
