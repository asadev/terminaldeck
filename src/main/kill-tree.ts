/**
 * Ending a child the way macOS already ends it, on the platform where the
 * obvious call does not.
 *
 * ## The difference, stated exactly
 *
 * Every probe in this app spawns a CLI and then kills it. On macOS the thing
 * that gets spawned *is* the CLI — `launchSpec` returns `{ shell: false }` for
 * every non-Windows platform (`tool-probe.ts`) — so `child.kill()` signals
 * `claude`/`codex`/`gemini` itself and nothing is left behind.
 *
 * On Windows the thing that gets spawned is frequently **not** the CLI. An
 * npm-installed agent resolves on PATH to a `.cmd` shim, Node has refused to
 * spawn `.cmd`/`.bat` without `shell: true` since 18.20.2/20.12.2 (the fix for
 * CVE-2024-27980), and `usage-probe.ts` hard-codes `resolved = null` when it
 * asks `launchSpec` — deliberately, because `agent-binaries.ts` records
 * `runnable` as the bare name for exactly the reason that "the resolved path is
 * a `.cmd` shim that CreateProcess will not run". So on Windows the probe's
 * direct child is **cmd.exe**, and the `node …\claude` doing the actual work is
 * its grandchild.
 *
 * `child.kill()` and Node's `execFile({ timeout })` both come down to
 * `TerminateProcess` on the direct child on Windows. Windows has no process
 * groups to signal and no `SIGTERM` to propagate: terminating cmd.exe does not
 * touch what cmd.exe started. So the shell dies, the agent CLI keeps running,
 * and nothing ever collects it.
 *
 * That is not a cosmetic difference. `usage-probe.ts` says in its own comment
 * that it kills the child on *every single reading* because "an idle CLI
 * holding half a gigabyte for no reason is a cost with nothing on the other
 * side of it". On Windows that sentence inverts: every usage refresh would
 * leave behind exactly that half gigabyte, for as long as the app runs, one per
 * refresh. macOS leaks nothing. That is the parity gap this module closes.
 *
 * ## Why `taskkill /T /F` and not something cleverer
 *
 * The textbook answer on Windows is a Job Object with
 * `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, which is genuinely better: it is
 * race-free and it catches grandchildren that re-parent. It is also not
 * reachable from Node without a native addon, and this app already refuses to
 * add native code it cannot build and test on the machine the work is done on.
 * `taskkill /PID <pid> /T /F` ships in every Windows install, walks the tree by
 * parent-pid, and is what every cross-platform runner (`tree-kill`, VS Code's
 * own terminal teardown) settles on for the same reason.
 *
 * ## Two ordering facts that are easy to get wrong, and are load-bearing
 *
 *  1. **taskkill runs first, the shell is never signalled first.** `/T` walks
 *     the tree *downward from the pid it is given*. If cmd.exe has already been
 *     terminated, the grandchild is orphaned and there is no longer any pid
 *     whose tree contains it — taskkill would report success having killed
 *     nothing. So `child.kill()` is only ever a *fallback*, reached when
 *     taskkill could not be started at all.
 *
 *  2. **A child that has already exited is not killed by pid.** On POSIX this
 *     did not matter: `child.kill()` after exit is a no-op because Node still
 *     owns the handle. `taskkill` has no such protection — it takes a raw pid,
 *     and Windows recycles pids aggressively. Signalling a dead child's pid is
 *     how you kill a stranger's process tree. `askOverStdio` calls its `finish`
 *     from the `exit` handler, so this path is reached on every ordinary run,
 *     not in some corner. Hence the `already-gone` outcome, which signals
 *     nothing on purpose.
 *
 * ## Why the Windows branch is only taken when a shell is in the way
 *
 * When `launchSpec` says `shell: false` the direct child is the CLI on Windows
 * too, and killing it is exactly what macOS does. Reaching for `/T` there would
 * be *more* than macOS does — it would also kill whatever that CLI had started
 * — and the instruction for this port is parity, not improvement. The shell is
 * the whole of the difference, so the shell is the whole of the condition.
 *
 * ## The sibling that landed in the same wave, and which of the two wins
 *
 * `routines/runner.ts` grew a `killPlan` of its own on the same day, for the
 * same reason and with a worse consequence than a leak: a killed `cmd.exe` does
 * not close the stdio pipes its grandchild inherited, so the launch promise
 * there never settles and the routine is wedged for the life of the process.
 * Its comment names this module's two files as owed and says outright that
 * "when a shared helper lands beside `launchSpec`, this should call it". This
 * is that helper; folding `killPlan` into it is owed work in that lane, not
 * something to be done from here while another agent holds the file.
 *
 * One deliberate difference, so a later merge is not an argument. That plan
 * runs `taskkill` by bare name and argues, correctly, that System32 is always
 * on a Windows PATH and that `execFile` does not resolve a program name against
 * the working directory. Both are true. The absolute path is still preferred
 * here for the reason `lid-awake.ts` gives for `powercfg.exe` — PATH is
 * whatever the user made it, and cleanup is the wrong place to depend on it —
 * and the bare name is kept as the fallback, so neither machine loses.
 *
 * ## How this is proved without a Windows machine
 *
 * The platform is a parameter, never `process.platform` — the rule
 * `platform/host.ts` exists to enforce, and the reason its header gives is
 * precisely this one: "an inline Windows branch is untestable here in the
 * strongest sense: nothing in the suite can reach it, and the first person to
 * find out whether it works is a user." So `kill-tree.test.ts` pins the win32
 * answer and the darwin answer side by side on the same run, on this Mac, with
 * the command spelled out verbatim.
 */

import { spawn } from 'node:child_process'
import { isWindows, type Platform } from './platform/host'

/**
 * Just enough of a `ChildProcess` to end one.
 *
 * Structural rather than the real type so a test can hand this a plain object
 * and watch which of the two paths touched it. Every field is one Node's
 * `ChildProcess` already has, with the same meaning, so a real child satisfies
 * it without a cast.
 */
export interface KillableChild {
  readonly pid?: number | undefined
  /** Set by Node *before* `exit` is emitted, which is what makes it usable here. */
  readonly exitCode?: number | null
  readonly signalCode?: NodeJS.Signals | null
  kill(signal?: NodeJS.Signals | number): boolean
}

/** What actually happened, so a caller (or a test) can tell the paths apart. */
export type KillOutcome =
  /** `taskkill /T` ran: the command processor and everything under it is gone. */
  | 'tree'
  /** taskkill could not be run at all; the shell was signalled as a last resort. */
  | 'tree-refused'
  /** The child is the thing itself — signalled directly, exactly as macOS does. */
  | 'direct'
  /** It had already exited. Nothing was signalled, deliberately: see the header. */
  | 'already-gone'

export interface KillTreeOptions {
  /** Never read from `process.platform` here. See `platform/host.ts`. */
  platform: Platform
  /** Whether `launchSpec` put a command processor between us and the real child. */
  shell: boolean
  /**
   * `%SystemRoot%`, when the caller has it. Production passes `process.env`'s
   * copy so the absolute `System32` path is used; tests pass both spellings.
   */
  systemRoot?: string | undefined
  /**
   * How the tree-kill is issued. Resolves true when the tree is gone.
   *
   * Injected at this seam rather than around `spawn` because what is worth
   * proving from a Mac is *which command, with which arguments, and whether the
   * shell was signalled instead* — not that this machine can run `taskkill`,
   * which it cannot.
   */
  run?(file: string, args: readonly string[]): Promise<boolean>
}

/**
 * The command that ends a Windows process tree, built as a string rather than
 * with `path.join`.
 *
 * That is not an oversight and it is the single easiest way to write a test
 * here that passes on this Mac and means nothing. `join('C:\\Windows',
 * 'System32', 'taskkill.exe')` yields `C:\Windows/System32/taskkill.exe` when
 * the code is *running* on macOS, because `path.join` uses the separator of the
 * host it is on, not of the platform being described. A test asserting that
 * value on a Mac would be asserting a path Windows has never seen. So the
 * separator is written literally, and the test asserts there is no forward
 * slash in the result.
 *
 * The absolute path is preferred over the bare name for the reason
 * `lid-awake.ts` gives for `powercfg.exe`: PATH on Windows is whatever the user
 * made it, and a probe's cleanup must not be defeated by a shadowed name. The
 * bare name remains the fallback for a machine that does not export
 * `%SystemRoot%` (a stripped container, WSL interop) rather than giving up.
 */
export function treeKillCommand(pid: number, systemRoot?: string): { file: string; args: string[] } {
  const root = (systemRoot ?? '').trim().replace(/[\\/]+$/, '')
  const file = root === '' ? 'taskkill.exe' : `${root}\\System32\\taskkill.exe`
  // `/T` is the tree — the pid *and* everything it started, which is the only
  // part that matters here. `/F` because the grandchild is a console process
  // with no window and no message loop, so there is nothing for a polite
  // WM_CLOSE to arrive at.
  return { file, args: ['/PID', String(pid), '/T', '/F'] }
}

/** The real issuer. Never rejects; a failure to kill is an answer, not a throw. */
async function issueTaskkill(file: string, args: readonly string[]): Promise<boolean> {
  return await new Promise<boolean>((resolve) => {
    let settled = false
    const settle = (ok: boolean): void => {
      if (settled) return
      settled = true
      resolve(ok)
    }
    try {
      const killer = spawn(file, [...args], {
        stdio: 'ignore',
        // Cleanup must never put a console window on screen. Twenty other
        // spawns in this folder carry this flag with the same comment.
        windowsHide: true,
      })
      killer.on('error', () => settle(false))
      killer.on('exit', (code) => {
        // 0 is "killed it". 128 is taskkill's "there is no such process", which
        // is the same outcome for our purposes: nothing is left running. Any
        // other status (1 = access denied, most often) means the tree may still
        // be there and the fallback should run.
        settle(code === 0 || code === 128)
      })
      // Cleanup must not be the thing that keeps the app alive at quit.
      killer.unref()
    } catch {
      settle(false)
    }
  })
}

/**
 * End a spawned child and everything it started, on every platform.
 *
 * Never rejects and never throws: this is called from `finally` blocks and from
 * promise executors where a throw would strand the caller. Callers that do not
 * care about the outcome may `void` it.
 */
export async function killTree(child: KillableChild, options: KillTreeOptions): Promise<KillOutcome> {
  // Already finished. Signalling anything here would be signalling a pid that
  // Windows may have handed to somebody else — see the header.
  if ((child.exitCode ?? null) !== null || (child.signalCode ?? null) !== null) return 'already-gone'

  const signalDirectly = (): void => {
    try {
      child.kill()
    } catch {
      // Already gone between the check above and here. Nothing to do and
      // nothing worth reporting.
    }
  }

  // POSIX, or Windows with no command processor in the way: the direct child is
  // the real one, and this is exactly what macOS has always done.
  if (!isWindows(options.platform) || !options.shell) {
    signalDirectly()
    return 'direct'
  }

  const pid = child.pid
  if (pid === undefined || !Number.isInteger(pid) || pid <= 0) {
    // A spawn that never produced a pid has no tree to walk. Falling back keeps
    // the old behaviour rather than doing nothing at all.
    signalDirectly()
    return 'direct'
  }

  const { file, args } = treeKillCommand(pid, options.systemRoot)
  const run = options.run ?? issueTaskkill
  let killed = false
  try {
    killed = await run(file, args)
  } catch {
    killed = false
  }
  if (killed) return 'tree'

  // taskkill could not be started. Killing the shell is worse than killing the
  // tree and better than leaking both, and it is what this code did before this
  // module existed.
  signalDirectly()
  return 'tree-refused'
}

/**
 * `%SystemRoot%` out of an environment, in whatever case it was spelled.
 *
 * Windows environment names are case-insensitive and Node mirrors that on
 * Windows only, so a copied env — which is what every probe here builds, via
 * `withPath` — can hold `SystemRoot`, `SYSTEMROOT` or `systemroot` and a plain
 * property read finds only one of them. The same hazard `platform/host.ts`
 * documents at length for PATH, in a second variable.
 */
export function systemRootOf(env: Record<string, string | undefined>): string | undefined {
  for (const [key, value] of Object.entries(env)) {
    if (key.toUpperCase() === 'SYSTEMROOT' && typeof value === 'string' && value !== '') return value
  }
  return undefined
}
