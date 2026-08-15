# Terminal Deck — Build Plan

A desktop workspace for AI coding agents, and — since the last three batches —
the same host without a window, plus the phones and other machines that reach
it. Every line written for this repo: about 102,000 lines of non-test
TypeScript across `src/`, `relay/` and `pwa/`, with 4,916 tests in 186 files at
the last commit, plus the Swift and Kotlin clients.

**Ground rule:** features and functional values (dimensions, colours, timings,
behaviour) are matched freely — they aren't copyrightable. Their components, CSS
and icon artwork are never copied, because that would pull their MIT licence and
copyright notice permanently into this repo.

Status key: `[x]` done · `[~]` in progress · `[ ]` not started

## What a tick means here

**`[x]` means a person can reach it in the running app.** Not "the code exists",
not "the tests pass", not "it is wired but nothing renders it".

That rule is written down because this file broke it. Five features were once
ticked as done with no way in — split panes, unread indicators, notifications on
completion, task-derived session titles and restore-on-launch. All five had real
code and real tests. Two agents then read this roadmap and copied it onto the
marketing site as fact. `src/reachable.test.ts` exists because of that, and it
now asks the question five mechanical ways: every module reachable from an entry
point, every setting read by something, every chord answered, every menu command
dispatched, every sidebar view rendering something.

**A second thing a tick does not mean: shipped.** Everything in phases 9 to 12,
and much of the shell work above them, is in `main` and in no tagged release.
[CHANGELOG.md](CHANGELOG.md) is the file that knows which is which.

---

## Phase 1 — Foundation `[x]`

Everything else sits on this.

- [x] Electron 41 + React 19 + TypeScript, electron-vite
- [x] `PtyManager` — process ownership, scrollback replay across tab switches
- [x] Provider layer — Claude / Codex / Gemini detection, login-shell PATH
- [x] One sidebar — projects → sessions, the project views, and Settings in
      the bottom-left corner — plus status dots and an empty state. (The icon
      rail, the panel drawer and the title-bar tab strip it replaced are gone.)
- [x] Design tokens on Apple's HIG — system type scale, 8pt spacing, macOS
      control metrics, dark + light both first-class
- [x] JSON store, atomic writes, projects + window bounds persist
- [x] CSP from main process — strict in prod, dev-permissive
- [x] Visual verification pass — screenshotted running, a live Claude session
      inside it, status dots and light/dark both confirmed by eye

## Phase 2 — Session intelligence `[x]`

Turns a terminal multiplexer into something that understands agents.

- [x] **Status detection** — classifies working / waiting / needs-input /
      exited from a headless emulator's viewport, in the main process so it
      works for unrendered tabs
- [x] **Provider picker** — per-session choice, per-project default, global default
- [x] **Session resume** — `claude --continue`, `codex resume --last`
- [x] **Preferences** — theme, default provider, notifications, restore-on-launch
- [x] **Live re-theming** — terminals recolour without restart. Ticked twice
      over: the setting worked, and every *already-open* terminal stayed in the
      old palette until `subscribeTheme` was finally called by something.
- [x] **Desktop notifications + sounds** on completion / input needed. The
      engine was constructed by nothing for months while five settings pointed
      at it; and once it was, macOS was still dropping every banner because its
      authorisation prompt had never been answered and
      `Notification.permission` in a renderer always says `granted`. The app
      now asks the OS whether a banner actually arrived.
- [x] **Session titles** derived from the task. `session-title.ts` could read a
      title out of output since the day it was written and was never handed any;
      `auto-title.ts` is the half that feeds it.
- [x] **Unread indicators** — output on a session nobody is looking at puts a
      dot on its sidebar row; the same dot is how a session started from a phone
      announces itself without stealing the focused tab
- [x] **Restore on launch** — the sessions come back *continued*, not blank. The
      switch had existed the whole time and reopened only projects.

## Phase 3 — Cost, context and telemetry `[x]`

Claude Code writes JSONL transcripts under `~/.claude/projects/`. That is the
data source for all of this — no scraping of terminal output.

- [x] **Transcript watcher** — tail the JSONL per session
- [x] **Cost tracking** — spend per session / project / day
- [x] **Token + context-window monitoring** with a bloat warning
- [x] **Session inspector** (⌘⇧I) — timeline, cost breakdown, tool-usage stats
- [x] **Deep session search** across past transcripts
- [x] **Smart alerts** — missing tools, context bloat, session health

## Phase 4 — Project workspace `[x]`

- [x] **Git status watcher** + git panel (branch, dirty files, diff view)
- [x] **File tree** + file viewer with syntax highlighting
- [x] **Quick open** (⌘P) and command palette (⌘K)
- [x] **GitHub integration** via `gh` — PRs, issues, discussions, unread badges
- [x] **AI Readiness score** — does the project have CLAUDE.md, tests, lint,
      typecheck, a clean git state — with one-click fixes
- [x] **Ignore file** (`.deckignore`) honoured by tree, search and watchers

## Phase 5 — Dashboard `[x]`

- [x] **Customisable project overview** — drag-and-drop widget grid (gridstack)
- [x] **Widgets** — AI Readiness, Sessions, Cost, Git, GitHub
- ~~**Kanban board**~~ and ~~**Board ↔ session link**~~ — **removed, code and
      all**, on 2026-08-15. Not wanted: a task board is a thing you keep up to
      date by hand, and nothing else in this app asks that of you. The page, its
      state module, its main-process store, its overview widget, its menu item
      and its ⌘⇧B all went together — a half-removed feature leaves rows that
      open nothing, which is worse than the feature was.

## Phase 6 — Multi-session power features `[x]`

- [x] **Swarm mode** — grid view of every running session (⌘\)
- [x] **Split panes** with focus routing. `SplitView.tsx` and `pane-tree.ts`
      were complete, tested and rendered nowhere for their whole life, and came
      within a commit of being deleted. What was missing was never code: it was
      the answer to "which session does the sidebar name", and the answer is one
      sentence — **the sidebar names the session in the focused pane**, which is
      exactly what it has always done with a single pane. `renderer/layout/panes.ts`
      is where that rule lives. Split (⌘D) is arranged by hand; swarm (⌘\) is
      derived from the session list; they are mutually exclusive because they
      are two answers to the same question.
- [x] **Multiple Claude profiles** — isolated `CLAUDE_CONFIG_DIR` per profile so
      work and personal logins never mix; per-session / per-project / global
      default. Session restore was blind to these until recently and came back
      blank on top of an intact transcript.
- [x] **Full keymap** + shortcut reference sheet

## Phase 7 — Integrations `[x]`

- [x] **Hooks** installed into each provider's settings, namespaced
      `terminaldeck-hook` so they never collide with another tool's on the same
      machine
- [x] **MCP client** + inspector, add/edit servers
- [x] **Embedded browser tab** — load a URL, inspect elements, send the selector
      and text back to the agent as context
- [x] **Chrome import** — pull existing config
- [ ] **Embedded iOS simulator pane.** Investigated and **not built**, which is
      the honest outcome rather than a deferral: capture works at 57fps even
      when the Simulator is occluded, but `simctl` has no input command, the
      guest accessibility tree is not exposed, and `CGEventPostToPid` does not
      reach Simulator. Being embedded requires the window to be occluded;
      accepting touch requires it to be frontmost. A phone screen you cannot tap
      is a dead control, so nothing was shipped.

## Phase 8 — Ship `[~]`

- [x] **Auto-updater** pointed at our own releases, including the Windows half:
      an assisted NSIS installer needs `/S` or it opens a setup window nobody
      asked for and sits there, and a *portable* build must refuse to update at
      all rather than installing a second copy somewhere the user did not choose
- [x] **Packaging** — `.dmg` and `.zip` with blockmaps and an update manifest on
      macOS, an installer and a portable build on Windows, both in CI
- [x] **Icon and brand assets**, original — and the app's accent is now sampled
      from that icon rather than invented
- [ ] **Code signing and notarisation.** The chain works end to end —
      `dev.terminaldeck.app`, hardened runtime, `codesign --verify --strict`
      passing — and the certificate is missing. Developer ID cannot be issued
      over the API (403, "can only be performed by the Account Holder"), so it
      needs one interactive sign-in. Two scripts are waiting for it; see
      [SIGNING-HANDOFF.md](SIGNING-HANDOFF.md). **Every build shipped so far is
      unsigned.**
- [ ] **i18n** + locale files. Settings has a language row with exactly one
      option and help text saying no other language has been translated, which
      is the honest version of not having this yet.
- ~~**P2P session sharing** — WebRTC, PIN auth~~ — superseded rather than
      dropped. Phases 9 to 11 are what got built instead, and the shape is
      different enough that leaving the old line ticked or unticked would both
      mislead: no WebRTC, no PIN, a relay that carries ciphertext it holds no
      key for, and a device that is paired *and* approved by a human.

## Phase 9 — Remote access `[~]`

The differentiator, and never a feature-store entry.

- [x] **Sealed channel** — Noise IK over WebSocket, one implementation
      (`@noble/ciphers`) shared by every end, with an Electron-runtime probe in
      the test command because Electron's BoringSSL ships no ChaCha and a
      "native when available" path would mean tests exercising code users do not
      run
- [x] **Relay** — `relay.terminaldeck.dev`, no Tailscale required, no key held
- [x] **Pair a phone, then approve it on the desktop.** Two steps, and the
      second is a person. This is the security boundary the rest sits on.
- [x] **iOS client** — sessions, terminal, pairing, localhost browser, uploads,
      clipboard, and the rebuilt key bar and gestures. On TestFlight; not on the
      App Store.
- [x] **Android client** — sessions, terminal, pairing, uploads; proved against
      the live relay and a real desktop. Built from `android/`; not on Play.
- [x] **Browser client** (`pwa/`), served by the desktop and bundled into the
      app. It was absent from three shipped releases because `pwa/dist` is
      gitignored and the packaging allowlist matched zero files, which looks
      exactly like a line whose files were excluded on purpose; the release
      check fails now if the built page is not in the bundle.
- [x] **Localhost tunnel** — the dev servers listening here, listed on the
      phone, opened at the same port number over a byte pipe rather than an HTTP
      proxy, so hot reload, cookies, SSE and the WebSocket upgrade all work.
      Host and iOS; the Android client names the capability as "not implemented
      here yet" and the browser client has no place to put it.
- [x] **Uploads** — send a photo, a video or a file from the phone into a
      session. iOS and Android both.
- [x] **Clipboard both ways on iOS** — paste into the terminal, copy the
      selection or the screen out. A browser tab cannot do the second half
      without a gesture it does not get, so this is a native-client feature.
- [x] **Start a session from the phone**, in a granted folder
- [x] **Per-device folder grants** — the host decides which folders each device
      may **start a session in**, pushed to the device when it changes. Read
      that as written: it is where a session *starts*, not a confinement. A
      shell can `cd` out of a granted folder, and no wording in the app may
      suggest otherwise.
- [~] **Credential proxy** — a guest session gets its own git configuration so
      it cannot reach the host's GitHub (done, and shipped on its own), and a
      credential request crosses the sealed channel to be answered on the
      device that asked for the session. **The host and the iOS client do this;
      Android and the browser client do not answer yet** and therefore never
      advertise the capability, so a host never asks them.
- [ ] **Wake a sleeping machine.** Not possible over the relay and must not be
      implied — it needs something external (Wake-on-LAN, the platform's own
      scheduler).

## Phase 10 — Machine to machine `[~]`

- [x] **Pair with an eight-character code** — Crockford base32 without `I`, `L`,
      `O` and `U`: exactly 32 symbols, so eight characters are exactly 40 bits
      with no modulo bias
- [x] **Rendezvous through a relay slot** — a typed code cannot carry an
      address, so it names a slot; the responder's static key pair is derived
      from the code, which is what stops a hostile relay answering in its place.
      No relay change and no new primitive.
- [x] **Rate-limit a wrong code.** A miss used to be refused before it reached
      the limiter, which was harmless at 256 bits of token and not at 40. A code
      now burns after five misses.
- [x] **Machines panel** — both halves of pairing on one screen, in the order
      somebody does them, with five link states because collapsing them tells
      somebody "cannot connect" when the truth is "waiting to be approved"
- [x] **Drive the other machine's sessions** from here
- [ ] **Proved between two operating systems.** It has been run end to end
      against a real relay, trust store and pairing desk with **both ends in one
      macOS process on loopback**. A Mac talking to a Windows PC across the
      internet is the same code and has not been run. Until it has, this line
      stays unticked.

## Phase 11 — The host with no window `[~]`

- [x] **Core / shell split** — sessions, remote server, crypto and grants on one
      side, Electron window and renderer on the other. Not a fork: a second
      implementation means every fix lands twice and one of them rots.
- [x] **Plain-Node daemon**, no Electron in the process
- [x] **Four-command CLI** — `pair`, `status`, `folders`, `stop`, and
      deliberately no fifth
- [x] **Idle mode** — with nothing attached it holds only the relay connection
      and wakes on first attach, driven by the attach and detach events that
      already exist rather than by a timer. The ping/pong stays: a NAT drops an
      idle connection in silence without it. `status` says which mode it is in,
      because an idle mode nobody can observe is indistinguishable from a bug.
- [x] **WSL sessions routed by folder** — a Linux path launches through
      `wsl.exe` in the distribution, a Windows path through `cmd.exe`. No "use
      WSL" switch, because a switch is what lets the shell and the files end up
      on opposite sides of the boundary.
- [ ] **Installed in WSL**, which is the machine this was written for. Run end
      to end on macOS against the live relay with a real pty; not yet on the
      target.
- [ ] **Published** — `npm run dist:headless` produces the package; the name on
      npm today is a placeholder reservation, not this program, and
      `install.sh` points at a package that is not there yet.
- [ ] **Survives its host going away** — systemd inside WSL, the distro started
      at login, and `status` saying which of those is true before somebody
      relies on it from another country.

## Phase 12 — Features, not plugins `[x]`

- [x] **One registry** declaring every feature: name, default, the panels,
      commands, settings sections and widgets it gates, and the data it owns.
      Surface ids are typed against the real panel, section and widget ids, so
      renaming one without renaming it here fails the build.
- [x] **Entries for** the browser pane, split view, every-session-at-once, cost
      and usage, alerts, GitHub, MCP servers, hooks, AI readiness and voice
      dictation — with the registry, not this file, as the list
- [x] **Install / disable / uninstall**, with off and uninstalled kept
      distinct: off keeps your data, uninstalled clears what the feature
      declares it owns
- [x] **Offer where the feature would have been** — the empty split view says
      split view is available and the button installs it and splits. A store's
      own failure mode is undiscoverability; the dead end is the bug, not the
      absence.
- [x] **Everything-on and everything-off both in the guard tests.** Every
      combination cannot be tested, so feature independence is what makes the
      two extremes sufficient.
- [x] **Remote access is not in it** and a test asserts no entry ever claims one
      of its surfaces

---

## Sequencing logic

Phase 2 before 3 because status detection is what the inspector visualises.
Phase 3 before 5 because the dashboard widgets display cost and readiness data.
Phase 9 before 10 and 11, because a phone and another desktop are the same
protocol with a different client, and the headless host is the same core with a
different shell — doing either first would have meant building the seam twice.

## Open questions for Asad

- Final name (currently `Terminal Deck`, isolated in `src/shared/brand.ts`)
- The Developer ID sign-in, which is the only thing between here and a signed,
  notarised build
- Whether the headless host should be published to npm under the reserved name
  now, or wait until it has been installed somewhere that is not a Mac

## Tracked follow-ups

- **Android and the browser client do not answer a credential request.** The
  host asks only clients that advertise the capability, so nothing is broken
  today — it is a feature that exists on one phone platform.
- **Chunked JSONL reader is duplicated three times** — `transcript.ts`,
  `session-insights.ts` and `session-search.ts` each carry their own 4MB +
  StringDecoder read loop. Should be lifted into one `streamLines` helper. Not
  urgent: all three are tested and working, and refactoring them carries
  regression risk for no user-facing gain.
- **Escape-to-close on modals is unconfirmed** — the code is correct, but
  synthetic keypresses were not delivered during testing, so it needs a real
  human keypress to verify.
- **The iOS UI tests compile and have never been executed against a live host.**
  They are written to pair themselves against the harness in `ios/Harness`; the
  key-bar suite in particular has to run on a 375-point screen, because on a
  430-point one the bar it replaces looked nearly fine, which is how it shipped.
