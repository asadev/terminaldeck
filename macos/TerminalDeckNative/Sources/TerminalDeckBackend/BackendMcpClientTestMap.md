# MCP source test map

Local source mapping, 6 October 2026. This is a written test port, not a test-run result. No compiler, build, test runner, Node probe, app, live-data access or credential read was used.

**201 declared TypeScript `it` cases: 199 ported, 2 skipped (Windows execution only).** The quoteArgv declaration expands to six fixture cases in TypeScript; all six vectors are present in Swift, so there are 206 fixture-expanded source cases: 204 ported, 2 skipped. New parity coverage: **7 Swift files, 55 `@Test` functions** (one shared-fakes file has no test declaration). Existing RulesTests covers the first three catalogue cases; every table below names a concrete Swift function.

## Test map

| TypeScript file | Declared cases | Ported / skipped | Swift source |
|---|---:|---|---|
| `src/main/mcp-catalogue.test.ts` | 20 | 20 ported / 0 skipped | `BackendMcpClientRulesTests.swift`, `BackendMcpClientParityCatalogueCustom.swift` |
| `src/main/mcp-client.test.ts` | 73 | 73 ported / 0 skipped | `BackendMcpClientParityDiscovery.swift`, `BackendMcpClientParityPool.swift`, `BackendMcpClientParityChannelsPayload.swift` |
| `src/main/mcp-store.test.ts` | 30 | 29 ported / 1 skipped | `BackendMcpClientParityStore.swift` |
| `src/main/mcp-add.test.ts` | 37 | 36 ported / 1 skipped | `BackendMcpClientParityAddEditShare.swift` |
| `src/main/mcp-custom.test.ts` | 18 | 18 ported / 0 skipped | `BackendMcpClientParityCatalogueCustom.swift` |
| `src/main/mcp-edit.test.ts` | 15 | 15 ported / 0 skipped | `BackendMcpClientParityAddEditShare.swift` |
| `src/main/mcp-share.test.ts` | 8 | 8 ported / 0 skipped | `BackendMcpClientParityAddEditShare.swift` |

## Deterministic seams and boundaries

- `BackendMcpClientDeadlineScheduling` is injected into the existing race, pool and stdio request deadlines. Production defaults to `BackendMcpClientDispatchScheduler`; `McpParityClock` manually advances the same scheduled race closures. It releases its own lock before firing callbacks. Source race cancellation/resume also happens outside the race lock.
- `McpParityTransport`, `McpParityFactory`, `McpParityRuns`, continuation gates and event recorders replace SDK processes, network replies, CLI writes and wall clocks. No real sleeps or polling loops are used. The earlier own 60-second sleep fixture was changed to this same manual seam, after read-only git verification that the file was untracked.
- JSON-reader/edit source cases use only explicit random temporary fixture directories. The port does not open the live home/config/data folder. Custom binary existence and environment-name wanted keys are injectable in the actual Store path; the tests never probe the host binaries.
- Existing pure scope-gate/map/merge logic was extracted into callable Configuration helpers, and existing custom/install rules into callable Store helpers; actual collect/view/install uses them. They are not test-only copies of an implementation.
- Electron IPC registration intent is ported to the real NativeChannelRegistry; these source tests only stubbed Electron and are portable. Explicit Windows console-window/process-environment branches are skipped below. Windows-looking runtime/parser strings and the portable PATH spelling assertion remain covered.
- Catalogue screenshot search preserves the Playwright assertion; the puppeteer-only subexpectation is retired by Asad's Chrome removal. This is a partial Chrome-only expectation retirement, not a skip of the whole portable search case.
- Swift NativeRPCValue cannot contain a JavaScript object-identity cycle. The circular-payload source case is ported through its intent/exact expectation (`truncated == true` for an unserializable result): a value beyond the real codec depth bound is rejected and receives the exact serialization refusal note.
- No runnable `.live.test.ts` or `.electron-probe.ts` belongs to these seven supplied files. Existing explicit native pipe-fixture tests are separate from this TypeScript parity map and have not been run.

## `src/main/mcp-catalogue.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 32 | has a unique id and a unique server name for every row | 🟢 Ported — `BackendMcpClientRulesTests.swift` / `backendMcpClientCatalogueIsStaticCompleteAndChromeRowsRetired`. |
| 40 | names every row with something the CLI will accept as a positional | 🟢 Ported — `BackendMcpClientRulesTests.swift` / `backendMcpClientCatalogueIsStaticCompleteAndChromeRowsRetired`. |
| 49 | gives every row a token that actually appears in its own command | 🟢 Ported — `BackendMcpClientRulesTests.swift` / `backendMcpClientCatalogueIsStaticCompleteAndChromeRowsRetired`. |
| 63 | gives every row a token no other row would match | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTokensAndPlaceholdersAreUnambiguous`. |
| 75 | fills every placeholder from an input, and places every arg input | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTokensAndPlaceholdersAreUnambiguous`. |
| 94 | names every environment input with a shell identifier | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTokensAndPlaceholdersAreUnambiguous`. |
| 105 | gives every row a source and a package address that can be opened | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueSourceFieldsRuntimesAndShelvesAreComplete`. |
| 118 | has a runtime word and an install sentence for every runtime it uses | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueSourceFieldsRuntimesAndShelvesAreComplete`. |
| 125 | sits on exactly one shelf, and one the store draws | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueSourceFieldsRuntimesAndShelvesAreComplete`. |
| 139 | leaves no shelf empty, so every heading the store can draw has something under it | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueSourceFieldsRuntimesAndShelvesAreComplete`. |
| 148 | carries tags, in the words somebody would actually type | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 159 | answers the searches people arrive with rather than the names it happens to use | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. Puppeteer subexpectation retired (Chrome-only); all portable search expectations kept. |
| 180 | says what an archived row is, on the row | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 195 | names a price, and says more than the word when it is not free | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 211 | has more than one answer about price, or the field is decoration | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 220 | says what a hosted row is really installing, on the row | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 241 | answers the vendors people arrive with | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 259 | offers both halves of what was asked for | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueTagsSearchPricesAndMaintenanceClaims`. |
| 276 | collects only environment keys, never argument placeholders | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueKeysAndLookupRejectUnknownValues`. |
| 290 | finds a row by id and refuses anything that is not one | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCatalogueKeysAndLookupRejectUnknownValues`. |
## `src/main/mcp-client.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 177 | sits beside ~/.claude, not inside it, on a default install | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityClaudeConfigPathsKeepDefaultOverrideAndEmptyOverrideRules`. |
| 182 | moves inside CLAUDE_CONFIG_DIR when that is set | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityClaudeConfigPathsKeepDefaultOverrideAndEmptyOverrideRules`. |
| 189 | ignores an empty override rather than reading from the filesystem root | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityClaudeConfigPathsKeepDefaultOverrideAndEmptyOverrideRules`. |
| 204 | returns null for a file that is not there | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityJSONReaderIsolatedTemporaryFilesMatchEveryFailureShape`. |
| 208 | returns null for truncated JSON instead of throwing | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityJSONReaderIsolatedTemporaryFilesMatchEveryFailureShape`. |
| 214 | parses a well-formed file | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityJSONReaderIsolatedTemporaryFilesMatchEveryFailureShape`. |
| 220 | refuses a path that is not a regular file rather than blocking on it | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityJSONReaderIsolatedTemporaryFilesMatchEveryFailureShape`. |
| 229 | substitutes a set variable | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityEnvironmentExpansionEveryFallbackAndMissingRule`. |
| 233 | falls back with the :- form | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityEnvironmentExpansionEveryFallbackAndMissingRule`. |
| 237 | leaves an unresolvable reference literal so the failure names itself | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityEnvironmentExpansionEveryFallbackAndMissingRule`. |
| 241 | treats an empty variable as unset | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityEnvironmentExpansionEveryFallbackAndMissingRule`. |
| 247 | reads a stdio server that declares no type | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 266 | reads the real shape of the user-scope entry on this machine | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 287 | infers sse from the declared type even when a command is also present | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 292 | rejects an entry with neither a command nor a url | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 296 | rejects a non-object entry | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 302 | coerces numeric args and env values rather than dropping them | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 308 | expands env references in command, args and env | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerEntryNarrowsTransportMalformedRowsAndNumericValues`. |
| 323 | keeps the good entries beside a broken one | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerMapKeepsSourceOrderAndGoodNeighbors`. |
| 333 | returns nothing for a missing map | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityServerMapKeepsSourceOrderAndGoodNeighbors`. |
| 344 | marks an unapproved project server pending rather than hiding it | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityProjectGatesPreservePendingExplicitApprovalAndRejectionPrecedence`. |
| 350 | approves a listed server | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityProjectGatesPreservePendingExplicitApprovalAndRejectionPrecedence`. |
| 356 | lets a rejection beat both the allow list and the blanket switch | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityProjectGatesPreservePendingExplicitApprovalAndRejectionPrecedence`. |
| 362 | leaves user and local scopes alone | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityProjectGatesPreservePendingExplicitApprovalAndRejectionPrecedence`. |
| 367 | reads gates from settings and from the project entry, keyed on the resolved path | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityProjectGatesPreservePendingExplicitApprovalAndRejectionPrecedence`. |
| 382 | lets local beat project beat user for the same name | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityScopeMergeLocalProjectUserPriorityAndNameSorting`. |
| 393 | sorts by name so the panel does not reshuffle between reads | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityScopeMergeLocalProjectUserPriorityAndNameSorting`. |
| 413 | merges user, project and local scopes for the open project | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityDiscoveryMergesOnlyTheOpenProjectsSourcesAndSurvivesMissingJSON`. |
| 433 | never leaks another project’s local servers | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityDiscoveryMergesOnlyTheOpenProjectsSourcesAndSurvivesMissingJSON`. |
| 446 | returns only user scope when no project is open | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityDiscoveryMergesOnlyTheOpenProjectsSourcesAndSurvivesMissingJSON`. |
| 459 | survives a config file that failed to parse | 🟢 Ported — `BackendMcpClientParityDiscovery.swift` / `mcpParityDiscoveryMergesOnlyTheOpenProjectsSourcesAndSurvivesMissingJSON`. |
| 477 | resolves when the work wins | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityDeadlineWorkWinsAndCancelsFakeTimer`. |
| 481 | rejects with a labelled message when the clock wins | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityDeadlineClockWinsWithExactLabelAndConsumesLateRejection`. |
| 486 | does not leave an unhandled rejection when the work fails after the timeout | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityDeadlineClockWinsWithExactLabelAndConsumesLateRejection`. |
| 502 | refuses a non-stdio server without building a transport | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolUnsupportedSpawnAndEnvironmentFailuresNeverRetainAConnection`. |
| 514 | reports a server that cannot start, and holds no connection afterwards | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolUnsupportedSpawnAndEnvironmentFailuresNeverRetainAConnection`. |
| 523 | times out a server that starts and never speaks | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolStartAndInitializeTimeoutsUseManualTimeAndReapTransport`. |
| 533 | times out a server that starts but never answers initialize | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolStartAndInitializeTimeoutsUseManualTimeAndReapTransport`. |
| 544 | records server info, capabilities and instructions on success | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolHandshakeMetadataReadyReuseAndIntentionalDisconnect`. |
| 555 | reuses a ready connection instead of spawning a second one | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolHandshakeMetadataReadyReuseAndIntentionalDisconnect`. |
| 565 | surfaces a failure to build the environment as a failed status | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolUnsupportedSpawnAndEnvironmentFailuresNeverRetainAConnection`. |
| 579 | marks the server closed and drops the handle so the next call reconnects | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolUnexpectedExitDropsHandleAndNextCallReconnects`. |
| 601 | does not report a crash for a close we asked for | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolHandshakeMetadataReadyReuseAndIntentionalDisconnect`. |
| 612 | ignores a disconnect for a server it never connected | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityPoolHandshakeMetadataReadyReuseAndIntentionalDisconnect`. |
| 628 | collects tools, resources, templates and prompts | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryCollectsEverySectionWithExactOptionalFieldShapes`. |
| 642 | skips sections the server never advertised, rather than reporting them as errors | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventorySkipsUnadvertisedAndUnsupportedOptionalSections`. |
| 653 | treats an unimplemented optional listing as empty, not as an error | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventorySkipsUnadvertisedAndUnsupportedOptionalSections`. |
| 673 | keeps the tools when one section fails | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryErrorsAndManualTimeoutDoNotLoseHealthySections`. |
| 689 | times out a section that hangs without losing the rest | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryErrorsAndManualTimeoutDoNotLoseHealthySections`. |
| 703 | follows pagination cursors | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryFollowsCursorsAndStopsAtTheFirstRepeat`. |
| 723 | returns an empty inventory rather than throwing when the server will not start | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryCannotStartReturnsFailedEmptyInventory`. |
| 733 | returns the result on success | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityCallsReturnWholeResultsReadableServerErrorsAndConnectionFailures`. |
| 747 | reports a tool that never answers as a timeout instead of hanging | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityToolCallTimeoutIsDrivenByTheSameRaceWithAFakeClock`. |
| 758 | reports a server-side error without throwing across IPC | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityCallsReturnWholeResultsReadableServerErrorsAndConnectionFailures`. |
| 771 | refuses to call on a server that could not connect | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityCallsReturnWholeResultsReadableServerErrorsAndConnectionFailures`. |
| 783 | ignores an explicitly undefined override instead of timing out instantly | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityTimeoutOverridesMatchEveryDefaultAndInvalidDurationCase`. |
| 791 | refuses a non-positive or non-finite duration | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityTimeoutOverridesMatchEveryDefaultAndInvalidDurationCase`. |
| 797 | takes a real override | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityTimeoutOverridesMatchEveryDefaultAndInvalidDurationCase`. |
| 808 | shares one handshake between overlapping callers instead of racing | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityConcurrentConnectsAndListingsShareOneProcessAndRetryCleanly`. |
| 836 | spawns one process for two overlapping listings, and both see the tools | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityConcurrentConnectsAndListingsShareOneProcessAndRetryCleanly`. |
| 862 | lets a failed connect be retried without the first failure poisoning the second | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityConcurrentConnectsAndListingsShareOneProcessAndRetryCleanly`. |
| 876 | closes a server that was still starting when quit began | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityQuitWaitsForPendingEnvironmentThenClosesEveryStartedServer`. |
| 901 | does nothing when it holds no connections | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityQuitWaitsForPendingEnvironmentThenClosesEveryStartedServer`. |
| 908 | reports the death in the inventory rather than rejecting into IPC | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryServerDeathBeforeListingReturnsInventoryFailure`. |
| 930 | stops when a server repeats its cursor instead of walking the page cap | 🟢 Ported — `BackendMcpClientParityPool.swift` / `mcpParityInventoryFollowsCursorsAndStopsAtTheFirstRepeat`. |
| 983 | claims every documented channel | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityChannelRegistrationAndAllBridgeRefusalsMatchSource`. Native registry replaces the stub Electron registry. |
| 1017 | is safe to call twice rather than taking the app down on a duplicate channel | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityChannelRegistrationAndAllBridgeRefusalsMatchSource`. Native registry replaces the stub Electron registry. |
| 1024 | refuses a relative project path instead of resolving it against the app cwd | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityChannelRegistrationAndAllBridgeRefusalsMatchSource`. Native registry replaces the stub Electron registry. |
| 1032 | will not dial a server the renderer named but the config does not contain | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityChannelRegistrationAndAllBridgeRefusalsMatchSource`. Native registry replaces the stub Electron registry. |
| 1043 | rejects malformed tool and prompt arguments before they reach a server | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityChannelRegistrationAndAllBridgeRefusalsMatchSource`. Native registry replaces the stub Electron registry. |
| 1058 | passes an ordinary result straight through | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityPayloadKeepsSmallReplacesOversizedAndReportsUnserializableValues`. |
| 1063 | replaces an enormous result with a preview | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityPayloadKeepsSmallReplacesOversizedAndReportsUnserializableValues`. |
| 1071 | does not throw on a circular result | 🟢 Ported — `BackendMcpClientParityChannelsPayload.swift` / `mcpParityPayloadKeepsSmallReplacesOversizedAndReportsUnserializableValues`. Unserializable native codec refusal maps the circular-object intent. |
## `src/main/mcp-store.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 116 | offers a row whose runtime is here | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 121 | refuses a row whose runtime is not, and says which binary was looked for | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 134 | knows its own row in the configuration by token, not by name alone | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 142 | shows an installed row what is actually configured, not the template | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 158 | will not touch a server that merely shares a name | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 174 | blocks every row when the tool that writes the configuration is missing | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 183 | marks an environment input as inheritable only when it was actually found | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 189 | never offers to inherit an argument | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityStoreStatesBlockingAndConfiguredCommandsMatchSource`. |
| 200 | substitutes an argument and quotes it | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 206 | refuses rather than leaving a placeholder in the command | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 216 | refuses a value that would split in the wrong place | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 223 | writes a typed secret as an environment pair | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 229 | leaves a secret to the shell when the shell already has it | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 241 | prefers what was typed over what the shell has | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 247 | refuses a required secret that is neither typed nor in the shell | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 251 | refuses a pasted value with a line break in it | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityBuildInstallQuotesPathsAndRefusesEveryUnfilledOrMalformedInput`. |
| 260 | takes only strings, and trims them | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityResolveInstallNarrowsValuesScopeAndEmptyRequests`. |
| 265 | falls back to user scope rather than guessing | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityResolveInstallNarrowsValuesScopeAndEmptyRequests`. |
| 269 | refuses nothing at all | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityResolveInstallNarrowsValuesScopeAndEmptyRequests`. |
| 293 | writes the whole server through the add path | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityCatalogueInstallationWritesExactRequestAndReprobesRuntime`. |
| 312 | re-probes the runtime rather than trusting the view | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityCatalogueInstallationWritesExactRequestAndReprobesRuntime`. |
| 329 | refuses to overwrite a server that already owns the name | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityInstallConflictsRequiredTokensAndUnknownRowsNeverWrite`. |
| 339 | says where a typed secret went, in the message | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityInstallMessagesSayExactlyWhereTokensWereKept`. |
| 352 | says when nothing was written down, because the shell already had it | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityInstallMessagesSayExactlyWhereTokensWereKept`. |
| 363 | refuses a required secret before it writes anything | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityInstallConflictsRequiredTokensAndUnknownRowsNeverWrite`. |
| 371 | never throws for an ordinary refusal | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityInstallConflictsRequiredTokensAndUnknownRowsNeverWrite`. |
| 382 | measures this machine once per read, and re-asks the shell on the next one | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityFactsRefreshAndEnvironmentNamesUseFakesOnly`. |
| 411 | reads this process’s own environment on Windows | ⚪ Skipped — Windows process-environment execution branch is not applicable on Mac. |
| 422 | claims nothing when the shell could not be asked | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityFactsRefreshAndEnvironmentNamesUseFakesOnly`. |
| 439 | keeps only the names it was asked about | 🟢 Ported — `BackendMcpClientParityStore.swift` / `mcpParityFactsRefreshAndEnvironmentNamesUseFakesOnly`. |
## `src/main/mcp-add.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 57 | survives a round trip: ${JSON.stringify(argv)} | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityArgvRoundTripsEverySourceVariantAndQuotesOnlyNecessaryTokens`. Six exact argv vectors. |
| 62 | leaves an ordinary command exactly as somebody would type it | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityArgvRoundTripsEverySourceVariantAndQuotesOnlyNecessaryTokens`. |
| 69 | quotes only what would otherwise re-tokenize as two arguments | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityArgvRoundTripsEverySourceVariantAndQuotesOnlyNecessaryTokens`. |
| 77 | splits a plain command line | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 86 | keeps a quoted path with a space in one piece | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 101 | treats single quotes as literal, the way a shell does | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 105 | honours escapes outside quotes and \" inside them | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 110 | keeps an explicitly empty argument | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 114 | collapses runs of whitespace rather than emitting blanks | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 119 | refuses an unclosed quote instead of guessing which half was meant | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityTokenizerPreservesEveryREADMECommandForm`. |
| 125 | puts the command behind -- so its own flags survive | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 144 | names the transport and passes a url straight through | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 165 | keeps the name out of reach of the variadic -e | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 172 | keeps the url out of reach of the variadic -H | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 179 | carries the scope the user picked | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 189 | sends environment variables as -e and headers as -H | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 198 | puts the single-value options before the name, where they are safe | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddArgsScopeSeparatorsAndVariadicOrderingAreExact`. |
| 210 | rejects a name that could impersonate a flag | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 219 | accepts the names people actually use | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 225 | refuses a project-shaped scope when there is no project | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 236 | requires the field belonging to the chosen transport | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 241 | refuses an unknown scope or transport rather than defaulting to one | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 246 | checks that extras are written the way their flag expects | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 253 | drops blank lines from the extras box instead of sending empty flags | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 257 | is not fooled by a payload that is not an object | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityAddValidationUsesExactRefusalsAndNarrowing`. |
| 267 | runs the CLI in the project folder, because two scopes are addressed by it | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact`. |
| 302 | reports a refusal from the CLI instead of claiming success | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact`. |
| 320 | names the missing CLI rather than reporting a bare ENOENT | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact`. |
| 331 | turns a validation failure into a sentence, never a rejection | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact`. |
| 348 | hands the child one spelling of PATH, holding the login value | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact`. |
| 376 | still confirms when the CLI succeeds without saying anything | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityWriterMessagesValidationAndInheritedEnvironmentStayExact`. |
| 384 | does not flash a console window over the settings panel on Windows | ⚪ Skipped — Windows console windowsHide behavior is not applicable on Mac. |
| 419 | names the scope, so a same-named server in another scope cannot go instead | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityRemoveScopeAndFailureMessagesRemainSpecific`. |
| 429 | refuses a name that could impersonate a flag | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityRemoveScopeAndFailureMessagesRemainSpecific`. |
| 439 | refuses a project scope with no project open | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityRemoveScopeAndFailureMessagesRemainSpecific`. |
| 443 | runs the CLI in the project folder and reports what it said | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityRemoveScopeAndFailureMessagesRemainSpecific`. |
| 463 | reports a refusal instead of claiming the server is gone | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityRemoveScopeAndFailureMessagesRemainSpecific`. |
## `src/main/mcp-custom.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 41 | takes the first token through the same tokenizer the add path uses | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomBinaryParsingDeduplicationAndPortableRuntimeStrings`. |
| 52 | answers nothing at all for a server that starts nothing on this machine | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomBinaryParsingDeduplicationAndPortableRuntimeStrings`. |
| 62 | makes no claim about a command it could not read | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomBinaryParsingDeduplicationAndPortableRuntimeStrings`. |
| 69 | asks for each binary once, however many servers use it | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomBinaryParsingDeduplicationAndPortableRuntimeStrings`. |
| 80 | maps a container command onto the docker runtime, so the Docker filter is right | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomBinaryParsingDeduplicationAndPortableRuntimeStrings`. |
| 94 | names the binary and where it was found | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomRowsExplainMeasuredMissingAndUnknownBinariesExactly`. |
| 98 | says the runtime is missing without turning the row into a warning | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomRowsExplainMeasuredMissingAndUnknownBinariesExactly`. |
| 116 | claims nothing when nothing was looked for | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomRowsExplainMeasuredMissingAndUnknownBinariesExactly`. |
| 125 | does not look for a binary for a server that is somewhere else | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomRowsExplainMeasuredMissingAndUnknownBinariesExactly`. |
| 137 | carries no homepage, package, licence or version | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomMetadataSecretsAndScopeIDsAreRestrained`. |
| 153 | sits on a shelf the catalogue can never fill | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomMetadataSecretsAndScopeIDsAreRestrained`. |
| 157 | prices nothing, and borrows nobody else’s mark | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomMetadataSecretsAndScopeIDsAreRestrained`. |
| 186 | says the variables it carries by name and never by value | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomMetadataSecretsAndScopeIDsAreRestrained`. |
| 194 | keeps two servers of one name in two scopes apart | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomMetadataSecretsAndScopeIDsAreRestrained`. |
| 205 | leaves out the ones a catalogue row already is | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomClaimsAndBothStoreDepartmentsStayConsistent`. |
| 214 | keeps a server that merely wears a catalogue name | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomClaimsAndBothStoreDepartmentsStayConsistent`. |
| 236 | puts a hand-written server in the store it was added from | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomClaimsAndBothStoreDepartmentsStayConsistent`. |
| 257 | does not draw a second row for a catalogue server that is installed | 🟢 Ported — `BackendMcpClientParityCatalogueCustom.swift` / `mcpParityCustomClaimsAndBothStoreDepartmentsStayConsistent`. |
## `src/main/mcp-edit.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 74 | carries a saved value through a line whose value is blank | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEnvironmentMergeKeepsReplacesDropsAndRefusesExactly`. |
| 81 | replaces one that was typed | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEnvironmentMergeKeepsReplacesDropsAndRefusesExactly`. |
| 85 | splits at the first = only, because values contain them | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEnvironmentMergeKeepsReplacesDropsAndRefusesExactly`. |
| 91 | drops a variable when its line is deleted | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEnvironmentMergeKeepsReplacesDropsAndRefusesExactly`. |
| 98 | refuses a blank value with nothing saved behind it, rather than writing an empty one | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEnvironmentMergeKeepsReplacesDropsAndRefusesExactly`. |
| 106 | holds the new server to every rule an add is held to | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditValidationAndMergeFailBeforeAnyWrite`. |
| 117 | refuses to edit a project-scoped server with no project open | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditValidationAndMergeFailBeforeAnyWrite`. |
| 130 | removes the old one and adds the new one, in that order, with the merged environment | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditWritesInOrderKeepsValuesAndNamesTheRename`. |
| 139 | addresses the removal by the name the server has now, not the one it is getting | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditWritesInOrderKeepsValuesAndNamesTheRename`. |
| 146 | says what it was called before, when the name changed | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditWritesInOrderKeepsValuesAndNamesTheRename`. |
| 152 | writes nothing at all when the merge cannot be done | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditValidationAndMergeFailBeforeAnyWrite`. |
| 167 | writes nothing when the remove fails | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditRemoveFailureAndMissingOriginalDoNotWriteReplacement`. |
| 175 | puts the original back when the add fails, and says so | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditRollbackRestoresExactOriginalArgvAndReportsBothOutcomes`. |
| 194 | says outright when the rollback also failed | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditRollbackRestoresExactOriginalArgvAndReportsBothOutcomes`. |
| 206 | refuses politely when the server has gone since the page was drawn | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityEditRemoveFailureAndMissingOriginalDoNotWriteReplacement`. |
## `src/main/mcp-share.test.ts`

| Line | Original TypeScript case | Status and exact Swift test |
|---:|---|---|
| 23 | holds the definition and the names of what it needs | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareDefinitionTransportFilenameAndRoundTripAreExact`. |
| 35 | cannot hold a value, because the shape it is given has nowhere to keep one | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareDefinitionTransportFilenameAndRoundTripAreExact`. |
| 50 | puts a URL under url and a command under command, never both | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareDefinitionTransportFilenameAndRoundTripAreExact`. |
| 57 | offers a filename that is safe on all three platforms | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareDefinitionTransportFilenameAndRoundTripAreExact`. |
| 65 | round-trips | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareDefinitionTransportFilenameAndRoundTripAreExact`. |
| 78 | says which field is wrong, not that "something went wrong" | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareParserNamesWrongFieldAndDropsForeignSecretValues`. |
| 100 | drops a value somebody hand-wrote into the env list | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareParserNamesWrongFieldAndDropsForeignSecretValues`. |
| 115 | narrows everything rather than trusting it | 🟢 Ported — `BackendMcpClientParityAddEditShare.swift` / `mcpParityShareParserNamesWrongFieldAndDropsForeignSecretValues`. |

## Review and next action

All 201 declarations were enumerated from source and mapped to existing function names in the written Swift files. That source/name inspection is not runtime verification. Parent reviews this map and the new tests, then the integration owner includes them in the single combined validation gate. The parent owns the aggregate clients handoff; this file is the new MCP test-map contribution.
