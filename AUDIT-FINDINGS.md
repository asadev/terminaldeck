# Audit findings — 2026-08-17

Four agents re-read both recordings, every recorded requirement, and drove the app.
**140 findings, 108 open.**
This file is the record; RELEASE-CHECK.md is the gate.


## HIGH

### [missing] "also bring the flow thing and all that stuff, all important stuff, maybe taking screenshot and sending to the agent directly from here and that all those features that we have in WebView and application and also bring to the WebView for localhost thing"
- **Where:** iOS — ios/TerminalDeck/Screens/LocalhostBrowser.swift, ios/TerminalDeck/Inspect/
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (line 1); also recorded in PLAN-LOCAL-FIRST.md:145 "flow and screenshot-to-agent in the mobile WebView"
- **Evidence:** grep -rni 'screenshot' and 'flow' across ios/TerminalDeck/**.swift returns ZERO hits in app source (only UITest helper screenshots). LocalhostBrowser's header has exactly one feature: inspect → ElementCapture → InspectSheet → sendToAgent. There is no capture-page button, no preview, no path, no recorder. The desktop got all three this week — src/renderer/browser/ScreenshotPopup.tsx, RecorderPanel.tsx, SendToAgent.tsx, AnchoredPopup.tsx all exist — so the asymmetry is one-directional: the phone gave the desktop its session-picker idiom and got nothing back.

### [missing] "in this list actually we need to be able to close something or put inside the list… archive or whatever or fold inside a list… when we do left right horizontal drag… we need to have any action like putting inside at least or… closing this completely deleting the session" — swipe actions on the SESSIONS list
- **Where:** iOS — ios/TerminalDeck/Screens/SessionListView.swift
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (line 1); PLAN-LOCAL-FIRST.md:144 "swipe actions on rows"
- **Evidence:** SessionListView is a ScrollView + LazyVStack (line 301-302), not a List, so `.swipeActions` is structurally impossible there; grep for swipeActions in that file returns nothing. The only row affordance is a `.contextMenu` with a single item, "Details" (line 324-329). He asked for swipe on BOTH lists — Localhost got it (LocalhostListView switched to a `List` explicitly for this, and its header says so), the sessions list did not. Worse, closing a session from a phone is not merely unbuilt, it is unrepresentable: ios/TerminalDeck/Protocol/WireProtocol.swift's ClientMessage enum has create/attach/detach/input/resize/ports/tunnel*/dev*/upload*/credential* and no close or kill verb, so this needs a desktop protocol change, not just an iOS view change.

### [missing] Tonight's entire iOS pass has never been compiled, never been tested, and is not in any build on his phone
- **Where:** iOS — whole target
- **Source:** His standing rule (memory: "Report unreleased work as unreleased" — "iOS is redesigned" was true of main while his phone had TestFlight build 3 and looked identical); RELEASE-CHECK.md:140 "needs a TestFlight build"
- **Evidence:** The uploaded IPA is from ios/build/release/upload.log, 2026-08-16 19:36 ("UPLOAD SUCCEEDED"), archived at 19:33. Every file of tonight's work is newer: DeckChrome.swift 17 Aug 02:20, LocalhostListView.swift 02:21, DeckTabs.swift 02:26, DeckModel.swift 02:37, Ports/PortCatalog.swift 01:11, GitHubSignIn.swift 01:37. `git status ios/` shows 25 modified + 9 untracked files, none committed. No build artifact anywhere is newer than 16 Aug 19:33: `find ios/build -newermt '2026-08-16 22:00'` is empty, ios/build/DerivedData/TestResults/metadata.db is 16 Aug 14:39, ios/build/verify last touched 16 Aug 16:59, and ~/Library/Developer/Xcode/DerivedData holds nothing newer than 14 Aug. So the new unit tests (BrowserBackTests, DeckChromeTests, PortBookTests, PortCatalogTests) and UI tests (LocalhostGroupingUITests, TerminalScrollUITests) have not run once, and it is not established that the target even builds.

### [missing] The release gate's own iOS checklist omits five items he recorded — so the gate can go green with them undone
- **Where:** RELEASE-CHECK.md (iOS section)
- **Source:** RELEASE-CHECK.md:112-119, compared against PLAN-LOCAL-FIRST.md:136-145 and the transcript
- **Evidence:** RELEASE-CHECK.md lists six iOS checks (three tabs, pill hidden, back button, GitHub sign-in, no notification spam, localhost folds/groups/renames). PLAN-LOCAL-FIRST.md's own iOS paragraph additionally names: swipe actions on rows; flow and screenshot-to-agent in the mobile WebView; start/stop a server from the phone; one-finger scroll still selects; possibly chat per session. Four of those five are undone (findings above). The gate that is supposed to stop a premature push does not ask about any of them.

### [missing] The marketing site sells cost tracking as a headline feature — in meta descriptions, JSON-LD and a whole homepage band — after he closed the feature entirely
- **Where:** Marketing site — index.html (lines 9, 22, 32, 513, 530, 560, 561, 780-802), about.html (lines 32, 572, 606, 623, 631, 774), 404.html:536
- **Source:** PLAN-LOCAL-FIRST.md:212-236 — "Let's not show any kind of price, any kind of cost… Close this."
- **Evidence:** index.html:780 opens a section `aria-labelledby="cost-heading"` titled "Cost and context"; the og/twitter descriptions and the schema.org featureList both promise "cost read from the agent's own transcript" and "Session inspector with timeline, cost breakdown". Meanwhile src/main/cost.ts and src/renderer/dashboard/widgets.tsx have deleted formatUsd, aggregateCost, SUBSCRIPTION_PLANS and the rate table, with cost.test.ts asserting no renderer file contains formatUsd. The moment this ships, the site's headline claim and its structured data are both false.

### [missing] "improve the website also accordingly" — the site is pinned at 0.1.8 while 0.1.9 and 0.2.0 are public
- **Where:** —
- **Source:** RELEASE-CHECK.md:146-147; gh release list
- **Evidence:** gh release list: v0.2.0 published 2026-08-16T15:27Z, v0.1.9 on 08-15. terminaldeck-site last commit is 2cc4898, 14 Aug, "Catch the site up to 0.1.8". The live page (curl https://terminaldeck.dev/) still renders 0.1.8; "0.1.8" appears in download.html ×6, index.html ×3, terms/security/privacy/about/roadmap. changelog.html's newest entry is 0.1.8, so 0.2.0's six-digit pairing, Artifacts, Overview board, Windows single title bar and the per-agent accounts are undocumented publicly. Binary downloads are fine — /api/download resolves releases/latest at request time — but api/download.js's FALLBACK_TAG is hardcoded 'v0.1.8' and is only re-pinned by a Vercel build, which has not run since.

### [missing] Tonight's new copilot session module skips the Windows branch of a two-branch platform switch
- **Where:** Windows — src/main/copilot-session.ts:617 (new, untracked), against src/main/host-core.ts:463
- **Source:** Scope item: "Windows-specific code paths in src/ — anything guarded by platform that tonight's work touched and may have skipped"
- **Evidence:** host-core.ts:463 does it correctly: `confinementKind(platform) === 'appcontainer' ? windowsConfinedEnv(home) : confinedEnv(home)`, with a comment at :447-450 explaining that confinedEnv sets HOME and TMPDIR, "the POSIX spelling". copilot-session.ts — created tonight, `git status` shows it as `??` — calls `confinedEnv(home)` unconditionally at line 617 and never imports windowsConfinedEnv (grep confirms: the only two imports from confine are confinedEnv and confinementKind). On Windows that probe runs with HOME/TMPDIR set and USERPROFILE, APPDATA, LOCALAPPDATA, TEMP and TMP inherited from the real process env, so the copilot's confinement home is not applied — the exact failure the function's own comment warns about ("the probe would report the machine's login and call a signed-out copilot signed in").

### [missing] "I should be able to take anything from my PC to paste here… If I just click, it should just open browse my file manager of the PC or Windows or MacBook and I should be able to just choose something from there instead of opening something inside. I don't know. It doesn't make any sense to me." (also: "Add an image also keeps me in the same folder")
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/chat/attach/AttachPicker.tsx, /Users/apple/Projects/terminaldeck/src/renderer/chat/attach/AttachMenu.tsx, /Users/apple/Projects/terminaldeck/src/renderer/components/ChatComposer.tsx
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (composer ＋ menu walkthrough). Recorded in NEITHER VIDEO-FEEDBACK.md nor PLAN-LOCAL-FIRST.md — dropped by the earlier pass.
- **Evidence:** AttachPicker.tsx lines 6-20 state the opposite as policy: "This is a project-scoped picker rather than a native open dialog, and that is a decision rather than a shortcut." It calls `searchProjectFiles({root})` only. AttachMenu's four rows (Add files / Add folder / Add an image / Connectors) all route into that same in-project picker — there is no "Browse…" row. `grep -n 'onDrop|dragover|DataTransfer|onPaste' ChatComposer.tsx chat/attach/*.tsx` returns nothing, so there is no drag-drop or paste escape hatch either. Main has `dialog.showOpenDialog` wired only for `project:pick` (src/main/index.ts:783). Net: there is currently no way to attach a file from outside the open project.

### [missing] "there should be a plus button to add with the big list of type of AI agents to connect, not only codex not only cloud code. There are so many grok agents… Just take a look how many types of agents and setup they have in cursor and in visual studio code… They should be able to connect a huge number of type of agents."
- **Where:** /Users/apple/Projects/terminaldeck/src/shared/agent-catalog.ts:168-300
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3 (Setup page). Also written down in PLAN-LOCAL-FIRST.md §B as "A `+` that offers many agents — Grok and the rest — not a hardcoded four."
- **Evidence:** `AGENT_CATALOG` is still `Record<ProviderId, AgentEntry>` with exactly four entries: claude, codex, gemini, shell. `AGENT_ENTRIES` lists the same four. `ProviderId` in src/shared/types.ts is the same closed union. No registry, no user-added agent, no Grok/Cursor-style catalogue. The plan file lists it as a requirement; nothing in the tree implements it.

### [missing] "So this draw option we need to have also and we can send it to the agent like this." — a draw/annotate tool in the built-in browser, alongside inspect / record / screenshot.
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/browser/ (Toolbar.tsx, modes.ts, RecorderPanel.tsx, CapturePopup.tsx)
- **Source:** VIDEO-2-TRANSCRIPT.txt para 2, said in passing right after the record-mode complaint. Appears in NEITHER VIDEO-FEEDBACK.md nor PLAN-LOCAL-FIRST.md §F — compressed away entirely.
- **Evidence:** `grep -rni 'draw|annotat' src/ --include=*.ts --include=*.tsx` (excluding the words drawer/drawn/draws/drawing) returns only prose about rendering — no annotation tool, no overlay canvas, no pen. `modes.ts` defines exactly two browser modes, `'inspect' | 'record'`. The browser toolbar (live screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/startpage.png) shows cursor, circle, camera, device, code and smiley icons — no draw tool.

### [missing] "and also bring that usage bar" — a usage-window bar beside the account: "for Claude we have a five hour window… how much limit is completed, how much is left, with the time of renewal."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/shell/SessionControls.tsx, /Users/apple/Projects/terminaldeck/src/renderer/components/ChatView.tsx:931
- **Source:** PLAN-LOCAL-FIRST.md "The account chip, as specified 2026-08-17" and "Per-pane chrome" — his own words quoted there; the same session-chrome ask as model/effort.
- **Evidence:** `grep -rn 'UsageStrip' src/renderer` outside its own folder returns exactly two live hits, both in ChatView.tsx — it is still chat-view furniture. The new `SessionControls.tsx` (written 04:11 tonight, now mounted in both PaneBar and WindowToolbar) imports ControlPicker/ControlSection/useSessionControls and nothing from `chat/usage`. The data source exists and works — src/main/plan-limit.ts parses limits with `resetsAt` — so this is placement, not feasibility. Live screenshot startpage.png: the session bar reads `Model Unknown · Effort Ultracode · Fast mode Not reported · Connectors` with no usage element.

### [missing] "Full suite green. Not a targeted run — the whole thing."
- **Where:** src/reachable.test.ts, src/main/title-bar.test.ts
- **Source:** RELEASE-CHECK.md:26 (Before pushing)
- **Evidence:** Ran `npx vitest run --maxWorkers=3` over the whole tree (7321 tests, 287 files): **3 failed**. `reachable.test.ts > has no unlisted orphans` and two in `title-bar.test.ts`. Re-ran both files alone at 04:19 — still 3 failures. The other four files RELEASE-CHECK listed as known-failing (finish, workspace-strip, shell, routines/engine typecheck) all PASS now.

### [missing] deck-control MCP server: "tools work; Alter tier genuinely blocks without consent"
- **Where:** src/main/deck-control/* (8 modules)
- **Source:** RELEASE-CHECK.md:106, COPILOT-DESIGN.md phase 2
- **Evidence:** The repo's own `reachable.test.ts` fails naming all eight: action-log, catalogue, consent, control, index, live-surface, server, surface — "cannot be reached from the running app". `grep` confirms nothing outside that folder imports it, and `src/main/index.ts` has zero occurrences of `deck-control`/`consent`. The consent broker is well built and default-denies, but it is never wired to a WebContents and there is no preload channel and no renderer dialog — so no Alter call can ever be approved, and none can ever be made either, because the server does not run. The gate does not "genuinely block"; it does not exist at runtime.

### [missing] Copilot phase 1 — "Its folder, memory and CLAUDE.md exist and are visible in Settings"
- **Where:** src/renderer/settings/sections/ (no Copilot section), userData/copilot/
- **Source:** RELEASE-CHECK.md:105, COPILOT-DESIGN.md "Order" step 1
- **Evidence:** Main-process side exists (copilot.ts, copilot-home.ts, copilot-session.ts, preload exposes ensureCopilot/copilotState/copilotFiles/stopCopilot/copilotSignIn). Renderer side: grep for copilotState|ensureCopilot|copilotFiles across src/renderer returns nothing. Settings nav read live from the running app = General, Appearance, Notifications, Agents, Tools, Browser, Power, Advanced, About (+Shortcuts, Help) — no Copilot pane. No pinned sidebar entry, no chat view. `ls ~/Library/Application Support/terminaldeck` and `.../Terminal Deck` — no `copilot/` folder has ever been created, because nothing calls `copilot:ensure`.

### [missing] "Action log records every call"
- **Where:** src/main/deck-control/action-log.ts
- **Source:** RELEASE-CHECK.md:107
- **Evidence:** Module is one of the eight unreachable ones. No Activity view in Settings. Nothing can write to `log/actions.jsonl` because no tool call is possible.

### [missing] "The account chip never says Default" — Settings → Agents → "Run them as"
- **Where:** src/renderer/settings/sections/AgentsSection.tsx:~208
- **Source:** RELEASE-CHECK.md:76 ("Small leftover, not yet done")
- **Evidence:** Read live in the running app: the dropdown offers `Default — your own install`, `Default (Codex CLI) — your own install`, `Default (Gemini CLI) — your own install`, Work, School. Source still renders `{profile.name}{profile.system ? ' — your own install' : ''}`. `profileLoginLabel` is exported and unused here. Exactly as RELEASE-CHECK predicted — still undone.

### [missing] "Login shows the email, not Default" — the sidebar session rows
- **Where:** src/renderer/shell/Sidebar.tsx:627 (and the tooltip at :570)
- **Source:** PLAN-LOCAL-FIRST.md §E, RELEASE-CHECK.md:86
- **Evidence:** Verified live twice, across an app restart: sidebar rows read `Session 5 Default`, `Session 7 Default`, `Session 8 Default`, `Update Claude C… D…`. Source prints `{tab.account.name}` raw — the profile slug, not `accountIdentity`. The same session's chip in the toolbar correctly reads `app.imatch.ae@gmail.com`, so the app shows two different names for one account, forty pixels apart. Tooltip at :570 does the same (`signed in as ${tab.account.name}`).

### [missing] "Alerts unread badge — known unwired; decide whether to wire or remove"
- **Where:** src/renderer/shell/Sidebar.tsx:993-998, src/renderer/App.tsx:1842 (<Sidebar …>)
- **Source:** RELEASE-CHECK.md:66
- **Evidence:** Confirmed still unwired, and I can say what it shows: **nothing, ever**. The bell renders a dot only `{alertCount > 0 && …}`; `alertCount` is a prop defaulting to 0 and App.tsx's `<Sidebar>` never passes it (nor `badges`). I opened the bell live — the popup listed "1 worth fixing, 1 worth knowing", i.e. 2 real alerts — and the bell carried no dot at all. The decision he was owed has not been made either way.

### [missing] "and also bring that usage bar" — usage next to the account, per pane
- **Where:** src/renderer/shell/SessionControls.tsx:107
- **Source:** PLAN-LOCAL-FIRST.md "Per-pane chrome" (§ What goes in that bar: account · model · effort · usage)
- **Evidence:** The controls cluster that landed at 04:11 is `CHROME_CONTROLS = ['model','effort','fast']` plus a Connectors chip. No usage. Read live off the running toolbar: `Model Unknown | Effort Ultracode | Fast mode Not reported | Connectors` — no usage/plan-limit element. `UsageStrip` still lives only in `src/renderer/chat/usage/` and is only mounted from the chat composer. The gating test he set (real reset time AND real consumed fraction, else build nothing and report what was checked) has no recorded answer anywhere I could find.

### [missing] "Power's own copy refutes its own switch"
- **Where:** src/renderer/settings/sections/PowerSection.tsx
- **Source:** PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 2
- **Evidence:** Read live, verbatim, unchanged. "Keep running with the lid closed" toggle is ON, and twenty pixels below: "While Terminal Deck is open, this Mac will not fall asleep on its own. **Closing the lid or choosing Sleep still does.**" Then, still on the same pane: "This was already on before the app started — it is a setting on the Mac, so something else may have set it." His bug report is still printed in the pane. Screenshot: /Users/apple/.claude/jobs/5ccc1804/tmp/set-Power.png

### [missing] "Build the real app and open it. Not the dev instance on 9444 — a packaged build."
- **Where:** n/a
- **Source:** RELEASE-CHECK.md:30
- **Evidence:** Not done. `out/` holds the electron-vite dev output and `npm run dev` is serving it. No packaged build was produced tonight and none could be — CLAUDE.md forbids `npm run build` while dev is live, and dev is live with six agents on it. Everything I verified, I verified in the dev instance.

### [missing] Windows title-bar overlay is painted a colour the toolbar no longer is
- **Where:** src/main/title-bar.ts:115, src/renderer/styles/tokens.css:420
- **Source:** RELEASE-CHECK.md:17 (title-bar.test.ts, 2 failures) — root cause found
- **Evidence:** The two title-bar failures are not flakes and are not the tab strip. The dark-flat pass set `--material-sheen: none` in dark; `title-bar.test.ts` computes the Windows overlay colour by integrating that gradient and now gets "no white stops in none". The shipped constant is still `dark: { color: '#282828' }`, while the running dark toolbar measures `rgb(25,25,25)`. On Windows in dark mode the native window-button strip will be painted three levels off the bar it sits in. This is a real regression from the appearance work, not just a stale test.

### [missing] "Align Windows — his PC is on 0.1.9, so this is a build ship" / iOS TestFlight build / push and tag macOS / write the summary list
- **Where:** n/a
- **Source:** RELEASE-CHECK.md:122-128
- **Evidence:** None of the four has happened. `git log` head is `9ede37c Pairing: one copy per machine…`; nothing tagged tonight. The working tree has ~200 modified files and untracked new modules.

### [missing] Split view: the per-pane Model / Effort / Fast mode controls overprint each other into unreadable mush. In the right pane the labels render as "UnLltnkoawn/Ultracode", "FastEsffcodrte", "NoConnecptorrsted".
- **Where:** src/renderer/chat/controls/AgentControls.css — .ac-picker (rendered in the split pane header)
- **Source:** Live app sweep, Split mode at 1440x900, dark theme
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/dark-full.png and zoom crop /Users/apple/.claude/jobs/5ccc1804/tmp/crop-dark-overlap.png. Measured live: the three right-pane .ac-picker elements have width 51/51/69px but scrollWidth 118/118/159px, with computed `overflow: visible`, `text-overflow: clip`, `min-width: 0`, `flex: 0 1 auto`. Flex shrinks the boxes; the text still paints at natural width and spills ~67px into each neighbour. The left pane's identical controls sit at full 118px and read fine, so the two panes disagree in the same frame.

### [missing] The Terminal / Chat / Split switch is cut off by the window edge at narrow widths — it renders as "Termina" and Chat and Split are entirely off-screen, so the view cannot be changed at all.
- **Where:** src/renderer/shell/WindowToolbar.tsx / ModeSwitch — toolbar row
- **Source:** Live app sweep at 760px window width
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/now.png and crop /Users/apple/.claude/jobs/5ccc1804/tmp/crop-toolbar-760.png. The app's own minimum is `minWidth: 720` (src/main/index.ts:480), so 760px is a legal, user-reachable size — this is not an artificial width. The toolbar neither wraps, scrolls, nor collapses; Model/Effort/Fast mode/Connectors keep full width while the mode switch and the session title are the parts sacrificed (the title collapses to a single glyph). At 980px and 1440px nothing is clipped, so it is width-dependent.

### [missing] Every app launch invalidates every installed hook. All three providers sit permanently on "Needs reinstalling — N events still point at a previous run of the app", and the user must click Reinstall three times on every start or the tab status feature silently stops working.
- **Where:** src/main/hook-server.ts:398 + src/main/hooks.ts:803; surfaced on the Hooks page and Settings → Agents → Session hooks
- **Source:** Live app sweep (Hooks page) + source verification
- **Evidence:** Hooks page text captured in /Users/apple/.claude/jobs/5ccc1804/tmp/sweep.txt lines 1061-1120: Claude Code "10 events", Codex CLI "5 events", Gemini CLI "7 events", all three "Needs reinstalling". Root cause verified in source: `next.listen(options.port ?? 0, HOST, …)` takes an ephemeral port every run and the token is fresh `randomBytes`, so previously written hooks always point at a dead port. `grep -rn installHooks src/main/` shows it is called only from hooks.ts itself and from the renderer (settings-bridge, SetupSection, HooksPanel) — nothing in the main process repairs hooks at boot. The Agents pane even states the cause plainly: "It moves to a new port every run, which is why hooks from a previous run need repairing."

### [partial] "Pushing live means you will test first all the versions — iOS and Windows" — no Windows verification has happened since before 0.2.0
- **Where:** Windows — his PC (imza-pc / DESKTOP-DDGMNCV), and /Users/apple/Projects/terminaldeck-windows-probes
- **Source:** RELEASE-CHECK.md:125-127 and :134-139 ("his PC is on 0.1.9, so this is a build ship")
- **Evidence:** The probe rig's newest file is p09-conpty-proof.ps1 at 16 Aug 04:00 — eleven hours before 0.2.0 was cut and a full day before tonight's 239 changed files in src/. 0.2.0 did publish Windows assets (terminaldeck-0.2.0-x64-setup.exe and -portable.exe are on the release), so the artefacts exist; what does not exist is any record of one being installed, launched or walked. I cannot verify his PC's version from here — that claim comes from the plan file, not from evidence — but I can verify that nothing on this machine has touched Windows since before the release.

### [partial] Chrome controls do not fold on a narrow window; the toolbar overflows
- **Where:** src/renderer/shell/SessionControls.tsx (useFoldedBar)
- **Source:** PLAN-LOCAL-FIRST.md "Per-pane chrome" (implied), src/renderer/shell/SessionControls.tsx:134 FOLD_BELOW_PX
- **Evidence:** Screenshot at /Users/apple/.claude/jobs/5ccc1804/tmp/final.png, taken while the window was ~760 CSS px wide (another agent had resized it): all four chips drawn expanded, the Terminal/Chat/Split switch clipped to "Termina" at the right edge, the session title reduced to a single "|" glyph, and the account chip wrapped onto a second line. `FOLD_BELOW_PX` is 900, so it should have folded. Also in the same frame the sidebar's unread dots are painted on top of the labels ("Sessio●2", "Sessio●3"). In an earlier split at ~560px pane width the pane bar's chips overlapped each other into unreadable text (/Users/apple/.claude/jobs/5ccc1804/tmp/chrome-controls2.png: "Model Unkflown UltEffodeFastcnode NoCompectors"). I could not re-create the narrow width deliberately, so I cannot say whether the ResizeObserver simply lags a live resize or never fires — but both frames are real settled screenshots.

### [partial] All of tonight's iOS work is uncommitted, so it is in no build he can install
- **Where:** ios/
- **Source:** PLAN-LOCAL-FIRST.md "iOS — recorded, not started"; RELEASE-CHECK.md:112-119
- **Evidence:** `git status ios/` shows 24 modified files plus four new untracked ones — `App/DeckChrome.swift`, `Screens/LocalhostListView.swift`, `Ports/`, `Tests/BrowserBackTests.swift`, `Tests/DeckChromeTests.swift`. The last iOS commit is `5fd30e7 iOS 0.2.0, build 2608161532`, which predates all of it. So the pill-hiding rule, the localhost list and the back-button work exist only on this disk. Worth stating plainly to him rather than as "iOS is done".

### [partial] The internal slug `Default` is still printed where a login should be named — in the sidebar rows, in the sidebar row tooltips ("signed in as Default"), and on the Overview session cards. This is the exact thing he reported: "Inside the terminal page it is still showing selected account as Default and not showing the email ID."
- **Where:** src/renderer/shell/Sidebar.tsx:627 and :570; src/renderer/dashboard/SessionBoard.tsx:243
- **Source:** Live app sweep; his complaint is quoted verbatim in src/renderer/accounts.ts:352-356 and :727
- **Evidence:** Live DOM read of the sidebar returned rows with `acctText: "Default"` and `title: "Session 5 — signed in as Default — double-click or F2 to rename"`. Overview text capture shows "Claude Code · Default · started 25m ago" on two cards (/Users/apple/.claude/jobs/5ccc1804/tmp/nav-overview.png). The fix exists and works — `accountIdentity()` in accounts.ts climbs to the real address and the AccountChip renders `app.imatch.ae@gmail.com` correctly in the same frame — but `grep -rn accountIdentity src/renderer/` shows only AccountChip.tsx and ProfilePicker.tsx call it. Sidebar.tsx and SessionBoard.tsx render `tab.account.name` / `session.account` raw. The fix landed on two of four surfaces.

### [regressed] "improve the website also accordingly" — the marketing site still advertises pairing by QR code, which 0.2.0 deleted outright
- **Where:** Marketing site — /Users/apple/Projects/terminaldeck-site/features.html:748 (repo asadev/terminaldeck-site, pointer in terminaldeck README.md:9)
- **Source:** His release-scope instruction quoted at RELEASE-CHECK.md:125-128; CHANGELOG.md 0.2.0 "the pairing link and the QR code are gone entirely — deleted, not hidden"
- **Evidence:** features.html:748 reads "Pair a phone by QR code and approve it on the desktop". CHANGELOG.md's 0.2.0 entry says the QR encoder, the iOS scanner and its camera permission, the Android scanner and its CAMERA permission and every terminaldeck://pair route were deleted; pairing is six digits on a numeric keypad. The page instructs a new user to do something the shipped app cannot do.

### [regressed] The marketing site still names Tailscale and "your own tailnet" as how a phone reaches the desktop
- **Where:** Marketing site — features.html:750, privacy.html:766
- **Source:** Standing rule in memory: "No Tailscale dependency, ever — the relay IS the network. Never present Tailscale as needed"; CHANGELOG.md 0.2.0 "The 'Direct on your tailnet' card is gone. The relay is the network."
- **Evidence:** features.html:750: "neither needs a port forwarded: your own tailnet, where Tailscale…". privacy.html:766: "If you run Tailscale, a phone can come over your own tailnet instead…". The app removed the tailnet card in 0.2.0 and commit 388ee5b is literally titled "Tailscale leaves the product's face". The public site is the one surface still putting it there.


## MEDIUM

### [missing] "web app, mobile app, all of the versions" — the public site never mentions the web app or the iPhone app at all
- **Where:** Marketing site — index.html, download.html, features.html
- **Source:** RELEASE-CHECK.md:125-128 quoting him
- **Evidence:** grep for app.terminaldeck.dev across the site hits exactly one file, review.html — an unlisted page. Download and index offer only the macOS dmg and the two Windows exes. "iPhone" and "App Store" appear only inside changelog.html and review.html; there is no TestFlight link, no iOS section, no web-client entry point. Someone told "we have a web app and a phone app" cannot find either from the homepage.

### [missing] The web app has no counterpart for tonight's Localhost work — no grouping, no folding, no renaming, no row actions
- **Where:** Web app — pwa/src/main.ts (localhostScreen, ~line 1163), pwa/src/localhost.ts
- **Source:** His "web app also, improve according to the new things" (RELEASE-CHECK.md:128); the iOS Localhost tab built tonight
- **Evidence:** pwa's localhostScreen() is portsInto() + devInto() + one footnote — a flat list, exactly the wall he objected to on the phone. Nothing in pwa/src holds a per-port name, a category or a fold state; there is no equivalent of ios/TerminalDeck/Ports/PortBook.swift or PortCatalog.swift. All three are pure client-side features that a browser can do (unlike page rendering, which localhost.ts correctly proves it cannot). Last pwa commit is aa08a84, 16 Aug 19:04 — before the iOS localhost work existed.

### [missing] The web app has no Settings surface, no Machines screen and pairs with only one machine, while iOS now has all three
- **Where:** Web app — pwa/src/main.ts:127 (`type Screen = 'pair' | 'sessions' | 'localhost' | 'terminal'`), renderTabs ~line 1012
- **Source:** Alignment requirement, RELEASE-CHECK.md:142
- **Evidence:** The tab strip is built from exactly two entries, Sessions and Localhost (main.ts:1022-1023). There is no Settings tab, no Machines list, no text-size control, no alerts. main.ts's own comments describe a single paired machine ("the machine it is paired with"), where DeckModel on iOS holds `hosts` and a switcher. The web client also has no notification path at all (grep: no Notification API, only a service-worker registration for offline). So Sessions/Localhost/Settings-with-Machines exists on one of the two phone-shaped clients.

### [missing] Android is far behind and has had no decision recorded about whether it is in this release
- **Where:** Android — android/app/src/main/java/dev/terminaldeck/android/
- **Source:** RELEASE-CHECK.md:144 — "establish what state it is in; align or say plainly it is out of scope"
- **Evidence:** Seven UI files exist: PairingScreen, SessionListScreen, TerminalScreen, KeyBar, HostSwitcher, GitHubSheet, CredentialPrompt. There is no localhost screen, no port list, no dev-server control, no tunnel, no tabs, no settings screen, no alerts — grep for localhost/tunnel/ports across android/app/src/main returns one incidental comment in protocol/Messages.kt:550. Multi-host and GitHub sign-in did land (9e00c74). Last android commit is 3babd08, 16 Aug 07:03 — untouched by everything after the recording. The checklist item is still unticked and no one has written the in/out call.

### [missing] "maybe we can also have separations of like at one place we can see our cloud accounts at one place, all GPT codecs account separate, not at one place like this, all the login ones."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/settings/sections/AccountsSection.tsx:308-340
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3 (Accounts). Recorded in NEITHER plan file.
- **Evidence:** Accounts render as one flat `<ul className="settings-profiles">{accounts.map(...)}` with a 14px `<ProviderBadge>` on each row. There is no grouping by provider, no per-agent heading, no sort by provider. The file's own comment at 312-324 shows the consequence he is describing: three system rows all called "Default (…)" sitting next to each other in one list.

### [missing] "maybe you can make one section here for the tools where they can see all of the tools that their models can use and they can see them… So they understand which kind of tools their models are having."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/settings/sections/ToolsSection.tsx
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3 (after voice dictation). Recorded in NEITHER plan file — the plan captured only "rename Features to Tools, keep voice dictation".
- **Evidence:** The whole section is 111 lines and renders exactly one Group ("Voice dictation") containing one Switch and one Explain. There is no list of the tools a model can call — no Read/Write/Bash/WebSearch inventory, no MCP tool roll-up. The section blurb in settings-schema.ts:114 says "Extra tools a session can use", which promises the list he asked for and does not draw it.

### [missing] A browser tab sitting on the app's own start page identifies itself as `about:blank` — in the sidebar, the tab strip, the pane bar and the address field. Against "a new browser tab… should open on a real start page" and his blanket "it is just like jargon for them".
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/App.tsx:765-786 (`renameBrowserTab`, initial label 'New tab'), /Users/apple/Projects/terminaldeck/src/renderer/browser/BrowserWorkspace.tsx:174
- **Source:** VIDEO-FEEDBACK.md "The built-in browser" + VIDEO-2-TRANSCRIPT.txt para 2/3 jargon rule. Found live, not in either plan file.
- **Evidence:** Observed live twice. Sidebar innerText read `about:blank` for two rows; after I opened a fresh tab with the strip globe, /Users/apple/.claude/jobs/5ccc1804/tmp/startpage.png shows the tab pill, the pane bar and the omnibox all reading `about:blank` while the pane correctly renders the "Open a page" start page. Cause: the tab starts as "New tab", then the page reports its title and `renameBrowserTab` overwrites it with the document title of `about:blank`. `onStartPage()` already knows this state — the label just does not consult it.

### [missing] "Copilot sessions grouped separately in the sidebar"
- **Where:** src/renderer/shell/Sidebar.tsx
- **Source:** RELEASE-CHECK.md:109
- **Evidence:** No `origin: 'copilot'` field on session metadata, no Copilot group in the sidebar's render. Sidebar groups by project only (verified live: terminaldeck / science-locus).

### [missing] "The account chip never says Default" — Overview session cards
- **Where:** src/renderer/dashboard/SessionBoard.tsx:242
- **Source:** RELEASE-CHECK.md:86
- **Evidence:** Overview read live: cards say `Claude Code · Default · started 25m ago` (two of them). Source interpolates `session.account` raw.

### [missing] "The account chip never says Default" — Settings → Agents → Accounts rows, and the chip's own menu
- **Where:** src/renderer/settings/sections/AccountsSection.tsx:377, src/renderer/shell/AccountChip.tsx:703
- **Source:** RELEASE-CHECK.md:86
- **Evidence:** Accounts list read live inside Settings → Agents: rows titled `Default`, `Default (Codex CLI)`, `Default (Gemini CLI)`. Both files print `{account.name}` directly. So the slug leaks in six places total (sidebar row, sidebar tooltip, Run-them-as, Accounts rows, chip menu rows, Overview cards) while the two surfaces that were fixed — the chip label and the New-session dialog — are clean.

### [missing] The account chip's tooltip describes the wrong agent
- **Where:** src/renderer/shell/AccountChip.tsx:302 (`blocked = isolationNotice(provider)`), src/renderer/App.tsx (passes `defaultProvider`)
- **Source:** PLAN-LOCAL-FIRST.md "The account chip" (never say something untrue about identity)
- **Evidence:** Read live: in a Claude Code session, the chip's label is `app.imatch.ae@gmail.com` and its title attribute is "A plain shell has no account to sign in to." Same on the `School` chip in the other pane. The window chip is handed `defaultProvider` (Settings → Agents → Default coding tool, currently "Plain shell") instead of the session's own provider, so the tooltip describes the app's default agent, not the session it sits over. New bug, introduced with the chrome work tonight.

### [missing] "DECISION FOR HIM" — he asked for the selected pill to be lifted too; it cannot be lifted alone without lifting the terminal background
- **Where:** src/renderer/styles/tokens.css:192/231 and :367/380
- **Source:** RELEASE-CHECK.md:45-54
- **Evidence:** Still unresolved and still owed to him. Confirmed the constraint is real: light `--tab-active: #e8e8e8` and `--terminal-bg: #e8e8e8`; dark both `#191919`; `tokens.test.ts` holds them equal. Nothing in the tree records a decision either way, and nothing surfaces the question to him.

### [missing] "Advanced → Debug trace is badged `not created yet` and still offers live Copy and Reveal for a file that does not exist"
- **Where:** src/renderer/settings/sections/AdvancedSection.tsx
- **Source:** PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 14
- **Evidence:** Read live: "Debug trace / not created yet / Every IPC call, recorded while Debug mode is on. Off by default. / …/ipc-trace.log / Copy / Reveal". Unchanged. (The Open-vs-Reveal mixing in the same list now follows a defensible rule — Open for folders, Reveal for files — so I would not chase that half.)

### [missing] "The three yellow Browser warnings are word-for-word identical except the browser name … Chrome (14 profiles) advertised in a disabled segment while the only real profile picker is a bare Default dropdown 300px below"
- **Where:** src/renderer/settings/sections/BrowserSection.tsx
- **Source:** PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 7
- **Evidence:** Read live, unchanged: three consecutive paragraphs identical except for Chrome / Edge / Brave, each ending "…add this app, then run the import again." The segmented control still reads "Chrome (14 profiles) | Edge | Brave | Every browser", and 300px below there is still a separate flat list `Default, Profile 2, Profile 3, Profile 13, …, Profile 40`.

### [missing] "A + that offers many agents — Grok and the rest — the way Cursor and VS Code do, not a hardcoded four"
- **Where:** src/shared/types.ts:4, src/shared/agent-catalog.ts:298
- **Source:** PLAN-LOCAL-FIRST.md §B
- **Evidence:** `ProviderId = 'claude' | 'codex' | 'gemini' | 'shell'` and `AGENT_ENTRIES` holds exactly those four (Claude Code, Codex CLI, Gemini CLI, Shell). Confirmed live in the New-session dialog and in Settings → Agents → "Sign in to another account": four options, no Grok, no extension point.

### [missing] Every Overview session card is titled with the project folder name, so eight cards all read "terminaldeck" and are impossible to tell apart — while the sidebar calls the same sessions "Session 2"…"Session 8". The folder name is also printed a second time in the card's own top-right corner.
- **Where:** src/renderer/dashboard/SessionBoard.tsx:236 (title) vs :228 (folder chip)
- **Source:** Live app sweep, Overview page
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/nav-overview.png — 8 of 9 cards headed "terminaldeck", each with "terminaldeck" also in the corner. Source: `deriveSessionTitle` (session-title.ts:491) falls back to `folderName(input.cwd)` when there is no transcript title. The sidebar and tab strip both route through `sessionLabel(title, index, folderName)` (workspace-tabs.ts:147), which returns `Session N` precisely when the title equals the folder name. SessionBoard renders `{session.title}` raw and never calls it. This is the same bug that was already found and fixed between the sidebar and the tab strip — the comment at workspace-tabs.ts:155 describes it: "one window was 'terminaldeck' along the top and 'Session 1' down the side".

### [missing] Model reads "Unknown" for the whole life of any session where nobody typed /model, while the session's own banner two lines below prints the model. Effort, Fast mode and Permission all have a settings fallback; Model does not.
- **Where:** src/main/agent-controls.ts:1138-1145 (model) vs :1148-1166 (effort/fast) and :1130-1135 (permission)
- **Source:** Live app sweep — toolbar chip and terminal buffer read in the same evaluate() call
- **Evidence:** Single-instant read: model chip text = "Unknown" while the focused terminal buffer contained "Claude Code v2.1.233 Opus 5 (1M context) with xhigh effort · Claude Max". Verified at 820px and again at 1440px, so it is not a width artefact. `readModelFromScreen` (agent-controls.ts:780) only returns `readModelConfirmation(screen)` — it matches "Set model to X" / "Kept model as X", never the startup banner. The ladder is screen-confirmation → transcript → UNKNOWN, with no settings rung, whereas permission got exactly that rung with the comment "Without this the control was `Unknown` for the whole life of any session nobody had pressed shift+tab in". Later in the session someone typed `/model default` and the chip immediately resolved to "Opus 5 (1M context)" (see /Users/apple/.claude/jobs/5ccc1804/tmp/dark-full.png), confirming the mechanism.

### [missing] Settings → Power: the "Keep running with the lid closed" toggle is ON, and the notice directly beneath it says "Closing the lid or choosing Sleep still does" — i.e. the screen tells you the lid will sleep the Mac immediately under a switch that is on to stop exactly that. The sentence is also factually wrong on this machine.
- **Where:** src/renderer/settings/sections/PowerSection.tsx:288-293 (idleBlockedNote) and :422-424 (render site)
- **Source:** Live app sweep, Settings → Power
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/set-power.png shows the blue toggle ON above the notice. Verified against the real machine: `pmset -g` reports `SleepDisabled 1`, so closing the lid does NOT sleep it — the sentence is false right now. Source: `idleBlockedNote(platform, { hasLid })` takes only the platform and whether the machine has a lid; it never receives the toggle's state, and the render is gated only on `state?.idleBlocked === true`. The note describes `powerSaveBlocker` while the switch above drives the privileged `SleepDisabled` setting — two mechanisms, one unaware of the other. (The "On battery at 100%" line on the same pane IS accurate — `pmset -g batt` confirms battery, 100%, discharging.)

### [missing] Settings → Notifications: "Play a sound when a session finishes" is OFF, but the Sound picker and its Test button below stay fully live — not dimmed, not disabled — so you can pick a sound for a thing that will never play.
- **Where:** src/renderer/settings/sections/ — Notifications section
- **Source:** Live app sweep, Settings → Notifications
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/set-notifications.png shows the parent toggle grey/off. Live DOM read of the dependent controls: the Sound `<select>` reports `disabled: false, opacity: "1", pointerEvents: "auto"`, and the Test button likewise `disabled: false, opacity: "1"`. Nothing marks them as inert.

### [missing] A plain-shell session's header chip says "Claude Code · Work" while the chip's own tooltip says "A plain shell has no account to sign in to" — and in Chat mode the body of the same pane says "This session is a shell". Three statements, one frame, two of them contradicting the third.
- **Where:** src/renderer/shell/AccountChip.tsx:302 and :425 (mark) vs :530-532 (title)
- **Source:** Live app sweep, Chat mode on a shell session
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/mode-chat.png — header reads "terminaldeck • ✳ Work" above body text "This session is a shell … the terminal is the whole session". Live DOM read returned both chips with `text: "Claude CodeWork"` and `title: "A plain shell has no account to sign in to."`. Source: `blocked = isolationNotice(provider)` uses the session's real agent (shell) and drives the tooltip, but `mark = current?.provider ?? listed?.provider ?? …` falls through to the *account's* provider (claude) and drives the badge, while `identity.label` still prints the account name. The string comes from `agent-catalog.ts:292` (`loginsNote` for the shell entry).

### [missing] Settings → General: the Language control is an enabled dropdown with exactly one option, sitting next to prose that says "English is the only one there is." A control that looks pressable and can never do anything.
- **Where:** src/renderer/settings/sections/ — General section
- **Source:** Live app sweep, Settings → General
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/settings-1.png. Live DOM read of every `<select>` in the dialog returned exactly one: `{"opts":["English"],"disabled":false}` — one option, not disabled.

### [missing] The New Session dialog opens with its last option, "Remember these choices for this project", sliced horizontally through the middle of the glyphs by the footer bar.
- **Where:** src/renderer/components/NewSessionDialog.tsx — scroll region / footer
- **Source:** Live app sweep, ⌘⇧T
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/newsession.png and zoom crop /Users/apple/.claude/jobs/5ccc1804/tmp/crop-cutoff.png — the checkbox and every letter of the label are cut in half. Scrolling the dialog to the bottom does reveal the row intact (/Users/apple/.claude/jobs/5ccc1804/tmp/newsession-scrolled.png), so it is reachable — but the dialog's initial scroll position lands mid-glyph with no visible affordance that there is more.

### [missing] The Files viewer applies programming ligatures, so it shows characters that are not in the file: `<!--` renders as `←!—`, `-->` renders as `⟶`, `=>` renders as `⇒`. A file reader is misreporting file contents.
- **Where:** src/renderer/components/FileViewer.css:49,82 (`var(--font-mono)`) with no `font-variant-ligatures` reset
- **Source:** Live app sweep, Files page rendering README.md
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/nav-files.png — README.md line 17 draws `←!—` and line 23 draws `⟶`. Verified against the real bytes: `sed -n '17p;23p' README.md | od -c` returns `< ! - - \n - - >`. Same effect on settings-surface.test.ts line 38 (`=>` → `⇒`) in /Users/apple/.claude/jobs/5ccc1804/tmp/settings-open.png. `--font-mono` is `'SF Mono', 'JetBrains Mono', Menlo, monospace` (tokens.css:440) with JetBrains Mono bundled at tokens.css:64; `grep -rn 'font-variant-ligatures\|font-feature-settings' src/renderer/` returns nothing, so `calt` is on by default.

### [partial] "I don't see any kind of option here to make anyone up or make anyone activated and deactivated also after I use" / "activating the bringing the server up activating the server or deactivating"
- **Where:** iOS — ios/TerminalDeck/Screens/LocalhostListView.swift, ios/TerminalDeck/Ports/PortCatalog.swift, and src/main/remote/ (wire)
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (line 1), said twice; PLAN-LOCAL-FIRST.md:143 "start/stop a server from the phone"
- **Evidence:** Only the START half exists. PortCatalog.secondAction yields .start / .retry / .openSession / .copyAddress — there is no .stop. LocalhostListView's header states the omission and defends it: no stop verb exists on the wire, `dev.state` only leaves `ready` when the session exits, so a blind Ctrl-C would leave the row advertising a dead address. The reasoning is sound but the feature he asked for twice is half-built, and the honest fix named in that same header ("a stop verb on the desktop") has not been done — WireProtocol.swift ClientMessage has devStatus and devStart and no devStop.

### [partial] "more importantly scroll with one finger inside the terminal" / "if I scroll, it's coming blue. It's not scrolling, it's selecting"
- **Where:** iOS — ios/TerminalDeck/Terminal/TerminalGestures.swift, DeckTerminalView.swift
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (line 1)
- **Evidence:** Fixed in source and the fix is well-argued: selectionHold raised 0.5→0.7s, selectionSlop 6 held strictly below DeckTerminalView.scrollSlop 10 so a finger heading for a scroll fails the press first, and the three recogniser relationships are declared. But TerminalGestures.swift's own comment says "That is the THIRD recording in a row where Asad has said 'if I scroll, it's coming blue'" — this has been declared fixed twice before. It is uncommitted, unbuilt and unshipped (see the build finding), and its own WhatToTest text admits "a UI test cannot hold a finger still for longer than about six tenths of a second, so it is on you" — i.e. the selection half is unverifiable by machine. Do not report this one as fixed until he has dragged a real terminal on a real build.

### [partial] iOS TestFlight release notes are two versions stale — he tests from what the notes tell him is new
- **Where:** iOS — ios/WhatToTest.md
- **Source:** His own testing loop; ios/WhatToTest.md
- **Evidence:** The file is still headed "What to test — 0.1.8" and its body describes the 0.1.8 key bar, find, pinch, share and machine-name work. The only edit tonight (git diff) rewrote the ONE-FINGER-SCROLL paragraph. Nothing in it mentions the three-tab layout, Machines moving into Settings, the Localhost tab with grouping/folding/renaming, the back button, the GitHub sign-in fixes or the notification-spam grace — which is exactly the list he will be looking for.

### [partial] Tonight's CLAUDE_CODE_TMPDIR fix — the one that stopped every confined Claude session dying on its first turn — was added to the POSIX env only
- **Where:** Windows — src/main/confine/plan.ts:492-496 vs src/main/confine/appcontainer.ts:436-448
- **Source:** Same scope item; git diff src/main/confine/plan.ts (uncommitted, tonight)
- **Evidence:** The diff adds `CLAUDE_CODE_TMPDIR: tmp` to confinedEnv, with a long note that Claude Code 2.1.233 ignores TMPDIR and uses a literal /tmp/claude-<uid>, and that a confined session printed `EPERM … open '/tmp/claude-501'` and exited before generating a token. windowsConfinedEnv returns HOME, USERPROFILE, HOMEDRIVE, HOMEPATH, APPDATA, LOCALAPPDATA, TEMP, TMP — and no CLAUDE_CODE_TMPDIR. Whether the Windows CLI has the same literal-scratch-dir behaviour is not knowable from this Mac, which is the point: the fix was measured on one platform and the two-branch switch was only half updated. Needs a run on the Windows PC before the release, not a guess.

### [partial] The new model/effort click-to-change mechanism is verified only against the macOS CLI in a macOS pty
- **Where:** Windows — src/main/agent-controls.ts
- **Source:** PLAN-LOCAL-FIRST.md:392-400 "It should actually work — change the efforts and models for terminal also"; scope item on Windows paths
- **Evidence:** The file's header documents three verification passes, all of them "driven against the real CLI on this machine (claude 2.1.228, ~/.local/bin/claude) inside a pty" — a macOS pty. It writes `\r` and `\x1b[Z` (shift+tab) into the pty and reads the footer back. There is no platform guard anywhere in the file (grep for darwin/win32 returns one unrelated comment about a codex-darwin-arm64 path). Windows sessions run through ConPTY, where key-sequence handling and echo have already bitten this repo (see the terminaldeck-windows-probes p06–p09 ConPTY series, last run 16 Aug 04:00 — before this code existed). Nothing has exercised the writer on Windows.

### [partial] "Login default, instead of just saying default because nobody now knows which one is default. So there should be a default and then next to it we can have an email so we know which one is default currently."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/shell/Sidebar.tsx:626-627
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1. PLAN-LOCAL-FIRST.md §E: "Login shows the **email**, not 'Default'."
- **Evidence:** Half done. The pane bar and window toolbar resolve the address properly — live DOM read at 04:2x shows the chip reading `app.imatch.ae@gmail.com` via `accountIdentity` (src/renderer/accounts.ts:370-425), and the New session dialog has `profileLoginLabel` + a make-default action. But the sidebar prints the raw profile name: `{showAccounts && tab.account && (<span className="sb-account">{tab.account.name}</span>)}`. Every screenshot I took (main01.png, overview01.png, artifacts01.png) shows sidebar rows reading `Default` beside Session 5 / Session 8 / "Update Claude C…" — the exact word he objected to, still on screen in the rail.

### [partial] "which conversation will it bring? … it should actually give the choice of which session, maybe with session IDs or the name or maybe a little bit context with the summary or very short, like one liner thing."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/components/NewSessionDialog.tsx:196-286
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (New session dialog, Continue the last conversation). PLAN-LOCAL-FIRST.md §E: "'Continue the last conversation' must say **which**, with a picker."
- **Evidence:** The identity half landed (`conversationLine` prints `2h ago · 75fc3408`). The choice half was explicitly declined in the file header: "The **choice** cannot be built today… `CreateSessionInput` carries `resume?: boolean` and nothing else." `olderConversationsLine` says "N older conversations here. Resume always takes the newest." Worth flagging because the constraint is a wiring decision, not a CLI limit — the terminal in my own screenshot main01.png prints `claude --resume edfbe3b6-9a58-4589-84cc-dc45000192e7`, so per-id resume is available on the CLI he is running.

### [partial] "this is not actually, I think it's not original logo, it's a logo that you made. So let's bring original logos and with their original colors, orange color, blue color, whatever the original logo is."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/components/ProviderBadge.tsx, /Users/apple/Projects/terminaldeck/src/renderer/components/ProviderBadge.css:28-90
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3 (Appearance / dark mode). PLAN-LOCAL-FIRST.md §H: "**Real provider logos in their real colours.**"
- **Evidence:** Colours landed: the CSS now sets Claude `#d97757` and Gemini `#4285f4` at full opacity, and the orange burst is visible in main01.png beside "Work". The *shapes* did not: ProviderBadge.tsx still says "Every path below was constructed here from a geometric rule, not traced from anyone's artwork" — i.e. still "a logo that you made", declined on trademark/licence grounds. Also stale: the .tsx header section is still titled "## Monochrome, deliberately" and argues brand colours were "considered and dropped", which the CSS now contradicts — two files disagreeing about the same control.

### [partial] "we can ask them to put some API in the setting for voice so they can put a API and this one will come here" — said again later as "but there should be some settings for them to put an API and we should have all the rest of the settings and built there. They just paste an API for [voice] model." **He asked for this twice in one recording.**
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/settings/sections/ToolsSection.tsx:47-58
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (mic button) and para 2/3 (Features section).
- **Evidence:** Explicitly declined in the file: "a field for an API key that nothing in this app would send anything to… shipping the field anyway would be a control over nothing." The related half he asked for *is* satisfied — `registry.ts:415` gives `voice` `default: 'off'`, so the mic is absent from the chat box until switched on. Flagging because a thing asked for twice and then declined should be an explicit decision he sees, not a silent one; the honest middle would be an API-key field plus a real transcription call.

### [partial] "they are three separate errors, three of them are saying the same thing. Now the question is why do we have three here? … they should mention that one thing specifically. So we know why they are three and what each of them is belonging to."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/settings/sections/BrowserSection.tsx:270, 315-320
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3 (Browser settings). PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 7.
- **Evidence:** Unchanged: `const blocked = browsers?.filter(b => b.access === 'blocked')` then `{blocked.map(browser => <Notice tone="warn">{browser.note ?? `${browser.name}'s data is protected by the system. Grant Full Disk Access to read it.`}</Notice>)}`. Still one yellow notice per blocked browser, word-for-word identical except the name, each repeating the same single remedy. Not collapsed into one, not tied to a profile, and not filtered to browsers that are actually installed.

### [partial] "If I click on refresh, I don't know if the refresh is working because we don't feel anything getting refreshed also."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/components/GitHubPanel.tsx:1652-1665, /Users/apple/Projects/terminaldeck/src/renderer/components/GitHubPanel.css:81-100
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (GitHub page).
- **Evidence:** The only feedback is `disabled={busy}` plus `.gh-refresh:disabled { opacity: 0.45 }`. No spin animation (`grep -n 'spin|@keyframes' GitHubPanel.css` → nothing), no "Updated N ago" line. `fetchedAt` is carried in the data shape (lines 84, 139) but never rendered anywhere. So the click still produces a barely visible dim and no statement that anything changed.

### [partial] "I'm trying to disconnect and it is not disconnecting. So I can connect again myself, but I cannot first of all disconnect. If I click on disconnect, it will take me back."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/components/GitHubPanel.tsx:573-690, `githubDisconnect` IPC
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (GitHub page).
- **Evidence:** A two-step confirm now exists (`onAskDisconnect` → confirm text → `onDisconnect` calling `githubDisconnect(cwd)`), and there is an explicit branch for the environment-token case ("Nothing to disconnect — unset GH_TOKEN and restart"). COULD NOT VERIFY that pressing it actually clears the credential: exercising it would sign his real GitHub session out, which is destructive and outside my brief. Needs one manual press.

### [partial] "It runs under the same confinement as any other session"
- **Where:** src/main/copilot-session.ts
- **Source:** RELEASE-CHECK.md:110
- **Evidence:** copilot-session.ts documents its own home dir and boundary and hands the spawn to host-core's startSession, so on paper it inherits confinement. Unverifiable in practice — the copilot has never been started (no folder on disk, no UI to start it).

### [partial] "Routines are event-driven, with the four hard cases answered"
- **Where:** src/main/routines/, src/main/index.ts:389
- **Source:** RELEASE-CHECK.md:108, COPILOT-DESIGN.md "Routines"
- **Evidence:** Event-driven is genuinely done: sources.ts subscribes to git's existing watcher, chokidar (native FSEvents), and session/alert callbacks; schedule.ts arms ONE setTimeout for the earliest due routine and refuses sub-minute schedules as "a poll wearing a costume". Engine is registered and started in index.ts. But `runner` is deliberately absent — index.ts:382 says routines run through the copilot and "there is nothing on the other end", so every routine reports itself unarmed. There is also no routines UI in the renderer (grep: zero references in src/renderer or src/preload) and no `routines/` folder on disk. A routine cannot be created, and if it existed it would fire and do nothing.

### [partial] "Clicking a model actually changes a running session, verified by read-back"
- **Where:** src/main/agent-controls.ts, src/renderer/shell/useSessionControls.ts
- **Source:** RELEASE-CHECK.md:91
- **Evidence:** Mechanism is real and carefully built: `applyAgentControl` is in the preload, `useSessionControls` calls it, and `agent-controls.ts` documents driving the real `claude 2.1.228` binary in a pty (including the `Switch model?` modal that appears in any session with one exchange behind it) and takes its reading from the re-read, never from the clicked value. I did NOT click it — changing the model on a live session another agent is using is destructive, so this half is unverified by me.

### [partial] "Model Unknown / Permission Unknown in the composer. Permission never resolves at all."
- **Where:** src/renderer/chat/controls/catalog.ts (unreadLabel), src/renderer/shell/SessionControls.tsx
- **Source:** PLAN-LOCAL-FIRST.md §A
- **Evidence:** Read live off a running Claude Code session in the new chrome: `Model Unknown` with tooltip "Model: Unknown — not known", right beside `Effort Ultracode` with tooltip "Effort: Ultracode — from Claude settings". Both are read from the same place; effort resolves and model does not. The terminal itself printed `Opus 5 (1M context)` in its own banner two lines below the chip that says Unknown.

### [partial] "Settings is one surface — rail, pane, content all one colour per theme"
- **Where:** src/renderer/settings/SettingsWindow.css:101 (.settings-rail), src/renderer/components/Modal.css:57 (.modal-panel)
- **Source:** RELEASE-CHECK.md:73
- **Evidence:** Measured computed styles in the running Settings modal. Light: rail `rgb(245,245,245)` (`--bg-secondary`) vs panel `rgba(253,253,253,0.86)` (`--material-bg-strong`). Dark: rail `rgb(32,32,32)` vs panel `rgba(40,40,40,0.88)` — eight levels apart, visible. Two surfaces, not one, in both themes.

### [partial] "Anything opened from the header lands in the header and stays there until removed deliberately"
- **Where:** src/renderer/browser/workspace-strip.ts (shownTabs / transient tabs)
- **Source:** RELEASE-CHECK.md:63
- **Evidence:** Tested live: clicked the header globe, the new page appeared in the strip marked `kept`, then switched to another tab — it was still there. That half works (`keepNewWindowInStrip` is called from all four open paths). Two caveats, both observed: (1) a tab that is only in the strip because it is active is marked `transient` and vanishes the instant you leave it — Session 2 disappeared from the strip the moment I opened the browser tab, with nobody removing it; (2) after the app restarted mid-audit with "Pick up where you left off", 10 sessions were restored and the strip held **one** tab. The promoted order lives in `sessionStorage`, which is deliberately wiped on quit, so every window the user kept is silently gone on the next launch.

### [partial] "Tab ✕ closes the view only; session survives in the sidebar" / "Sidebar ✕ ends the session, with its confirmation"
- **Where:** src/renderer/browser/WorkspaceTabStrip.tsx:640-646, workspace-strip.ts removeFromStrip
- **Source:** RELEASE-CHECK.md:61-62
- **Evidence:** Source and labelling are right: the tab button's aria-label is `Remove <name> from the top bar` and its title is "Remove from the top bar. It keeps running, in the sidebar." `removeFromStrip` only edits the promoted order and moves the selection; it never touches the session. `workspace-strip.test.tsx` passes in the full run. I attempted the live click on Session 5's tab ✕ but the app hot-reloaded between snapshot and click, so I never actually saw a session survive its tab being closed. The sidebar ✕ + confirmation I did not test at all — it ends a session another agent is using.

### [partial] "Globe opens the start page"
- **Where:** src/renderer/App.tsx:772 newBrowserTab, tab labelling via renameBrowserTab
- **Source:** RELEASE-CHECK.md:57, PLAN-LOCAL-FIRST.md "The chrome"
- **Evidence:** Functionally done — clicked the header globe live and got the real start page ("Open a page", the address box, "Listening on this machine right now: :5037 adb"). But the tab is created as "New tab" and then renamed from the guest's document title, which for the start page is empty, so the tab and the sidebar row both read **`about:blank`**. That is the name of the app's own start page in two places.

### [partial] Pages that never resolve — "Reading the transcript…", "Reading your MCP configuration…"
- **Where:** src/renderer/components/ChatView.tsx:336, src/renderer/components/SessionInspector.tsx:1129, src/renderer/chat/attach/McpServers.tsx:139
- **Source:** PLAN-LOCAL-FIRST.md §A
- **Evidence:** `deadline.ts` was written for exactly this and is a good fix, but it is imported by only seven files: widgets, GitPanel, McpInspector, ArtifactsPanel, FileTree, FileViewer, RemoteSection. The three above are not among them and have no setTimeout, no Overdue, no timeout of their own. Two of them print "Reading the transcript…", which is one of the four sentences he named by hand. Live sweep of every project page (Overview, Files, Artifacts, Source control, GitHub, AI readiness, MCP servers, Hooks, Remote) found none hanging — but I could not reach the chat transcript or the attach-menu connector list from a session I was allowed to drive.

### [partial] "Continue the last conversation must say which, with a picker"
- **Where:** src/renderer/components/NewSessionDialog.tsx:1343
- **Source:** PLAN-LOCAL-FIRST.md §E
- **Evidence:** Half done, verified live. The dialog now reads "Continue the last conversation / 36m ago · 75fc3408" — it says which. But underneath: "23 older conversations here. **Resume always takes the newest.**" There is no picker. The sidebar's own Continue-last row action is still immediate with no naming at all (aria-label "Continue the last session in terminaldeck").

### [partial] iOS: "Three tabs, Machines inside Settings — he said four pills first and then reconsidered; flag this for him rather than assume"
- **Where:** ios/TerminalDeck/App/DeckModel.swift:107, ios/TerminalDeck/Screens/DeckTabs.swift:91-130
- **Source:** RELEASE-CHECK.md:112
- **Evidence:** Code has settled on three: `enum Tab { sessions, localhost, settings }`, with `SettingsRoute.machines` pushed from Settings. That matches the reconsidered version. But the flag RELEASE-CHECK asked for has not been raised anywhere — no note in the plan files, nothing surfaced to him. He is owed the question, not the assumption.

### [partial] iOS: pill hidden inside a session and inside a localhost page
- **Where:** ios/TerminalDeck/App/DeckChrome.swift (untracked)
- **Source:** RELEASE-CHECK.md:113
- **Evidence:** The file exists and reads convincingly — it quotes him directly, explains why `.toolbar(.hidden, for: .tabBar)` on the pushed screen had no effect on iOS 26 (measured), and moves the decision to each tab's NavigationStack with `DeckChromeTests` walking every case. Cannot be verified without a build; also uncommitted, so it is in no TestFlight build.

### [partial] iOS: back button live on same-document navigation / GitHub sign-in completes / no notification spam / localhost list folds, groups, renames
- **Where:** ios/TerminalDeck/Screens/LocalhostBrowser.swift, GitHubSignIn.swift, SessionAlerts.swift, LocalhostListView.swift
- **Source:** RELEASE-CHECK.md:114-119
- **Evidence:** All four have matching edits and new test files (BrowserBackTests, GitHubAccountTests, SessionAlertsTests, LocalhostUITests). I cannot build or run iOS from here, so none of the four is verified behaviourally — and none is in a build on his phone.

### [regressed] Site's "not built yet" list still names two things that are built
- **Where:** Marketing site — features.html:828-847
- **Source:** His rule that the app and site must not say things that are not true; features.html's own honesty list
- **Evidence:** The list still contains "Split panes. The layout code and the ⌘D/⌘⇧S/⌘⇧W chords exist in the repository, but nothing renders the split view — there is no way to reach it in the app" (the running app on CDP 9444 shows a Terminal/Chat/Split control in the session band, and tonight's per-pane chrome work in src/renderer/shell/PaneBar.tsx is built on splits existing), and "The localhost tunnel, on Windows… Windows resolves localhost to ::1 first" (src/main/remote/tunnel.ts now defines LOOPBACK_V6 = '::1' and dials IPv4 then IPv6; release 0.1.7 is titled "reach an IPv6 dev server"). The signing line — "neither is signed" — is also probably stale given scripts/mac-release-signed.sh and the Developer ID work, but electron-builder.yml still carries identity: null / notarize: false, so I could not establish from here whether the published 0.2.0 dmg is signed. Check that one before editing it.

### [regressed] Session identity: two sidebar rows with the same visible name and the same account chip, indistinguishable. Against "Session names must not lose to account chips" / the session-identity item.
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/shell/workspace-tabs.ts (`tabIdentities`), general.autoNameSessions
- **Source:** PLAN-LOCAL-FIRST.md "What the frames found" item 4. Found live tonight in a new form.
- **Evidence:** Live DOM read while on Artifacts: the terminaldeck group listed `Session 5 / Update Claude Code terminal to new… / Default / Session 7 / Work / Update Claude Code terminal to new… / Default` — two rows carrying the identical auto-derived name AND the identical account qualifier, so nothing on screen tells them apart. Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/artifacts01.png shows them as "Update Claude C… D…" twice. `tabIdentities` adds a qualifier for duplicates, but the qualifier it picks (the account) is the same for both.

### [regressed] Dark mode: the Shortcuts popover (and one browser popover) lost their glass — they render as flat opaque slabs while every other floating surface in the app is still translucent. The CSS comment above them claims the opposite.
- **Where:** src/renderer/settings/SettingsWindow.css:1502 and src/renderer/browser/BrowserWorkspace.css:788
- **Source:** Live app sweep, both themes compared on the same element
- **Evidence:** Measured the same `.settings-popover` element in both themes. Light: `background rgba(250,250,250,0.72)` + sheen gradient. Dark: `background rgb(33,33,33)` fully opaque, `background-image: none` — screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/popover-dark.png vs popover-light.png. Cause is a collision: these two surfaces use `var(--material-bg)`, which the deliberate dark-chrome flattening at tokens.css:418-420 redefined to opaque `#212121` with `--material-sheen: none` (correct for the sidebar/toolbar it was written for). Every other floating surface — Modal, CommandPalette, tooltip, AttachMenu, SessionInspector, ChatView, AgentControls — uses `--material-bg-strong`, which is still 88% translucent. The comment at SettingsWindow.css:1499 still says "The same glass every other floating surface in this app wears", which is now false in dark. `backdrop-filter: blur(26px)` is also being paid for behind an opaque fill.


## LOW

### [missing] "if you think chat mode will be a good option here or not if you think maybe we can bring chat option here also like chat view for per session"
- **Where:** iOS — ios/TerminalDeck/Screens/TerminalScreen.swift
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (final sentence); PLAN-LOCAL-FIRST.md:145 "possibly chat per session"
- **Evidence:** grep -rni 'chat' across ios/TerminalDeck/**.swift returns four hits, all unrelated (PairingCode comments about "the curly dash a chat app substitutes", HostLink's "chattiest"). There is no chat view, no Terminal/Chat toggle. The desktop has a Terminal/Chat/Split control — I read it in the live renderer DOM on CDP 9444 tonight. He phrased it as a question, so it needs an answer from him rather than silence; nothing in the tree records a decision either way.

### [missing] "Whatever the tools are already existing in the MacBook, they can maybe have an option to bring them here inside the application… move their path or something… it can maybe scan once and see whatever is already existing in the PC and move to the right place and all together they will show here."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/settings/sections/ToolsSection.tsx, /Users/apple/Projects/terminaldeck/src/main/
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3. Recorded in NEITHER plan file.
- **Evidence:** No scan-the-machine-for-tools feature exists. `detectProviders` looks up four agent binaries on PATH and nothing else; there is no generic tool discovery, no adopt/import action, no path registry. He hedged it ("if possible, easily"), so it may be a decline rather than a build — but it was never recorded as a request, so it has not been decided either way.

### [missing] "And should we have isolated and shared in actual terminal also? Does it make more sense for this?" — a direct question he asked and nobody answered.
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/browser/Toolbar.tsx:274-308, /Users/apple/Projects/terminaldeck/src/main/
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (localhost/browser page).
- **Evidence:** The first half of the ask landed — the Shared/Isolated control now carries a plain-English tooltip explaining both states (Toolbar.tsx:280-281), which answers "can you explain in short and simple". The second half is nowhere: no shared/isolated concept for terminal sessions, and no note in any plan or design file recording a decision either way. Left open.

### [missing] Alerts name sessions by hex id rather than by name
- **Where:** src/renderer/components/AlertsPanel.tsx / src/main/alerts.ts
- **Source:** PLAN-LOCAL-FIRST.md §A / "stop it lying" spirit; not in any checklist
- **Evidence:** Opened the Alerts popup live: "Session 271d364a asked a question 17 minutes ago…" and "Session eb23b15c moved 1.62M tokens…". Those sessions are called Session 6 and Session 3 everywhere else in the window. The one place that tells you something is wrong names the session in a way you cannot match to a tab.

### [missing] ios/WhatToTest.md still describes 0.1.8
- **Where:** ios/WhatToTest.md
- **Source:** Housekeeping for the TestFlight build RELEASE-CHECK asks for
- **Evidence:** File is modified in the working tree but still opens "What to test — 0.1.8" while the last iOS commit is 0.2.0 build 2608161532 and this build would be later still. Testers would be handed release notes two versions stale.

### [missing] Raw internal ids are shown where a name belongs: the Overview usage widget says "Context window · session 75fc3408", and the New Session dialog identifies the conversation you are about to resume as "just now · 51e5542f" out of 25 candidates.
- **Where:** src/renderer/dashboard/widgets.tsx (usage widget); src/renderer/components/NewSessionDialog.tsx (Conversation group)
- **Source:** Live app sweep
- **Evidence:** Screenshots /Users/apple/.claude/jobs/5ccc1804/tmp/nav-overview.png and /Users/apple/.claude/jobs/5ccc1804/tmp/newsession.png. The dialog also says "24 older conversations here" — so an 8-char hex is the only thing distinguishing the one being resumed. The app already derives human titles from transcripts in session-title.ts (`titleFromTranscript`), so the material to name these exists and is not being used here.

### [missing] Settings → Browser lists Chrome cookie profiles by their on-disk folder slugs — "Default, Profile 2, Profile 3, Profile 13, Profile 18, Profile 30…" — 14 unlabelled chips with no way to tell which login is which.
- **Where:** src/renderer/settings/sections/ — Browser section, "Sign-ins: cookies from Chrome"
- **Source:** Live app sweep, Settings → Browser
- **Evidence:** Captured in /Users/apple/.claude/jobs/5ccc1804/tmp/setsweep.txt lines 267-340 and screenshot set-browser.png. Chrome stores a human profile name in each profile's Preferences file; the app is showing the directory name instead. Same class as the `Default` account slug.

### [missing] Sidebar: at a narrow-but-legal sidebar width the account column truncates to "D." — a two-character stub that identifies nothing.
- **Where:** src/renderer/shell/Sidebar.tsx:626-628 (.sb-account)
- **Source:** Live app sweep at 980px window / 208px sidebar
- **Evidence:** Zoom crop /Users/apple/.claude/jobs/5ccc1804/tmp/crop-sidebar.png shows three rows rendering the account as "D.". Live DOM read confirms the underlying text is "Default" and CSS ellipsis is cutting it. Compounds the `Default` slug finding above: the column is showing the wrong word, and then showing one letter of it. (I also initially suspected the unread dot was overlapping the label text — measured it and it is not: label right edge 166px, dot at 174px. Not a defect.)

### [missing] Settings → Tools: "No transcription yet" is typeset exactly like a setting row — bold heading, ⓘ button, description line — but has no control on the right. It reads as a setting whose toggle went missing.
- **Where:** src/renderer/settings/sections/ToolsSection.tsx
- **Source:** Live app sweep, Settings → Tools
- **Evidence:** Screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/set-tools.png — it sits directly under "Microphone in the chat box", in the same row grid and the same type, with an empty right-hand column where that row has a toggle. The wording also reads as a state ("nothing has been transcribed yet") when it means "this app does no transcription".

### [missing] Settings → Browser repeats the same full-disk-access paragraph three times in a row, once each for Chrome, Edge and Brave — roughly 40 identical words stacked.
- **Where:** src/renderer/settings/sections/ — Browser section, "Import addresses from a browser you already use"
- **Source:** Live app sweep, Settings → Browser
- **Evidence:** Captured verbatim three times in /Users/apple/.claude/jobs/5ccc1804/tmp/setsweep.txt (Browser section): "macOS will not let this app read {Chrome's,Edge's,Brave's} data until it is given full disk access. Open Privacy & Security → Full Disk Access, add this app, then run the import again." One sentence naming the three browsers would say the same thing. Worth noting Edge and Brave are not installed on this Mac (`/Applications/Microsoft Edge.app` and `Brave Browser.app` both absent) — only leftover Application Support folders remain, so two thirds of that wall is about browsers the user does not have.

### [partial] Notification spam on returning to the session list — "I go inside I come back it's throwing a new notification"
- **Where:** iOS — ios/TerminalDeck/App/DeckModel.swift:278-410, App/SessionAlerts.swift, App/AlertCenter.swift
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (line 1)
- **Evidence:** Diagnosed correctly and fixed in source, and the diagnosis is the convincing part: attaching resizes the pty, every full-screen agent CLI repaints on SIGWINCH, the desktop's ActivityTracker calls that `working`, waits SETTLE_MS and classifies — so the verdict lands ~1s later, on the list. leftSessionAt + watchedGrace (5s) + the route check in isBeingWatched suppress it; AlertCenter also reuses the thread id as the request id so a session has one live notification instead of a stack. Marked partial only because it is unbuilt and unshipped (see the build finding) and because "no banner on returning" can only be proved on his phone.

### [partial] GitHub sign-in: "I clicked nothing happened" ×6, and "if I click on done, it's again there. So not working"
- **Where:** iOS — ios/TerminalDeck/Screens/GitHubAccountView.swift:263-293, Transport/GitHubSignIn.swift:242-290
- **Source:** VIDEO-3-MOBILE-TRANSCRIPT.txt (line 1)
- **Evidence:** Both halves are found and fixed, with the right root causes. The dead taps: `.buttonStyle(.plain)` made the Text the hit target while the blue pill was painted by a .background three hundred points wide — `.contentShape(Rectangle())` added, and the comment says the same trap was fixed under every .plain button on that screen. The Done bug: cancel() used to be called from the sheet's onDisappear, so pressing Done killed the poll one request short of the token; the flow now lives on DeckModel and outlives the sheet, ends by itself on token/refusal/15-minute expiry, and cameToTheFront() polls immediately on return from Safari instead of sitting out the remaining five seconds. Partial only because it is unbuilt, and because a device-flow round trip is not something I can exercise from here.

### [partial] Site repo and the live site have diverged — /review is live but exists only in an uncommitted working tree
- **Where:** Marketing site — /Users/apple/Projects/terminaldeck-site/review.html (untracked), vercel.json (modified, adds the /review rewrite)
- **Source:** Scope item: report what on the marketing site is out of date
- **Evidence:** `git status` in terminaldeck-site shows ` M vercel.json` and `?? review.html`, yet curl https://terminaldeck.dev/review returns 200. So a deploy was made from a dirty tree. A future deploy from a clean checkout drops the page and its rewrite. Low impact today, but it means the repo is not the source of truth for what is live — which matters as soon as the site is caught up to 0.2.0.

### [partial] "here right next to the each tab, we should have button for new session and new window instead of only here. We should be able to just click here and open next to each one to them."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/browser/WorkspaceTabStrip.tsx, /Users/apple/Projects/terminaldeck/src/renderer/App.tsx:2108-2112
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1. PLAN-LOCAL-FIRST.md §E recorded it verbatim; the later "chrome, as specified 2026-08-17" narrowed it to "After the last tab, two icons: terminal and globe."
- **Evidence:** Delivered as two icons after the *last* tab (`>_` and globe — visible in main01.png at the right end of the strip), not next to each tab, and a new session is appended to the end rather than inserted after the tab you launched it from. The per-project sidebar rows do carry hover "New session in <project>" (Sidebar.tsx:885), which covers part of the intent. Calling it partial rather than done because the later spec he gave was about removing the `+`, and the "opens next to the one I clicked" half was never separately answered.

### [partial] "issue and pull request pages are like identical showing the same stuff, same error, same buttons."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/components/GitHubPanel.tsx:1584-1600
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (GitHub page).
- **Evidence:** Partly fixed: the two tabs now have distinct empty states ("No open pull requests." / "No open issues."). But in the failing state — which is the state he was looking at — `listBody` returns the same `<FailureBlock failure={state.repo} onRetry={loadAuth}/>` for both `kind === 'pulls'` and `kind === 'issues'`, so both tabs still render byte-identical error text and the same button whenever auth or the repo lookup fails.

### [partial] "Model Unknown" still rendered in the session chrome (PLAN-LOCAL-FIRST §A lists `Model Unknown` / `Permission Unknown` as things that must resolve).
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/shell/SessionControls.tsx, /Users/apple/Projects/terminaldeck/src/renderer/shell/useSessionControls.ts
- **Source:** PLAN-LOCAL-FIRST.md §A.
- **Evidence:** Live screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/startpage.png, taken 04:2x, shows the toolbar reading `Model Unknown ⌄ Effort Ultracode ⌄ Fast mode Not reported ⌄`. Caveat that keeps this at low: that session's terminal was sitting on Claude's first-run theme picker, so "Unknown" may be the honest answer at that moment. I could not verify what it reads for a settled Claude session without typing into somebody else's pty.

### [partial] A dead prop that would re-introduce the exact behaviour he banned — "it will just randomly send to anyone whatever I say here."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/App.tsx:1733-1735, /Users/apple/Projects/terminaldeck/src/renderer/browser/BrowserWorkspace.tsx:118
- **Source:** VIDEO-2-TRANSCRIPT.txt para 2 (inspection mode). Found while checking the session-picker fix.
- **Evidence:** App.tsx still passes `onSendToAgent={(context) => { if (activeSessionId) window.deck.writeToSession(activeSessionId, context) }}` — a send targeted at whatever session happens to be focused. `grep -n 'onSendToAgent' BrowserWorkspace.tsx` returns exactly one hit, the Props declaration on line 118; the component never calls it. So it is inert today, but it is a loaded gun: anyone wiring it up restores the random-session send that `useAgentTarget`/`SendToAgent` were built to eliminate.

### [partial] "if I click on connector, it's like nothing is here. So you know what is it?"
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/chat/attach/McpServers.tsx:143-146
- **Source:** VIDEO-2-TRANSCRIPT.txt para 1 (composer ＋ menu).
- **Evidence:** There is now an empty state: "No MCP servers configured. Add one with `claude mcp add` and it appears here." That answers "nothing is here" but answers it with a CLI command, to the audience he named in the same recording — "not technical actual coder… mostly for the normal level of the coders or the vibe coders." The app already ships an MCP servers page with an add form (components/McpAddForm.tsx); the empty state should send him there rather than to a terminal.

### [partial] "App data settings copy… debug trace" rows: a path badged "not created yet" still offers a live Reveal.
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/settings/sections/AdvancedSection.tsx:186-198
- **Source:** PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 14.
- **Evidence:** The Open/Reveal wording split was fixed (`entry.kind === 'folder' ? 'Open' : 'Reveal'`). The other half was not: the row renders `{!entry.exists && <span className="settings-badge quiet">not created yet</span>}` and then unconditionally draws Copy and Reveal, so Reveal is offered for a file the same row just said does not exist.

### [partial] "this dark mode is a little bit a different kind of dark mode with gradients… If you see it here of Claude, it is very simple, plain. I want it to be actually like this as plain **and the same color tune also**."
- **Where:** /Users/apple/Projects/terminaldeck/src/renderer/styles/tokens.css:281-425
- **Source:** VIDEO-2-TRANSCRIPT.txt para 3. PLAN-LOCAL-FIRST.md §H recorded only "Dark mode goes flat" — the colour-tune half was compressed out.
- **Evidence:** The flat half is genuinely done and well argued: `--material-bg: #212121` opaque, `--material-sheen: none`, with the 23-step vertical ramp measured and removed. The colour-tune half was never addressed — the dark palette is a neutral grey ramp (#191919 / #202020 / #212121, r=g=b enforced by tokens.test.ts), which is a different tune from Claude's warm dark. Could not verify against his reference without opening the Claude app side by side; flagging so the second half of the sentence gets a decision.

### [partial] "Unselected tabs lifted (rgb(33)→rgb(41) dark, 252→244 light), seam still measured identical both sides, both themes"
- **Where:** src/renderer/browser/WorkspaceTabStrip.css:440-463
- **Source:** RELEASE-CHECK.md:19
- **Evidence:** Unselected tabs now carry a fill (`--strip-tab-fill: var(--fill-quaternary)`, hover `--fill-tertiary`) rather than nothing, so the lift exists. I did not measure the specific rgb values he named, and I did not measure the seam on both sides in both themes — the app was in a panel view or split for most of the audit and then restarted.

### [partial] "Agents → Check again hangs forever … It also destroys the information it had."
- **Where:** src/renderer/settings/sections/AgentsSection.tsx
- **Source:** PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 3
- **Evidence:** Clicked it live and timed it: resolved in about 6 seconds to Claude Code 2.1.233 Ready / Codex CLI Ready / Gemini CLI Ready. The hang is fixed. The second half of his complaint is not — for those 6 seconds the whole list is replaced by the word "Checking…" instead of the previous answer being held while the new one arrives.

### [partial] `hook-backups/gemini-.gemini-settings.json.bak` — "a malformed backup file is written to disk"
- **Where:** ~/.terminaldeck/hook-backups/
- **Source:** PLAN-LOCAL-FIRST.md "Found in the Settings frames" item 13
- **Evidence:** The three files on disk are `claude-.claude-settings.json.bak`, `codex-.codex-hooks.json.bak`, `gemini-.gemini-settings.json.bak` — a consistent `<agent>-<path with / → ->` scheme, not actually malformed. It only reads as broken. Low, but he flagged it, so it is worth either renaming the scheme or telling him it is deliberate.

### [partial] Settings → Agents states "Local endpoint: not running, so an installed hook has nowhere to report until the app starts it" for the first seconds after the pane opens, then flips to "listening on 127.0.0.1:51289". During that window it flatly contradicts the Hooks page, which says it is listening.
- **Where:** src/renderer/settings/sections/SetupSection.tsx:393-397
- **Source:** Live app sweep, timed
- **Evidence:** Measured by remounting the pane and polling every 500ms: the false-negative was on screen at 1.6s and resolved at 4.3s (screenshot /Users/apple/.claude/jobs/5ccc1804/tmp/agents-false-negative.png); on a cold pane it took ~14s. Source is a two-branch ternary on `endpoint.running` with no third branch for "not read yet", so unknown renders as the definite negative. Same pane's "What is installed" and "Other coding tools" show skeleton bars and "Checking…" for the same window — those do resolve, so they are slow rather than stuck.

### [partial] A chat empty state can print raw internals: "Chat is not wired into this build / The transcript reader is missing from the preload bridge."
- **Where:** src/renderer/components/ChatView.tsx:377-380
- **Source:** Source read while verifying the shell empty state
- **Evidence:** Found in the `copy` map alongside the states I did see rendered. I could not reach this state in the running app — it appears to be a defensive branch for a preload that lacks the transcript method, which the shipped preload has. Reporting it because the string names an internal boundary ("the preload bridge") rather than saying anything a user can act on; if it is genuinely unreachable it should be an invariant, not user-facing copy.
