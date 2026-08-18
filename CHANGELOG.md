# Changelog

Notable changes to Terminal Deck. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add to **Unreleased** as you go — `npm version <patch|minor|major>` moves that
section under the new version, stamps it with the date and creates the tag.
A release with nothing under Unreleased is refused rather than shipped blank.

## [Unreleased]

### Fixed

- **The app was typing `/usage` into your session and leaving the panel open on
  top of your work.** On an account billed through the API there is no rolling
  subscription window, so the CLI draws no session or weekly line at all — which
  meant the reading could never be found, every attempt timed out, and every
  attempt left the panel sitting over the conversation. Then it tried again on
  the next quiet moment, and again, for as long as the session was open.

  Three things changed. The panel is now **closed and the close is verified** by
  reading the screen back, rather than sending an Escape and assuming; if it
  genuinely cannot be closed, the app says so instead of leaving it there.
  "There are no limits to read" is now an **answer** rather than a failure, so
  it stops. And an attempt that typed into your session and found nothing
  **blocks that session for good** — enforced where the typing happens, so a
  reload or a second window cannot reach past it.

  Automatic checking stays on, because on an account that has limits the whole
  exchange measures 506ms end to end. What made it unshippable was the residue
  and the repetition. Where a session has stopped, the bar now says why and
  offers **Check again**, which is the only thing that can clear the block.

- **A session running an agent you started yourself had no model, effort or
  usage controls at all.** Two components in the same bar were answering the
  same question from two places: the account chip read the screen and correctly
  showed the agent, while the controls beside it read the session record, saw
  "shell", and drew nothing. So on any session where you opened a plain shell
  and ran an agent in it — which the app itself offers a button for — the entire
  control surface was missing. They read one source now, and they withdraw again
  when the agent exits, including when its process was killed with its banner
  still on screen.

- **A project could be drawn before its own scan had finished.** The routine
  that reads session records returned immediately if another read was already
  running, so a file-watcher event arriving during startup made the initial
  scan's own wait a no-op — and the window opened with a partial figure and
  nothing saying it was partial. It now waits for the work already in flight.

- **Forgetting or renaming a machine did not reach every screen.** Only the
  panel you did it in was told, so a machine removed in Settings was still
  offered in the browser.

### Added

- **The browser reaches whichever machine you pick.** A machine chooser sits
  beside the address bar, the start page lists what is listening on *that*
  machine, and typing `3000` opens that machine's port 3000 — the same window,
  the same tabs, the same everything. Choosing a machine changes what `localhost`
  means and nothing else: a public address is the same site from either
  computer, so it is left alone.

  Port lists and tunnels are for **your own devices**. A guest gets neither and
  is never told the capability exists — a port scan can say which program holds
  a port but never which project, so it cannot be limited to the folders a guest
  was granted. Every port or none, and none is the honest answer.

- **A remote machine looks and behaves like a project.** One machine mark on the
  heading rather than one on every row, the same pill and the same menu a local
  project has, and remote sessions get a tab in the strip like any other. Close
  on a machine ends its sessions and folds it away **without disconnecting it** —
  New session brings it straight back.

- **A device waiting for your approval says so**, instead of appearing only in a
  settings pane you had to already be looking at.

- **The web app takes an address.** A browse bar with a machine chooser: open it
  on the machine you are connected to, or in the browser you are already in. The
  three theme buttons became one icon, which also gave the header back enough
  room to exist on a phone.

### Changed

- **Settings → Copilot is half the height it was**, every file it lists can be
  edited in place, and the memory folder is one button rather than a list of
  dated filenames.

- **The model and effort chips keep their labels at every window width.** They
  had been fading to nothing below 1000 pixels — at the app's own minimum width
  they were 106 pixels of blank.

- **On the phone: the copilot's tab bar is out of the way of the composer**, and
  it appears only when the copilot is connected. Connecting moved to Settings.

## [0.4.0] — 2026-08-18

### Security

- **A paired device could reach every session on the machine, whatever folders
  it had been granted.** Three doors lead in and only one was locked. Creating a
  session checked the grant correctly. Listing sessions took no device id at
  all, so every paired device was sent every session running on the machine, and
  attaching admitted any id off that list — so starting a *new* shell in an
  ungranted folder was refused while typing into an agent **already running** in
  one was not. Underneath all three, a device with no grant record on file was
  read as "fall back to whatever this desktop is offering", which is every open
  project plus the working directory of every running session.

  Approving a device wrote nothing: six digits, Approve, and the folder picker
  was a separate block further down a page nobody had to visit.

  Approval is now the choice, and it writes before it admits — the kind of
  device, then its folders, then the approval, in that order, held by a test
  that reads the call order rather than the end state, because the end state
  looks identical when the approval comes first.

  **Devices paired by an earlier version have no kind recorded, so they become
  guests with nothing.** That is deliberate. A fix that keeps working for
  everyone who already had everything has not fixed anything. Re-pair them; the
  desktop names them and the refusal says which machine to go and do it on.

- **A device is either yours or a guest, and it cannot change kind afterwards.**
  *My device* is you at another keyboard — every session, any folder, the
  copilot. *Guest* reaches only what you tick, and **is never offered the
  copilot at all**: not a permission defaulted off, absent, because an unchecked
  box still advertises the thing and invites the ask. Changing kind means
  pairing again, which is the honest cost of not making an escalation one tap
  deep. Folder containment is re-checked on every keystroke, so removing a
  folder takes effect immediately rather than at the next reconnect.

- **Saved logins in the built-in browser never reach the renderer.** The summary
  type has no field for a password to be forgotten out of; matching is on exact
  origin rather than Chrome's public-suffix grouping, so a subdomain a stranger
  controls cannot ask for a password stored for the parent; and autofill refuses
  invisible or tiny fields and subframes and never overwrites a field that
  already has something in it. On a machine with no secure store, saving is
  refused rather than written in the clear.

### Added

- **The copilot can drive a browser, and now it actually does.** It was
  reported as unable to, and it was right. `browser_open` refused whenever no
  browser tab happened to be open already and told the copilot to ask a person
  to open one — so it quietly fell back to fetching the page and said it had not
  used the browser. `browser_read` returned an outline with no page text in it
  at all, leaving the model to guess CSS selectors to read a single line. And
  handing control back always failed, because the ninety-second window it waited
  in outlives the sixty-second limit on the call itself. All three are fixed and
  all twenty of its tools were then re-checked by asking a running copilot to use
  them in words, rather than by testing them against a stand-in.

- **It knows where you are.** Ask it what you are looking at and it can answer:
  which page, which pane, and the address and text of a page it is driving.

- **Driving mode scans instead of reading to you.** It used to stop at each
  place and hold it long enough for a person to read. Now it goes through every
  session at machine speed — including the ones you started yourself — with the
  rest of the window under a field of dots and the quoted line cut clear of
  them, and comes back to its own conversation with one answer grouped by
  session. Interactive mode can be turned off, in which case the same work
  happens with none of the showing and the same answer arrives.

- **A phone gets the copilot in full**, over its own connection rather than the
  one carrying sessions, and four tabs with the copilot leftmost. Session rows
  take swipes: pin, archive, details, close.

- **Remote machines are in the sidebar next to local ones**, under a heading per
  machine. New session asks where, then which folder, then starts — the same
  three steps whether the machine is this one or another. Controls that cannot
  act on a remote machine are absent there rather than drawn and inert.

- **The web app can open a page on the machine it is connected to**, and pick
  which machine to start a session on.

- **Dictation, once you give it a key.** Three transcription services, each
  checked against its real endpoint before the key is stored, so a key that does
  not work can never be the thing that makes a microphone appear. Until one is
  stored the microphone is absent rather than greyed out.

- **A short setup flow the first time you open the copilot.** Four questions,
  every one of them skippable, in front of the first start rather than after it:
  what to call it, what it should call you, which folder it works in, and which
  account it runs as. Then a screen showing what it is about to become —
  including the text it will be handed, word for word — before anything is
  spawned or billed.

  The name is the one that matters, because you will say it a hundred times a
  day: it appears on the pinned row, on the tab and in Settings, and the copilot
  itself is told what it is called, so it answers to it. Skipping that question
  is a real answer rather than a blank — it is told that you have not named it
  and not to pick a name for itself, and the app goes on calling it the Copilot.

  There is **no new store**. The answers are written into the copilot's own
  instruction file, in the app's storage, which is the same file Settings →
  Copilot puts in an editable box — so renaming it by editing that sentence
  works exactly as well as running the questions again, and there is only ever
  one copy of the fact. Nothing is written into the copilot's working directory,
  because that folder can be one you already keep an assistant in. The flow is
  re-runnable from Settings → Copilot, and it says plainly that a rename reaches
  a copilot that is already running only at its next start.

### Fixed

- **Every sign-in that got stuck was the same bug.** A page's request to open a
  window was always refused, and refusing it makes the page's own call return
  nothing — so a sign-in library opened its popup, was handed nothing back, and
  waited forever for a message from a window it never had. The destination did
  open, as a tab, and the sign-in did complete. It had no way to say so. That is
  the QR code that appeared and stopped and the verification link that hangs.

- **Google sign-in works.** It was being served a cut-down flow because the
  browser announced itself as Electron. Nothing else about the browser is
  disguised — the platform, engine and version stay true. If a site still
  refuses, there is now a deliberate handover: open it in your own browser,
  finish, and press a button to bring the session back.

- **A sign-in that succeeds and then fails is explained.** One agent CLI's
  sign-in genuinely completes and is then turned away on its first API call
  because the installed version is no longer supported — which is why the
  browser said it worked while the app showed nothing. The app now reports the
  version it found, says it is too old, and offers to upgrade it with the
  package manager that installed it.

- **Token totals were over-counted by about 4%.** Resuming or forking a
  conversation copies its history into a new session record, and each record was
  de-duplicated only against itself. On one real folder that was 11,110 distinct
  requests counted 11,598 times — 210 million tokens that had not been spent.
  Per-session figures are unchanged, because a resumed conversation really did
  re-send everything it inherited.

- **Artifacts shows artifacts.** It kept coming back as a file browser because
  nothing in the code held the meaning of the word, and the underlying data is a
  list of file paths. An artifact is a file an agent produced whole; a file it
  only edited is a change to your project and sits one chip away with its count.

- **Source control opens the diff instead of jumping to Files.** The panel had
  no way to show a diff — the function that fetches one had no callers anywhere
  in the interface — so every row could only leave the page.

- **A setting the copilot changes takes effect on the open window.** It would
  write the change, report success, and leave the screen exactly as it was until
  the app was reloaded. It now says which of the two happened, and it measures
  that rather than claiming it.

- **A session that ends stops being drawn.** A row could survive in the sidebar
  after the session behind it was gone.

- **The file pickers open the real one.** Add file, add folder and add an image
  open the system dialog directly, with no in-app browser and no extra click,
  and the copilot's folder picker is a proper window rather than a panel clipped
  to the app's edges with its buttons outside.

- **A session in a WSL folder can be restarted again, and a session that fails
  to start is no longer turned into a shell.** Three faults on one Windows
  machine, stacked, and each was enough on its own to lose a day's conversation.

  `wsl.exe` was handed to the terminal as a *relative* program name, and
  node-pty on Windows resolves one of those against the app's own working
  directory first — returning an empty path when it hits. `C:\Windows\System32`
  is the one directory that holds `wsl.exe`, and it is the working directory a
  process inherits from a Start-menu entry or a login relaunch. So the app was
  not told that `wsl.exe` is missing; it was told `File not found:` with nothing
  after the colon, once per WSL tab, after every restart. The launcher is now an
  absolute path, which never reaches that branch.

  The probe that asks a distribution which agents it has was reading the exit
  status instead of the output. A login shell exits with the status of its last
  command, so whenever the *last* agent asked about was not installed — Claude
  Code and no Gemini, which is the ordinary case — the probe printed
  `agent-found:claude`, exited 1, and the whole answer was discarded with the
  error. Every WSL session then reported every agent missing.

  And a session that could not start was opened as a plain terminal instead, in
  the same tab, with nothing said — and *that* was written down as what was
  open. Every launch afterwards restored a shell, correctly reported that a
  shell has no conversation to continue, and never attempted the real agent
  again. A distro that was asleep for eight seconds became permanent. What was
  asked for is now what gets remembered: a session that could not be started as
  Claude Code is a session that failed to start.

- **A session that does not come back is kept, and says so.** It used to be
  dropped — silently, and not at the moment it failed: the remembered list is
  rewritten from the running sessions, so a failed session survived only until
  the next tab opened. Now it stays in the list, appears as a row under its
  project saying what did not start and why, and offers to try again. Nothing is
  retried behind your back and nothing is dismissed on a timer.

- **The copilot is no longer restored as two ordinary sessions.** It is a
  singleton the app starts for itself, with an instruction layer and its own
  tools, and it was being remembered like a tab — twice, on a machine where it
  had been restarted. Restoring one produced a plain Claude Code session in the
  app's own storage with none of that, invisible in the sidebar and billing on
  every launch. Launches the app composes for itself are no longer written down,
  and the entries already on disk are dropped on the next start.

- **A spawn that fails says what it was starting.** `File not found:` with
  nothing after the colon appeared seven times in one log and named no file, no
  folder and no agent — accurately, because the layer that refused had no path
  to report. The agent, the folder, the program and the directory the process
  was to start in are now added by the layer that still knows them, with the
  original message kept verbatim at the end.

- **A folder on a Windows path is named by its last segment.** Project rows, tab
  qualifiers and two pickers were printing `C:\Users\…\Projects\app` where a
  word belongs, because the name was taken by splitting on `/` alone.

- **The bell in the sidebar now carries a count.** It has been drawn, styled and
  tested since Alerts became a pop-up, and nothing in the app ever gave it a
  number — *"if there is an alerts option and we don't wire anything to it to
  give us the alerts, why would we have an alerts option?"* Alerts themselves
  worked the whole time; what was missing was the mark that tells you to look.

  **Unread means: this alert has not been on screen.** Opening the sheet is
  what clears it, and that is the only thing that does — five of the six alert
  kinds describe a condition that is still true after you have read about it, so
  a per-row dismiss would either lie about the project or come back on the next
  scan. An alert that gets *worse* counts as new: a session blocked for ten
  minutes and the same session blocked for forty-five share one id, and the
  escalation is the most important thing this panel says, so the bell lights
  again for it exactly once. The record is per project, kept in the window's own
  storage so the dot is right on the first frame rather than a frame later, and
  it is bounded in both directions — a project remembers only the alerts it
  currently has, and only the last thirty-two projects are remembered at all.

  It costs nothing when nothing is happening. The reason the count was left
  unwired was that the only thing which knows the number is a scan of every
  transcript in the project, and putting that on a timer was a price the window
  would not pay for a dot. So the scan is driven by the events the app already
  receives — a session changing status, starting or exiting — at most once a
  minute, which is no more than the panel already cost while it was open, and
  never at all on a quiet machine. The one alert that is genuinely about a clock
  rather than an event, a session that has been waiting on you for ten minutes,
  gets a single wake-up armed for that exact moment instead.

  The sheet and the bell now read one report, so they cannot disagree about how
  many there are.

### Removed

Each of these was drawn, looked usable, and could not do what it appeared to.
Removing them is the change, not a side effect of one.

- **The row of controls inside the message box.** It repeated what the bar above
  already carried. Attaching a file stays; everything else in that row is gone,
  along with the two components behind it.
- **Refresh and Reconnect on the phone.** Refresh sent exactly the frame that
  pulling the list down already sends. Reconnect asked for something the app
  does by itself on foreground, on a network change, and on a backoff — a button
  for it is an admission that it might not. The one manual retry left appears
  only when the connection is down *and* not already retrying.
- **The pace controls in driving mode**, and the reading-time estimate they were
  built on. Nothing measures how long text takes to read any more, so the dial
  had nothing left to turn.
- **The language picker**, which had one option.
- **The bottom band of the browser.** What was there moved to the top right;
  what was a label for a single tab is gone.
- **The copy of the hooks page inside Settings.** It drew the same three
  providers with the same three buttons as the page of the same name.
- **A list of past sessions on the overview**, where every row opened the same
  session — which was not a bug in the list, it was the only thing the list
  could do. The itemisation it belonged to still adds up to the headline.

## [0.3.0] — 2026-08-17

### Added

- **A copilot.** An assistant for the deck itself, pinned above the session
  list: it can see your sessions, read their transcripts, start new ones and
  change settings, and it keeps a memory of your conversation with it. It is a
  developer's assistant and not a general one — no inbox, no calendar. It is
  built as **a real session** rather than a hidden service, which is the whole
  point: its folder, its instructions, its memory and its transcript are all
  files you can open, and Settings → Copilot shows you exactly what it reads
  before it starts.

  It runs inside the same sandbox as any other session — **including from us**.
  Proven against `sandbox-exec` rather than asserted: it cannot read your home
  directory, your SSH keys, your keychain or any other account's login. Its
  routines and its action log live *outside* the one folder it can write to,
  because a routine it could author without asking is not gated, and an audit
  log the audited party can rewrite is not an audit log. A consequence worth
  stating: it starts **signed out**, because the keychain is closed to it, and
  its first screen says so.

- **Routines** — saved instructions that run on their own, triggered by
  something happening rather than by a clock: a session finishing, a session
  failing, git state changing, a file changing. A schedule is one trigger among
  several, not the foundation. A routine that fires while nobody is at the
  machine is refused an action needing consent, immediately and legibly, instead
  of hanging on a dialog no one can answer.

- **Add your own agent.** The list of agents is no longer four names compiled
  into the app. Name a command, and it runs — with the honest caveat drawn on
  the row that an agent we have never characterised gets a terminal and not a
  model picker.

- **Model, effort, fast mode, connectors and usage live in the chrome**, beside
  the account, for a terminal as much as a chat. Clicking a model now actually
  changes a running session — and refuses, saying why, when your prompt has
  something typed in it.

- **Attach a file from anywhere**, through the real system dialog, by drag and
  drop, or by paste. The picker had only ever offered files inside the project.

- **Draw on a page and send it to an agent**, alongside inspect and record.

### Changed

- **Tabs take Chrome's shape** and join the pane below them. The `+` leaves the
  strip; a terminal and a globe sit after the last tab. There is one path to a
  new session and it is the dialog.
- **A tab's ✕ closes the view, not the session.** The session keeps running and
  stays in the sidebar; only the sidebar's ✕ ends one.
- **Chrome belongs to the pane, not the window.** In a split, each pane names
  its own account, folder and session — an account chip drawn once above two
  sessions from two projects was wrong for at least one of them, with nothing
  saying which. The main session keeps its chrome in the top bar, which is what
  makes it read as the main one.
- **A pane can hold a browser page.** It could only hold a session before, so
  anything else was by definition a closed one and the split collapsed.
- **Notifications open as a popup** rather than taking over the window.
- **Settings is one surface** — no card floating on a pane, and the selected
  section is marked by colour and weight rather than by a grey box that kept
  disappearing in dark mode.

### Removed

- **Every price and cost figure.** One of the two could not be computed at all —
  nothing is published from which to derive what a subscription costs per token
  — and the other told someone on a flat monthly fee that they had spent money
  they had not. Token counts, cache share and context window stay, because those
  are facts rather than inferences.

### Fixed

- **Hooks stopped working every time the app restarted.** The endpoint took a
  new port on each launch and that port was written into the hook files, so
  session-finished events silently never fired — and a credential was written
  into `~/.gemini/settings.json` world-readable. The endpoint is now a socket at
  a path the kernel cannot reassign to a stranger.
- **The model picker left a dialog standing on your terminal.** It typed
  `/model` into a live prompt; on any session with history the CLI answers with
  a confirmation dialog, and the next Return *you* typed answered it. It now
  waits for the screen to echo the command before committing it, and refuses
  outright when you have something typed.
- **Clicking a file in the tree closed the Files page.** Navigation was a
  toggle, so selecting the page you were already on turned it off.
- **A confined session died on its first turn on macOS**, before generating a
  token, because Claude Code keeps scratch files at a path outside every
  sandbox. This also broke sessions started from a paired phone.
- **The file viewer drew characters the file did not contain** — `<!--` as
  `←!—`, `-->` as `⟶` — because programming ligatures were on in a pane whose
  whole job is showing text verbatim.
- Settings panes that contradicted themselves: a lid switch its own notice
  denied, a sound picker promising to play under a switch that stopped it, a
  language dropdown with one option, a debug file offering Reveal when it did
  not exist, and three identical warnings about browsers that were not installed.
- The account is named by its email everywhere, instead of the internal word
  `Default`. Renaming an account worked on none of them; it works now.
- Sessions with the same name are told apart by the shortest id prefix that
  actually distinguishes them, rather than by a fixed cut that could collide.
- A scrolling sidebar fades at its edge instead of slicing the bottom row
  through the middle of the letters.

## [0.2.0] — 2026-08-16

### Changed

- **A pairing code is six digits.** No dashes, no letters, one method. The
  pairing **link and the QR code are gone entirely** — deleted, not hidden: the
  QR encoder, the iOS scanner and its camera permission, the Android scanner and
  its `CAMERA` permission, and every `terminaldeck://pair` route into a
  credential write. Every client takes six digits on a numeric keypad and submits
  on the sixth.

  Six digits is a million codes where eight Crockford characters were 1.1
  trillion — a **1,099,511-fold** reduction, stated here rather than buried. What
  makes it sound is unchanged and now pinned as values rather than assumed: a
  code lives 60 seconds, is single-use, and dies after five wrong guesses; and
  redeeming one still only creates a *pending* device a human approves. The
  rendezvous slot is derived through memory-hard scrypt, which is what stops the
  space being swept — without it, five guesses would buy nothing because an
  attacker would never need a second one.

- **Machines and Remote are one section**, in the rail where Machines was. They
  were the same subject — devices paired with this machine — described in two
  places. It went to Settings first, which was the wrong half to keep: pairing a
  device is something you do, standing at two keyboards, not something you
  configure once.
- **The "Direct on your tailnet" card is gone.** The relay is the network.
- **Overview is a live board of running sessions** — what each agent is doing,
  how long it has been doing it, and which one is waiting on you. Deliberately no
  progress bar: an agent does not report progress, and a number the app invented
  is worse on that screen than no number.
- **Search is replaced by Artifacts** — every file your agents wrote or changed,
  with the diff of each change. Searching past sessions moved to the command
  palette's `?`, where it is one keystroke from what you were already doing.
  Search's own results had never been clickable.
- **Windows has one title bar** instead of an OS strip, a menu strip and the app's
  own chrome. Real Windows minimise/maximise/close, snap layouts intact. The menu
  is hidden rather than removed, so every accelerator still works.
- **An account belongs to an agent.** Adding one asks which — Claude Code or
  Codex CLI, both verified to isolate a login. Gemini is listed and refused, with
  the reason on the row: its token lives in one keychain slot no config directory
  moves, so a second login would overwrite the first rather than sit beside it.
- About 900 words of on-screen prose removed, with every warning kept.

- **Start the dev server behind a localhost link**, from the desktop or a phone.
  Per project, because that is what is true — one global button would have to
  guess which of four checkouts you meant. "Ready" means something accepted a TCP
  connection, not that a process started or a log line matched.
- **Sessions can be dragged into the top strip** — the strip was built and
  nothing in the app was draggable, so it looked finished and did nothing.
  Promote and demote also work from a row toggle and ⌥←/⌥→.
- **A session can be renamed**, and an auto-derived title can no longer overwrite
  the name you typed.
- **Light and dark in the web client**, following the system by default.
- Menus close each other. The Options menu stopped repeating the two chips beside
  it.

### Removed

- **The GitHub notifications bell.** GitHub's notifications endpoints accept only
  classic personal access tokens; a GitHub App user token is not one, and no
  permission can be added to change that. Sign-in is the GitHub App and nothing
  else now — the classic OAuth path went with it.

### Fixed

- **Keep-awake held nothing.** The app's own power-save blocker was gated behind
  the *privileged* system sleep setting, so on every machine where that had not
  been granted — including every machine on first run — no lock was held at all.
  An unreadable `pmset` also released a lock that was correctly held and then
  cancelled the timer that would have retried.
- **Sessions did not come back on Windows.** `encodeProjectPath` resolved a WSL
  path against the Windows host, so `/home/you/x` became `C:\home\you\x` and
  matched nothing the Linux agent had written. The same fault emptied the Files
  page on Windows.
- **Adding an account always signed you into Claude.** The preload dropped the
  options object, so the provider never crossed the bridge. Signing in beside a
  Codex account opened a Claude session, which then correctly refused the account
  — so it was silently discarded too.
- The Overview git tile printed git's raw stderr at the user.
- A new browser tab opened on `localhost:3000` whether or not anything was
  listening, landing on Chromium's error page instead of the start page.
- Browser popups and the session flyout rendered *behind* web content — a native
  view is composited above the whole page, so no `z-index` could ever have fixed
  it.
- The trailing "Read from the session transcript" line under a conversation.

## [0.1.9] — 2026-08-16

Four batches of work since 0.1.8 and **none of it is in a tagged build**. Anyone
reading this from a downloaded release has none of what follows.

Two things below have been proved on one operating system only, and are marked
again where they appear. **A Mac has never talked to a Windows PC**:
machine-to-machine pairing has been run end to end against a real relay, a real
`RemoteAuth` and a real pairing desk — with both ends in one macOS process on
loopback, which is where every seam that has ever broken lives, and nowhere
else. And the **iOS UI tests compile but have not been executed against a live
host**.

### Added

- **One machine can be paired to another with an eight-character code**, and
  then drive its sessions from the Machines panel. Crockford base32 with `I`,
  `L`, `O` and `U` removed — exactly 32 symbols, so eight characters carry
  exactly 40 bits with no modulo bias, and no pair of symbols can be misread for
  each other on a screen across a desk.

  A typed code cannot carry an address, so it names a slot at the relay: the
  machine showing the code sits in that slot for the sixty seconds the code
  lives and answers with its real URL, host id and public key. A hostile relay
  cannot answer in its place, because the responder's static key pair is derived
  from the code as well — the offer channel is ordinary Noise IK whose identity
  only a code-holder can produce. No relay change and no new primitive.

- **Per-device folder grants.** The machine that owns the files decides which
  folders each paired device may **start a session in**, per device, and every
  client reads that list from the wire instead of inventing one from whatever
  sessions it can see. Editing the list pushes it to the device immediately.

  Read that sentence literally: it decides **where a session starts**. It is not
  a sandbox and nothing in the app may say otherwise — a shell that starts in a
  granted folder can `cd` anywhere the user account can reach. It is
  organisation, in the same spirit as choosing which folder a file dialog opens
  in. The security boundary is the one that was already there: pairing, plus a
  human approving the device on the machine itself.

  A device with no record falls back to the old behaviour rather than being
  locked out — two phones were already paired when this was written, and a
  refusal that arrives on a phone in another room is a bug, not a policy. An
  empty recorded list is a different fact and is honoured: that is somebody
  having removed every folder, which means nowhere.

- **The credential proxy — their GitHub, from their device, never on yours.**
  Two halves, and the first ships regardless of the second:

  A session started from another device is handed **its own git configuration**
  rather than the machine's, so `git push` cannot reach the owner's account
  through any of the four doors it used to: the credential helper (an empty
  `credential.helper` entry, which is git's "forget every helper seen so far",
  followed by ours), the rest of the global config (`url.insteadOf`,
  `http.extraHeader`, `include.path` — the whole file is replaced through
  `GIT_CONFIG_GLOBAL`), `gh` (its own config directory and token variables), and
  ssh (GitHub remotes rewritten to HTTPS; anything left over gets an ssh with no
  agent and no identity file, so it fails loudly instead of quietly succeeding
  as the owner).

  On top of that, when git on the host needs a login, the request crosses the
  sealed channel to the device that started the session, is answered there, and
  is used once in memory. It is asked through a git **credential helper** rather
  than `GIT_ASKPASS`, because askpass is handed a host and not a repository, and
  "approve a push to github.com" is consent to push anywhere the account can
  reach. Fetches and clones are silent; a push asks once per repository and
  remembers the answer for as long as the app is running. Nothing is written to
  the host's disk, so revocation is disconnection.

  **The host half and the iOS client are done. Android and the browser client do
  not answer a `credential.request` yet** — they never advertise the capability,
  so a host never asks them, and nothing on either offers to sign in to GitHub.

- **Sessions in WSL, routed by the folder rather than by a switch.** A Linux
  path (`/home/asad/proj`) launches through `wsl.exe` inside the distribution; a
  Windows path (`C:\Users\Asad\proj`) launches through `cmd.exe` as before. The
  shell and the files therefore never end up on opposite sides of the boundary,
  which is the one arrangement that is both slow and confusing. There is no "use
  WSL" toggle on purpose — a toggle is what lets the two disagree. The single
  choice a person does make is *which* distribution, in Settings → Linux, and
  only because a path genuinely cannot answer it.

- **A headless host: the same machine, without a window.** Core (sessions, the
  remote server, crypto, grants) is split from shell (the Electron window, menus
  and renderer), and a plain-Node daemon takes the core. Not a second
  implementation — a fork would mean every fix landing twice and one copy
  rotting.

  The user interface is the terminal it was installed from: `pair`, `status`,
  `folders` and `stop`, and deliberately no fifth command. Idle mode holds only
  the relay connection when nothing is attached and wakes on the first attach,
  driven by the attach and detach events that already exist rather than by a
  timer; the WebSocket ping/pong stays, because a NAT drops an idle connection
  in silence without it.

  Verified end to end on macOS against the live relay with a real pty and no
  Electron in the process. **It has not been installed in WSL yet**, which is
  the machine it was written for.

- **Features, not plugins.** Settings → Features switches parts of the app off
  and back on: the browser pane, split view, every-session-at-once, cost and
  usage, alerts, GitHub, MCP servers, hooks, AI readiness and voice dictation.
  Everything ships inside the app always — installing turns one on,
  uninstalling turns it off and clears the data it declares it owns, nothing is
  downloaded and no third-party code ever runs, which is why reinstalling is
  instant.

  One registry file declares each feature and every surface it gates, and the
  surface ids are typed against the panel, section and widget ids, so renaming a
  panel without renaming it there fails the build rather than leaving a feature
  that gates nothing.

  Remote access is **not** in the store and never will be — the tunnel, the
  clipboard, file transfer, pairing, device grants and the Machines panel are
  the product, not an option. A test asserts no entry ever claims one of those
  surfaces.

  A store's own failure mode is undiscoverability, so where a feature would have
  been, the app offers it: the empty split view says split view is available and
  the button installs it and splits. The dead end would be the bug, not the
  absence.

- **Keep this machine awake with the lid closed** (Settings → Power), and it
  reports the system's answer rather than its own intention. Electron's
  `powerSaveBlocker` does not do this — it blocks *idle* sleep, and closing the
  lid is a different path — so the switch reads and writes macOS's own
  `SleepDisabled` and every read goes to the OS instead of to a stored boolean
  that could be stale. The blocker is still taken, because idle sleep is a
  second real way to lose a running agent. `Sleep On Power Button` is a
  different key and is never touched, so the power button still locks the way it
  always did.

- **Sessions come back continued rather than reopened.** Restore-on-launch has
  existed as a switch since the beginning and reopened only *projects*; its own
  help text said so. It now reopens the sessions and hands the CLI its own
  resume flag, with one rule that comes from `claude --continue` itself: it
  picks the most recently written conversation in a folder, so the most recently
  used tab in a conversation store continues and its siblings start clean rather
  than two tabs attaching to one transcript.

- **The iOS key bar and the terminal's gestures were rebuilt.** The bar this
  replaces put twenty-six buttons in one horizontal scroll view and added
  *dismiss* last, so the control reached for most often was the furthest away:
  putting the keyboard down meant scrolling past the symbol row, four signals,
  home, end, pgup, pgdn, copy and paste. A scrolling key bar is the wrong shape
  anyway — you cannot see what is in it, and a key's position moves as you
  scroll, so no muscle memory ever forms.

  The bar never scrolls now and holds only what is pressed constantly while
  typing a command, with *more* and *dismiss* pinned hard right; everything else
  lives in a grid that opens where the keyboard was, grouped and labelled so it
  can be read instead of hunted. Seven 44pt targets is about 350pt of content,
  which fits a 375pt phone — the arithmetic is in a test, because it is the
  whole design. There is no cmd or win cap: a PTY cannot receive either, so they
  would have been two dead controls in a brand-new grid.

  Gestures follow the system rather than the library: one finger scrolls, a
  half-second press selects the word under it, dragging extends the selection,
  and letting go offers the standard Copy callout. Scrolling needed no code —
  the terminal is a scroll view — only the two recognisers that were taking the
  drag away from it.

  **The UI tests for all of this compile and have not been run against a live
  host.** They are written to pair themselves against the harness and to run on
  a 375-point screen, because on a 430-point one the old bar looked nearly fine,
  which is how it shipped.

- **Split view is on screen.** `SplitView.tsx` and `pane-tree.ts` were written,
  tested and rendered nowhere for their whole life, and came within a commit of
  being deleted as dropped. What was missing was never code: it was the answer
  to "which session does the sidebar name", and the answer is the focused pane.
  ⌘D splits, the divider drags, and the sidebar follows focus.

- **A restored session comes back with its conversation on the screen**, not
  just in the model's context. Everything already survived a quit except the
  picture — `claude --continue` re-reads the whole transcript, while scrollback
  lived only in memory and died with the process, so a reopened tab was an empty
  terminal in front of a fully-contexted session. That works and it looks
  identical to having lost the lot.

  The transcript the restore decided to continue is read back through the same
  reader chat mode uses and painted above the session's own output. It is a
  read, never a re-run: nothing is sent to the CLI and no command re-executes.
  It is bounded to the last 800 lines of prose and says at the top that the rest
  is in the transcript rather than pretending the buffer is whole; it is dim,
  ruled off at both ends, and never ends in anything that could be mistaken for a
  prompt. Nothing is summarised — a generated summary would replace real history
  with a paraphrase, which is the loss this exists to prevent.

  The text goes into the session's scrollback buffer rather than into the
  process, so it reaches a phone that attaches later already flagged as replayed
  output, and the headless host — the one that restarts on its own, where WSL
  takes the whole process down with the last terminal — paints it too.

### Changed

- **The accent is blue, taken from the app icon rather than invented**, and dark
  mode is a neutral grey with the warm cast removed. Orange survives nowhere as
  an accent.
- **Settings is a modal with its own section rail**, not a full page that takes
  the window away from what you were doing.
- **The sidebar's close control moved out of the panel header** to sit beside
  the window buttons, and the panel edge reveals on approach and pins on click.
- **A new session starts immediately**, in the folder used last, with the folder
  still changeable from a chip until something is typed. No dialog in the way.
- **One segmented mode switch** in the top right, rather than a strip of
  controls.
- **One parser for the wire, not two.** The browser client carried its own
  decoder for the frames a host sends; it now calls the desktop's
  `parseServerMessage`, which is the only TypeScript reader of an inbound frame
  in this repository. Two decoders for one wire is how the two ends drift while
  both keep compiling. As a side effect the browser client now enforces the same
  maximum message size every other reader does — it had none.

### Removed

- **The task board, code and all** — the page, its state module, its
  main-process store, its dashboard widget, its menu item and its ⌘⇧B. Not
  wanted: a board is something you keep up to date by hand, and nothing else in
  this app asks that of you. Removing half of it would have left rows that open
  nothing, which is worse than the feature was.
- `requestNotificationPermission`. In a renderer it resolves `granted` without
  asking anyone, so the "Ask now" button it backed did nothing while looking
  like it had done something.

### Fixed

- **Notifications actually arrive, and the app can tell when they do not.**
  `Notification.permission` is always `granted` in an Electron renderer —
  Chromium answers from its own permission model and never asks
  `UNUserNotificationCenter` — so the app read a healthy permission it had not
  checked, enabled its Test button on the strength of it, printed "Sent." for a
  delivery it had not confirmed, and then blamed a Focus mode, which was the one
  cause that had been ruled out. macOS had put up its authorisation prompt, the
  banner-shaped one whose Allow hides behind *Options*, and nobody had ever
  answered it.

  The app now asks macOS's own notification store whether anything arrived, with
  three verdicts of which only `delivered` reads as success; every branch that
  cannot ask says so. Two measured facts are encoded in it: the row is written
  when the banner *leaves* the screen, about six seconds in, so a short poll
  would have cried wolf over every banner that worked; and the store lower-cases
  the identifier, so an exact match found nothing for banners that plainly
  arrived. Authorisation is requested when a banner preference is switched on,
  where somebody is looking at the screen, rather than on a background event
  where the one prompt macOS ever shows is missed for good.
- **Changing the theme recolours the terminals that are already open.** They
  resolved their xterm palette once at construction and never again, so a switch
  to light mode left every open terminal a black slab in a white app.
  `subscribeTheme` existed, was documented as being for exactly this, and was
  called by nothing.
- **The folder chip's menu is clickable.** It painted *under* the terminal and
  could not be reached. Not a z-index problem: `backdrop-filter` creates a
  stacking context, and on a statically positioned box that paints with in-flow
  content, beneath every positioned descendant whatever z-index it asks for. The
  same property from the other side made the menu a backdrop root's child, so
  its own blur sampled nothing and terminal text read through its labels.
- **MCP servers get the login PATH on Windows.** `{ ...process.env, PATH: path }`
  leaves Windows' own `Path` spelling in place, so the child process held both
  keys with no rule about which it reads — and the one it ignored was the PATH
  that had just been resolved.
- **Session restore is no longer blind to profiles.** A session under a work or
  personal profile asked `~/.claude`, was told there was no conversation, and
  came back blank on top of an intact transcript. The unit is a conversation
  scope now — provider, config directory and folder — and the config directory
  is required, so making that mistake again is a compile error.
- **A notification no longer says the same word twice.** A tab keeps its folder
  name until the conversation has a title, which made the common case read
  "terminaldeck / terminaldeck needs your input".
- macOS signing works end to end — identifier `dev.terminaldeck.app` rather than
  Electron, hardened runtime, `codesign --verify --strict` passing. **Builds are
  still unsigned**: a Developer ID certificate cannot be issued over the API
  (`POST /v1/certificates` answers 403 "can only be performed by the Account
  Holder"), so it needs one interactive sign-in that has not happened.

### Security

- **A wrong pairing code is counted.** `authenticatorFor` refused an unknown
  code *before* `redeemPairingToken` ran, so a wrong guess never reached the
  rate limiter. That was harmless while a token carried 256 bits and is not
  harmless at 40. Misses are counted now and a code burns after five, which is
  what makes the arithmetic in that file honest rather than decorative.
- **A guest session no longer inherits the host's GitHub.** See the credential
  proxy above; this half shipped on its own and needs nothing on the other end.

## [0.1.8] — 2026-08-14

### Fixed

- **Nothing sent to a phone calls a Windows PC a Mac any more.** Ten sentences
  in the remote server crossed the sealed channel saying "this Mac" — *"This
  device is not allowed in. Pair it again from the Mac."*, *"This Mac cannot
  start sessions from a phone."*, *"Stopped from the Mac."* — and one phone can
  now hold several machines at once, so those could appear on screen directly
  beneath a row naming a Windows PC. The phone already prints each machine's own
  label beside anything it says, so wire copy names no platform at all; copy the
  person at the keyboard reads keeps the noun and gets it from `machineNoun()`,
  which knows.

  This is the third sweep of the same rule by the third pair of hands, so it is
  scanned now rather than swept again: a string literal in a module whose output
  crosses the wire may not name a platform, and the test says which lines are
  wrong when one does. Run against the previous release it reports all fourteen
  it was written for — including four that a careful reading of the diff had
  missed.

## [0.1.7] — 2026-08-14

### Fixed

- **The localhost tunnel reaches a dev server on `::1`, which on Windows is
  most of them.** Windows resolves `localhost` to `::1` before `127.0.0.1`, so
  `vite`, `next dev` and `node --host localhost` bind IPv6 and nothing else —
  and the tunnel only ever dialled `127.0.0.1`. The port was scanned, listed,
  offered to the phone and then refused the moment it was tapped, with no
  message anywhere: the phone showed a blank page. A port that is listed and
  unreachable is worse than one that is not listed.

  The scan now carries the address family it always knew and the tunnel dials
  the loopback the port is actually on, deciding once per tap by connecting
  rather than per browser connection by guessing. When nothing accepts on
  either loopback the tunnel is refused with a sentence naming what was tried,
  instead of opening a pipe that cannot carry bytes. Nothing changed on the
  wire — the phone still names a port and this side still decides where that
  port lives — and nothing changed about the tunnel being a **byte pipe rather
  than an HTTP proxy**, which is what keeps hot reload, SSE, cookies and the
  WebSocket upgrade working.

  Measured on a real Windows machine, all three ways a dev server is started:
  `localhost` binds `::1` alone and `127.0.0.1` answers `ECONNREFUSED`;
  `127.0.0.1` and the wildcard bind are unchanged and still dial IPv4 first.
  A real HTTP response and a real `101 Switching Protocols` upgrade were pulled
  through the tunnel in each case.

- **Windows installs its own updates without anyone clicking an installer.**
  Finding and downloading an update already worked there; installing did not.
  `quitAndInstall()` with electron-updater's defaults runs the NSIS setup
  *without* `/S`, and this project builds an assisted installer — so the app
  quit, a setup window nobody asked for opened, and it sat on a page waiting
  for a click. Watched happening: fifty seconds later the setup was still
  running, the app was still the old version, and there was no app on screen at
  all. The update now installs silently and the app comes back, which is what
  the button saying **Restart** promises.

- **The portable Windows build no longer offers an update it cannot install.**
  It is the same build as the installed one and carries the same release feed,
  so it reported itself updatable — and an update on Windows is an installer,
  which would have put a *second*, installed copy of the app somewhere the user
  did not choose while the portable exe they were running stayed old. It now
  says plainly that a portable app cannot update itself and points at Releases,
  which is what the release notes have always claimed.

## [0.1.6] — 2026-08-14

### Fixed

- **The phone client is in the app.** It never has been. `webRoot` points at
  `pwa/dist` inside the bundle, and 0.1.3, 0.1.4 and 0.1.5 all shipped without
  it — so the tailnet address the Remote panel prints for you to open on your
  phone answered with nothing at all. The native phone apps were unaffected;
  they speak the sealed protocol directly and never fetch that page.

  Nothing failed loudly enough to notice. `pwa/dist` is build output, so it is
  gitignored, so a clean release checkout does not have it, so the line in the
  packaging allowlist that names it matched zero files — which looks exactly
  like a line whose files were all excluded on purpose. It only ever worked on
  a machine where someone had built the phone client by hand at some point.
  Packaging builds it now, and the release check fails if the built page is not
  in the bundle.

## [0.1.5] — 2026-08-14

### Fixed

- **Remote access now works without anyone switching it on — which is the whole
  point of it.** The relay had existed for a day and this Mac had never dialled
  it once outside a test. `start()` ran only from a two-press switch in
  Settings → Remote, and nothing re-ran it on the next launch, so a computer
  that had been restarted simply was not reachable. Measured on the machine this
  was found on: the host identity on disk, two paired iPhones in the trust
  store, the relay up — and not one socket to it. A phone attaching to that host
  was attaching to something that was not there, which is exactly what
  "connected, but showing me old output" looks like from the sofa.

  It dials at launch now, every launch, unless this Mac was deliberately
  switched off — and that off is remembered, so off still means off. Dialling
  exposes nothing by itself: the relay learns that a host is online and no more,
  and a device still has to be paired *and* approved before one byte moves. A
  launch dial that fails says so in the log rather than failing silently,
  because there is no user waiting on a reply to it.

  Proven on the packaged app rather than asserted: an established socket from
  its own process to the relay, the panel reading Connected against this Mac's
  host id, and the relay's host count rising when the app launches and falling
  when it quits.

- **The Remote switch no longer describes the opposite of its own position.** It
  read "Off by default. Nothing can reach this Mac while it is off." beside a
  switch that is now on.

## [0.1.4] — 2026-08-14

### Added

- **One phone, several machines.** A phone paired to a second computer used to
  quietly drop the first — the relay was always a map of host ids and the wire
  cannot tell a Mac from a Windows PC, so the only thing that was ever single
  was the phone's own storage. Pairing now *adds* a machine: each one owns its
  own transport, its own sealed channel against that machine's static key and
  its own sessions, so two machines cannot read each other's work. All of them
  stay connected, so switching needs no handshake, and the keepalive they need
  is folded into one app-wide tick — 144 radio wake-ups an hour at one machine
  and at five, measured rather than asserted.

- **Tap an element on the tunnelled page and send the change to the agent.**
  The desktop browser's inspect mode, now on the phone: tap, say what should
  change, and it lands in a terminal on this Mac as exactly one line. The rule
  is transcribed from the desktop's `CapturePanel`, not approximated, so both
  clients hand the agent identical strings — a newline would submit the prompt
  early and an ESC would repaint the terminal it arrived in.

### Changed

- **Every page has one blank, and it is the same blank.** Empty states were
  four different designs across ten panels — GitHub drew its own glyph, title
  and button, MCP printed a bare sentence with literal backticks in it, the
  board dropped inline text into a column, the Overview hand-rolled a third
  variation. There are two now: one for a page with nothing on it, one for a
  section of a working page or a page still reading — parked at the same
  height, so the answer lands exactly where "Reading…" was.

- **No-project screens ask once.** They used to reprint the toolbar subtitle
  and offer four different ways to open a project; the empty Overview added a
  drag hint for widgets that were not there, a Reset with nothing to reset, and
  a second Add widget one line above the first.

- **Settings → Help no longer duplicates the window's own menu.** It drew its
  own sub-navigation offering Shortcuts and About two rows above the window's
  Shortcuts and About — the same keymap, the same version numbers, two ways in
  from one screen.

- **Context → "How it filled" draws something.** It plotted a percentage of the
  context window against a fixed 0–100 axis, and a healthy session peaks near
  four percent, so every point landed within a pixel of the baseline. The axis
  scales to the peak now, on a ladder whose rungs halve cleanly, with gridlines,
  a marked peak, a cursor and a readout that follows the pointer — and both the
  ticks and the caption print the ceiling, because the honesty problem was never
  the scale, it was a chart that drew nothing.

- **"Unknown" is gone where the answer was never knowable.** Fast mode said
  Unknown beside three siblings that always resolve, which read as this app
  failing; the CLI announces fast mode only when it changes and keeps it out of
  `settings.json`, so a session that has never been told has nothing to report.
  It says "Not reported" and the menu says why. Codex's blank version row is the
  same fix — it is found on PATH and its `--version` errors, so the row says
  "version not reported".

- **A release build can be produced from a commit without publishing it.** The
  release workflow can be dispatched by hand, and publishing stays gated on a
  version tag. Building an installer locally to check something meant packaging
  whatever the working tree happened to hold at that moment.

- **The installer is checked for what is inside it, not just that it exists.**
  A platform `files:` list in electron-builder replaces the root allowlist
  rather than extending it, which shipped the whole repository — a 1.0 GB app —
  until it was caught. Both platform blocks were fixed, and CI now fails if any
  build carries `ios/`, `android/`, `relay/`, `src/` or `build/`, if the app
  cannot start, or if an artifact lands outside a sane size band.

### Fixed

- **The inspector stopped jumping under the pointer.** It re-centred on every
  tab press: the four panels are 96 timeline rows, two tables, and one table
  plus a chart, so the tallest ran past the floor and the sheet moved 50px each
  time. A definite height parks it and the body scrolls.

- **The phone's Connected badge no longer claims a connection the app does not
  have.** Observed against the live relay: no guest attached for a sustained
  forty seconds while the app read Connected. Resuming was a no-op while the
  state said online — but "online" was decided before the phone went in a
  pocket, and nothing tells a socket that a carrier NAT reclaimed it. Resuming
  now doubts the channel, says "Checking", and probes immediately.

- **Quitting with a live session no longer prints a wall of errors.** Stopping
  the app while a terminal was still producing output threw
  `Render frame was disposed before WebFrameMain could be accessed`, once per
  message still in flight. The main process was broadcasting into a window that
  had already gone. Nothing was lost and nothing was corrupted — the errors were
  the whole symptom — but they were the last thing a packaged build printed.

- **The debug trace no longer writes unless you ask for it.** A build could
  leave a `ipc-trace.log` of 12 MB and growing in its application-support
  folder with Debug mode switched off. It is now written only while Debug mode
  is on, capped at 4 MB with one previous generation kept, and listed in
  Settings → Advanced → "Where things are kept" so it can be found and cleared.
  A file left by an earlier version is deleted the next time the app starts
  with tracing off.

- **The Windows test suite runs as a gate.** All 3,762 tests were ported to
  Windows and the release workflow no longer lets that job fail without
  stopping the build. The cases that cannot mean anything on Windows — POSIX
  file modes, the POSIX shell the hook command is written for, the macOS-only
  updater — are skipped individually, each saying why, rather than the suite
  being waved through as a whole.

- **`gh`, `git` and MCP servers find their binaries on Windows.** Six places
  built a child process environment in a way that left Windows holding two
  spellings of `PATH`, with no rule about which one the child would search.
  Affected the GitHub panel, the git status poller, the readiness checks, the
  Copilot detection and every stdio MCP server.

- **Turning remote access on is instant on Windows again, and says something
  useful when the tailnet cannot help.** It used to sit for fifteen seconds on
  every launch with the panel spinning, then report "Tailscale did not answer".
  Tailscale had answered, immediately: `serve` prints *"Serve is not enabled on
  your tailnet"* with a link to switch it on, and then waits forever for
  somebody to click it. The wait was being read as a hang and the sentence
  naming the fix was thrown away. The output is now read as it arrives, so the
  refusal comes back in under a second carrying Tailscale's own words and the
  link. Remote access was never actually blocked by this — the relay does not go
  through Tailscale — but nothing said so for fifteen seconds.

- **Starting a session from a phone no longer refuses a folder that is on the
  list the phone is showing.** Two spellings of one Windows folder — a
  lower-cased drive letter is enough — compared as different directories, and
  the refusal said "open it on the Mac first" about a folder already open.

- **Agent CLIs report their version on Windows.** They are `.cmd` shims there,
  which Node refuses to spawn without a shell, so every version column was
  blank. The shim path is quoted too, or the fix would still have failed for
  anyone whose Node lives under `C:\Program Files`.

- **No more console windows flashing over your screen.** Seven child processes —
  including the Tailscale status check that runs whenever the remote panel is
  open — were spawned without `windowsHide`.

- **Windows has Settings, Keyboard Shortcuts, About and Exit again.** All four
  lived only in the macOS application menu, which Windows drops wholesale, so
  the menu bar had no way to reach Settings and no way to quit, and `Ctrl+,` and
  `Ctrl+/` were unregistered along with them.

- **The diagnostics bundle's PATH is readable on Windows.** It was split on the
  POSIX separator, so every entry was torn apart at its drive letter — in the
  one file somebody attaches to an issue that says a CLI cannot be found.

- **A Windows user is no longer told about their Mac.** The sentences on the
  remote paths above said "this Mac", including ones sealed up and sent to a
  phone. Not yet every one of them; the rest now have one place to come from.

## [0.1.3] — 2026-08-14

### Added

- **Start a session from the phone.** Both phone clients have had a New Session
  button for a while, gated on a `create` capability that no desktop advertised
  — so it could never appear, and each client had invented its own frame shape
  against its own stand-in. There is now one shape, `{"t":"create"}` with an
  optional folder and size, parsed and narrowed in `protocol.ts` like every
  other frame; the desktop advertises `create` only when its session layer can
  actually start one; and a session started this way is a real PTY made by the
  same call the desktop's own button makes — same shell, same PATH, same
  profile. A phone may name a folder only if the Mac is already offering it.

- **A session started from a phone now appears on the desktop.** It arrives
  without focus and with an unread dot, so answering something on your phone
  never pulls the Mac out of the terminal you were typing into.

- **See your Mac's localhost on your phone.** Tap a port and the phone dials
  `127.0.0.1` on the Mac through the sealed channel. It is a raw TCP byte pipe
  rather than an HTTP proxy, so WebSockets, hot reload, service workers and
  cookies all survive untouched — save a file on the Mac and the page reloads
  on the phone. Only `127.0.0.1` is dialable, only ports something is listening
  on right now, and only after a person taps one.

### Changed

- **Every page has a designed empty state**, instead of a bare sentence floating
  in the middle of the window. One shape — the view's own glyph, a title, the
  explanation, and the single thing to do next — used by Source control, GitHub,
  Alerts, Hooks, the file viewer and every view that needs a project.
- **The update notice is an inset card**, not a full-bleed grey strip under the
  toolbar. It wears the same glass as the sidebar and the toolbar.
- **Pages and Settings hold a measure and centre it.** On a wide display the
  content used to sit in the top-left corner with an ocean of blank paper beside
  it; the gutter never falls below its old value, so nothing changes on a narrow
  window.
- Hooks no longer offers two buttons called Refresh.
- **The desktop speaks Apple's language.** One sidebar, one toolbar, Settings
  bottom-left, liquid glass, and both themes first-class. Three reachability
  allowlist entries came out and none went in — CloseSessionConfirm, DebugPanel
  and FileViewer were each a setting that turned nothing on.
- **Roughly 87,800 fewer wake-ups a day.** One shared renderer scheduler where
  N jobs cost one wake-up rather than N, nothing armed at all while the window
  is hidden, and a panel that polled a channel already pushing to it now
  subscribes instead. The remote panel alone was a 500 ms interval — 172,800
  wake-ups a day to move labels that mostly change once a minute.

### Fixed

- **Remote access had never worked, on any platform.** Electron links
  BoringSSL, which ships 28 ciphers and not one ChaCha, so
  `createCipheriv('chacha20-poly1305', …)` threw `Unknown cipher`, a silent
  catch swallowed it, and every relayed handshake closed with nothing on the
  wire and nothing in the log. 3628 tests passed throughout, because vitest
  runs under plain Node. The AEAD now comes from `@noble/ciphers` — the same
  code in every runtime, with no "native when available" fast path, because a
  fallback means the suite exercises one implementation and users run the
  other. `npm test` now runs the sealed channel under Electron's own Node and
  fails the build if that stops being true.
- **A paired device no longer has to be paired again after a restart.**
  Host-identity validated its stored keypair by running a handshake, so the bug
  above quarantined and regenerated a perfectly good identity on every launch,
  orphaning every device paired to it.
- **Both phone clients were one byte off the wire spec** (80/48 where the spec
  says 81/49), and both stand-in hosts shared the bug — so the fixtures agreed
  with each other and disagreed with reality. The stand-ins now import the real
  framing rather than reimplementing it.
- **Windows, launched for the first time in this project's history, then
  fixed.** `which` was spawned as a literal command, `spec.bin` was spawned
  where `spec.spawn` was meant (an npm-installed CLI answers a Windows PATH
  lookup with a `.cmd` shim, and `CreateProcess` will not run a batch file),
  and three `{ ...process.env, PATH }` sites lost against Windows' own `Path`
  key. 31 Windows test failures became 0.
- **Every macOS build shipped the whole repository.** electron-builder's
  per-platform `files:` list *replaces* the root allowlist rather than
  extending it, so `mac:` had no allowlist at all. Invisible until `ios/` and
  `android/` existed, at which point the app reached 1.0 GB. It is 287 MB now.
  The identical latent bug in the `win:` block is fixed in the same pass.
- `scripts/remote-host.sh` served an empty session list, because it was built on
  the belief that `PtyManager` needs Electron. It does not, so the harness now
  runs real terminals against the real endpoint.

## [0.1.2] — 2026-08-13

### Added

- A Windows build, produced natively in CI. It has not been run on Windows.

### Fixed

- Two tests read the machine they ran on instead of a fixture, so they passed
  here and failed on the CI runner.

## [0.1.1] — 2026-08-13

### Added

- Updates install from inside the app. It reads the release feed, verifies the
  archive's sha512, and swaps the bundle — none of which needs Squirrel, which
  refuses unsigned builds. The old app is moved aside, not deleted, and moved
  back if the new one fails to land.
- Remote access over your own tailnet: pair a phone by QR, approve it on the
  Mac, and attach to a running session from it. TLS is terminated by
  `tailscale serve`; the app's own listener is loopback-only.
- A start page for new browser tabs, listing the dev servers actually
  listening, instead of guessing `localhost:3000`.
- Windows packaging, built natively in CI. Not yet run on Windows.

### Fixed

- Sessions no longer inherit a parent agent run's environment, which disabled
  transcript saving and left chat mode and cost tracking blank.
- Four panels printed their own name under the dock's.

## [0.1.0] — 2026-08-12

First cut. macOS 12+, Apple silicon, unsigned.

### Added

- Multiple agent sessions per project, each in its own terminal, with tabs and
  scrollback that survives switching away
- Per-tab status — working / waiting / needs-input / exited — classified from a
  headless emulator's viewport rather than from the raw output stream
- Cost and context tracking read from Claude Code's own transcripts
- Session inspector (`⌘⇧I`): timeline, cost breakdown, tool usage, context meter
- Git panel, file tree and viewer, quick open, command palette
- Kanban board and a customisable dashboard per project
- GitHub panel backed by the `gh` CLI
- Embedded browser workspace with tab isolation and Chrome cookie import
- AI readiness score with one-click fixes
- MCP inspector and hook installation
- Preferences with live dark/light theming
- Session resume (`⌘⇧T`)

[Unreleased]: https://github.com/asadev/terminaldeck/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/asadev/terminaldeck/releases/tag/v0.4.0
[0.3.0]: https://github.com/asadev/terminaldeck/releases/tag/v0.3.0
[0.1.9]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.9
[0.1.8]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.8
[0.1.7]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.7
[0.1.6]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.6
[0.1.5]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.5
[0.1.4]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.4
[0.1.3]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.3
[0.1.0]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.0
