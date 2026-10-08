# MCP clients handoff

Local source written and reviewed on 6 October 2026, 16:30 Dubai (12:30 UTC). Worker: clients / mcp_clients. No build, compiler invocation, test run, app launch, git mutation, credential access or live-data read/write was performed.

Scope inventory: **7 TypeScript source modules mapped; 9 new Swift source files; 4 new test files with 37 `@Test` functions written; 14 invoke handlers plus `mcp:state` push written.** The catalogue has 37 active rows from the 39 source rows; the two Chrome-only rows are retired by Asad. These are source counts, not runtime results. The parent owns `macos/handoffs/clients-HANDOFF.md`; this worker did not edit that aggregate handoff.

## Stable scope checklist

| # | Requested module | Source status | Swift file / type |
|---|---|---|---|
| 1 | `src/main/mcp-catalogue.ts` | 🟢 Written | `BackendMcpClientCatalogue.swift` / `BackendMcpClientCatalogue`; literal catalogue strings and input definitions retained; `chrome-devtools` and `puppeteer` retired by Asad's Chrome removal |
| 2 | `src/main/mcp-client.ts` | 🟢 Written | `BackendMcpClientConfiguration`, `BackendMcpClientPool`, `BackendMcpClientStdioTransport`, `BackendMcpClientService`, `BackendMcpClientChannels`, `BackendMcpClientValidation` in matching prefix files |
| 3 | `src/main/mcp-store.ts` | 🟢 Written | `BackendMcpClientStore.swift` / `BackendMcpClientStore`, `BackendMcpClientStoreRules`; real runtime/writer/environment probes, in-flight facts sharing, fresh install probes and conflict refusals |
| 4 | `src/main/mcp-add.ts` | 🟢 Written | `BackendMcpClientCommands.swift` / `BackendMcpClientCommands`, `BackendMcpClientWriter`; argv tokenizer/inverse, scope/name/extras validation, owner CLI add/remove |
| 5 | `src/main/mcp-custom.ts` | 🟢 Written | `BackendMcpClientStore.swift` / custom binary/runtime/row functions in `BackendMcpClientStoreRules`; installed custom rows keep controls even when a measured binary is absent |
| 6 | `src/main/mcp-edit.ts` | 🟢 Written | `BackendMcpClientCommands.swift` / `BackendMcpClientWriter.edit`, `BackendMcpClientCommands.mergeEnvironment`; keep/replace/drop saved env, remove/add with reported rollback |
| 7 | `src/main/mcp-share.ts` | 🟢 Written | `BackendMcpClientShare.swift` / `BackendMcpClientShare`; names-only typed export boundary, exact ordered JSON fields/two spaces/newline, safe filename and draft-only import with 32-name limit |

Source checklist total 7: done 7; in progress 0; blocked 0; queued 0. **Separate integration/validation work remains below.**

## Shared foundations reused

- `NativeRPCValue`, `OrderedJSON` and `NativeChannelRegistry` provide ordered JSON, JavaScript number rendering, missing/null semantics, handler dispatch and event teardown. Existing `McpAddScope` and `McpAddTransport` are reused; UI view models are not redefined.
- `BackendNativeProviders.loginPath()` and `.lookup()` provide the existing executable resolution. Production `BackendMcpClientWriter` resolves bare `claude`, `which` and shell commands to an absolute **existing** `BackendGitExecutionPlan` before calling `BackendDevProcessExecutor`. Missing executables produce `BackendGitOutcome.missing`, rather than failing the executor's absolute-path guard.
- `BackendMCPTools.swift` / `BackendNativeMCPServer` and `BackendMCPStdioRelay` serve app tools in the other direction. This port is a client inspector for user-configured external servers and does not create another app MCP server/grant type.

## Exact startup and shutdown wiring

The integration worker should retain one `BackendMcpClientService`, pool and store for the app's lifetime, using the authoritative account home/environment and the existing provider instance:

```swift
let config = BackendMcpClientConfiguration(home: accountHome, environment: inheritedEnvironment)
let writer = BackendMcpClientWriter(configuration: config, providers: providers)
let pool = BackendMcpClientPool(
    configuration: config,
    loginPath: { try await providers.loginPath() },
    outputValidator: actualOutputSchemaValidator // see dependency below
)
let service = BackendMcpClientService(
    writer: writer, pool: pool,
    saveChooser: chooseMcpSaveFile,
    openChooser: chooseMcpToolFile
)
try await BackendMcpClientChannels.register(registry: registry, ownerID: "mcp-clients", service: service)
// During orderly quit, before shutting down the shared registry:
await service.stopAll()
```

Registration is idempotent for one retained service/registry and concurrent calls share the same registration task. A failed partial registration removes only channels owned by this registration. Use one app registry: registering one service into additional registries replaces its status sink with the most recent registry.

Tracked-file edits required from the integration owner, **not made by this worker**:

1. `Sources/TerminalDeckNative/TerminalDeckNativeApp.swift` / the assembled lifecycle owner: construct/retain this service after the actual state/provider graph exists; call `stopAll()` before teardown.
2. (7 Oct: `NativeStateIPCService` and `native-state:call` were removed with the Node engine; registrations go on the composition root's registry.) Historical: `NativeStateIPCService.swift` constructed a registry but exposed only `native-state:call`. Add these registration calls to the shared domain registry composition; do not create a second authoritative Store or a second pool. If this service remains the composition owner, expose its domain invoke/event access separately from its Store-method guard.
3. `Sources/TerminalDeckNative/EngineBridge.swift` currently routes every screen request to the Node `/__td/invoke` endpoint. Route exactly the channels below to the registered native dispatcher with `.nativeApp` context, preserve the existing invoke envelope/ordered value conversion, and forward `mcp:state` from registry events into its listeners. Keep existing NativeMcp screens/model shapes unchanged.
4. Native app dialog owner: provide `@MainActor` `NSSavePanel` / `NSOpenPanel` closures that return the user's selected path or nil. Paths are never accepted from renderer arguments. Suggested export name comes from `fileName`; import is a shared `.mcpserver.json` JSON definition. Nil means an actual cancellation and returns `{ok:true,message:""}`. Absent closures return explicit unavailable messages.
5. `macos/TerminalDeckNative/Package.swift` currently declares only `TerminalDeckNativeCoreTests`. Add `.testTarget(name: "TerminalDeckBackendTests", dependencies: ["TerminalDeckBackend", "TerminalDeckNativeCore"])` once for the fleet's shared backend tests. The worker did not edit the package or run them.
6. Remove the old Mac `registerMcpIpc` / pool registration from `src/main/index.ts` when these channels transfer to native ownership; leave Linux/server registration unchanged. The same retained service should back the owner-authorized `deck-control/mcp-server-tools.ts` and remote panels' native adapters. Their registration/consent owners must still enforce the existing grants and strip env values for guest projections.

## Channel contracts

All invoke results use `NativeRPCValue`, with the exact fields already read by `McpModel`, `McpStoreModel`, `NativeMcpScreen`, `NativeMcpStore` and `NativeMcpForms`.

| Channel | Arguments | Result |
|---|---|---|
| `mcp:list` | `projectPath?` | `McpServerStatus[]` |
| `mcp:add` | add request | `{ok,message}` |
| `mcp:remove` | remove request | `{ok,message}` |
| `mcp:edit` | `{name,scope,next}` | `{ok,message}` |
| `mcp:store` | `projectPath?` | `{rows,runtimes,writer,environmentSource,projectPath}` |
| `mcp:store-install` | `{id,scope?,projectPath?,values}` | `{ok,message}` |
| `mcp:export` | `name,scope,projectPath?` | `{ok,message}` |
| `mcp:import` | none | `{ok,message,draft?}`; import never writes provider config |
| `mcp:connect` | `serverId,projectPath?` | `McpServerStatus` |
| `mcp:disconnect` | `serverId` | status or null |
| `mcp:inventory` | `serverId,projectPath?` | `{serverId,tools,resources,resourceTemplates,prompts,errors,status}` |
| `mcp:call` | `serverId,tool,args,projectPath?` | `{ok,result,error,durationMs,truncated}` |
| `mcp:read-resource` | `serverId,uri,projectPath?` | call result |
| `mcp:get-prompt` | `serverId,name,args,projectPath?` | call result, prompt args coerced to strings |
| `mcp:state` | **push**, one status argument | connection changes; registry listener ownership handles teardown |

Connect/inventory/call/resource/prompt resolve only a server ID already present in current configuration. The caller cannot supply a command to the connection path. Registry handlers accept app-owned native/internal callers only, matching the original Electron-window boundary; direct service use by remote/MCP adapters requires their established owner grants.

## Persistence, limits and timeouts

- Config discovery reads `~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`; settings are `~/.claude/settings.json` or that overridden directory's `settings.json`; project definitions are `<project>/.mcp.json`; private local definitions are `projects[<normalized absolute project>].mcpServers`. Precedence remains local > project > user. Rejection beats explicit/blanket approval; pending project servers remain visible.
- Config files must be regular files, at most 4 MiB; invalid JSON/failure loses only that source. Reads preserve source key order through the existing codec. `${VAR}` / `${VAR:-fallback}` expansion preserves unresolved references. The inspector does not read/write the live data folder during construction.
- Provider config **writes never round-trip the whole file**. They call `claude mcp add/remove` with validated argv, the correct cwd and login PATH; thus the owning CLI keeps its file schema/state. Share files use the source's exact ordered 8 fields and names-only env list, two-space JSON, one final newline.
- Connect/list/tool/close defaults: **20,000 / 15,000 / 60,000 / 3,000 ms**; invalid overrides ignored. Runtime probes **5,000 ms**; environment names probe **10,000 ms**; config CLI writes **30,000 ms**. The fixed `printenv | sed` script emits names, never values; reload starts a fresh environment probe, with only overlapping facts reads sharing work.
- Pool sharing, stderr **8,000 UTF-16 units**, results **512 Ki UTF-16 units**, listings **50 pages** and repeated-cursor stop are implemented. Optional `-32601` listing errors are suppressed; other section errors remain separate. Initialized protocol versions mirror installed SDK constants through `2025-11-25`; no sampling/elicitation capability is advertised; incoming ping is answered, other unsolicited methods refused.
- Native transport uses the shared codec's **64 MiB / 64-level** envelope bounds, nonblocking stdout/stderr drains on one queue, and drains final bytes before process exit rejects pending calls. Close terminates the child and escalates to SIGKILL after one second if needed. New code only; process behavior remains unverified.

## Protocols and suppliers

| Protocol / closure | Supply owner | Current behavior |
|---|---|---|
| `BackendMcpClientTransport` | Native implementation supplied here by `BackendMcpClientStdioTransport`; optional fake transport for tests | Real stdio process/JSON-RPC implementation exists; HTTP/SSE inspector remains refused exactly as source |
| `BackendMcpClientOutputValidating` | Integration/domain validation owner must supply a real arbitrary JSON Schema validator to `BackendMcpClientPool(outputValidator:)` | Replaces the installed JS SDK's Ajv dependency. If a listed output-schema tool returns structured output without a supplier, result is `{ok:false,error:"MCP tool output schema validation is unavailable."}`. Missing structured content and required-task tools retain explicit SDK-style refusals. No validator success is invented |
| `BackendMcpClientWriter.Run`, `loginPath` | Production overload reuses `BackendNativeProviders` and `BackendDevProcessExecutor` | Actual bounded argv execution; injected closures only for deterministic tests |
| `SaveChooser` / `OpenChooser` | Native AppKit dialog owner | Missing chooser reports `This build cannot save/open a file.` |

## Provider scope evidence and genuine gaps

The seven assigned TypeScript modules and today's native MCP forms **only implement Claude Code configuration**. There is no `provider`/`agents` selector in their request shapes. `NativeMcpScreen` says “Read from your Claude Code configuration”; `NativeMcpStore` likewise says install writes Claude Code configuration. This port does not silently claim generic Codex/Gemini store mutation support.

Existing cross-provider MCP launch behavior is separate: `src/main/staysfixed/agents.ts:agentLaunch` writes Claude `--mcp-config` JSON, Codex `-c mcp_servers.<name>.command/args/env/tool_timeout_sec` TOML overrides, and a Gemini system-defaults JSON merge through `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`. Those formats are **already ported by the session/project-tools lane in `BackendProjectToolComposition.swift`** (Claude at lines 153–155, Codex 157–160, Gemini 164–174). Reuse that path; Stays Fixed's assigned owner supplies its actual server definition. `src/main/tasks/agent-inventory.ts:codexServers` reads TOML table names only and is not a Codex generic writer.

Remaining gaps, stated plainly:

- No arbitrary output JSON Schema validator is supplied by this worker; that capability is unavailable until its named integration dependency is implemented/provided. The plain MCP result/listing public shapes are validated here; this is not a complete clone of every installed SDK Zod annotation/icon/URI constraint or Ajv error diagnostic.
- Generic add/edit/remove/discovery for Codex and Gemini **does not exist in these source modules or current native consumer contracts**. Delivering new generic provider store controls needs an explicit request schema/UI scope from orchestration; their existing Stays Fixed session configuration remains under its original owner.
- Source HTTP/SSE inspector refusal retained. Source edit reader does not read HTTP headers; saving replaces supplied headers, and rollback only carries the source's command/URL/env fields. This original limitation remains and is already explained in `NativeMcpForms`.
- External catalogue servers can themselves depend on user-installed Node/Python/Docker. The new app-side clients require no bundled Node SDK. Removing Terminal Deck's transitional engine is the integration gate, not proof those third-party servers require no runtime.
- Native dispatch/lifecycle/dialog/event wiring and the backend test-target addition are pending. No build, test, visual, live config interoperability, process lifecycle or app reachability is verified.

## Static review and test-source mapping

Read the seven sources and their `.test.ts` files, native MCP model/screens, shared bridge/process/provider foundations and existing project-tool serialization. Reviewed new files for config ownership, names-only share/store boundaries, scope refusals, process cleanup, caller lookup, paging and deadlines. A read-only lexical delimiter scan of the initial 12 Swift files reported balanced delimiters; later edits received further source review, not a compiler result. Root review found and this worker corrected the bare-command executor adapter and final-stdout/exit ordering issues.

- `BackendMcpClientRulesTests.swift` (15 functions): `mcp-catalogue`, `mcp-client` discovery, `mcp-add` tokenizer/validation, `mcp-custom`, `mcp-store` rules, `mcp-edit` env merge and `mcp-share` format/parser rules.
- `BackendMcpClientWriterTests.swift` (8 functions): owner CLI argv/cwd/PATH/missing/error shapes, rollback/prevalidation, runtime refusal, names-only probing, explicit missing dialogs and production executable-plan resolution without spawning.
- `BackendMcpClientPoolTests.swift` (12 functions): handshake sharing, unsupported/failed cleanup, section isolation, repeated/fifty-page limits, result errors, deadlines, UTF-16 cap, registration/caller lookup, output-validator/task refusals and config/runtime merge.
- `BackendMcpClientTransportTests.swift` (2 functions): real fixture pipe final-reply drain and stderr/RPC error delivery, **written for the final combined gate and not run**.

Safe next action: integration owner reviews these new sources, supplies schema validation/dialog/domain routing, adds the existing fleet backend test target, and includes these files in the single final combined gate. Do not mark MCP runtime migration complete from this source handoff alone.
