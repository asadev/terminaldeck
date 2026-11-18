# C check correction and receipt retention

Source preparation only, 18 November 2026. No tests or build were run by this worker.

The second C CI run `44244418695`, head `e603246694fcf7bec88070fd86a2eb420f46c70d`, checked source `288cd69d180ebab6432fa23dbb5fab9e65545867` (tree `11f471cff3e93013f58f713d6c5f8604e080a2ac`). Its Core receipt and TRX contain 155 results: **153 passed, 2 failed**. Chat Windows and Shell compiled but were never run. The immutable `windows-ui-check` artifact is `14400449087`, ZIP SHA-256 `005ecb222deb43fb142a6974c7093d69afd3c7fafa363155df11f208566af7ab`.

The failed pin rejection was **Store**, not Files. The original source has only one `pin-page` theory row, naming Store; its failure TRX identifies that row (xUnit abbreviates the displayed parameter). Store is in both the current sidebar catalogue and schema. Code and Files/SourceControl/GitHub are also supported canonical/read aliases. The obsolete Store rejection row was removed, and a separately named positive `SupportedStoreAndCodeAliasPinsUseTheExistingActContract` test covers those supported pages and their existing Act tier. The other rejection rows—sheet presentation, width999 and overlong rename—remain unchanged.

The Cloud budget correction uses separate durable `TaskStore.At(root)` owners, matching production, instead of independently cached memory stores. It preserves all narrowing/no-widening expectations. Only these two fixture files differ between the tested source and reviewed correction commit `847da8f34ce6aa4cb6727dfab816d8555d2330f1`; no production change is covered by this retention.

## Next selection

The C scope names exact methods, never whole classes. The six inherited A SidebarState cases remain unselected. It runs exactly:

| Project | Selection | Expected cases |
|---|---|---:|
| Core | New supported-pin fact and the previously failed Cloud budget method | 2 |
| Chat Windows | Five explicit AgentAddonLaunch methods (four Facts + three theory rows) | 7 |
| Shell | Only CodeAliasDoesNotWriteOrRewriteTheStoredPins and LegacyCodePinsMergeOnceAndKeepTheirOrderAndActions | 2 |
| Fresh total | No previously passed case selected | 11 |

`ui-check-evidence.py preflight` verifies the current source/selection boundary before any selected test runs. `retain` runs after those selected checks pass. It verifies the original CI metadata, artifact identity/digest, downloaded ZIP hash, original receipt source/tree/filter/counts and all original TRX result identities. It retains only the 153 Passed rows; neither failed result is counted as a pass. It also rejects any product/fixture change after the pinned correction and any fresh result matching a retained passed test ID. The current source-owned selection cannot expand the allowed paths or counts by editing metadata alone.

The final receipt keeps its eleven fresh results and adds an explicit retained section with the original 153 case identities, original failed identities, commit/tree/run/artifact provenance, content hashes and preserved original ZIP/receipt/TRX. `combined` can become 164/164 only after all eleven new cases pass. Old results keep their old source attribution. This is not a new execution of 164 tests.

The release workflow downloads the exact green current-commit CI artifact, then calls the same validator. The validator reopens the pinned ZIP and fresh TRXs, checks all counts and case identities and rechecks source bounds/tree. Failed evidence, a missing original, duplicate reruns, changed source, partial selection or forged combined counts prevent packaging. The exact-commit green CI requirement remains in place.

Pending B hosting/product changes are not silently included: the current bound rejects them. Join their own reviewed evidence and update the approved source boundary before claiming coverage of a later combined source.
