# Release check — must be clean before anything is pushed

Asad, going to sleep 2026-08-17: *"once all of these agents and tasks are done
nicely, properly, you will review every single thing — how everything is done
according to my requirements — and make a proper list for me and verify
everything and push everything live without waiting for me to wake up."*

So this file is the gate. Nothing is tagged or pushed while anything below is
unchecked.

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
- [ ] Three tabs, Machines inside Settings — **he said "four pills" first and
      then reconsidered; flag this for him rather than assume**
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

Open, and worth his answer when it is built: can a device be changed from one
kind to the other afterwards, or does that mean re-pairing? Re-pairing is safer
and is probably right — a device that was a guest becoming an owner by a toggle
is the kind of quiet escalation this app has been removing all night.

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
