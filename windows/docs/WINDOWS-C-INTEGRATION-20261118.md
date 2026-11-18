# Windows C integration — source handoff

18 November 2026. This is local source, prepared for the parent's one focused Windows check. No build, test execution, Windows app launch, live account request, SSH, push or release was run in this integration lane. Native pictures and behavior remain unverified until the parent runs the prepared fixture. Browser B's pending hosting correction remains a separate join; no browser implementation files are edited here.

## Joined source and root wiring

- Merged root B `9518658`, retaining latest main and the Umer preservation correction.
- Relay lifecycle `2ad42123` is here as `30b5c49`.
- C integration/admission and isolated native fixture: `21e30ec`.
- Browser proof-start timing `2da36690` is here as `e8b6668`.
- Efficiency `1fa5606` is here as `8984769`; follow-up `836c0fe` as `8777acf`.
- Root initializes the subscription predicate before Cloud/Reach startup; supplies it to inbound Remote, outgoing OtherComputers and MCP relay admission; registers the plan spec/page; filters paid UI/tools/commands and refuses stale callbacks. Boot uses `StartAtLaunchAsync`, so unpaid access never prevents local initialization. Lapse keeps saved intent, peers, keys, trust and preferences. Existing loopback access remains local; new relay entrypoints refuse.
- Root calls `InitializeAgentBudgets()` once after Agents and Door exist, adds both efficiency/work specs and action tiers, and launches task chats through `AgentTaskChatDefinition(plan)` with `plan.ConversationId`.
- Source admission is immediate; serialized lifecycle cleanup follows. Reach suspension does not call `Gate.SignedOut`, switch off a saved gate, or forget outgoing connection intent. Account replacement and a true sign-out retain their existing cleanup.
- Already-open paid content collapses while retaining its model/draft. A Cloud manager confirmation rechecks its actual owner before each mutation. A returned preview is discarded after access loss. Device rename/sign-out callbacks recheck the current paid state before a request. Local artifact/GitHub/SSH/WhatsApp behavior is retained.

## Off means no change

`CloudSubscriptionSnapshot.AllowsCloudServices` is true for off, old and unavailable service answers; paid/gift is true when on. Only on+none/lapsed is denied. Off hides the subscription row/page/tool even when `offer=true`. Discovery is composed with any previous predicate. No tool grant or saved option is rewritten for a lapse. A subscription event only refreshes root surfaces when access or plan visibility changes; unrelated off-state Cloud events do not add root lifecycle work.

The [41-anchor source inventory](windows-c-paid-anchor-inventory-20261118.json) preserves all original Mac anchor numbers and maps them to actual Windows source and MCP owners. It explicitly marks partial/absent capabilities. This is a source mapping, not 41 native observations. Original Mac lane line offsets and some report descriptions are stale after consolidation; path/number identities are retained and current feature descriptions follow the consumer.

## Shared capability owners and approval

| Capability | Existing/shared owner and MCP | Change approval |
|---|---|---|
| Remote terminals, chats, options, account and usage | `OtherComputersService`, `ComputerOperations`, `OtherComputersChat`; `computers.services` | Reads/watch/options Read; chat send/answer/interrupt/set and controls/account changes Alter |
| Reach, peers, screens and host lifecycle | `ReachAccountCoordinator`, `RemoteService`, `OtherComputersService`; `cloud.reach.status`, `remote.manage`, `computers.manage/screen` | Existing grants and action tiers, plus current service admission |
| Chat → Hoot handoff | `ConversationHandoff`, existing Hoot background owner; `hoot.background.start` | Existing background-start policy; opposite-direction `hoot.handoff` unchanged |
| Code destination | Existing Files/GitHub/source control pages and `CodeMcp`; `code.*`, `ui.workspace`, `shell.read` | Existing read/change policy; legacy pin storage preserved through read aliases |
| At work / installed skills / assignments | `AgentService`, `AgentSkills`, `AgentSkillLibrary`; `agents.library` | Reads Read; save/assign/unassign Alter |
| Agent budgets / task limit / efficiency | `AgentBudgetRuntime`, task owner; `agents.efficiency` | Read/read-defaults/usage Read; policy/default/task-budget changes Alter |
| Shared heavy-work queue | `AgentHeavyWork`; `agents.work` | List/wait Read; acquire/release Act; one existing scoped caller policy |
| Plan | `CloudAccountClient`; `cloud.subscription` | Read only; phone store owns purchase/management |
| Cloud contents | Existing `CloudContents` and sync/file/artifact owners | Native manager mutations remain person-only under existing policy; no new mutation door introduced |

## Native scratch proof prepared for the parent

The branch is before AppRuntime, keeper, hooks, activation pointers and account initialization. It uses actual native pages with made-up local models and an in-memory HTTP service. It never calls an AI provider or an external service. All fixture files and pictures stay inside the explicit marked root. Installed account files, skill home folders and real session state are not enumerated. Invalid C proof arguments stop startup rather than falling through into the app runtime.

Parent runs the compiled **scratch** executable with a new `--user-data-dir=<scratch>` and process environment:

```powershell
$scratch = Join-Path $env:TEMP ('td-c-proof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
New-Item -ItemType File -Path (Join-Path $scratch '.c-parity-proof') | Out-Null
$env:TD_DEV = '1'
$env:TD_C_PARITY_PROOF = Join-Path $scratch 'proof'
# Launch only the scratch executable with --user-data-dir=$scratch.
# The fixture closes itself and writes proof/c-parity-proof.json.
```

The parent should set these only for that child process and clear them afterward. Expected output is 21 light/dark PNGs plus JSON `written`, `passed`, `failed`, stand-in and not-drawn boundaries. The JSON lists real control-tree/policy checks, not merely successful screenshots. Inspect whole frames and dense header/control crops. A zero-failure fixture is still fixture evidence.

Prepared screens: actual Agents At work/Skills/library; nine real efficiency controls and local budget dedup/warn/pause; native remote header with offered account/model/effort/device; real refusal for an ungranted capability and a stale granted action; actual Profile off+offer/none/gift/lapsed and on-state plan pages; retained draft collapse/restoration. The header has a made-up welcome snapshot and suppresses remote reads; it is not a connected-host test.

## Focused parent check scope — not run here

Run each changed class once on the joined source, not the full suite. Reuse any exact-source receipt already held by the parent; browser B checks remain its own receipt.

Core project `windows/tests/TerminalDeck.Core.Tests/TerminalDeck.Core.Tests.csproj`:

- `Agents.AgentBudgetTests`, `Agents.AgentHeavyWorkTests`, `Agents.AgentSkillLibraryTests`
- `Sessions.AgentIdleCompletionTests`, `Tasks.TaskEfficiencyTests`, `Tasks.AgentTaskRunnerTests`
- `Chats.ChatSessionsTests`, `Chats.W12ChatTests`
- `Cloud.CloudAccountTests`, `Cloud.CloudWiringTests`, `Cloud.CloudSubscriptionTests`, `Cloud.CloudContentsTests`, `Cloud.CloudTaskBudgetTests`
- `Computers.RemoteSessionReadingTests`, `Hoot.ConversationHandoffTests`, `Remote.CloudRelayLifecycleTests`, `Mcp.W12ShellContractTests`

Chat Windows project `windows/tests/TerminalDeck.Chat.Windows.Tests/TerminalDeck.Chat.Windows.Tests.csproj`: `AgentAddonLaunchTests`.

Shell tests project includes `Views/Windows/Tests/SidebarStateTests.cs` (legacy Code pin read-alias and raw persistence). Build the changed native app/keeper/tool bridge once with those checks using the parent's existing pipeline. Root integration adds 1 stale relay token test, 12 action-tier cases, 1 retained Cloud-manager callback test, and stale device assertions in the existing refresh test. These have not been executed here.

## Preservation and limits

Source blame audit against root B `9518658`: 213 removed baseline lines inspected; **0 Umer-authored lines removed or rewritten**. This is a read-only diff/blame check, not a substitute for the parent's established 250/250 exact-line proof against the original baseline.

- No Windows move/take protocol exists. Requirement 33 remains unsupported; no fake move action or local duplicate was added.
- Remote screens use only real advertised desktop displays. No Mac simulator layout or full local context-usage strip is implied by the remote header.
- Off-machine Cloud copies have no input. Live routing needs an actual reachable machine and exact session ID; failed reach preserves the copy/title.
- Remote Hoot lives in existing Services controls. Global remote Hoot/machine-scope selectors, per-kind sync switches and a separate Phones-copy switch have no Windows counterpart.
- Budget usage is provider-reported; unknown stays unknown. Pause blocks new tasks; running work continues. Context reuse requires exact compatible parked conversation. Park/Stop follows the task Done owner. The heavy-work queue is cooperative for agent builds/tests; manually started commands are not intercepted. Provider-specific add-on exclusions can refuse unsupported configurations rather than silently claiming exclusion.
- No live purchase, renewal, provider response, Hoot answer, relay disconnect timing, recovery, native appearance, or real account behavior is proven by this source handoff. Parent owns the final B join, focused compiler fixes, single scratch/native run and release.
