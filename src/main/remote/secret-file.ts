/**
 * Writing a file that must not be half-written and must not be readable.
 *
 * Five files in this app hold something an attacker wants: `remote-auth.json`
 * (the devices allowed to reach a shell), `relay-identity.json` (this machine's
 * X25519 private key), `machines.json` (a plaintext bearer credential per paired
 * machine), `github/auth.json` (the user's GitHub token) and `host.json` (the
 * headless daemon's control token, which is enough to run `pair` and `stop`).
 * `folder-grants.json` is written through here too and is *not* a secret — it
 * comes for the atomicity, and its own header says so.
 *
 * All of them have the same requirements, and each one used to be a hand-rolled
 * copy of the dance below — the second copy is how two of them eventually
 * disagree about which of the steps were the important ones.
 *
 * They are all important, and each is here because of a specific way the
 * obvious version fails:
 *
 *  - **A leftover temp file is removed rather than written through.** `w`
 *    follows a symlink, and this is where credential hashes and a private key
 *    land. `wx` after the unlink means the open either creates the file or
 *    fails.
 *  - **The write is looped.** A single `write` is allowed to come up short — on
 *    a full disk it reports the bytes it managed rather than failing — and a
 *    trust file that stops halfway is one that will not parse on the next start.
 *  - **The bytes are fsynced before the name moves.** `rename` is atomic in
 *    ordering, not in durability: on APFS the directory entry can land while the
 *    bytes behind it are still in cache, so a power cut straight after a revoke
 *    can come back up with the device still trusted. That is the one failure
 *    these files promise does not happen.
 *  - **The mode is set explicitly, twice.** `mode` on `open` applies only when
 *    the file is created and is masked by umask.
 *  - **The directory is fsynced too**, for the same reason as the file, and its
 *    failure is ignored because not every filesystem lets a directory be synced.
 *  - **The temp name carries the pid.** Two windows writing at once must not
 *    rename each other's half-written file into place.
 *
 * ## The Windows half, which for a long time was not here at all
 *
 * Everything above protects the *contents* on every platform. Only one of those
 * steps was ever about who may read them — the mode — and **on Windows the mode
 * is theatre.** NTFS has no POSIX permission bits; Node synthesises one, so any
 * read-write file reports 0666 whatever was asked for, `chmod` there can express
 * exactly one thing (the read-only attribute) and access is decided entirely by
 * an ACL that nothing in this module used to set. A new file simply inherits the
 * ACL of the folder it lands in, and the folder this app writes into —
 * `%APPDATA%\<app>` — inherits from the user profile, which on a machine with
 * more than one account is routinely readable by administrators and, on plenty
 * of real installs, by `Users`.
 *
 * So on Windows, every one of those files was readable by other accounts on the
 * machine, and three test files said so in a comment. Saying it is not fixing
 * it. The person this lands on is not the developer: it is somebody whose work
 * PC is shared with two colleagues, or whose family computer has an account per
 * child, or whose company laptop has an IT account that is not a full
 * administrator. Any of them could open `machines.json` and take a bearer
 * credential that reaches a shell on another machine.
 *
 * ### What is set, and why it is set on the directory as well
 *
 *     icacls <path> /inheritance:r /grant:r <DOMAIN\user>:(F)
 *
 * `/inheritance:r` removes the inherited entries — the whole point, since the
 * inherited entries *are* the exposure — and `/grant:r` replaces rather than
 * adds, so running it twice is not two entries and a file that already had a
 * wider grant does not keep it. The directory gets the same treatment plus
 * `(OI)(CI)`, so the entry is inheritable, and that is doing real work rather
 * than being belt-and-braces: it means every file created in that folder is
 * born protected, including the temp file below, the `.corrupt-*` copies
 * `machines.json` quarantines, and anything a future writer adds without reading
 * this comment. A locked file in a folder anyone can write to is also a file
 * anyone can replace, move aside or watch for, which is the other half of why
 * the directory is not optional.
 *
 * What this does **not** claim: an administrator can still take ownership, and
 * anything holding `SeBackupPrivilege` — a backup agent, the antivirus — reads
 * the file regardless. That is Windows, not something an application can close,
 * and the defect being fixed here is the ordinary second account on the same PC.
 *
 * ### The ACL goes on the temp file, before the rename
 *
 * Not on the final name afterwards. A file that appears at its real path and is
 * locked down a few milliseconds later is a file that was readable for a few
 * milliseconds, and worse, one that stays readable forever if the process dies
 * in between. Explicit entries travel with a rename inside a volume, so locking
 * the temp means the destination name never exists in an unprotected state.
 *
 * ### A failure refuses the write. It is not a warning.
 *
 * The tool can genuinely fail: the state directory can be pointed at exFAT on a
 * USB stick, which has no ACLs at all; a corporate policy can lock the profile
 * folder; `icacls` can be missing from a stripped image. In every one of those
 * cases the honest outcome is that the secret **is not written**, and the caller
 * is told with a sentence, because the alternative is the exact failure this
 * whole module exists to prevent: a person who believes they are protected and
 * is not. A warning on a console nobody reads, under a credential sitting in a
 * folder every account can open, is worse than a refusal — a refusal is
 * recoverable and visible; the file is neither. There is deliberately no
 * environment variable to turn this off, because that variable is what ends up
 * pasted into a forum answer.
 *
 * The cost is real and worth naming: on a machine where the ACL cannot be
 * applied, the user cannot sign in to GitHub and cannot pair a machine. That is
 * the correct direction to fail. Both of those store a bearer credential, and
 * neither is worth handing to the rest of the machine.
 *
 * ### `icacls` by absolute path, and its exit code rather than its prose
 *
 * `spawnSync` without a shell still searches `PATH`, and `PATH` on Windows
 * routinely contains directories the user — or anything running as the user —
 * can write to. This is a call made *in order to protect a secret*; resolving it
 * through `PATH` would let whatever put `icacls.exe` in a writable directory run
 * as us, and report success. So it is `%SystemRoot%\System32\icacls.exe` and
 * nothing else. `lid-awake.ts` reaches for `powercfg` the same way, for the same
 * reason.
 *
 * The result is judged on the exit status and on stderr, and never on the
 * "Successfully processed 1 files" line: that sentence is **localised**, so a
 * check that greps it works on an English PC and silently stops checking
 * anything on a German or Japanese one. A guard that quietly stops guarding is
 * how this class of bug ships in the first place.
 *
 * ## Why the platform is a parameter
 *
 * Because CI here is macOS-only and an inline `process.platform` branch is a
 * branch nothing in this suite can reach — `platform/host.ts` argues it at
 * length, and `session-create.ts` pins its Windows answers from a Mac by taking
 * the platform as an argument. The tool runner is injected for exactly the same
 * reason: `icacls` cannot run on this machine, and "cannot be run here" is not a
 * licence to ship it untested. That is how the PATH/Path bug shipped.
 */

import { spawnSync } from 'node:child_process'
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  unlinkSync,
  writeSync,
} from 'node:fs'
import { userInfo } from 'node:os'
import { win32 } from 'node:path'
import { renameWithRetry } from '../atomic-write'
import { currentPlatform, isWindows, type Env, type Platform } from '../platform/host'

/**
 * What running the ACL tool produced.
 *
 * Shaped like `lid-awake.ts`'s `CommandResult` and for the same reason: every
 * caller wants the same three things whether the command worked or not, and a
 * runner that throws hides the output on the rejection where nobody unpacks it.
 * A command that could not be started at all comes back as code -1 with the
 * reason in `stderr`, which lands in the same branch as a refusal.
 */
export interface AclResult {
  code: number
  stdout: string
  stderr: string
}

/** Synchronous on purpose: every caller of {@link writeSecretFile} is. */
export interface AclRunner {
  (file: string, args: readonly string[]): AclResult
}

export interface SecretFileOptions {
  /** Defaults to this machine's. Passed in so a Mac can pin the Windows path. */
  platform?: Platform
  /** Read for `SystemRoot` and `USERDOMAIN`. Defaults to `process.env`. */
  env?: Env
  /**
   * The account to grant, without a domain. Defaults to the account this
   * process is really running as.
   */
  account?: string
  /** Defaults to `icacls`. Injected so the Windows path is exercised here. */
  runAcl?: AclRunner
}

/**
 * How long `icacls` gets before it is treated as never having answered.
 *
 * Generous, and blocking: this runs on the main thread, so it is ten seconds of
 * frozen window in the worst case. It is that long because the one slow case is
 * real — resolving `DOMAIN\user` on a corporate laptop goes to a domain
 * controller over the network, and a laptop on hotel wifi can take seconds to
 * hear back. Timing out early there would refuse a sign-in that was about to
 * work. A local account never comes near this.
 */
const ACL_TIMEOUT_MS = 10_000

/**
 * Paths this process has already locked down.
 *
 * The directory is locked once rather than on every write, because a secret
 * write is not free — it already costs two fsyncs — and `machines.json` is
 * rewritten on every connection, which would otherwise be two process spawns
 * per reconnect on a phone with a flaky signal.
 *
 * Skipping it later is safe rather than merely cheap: undoing what was applied
 * needs `WRITE_DAC` on the object, and after the grant below only this user
 * holds it — plus administrators, who can take ownership whatever this module
 * re-runs. Re-applying per write would buy nothing against anyone who can
 * actually change it.
 *
 * Only successes are recorded, so a failure is retried by the next write rather
 * than remembered as done.
 */
const alreadyProtected = new Set<string>()

/**
 * `icacls`, addressed rather than searched for. See the header.
 *
 * `win32.join`, not the host's, so that asking for the Windows answer from a Mac
 * gives the Windows answer — the same reason `session-create.ts` selects its
 * path implementation instead of importing `node:path`.
 */
export function icaclsPath(env: Env): string {
  return win32.join(env.SystemRoot ?? 'C:\\Windows', 'System32', 'icacls.exe')
}

/**
 * The one account that may read these files, spelled the way `icacls` wants it.
 *
 * The name comes from the OS (`os.userInfo()`), not from `%USERNAME%`. The
 * environment is inherited and can be stale or simply wrong — a process started
 * through `runas`, a scheduled task, a service wrapper — and a grant to the
 * wrong account is both an exposure and a file this app can no longer read.
 * `USERDOMAIN` is taken from the environment because there is no other source
 * for it, and it is only ever used as a prefix: getting it wrong makes the
 * lookup fail loudly rather than granting somebody else.
 *
 * A name that already carries a domain is left alone, so an explicitly supplied
 * `DOMAIN\user` is not turned into `DOMAIN\DOMAIN\user`.
 *
 * The character check is not paranoia about exotic usernames — it is about the
 * shape of the argument this ends up inside. `icacls` reads `name:(F)` by
 * splitting at the *first* colon, so a name containing one would silently apply
 * a different, weaker right, and a name beginning with `/` would be read as a
 * switch. Neither can be produced by a real Windows account, so the only way to
 * see one is for something upstream to be wrong, and the safe answer to that is
 * to stop rather than to write a secret under an ACL nobody predicted.
 *
 * The residual risk, named rather than hidden: a *name* has to be resolved to a
 * SID, and for a domain account that resolution can reach for a domain
 * controller. A SID would not need resolving at all, and getting one costs a
 * second process (`whoami /user`) on every machine to remove a failure that
 * Windows' own documentation does not treat as one — `icacls <file> /grant:r
 * "%USERNAME%":(F)` is the form Microsoft prints for locking down an OpenSSH
 * key. So the name is used, the timeout below is generous enough for a slow
 * lookup, and a lookup that fails names the principal it tried in the sentence
 * the user gets. What it never does is continue as though it had worked.
 */
export function windowsPrincipal(account: string, env: Env): string {
  const name = account.trim()
  const domain = (env.USERDOMAIN ?? '').trim()
  const principal = name.includes('\\') || domain === '' ? name : `${domain}\\${name}`
  if (principal === '') {
    throw new Error('This PC did not say which account this app is running as.')
  }
  if (/[:"|<>*?\r\n]/.test(principal) || principal.startsWith('/')) {
    return refuseName(principal)
  }
  return principal
}

function refuseName(principal: string): never {
  throw new Error(
    `"${principal}" is not a Windows account name this app is willing to build an ACL from.`,
  )
}

/** The one place the command line is written. Exported so a test can pin it. */
export function aclArguments(
  target: string,
  principal: string,
  kind: 'file' | 'directory',
): string[] {
  // `(OI)(CI)` on the directory only: those flags say "object inherit, container
  // inherit", so files created inside are born with this entry. They are
  // meaningless on a file, and `icacls` rejects them there.
  const rights = kind === 'directory' ? '(OI)(CI)(F)' : '(F)'
  return [target, '/inheritance:r', '/grant:r', `${principal}:${rights}`]
}

const runIcacls: AclRunner = (file, args) => {
  const result = spawnSync(file, [...args], {
    encoding: 'utf8',
    timeout: ACL_TIMEOUT_MS,
    // Without this every credential write flashes a console window on screen.
    windowsHide: true,
    maxBuffer: 1024 * 1024,
  })
  // `stdout`/`stderr` are typed `string` and are `null` at runtime whenever the
  // child never ran, which is exactly the case being handled here.
  const stdout = result.stdout ?? ''
  const stderr = result.stderr ?? ''
  if (result.error) return { code: -1, stdout, stderr: `${stderr}\n${result.error.message}`.trim() }
  if (result.signal !== null) {
    return {
      code: -1,
      stdout,
      stderr: `${stderr}\nicacls was killed (${result.signal}) after ${ACL_TIMEOUT_MS}ms.`.trim(),
    }
  }
  return { code: result.status ?? -1, stdout, stderr }
}

/** The account this process is really running as. */
function currentAccount(): string {
  try {
    return userInfo().username
  } catch (err) {
    throw new Error(`This PC would not say which account this app runs as: ${textOf(err)}`)
  }
}

function textOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

/**
 * Restrict one path to one account, or throw saying why it could not be.
 *
 * Both halves of the check matter. A non-zero status is the ordinary refusal —
 * access denied, no such path, a filesystem with no ACLs. A zero status with
 * anything on stderr is treated as a failure too, because `icacls` prints its
 * per-file errors there and has been reported to still exit 0 in some of them,
 * and between "refuse a write that would have been fine" and "believe a
 * protection that was not applied", only the second one loses a credential.
 *
 * `shown` is the path the *sentence* names, which is not always the path being
 * locked: a file is locked while it is still `auth.json.4242.tmp`, and a person
 * reading a failure about a temp file that no longer exists has been told
 * nothing they can act on.
 */
function protect(
  target: string,
  kind: 'file' | 'directory',
  options: SecretFileOptions,
  shown: string = target,
): void {
  const env = options.env ?? process.env
  const principal = windowsPrincipal(options.account ?? currentAccount(), env)
  const tool = icaclsPath(env)
  const run = options.runAcl ?? runIcacls
  const result = run(tool, aclArguments(target, principal, kind))
  if (result.code === 0 && result.stderr.trim() === '') return

  const said = [result.stderr, result.stdout]
    .map((stream) => stream.trim())
    .filter((stream) => stream !== '')
    .join(' ')
  throw new Error(
    `Windows would not restrict this ${kind} to ${principal} only, so nothing was written to ` +
      `${shown}: ${tool} exited ${result.code}${said === '' ? '' : ` — ${said}`}. ` +
      'Until it can be locked down, every account on this PC could read what goes in it. ' +
      'Check the folder is on an NTFS drive and that its permissions are not locked by policy.',
  )
}

function protectOnce(target: string, kind: 'file' | 'directory', options: SecretFileOptions): void {
  if (alreadyProtected.has(target)) return
  protect(target, kind, options)
  alreadyProtected.add(target)
}

/**
 * Replace `file` with `contents`, atomically, readable only by this account.
 *
 * Throws rather than reporting failure: every caller here is writing something
 * whose loss changes who can reach this machine, and a write the caller believes
 * and the disk does not is the failure that puts a revoked device back on the
 * shell after the next restart. On Windows it throws for a second reason as
 * well — see the header — and in that case nothing has been written at all.
 */
export function writeSecretFile(
  dir: string,
  file: string,
  contents: string,
  options: SecretFileOptions = {},
): void {
  const windows = isWindows(options.platform ?? currentPlatform())
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  // Before the temp file exists, not after: the directory's inheritable entry
  // is what makes the temp file protected from the instant it is created, and
  // this also locks a directory an older version of this app left open.
  if (windows) protectOnce(dir, 'directory', options)
  const tmp = `${file}.${process.pid}.tmp`
  try {
    try {
      unlinkSync(tmp)
    } catch {
      /* nothing there, which is the normal case */
    }
    const fd = openSync(tmp, 'wx', 0o600)
    try {
      const bytes = Buffer.from(contents, 'utf8')
      for (let written = 0; written < bytes.length; ) {
        written += writeSync(fd, bytes, written, bytes.length - written)
      }
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    chmodSync(tmp, 0o600)
    // Not memoised: the temp path repeats every write, but the *file* behind it
    // is a new object each time and carries no entry of its own until this runs.
    if (windows) protect(tmp, 'file', options, file)
    /*
     * Retried, because on Windows this is the line most likely to be refused.
     *
     * `MoveFileEx` fails with `EPERM` — which reads as a permission problem and
     * is not one — while any process holds the destination open, and the line
     * above has just written an ACL onto the source, which is exactly what makes
     * Defender open a file to look at it. A bare `renameSync` here threw out of
     * the one write in this app that must not fail: the device's private key and
     * the credential hashes the remote wire is built on.
     *
     * `atomic-write.ts` has owned that retry for every other file in the app;
     * this one could not use `writeFileAtomic` because of the `wx` open, the
     * fsync, the chmod and the ACL above, so the retry was split out to be
     * shared rather than written twice with two different ideas of how long to
     * wait for a scanner.
     */
    renameWithRetry(tmp, file, options.platform ?? currentPlatform())
    chmodSync(file, 0o600)
    try {
      const handle = openSync(dir, 'r')
      try {
        fsyncSync(handle)
      } finally {
        closeSync(handle)
      }
    } catch {
      /* not every filesystem lets a directory be synced; the file already is */
    }
  } catch (err) {
    try {
      unlinkSync(tmp)
    } catch {
      /* never created, or already gone */
    }
    throw err
  }
}

/**
 * Lock down a secret file that is already on disk, on the way to reading it.
 *
 * The write path above protects everything it writes, which covers a file from
 * the moment this version of the app first saves it — and covers nothing at all
 * for a file an older version already wrote. That gap is not theoretical: a
 * GitHub token is written once at sign-in and may never be rewritten, so a user
 * upgrading into this version would keep an exposed credential indefinitely
 * while every test here passed. The readers call this so the repair happens the
 * first time the file is opened.
 *
 * **This one does not throw, and that is not the header contradicting itself.**
 * Refusing a *write* removes exposure: the secret stays off the disk. Refusing a
 * *read* removes none — the file is already there, already exposed — and would
 * only break an app that could otherwise work, while leaving the file exactly as
 * it was. So the failure is reported and the read continues, which is the only
 * one of the two directions that helps the person it happens to.
 *
 * Idempotent and memoised, so a caller in a loop — `readDaemonRecord` while
 * waiting for a host to come up — spawns one process, not one per call.
 */
export function protectSecretFile(
  dir: string,
  file: string,
  options: SecretFileOptions = {},
): void {
  if (!isWindows(options.platform ?? currentPlatform())) return
  // Nothing to repair, and no reason to lock a folder that holds no secret yet;
  // the write path does that the moment there is one.
  if (!existsSync(file)) return
  try {
    protectOnce(dir, 'directory', options)
    protectOnce(file, 'file', options)
  } catch (err) {
    console.error(
      `[secret-file] ${file} holds a secret and could not be restricted to this account, ` +
        `so other accounts on this PC may be able to read it: ${textOf(err)}`,
    )
  }
}
