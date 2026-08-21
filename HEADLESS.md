# Headless build — WSL, Linux servers, and the machine with no screen

Asad, 2026-08-15: build it now, install it in his WSL Ubuntu. *"maybe give it
basic ui to just connect, and keep it same potential and being able to do
everything from controlling device what that device can do for local ones"*.

So: **not a reduced product. The same machine, without a window.**

---

## What it is

The desktop app minus Electron. It runs as a background process, joins the
relay, serves sessions, and is driven from a phone or from Terminal Deck on
another machine. Everything the GUI build can do *for the machine it runs on* —
start sessions in granted folders, the localhost tunnel, clipboard both ways,
file transfer, multi-host — it does too.

It is also the answer for Linux servers, and it is what makes PC-to-PC pairing
worth having: your Mac lists your Windows box, your WSL and any server, and they
are all just machines you can open a session on.

## The "basic UI to just connect"

There is no window, so the UI is the terminal it is installed from.

```
$ terminaldeck pair        # prints a short code + a QR, waits, confirms
$ terminaldeck status      # running? paired to what? sessions? relay reachable?
$ terminaldeck folders     # list / add / remove the folders a device may use
$ terminaldeck stop
```

`pair` is the whole onboarding: run it, read the code off the screen, type it
into the phone or the other machine. Same short-code scheme as PC-to-PC pairing
(`CREDENTIAL-PROXY.md` and the pairing notes) — one mechanism everywhere, not a
second one for headless.

Keep it to those. A headless build that grows a config file nobody can find is
how these become unmaintainable.

## What it must NOT become

A second implementation. The temptation is to write a small standalone server
"just for Linux" — and then every fix has to land twice, and one of the two
quietly rots. The sealed channel, the protocol, device auth, folder grants and
session management are shared code and stay shared.

The split is: **core** (sessions, remote server, crypto, grants) and **shell**
(Electron window, menus, renderer). Headless takes the core and gives it a
different shell. Much of this is already possible — `registerRemoteIpc` takes its
`ipcMain` as a parameter rather than importing it, so the seam exists.

## The Electron dependencies to unpick

The core reaches for Electron in places that need a non-Electron answer:

- `app.getPath('userData')`, `app.getPath('home')`, `app.getAppPath()` — needs a
  platform-paths module both shells provide. On Linux use XDG (`$XDG_DATA_HOME`,
  falling back to `~/.local/share/terminaldeck`).
- `ipcMain` — headless has no IPC. The injected interface is already the seam.
- `Notification` — a headless host has nobody to notify locally. It should
  forward to the paired devices instead, which is more useful anyway.
- `BrowserWindow`, menus, the browser pane — GUI only, excluded from the build.
- **`deck-control`, which is why a server has no copilot.** The one item on this
  list still outstanding, and the only one a *user* meets. `deck-control` is the
  copilot's whole tool surface, and `CopilotRuns` refuses a run without it rather
  than starting a Claude CLI with no tools — so a headless host passes no copilot
  layer at all, and a device approved as *my device* gets no Copilot on a server.
  Two real value imports are in the way: `deck-control/index.ts` pulls
  `browserDrive` from `browser-drive-ipc`, which loads `browser-tab` and
  `browser-driver` (`BrowserWindow`, `WebContentsView`, `nativeImage`) at module
  scope, and its `live-surface.ts` pulls `settings-extra`, which loads `app`,
  `session` and `shell`. Both want the same treatment `app.getPath` got.
  Until then the limit is *stated* rather than silent — `terminaldeck pair` and
  `terminaldeck status` both say it — because on the wire "this host has no
  copilot" and "you were approved as a guest" arrive as the same absence, and a
  person cannot otherwise tell which happened.

**The crypto needs no change and this is worth stating.** `src/shared/sealed.ts`
uses `@noble/ciphers` with deliberately no "native when available" path, because
Electron's BoringSSL ships no ChaCha and a fallback would mean the tests exercise
one implementation while users run the other. Plain Node runs the identical code.

## WSL: the thing that will actually bite

**WSL is not always running.** Close every WSL terminal and Windows will shut the
distro down after an idle timeout — taking the headless process, and every
session in it, with it. A phone that was paired to it then finds nothing there,
which looks exactly like the app being broken.

This must be handled openly, not discovered:

1. Run under **systemd inside WSL** (`/etc/wsl.conf` with `systemd=true`), as a
   user service, so it starts with the distro and restarts if it dies.
2. Keep the distro alive — Windows can start it at login (Task Scheduler running
   `wsl.exe -d <distro> -u <user> --exec ...`), so the machine is reachable
   without a human opening a terminal first.
3. **`terminaldeck status` must say which of these is true.** If the distro will
   stop when the last terminal closes, say so, on screen, before someone relies
   on it from a phone in another country.

Also true and worth saying once: keep the code in the Linux filesystem
(`/home/...`). Reaching Windows files from Linux through `/mnt/c`, or Linux files
from Windows through `\\wsl$`, crosses a slow boundary in either direction. The
whole reason to run in WSL is that nothing has to cross it.

## Staying reachable — and this is not just a WSL problem

Asad's correction, and it is right: WSL shutting down is *his* case. Somebody
running this on a server has a different version of the same question, and the
answer should be one feature, not a Windows workaround.

The requirement, in his words: keep it *"running a little bit with all the
necessary things whatever we can reach out to"*, and *"once we reach out to a
session or start a new session it may wakes it up"*.

So: **an idle mode, and a reachability setting, on every platform.**

### Idle mode — the default, always on

With no device attached, the process holds exactly one thing: **the relay
connection**. Everything else stops — file watchers, transcript tailing, port
scanning, cost polling, status detection. On the first attach it all comes back.

This is not a timer that checks whether to idle. Attach and detach are **events**
that already exist, so idling is a reaction to them and costs nothing while
nothing is happening. Asad's standing rule applies — *events, not polling* — and
the one thing that must survive is the WebSocket **ping/pong**, because a NAT
silently drops an idle connection and the socket dies without it. One heartbeat
layer, not two.

A `status` command must be able to say which mode it is in and what it is
currently holding open. An idle mode nobody can observe is indistinguishable from
a bug.

### Keep the host reachable — the same toggle as the desktop

The desktop has "keep this machine awake with the lid closed". Headless needs the
same idea with the same honesty, and the mechanism differs per host:

| Host | What it means |
|---|---|
| **Linux server** | Usually nothing to do — it is already always on. Say so rather than showing a toggle that does nothing. If it is a laptop, `systemd-inhibit` holds off idle and lid sleep. |
| **WSL** | Keep the distro alive: systemd inside WSL, plus Windows starting it at login. |
| **macOS / Windows host** | The same mechanism the GUI build uses. |

**Show only what applies to the host it is running on**, and when there is
nothing to do, say that. A toggle that is inert on a server is worse than no
toggle, because it implies a protection that is not being provided.

### Waking on demand

A session request that arrives while idle should simply work — wake, start, and
serve, with the delay being real work rather than a poll interval. Where the host
itself is asleep, be honest that the machine cannot be woken over the relay
unless something external does it (Wake-on-LAN, the platform's own scheduler),
and say so rather than implying the app can reach a powered-down computer.

## Packaging

- Node, not Electron.
- Ship as an npm package (`terminaldeck` is already claimed) plus a plain
  `curl | sh` script, since a server user will not want a GUI toolchain.
- No Electron, no Chromium: it should be small enough that installing it on a
  server is an easy decision.

An earlier version of this section said *"`node-pty` and `better-sqlite3` build
for Linux normally"*. Half of that is wrong and the wrong half is what broke the
install, so it is corrected here rather than quietly edited: `better-sqlite3` is
not in this package at all (`scripts/build-headless.mjs` derives the dependency
list from the bundle, and the bundle imports `@noble/ciphers`, `@xterm/headless`
and `node-pty` — nothing else), and node-pty does not *have* a Linux build to
place. Measured against the published tarball on 2026-08-18: node-pty 1.1.0 ships
prebuilds for `darwin-arm64`, `darwin-x64`, `win32-arm64` and `win32-x64`, and
its install step is `node scripts/prebuild.js || node-gyp rebuild`. On every
Linux box, the second half runs. It compiles.

## Installing it

There are two routes and they run the same script.

### From the desktop app, on a server it is already connected to

Machines → the server → **Sessions on this server** → *Set it up*. That is the
route somebody who does not want to open an SSH session takes, and it is what
Asad asked for on 2026-08-21: *"instead of going inside a server and doing some
stuff there … from the main application we can give some steps there for
installation, they will click on install and it will install."*

What it does, as five steps it reports one at a time:

1. **Checks** what the box has — Node, npm, a compiler, libc, room, systemd —
   and refuses *before copying anything* when it cannot take a host, naming the
   packages to install. `src/main/servers/host.ts` decides; the installer
   re-checks all of it on the machine itself.
2. **Copies** `terminaldeck-host.tgz` and `install.sh` over the SFTP channel the
   page already has. The tarball travels with the app — see below — because the
   npm name is a reservation.
3. **Installs**, in the terminal on screen, by typing
   `TERMINALDECK_PACKAGE=<tarball> sh install.sh`. Everything below about the
   private Node runtime applies unchanged; it is the same script.
4. **Starts** it: a systemd *user* unit where there is a user manager, `nohup`
   where there is not — and says which, plus whether it survives a logout and
   what would change that.
5. **Pairs** it: runs `terminaldeck pair --kind mine` in that same terminal,
   reads the code out of its output and offers to redeem it into this computer's
   Machines list. It does **not** answer the `Approve it? [y/N]` question, which
   carries the fingerprint.

`pair` in a real terminal is not decoration. It refuses to finish without a tty
— `if (!process.stdin.isTTY)` it prints the code, says so, and stops, because
approving nothing after appearing to wait would leave a device paired and
locked out. An exec channel is not a tty; a shell is.

Removing it is the same screen: it stops the service, deletes the unit, the
program and the private runtime, and leaves `~/.local/share/terminaldeck` — the
paired devices and their folder grants — unless the box is ticked.

**The package ships inside the app.** `npm run dist:headless` now also writes
`out/headless-package/{terminaldeck-host.tgz,install.sh}`, and
`electron-builder.yml` copies that folder to `Resources/headless`. A build where
that step did not run carries no package, and the server page draws **no**
Install button with a sentence saying so — never a registry install, because
`terminaldeck` on npm is a name reservation and installs a package with no `bin`
entry.

### By hand, on the machine itself

```
curl -fsSL https://terminaldeck.dev/install.sh | sh
```

That is `scripts/install-headless.sh`. It is still a wrapper around
`npm install -g terminaldeck` — npm is what places node-pty correctly for a
platform, arch and libc nobody here can see — and the reasoning at the top of the
file is worth reading before changing any of it.

### What the machine needs

| | |
|---|---|
| **OS** | Linux or macOS. Windows people install the desktop app. |
| **Architecture** | anything Node publishes a build for: `x64`, `arm64`, `armv7l`, `ppc64le`, `s390x`. `uname -m` says `aarch64`; Node spells that `arm64`, and the installer does the translation. |
| **C library** | glibc. See below. |
| **Node** | 22 or newer, with npm — **or nothing at all**, in which case the installer supplies its own. |
| **Build tools** | on Linux only: `python3`, `make`, a C++ compiler. For node-pty, per above. |
| **Network** | nodejs.org (only when it fetches a runtime) and registry.npmjs.org. |

### When there is no Node

This is the ordinary state of a rented Linux server and it is no longer treated
as the user's problem. Measured on the owner's own box on 2026-08-18 — aarch64,
Ubuntu 24.04.4, glibc 2.39 — `node` and `npm` were both absent, so the one
machine this feature was built against was the one machine it could not be
installed on.

So when Node is missing or older than 22, the installer:

1. works out `linux`/`darwin`, the architecture in Node's spelling, and glibc vs
   musl;
2. reads `https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt` — one 4 KB file
   that names both the current 22.x version and every checksum, so there is no
   version literal in the script to rot and no JSON to parse in `sh`;
3. downloads the `.tar.gz` (not the `.tar.xz`: GNU tar shells out to an `xz`
   binary a minimal image need not have) and **refuses to unpack it unless the
   sha256 matches**;
4. unpacks it into `~/.terminaldeck/runtime`, checks the binary actually runs,
   and uses that node and npm for the install.

Nothing is written outside `$HOME`. Nothing runs as root. Nothing is put on a
PATH behind anyone's back: the package goes into the runtime's own prefix, and a
four-line launcher at `~/.local/bin/terminaldeck` puts the private runtime first
*for that one process*, so a Node the machine gets later is never shadowed.
`rm -rf ~/.terminaldeck` and `rm ~/.local/bin/terminaldeck` undo all of it.

A machine that already has Node 22+ and npm downloads none of this and behaves
exactly as it did before.

What the checksum buys and does not buy: the bytes are the bytes nodejs.org
published, so a truncated transfer or a stale mirror is caught. It is not a
signature check — `SHASUMS256.txt` comes from the same origin as the tarball, so
a compromised origin signs its own homework. Node publishes a detached GPG
signature; checking it would mean shipping a keyring into a `curl | sh`.

### Not supported, and why

- **musl (Alpine, and anything else without glibc).** The Node project publishes
  no musl build — every tarball under `nodejs.org/dist` is linked against glibc.
  One unpacks perfectly on Alpine and then exits with `not found`, which is the
  loader missing and reads like nothing at all. The installer detects musl
  (`ldd --version` prints `musl libc`; the `/lib/ld-musl-*` loader is the
  fallback probe) and says so, naming `apk add --no-cache nodejs npm`. Everything
  else works on Alpine once node and npm are on PATH — node-pty compiles against
  musl fine, given `build-base python3`. What is unsupported is *fetching* a Node,
  not running on one.
- **A Linux box with no compiler.** node-pty has no Linux prebuild, so
  `npm install` runs node-gyp. Without `python3`, `make` and `g++` that fails a
  minute in with `gyp ERR! find Python`, which reads like a bug in this project.
  The installer checks first, before anything is downloaded, and names the
  packages for apt/apk/dnf/yum/pacman/zypper. `TERMINALDECK_SKIP_TOOLCHAIN_CHECK=1`
  goes past it if node-pty ever ships Linux prebuilds.
- **Windows.** The desktop app is the answer there; this installs a POSIX host.
- **Architectures Node does not build for.** Named as Node's answer rather than
  this project's opinion, with the exact filename that was not in the checksum
  file.
- **The npm package itself, today.** As of 2026-08-19 the registry still holds
  `terminaldeck@0.0.1`, a placeholder with no `bin` — `npm install -g` exits 0
  and installs no command. The installer now checks for the command after
  installing and refuses to report success without it, but until the real package
  is published, `curl | sh` cannot produce a working host on any machine.

### Environment

All optional. `TERMINALDECK_DRYRUN=1` prints the whole plan — detected machine,
resolved Node version, exact tarball URL, expected sha256, install prefix — and
writes nothing, which is what makes the rest of it testable from a machine that
is not the machine it is for (`src/headless/install-script.test.ts`).

| | |
|---|---|
| `TERMINALDECK_VERSION` | npm version or tag (default `latest`) |
| `TERMINALDECK_PACKAGE` | install this instead — a path to a tarball, for a server with no route to npmjs.org |
| `TERMINALDECK_DRYRUN=1` | print the plan, write nothing |
| `TERMINALDECK_NO_RUNTIME=1` | never fetch Node; refuse instead, leaving the machine untouched |
| `TERMINALDECK_FORCE_RUNTIME=1` | use the private runtime even where there is a good Node |
| `TERMINALDECK_RUNTIME` | where the private runtime goes |
| `TERMINALDECK_NODE_VERSION` | pin it |
| `TERMINALDECK_NODE_LINE` | release directory to track (default `latest-v22.x`) |
| `TERMINALDECK_NODE_MIRROR` | base URL for Node downloads |
| `TERMINALDECK_OS` / `_ARCH` / `_LIBC` | override detection |
| `TERMINALDECK_SKIP_TOOLCHAIN_CHECK=1` | skip the node-pty build-tools check |

## Definition of done

Installed in Asad's WSL Ubuntu, paired from his Mac's Terminal Deck **and** from
his phone, running a real session in a real Linux folder, surviving the last WSL
terminal being closed — proved by reading the session's own output on the far
side, not by the app claiming it is connected.
