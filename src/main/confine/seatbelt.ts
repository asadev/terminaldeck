/**
 * The macOS half: a plan, written as a Seatbelt profile.
 *
 * ## Is this thing still real?
 *
 * `sandbox-exec(1)` has carried a deprecation notice for years and the profile
 * language has never been documented. That is a reason to *measure* it, not a
 * reason to assume it is decorative. Measured on macOS 27.0 (build 26A5388g,
 * arm64), every claim below was produced by running the command and reading what
 * happened, not by reading a manual page:
 *
 *   - A `(deny default)` profile with an explicit allow list confines a real
 *     `zsh -l` running under a real pty. `cat` of the owner's `~/.gitconfig`,
 *     `ls` of the owner's home, `ls /Users`, writes to `/tmp` and writes to the
 *     owner's home all return `Operation not permitted`.
 *   - The confinement is inherited. A grandchild — `sh -c 'sh -c "cat …"'` — is
 *     refused exactly as the shell is.
 *   - It cannot be loosened from inside. `sandbox-exec -p '(allow default)'`
 *     under it fails with `sandbox_apply: Operation not permitted`.
 *   - The classic escapes do not work from inside it. `open -a Calculator` fails
 *     in LaunchServices with error -54; an AppleEvent to a *running* Terminal
 *     comes back "Application isn’t running (-600)" because the sandboxed
 *     process cannot reach the LaunchServices database that would find it;
 *     `osascript`'s `do shell script` forks in-sandbox and is refused like
 *     anything else; `launchctl submit` writes nothing.
 *   - The keychain is closed. `security find-generic-password -s 'Claude
 *     Code-credentials'` returns the item outside the sandbox and does not find
 *     it inside — the owner's agent login is not readable from a confined
 *     session, which is the leak that mattered most on this machine.
 *   - Symlinks are resolved before the rule is applied, in both directions. A
 *     link inside the folder pointing at the owner's home is refused; a hard
 *     link cannot even be created.
 *   - `sudo` will not exec at all, so a setuid binary is not a way out.
 *   - Typing into another terminal with `TIOCSTI` fails — and fails *outside*
 *     the sandbox too, because macOS refuses it regardless. Worth writing down
 *     as a thing that is closed by the operating system rather than by this
 *     file, so nobody credits the profile with it.
 *
 * ## What still gets out, said plainly
 *
 * **Metadata.** `file-read-metadata` is allowed everywhere, so a session can
 * `stat` a path it already knows and learn that it exists and how big it is. It
 * cannot list a directory and cannot read a byte of content — `ls /Users/apple`
 * is refused while `stat /Users/apple/.ssh` succeeds. It is allowed because
 * without it the loader cannot follow the symlink chain that leads to an agent
 * CLI installed under the home directory, and `execvp` fails outright. Existence
 * disclosure in exchange for the CLIs running is the trade, and it is a trade,
 * not a free lunch.
 *
 * **The network.** Fully open. A confined session can reach anything this
 * machine can reach, so whatever it *can* read it can also send somewhere. The
 * boundary is about which files it can read, not about where the bytes go —
 * closing the network would stop `git push`, `npm install` and every agent CLI,
 * which is the whole product.
 *
 * **The tools themselves.** Every directory in the plan's readable list is
 * readable, and one of them may be a prefix under the account's home if that is
 * where a CLI was installed. `plan.ts` says exactly which and why.
 *
 * **Anything the kernel gets wrong.** This is a sandbox implemented by Apple and
 * it has had holes before. It is one layer over the layer that was already
 * there — pairing plus a person approving the device — and it is not a promise
 * that a determined attacker with a shell cannot get out.
 *
 * ## Two details that cost a day each
 *
 * 1. **`(allow file-read* (literal "/"))`** — the root *directory*, not a
 *    subpath. Without it `node` dies in `InitializeOncePerProcessInternal` with
 *    SIGABRT and prints nothing. Nothing else tested needed it. It is not
 *    optional and it grants nothing beyond listing `/`.
 * 2. **The `xcrun_db` rule.** `/usr/bin/git` on a Mac is a shim that caches the
 *    real tool's location in the per-account temp directory, found through
 *    `confstr(_CS_DARWIN_USER_TEMP_DIR)` — which `TMPDIR` does not move.
 *    Without a rule for it, *every* git command prints two lines of
 *    `couldn't create cache file … Operation not permitted` before doing its
 *    job. Rather than open that shared directory, only files whose name starts
 *    `xcrun_db` are allowed in it. Verified: the noise goes, and listing that
 *    directory or writing any other name in it is still refused.
 */

import type { ConfinementPlan } from './plan'

/**
 * A path, as a Seatbelt string literal.
 *
 * Not decoration. A folder called `q"uote` produces
 * `sandbox-exec: unbound variable` and exit 65 — the profile fails to parse, so
 * nothing starts. That fails in the safe direction, but it fails for a person
 * whose folder is named legally, so both characters that can end a literal early
 * are escaped. Verified against folders named `q"uote`, `back\slash`, `ap'os`,
 * `sp ace`, `semi;colon` and `paren(x)`: each one could be written to from
 * inside while a write outside it was still refused.
 *
 * Backslash first, or the backslash introduced by escaping a quote would itself
 * be escaped a second time.
 */
export function seatbeltString(path: string): string {
  return `"${path.split('\\').join('\\\\').split('"').join('\\"')}"`
}

/**
 * Files in the per-account temp directory that the Xcode tool shim may use.
 *
 * A regular expression rather than a subpath because the directory itself must
 * stay closed: it is shared with every other program the account runs. The
 * pattern is anchored at both ends so it can match nothing but that shim's own
 * cache — `xcrun_db`, or `xcrun_db-` and the random suffix it writes before
 * renaming.
 */
const XCRUN_CACHE = String.raw`^/private/var/folders/[^/]+/[^/]+/T/xcrun_db(-[A-Za-z0-9]+)?$`

/**
 * The profile for one plan.
 *
 * Read it top to bottom: everything is denied, then the operations a process
 * needs to exist are allowed, then the filesystem is opened one directory at a
 * time. Nothing here is conditional on anything, which is deliberate — a profile
 * with a branch in it is a profile whose weaker half nobody has run.
 */
export function seatbeltProfile(plan: ConfinementPlan): string {
  const lines: string[] = [
    '(version 1)',
    '',
    '; Everything is refused unless a rule below allows it. Denials are logged',
    '; rather than silenced, because the first question about a session that',
    '; will not start is which rule stopped it.',
    '(deny default)',
    '',
    '; A process has to be able to be a process. `process-exec` is unfiltered on',
    '; purpose: the session is a shell and the point of a shell is running',
    '; things, and every child it starts inherits this profile anyway — proven',
    '; by a grandchild being refused the same file the shell was.',
    '(allow process-exec)',
    '(allow process-fork)',
    '(allow sysctl-read)',
    '(allow ipc-posix-shm)',
    '',
    '; Only its own processes. `process-info*` unfiltered would let a session',
    '; read every other process\'s command line, and a command line is where a',
    '; token ends up when somebody passes one as an argument. `ps` showing less',
    '; than usual is the price and it is worth paying.',
    '(allow process-info* (target self))',
    '(allow signal (target self))',
    '',
    '; Job control needs this and it was checked rather than assumed: with a real',
    '; pty in front of a real `zsh -l`, Ctrl-C during `sleep 30` returns the',
    '; prompt and the next command runs.',
    '',
    '; The network is open. See the header — this boundary is about which files',
    '; a session can read, not about where bytes may go.',
    '(allow network*)',
    '(allow system-socket)',
    '',
    '; Mach services, minus the ones that are a way out of the sandbox by asking',
    '; another process to act on your behalf. AppleEvents and LaunchServices are',
    '; the classic pair; the keychain and the security agent are here because a',
    '; confined session must not be able to ask for the owner\'s stored logins.',
    '(allow mach-lookup)',
    '(deny mach-lookup',
    '  (global-name "com.apple.coreservices.appleevents")',
    '  (global-name "com.apple.coreservices.launchservicesd")',
    '  (global-name "com.apple.lsd.open")',
    '  (global-name "com.apple.lsd.modifydb")',
    '  (global-name "com.apple.SecurityServer")',
    '  (global-name "com.apple.securityd.xpc")',
    '  (global-name "com.apple.security.agent"))',
    '',
    '; Stat, anywhere. Without it the loader cannot follow a symlink to an agent',
    '; CLI installed under the home directory and `execvp` fails. It reveals that',
    '; a known path exists; it does not list a directory or read a byte.',
    '(allow file-read-metadata)',
    '',
    '; The root directory itself. Node aborts at startup without it.',
    '(allow file-read* (literal "/"))',
    '',
    '; The terminal. A session without this has no pty to write to.',
    '(allow file-read* (subpath "/dev"))',
    '(allow file-write* (subpath "/dev"))',
    '',
    '; And the ioctls on it, which is not the same permission and was found the',
    '; expensive way. `tcsetpgrp` is an ioctl, so without this a login shell',
    '; prints "can\'t set tty pgrp: operation not permitted" — twice — at the top',
    '; of every session, and only under the sandbox. Confirmed by running the',
    '; same `zsh -l` on the same pty with and without the profile.',
    ';',
    '; Scoped to /dev rather than allowed everywhere. It does not open the raw',
    '; disks — `/dev/disk0` is root:operator 0640, so the account cannot read it',
    '; with or without a sandbox — and it does not open TIOCSTI, which macOS',
    '; itself refuses: typing into another terminal fails with EPERM outside the',
    '; sandbox exactly as it does inside, checked against a second pty rather',
    '; than assumed.',
    '(allow file-ioctl (subpath "/dev"))',
    '',
    '; The Xcode tool shim\'s cache, and nothing else in that shared directory.',
    `(allow file-read* file-write* (regex #${seatbeltString(XCRUN_CACHE)}))`,
    '',
    '; The operating system and the tools. Read only: a confined session cannot',
    '; modify the machine it is running on.',
  ]

  for (const root of plan.readable) lines.push(`(allow file-read* (subpath ${seatbeltString(root)}))`)

  if (plan.readableFiles.length > 0) {
    lines.push(
      '',
      '; Single files whose directory must stay closed. The credential helper is',
      '; the reason this list exists: it sits beside every other device\'s guest',
      '; git directory, and granting its folder would hand one device another',
      '; device\'s git identity.',
    )
    for (const file of plan.readableFiles) {
      lines.push(`(allow file-read* (literal ${seatbeltString(file)}))`)
    }
  }

  lines.push(
    '',
    '; The granted folder, and the session\'s own state. This is the whole of',
    '; what a confined session may change.',
  )
  for (const root of plan.writable) {
    lines.push(`(allow file-read* file-write* (subpath ${seatbeltString(root)}))`)
  }

  lines.push('')
  return lines.join('\n')
}

/**
 * The command that starts a confined process, given the one that would have
 * started an unconfined one.
 *
 * The profile travels as an argument rather than in a file, and that is a
 * decision with a reason: a file has to be written somewhere, read back by
 * `sandbox-exec`, and is replaceable by anything running as this account in the
 * moment between the two. An argument cannot be swapped after the call is made.
 * It is visible in `ps` to the session itself, which is fine — a session reading
 * the rules it is already subject to learns nothing it could act on.
 */
export function seatbeltCommand(
  profile: string,
  command: string,
  args: readonly string[],
): { command: string; args: string[] } {
  return { command: SANDBOX_EXEC, args: ['-p', profile, command, ...args] }
}

/** Where the sandbox launcher lives. Absent from no macOS this app supports. */
export const SANDBOX_EXEC = '/usr/bin/sandbox-exec'
