/**
 * The Linux half: a plan, held by a user namespace and a handful of mounts.
 *
 * ## What holds the fence here, and why it is not the same shape as macOS
 *
 * Seatbelt is deny-by-default: a profile lists what may be touched and the
 * kernel refuses everything else. Linux has no equivalent an unprivileged
 * process can ask for. What it does have — measured on the machine, not read —
 * is an unprivileged **user namespace**, which hands a process a private mount
 * table it may rearrange, and `setpriv`, which throws away the capabilities that
 * would let it rearrange the table back afterwards. So the boundary is built the
 * other way round: the trees that hold the account's secrets are covered with
 * empty `tmpfs`, the handful of directories this session is entitled to are
 * bound back in on top, and then every capability is dropped before the shell
 * starts.
 *
 * That difference is stated here rather than smoothed over, because it decides
 * what the fence does **not** do. A directory the account owns that is outside
 * every covered tree stays readable. On the machines this is for — a home
 * directory, `/tmp`, `/mnt/c` — that set is empty, and `linuxCovers` also covers
 * the granted folder's own parent so a grant on `/srv/app` does not expose
 * `/srv/other`. It is not the same promise as "everything is denied", and the
 * settings copy must not claim it is.
 *
 * ## Measured — 2026-08-16, Ubuntu 24.04 under WSL2, kernel 6.18.33.2
 *
 * `CONFINEMENT.md` records the first pass over ssh: user namespaces are enabled,
 * `bwrap` is absent and needs sudo to install, a `tmpfs` over `/home` with the
 * folder bound back holds, an empty bind over `/mnt` removes every path to a
 * Windows `.exe`, and **dropping the capability bounding set before `exec` is
 * load-bearing** — without it a shell simply runs `umount /home` and reads the
 * canary. None of that is repeated here. What follows is what this file added,
 * all of it run on the same machine, most of it a hole that first pass did not
 * look for.
 *
 * | Attempt | Result |
 * | --- | --- |
 * | `cat ../../.tdprobe-home-canary` — a **relative** path, from the cwd the launcher set | **ESCAPE.** The secret came back, on the native launch and through `wsl.exe --cd` alike. See below; this is the one that would have shipped. |
 * | The same, after the script `cd`s to the folder by absolute path | `No such file or directory`. |
 * | `cat /proc/self/fd/9/secret.txt`, fd 9 opened by the launcher before the spawn | **ESCAPE.** An inherited descriptor is a path out that no mount can cover. |
 * | `kill -TERM <pid of another process this account owns>` | **ESCAPE**, without a PID namespace: `kill -0` permitted, the signal delivered, the process died. `kill -TERM -1` from inside took down the whole login session that launched it. |
 * | The same, with `--pid --fork --mount-proc` | `No such process`; four pids visible in `/proc`; the victim survived. |
 * | `cat /proc/<pid outside the namespace>/root/…` | `Permission denied` — **already closed by the user namespace itself**, before any PID namespace. Credentials in a child user namespace fail `ptrace_may_access` against a process in the parent one. |
 * | A Windows `.exe` **inside the granted folder**, run through the interop binfmt handler | **ESCAPE.** `./cmd.exe /c echo` printed `WINDOWS-RAN` from a confined session. `/mnt` being covered does not close interop; it only removes the paths to Windows' own binaries. |
 * | The same, with `WSL_INTEROP` unset and `/run/WSL` left alone | **STILL AN ESCAPE.** `WINDOWS-RAN` again. The handler finds the socket without the variable. |
 * | The same, with `/run/WSL` covered and the variable left set | Refused: `UtilConnectUnix:535: connect failed 2`. |
 * | Both | Refused. |
 * | `unshare --user --map-current-user` instead of `--map-root-user` | `mount: must be superuser to use mount`. A non-root euid loses every capability at `exec`, so the mounts cannot be made at all. The session is uid 0 **inside its own namespace**; outside it is the ordinary account. |
 * | A nested user namespace to get the capabilities back | `write failed /proc/self/uid_map: Operation not permitted`, and with an ordinary uid mapped, `setpriv: apply bounding set: Operation not permitted` — the nested route cannot drop what it would need to drop. |
 * | `git`, `node`, `npm`, `claude --version` inside | All work. The agent CLI reports `2.1.224` as uid 0 and does not refuse. |
 * | A real pty (`script`), `bash -l`, `sleep 30`, Ctrl-C, next command | Works, with and without the PID namespace: the login shell starts, the canary is refused, a write inside the folder lands, and the interrupt returns the prompt. |
 * | `/etc/resolv.conf` after `/mnt` is covered | **Broke the session.** On WSL it is a symlink to `/mnt/wsl/resolv.conf`, so covering `/mnt` left DNS dead: `getent hosts github.com` empty, `curl` `000`, `git ls-remote` refused. Hence {@link resolvKeep}. |
 *
 * ### The escape that would have shipped
 *
 * The launcher sets the child's working directory *before* the namespace exists,
 * so the shell starts on a `(vfsmount, dentry)` pair belonging to the tree that
 * is about to be covered. Every absolute path then resolves through the new
 * mounts and looks perfect — `pwd` is right, `readlink /proc/self/cwd` is right,
 * `cd .. && ls` shows only what the boundary allows, because a shell tracks `..`
 * as a *string*. Hand a **relative** path to any program and the kernel walks
 * the real parent instead: `cat ../../.tdprobe-home-canary` returned the secret.
 * A test that only checked `cd ..` and `ls` would have passed. The fix is one
 * line — the script `cd`s to the folder by absolute path once the mounts are in
 * place — and the reason it is in the script rather than left to the caller is
 * that no caller can do it: the directory has to be re-resolved *after* the
 * covering, inside the namespace.
 *
 * ## What is deliberately still open
 *
 * - **The network**, exactly as on macOS. Closing it would stop `git push`,
 *   `npm install` and every agent CLI.
 * - **A socket outside the covered trees.** `SSH_AUTH_SOCK` is unset and the
 *   usual homes for an agent socket (`/tmp`, `/run/user/<uid>`) are covered, but
 *   an agent listening somewhere else is reachable by a session that knows the
 *   path.
 * - **Descriptors above 9.** The script closes 3 through 9, which is every
 *   descriptor a POSIX `sh` can name. Node marks its own descriptors
 *   close-on-exec, so nothing was observed leaking; a launcher that deliberately
 *   passed a high descriptor would pass a hole with it.
 * - **`/proc/self/mountinfo`** names the paths that were covered. It discloses
 *   the shape of the boundary, not the contents of anything behind it.
 * - **Writes to a covered tree** land in that session's private `tmpfs` and are
 *   gone when it ends. `HOME` points at the device's own directory, which is
 *   bound back in and persists; a file written to some other covered path does
 *   not, and nothing warns about it.
 */

import { existsSync, realpathSync } from 'node:fs'
import { posix } from 'node:path'
import { shellCommandLine } from '../wsl'
import { collapse, within, type ConfinementPlan } from './plan'

/**
 * Trees that are never covered, whatever a plan asks for.
 *
 * The fixed list below is allowed inside them — `/tmp` and `/var/tmp` are under
 * `/var`'s neighbourhood by spelling and are the account's scratch space by
 * purpose — but a cover *derived* from a granted folder is refused if it lands
 * in here. Without the rule, a grant on `/usr/local/src/proj` would cover
 * `/usr/local` and take `/usr/local/bin` and `/usr/local/lib` with it, and the
 * session would lose the tools rather than the secrets.
 *
 * `/nix` is on the list for the same reason as `/usr`: on a NixOS machine every
 * binary in the session is a symlink into it.
 */
export const LINUX_SYSTEM_ROOTS: readonly string[] = [
  '/usr',
  '/bin',
  '/sbin',
  '/lib',
  '/lib32',
  '/lib64',
  '/libx32',
  '/etc',
  '/opt',
  '/var',
  '/run',
  '/proc',
  '/sys',
  '/dev',
  '/boot',
  '/snap',
  '/nix',
]

/**
 * The machine, as this file needs to see it.
 *
 * Injected for the reason `platform/host.ts` argues at length: none of these
 * questions can be asked on the Mac this is written on, and a branch that can
 * only be exercised on the machine it was written on is a branch whose first
 * user finds the bug. `uid` is the account's, and it is needed because the
 * runtime directory holding the keyring and agent sockets is named after it.
 */
export interface LinuxMachine {
  exists(path: string): boolean
  /** `fs.realpathSync`, or a fake. Must return the input when it cannot resolve. */
  real(path: string): string
  uid: number
}

export const realMachine: LinuxMachine = {
  exists: (path) => existsSync(path),
  real: (path) => {
    try {
      return realpathSync(path)
    } catch {
      return path
    }
  },
  // `process.getuid` is absent on Windows, which is not a hypothetical here: the
  // Windows build computes a Linux plan for a session inside WSL. `-1` cannot
  // name a real runtime directory, and `linuxCovers` drops it rather than
  // emitting `/run/user/-1` for something to fail on later.
  uid: process.getuid?.() ?? -1,
}

/** Is this directory inside a tree that must never be covered? */
function isSystem(path: string): boolean {
  return LINUX_SYSTEM_ROOTS.some((root) => within(path, root, 'linux'))
}

/**
 * The directory whose contents a cover would hide, for one the session owns.
 *
 * The parent, when covering the parent is safe, and the directory itself
 * otherwise. `/home/asad` answers `/home` — which hides every *other* account's
 * home on a shared box as well, and this machine has three. `/root` answers
 * `/root`, because its parent is `/`. Anything under `/usr` answers itself,
 * because {@link LINUX_SYSTEM_ROOTS} refuses the parent.
 */
function coverFor(dir: string): string | null {
  if (dir === '' || !dir.startsWith('/') || dir === '/') return null
  if (isSystem(dir)) return dir
  const parent = posix.dirname(dir)
  return parent === '/' || parent === dir || isSystem(parent) ? dir : parent
}

/**
 * Every tree this session should not be able to see, for one plan.
 *
 * Four sources, and each one is a place a secret was actually found rather than
 * a place one might be:
 *
 *  - **The account's home.** `~/.ssh`, `~/.gitconfig`, `~/.config/gh`,
 *    `~/.claude` and every other device's granted folder live here.
 *  - **`/tmp` and `/var/tmp`.** Shared with every other program the account
 *    runs, which is where an ssh-agent socket goes when it is not in the
 *    runtime directory.
 *  - **`/mnt`.** Under WSL this is the whole Windows filesystem, mounted with
 *    `uid=1000`, so `/mnt/c/Users/<name>` is the owner's Windows profile — and
 *    it is also every path to a Windows `.exe`.
 *  - **`/run/user/<uid>` and `/run/WSL`.** The keyring, the gpg-agent socket,
 *    and the interop socket that asks Windows to start a process with the
 *    user's full privileges. `/run/WSL` is the load-bearing one: measured, a
 *    Windows binary inside the granted folder still ran with `WSL_INTEROP`
 *    unset, and stopped the moment that directory was covered.
 *
 * Directories that are not there are dropped rather than emitted, because a
 * `mount` on a missing target fails and this script refuses the session when a
 * mount fails.
 *
 * `collapse` is not tidiness here, it is the difference between working and
 * not. Measured on the machine, with the first version of this function: a
 * folder under the home directory produced both `/home` and
 * `/home/asad/.tdreal` as covers, `/home` went on first, and the second one
 * then failed with `mount: /home/asad/.tdreal: mount point does not exist` —
 * because by then it did not. The session was refused, which is the right
 * failure, but it was refused on every machine where the granted folder is
 * where granted folders normally are.
 */
export function linuxCovers(plan: ConfinementPlan, machine: LinuxMachine): string[] {
  const wanted: string[] = []
  const home = coverFor(machine.real(plan.accountHome))
  if (home !== null) wanted.push(home)
  wanted.push('/tmp', '/var/tmp', '/mnt')
  if (machine.uid >= 0) wanted.push(`/run/user/${machine.uid}`)
  wanted.push('/run/WSL')
  // The granted folder's own parent, so a grant outside the home directory
  // still hides its neighbours. Inside the home it is already covered and drops
  // out as a duplicate.
  const beside = coverFor(machine.real(plan.folder))
  if (beside !== null) wanted.push(beside)

  return collapse(
    wanted.filter((dir) => machine.exists(dir)),
    'linux',
  )
}

/** One directory or file that has to survive being covered. */
export interface LinuxKeep {
  path: string
  mode: 'rw' | 'ro' | 'file'
}

/**
 * Everything in the plan that a cover would have swallowed, in the order it
 * must be staged and restored.
 *
 * Only what a cover would swallow. A tool root under `/usr` needs no rule
 * because nothing hides it; emitting one anyway would add a mount for every
 * entry on the `PATH` and make `/proc/self/mountinfo` unreadable for the person
 * who one day has to answer "what can this session see".
 *
 * The `resolv.conf` entry is not from the plan and is the reason this function
 * takes the machine as well: on WSL, `/etc/resolv.conf` is a symlink into
 * `/mnt/wsl`, so covering `/mnt` left a session with no DNS at all — `curl`
 * answering `000` and `git ls-remote` refusing to connect. It is resolved
 * rather than hard-coded, so a distribution that keeps it somewhere else gets
 * the same treatment and one that keeps it in `/etc` gets no rule.
 */
export function linuxKeeps(
  plan: ConfinementPlan,
  covers: readonly string[],
  machine: LinuxMachine,
): LinuxKeep[] {
  const hidden = (path: string): boolean => covers.some((root) => within(path, root, 'linux'))
  const keeps: LinuxKeep[] = []
  const seen = new Set<string>()
  const add = (path: string, mode: LinuxKeep['mode']): void => {
    if (!hidden(path) || seen.has(path) || !machine.exists(path)) return
    seen.add(path)
    keeps.push({ path, mode })
  }

  // Writable first, so that a directory named by both lists is restored
  // writable rather than read-only.
  for (const dir of plan.writable) add(dir, 'rw')
  for (const dir of plan.readable) add(dir, 'ro')
  for (const file of plan.readableFiles) add(file, 'file')
  const resolv = resolvKeep(machine)
  if (resolv !== null) add(resolv, 'file')
  return keeps
}

/**
 * Where this machine really keeps `/etc/resolv.conf`, when that is somewhere a
 * cover would hide.
 *
 * Exported so the test can say what it is checking. Returns null when the file
 * is an ordinary one in `/etc`, which is the case everywhere but WSL.
 */
export function resolvKeep(machine: LinuxMachine): string | null {
  const real = machine.real('/etc/resolv.conf')
  return real === '/etc/resolv.conf' ? null : real
}

/* -------------------------------------------------------------- the script -- */

/**
 * The script that builds the boundary, run by `sh` inside the new namespaces.
 *
 * A constant with no interpolation, exactly like `LOGIN_SHELL_SCRIPT` in
 * `wsl.ts` and for the same reason: everything that varies arrives as a
 * positional argument, so the quoting is one level deep and a folder named
 * `back\slash` or `q"uote` cannot change what the script *does*. The plan is a
 * list of `<tag>:<path>` words ended by `--`, and the command follows.
 *
 *   `S:` the staging directory. First, and made with `mkdir` rather than
 *        `mkdir -p` so that a name somebody else got to first is a refusal
 *        rather than a shared directory.
 *   `D:` where to `cd` once the mounts are in place. See the header: this is
 *        the line that closes the relative-path escape.
 *   `C:` cover with an empty `tmpfs`.
 *   `L:` cover last — the one whose tree the staging directory is inside.
 *   `W:` bind back, read-write.
 *   `R:` bind back, read-only.
 *   `F:` bind back a single file, read-only.
 *
 * The order is the whole trick and cannot be rearranged: a directory cannot be
 * bound back *after* the thing it lives in has been covered, because by then
 * there is no path to it. So everything that must survive is bound into the
 * staging area first, the covers go on, the staged copies are bound into place,
 * the staging area is unmounted, and only then is the tree the staging area
 * lived in covered too.
 *
 * `set -e` is not tidiness either. A cover that silently failed would leave the
 * account's home in plain view inside a session the app had already called
 * confined, which is precisely the shape of failure this project keeps being
 * bitten by — the side reporting success not being the side doing the work. Any
 * failure here refuses the session.
 */
export const LINUX_CONFINE_SCRIPT = `
set -eu

td_clean() {
  # Best effort, and deliberately incapable of recursion: \`rmdir\` and \`rm -f\`
  # remove an empty directory and a plain file and nothing else, so a mount that
  # refused to come apart is left alone rather than descended into. The two
  # guards are what stop an empty or shallow \`td_stage\` from turning this into a
  # loop over \`/*\`.
  [ -n "$td_stage" ] || return 0
  case "$td_stage" in
    /*/*) ;;
    *) return 0 ;;
  esac
  [ -d "$td_stage" ] || return 0
  for td_c in "$td_stage"/*; do
    [ -e "$td_c" ] || continue
    umount -R "$td_c" 2>/dev/null || umount -l "$td_c" 2>/dev/null || true
    rmdir "$td_c" 2>/dev/null || rm -f "$td_c" 2>/dev/null || true
  done
  rmdir "$td_stage" 2>/dev/null || true
  return 0
}

td_fail() {
  # Cleaned up on the way out too. A machine that refuses these namespaces
  # refuses them every time, and without this it would collect one abandoned
  # staging directory per attempt — which is exactly what the first run of this
  # script did before the cover order was right.
  td_clean
  printf '%s\\n' "terminaldeck: confinement failed: $1" >&2
  exit 91
}

td_plan=0
for td_entry in "$@"; do
  if [ "$td_entry" = "--" ]; then break; fi
  td_plan=$((td_plan + 1))
done

td_stage=
td_cwd=

# 1. hold on to everything that must survive being covered
td_i=0
td_n=0
for td_entry in "$@"; do
  td_i=$((td_i + 1))
  if [ "$td_i" -gt "$td_plan" ]; then break; fi
  td_tag=\${td_entry%%:*}
  td_path=\${td_entry#*:}
  case "$td_tag" in
    S)
      td_stage=$td_path
      mkdir -m 700 "$td_stage" || td_fail "could not make $td_path"
      ;;
    D)
      td_cwd=$td_path
      ;;
    W|R)
      td_n=$((td_n + 1))
      mkdir "$td_stage/$td_n" || td_fail "could not make $td_stage/$td_n"
      mount --rbind "$td_path" "$td_stage/$td_n" || td_fail "could not hold on to $td_path"
      ;;
    F)
      td_n=$((td_n + 1))
      : > "$td_stage/$td_n" || td_fail "could not make $td_stage/$td_n"
      mount --bind "$td_path" "$td_stage/$td_n" || td_fail "could not hold on to $td_path"
      ;;
  esac
done

# 2. cover
td_i=0
for td_entry in "$@"; do
  td_i=$((td_i + 1))
  if [ "$td_i" -gt "$td_plan" ]; then break; fi
  case "$td_entry" in
    C:*)
      td_path=\${td_entry#*:}
      mount -t tmpfs -o nosuid,nodev tmpfs "$td_path" || td_fail "could not hide $td_path"
      ;;
  esac
done

# 3. put back what this session is entitled to
td_i=0
td_n=0
for td_entry in "$@"; do
  td_i=$((td_i + 1))
  if [ "$td_i" -gt "$td_plan" ]; then break; fi
  td_tag=\${td_entry%%:*}
  td_path=\${td_entry#*:}
  case "$td_tag" in
    W)
      td_n=$((td_n + 1))
      mkdir -p "$td_path" || td_fail "could not make $td_path"
      mount --rbind "$td_stage/$td_n" "$td_path" || td_fail "could not restore $td_path"
      ;;
    R)
      td_n=$((td_n + 1))
      mkdir -p "$td_path" || td_fail "could not make $td_path"
      mount --rbind "$td_stage/$td_n" "$td_path" || td_fail "could not restore $td_path"
      mount -o remount,bind,ro "$td_path" || td_fail "could not seal $td_path"
      ;;
    F)
      td_n=$((td_n + 1))
      mkdir -p "\${td_path%/*}" || td_fail "could not make \${td_path%/*}"
      : > "$td_path" || td_fail "could not make $td_path"
      mount --bind "$td_stage/$td_n" "$td_path" || td_fail "could not restore $td_path"
      mount -o remount,bind,ro "$td_path" || td_fail "could not seal $td_path"
      ;;
  esac
done

# 4. take the staging area apart, so nothing can walk back through it
td_clean

# 5. and only now cover the tree the staging area was in
td_i=0
for td_entry in "$@"; do
  td_i=$((td_i + 1))
  if [ "$td_i" -gt "$td_plan" ]; then break; fi
  case "$td_entry" in
    L:*)
      td_path=\${td_entry#*:}
      mount -t tmpfs -o nosuid,nodev tmpfs "$td_path" || td_fail "could not hide $td_path"
      ;;
  esac
done

# 5b. and now ask the question that matters, rather than trusting step 4's exit
#     codes: is there any path left to the staging area at all? It held a bind
#     of the account's home a moment ago.
if [ -n "$td_stage" ] && [ -e "$td_stage" ]; then
  td_fail "the staging area is still reachable at $td_stage"
fi

# 6. leave the pre-mount working directory behind, or every relative path in the
#    session walks straight out through it
if [ -n "$td_cwd" ]; then
  cd "$td_cwd" || td_fail "could not enter $td_cwd"
fi

# 7. the doors that are not filesystem paths
unset WSL_INTEROP
unset SSH_AUTH_SOCK
exec 3<&- 4<&- 5<&- 6<&- 7<&- 8<&- 9<&-

shift "$td_plan"
shift
command -v setpriv >/dev/null 2>&1 || td_fail "setpriv is not installed"
exec setpriv --no-new-privs --bounding-set=-all --inh-caps=-all -- "$@"
`

/** `$0` for the script above. Only ever seen at the front of its own error. */
const SCRIPT_NAME = 'terminaldeck-confine'

/**
 * The namespaces, and why each one is there.
 *
 * `--user` is what makes any of this possible without sudo, and
 * `--map-root-user` is not a convenience: measured, `--map-current-user` loses
 * every capability at the `exec` that follows, so the mounts cannot be made at
 * all. The session is uid 0 **inside its own namespace** and the ordinary
 * account outside it, which is what `ls -l` on the host shows.
 *
 * `--mount` with `--propagation=private` keeps the covering inside the session:
 * without it the mounts propagate to the machine and the *owner's* `/home` goes
 * blank.
 *
 * `--pid --fork --mount-proc` is the one that is not about files. Measured on
 * the machine: without it a confined session sent SIGTERM to a process of the
 * account's outside the boundary and killed it, and `kill -TERM -1` from inside
 * took down the login session that had launched it. With it the same signal
 * answers "No such process". `--fork` is required — the first process in a PID
 * namespace has to be a child — and `--mount-proc` is what makes `/proc` list
 * that namespace instead of the machine.
 */
const NAMESPACE_ARGS: readonly string[] = [
  '--user',
  '--map-root-user',
  '--mount',
  '--propagation=private',
  '--pid',
  '--fork',
  '--mount-proc',
]

/**
 * Where `unshare` is, or its bare name.
 *
 * Absolute when this process can see the file, which is the native Linux case.
 * The bare name otherwise, which is the Windows build computing a plan for a
 * session inside WSL: the file is on the other side of the boundary, nothing
 * here can stat it, and the login shell over there resolves it from `PATH`.
 * `setpriv` is not resolved at all for the same reason — the script checks for
 * it with `command -v` on the far side, where the answer is knowable.
 */
export function unsharePath(machine: LinuxMachine = realMachine): string {
  for (const candidate of ['/usr/bin/unshare', '/bin/unshare']) {
    if (machine.exists(candidate)) return candidate
  }
  return 'unshare'
}

/**
 * The plan, as the words the script parses.
 *
 * `stage` is random per session and comes from the caller rather than from `$$`
 * inside the script, because with a PID namespace `$$` is always 1: the name
 * would be `/tmp/…-1` every time, and anything else running as this account
 * could sit on it and refuse every session.
 */
export function linuxSpec(
  plan: ConfinementPlan,
  machine: LinuxMachine,
  stage: string,
): string[] {
  const covers = linuxCovers(plan, machine)
  const keeps = linuxKeeps(plan, covers, machine)
  const words = [`S:${stage}`, `D:${machine.real(plan.folder)}`]
  for (const cover of covers) {
    // The tree the staging area lives in is covered last, after the staged
    // copies have been bound into place and unmounted. Anything else and the
    // staging area disappears half way through building the boundary.
    words.push(`${within(stage, cover, 'linux') ? 'L' : 'C'}:${cover}`)
  }
  for (const keep of keeps) {
    words.push(`${keep.mode === 'rw' ? 'W' : keep.mode === 'ro' ? 'R' : 'F'}:${keep.path}`)
  }
  return words
}

/**
 * The staging directory for one session.
 *
 * In `/tmp` because it is the one place an unprivileged account can certainly
 * create a directory, and because `/tmp` is covered — so even if the unmounting
 * in step 4 were to fail, the staged binds end up underneath a `tmpfs` with no
 * path leading to them.
 */
export function stagePath(token: string): string {
  return `/tmp/.terminaldeck-confine-${token}`
}

/**
 * The command that starts a confined session, given the one that would have
 * started an unconfined one.
 *
 * The mirror of `seatbeltCommand`, and like it the whole plan travels as
 * arguments rather than in a file: a file has to be written, read back, and is
 * replaceable by anything running as this account in the moment between the
 * two.
 */
export function linuxCommand(
  plan: ConfinementPlan,
  command: string,
  args: readonly string[],
  machine: LinuxMachine,
  stage: string,
): { command: string; args: string[] } {
  return {
    command: unsharePath(machine),
    args: [
      ...NAMESPACE_ARGS,
      '/bin/sh',
      '-c',
      LINUX_CONFINE_SCRIPT,
      SCRIPT_NAME,
      ...linuxSpec(plan, machine, stage),
      '--',
      command,
      ...args,
    ],
  }
}

/**
 * The same thing as one line for a shell to read, which is how a session inside
 * WSL is started.
 *
 * The Windows build does not spawn a Linux process; it spawns `wsl.exe`, which
 * hands a command line to the distribution's login shell (`wsl.ts` explains why
 * it has to be the login shell). So the confinement for that path has to arrive
 * as text that shell can run, and it must be the *same* text — built from the
 * same script and the same argument list — or the boundary that was measured
 * and the boundary that ships are two different things.
 *
 * `exec` so that no shell is left sitting between the pty and the session.
 */
export function linuxShellLine(
  plan: ConfinementPlan,
  command: string,
  args: readonly string[],
  machine: LinuxMachine,
  stage: string,
): string {
  const launch = linuxCommand(plan, command, args, machine, stage)
  return shellCommandLine(['exec', launch.command, ...launch.args])
}

/* --------------------------------------------------------------- the proof -- */

/**
 * The script the proof runs, on both sides of the boundary.
 *
 * One script rather than two, because the only honest way to know that a canary
 * proves anything is to read it with the *same command* from outside the
 * boundary and watch it come back. A file that is unreadable everywhere — a
 * path that does not exist, a directory the plan never covered, a canary
 * planted on the Windows side of a session that runs inside WSL — would
 * otherwise pass the test by failing at everything, which is the exact shape of
 * false confidence `seatbelt.ts` guards against with its `echo` probe.
 *
 * `$1` is the mode: `plant` writes the two canaries and then reports, `read`
 * only reports, `clean` removes them. The secrets travel as arguments and are
 * therefore visible in `ps` to this account — they are random, worth nothing,
 * and thrown away a moment later, the same trade the Seatbelt profile makes by
 * travelling as an argument.
 */
export const LINUX_PROOF_SCRIPT = `
if [ "$1" = plant ]; then
  ( umask 077; printf '%s' "$5" > "$3" ) || exit 3
  ( umask 077; printf '%s' "$6" > "$4" ) || exit 3
fi
if [ "$1" = clean ]; then
  rm -f "$3" "$4" 2>/dev/null
  exit 0
fi
printf 'td-token %s\\n' "$2"
printf 'td-home %s\\n' "$(cat "$3" 2>/dev/null)"
printf 'td-tmp %s\\n' "$(cat "$4" 2>/dev/null)"
printf 'td-interop %s\\n' "\${WSL_INTEROP:-none}"
printf 'td-runwsl %s\\n' "$(ls -A /run/WSL 2>/dev/null | head -n 1)"
printf 'td-uid %s\\n' "$(id -u)"
`

/** What the proof asks about, wherever it is asked from. */
export interface LinuxProofReport {
  token: string
  /** What the account-home canary read back as. Empty when it was refused. */
  home: string
  /** What the `/tmp` canary read back as. */
  tmp: string
  /** `none` when the interop variable is unset. */
  interop: string
  /** The first entry in `/run/WSL`, or empty when it is gone or empty. */
  runwsl: string
  uid: string
}

/** Read the report back. Absent lines are empty strings, never undefined. */
export function readProofReport(text: string): LinuxProofReport {
  const field = (name: string): string => {
    for (const line of text.split('\n')) {
      const head = `td-${name} `
      if (line.startsWith(head)) return line.slice(head.length).trim()
    }
    return ''
  }
  return {
    token: field('token'),
    home: field('home'),
    tmp: field('tmp'),
    interop: field('interop'),
    runwsl: field('runwsl'),
    uid: field('uid'),
  }
}

/** The arguments for one run of the proof script, confined or not. */
export function linuxProofArgs(input: {
  mode: 'plant' | 'read' | 'clean'
  token: string
  homeCanary: string
  tmpCanary: string
  homeSecret: string
  tmpSecret: string
}): string[] {
  return [
    '-c',
    LINUX_PROOF_SCRIPT,
    'terminaldeck-proof',
    input.mode,
    input.token,
    input.homeCanary,
    input.tmpCanary,
    input.homeSecret,
    input.tmpSecret,
  ]
}

/** The shell the proof's unconfined half runs in. Present on every Linux. */
export const LINUX_SHELL = '/bin/sh'
