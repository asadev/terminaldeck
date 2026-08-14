# Changelog

Notable changes to Terminal Deck. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add to **Unreleased** as you go — `npm version <patch|minor|major>` moves that
section under the new version, stamps it with the date and creates the tag.
A release with nothing under Unreleased is refused rather than shipped blank.

## [Unreleased]

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

[Unreleased]: https://github.com/asadev/terminaldeck/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.4
[0.1.3]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.3
[0.1.0]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.0
