# Release check — SHIP IT. He reviewed; the review is the work list.

**2026-08-18, and this supersedes the review-gate below it.** He did the review
he asked for — four recordings, 48 minutes, transcribed into
`REVIEW-2026-08-17.md` — and then handed the whole thing back with instructions
that could not be plainer:

> *"Make a proper plan of action from all of the requirements and get everything
> done properly and tested properly on all the devices — the simulator, the
> Windows side, the MacBook side, the app side and the web browser side —
> everything properly tested and verified. Then at the end launch a proper build
> and version of it to everywhere… push to iOS, push to TestFlight, push to
> GitHub. You will not even hold this just because I did not tell you, because
> it is a serious matter and blah blah blah — because you did that last night.
> If I am specifically telling you, it means it should be live. That's it."*

So the order is now: **build the review list → test on every surface → ship,
without asking.** The one thing he asked for up front was questions, before
starting, if any were blocking. There were none that would change the work:
every ambiguity in the review resolves to "the later statement wins", and those
decisions are recorded in `PLAN-FINAL.md` rather than queued for him.

Holding the release to be safe is the failure mode he named. Do not repeat it.

## Notarization is blocked at Apple, and is not a reason to hold

Re-checked 2026-08-18 00:40. Five submissions still `In Progress`, the oldest
from 14 August and the newest a **fresh probe from 17 August 12:51** — twelve
hours and counting on an artifact that is a few hundred bytes. A hold that
catches a probe is a hold on the account, not on any build this repo produces,
and no amount of rebuilding clears it. Only Apple Developer Support can.

`TD_MAC_SIGNED_ONLY` is `true`, so the release workflow signs, skips
notarization, and ships an install note telling people to right-click → Open
once. That is a real Developer ID signature and it is checkable
(`codesign -dv --verbose=2`) — it is **not** the "app is damaged" state that
unsigned builds produce. Flip the variable back to `false` the day Apple answers.

---

## Known-failing right now, and who owns each

Reported by the cost-removal agent at the moment it finished. Each is attributed
to another agent that was still mid-edit — **that attribution is a hypothesis,
not a fact, and must be re-run rather than assumed.**

- [ ] `src/main/title-bar.test.ts` — 2 failures, attributed to the tab-strip work
- [ ] `src/renderer/finish.test.ts` — attributed to tab-strip / `tokens.css`
- [ ] `src/renderer/browser/workspace-strip.test.tsx` — 2 failures, pill polish
- [ ] `src/renderer/shell/shell.test.ts` — attributed to `tokens.css` surfaces
- [ ] `src/main/routines/engine.ts` — duplicate-function typecheck error, copilot
      routine agent mid-edit

## Before pushing

- [ ] **Full suite green.** Not a targeted run — the whole thing. Every agent so
      far ran targeted tests only, deliberately, to avoid thrashing a shared
      machine. Nobody has yet run all ~6400 together against the combined tree.
- [ ] `npm run typecheck` clean across every tsconfig, not just `tsconfig.web.json`.
- [ ] **Build the real app and open it.** Not the dev instance on 9444 — a
      packaged build. The rule from experience: `next build` while a dev server
      is live clobbers shared state, and a 200 is not a rendered page. Look at it.
- [ ] Walk the requirement list below with the app open, in **both themes**.
- [ ] Check the seams and the transitions, not only the screens — spacing
      between sections, interactions actually exercised, all pages swept.

## Requirements, to verify by looking

Each of these came from him directly. Verify in the running app, not from the
agent's report.

### Chrome
- [ ] Tabs Chrome-shaped, active tab continuous with the pane below
- [ ] Tab pills at the restored width (~144px floor), not the narrow 119px
- [ ] Unselected tabs lifted (`rgb(33)→rgb(41)` dark, `252→244` light), seam
      still measured identical both sides, both themes
- [ ] **DECISION FOR HIM.** He asked for the *selected* pill to be lifted too.
      It cannot be lifted alone: its fill is `--tab-active`, shared with the
      session bar, `.panes`, the browser workspace and the terminal's paper
      (`tokens.test.ts` holds them equal). Lifting it means lifting the terminal
      background with it. I decided **not to**, because he had just asked light
      mode to match the terminal the way dark mode does, and this would undo
      that. One line if he overrules: raise `--tab-active` and `--terminal-bg`
      together and all four surfaces follow, join intact.
- [ ] `✕` pinned to the pill's trailing edge at short, long and floor widths
- [ ] No `+` in the strip; terminal and globe icons after the last tab
- [ ] Globe opens the start page; terminal opens the dialog
- [ ] No quick-open anywhere — every path opens the dialog
- [ ] No chevron in the sidebar; two actions only (Browser, New session)
- [ ] No fold-away arrow inside a tab
- [ ] Tab `✕` closes the view only; session survives in the sidebar
- [ ] Sidebar `✕` ends the session, with its confirmation
- [ ] Anything opened from the header lands in the header and **stays** there
      until removed deliberately
- [ ] Alerts is a bell beside Settings, opening a **popup**, with no page left
- [ ] Alerts unread badge — **known unwired**; decide whether to wire or remove

### Surfaces
- [ ] Light mode: session chrome band matches the terminal body (`#e8e8e8`)
- [ ] Dark mode unchanged (`#191919`) — he likes it as it was
- [ ] Top tab-strip header stays visually distinct — he asked for that
- [ ] Browser join matches the terminal join
- [ ] Settings is one surface — rail, pane, content all one colour per theme
- [ ] Settings selected section visible in **both** themes
- [ ] `.setup-hooks` no longer invisible
- [ ] **Small leftover, not yet done:** Settings → Agents → "Run them as"
      (`sections/AgentsSection.tsx:209`) still shows the `Default` slug, as
      `Default — your own install`. Less wrong than the dialog's bare `Default`
      because it appends the explanation, but it is the same slug leaking.
      `profileLoginLabel` is exported and drops straight in. Batch with the
      copilot UI pass.

### Identity and controls
- [ ] Account chip shows the email, never "Default"
- [ ] Profile picker in the New-session dialog likewise
- [ ] Account rename works and reports collisions in the UI
- [ ] Session rename by double-click / F2 inside the terminal
- [ ] Selected account unmistakably marked
- [ ] Model and effort pickers next to the account, working for **terminal and
      chat both**
- [ ] Clicking a model actually changes a running session, verified by read-back
- [ ] Usage bar from the accurate source; "not reported" when unknown

### Panes
- [ ] Per-pane chrome — each pane names its own account
- [ ] Primary plain, secondary boxed
- [ ] A pane can hold a browser page without destroying the split

### Cost
- [ ] No `$` anywhere in the app
- [ ] Tokens, cache rate and context window still shown
- [ ] Context window names whose window it is

### Copilot
- [ ] Its folder, memory and `CLAUDE.md` exist and are visible in Settings
- [x] **Pinned entry at the top of the sidebar**, above the session list and not
      inside it — a singleton, so no ＋ that starts a second and no ✕ that ends
      this one. Stopping it is a button on its own page.
- [x] **A chat view**, which is `ChatView` unchanged with the copilot's folder
      and session — no second chat implementation — plus its terminal, because
      the login can only happen in one.
- [x] **First run explains itself.** Verified on screen: the copilot starts
      signed out, the page says why (its login is inside its own sandbox and the
      keychain is closed to one), and its own terminal is right there showing
      Claude Code's `Select login method:`.
- [x] **A defect found doing that, and fixed.** `claude auth status --json`
      **exits 1 when signed out**, and `promisify(execFile)` rejects on any
      non-zero exit and hangs the output off the error — so the probe threw away
      a complete answer and reported `unknown`, which is drawn as *"could not
      check"*. Every copilot is signed out on its first run, so the one state a
      person most needs explained was the one state the app could not reach.
      `copilot-signin-output.test.ts` pins it.
- [x] `deck-control` **wired at boot** and proven live against the running app:
      a real MCP `tools/call` over the loopback socket raised a real
      confirmation; Refuse came back `settings.write was not approved` with
      preferences unchanged; Allow wrote the change after a last-good snapshot;
      `sessions.stop` on a session the copilot did not start **escalated from
      act to alter** and asked. Both themes checked.
- [ ] **Still owed:** the copilot session is not spawned with `--mcp-config`, so
      the copilot itself cannot call these tools yet. See `INTEGRATION-OWED.md`.
- [ ] `deck-control` tools work; Alter tier **genuinely blocks** without consent
- [ ] Action log records every call
- [ ] Action log is at `<userData>/copilot-log/`, **outside** the copilot's own
      folder, and the copilot's only way to add a line is the `log.note` tool.
      An audit log the audited party can append to, edit or delete is not one.
      Proved by `copilot-log-boundary.test.ts` against a real `sandbox-exec`.
- [ ] A transcript the copilot writes under another project's encoding does not
      surface anywhere — viewer, chat, usage, alerts, artifacts — while a real
      paired-device transcript still does.
      `copilot-transcript-forgery.test.ts` asks all five.
- [ ] Routines are event-driven, with the four hard cases answered
- [x] **Copilot sessions grouped separately in the sidebar**, under their own
      heading, with "why does this exist" one click in either direction — the
      row opens the action-log turn that started it, and the copilot's page
      lists what it started. `sessions.start` now writes `origin: 'copilot'` and
      `originRunId` (the id of the very log row that call writes), which nothing
      set before.
- [ ] It runs under the same confinement as any other session

### iOS
- [x] **Four tabs — Copilot · Sessions · Localhost · Settings, copilot leftmost.**
      This entry used to say three, and to flag the question for him rather than
      assume. He answered it in the 17 August review, having looked at it *with*
      the copilot in place, and the later statement wins. Built and driven on a
      simulator. The pinned copilot row in the session list is deleted — its
      badge moved onto the pill, which is strictly better, because a consent
      question expires into a refusal after two minutes and a badge on the
      session list could only be seen from the session list.
- [ ] Pill hidden inside a session and inside a localhost page
- [ ] Back button live on same-document navigation
- [ ] GitHub sign-in completes
- [ ] No notification spam returning to the list
- [ ] Localhost list folds, groups, renames

## Found on Windows, reported and deliberately not fixed (2026-08-17)

Both came out of clearing the v0.3.0 Windows release block. Each was judged too
broad to fix as a side quest, and each is real.

- [ ] **The headless daemon cannot write `host.json` on a workgroup Windows box
      started over ssh.** `windowsPrincipal()` builds `${USERDOMAIN}\${username}`,
      and in an OpenSSH-service session `USERDOMAIN=WORKGROUP`, so
      `icacls /grant:r WORKGROUP\Imza:(F)` fails with **1332, "No mapping between
      account names and security IDs was done"** and `writeSecretFile` refuses.
      Bare `Imza` and `DESKTOP-DDGMNCV\Imza` both work. The Electron app is
      unaffected — it runs in a desktop session — but this is exactly the
      deployment `HEADLESS.md` targets. A blind fallback to the bare name is not
      obviously safe on a domain-joined machine, which is why it was reported
      rather than guessed at.

- [ ] **`custom-agents.json` is written with a bare `writeFileSync`** — no mode,
      and a temp name without the pid. It names a program the app spawns, so it
      is worth protecting. It was not routed through `writeSecretFile` because
      its directory is `<userData>` itself, and that writer runs
      `/inheritance:r` on the directory — which would strip SYSTEM from Cache,
      Cookies and everything else under the Electron root. Correct call; needs a
      narrower fix.

## Pairing has two kinds of device (2026-08-17) — queued, not built

His model, and it supersedes per-tier checkboxes as the thing a person sees:

> *"We need maybe two types of connection — saying something like **my device**
> vs **giving someone else access**. If you connect to your device, everything
> comes with full access. If you give it to someone else, then you choose the
> access / folders."*

Why it is better than what is being built underneath it: the tier question
("should this phone hold `alter`?") is one nobody wants to answer about their own
phone, and everybody wants to answer about somebody else's. Asking *whose device
is this* answers it once, correctly, in the words the person already thinks in.

- **My device** — full access. Sessions, copilot, every tier, all folders. It is
  the same person at a different keyboard.
- **Someone else** — the existing pickers. Folder grants already exist
  (`folder-grants.ts`, `DeviceFolders`); copilot access and its tiers join them.

This layers **on top of** the separate-copilot-connection work, which is the
mechanism and is needed either way. What changes is the pairing flow and the
defaults, not the enforcement.

**Decided 2026-08-17.** *"When they connect for someone else, copilot is not an
option to give at all."* So it is not a grant defaulted off — it is **absent**.
A guest is never offered it, and the pairing flow never mentions it as a thing
withheld. An unchecked box still advertises the feature and invites the ask.

**The words, settled: "My device" and "Guest."** He asked for better ones than
"my device / someone else" and said to keep those if they were best. They are
not, quite:

> **My device** — Full access. It's you at another keyboard.
> **Guest** — You choose what they can reach. The copilot is never shared.

"Guest" earns its place where "someone else" does not. It is already understood
— guest Wi-Fi, guest user — so it carries *limited, and not you* without a
sentence of explanation, and it survives every derived label: "Guest folders",
"Remove guest", "2 guests". "Someone else's folders" and "revoke someone else"
do not read.

That second sentence is load-bearing and must ship with it. Without a line
saying the copilot is never shared, its absence from the guest flow reads as a
missing feature rather than a decision, and somebody will file it as a bug or
"fix" it.

Open, and worth his answer when it is built: can a device be changed from one
kind to the other afterwards, or does that mean re-pairing? Re-pairing is safer
and is probably right — a device that was a guest becoming an owner by a toggle
is the kind of quiet escalation this app has been removing all night.

## iOS localhost browsing — DONE, confirmed on screen 2026-08-18

The Safari resolution below landed and was verified rendered: the system
navigation bar is back with its chevron and its pop gesture, and reload,
inspect and Done moved to a bottom toolbar, with **Done last** as he asked.
The section is kept because the reasoning is the reason it is right, and
somebody will otherwise re-hide that bar to win 44 points of height.

## The original note (2026-08-17) — queued at the time

> *"Local host browsing is still not native on iOS."*

It **is** a push now — `navigationDestination`, sliding in from the trailing
edge, after he rejected the `fullScreenCover` that rose from the bottom. Two
things remain, and both are in `LocalhostBrowser.swift`:

1. **The left-edge swipe belongs to the page, not the screen.**
   `allowsBackForwardNavigationGestures = true` hands that gesture to the web
   view's own history. On iOS the edge swipe is how a pushed screen is left, so
   the one gesture everybody reaches for does the wrong thing.
2. **The system navigation bar is hidden** for a custom row carrying back,
   reload, where-you-are, inspect and Done. The reasoning in the file is real —
   a system bar above that row is 94pt of chrome in two rows, with two back
   buttons eleven points apart meaning different things — but the cost is no
   system back chevron, no standard title, and no pop gesture.

The native resolution is Safari's, and it dissolves the conflict rather than
picking a side: **keep the system navigation bar** (so the chevron and the pop
gesture are the platform's), and move reload/inspect/Done to a **bottom**
toolbar, which is where iOS puts browser controls. Page-back becomes a button
there rather than a gesture competing with the system's.

He blessed the current bar's *ordering* earlier — *"last button I think is on
its correct place"* — so keep Done last wherever it ends up.

**Not dispatched yet on purpose:** two agents are mid-edit in `ios/`, and the
light-mode one has this exact file open (it carries a
`.preferredColorScheme(.dark)` call). A third agent in the same file is how the
mass-revert happened earlier today.

## A setup flow before the copilot's first run (2026-08-17) — BUILT, for review

> *"Maybe we can give a few steps flow before someone sets up the copilot. It can
> ask, what would you call your copilot, give it a name — related to identity
> setup. And keep it in-app, actually, yes in app. So it will ask those questions
> in the flow, and the copilot will always know about this and act that way
> always."*

He reasoned it out and landed in the right place: **the identity is app-owned,
not folder-owned.** Same rule as the layer — the folder belongs to the person, so
a plain terminal opened there must never be somebody's named assistant. The
answers become part of the `--append-system-prompt-file` the app hands in at
spawn.

Queued deliberately: the copilot-layer agent owns both the identity file format
and the Settings → Copilot pane, which is precisely what this writes into.
Building the wizard before that settles means building it twice.

**Keep it short.** Three or four questions, every one skippable with a sensible
default, and re-runnable afterwards rather than a one-shot you can never revisit
— the same answers already have an editing surface in Settings → Copilot, so the
flow is a friendlier front door to it, not a separate store.

Worth asking, roughly in this order:

1. **What is it called.** This is the one that matters, because he will talk to
   it constantly and its name appears in the sidebar, the tab pill and the
   settings pane. Note the naming rule in CLAUDE.md applies to the *product* —
   `BRAND.name` is read, never spelled — but a copilot's name is **user data**
   and must not go near that constant.
2. **What it should call him**, and anything about how he wants to be addressed.
3. **Which folder it lives in** — the picker, with the honest sentence about
   what it will then be able to read.
4. **Which account it runs as.**

Then show what it is about to become, before it starts, rather than starting and
letting him discover it.

There is a nice symmetry worth preserving in the copy: his own instructions to
*me* say *"He hasn't named you yet. Until he does, don't pick one for yourself —
he'll tell you."* The flow is that moment, made part of the product.

### What landed, and what to look at

Four questions and a summary, in a dialog the pinned row opens **instead of**
starting the copilot — nothing is spawned or billed until the last button.
`copilot-setup-model.ts` owns the order, `CopilotSetup.tsx` the screens, and
`shared/copilot-identity.ts` the one thing worth arguing about: **where the
answers go.**

They go into `<userData>/copilot-layer/instructions.md`, as a paragraph, through
the same channel the editor in Settings → Copilot saves with. There is no
`copilot.name` setting and no second store — the sentence *is* the record, so
editing it in Settings renames the copilot exactly as well as re-running the
questions, and nothing can drift because there is one copy. Nothing is written
into the copilot's working directory, which is the rule the whole layer exists
for. The other two answers reuse the homes they already have: the folder is the
picker's own setting, the account is a per-project pin on the copilot's folder.

To look at, in the running app:

- [ ] The pinned row, the tab pill and the bar all say the name you gave it
- [ ] Skip every question: it is told *"they have not named you yet … do not
      pick a name for yourself"*, and the app goes on calling it the Copilot
- [ ] The summary shows the literal text it will be handed, `---` and all
- [ ] Settings → Copilot → **Its name**, and "Set it up again…" — which closes
      the settings sheet and re-opens the questions with your answers in them
- [ ] Re-running while it is running says Save, not Start, and says why: a
      session is handed its instructions at `exec`

Verified on a built instance rather than the harness: `--append-system-prompt-file`
carried the block, and the copilot answered *"I'm Nova, your Terminal Deck
copilot. You're Asad."*

## Switching account must carry the conversation (2026-08-17) — next

The dialog currently says the conversation does not come with you:

> *"This conversation stays with app.imatch.ae@gmail.com. imzapremium@gmail.com
> has its own conversation in this folder and that is the one that will be
> continued here — not the one on screen now."*

Truthful about the mechanism, and not what he wants:

> *"I want it to be like that — if I switch an account it should keep going just
> like nothing happened, because this is how a normal terminal also does."*

**Worth understanding why his comparison holds and what it actually proves.** In
a terminal, logging out and back in as someone else *in another window* leaves
the first session working — because it never switched. The running process
already holds its token. "Nothing happened" is literally true: nothing reached
that session. So the normal-terminal case is not evidence that switching is
seamless; it is evidence that **not** switching is.

What he is asking for is harder and is still right: change this session's
account and keep the conversation.

**The obstacle, and why it is not a wall.** Claude Code files transcripts under
the account's config directory — `CLAUDE_CONFIG_DIR` chooses the credential
*store*, which `profiles.ts` already records — so each account has its own
history for the same folder. But a transcript is a **local JSONL file, and it is
not owned by an account.** Which account is authenticated decides who is billed
and who may call the API, not who may read a file on this disk. So the
conversation can be carried into the account being switched to and resumed
there. New turns bill to the new account; the old ones were already billed to
the old one. Nothing is misattributed.

**He then supplied the decisive evidence, and it corrects my claim above that a
running process cannot change account.** It can:

> *"I start a new session and I change the account and I come back to the
> original one — this one comes with a new limit with the new account. If I do
> any slash command and check the usage it will show me the newer account, not
> the older one I was working with."*

That is the plain CLI, where every session shares `~/.claude` and, on macOS, one
Keychain item keyed to it. The account is **not fixed at spawn** — it is read
from the store per request, so changing the login anywhere changes it for every
session using that directory, on their next turn. Terminal Deck does not see
this because it gives each profile its own `CLAUDE_CONFIG_DIR`, which is exactly
what lets two accounts run at once.

**Why that settles the design:** in his account, a conversation continued across
an account change, in place, with new limits, and nothing broke. So a transcript
is demonstrably not owned by an account, and carrying one into the profile being
switched to is not a workaround — it is reproducing what the CLI already does
when the directory is shared. The only reason it does not happen here is the
isolation this app adds on purpose.

There is a second shape worth naming and rejecting: share one config directory
and swap the credential, which is the CLI's own behaviour exactly. It would be
seamless and it would cost the ability to run two accounts at the same time,
which is a feature of this app rather than an accident. Copying the transcript
keeps both.

To settle when building it:

- **Copy or move?** Copying leaves the conversation in both stores, which is
  probably right — switching back should also feel like nothing happened.
- **Resume by id or by path?** Establish what the CLI actually accepts; do not
  assume.
- **What if it genuinely cannot carry** — a mid-turn switch, a transcript the
  new account cannot read. Then the current dialog is the right answer and
  should still appear. It stops being the default and becomes the exception.
- The switch already restarts the session in place (same tab, folder and bar
  position), and that part is correct and stays.

## Release scope — every surface, tested before any of it ships

He was explicit, twice:

> *"Pushing live means you will test first all the versions — iOS and Windows —
> and improve the website also accordingly, web app, mobile app, all of the
> versions. Then once tested everything, then push it to live including iOS."*
> …*"I mean web app also, improve according to the new things."*

So this is one coordinated release, not a macOS push followed by ports. Nothing
goes out until every surface below is aligned and tested.

- [ ] **macOS** — the reference implementation. Everything above must be green.
- [ ] **Windows** — **his PC is on 0.1.9**, so this is a build ship, not just a
      UI port. `imza-pc` → WSL2 on `DESKTOP-DDGMNCV`; toolchain verified (Node
      26.7, npm 11.19, git 2.55). Drive the GUI over **CDP**, not GDI — the
      desktop sits at the lock screen so `CopyFromScreen` fails with "handle is
      invalid". Launch into Session 1 via `schtasks /IT`; Session 0 has no
      desktop.
- [ ] **iOS** — three-tab layout and the rest are built; needs a TestFlight
      build. Last shipped was 0.2.0 build 3.
- [ ] **Web app (`pwa/`)** — align to the new chrome. Do this **after** the
      macOS design settles; porting a moving target is how the two drift.
- [ ] **Android** — establish what state it is in; align or say plainly it is
      out of scope for this release.
- [ ] **The marketing site** — separate private repo, not this one. Update it
      for what actually shipped.

## Then, and only then

- [ ] Full suite green across the combined tree
- [ ] Packaged builds opened and walked, per platform, both themes
- [ ] Push and tag every surface together
- [ ] Write the summary list he asked for
