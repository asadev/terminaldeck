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

- Node, not Electron. `node-pty` and `better-sqlite3` build for Linux normally.
- Ship as an npm package (`terminaldeck` is already claimed) plus a plain
  `curl | sh` script, since a server user will not want a GUI toolchain.
- No Electron, no Chromium: it should be small enough that installing it on a
  server is an easy decision.

## Definition of done

Installed in Asad's WSL Ubuntu, paired from his Mac's Terminal Deck **and** from
his phone, running a real session in a real Linux folder, surviving the last WSL
terminal being closed — proved by reading the session's own output on the far
side, not by the app claiming it is connected.
