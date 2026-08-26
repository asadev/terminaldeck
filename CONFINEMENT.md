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
   look, and cost, alerts and the session inspector go blank. Confinement is not
   finished until that is solved.
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

The cost pane, alerts, the agent controls and the session inspector all read
every store now. See `src/main/transcript.ts`.

---

# Windows — measured again, 2026-08-16, and this time it holds

The 2026-08-15 pass stopped at *"reachable only from native code"*. That is the
right reason not to **ship**, and it was the wrong reason not to **measure** —
so this pass wrote the native code and measured it. Everything below was run on
`DESKTOP-DDGMNCV`, Windows 11 Pro `10.0.26200.0` build 26200, against a real
`cmd.exe` on a real ConPTY driven by the same `node-pty` 1.1.0 the app ships.
The launcher is `native/win-confine/tdconfine.c`; the module that drives it is
`src/main/confine/appcontainer.ts`.

## The mechanism, in one line each

| Mechanism | Verdict |
| --- | --- |
| **AppContainer** | **The boundary.** Applied at `CreateProcess` through `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES`. Every escape below was refused. |
| **Restricted tokens** | **Written off.** `DISABLE_MAX_PRIVILEGE` leaves the token at High integrity and reads `.gitconfig` and the whole of `.claude.json`; deny-only groups still read both and break every tool; a restricting-SID list breaks the granted folder too. The user's own SID is what grants the home directory, and nothing short of a restricting-SID list removes it. |
| **Job objects** | **Useful, not a boundary — and the launcher now uses one anyway.** Breakaway is refused (`ERROR_ACCESS_DENIED`, verified), but `wsl.exe -e /usr/bin/setsid /bin/sleep 511` survived `TerminateJobObject` with its pid and session id intact. **A job must never be described as containing a WSL session.** What it is in for is a defect measured on this launcher: see "the child outlives a hard kill" below. |
| **WSL** | **Out of scope for any Windows mechanism.** `wsl.exe` is refused outright inside an AppContainer, with the window station already granted. A session in a Linux folder must be confined on the Linux side by the namespace mechanism. |

## ConPTY works, and it is the part nobody had to reimplement

`node-pty` spawns `tdconfine.exe`, which inherits the pseudoconsole and passes
it to the child through ordinary handle inheritance — no second pty, no byte
pumping, no resize forwarding. Measured end to end: a live prompt, typed input
echoed with VT and cursor-positioning sequences, `type hello.txt` returning the
granted-folder canary, `type C:\Users\Imza\outside-canary.txt` returning
`Access is denied.`, and the exit code coming back.

## The escapes

All with one ACE on the granted folder, one on the device's home, and the
ancestor ACEs described below. Each was also run **unconfined first**, and all
of them succeed there — a test that cannot fail proves nothing.

| Attempt | Result |
| --- | --- |
| `type` the owner's home canary | `Access is denied.` |
| `type C:\Users\<user>\.gitconfig` | `Access is denied.` |
| `type C:\Users\<user>\.claude.json` | `Access is denied.` |
| `dir C:\Users\<user>\.ssh` | Refused (nothing listed) |
| `node -e "fs.readFileSync('C:/Users/<user>/outside-canary.txt')"` | `EPERM` |
| Another device's granted folder | `Access is denied.` |
| `mklink /D` out of the folder | `You do not have sufficient privilege` |
| `mklink /J` out of the folder | `Access is denied.` |
| Write into an ancestor | `Access is denied.`, and nothing landed |
| `icacls . /grant *S-1-1-0:(OI)(CI)F` — rewrite its own ACL | `Access is denied.` (the grant is Modify, which excludes `WRITE_DAC`) |
| Grandchild process (`cmd /c cmd /c type <canary>`) | `Access is denied.` |
| `powershell Start-Process` a process to copy the canary out | Ran, and was confined too; the file was never written |
| `dir "%LOCALAPPDATA%\Programs\Terminal Deck"` | `Access is denied.` |
| `reg add HKCU\...\CurrentVersion\Run` | `ERROR: Access is denied.` |
| `wevtutil qe System` | `Access is denied.` |

Identity inside: `Mandatory Label\Low Mandatory Level`, so UIPI applies on top of
everything above. Privileges: `SeChangeNotifyPrivilege` and
`SeIncreaseWorkingSetPrivilege`, and nothing else.

## Three things that are true and are not obvious

### 1. The interactive desktop does NOT have to be handed over

> **Corrected on 2026-08-16 by the non-elevated pass below.** Everything in this
> subsection is true of an **elevated** host and only of one. `CreateWindowStationW`
> needs an administrator, so the app that actually ships cannot do this. What it
> does instead — a private *desktop* on the station it is already on — is in
> "Windows, measured a third time" below, along with the clipboard measurement
> that says what that costs.

The previous pass found that almost nothing starts without the container being
granted a window station and desktop — `mode.com`, `where.exe`, `timeout.exe`,
`whoami.exe` and `tasklist.exe` all die with `0xC0000142` — and concluded that
granting `WinSta0` and `Default` was mandatory and was a genuine weakening.

It is not mandatory. The launcher creates a window station and a desktop **of
its own**, grants those, and starts the child on them by name. `WinSta0` is
never touched: its ACL after a confined session is what it was before. The
confined process has a desktop with nothing on it.

The trap on the way there is worth writing down, because it reads as "the OS
will not allow this" when it is really "ask for the right":
`WINSTA_ALL_ACCESS` is **not** all access. Unlike `FILE_ALL_ACCESS` it is a bare
OR of the window-station-specific rights with no `STANDARD_RIGHTS_REQUIRED`, so
a handle opened with it cannot read or write the object's own security
descriptor — and granting the container access to a station this very process
had just created failed with `ERROR_ACCESS_DENIED`. `WINSTA_ALL_ACCESS |
READ_CONTROL | WRITE_DAC` is the fix.

### 2. The ancestors have to be listable, and that is where Windows is weaker than macOS

The granted folder's ancestors — `C:\`, `C:\Users`, `C:\Users\<user>`, and each
directory down to the folder — need an ACE, and the narrow one does not work.
With `FILE_TRAVERSE | FILE_READ_ATTRIBUTES` (pass through, do not list) a shell
works, `node` works, the agent CLI works, `cd ..` shows nothing — and **every
git command dies** at `fatal: unable to get current working directory:
Permission denied`.

The reason is exact, and was measured with a probe compiled and run inside the
container:

```
GetCurrentDirectoryW                        -> ok
GetLongPathNameW                            -> 0  err=5   (ERROR_ACCESS_DENIED)
CreateFileW(cwd, 0, …BACKUP_SEMANTICS)      -> ok
GetFinalPathNameByHandleW(VOLUME_NAME_DOS)  -> 0  err=5
GetFinalPathNameByHandleW(VOLUME_NAME_NT)   -> \Device\HarddiskVolume3\Users\…
```

git-for-windows resolves its own working directory with `GetLongPathNameW`,
which enumerates every component — so it wants `FILE_LIST_DIRECTORY`, not
traversal. Its fallback for exactly this case opens the folder fine and then
fails as well, because `VOLUME_NAME_DOS` has to map `\Device\HarddiskVolume3`
back to `C:` and an AppContainer cannot enumerate the DOS device namespace. **No
ACL fixes that one.**

So the choice was git or the listing. `FILE_LIST_DIRECTORY` is in the mask, and
the honest sentence is: **a confined Windows session can see the names, sizes
and dates of the entries in each ancestor directory, including the owner's home
directory. It cannot open any of them.** On macOS `ls ~` is refused outright.
This difference belongs on the grant screen in its own sentence —
`WINDOWS_GRANT_NOTE` in `appcontainer.ts` is the wording.

### 3. `SetNamedSecurityInfo` on an ancestor is a disk walk, and it cost fifteen minutes

The first version wrote every ACE with `SetNamedSecurityInfoW`. That re-runs the
auto-inheritance algorithm over everything underneath the object, and on `C:\`
that is the whole disk: one grant-and-revoke cycle over three ancestors spent
**fifteen minutes at 100% of one core** and had to be killed, which left its
ACEs on the user's home directory — the exact litter the teardown exists to
prevent.

The split that fixes it is one line of policy: **propagate exactly when the ACE
is inheritable.**

- The granted folder, the device home and tool directories carry `(OI)(CI)`, so
  they use `SetNamedSecurityInfoW` and the walk is the point — NTFS materialises
  inherited ACEs on each child, so without it the session could create new files
  and not open the ones already there. Measured: **0.57s** for grant, run and
  revoke over a 5,000-file tree.
- Ancestors carry `NO_INHERITANCE`, so they use `SetFileSecurityW`, which writes
  the DACL and stops. `SE_DACL_AUTO_INHERITED` and `SE_DACL_PROTECTED` are
  carried across by hand, because that call takes the descriptor literally and a
  descriptor built from scratch would silently change how the directory inherits
  from then on.

Verified by string-comparing `icacls` output for `C:\`, `C:\Users`,
`C:\Users\<user>` and the granted folder before and after a full run:
**identical**, including after the MSVC build, and after every escape above.

## What is left, and it is a product decision rather than a mechanism

> **Corrected on 2026-08-16.** It was not a product decision. On Windows every
> session is `cmd.exe /c <cli>` — `providers.ts` has always built it that way,
> because the agent CLIs are npm shims and `CreateProcess` will not run a batch
> file — so the *shell* is what starts the tools in an agent session too. Without
> the tool grant there is no working confined Windows session of any kind. The
> paragraph below is otherwise accurate and the "13,000 files, needing
> administrator rights" estimate is what led to the one-time grant.

`node`, `git` and `claude` all run inside the container **with no permission
change anywhere near `Program Files`** — because the *launcher* opens the image,
and the launcher is not confined. Terminal Deck's own sessions launch the agent
CLI directly, so they work exactly as they are.

A confined **shell** cannot start them itself: those images carry no
`ALL APPLICATION PACKAGES` ACE, so `node -v` typed inside the container answers
`Access is denied`. Making them reachable means granting the tool trees to the
container for the life of the session — about 13,000 files across the node and
Git installs, needing administrator rights, and an `icacls` sweep already
perturbed `C:\Program Files\nodejs`' inheritance flag once. **Cheaper and
safer: the app keeps launching the tools. Closer to "a terminal": grant the tool
trees.** That is Asad's call, and `confinementKind('win32')` stays `'none'`
until it is made.

## The child outlives a hard kill, and that is what the job object is for

Measured, not reasoned about. With a confined `node` sitting in a 30-second
timer and the launcher killed with `TerminateProcess`:

| | before the job object | after |
| --- | --- | --- |
| ACE present while the session runs | yes | yes |
| ACE left behind after the kill | **yes** | yes |
| Confined child still running after the kill | **1** | **0** |

The child surviving is the part that mattered: a process still alive inside the
container, still holding the ACEs on the user's folders, with nothing left that
knows to take them off — and killing the launcher is exactly what `node-pty`
does when a tab is closed hard. `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` fixes it,
with the child created suspended and resumed only once it is in the job, so
there is no window in which it could spawn something outside.

The ACE is still left behind, because a terminated process gets no chance to
revoke. That is why the container name is per **device** rather than per session
— the litter is bounded at one SID per device, and the thing that inherits a
leftover ACE is the device that was granted the folder in the first place — and
why `tdconfine.exe --container <name> --release …` exists. Verified: after a
hard kill the ACE is there, and after `--release` every path is back to clean.

## Two costs and one gap, none of them hidden

- **Loopback.** An AppContainer cannot reach `127.0.0.1` without a machine-wide
  loopback exemption, which the launcher will not create. A confined session
  reaches the internet and cannot reach a dev server on the same machine.
- **Session start pays for the ACL**, proportional to the file count under the
  granted folder. 0.57s at 5,000 files.
- **Credential Manager isolation is still UNMEASURED, and now the reason is
  known.** `cmdkey /list` answers `* NONE *` inside the container — and it
  answers `* NONE *` outside it too, on this box, *even after a credential is
  added*: the only shell reachable here is a WSL-interop session, which carries
  `NT AUTHORITY\NETWORK`, and a network logon's credential set does not persist.
  So neither answer proves anything and this must not be reported as a blocked
  escape the way the macOS keychain result was. What *is* measured is the file
  side: `%LOCALAPPDATA%\Microsoft\Credentials` is under the home directory and
  has no container ACE, so the vault files are unreadable. Whether `CredEnumerate`
  would hand them over through LSA needs an interactive logon to answer.

## Building it

`native/win-confine/build.ps1` — `vswhere` → `VsDevCmd.bat` → `cl /W4 /WX /GS
/guard:cf`. Run against a real Visual Studio Build Tools 2022 install (MSVC
14.44.35207) on this machine: **compiles clean**, 154,112 bytes, and the
MSVC-built binary was put through the whole escape table above with the same
results as the mingw-w64 one used during development.

Two things that broke that script and would break it again in CI:

- **Windows PowerShell 5.1 reads a `.ps1` as the ANSI code page** unless the
  file has a UTF-8 BOM. One em dash inside a double-quoted string terminated the
  string early and produced five cascading parse errors naming the wrong lines.
  The script is pure ASCII on purpose.
- **`$PSScriptRoot` is empty inside a `param()` default block** in 5.1. It
  surfaced as "Cannot bind argument to parameter 'Path'" from a `Join-Path`
  forty lines away.

## Landing it — the integration, as a list for whoever lands this and the Linux work together

Nothing in this pass touched `src/main/confine/index.ts`, `plan.ts`, `linux.ts`
or `seatbelt.ts`, because the Linux mechanism was being built in them at the
same time. Two new files were added — `src/main/confine/appcontainer.ts` (with
its test) and `native/win-confine/` — and everything below is what connects
them. In order:

1. **`ConfinementKind` gains a fourth value, `'appcontainer'`.** A new value
   rather than a boolean, exactly as the type's own comment asks for.
2. **`confinementKind('win32')` returns it only when three things are true**, and
   until then it keeps answering `'none'`:
   - the launcher is on disk (`launcherPath(process.resourcesPath)`),
   - the **tool-launch decision above has been made** — this is the one that is
     not an engineering question,
   - and the per-session probe passed, which is `proveConfinement`'s job rather
     than this function's.
3. **`unconfinedReason('win32')` returns `WINDOWS_UNCONFINED_REASON`** from
   `appcontainer.ts`. Its current sentence says these mechanisms "has not been
   built or measured", and measured is now false.
4. **`proveConfinement` dispatches `'appcontainer'` to `proveAppContainer`**, the
   way it already dispatches `'namespace'` to `proveNamespace`. It needs one
   argument the other two do not: a directory inside the boundary to write the
   positive canary into. Pass the device's home, not the granted folder — it is
   app storage, so the probe leaves nothing in somebody's project.
5. **`confineSpawn` returns `{ command: launcher, args: appContainerArgs(...) }`**
   for that kind.
6. **`host-core.ts`'s `confined` condition** is currently
   `confinementKind(platform) === 'seatbelt' && target === null`. The
   `target === null` half must stay and is now load-bearing for a second reason:
   `wsl.exe` is refused inside an AppContainer, so a Linux-folder session must
   go to `confineWslLine` and never here.
7. **`plan.ts` puts the macOS system roots in every plan, on every platform.**
   `sessionPlan` prepends `MACOS_SYSTEM_READ_ROOTS` — `/System`, `/usr`, `/bin`,
   `/Library` and the rest — to the readable list unconditionally, which was
   harmless while nothing on Windows read a plan. `appcontainer.ts` drops
   anything that is not drive-rooted before it reaches the launcher, because
   asking it to ACL `/usr` on a Windows machine would fail and refuse a session
   that is perfectly confinable, with a reason naming a directory that has never
   existed there. The tidier fix is for `sessionPlan` to pick its system roots
   by platform, and that is a change in a file this pass did not touch.
8. **`confinedEnv` is the wrong function on Windows.** `host-core.ts` must call
   `windowsConfinedEnv` for this kind — `plan.ts`'s version sets `HOME` and
   `TMPDIR` with `posix.join`, and a Windows session needs `USERPROFILE`,
   `HOMEDRIVE`, `HOMEPATH`, `APPDATA`, `LOCALAPPDATA`, `TEMP` and `TMP` as well.
   Measured: with only `HOME` set, git warns three times about the *owner's*
   `.gitconfig` and then dies.
9. **`index.ts`'s existing note** — that a WSL session reports `win32` because
   the app is a Windows process — is the exact seam item 6 describes. It is
   worth restating there once both mechanisms exist.
10. **`electron-builder.yml`** needs `tdconfine.exe` in `extraResources` under
   `win:`, not in `files:`. It is an executable and `CreateProcess` cannot run a
   file that only exists inside the asar.
11. **`.github/workflows/release.yml`** needs one step in the `windows:` job,
    before `Build the Windows artifacts`:
    `- run: native/win-confine/build.ps1 -OutDir native/win-confine` with
    `shell: powershell`. The script is ASCII-only and PowerShell 5.1-safe for
    exactly that reason.
12. **`DeviceFolders.tsx`'s `confinesSessions`** returns true for Windows, and
    the Windows branch gets its **own** sentences — not the macOS ones — carrying
    what `WINDOWS_GRANT_NOTE` says about the ancestor listing. Rule 1 of this
    document is that one sentence never covers two platforms, and here the two
    platforms genuinely differ.
13. **Teardown gets a caller.** `releaseArgs` should be run when a folder grant
    is withdrawn, and on startup for every device that has one, so an ACE left
    by a hard kill does not outlive the grant that justified it.

---

# Windows — measured a third time, non-elevated, 2026-08-16

Everything above was measured from a shell that was **elevated**, and nobody
noticed, because the only route onto that machine from here is `ssh` into WSL
and out through interop — and that logon runs at High integrity with the
Administrators group enabled. `whoami /groups` says so:

    NT AUTHORITY\Local account and member of Administrators group   Enabled
    Mandatory Label\High Mandatory Level                            S-1-16-12288

Terminal Deck is a desktop app that nobody elevates. So this pass re-ran the
mechanism as the app actually is: **medium integrity, Administrators deny-only,
in the user's own interactive session** — reached by a scheduled task created
with `/RL LIMITED /IT`, which is the one way to get a genuinely filtered token
in a logged-on session from a machine you are only ssh'd into. It reports
`session=1` and `Mandatory Label\Medium Mandatory Level`, which is the whole
point of using it.

Three of the previous pass's conclusions changed, one of them completely.

## 1. A normal user cannot create a window station

`CreateWindowStationW` answers `ERROR_ACCESS_DENIED` for a non-elevated token.
So "the launcher creates a window station of its own and never touches
`WinSta0`" was true of the measuring shell and could never have been true of the
shipping app — the launcher would have refused every session with
`tdconfine: could not create a window station (0x00000005)`, which is exactly
what the non-elevated run printed.

What ships instead is `--station shared`: a private **desktop**, created on the
window station the app is already on, granted to the container, and named in
`STARTUPINFO.lpDesktop`. A desktop is something a normal user can create. The
station's ACL is still never touched, and now for a better reason than before —
nothing needs it: an AppContainer already reaches the interactive station
through the `ALL APPLICATION PACKAGES` ACE Windows puts there for store apps.

The cost this was braced for did not materialise, and it was measured rather
than assumed, because a window station owns the clipboard:

    OpenClipboard() from inside the container  ->  FAIL err=5 (ERROR_ACCESS_DENIED)

So a confined session on the shared station cannot read what the user last
copied. It has no window of theirs on its desktop either. `--station own` is
still in the launcher, still stronger, and is what an elevated host would use.

## 2. Two ancestors cannot be granted per session, and that is why there is a one-time grant

`AccessCheck` for `WRITE_DAC`, asked with a real filtered token, against the
paths a session needs:

| Path | Can a non-elevated user rewrite its ACL? |
| --- | --- |
| `C:\` | **No** |
| `C:\Users` | **No** |
| `C:\Users\<user>` | Yes |
| `C:\Users\<user>\AppData\Roaming\npm` | Yes |
| `C:\Program Files` | **No** — and *no* to an administrator too; owner is `NT SERVICE\TrustedInstaller` |
| `C:\Program Files\nodejs` | No (an administrator can) |

`C:\` and `C:\Users` are on the path to every granted folder under a user
profile, and a confined session that cannot list them cannot resolve an absolute
path at all: `cmd` answers `Access is denied` for a command given by full path.
Measured both ways, same session, same image, one flag apart:

    ancestors C:\ + C:\Users granted    ->  the program runs
    the same run without them           ->  Access is denied

So per-session ACLing would need an administrator **at every session start**.
That is the design that was rejected, and this is the measurement that says it
was not merely unpleasant but unavoidable-if-you-do-it-that-way.

`C:\Program Files` turns out not to be needed at all: `SeChangeNotifyPrivilege`
("bypass traverse checking") is in every token including the container's, so the
ACE on `C:\Program Files\nodejs` itself is what the open needs. Nothing in this
feature ever writes to `C:\Program Files`, which is just as well, because
granting it would mean taking ownership of it.

## 3. The trustee is a capability SID, so the grant can be made once

A per-device container SID cannot be granted once — a device paired next month
would not be covered. A **capability SID** can: it is derived from a fixed name
by a documented hash, so it is the same value on every machine and after every
reinstall, and a process created in an AppContainer can be handed that
capability at creation time.

`DeriveCapabilitySidsFromName("terminaldeck-confined-tools")` on Windows and
`capabilitySid()` in `confine/tools.ts` answer the same string:

    S-1-15-3-1024-2903970903-3332091749-2496909251-2529716095-1516878088-2465616563-3028488617-2738278047

(SHA-256 of the name uppercased, UTF-16LE, read as eight little-endian dwords.
`tools.test.ts` pins the value that machine produced rather than recomputing it,
because a test that derives the expectation the same way the code does passes
for any derivation at all.)

The three-way measurement that made this the design — one directory, one ACE,
nothing else changed:

| ACE for the capability | Capability in the token | Result |
| --- | --- | --- |
| present | present | the file is read, the image runs |
| present | absent | `Access is denied` |
| absent | present | `Access is denied` |

**Why not `ALL APPLICATION PACKAGES`.** It would work — it is what Windows uses
to make `System32` reachable — and it means *every* AppContainer on the machine.
The npm prefix lives inside the user's home directory, and granting it to every
store app is a wider change than this feature needs. A capability nothing else
asks for narrows it to sessions this app starts.

## What the one-time grant actually contains

Computed from the machine rather than hardcoded: for each of `node`, `git` and
the agent CLIs, the first directory on the session's `PATH` that holds it.
On this machine that is three directories out of the eighteen on the `PATH` —
the JDK, dotnet, two NVIDIA folders, VS Code and GitHub Desktop are **not**
granted, and a confined session cannot run them.

    read+execute, inheritable    C:\Program Files\nodejs
                                 C:\Program Files\Git\cmd
                                 C:\Users\Imza\AppData\Roaming\npm
    list+traverse, no inherit    C:\   C:\Users   C:\Users\Imza
                                 C:\Users\Imza\AppData   ...\Roaming
                                 C:\Program Files\Git

Cost: **0.54s** to grant, the same to withdraw. Verified by string-comparing
`icacls` output before and after — the six ancestors flat and
`C:\Program Files\nodejs` **whole tree, recursively**: identical.

## Where Windows is weaker than macOS, and it is written down rather than discovered

**A confined Windows session can list the entries of every directory on the path
from the drive root down to its own folder, including the owner's home
directory** — names, sizes and dates, the way `dir` shows them. It cannot open
any of them: reading `C:\Users\<user>\.gitconfig` is `Access is denied` while
`dir /b C:\Users\<user>\.gitconfig` prints the name.

This is not a convenience anybody chose. The ancestor ACE has to carry
`FILE_LIST_DIRECTORY` rather than traverse-only because **git dies without it**:
git-for-windows resolves its own working directory with `GetLongPathNameW`,
which enumerates each component, and its fallback for exactly that case
(`GetFinalPathNameByHandleW` with `VOLUME_NAME_DOS`) cannot work in an
AppContainer at all, because the DOS device namespace is not enumerable there —
measured with a probe compiled and run inside the container. With traverse-only,
every git command dies at `fatal: unable to get current working directory:
Permission denied`. The same ACE is what lets `cmd` resolve an absolute path, so
without it a confined session cannot start a program by full path either.

So the choice was: git works and the ancestors are listable, or the ancestors are
not listable and nothing works. On macOS `ls ~` is refused outright; here it is
not. `WINDOWS_GRANT_NOTE` in `appcontainer.ts` is the sentence the grant screen
owes the user about it, and it is the one thing about the Windows boundary a
person choosing who to hand a device to would want to know and would not guess.

## The whole thing, on the real path, non-elevated

`node-pty` — the very build Terminal Deck ships, loaded through the installed
app's own Electron — spawning `tdconfine.exe` on a real ConPTY, from a
medium-integrity process in the user's session, with the environment
`windowsConfinedEnv` produces. Typed at, like a person:

    echo TYPED-OK                       TYPED-OK
    node -v                             v26.7.0
    git --version                       git version 2.55.0.windows.1
    git status --porcelain              ?? clip.exe  ?? inside.txt  ...
    claude --version                    2.1.231 (Claude Code)
    type inside.txt                     INSIDE-SECRET-9911
    type C:\Users\Imza\<outside>.txt     Access is denied.
    cd .. & dir /b                      (lists the ancestor: the weakening above)
    exit                                <<<EXIT 0>>>

A live prompt, VT and cursor-positioning sequences, the exit code coming back.
And the control that makes it mean something — the same session, same grant,
with the capability removed from the token:

    node -v    'node' is not recognized as an internal or external command,
               operable program or batch file.

`git` also needs the redirected environment, and this is the failure that looks
like a broken boundary and is not: with only `HOME` set, git printed
`warning: unable to access 'C:/Users/Imza/.gitconfig': Permission denied` three
times and then `fatal: unknown error occurred while reading the configuration
files`. The boundary was working perfectly. With `windowsConfinedEnv` —
`USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`
— the same session ran `git status`, `git log` and `git commit`.

## What is switched on, and what a human still has to do

`confinementKind('win32')` now answers `'appcontainer'` — but **only when two
things are true on the machine it is asked on**: the launcher is on disk, and
the one-time grant has been made and recorded. Until both are, it answers
`'none'` and the grant screen says so in a sentence of its own, exactly as it
does for a platform with no mechanism at all. That is the honest reading: a
Windows machine where the grant has never been made does not have a boundary,
and claiming the kind there would produce sessions that refuse to start rather
than sessions that are held.

The per-session probe then has to pass as well, and it now asks two questions
rather than one. The boundary half is unchanged — a canary written outside the
plan must not come back. The new half starts the granted `node.exe` **from
inside the container** and requires a token that is echoed only if it exited
zero. Without it, a machine whose grant had been removed would pass every
boundary check and hand the user a terminal that cannot run anything, and the
proof would have called that confined. It would have been right, and useless.

**What is missing is the button.** Nothing in the shipped UI calls
`establishToolGrant()`, because the renderer and the IPC wiring were owned by
other work in the same batch. The mechanism is complete and proven; the trigger
is one call. Until it lands, a Windows user who installs 0.2.0 gets exactly what
0.1.x gave them — an unconfined session and a screen that says so — and the day
the button lands, the same build starts confining, because the gate is a fact
about the machine rather than a build-time constant.

The installer is **not** the place for it, and that is measured too rather than
assumed: `electron-builder.yml` has `perMachine: false`, so the NSIS installer
runs unelevated and installs into `%LOCALAPPDATA%`. There is no elevation at
install time to borrow, and the tools are frequently installed *after* the app
anyway.

## The two remaining teardown callers

Unchanged from the previous pass's list and still true: `releaseArgs` should run
when a folder grant is withdrawn, and on startup for every device that has one,
so an ACE left behind by a hard kill does not outlive the grant that justified
it. `withdrawToolGrant()` is the same idea for the one-time grant, and it exists
for a blunter reason: every permission this app can add to somebody's machine
has to be removable from inside it, or the honest instruction would be "run
`icacls`".
