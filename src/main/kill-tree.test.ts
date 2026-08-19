import { describe, expect, it } from 'vitest'
import { killTree, systemRootOf, treeKillCommand, type KillableChild } from './kill-tree'

/**
 * The Windows half of every probe's cleanup, proved on a Mac.
 *
 * There is no Windows machine here and CI that gates a merge is macOS-only, so
 * every test below **forces** the platform rather than reading it. That is the
 * rule `platform/host.ts` was written to make possible and the reason it gives
 * is exactly this one: an inline `process.platform` branch "is untestable here
 * in the strongest sense: nothing in the suite can reach it, and the first
 * person to find out whether it works is a user."
 *
 * Two shapes of worthless test are avoided on purpose, because this repo has
 * had to fix six of them:
 *
 *  - Nothing here asserts a value that macOS would produce anyway. Every case
 *    that names `'win32'` has a `'darwin'` twin asserting the *opposite*
 *    behaviour on the same run, so a regression that collapsed the branch into
 *    one answer fails whichever way it collapsed.
 *  - Nothing here builds a Windows path with `path.join`. On this Mac that
 *    produces `C:\\Windows/System32/taskkill.exe`, and a test asserting that
 *    string would be asserting a path Windows has never seen. The separator is
 *    checked literally.
 */

/** A child that records what was done to it, with none of `ChildProcess` in the way. */
function fakeChild(
  overrides: Partial<KillableChild> = {},
): KillableChild & { signals: (NodeJS.Signals | number | undefined)[] } {
  const signals: (NodeJS.Signals | number | undefined)[] = []
  return {
    pid: 4242,
    exitCode: null,
    signalCode: null,
    ...overrides,
    signals,
    kill(signal?: NodeJS.Signals | number) {
      signals.push(signal)
      return true
    },
  }
}

/** A recording issuer. `ok` is what taskkill is pretended to have answered. */
function recorder(ok: boolean): {
  run: (file: string, args: readonly string[]) => Promise<boolean>
  calls: { file: string; args: string[] }[]
} {
  const calls: { file: string; args: string[] }[] = []
  return {
    calls,
    run: async (file, args) => {
      calls.push({ file, args: [...args] })
      return ok
    },
  }
}

describe('the command that ends a Windows process tree', () => {
  it('spells an absolute System32 path with backslashes, on a Mac', () => {
    /*
     * The whole point of writing the separator literally. `join('C:\\Windows',
     * 'System32', 'taskkill.exe')` evaluated on darwin gives
     * `C:\Windows/System32/taskkill.exe` — a path that is wrong on the only
     * platform that will ever read it, and a test written against it would have
     * been green here and broken there.
     */
    const { file } = treeKillCommand(4242, 'C:\\WINDOWS')
    expect(file).toBe('C:\\WINDOWS\\System32\\taskkill.exe')
    expect(file).not.toContain('/')
  })

  it('takes the pid, the tree and force — in the spelling taskkill accepts', () => {
    const { args } = treeKillCommand(4242, 'C:\\WINDOWS')
    // `/T` is the only flag that matters here: without it taskkill ends the
    // command processor and leaves the agent CLI underneath it, which is the
    // exact bug this module exists for.
    expect(args).toEqual(['/PID', '4242', '/T', '/F'])
  })

  it('falls back to the bare name when the machine exports no %SystemRoot%', () => {
    // A stripped container or a WSL-interop environment can be missing it.
    // Losing PATH-shadow protection is worth more than not cleaning up at all.
    expect(treeKillCommand(7, undefined).file).toBe('taskkill.exe')
    expect(treeKillCommand(7, '   ').file).toBe('taskkill.exe')
  })

  it('does not double the separator when %SystemRoot% carries a trailing one', () => {
    expect(treeKillCommand(7, 'C:\\WINDOWS\\').file).toBe('C:\\WINDOWS\\System32\\taskkill.exe')
  })

  it('finds %SystemRoot% whatever case the environment spelled it in', () => {
    /*
     * Windows environment names are case-insensitive and Node mirrors that on
     * Windows only — but every probe here hands its child a *copy* built by
     * `withPath`, and a copy is an ordinary case-sensitive object. This is the
     * PATH hazard `platform/host.ts` documents, in a second variable.
     */
    expect(systemRootOf({ SystemRoot: 'C:\\WINDOWS' })).toBe('C:\\WINDOWS')
    expect(systemRootOf({ SYSTEMROOT: 'C:\\WINDOWS' })).toBe('C:\\WINDOWS')
    expect(systemRootOf({ systemroot: 'D:\\Win' })).toBe('D:\\Win')
    expect(systemRootOf({ SystemRoot: '' })).toBeUndefined()
    expect(systemRootOf({ HOME: '/Users/asad' })).toBeUndefined()
  })
})

describe('what a probe does with its child when it is finished with it', () => {
  it('kills the tree on Windows when a command processor is in the way — and never signals the shell', () => {
    /*
     * The load-bearing assertion of this whole module, and it is the *negative*
     * one. `child.kill()` on Windows terminates `cmd.exe`, which orphans the
     * `node …\claude` underneath it: the process survives, holding the half
     * gigabyte `usage-probe.ts` kills its child to avoid, once per reading.
     *
     * And the shell must not be signalled *first* either, even as belt and
     * braces: `taskkill /T` walks the tree downward from the pid it is given,
     * so a cmd.exe that is already dead has no tree left to walk and the
     * grandchild is missed. Hence `signals` must be empty, not merely short.
     */
    const child = fakeChild()
    const taskkill = recorder(true)
    return killTree(child, {
      platform: 'win32',
      shell: true,
      systemRoot: 'C:\\WINDOWS',
      run: taskkill.run,
    }).then((outcome) => {
      expect(outcome).toBe('tree')
      expect(taskkill.calls).toEqual([
        { file: 'C:\\WINDOWS\\System32\\taskkill.exe', args: ['/PID', '4242', '/T', '/F'] },
      ])
      expect(child.signals).toEqual([])
    })
  })

  it('signals the child directly on macOS, and runs no taskkill there', async () => {
    /*
     * The twin of the case above, on the same run. POSIX has no `taskkill` at
     * all, so reaching for it here would not be a parity improvement — it would
     * be an ENOENT in place of a cleanup.
     */
    const child = fakeChild()
    const taskkill = recorder(true)
    const outcome = await killTree(child, { platform: 'darwin', shell: false, run: taskkill.run })
    expect(outcome).toBe('direct')
    expect(child.signals).toHaveLength(1)
    expect(taskkill.calls).toEqual([])
  })

  it('still signals directly on macOS even if a caller claims a shell', async () => {
    // `launchSpec` cannot return `shell: true` off Windows, so this is a
    // guard against a future caller rather than a live path — but the answer
    // has to be "the POSIX one", because the reason taskkill exists is Windows
    // lacking process groups, not shells existing.
    const child = fakeChild()
    const taskkill = recorder(true)
    const outcome = await killTree(child, { platform: 'darwin', shell: true, run: taskkill.run })
    expect(outcome).toBe('direct')
    expect(child.signals).toHaveLength(1)
    expect(taskkill.calls).toEqual([])
  })

  it('signals directly on Windows too when there is no shell in between', async () => {
    /*
     * Parity is the instruction, not improvement. When `launchSpec` resolves a
     * real `.exe` the direct child *is* the CLI on Windows, and killing it is
     * precisely what macOS does. `/T` there would also kill whatever that CLI
     * had started, which macOS does not do — a different behaviour, arrived at
     * by accident, is exactly what this wave is removing.
     */
    const child = fakeChild()
    const taskkill = recorder(true)
    const outcome = await killTree(child, {
      platform: 'win32',
      shell: false,
      systemRoot: 'C:\\WINDOWS',
      run: taskkill.run,
    })
    expect(outcome).toBe('direct')
    expect(child.signals).toHaveLength(1)
    expect(taskkill.calls).toEqual([])
  })

  it('falls back to signalling the shell when taskkill will not run', async () => {
    // Access denied, or a machine whose PATH and %SystemRoot% both fail us.
    // Killing the command processor is worse than killing the tree and much
    // better than leaking both, and it is what this code did before.
    const child = fakeChild()
    const taskkill = recorder(false)
    const outcome = await killTree(child, {
      platform: 'win32',
      shell: true,
      systemRoot: 'C:\\WINDOWS',
      run: taskkill.run,
    })
    expect(outcome).toBe('tree-refused')
    expect(taskkill.calls).toHaveLength(1)
    expect(child.signals).toHaveLength(1)
  })

  it('falls back rather than rejecting when the issuer itself throws', async () => {
    // This is called from `finally` blocks and from inside a promise executor.
    // A throw here would strand a probe that already has its answer.
    const child = fakeChild()
    const outcome = await killTree(child, {
      platform: 'win32',
      shell: true,
      run: () => {
        throw new Error('spawn taskkill EPERM')
      },
    })
    expect(outcome).toBe('tree-refused')
    expect(child.signals).toHaveLength(1)
  })

  it('kills nothing at all once the child has exited, on Windows especially', async () => {
    /*
     * The hazard that only exists once a pid is passed to an external command.
     * `child.kill()` after exit is a harmless no-op because Node still owns the
     * handle; `taskkill /PID <n> /T /F` owns nothing and Windows recycles pids
     * aggressively, so the same call a moment later ends a stranger's process
     * tree.
     *
     * This is not a corner: `askOverStdio` calls its `finish` from the child's
     * own `exit` handler, so the ordinary successful run reaches here with the
     * child already gone.
     */
    const exited = fakeChild({ exitCode: 0 })
    const taskkill = recorder(true)
    expect(
      await killTree(exited, { platform: 'win32', shell: true, run: taskkill.run }),
    ).toBe('already-gone')
    expect(taskkill.calls).toEqual([])
    expect(exited.signals).toEqual([])

    const signalled = fakeChild({ exitCode: null, signalCode: 'SIGTERM' })
    expect(
      await killTree(signalled, { platform: 'darwin', shell: false, run: taskkill.run }),
    ).toBe('already-gone')
    expect(signalled.signals).toEqual([])
  })

  it('does not hand taskkill a pid it was never given', async () => {
    // A spawn that failed before it produced a pid has no tree to walk, and
    // `taskkill /PID undefined` is either a no-op or, worse, an argument parse
    // that hits something else.
    const taskkill = recorder(true)
    for (const pid of [undefined, 0, -1]) {
      const child = fakeChild({ pid })
      const outcome = await killTree(child, { platform: 'win32', shell: true, run: taskkill.run })
      expect(outcome).toBe('direct')
      expect(child.signals).toHaveLength(1)
    }
    expect(taskkill.calls).toEqual([])
  })
})
