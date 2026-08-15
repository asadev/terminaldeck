# Confinement — every platform, and no invented fences

Asad, 2026-08-15: *"let's do this confinement thing, build it ... purely,
securely and stable"*, and — correcting me — *"you have my windows pc you can use
windows pc for windows once and we have linux also installed inside so you can
use that environment for the linux confinement so both are there."*

He is right. The first pass skipped Windows and Linux for lack of a machine to
measure on. Both machines exist and are reachable.

---

## What confinement is, in one paragraph

A folder grant hands someone a terminal in a folder. A terminal can type `cd ..`.
So without the operating system enforcing it, a grant is a request, not a
boundary — and anyone granted one folder can read the whole disk, the SSH keys
and the git credentials. Confinement is the OS holding the fence.

## macOS — DONE, and this is the bar

`sandbox-exec` (Seatbelt) is deprecated and not decorative. Measured on macOS
27.0 against a real `zsh -l` under a real pty, a `(deny default)` profile refuses:
`cd ..` + `ls`, absolute paths elsewhere, `~/.gitconfig`, `~/.config/gh/hosts.yml`,
`~/.ssh`, `ls /Users`, `ls ~`, `/tmp` reads and writes, renaming the granted
folder — and **the login keychain item holding Claude Code's OAuth token**, which
was the biggest leak on that machine. Symlinks resolve before the rule applies in
both directions; a grandchild process is refused identically; `sandbox-exec` from
inside cannot re-sandbox itself out.

Two lines are load-bearing and read like tidy-up candidates:

- `(allow file-read* (literal "/"))` — without read on the root **directory**,
  `node` dies in `InitializeOncePerProcessInternal` with SIGABRT and prints nothing.
- `(allow file-ioctl (subpath "/dev"))` — `tcsetpgrp` is an ioctl, and without it
  every login shell prints that it cannot set the tty pgrp, twice.

## Linux / WSL — BUILD IT, and the machine is reachable

`ssh imza-pc-linux` from this Mac reaches Ubuntu 24.04 under WSL2. **Note: that
host config now pins `KexAlgorithms curve25519-sha256`** — OpenSSH 10's
post-quantum key exchange exceeds the 1280-byte MTU there and hangs.

Measure before choosing a mechanism:

1. Are unprivileged user namespaces enabled (`/proc/sys/kernel/unprivileged_userns_clone`,
   and whether `unshare -Urm` actually works)?
2. Is `bwrap` (bubblewrap) present or installable? It is the least surprising
   answer where it exists.
3. What does a bind-mount confinement do to `/mnt/c`, and to the `wsl.exe --cd`
   launch path the Windows build uses to start a session in a Linux folder?
4. Does the confinement survive systemd being the init, which this distro runs?

Then build it, and test the **escapes** rather than the happy path.

## Windows — BUILD IT, and the machine is reachable

`ssh imza-pc` reaches `DESKTOP-DDGMNCV`. Terminal Deck is installed there, and a
previous session already streamed a build onto it, so the route is known.

Measure before choosing:

1. **AppContainer** — the real sandbox, but it needs the process to be launched
   with a capability set and a per-container SID, and file access is granted by
   ACL rather than by path. Work out whether a granted folder can be ACL'd to the
   container's SID without permanently altering the user's own folder permissions.
2. **Restricted tokens** (`CreateRestrictedToken`) — coarser, easier, and worth
   measuring for what it actually stops.
3. **Job objects** — process containment, not filesystem, but relevant to
   stopping a session spawning its way out.
4. What any of these do to ConPTY, which node-pty uses, and to the WSL launch path.

## The rules that outrank ambition

1. **Never ship an unmeasured boundary.** A security feature that does not hold
   is worse than an honest gap, because people rely on it. If a platform cannot
   be confined, `confinementKind()` answers `'none'` there and the UI says so in
   its own sentence — never one sentence covering two platforms.
2. **Test the escapes, not the happy path.** `cd ..`, an absolute path elsewhere,
   a symlink pointing out, `/tmp`, the user's home, another device's granted
   folder, and reading the host's own git and gh credentials. A previous batch
   redirected those by environment — confirm whether that survives a determined
   shell, because environment is a suggestion and a filesystem rule is not.
3. **Sessions must still work.** A confinement that breaks node, git or the agent
   CLIs is unusable. Those tools live outside the granted folder and must stay
   reachable — read-only and executable, without opening a path back out.
4. **The transcript problem is part of this.** A confined session gets its own
   HOME, so the agent CLI writes transcripts somewhere the app's readers do not
   look, and chat mode and cost go blank. Confinement is not finished until that
   is solved.
5. **Uniform model.** Asad was explicit: no two-tier trust. Every connected
   device is treated the same regardless of type or owner, so confinement is how
   the feature works for everyone — not a special mode for outsiders.

## Definition of done

On each of the three platforms, either: a measured, escape-tested boundary with a
real session working inside it — or a written account of exactly what was tried,
what it did, and why it does not hold, with the UI telling the truth about that
platform.

---

# Measured — 2026-08-15

Answers to the questions above, run rather than reasoned about. Everything below
was executed; nothing is inferred from documentation.

## The two hosts are one machine

`ssh imza-pc` and `ssh imza-pc-linux` both land in the **same** Ubuntu 24.04
under WSL2 on `DESKTOP-DDGMNCV` (kernel `6.18.33.2-microsoft-standard-WSL2`).
There is no separate Windows shell on that name. The Windows side is reachable
from it through interop — `/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe`
answers — and that is how the Windows facts below were obtained.

## Linux / WSL — the mechanism holds. It is still not switched on.

| Question | Answer |
| --- | --- |
| Unprivileged user namespaces enabled? | **Yes.** `/proc/sys/user/max_user_namespaces` is `79947`; `unshare --user --map-root-user id` reports `uid=0(root)`. |
| `kernel.unprivileged_userns_clone`? | **Does not exist** on this kernel — the Debian-ism, absent as expected. |
| Ubuntu's AppArmor userns restriction? | **Does not exist either.** `/proc/sys/kernel/apparmor_restrict_unprivileged_userns` is absent in the WSL kernel, so the thing that blocks this on a stock Ubuntu 24.04 desktop does not apply here. |
| `bwrap` present? | **No.** In the archive as `0.9.0-1ubuntu0.1`; installing needs sudo, which this app must not assume. `unshare`, `nsenter`, `setpriv` and `capsh` are all present. |
| What does a bind-mount confinement do? | **It holds.** `tmpfs` over `/home` with the granted folder bound back in: the folder stays readable and writable, `ls $HOME` shows only the granted folder, and a canary in the owner's home is unreadable. `git` and `node` (v22.23.1) still run. |
| What does it do to `/mnt/c`? | **Removes it.** `/mnt/c` is a 9p `drvfs` mount; an empty bind over `/mnt` makes `/mnt/c` `No such file or directory`, which also removes every path to a Windows `.exe` — so interop-by-path stops working. The `WSLInterop` binfmt handler stays registered; it is the paths that are gone. |
| Survives systemd as init? | **Yes.** PID 1 is `systemd`, and the namespace + `tmpfs` over `/home` works unchanged from inside it. |

### The escapes, which are the part that matters

| Attempt | Result |
| --- | --- |
| `umount /home` from inside, **caps not dropped** | **ESCAPE.** The canary in the owner's home is read. Bind-over alone is decoration. |
| Same, after `setpriv --bounding-set=-all --inh-caps=-all` | Refused: `umount: /home: must be superuser to unmount`; canary unreadable. |
| Nested user namespace to regain `CAP_SYS_ADMIN` | Refused: `unshare: write failed /proc/self/uid_map: Operation not permitted`. |
| `/proc/1/root/home` | `Permission denied`. |
| Symlink out of the granted folder to `/home/asad` | Resolves into the `tmpfs`, which contains only the granted folder. Nothing gained. |
| Absolute path to the owner's home | `No such file or directory`. |
| `/mnt/c/Windows/System32/cmd.exe` (interop by path) | `not found` — `/mnt` is bound over. |

**Dropping the capability bounding set before `exec` is load-bearing.** Without
it the boundary is decoration; with it, every escape above fails. Any Linux
implementation that omits `setpriv` is not a boundary.

### Why it is not built anyway

Two reasons, both about this app rather than about the kernel:

1. **The `wsl.exe --cd` launch path has never been run.** A session inside WSL is
   started by the Windows build through `wsl.exe`, and none of the measuring
   above went through it — it was all over ssh. A boundary whose launch path is
   unmeasured is exactly the kind this project refuses to claim.
2. **`WSL_INTEROP` is an unmeasured door straight back out.** Under a real
   `wsl.exe` launch the session inherits that variable, pointing at a socket that
   asks the Windows side to start processes with the user's full privileges. The
   ssh sessions used for the measurements had it unset, so it was never tested.
   Closing it means unsetting the variable *and* hiding `/run/WSL`.

One box's kernel is also not "Linux": the same script on a distribution with the
AppArmor restriction switched on fails at the first step. So anything built here
must prove itself **per session on the actual machine**, the way
`proveConfinement` already does for Seatbelt, rather than trusting a platform
name.

## Windows — measured enough to say why it is not a weekend's work

- Windows 11 Pro, `10.0.26200.0`.
- Node is installed Windows-side (`C:\Program Files\nodejs\node.exe`) and Terminal
  Deck is installed at `%LOCALAPPDATA%\Programs\Terminal Deck`.
- The interop session runs at **High Mandatory Level**.
- **There are no AppContainer PowerShell cmdlets.** `Get-Command *AppContainer*`
  returns nothing. AppContainer is a Win32 API — `CreateAppContainerProfile`, and
  `UpdateProcThreadAttribute` with `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES`
  at spawn — reachable only from native code.

That last point is the finding. Node cannot put a child in an AppContainer, and
neither can `node-pty`: the container has to be applied *at process creation*, so
it needs either a native addon or a small launcher `.exe` that this repository
does not have. The same is true of `CreateRestrictedToken`. So Windows
confinement is not "wire up an API" — it is "ship a native launcher", and until
one exists `confinementKind('win32')` stays `'none'` and the grant screen keeps
saying so.

## What did get fixed

The transcript problem in rule 4 above — *"Confinement is not finished until that
is solved"*. It is solved, and solved without copying or symlinking anything: the
confined session goes on writing where it was always going to write, and the
transcript layer is told where the per-device homes are. Measured with the real
CLI (2.1.233):

    HOME=/tmp/homeprobe claude config ls
      → /tmp/homeprobe/.claude.json          (config, one level up)
      → /tmp/homeprobe/.claude/projects/…    (transcripts, here)

Chat mode, the cost pane, alerts, the agent controls and the session inspector
all read every store now. See `src/main/transcript.ts`.
