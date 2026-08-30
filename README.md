# Terminal Deck

A desktop workspace for AI coding agents. Run Claude Code, Codex CLI and Gemini
CLI sessions side by side in one window, see which ones are working and which
are waiting on you, and reach any of them from your phone.

Free and MIT-licensed. No account, no telemetry, no analytics. macOS and Windows
get a window; Linux runs the same core as a headless host with no Electron in it.

**[terminaldeck.dev](https://terminaldeck.dev)** ·
[Download](https://terminaldeck.dev/download.html) ·
[Docs](https://terminaldeck.dev/docs) ·
[Store](https://terminaldeck.dev/store/) ·
[Help](https://terminaldeck.dev/faq)

[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
![Platform: macOS, Windows, Linux headless](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux%20(headless)-lightgrey.svg)
![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)

## How it works, in the parts that are not obvious

Most of this is not visible from a feature list, so it is written out plainly.
Every claim here is a thing in this repository, and the file is named.

- **The status dot is read off the screen, not off the process.** Each session's
  output is fed to a headless terminal emulator in the main process, and what
  that emulator has drawn is classified into working, waiting, needs-input or
  exited. It is therefore accurate for tabs you are not looking at, and it
  survives a CLI repainting its own interface — which a process-state check
  cannot do, because a CLI waiting on you and a CLI thinking look identical from
  outside.

- **Usage is read out of Claude Code's own JSONL transcripts** — tokens, cache
  hit rate, and how much of the context window is left — rather than being
  counted here or asked for over an API.

- **It shows no prices, deliberately.** A per-token figure misleads somebody on
  a subscription, and a subscription figure cannot be computed from anything any
  provider publishes. A pricing display was built and then removed; there is no
  dollar figure anywhere in the app.

- **The copilot is a real session, not a special case.** The assistant that
  works the app itself runs in the same sandbox as any other session, addressed
  the same way, with routines that fire on an event — a session finishing, git
  state changing, a file changing — rather than on a clock.

- **Your phone reaches your desktop with nothing to set up.** No port
  forwarding, no VPN, nothing on anybody's network. Both ends dial out to a
  rendezvous server that staples the two sockets together and carries a Noise IK
  channel it holds no key for. It keeps no accounts and no database, and maps a
  host name to a socket in memory only.

- **The embedded browser can be driven by an agent, and hands the page back the
  instant a human touches it.** Clicking an element sends the agent a CSS
  selector rather than your description of what you clicked.

- **Nothing here handles your API keys or logins.** It launches the CLI you
  already have and inherits whatever authentication that CLI already uses.

- **A Kanban board was built and then deleted, code and all** — a board is a
  thing you keep up to date by hand, and nothing else in this app asks that.
  The QR code and the pairing link went the same way; pairing is six digits
  shown on the desktop and approved there.

## Why

Running agents in bare terminal tabs falls apart quickly. You lose track of which
session is mid-thought and which has been sitting on a question for ten minutes,
you have no idea what you have spent, and there is nothing between an agent and
your files when it decides to do something drastic.

## Status

**Alpha**, and specific about what that means. Version 0.15.0 is published for
both desktop platforms.

- **macOS**, Apple silicon only. Signed with an Apple Developer ID certificate
  and **not notarised**, so the first launch needs one trip through System
  Settings — see [Install](#install). There is no Intel build: macOS 27 does not
  run on Intel Macs at all.
- **Windows**, x64 only, as an installer and a portable `.exe`, **not signed**,
  so the first launch warns once. It is packaged natively in CI and has been run
  on a real Windows 11 machine — it installs, launches, opens projects, starts
  sessions both agent and plain shell, and remote access works there. The whole
  test suite runs on a Windows runner in CI and gates the installer. In-place
  updating works, and the localhost tunnel works against `::1`, which is where
  most dev servers on Windows actually bind. Windows on ARM runs the x64 build
  under emulation.
- **Linux** has no window. It has the headless host — plain Node, no Electron,
  no GPU — which is what makes a Linux server or a WSL distribution a machine
  your phone or your desktop can open a session on. One line installs it:
  `curl -fsSL https://terminaldeck.dev/install.sh | sh`. It has been left
  running in WSL under a user service holding real agent sessions.

**Not built yet:** notarisation on macOS and a Windows signing certificate;
translations; voice dictation, so the microphone is off by default and the app
hands over to the operating system's own dictation; an App Store release of the
iPhone client, which is on TestFlight, internal testing only; and a Play listing
for the Android client, whose signed APK ships with every release but cannot
update itself without one.

Machine-to-machine pairing has been run end to end with both ends in one macOS
process on loopback. A Mac has never talked to a Windows PC.

[CHANGELOG.md](CHANGELOG.md) is grouped by what changed rather than by commit
order, and its **Unreleased** section is the honest answer to whether a tag
contains the thing you just read about.

## Requirements

- **macOS 12 or later, on Apple silicon.** A release carries one artifact,
  `-arm64`. There is no Intel build and no universal binary: macOS 27 does not
  run on Intel Macs at all, so an Intel slice would serve only 2019-2020
  hardware frozen at macOS 26 — and it could not be tested on any machine here
- **Node 22 or newer** (CI runs 22 and 24)
- **At least one agent CLI**, installed and already authenticated:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Codex CLI or
  Gemini CLI
- Optional: [`gh`](https://cli.github.com) for the GitHub view

A Windows build exists — `npm run dist:win`, and CI packages one per release —
and is held to the same requirements minus the mac-only ones. It is not
exercised daily; treat it as thinner ice than the mac build.

The **headless host** has different requirements, because it is a different
program: Node 22 or newer and nothing else. No Electron, no window, no GPU. See
[HEADLESS.md](HEADLESS.md).

Terminal Deck never handles your API keys or logins. It launches the CLI you
already have and inherits whatever authentication that CLI uses.

## Install

Download the `.dmg` from [Releases](https://github.com/asadev/terminaldeck/releases),
open it, and drag the app to Applications.

The build is signed with a Developer ID certificate but **not notarised**, so
macOS refuses the first launch. Open the app, click *Done*, then go to **System
Settings → Privacy & Security** and click **Open Anyway**. Once, per install.

Right-click → *Open* is not a way past this — macOS 15 removed that bypass.

Windows releases carry two files, `…-x64-setup.exe` and `…-x64-portable.exe`.
The installed one updates itself; the portable one says plainly that it cannot,
rather than installing a second copy somewhere you did not choose.

## Build from source

```bash
git clone https://github.com/asadev/terminaldeck.git
cd terminaldeck
npm install
npm run dev
```

`npm install` compiles two native modules (`node-pty` and `better-sqlite3`)
against Electron's ABI, so the first install takes a while.

To produce an installable app rather than run from source:

```bash
npm run dist:mac         # build + package a .dmg and .zip into release/
npm run pack:mac         # just the .app, no installer — faster for testing
```

`npm run dist:mac` produces four files in `release/`: a `.dmg` and a `.zip`,
each with a `.blockmap`. Named from the slug, so no download URL contains an
escaped space:

```
terminaldeck-0.15.0-arm64.dmg   114 MiB
terminaldeck-0.15.0-arm64.zip   114 MiB
```

…plus `latest-mac.yml`, the update manifest. `npm run release:check` verifies
the two agree before an upload.

[BUILDING.md](BUILDING.md) covers all of it: outputs, the icon, what signing
and notarisation would take, and what they cost.

Other commands:

```bash
npm test              # vitest, plus the Electron-runtime crypto probe
npm run typecheck     # the main/preload project and the renderer project
npm run build:pwa     # the browser client
npm run dist:headless # the host with no window, as an npm package
```

The phone client has two tsconfigs of its own and is not covered by
`npm run typecheck` — check it with `npm --prefix pwa run typecheck`.

> **Never run `npm run build` while `npm run dev` is serving.** They share
> `out/`, and the build clobbers what dev is running.

## What it does

Everything listed here is built and reachable from the running app. Some of it
you switch on first — see [Choosing what the app is](#choosing-what-the-app-is)
— and some of it is in `main` and not in a release yet, which
[Status](#status) says plainly. For what is planned, see [ROADMAP.md](ROADMAP.md).

### Sessions

- Multiple sessions per project, each its own terminal, with scrollback that
  survives switching tabs
- **Status at a glance** — working / waiting / needs-input / exited, classified
  from what is actually rendered on the session's screen
- Per-session provider choice, with per-project and global defaults
- **Session resume** — continue the project's last conversation
- **Reopened continued, not blank** — with restore-on-launch on, the sessions
  you had open come back *and* pick their conversation up. One rule comes from
  the CLI rather than from us: `claude --continue` picks the most recently
  written conversation in a folder, so where two tabs share one conversation
  store the most recent continues and its siblings start clean, rather than both
  attaching to the same transcript
- **WSL sessions on Windows, routed by the folder** — a Linux path runs inside
  the distribution, a Windows path runs on Windows, so the shell and the files
  are never on opposite sides of the boundary. There is no "use WSL" switch,
  because a switch is what lets those two disagree; the one choice is which
  distribution, in Settings → Linux
- Titles derived from the task rather than the folder name
- Unread markers when output arrives on a background tab
- Desktop notifications and sounds when a session finishes or needs you

### Cost and context

Read from Claude Code's own JSONL transcripts, not scraped from terminal output.

- Spend per session, per project and per day
- Token and context-window tracking, with a warning before context bloat
- **Session inspector** — timeline, cost breakdown, tool usage, context meter
- Deep search across past transcripts
- Smart alerts for missing tools, context bloat and session health

### Project workspace

- Source control — branch, dirty files, diffs
- File tree and viewer, quick open, command palette
- GitHub — PRs and issues through the `gh` CLI
- **AI readiness score** — whether a project has CLAUDE.md, tests, lint,
  typecheck and a clean git state, with one-click fixes
- `.deckignore`, honoured by the tree, search and watchers

### Layout

- Customisable per-project dashboard, drag-and-drop widget grid
- **Split view** — sessions side by side, arranged by hand, with the divider
  draggable and the sidebar filling whichever pane has focus
- **Swarm view** — every running session in one grid, arranged for you
- Multiple agent profiles with isolated config directories, so work and personal
  logins never mix
- Live dark/light theming; terminals recolour without a restart

### Integrations

- **Embedded browser** — tabs, device emulation, per-tab isolation; inspect an
  element and send its selector and text back to the agent as context
- **MCP client and inspector** — add, edit and call servers
- **Hooks** installed into each provider's settings, namespaced so they never
  collide with another tool's hooks on the same machine
- Chrome cookie import
- Live dev-server port discovery

### Choosing what the app is

Settings → **Features**. Several of the things above can be switched off and
back on: the browser pane, split view, every-session-at-once, cost and usage,
alerts, GitHub, MCP servers, hooks, AI readiness and voice dictation.
`src/renderer/features/registry.ts` is the list, and it is the only list.

They are called Features and not Plugins because that is what they are.
Everything ships inside the app, always. Installing turns one on; uninstalling
turns it off and clears the data that feature declares it owns. Nothing is
downloaded, nothing is compiled, no third-party code ever runs — which is why
reinstalling is instant, and why this is safe rather than an extension API with
better marketing.

Off means gone: no dead menu items, no settings section for something
uninstalled, no empty panel. Where a feature would have been, the app offers it
instead — the empty split view says split view is available and the button
installs it and splits. A store's characteristic failure is making things
undiscoverable, and a dead end would be the bug, not the absence.

**Remote access is not in the store and never will be.** The tunnel, pairing,
device grants, the clipboard, file transfer and the Machines panel are the
product rather than an option; a test asserts that no store entry ever claims
one of their surfaces.

### From your phone, and from your other machines

A paired device can list this machine's sessions, attach to one, type into it,
start a new one in a folder you granted, and open a dev server running here. The
desktop app, the iOS app, the Android app and the browser client all speak the
same sealed protocol; a relay in the middle carries ciphertext it holds no key
for.

**Pairing is two steps and the second one is a person.** A device pairs, and
then somebody at this machine approves it. Nothing moves before both have
happened — that is the security boundary, and everything below sits on top of
it rather than beside it.

#### Folders a device may use

The machine that owns the files decides which folders each device may **start a
session in**, per device, in Settings → Remote. Every client reads that list off
the wire rather than inferring one from whatever sessions it can see, and
editing it on the desktop pushes the change to the device immediately.

**On macOS the list is also a boundary.** A session started from a device is
held inside the folder it was given: it can read and write that folder and
nothing else — not your other projects, not your home directory, not your ssh
keys, not the keychain your agent CLI keeps its login in. It still runs node,
git and the agent CLIs, and it still reaches the network; it gets a home
directory of its own, so it starts signed out of those tools until that device
signs in. If the boundary cannot be put in place, the session does not start —
there is no silent fall-through to an unconfined shell.

That is Seatbelt, through `sandbox-exec`, and every claim in the paragraph above
was measured on macOS 27 rather than read off a manual page.
`src/main/confine/seatbelt.ts` lists the escapes that were attempted — `cd ..`,
an absolute path elsewhere, a symlink out, a hard link in, another device's
granted folder, `sudo`, a nested `sandbox-exec`, `osascript`, `open`,
`launchctl`, the login keychain — and what each one did. Two things still get
out and are stated rather than hidden: a session can `stat` a path it already
knows (so it can learn a file exists, but cannot list a directory or read a
byte), and the network is open, so whatever it *can* read it can also send.

**On Windows and Linux it is not a boundary.** The list decides **where a
session starts** and nothing more: a shell that starts in a granted folder can
`cd` anywhere your user account can reach, read what that account can read, and
push wherever its keys open. AppContainer, restricted tokens, job objects, user
namespaces and bubblewrap are all plausible mechanisms and none of them has been
built or measured here, and an unmeasured boundary claimed on screen is worse
than an honest gap. The grant screen says which of the two you are getting, in
its own sentence, on the machine you are reading it on.

On every platform the thing that decides whether a device gets a shell at all is
the approval, not the list.

A device that has no list falls back to the old behaviour rather than being
locked out. An empty list is a different fact and is honoured: that is somebody
having removed every folder, which means nowhere.

#### Another machine, with an eight-character code

One desktop can be a guest of another: the **Machines** panel shows a code on
the machine you want to reach, you type it on the machine you are sitting at,
and its sessions open here.

The code is Crockford base32 without `I`, `L`, `O` and `U` — exactly 32 symbols,
so eight characters are exactly 40 bits with no modulo bias and no pair that can
be misread across a desk. A typed code cannot carry an address, so it names a
slot at the relay for the sixty seconds it lives; the machine showing it sits in
that slot and answers with its real URL, host id and public key. The relay
cannot substitute itself, because the responder's key pair is derived from the
code too — the offer channel is ordinary Noise IK whose identity only a
code-holder can produce.

Both halves of pairing live on one screen, in the order somebody does them,
because the code is on screen for a minute and explaining which page to open on
which machine would spend most of it.

#### Their GitHub, not yours

Two things have to be true when somebody works in a folder on your machine, and
neither is true of a plain shell: they never get your GitHub, and you never hold
theirs.

A session started from another device is handed **its own git configuration**
rather than this machine's, so `git push` cannot reach your account through the
credential helper, the rest of your global config, `gh`, or an ssh key. That
half needs nothing on the other end and is worth having on its own.

The other half is the proxy: when git here needs a login, the request crosses
the sealed channel to the device that started the session, is answered there,
and is used once, in memory. Nothing is written to this machine's disk, so
revoking is disconnecting. Fetches and clones are silent; a push asks once per
repository — it is asked through a git *credential helper* rather than
`GIT_ASKPASS` precisely so the prompt can name the repository, since "approve a
push to github.com" is consent to push anywhere the account can reach.

**Today the host and the iOS app do this.** The Android and browser clients do
not answer a credential request yet; they never advertise the capability, so a
host never asks them and nothing on either offers to connect a GitHub account.

And the thing this does not do, said plainly: they are still running commands on
your computer, and the code is still pushed *from* your computer. On macOS those
commands are held inside the granted folder — see **Folders a device may use**
above for exactly how far that goes and what still gets out. On Windows and
Linux they are not held anywhere, and no wording in the app may suggest
otherwise on those platforms.

#### Your localhost, on your phone

The **iOS** app does this today. The Android client names the capability in its
protocol as not implemented yet, and the browser client has nowhere to put it.

The phone lists the dev servers running on this machine — no typing a port, no
typing a URL — and tapping one opens it in a browser view on the phone, at the
**same port number**, over the connection that is already there. No public URL
and no third-party tunnel service is involved.

It is a byte pipe rather than a page fetcher, which is what makes it useful: the
page's own `fetch` calls, its cookies and its **hot-reload WebSocket** all work,
so a file saved here reloads what is on the phone. Matching the port matters for
the same reason — a dev server writes absolute URLs into its own redirects and
sockets, and any of them would escape a tunnel served on a different number.

On Windows it dials the loopback the port is actually on: `localhost` resolves
to `::1` there before `127.0.0.1`, so `vite`, `next dev` and
`node --host localhost` bind IPv6 and nothing else, and a tunnel that only ever
dialled `127.0.0.1` listed the port and then refused it with a blank page.

What it will and will not reach:

- Only the paired machine, and only its loopback. There is no field for a host
  anywhere in the protocol, so a phone cannot reach another computer on that
  machine's network or its tailnet.
- Only ports a fresh scan says are being listened on right now, so this cannot
  be used to sweep a loopback for services that are not there.
- Only after the device has paired and a human at that machine has approved it —
  the same gate that guards attaching to a terminal.
- Only after a tap. The tap **is** the consent: nothing is reachable before it,
  closing the view ends it, and while it is live it is listed on both ends and
  can be stopped from either.

It rides the same sealed channel as everything else — no separate listener, no
second thing to secure.

#### A machine with no window

The same host, without Electron: sessions, the remote server, the crypto and the
grants are the core, and the headless build gives that core a different shell
rather than being a second implementation of it. It is what makes a Linux
server, or a WSL distribution, a machine your phone and your desktop can open a
session on.

Its whole user interface is the terminal it was installed from:

```sh
terminaldeck pair      # prints a code, waits, confirms
terminaldeck status    # running? paired to what? sessions? relay reachable?
terminaldeck folders   # list / add / remove the folders a device may use
terminaldeck stop
```

Four commands, deliberately, and no configuration file to lose. With nothing
attached it holds exactly one thing open — the relay connection — and wakes on
the first attach; that is a reaction to the attach and detach events that
already exist rather than a timer, and `status` will tell you which mode it is
in, because an idle mode nobody can observe is indistinguishable from a bug.

Building it: `npm run dist:headless` produces an npm package in `out/headless`
with two bins (`terminaldeck`, `terminaldeck-host`) and a dependency list read
out of the emitted bundle rather than maintained by hand. **It is not published
yet** — the name on npm today is a placeholder reservation, not this program —
so installing it means building it here. [HEADLESS.md](HEADLESS.md) covers WSL,
systemd and what `status` has to admit about a distribution that stops when its
last terminal closes.

#### Keeping this machine reachable

Settings → **Power**: keep this machine awake with the lid closed. It reports
the system's answer rather than its own intention, which matters more here than
it sounds. Electron's `powerSaveBlocker` blocks *idle* sleep, and closing the
lid is a different path entirely — an app that holds a blocker and promises
lid-closed operation is the exact failure this codebase keeps writing modules to
avoid. So the switch reads and writes macOS's own system setting, and every read
goes to the OS rather than to a stored boolean that something else could have
changed. The power button still locks the machine; that is a different key and
nothing here touches it.

#### What is not proven

- **A Mac has never talked to a Windows PC.** Machine-to-machine pairing runs
  end to end against a real relay, a real trust store and a real pairing desk —
  with both ends in one macOS process on loopback, which is where every seam
  that has broken before lives. Across the internet, between two operating
  systems, it is the same code and it has not been run.
- **The iOS UI tests compile and have not been executed against a live host.**
  They are written to run against the harness in `ios/Harness`, on a 375-point
  screen, and until somebody runs them they prove nothing about the app on a
  phone.
- **The headless host has not been installed in WSL**, which is the machine it
  was written for. It has been run end to end on macOS against the live relay,
  with a real pty and no Electron in the process.

### When something breaks

Turn on **Settings → Advanced → Debug mode** to get a Debug panel with a live
IPC trace, the session process table, the app log, and a **support bundle**.

The bundle is what to attach to a bug report. It carries versions, detected
CLIs, which IPC modules registered, config paths and the recent log. Tokens, API
keys, authorization headers and your home directory are stripped in the main
process before it is handed to the UI — IPC *arguments* are never recorded at
all. Read it before you paste it anyway.

## Keyboard shortcuts

Generated from [`src/renderer/keymap.ts`](src/renderer/keymap.ts), which is the
single source of truth — the app matches keystrokes against that table and the
in-app sheet (`⌘/`) renders the same rows. If this list and that file disagree,
the file is right.

`⌘` is the primary modifier on macOS; elsewhere the same bindings use `Ctrl`.

### Anywhere

| Action | Keys |
|---|---|
| New session | `⌘T` |
| New session, with options | `⌘⇧T` |
| Resume the last session here | `⌘⇧R` |
| Close session | `⌘W` |
| Jump to an open session | `⌘1`–`9` |
| Next session | `⌃⇥` |
| Previous session | `⌃⇧⇥` |
| Open a project | `⌘O` |
| Quick open a file | `⌘P` or `⌘⇧O` |
| Command palette | `⌘K` or `⌘⇧P` |
| Project dashboard | `⌘⇧D` |
| Files | `⌘⇧E` |
| Search past sessions | `⌘⇧F` |
| Source control | `⌘⇧G` |
| Session inspector | `⌘⇧I` |
| Split the window | `⌘D` |
| Focus the pane left / right | `⌘⌥←` / `⌘⌥→` |
| Swarm view | `⌘\` |
| Toggle the sidebar | `⌘B` |
| Settings | `⌘,` |
| Keyboard shortcuts | `⌘/` |

### In a session

Claimed while a terminal has focus. Everything else reaches the agent.

| Action | Keys |
|---|---|
| Find in the terminal | `⌘F` |
| Clear the terminal | `⌘⇧K` |
| Copy the selection | `⌘⇧C` |
| Interrupt the agent | `⌃C` *(passes through)* |
| Stop what the agent is doing | `Esc` *(passes through)* |

### In a dialog

| Action | Keys |
|---|---|
| Close | `Esc` |
| Confirm | `⌘↩` |
| Next item | `↓` |
| Previous item | `↑` |

## How it is put together

```
src/
  main/       the host — owns every terminal process, and the git / fs /
              search / cost / github / readiness / mcp IPC modules
    remote/   the sealed channel: protocol, device auth, folder grants,
              tunnel, uploads, credentials, and machines/ for desktop-to-desktop
  headless/   the second shell around that same host: a daemon and a CLI,
              with no Electron anywhere in it
  preload/    the only bridge between renderer and main
  renderer/   React UI — components, dashboard, browser, layout, features
  shared/     types, branding, the sealed-channel crypto and the short code
pwa/          the browser client, compiled with "types": []
ios/          the iOS app (SwiftUI)
android/      the Android app (Compose)
relay/        the rendezvous server; it carries ciphertext and holds no key
```

Each main-process feature exports one `registerXIpc(ipcMain)` and is wired in
`src/main/index.ts`. Feature types stay in their own module and cross the bridge
as `unknown`; duplicating them into `shared/types.ts` only lets the two sides
drift apart.

Four decisions worth knowing before you change anything:

**Session status is read from a headless terminal, not the output stream.**
Agent CLIs are full-screen applications that repaint by moving the cursor, so
the tail of the byte stream bears no relation to the bottom of the screen. Each
session feeds a background emulator, and status is classified from its viewport.

**Sessions run with the login shell's PATH.** A GUI app on macOS inherits a
minimal PATH and genuinely cannot see `claude`. The real PATH is resolved once
by asking the login shell.

**The wire has one vocabulary and one parser.** `src/main/remote/protocol.ts`
holds every frame type, every limit, and both directions of parsing — what
arrives at a host, and what arrives at a client. The browser client imports it
rather than restating it, which is why that file may use **no node built-in and
no DOM API**: no `Buffer`, no `TextEncoder`, no `window`. The phone project
compiles with `"types": []`, so one `Buffer` reference stops its build with
`TS2591`, and tree-shaking does not save it — the bundler drops unused code, the
compiler still checks it. Two decoders for one wire is how the two ends drift
while both keep compiling; there is one.

**The product name lives in one file for application code** —
`src/shared/brand.ts`. Every module that shows the name imports `BRAND`; none
of them types it out. Three places outside it hold the literal because nothing
there can import TypeScript: `package.json` (`productName`),
`electron-builder.yml` (bundle name and the macOS folder-access prompts) and
`src/renderer/index.html` (the window title, which is on screen before React
mounts). Two CSS file headers mention it in a comment. Renaming means editing
those by hand, which is what the note at the top of `brand.ts` is for.

Note that `BRAND.name` is `'Deck'`, not `'Terminal Deck'` — the UI calls itself
Deck, the bundle is called Terminal Deck.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) —
it covers running the app, the house rules this codebase is strict about, and
how to propose a change. By taking part you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

Found a security problem? Do not open an issue — see [SECURITY.md](SECURITY.md).

## Licence

MIT — see [LICENSE](LICENSE).

Third-party dependencies and their licences are inventoried in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).
