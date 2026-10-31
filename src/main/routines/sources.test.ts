import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ALERTS_CHANNEL, registerAlertsIpc, type AlertReport } from '../alerts'
import { stopAllGitWatches } from '../git'
import { RoutineFileWatchers, watchGitFolder } from './sources'

/**
 * The real subscriptions, against a real filesystem and a real git repository.
 *
 * `engine.test.ts` drives the rules with the sources injected, which is what
 * lets it be fast. This file is the other half and it is deliberately slow: a
 * file watcher that is wired wrong types perfectly and reports nothing, and no
 * amount of testing the engine finds that. Both of these fire from an event the
 * operating system produced, with nothing in the test polling for it.
 */

const run = promisify(execFile)

let dir: string

/** Wait for `check` to become true, or give up. Returns whether it did. */
async function until(check: () => boolean, ms: number): Promise<boolean> {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (check()) return true
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return check()
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-sources-'))
})

afterEach(() => {
  stopAllGitWatches()
  rmSync(dir, { recursive: true, force: true })
})

describe('RoutineFileWatchers', () => {
  it('reports a change as a path relative to the folder', async () => {
    const watchers = new RoutineFileWatchers()
    const seen: string[] = []
    const off = watchers.watch(dir, (path) => seen.push(path))
    try {
      // chokidar returns before it is watching. `transcript.ts` documents the
      // same trap; a write issued immediately is missed most of the time.
      await new Promise((resolve) => setTimeout(resolve, 300))
      mkdirSync(join(dir, 'src'), { recursive: true })
      writeFileSync(join(dir, 'src', 'app.ts'), 'hello', 'utf8')
      expect(await until(() => seen.includes(join('src', 'app.ts')), 5000)).toBe(true)
    } finally {
      off()
      await watchers.stop()
    }
  }, 20000)

  it('never reports anything inside node_modules or .git', async () => {
    const watchers = new RoutineFileWatchers()
    const seen: string[] = []
    const off = watchers.watch(dir, (path) => seen.push(path))
    try {
      await new Promise((resolve) => setTimeout(resolve, 300))
      mkdirSync(join(dir, 'node_modules', 'thing'), { recursive: true })
      writeFileSync(join(dir, 'node_modules', 'thing', 'index.js'), 'x', 'utf8')
      mkdirSync(join(dir, '.git'), { recursive: true })
      writeFileSync(join(dir, '.git', 'HEAD'), 'ref: refs/heads/main', 'utf8')
      writeFileSync(join(dir, 'real.txt'), 'x', 'utf8')

      expect(await until(() => seen.includes('real.txt'), 5000)).toBe(true)
      expect(seen.some((path) => path.includes('node_modules'))).toBe(false)
      expect(seen.some((path) => path.includes('.git'))).toBe(false)
    } finally {
      off()
      await watchers.stop()
    }
  }, 20000)

  it('keeps one watcher for two routines on one folder, and drops it with the last', async () => {
    const watchers = new RoutineFileWatchers()
    const first: string[] = []
    const second: string[] = []
    const offFirst = watchers.watch(dir, (path) => first.push(path))
    const offSecond = watchers.watch(dir, (path) => second.push(path))
    try {
      await new Promise((resolve) => setTimeout(resolve, 300))
      writeFileSync(join(dir, 'a.txt'), 'x', 'utf8')
      expect(await until(() => first.length > 0 && second.length > 0, 5000)).toBe(true)

      offFirst()
      const before = first.length
      writeFileSync(join(dir, 'b.txt'), 'x', 'utf8')
      expect(await until(() => second.length > 1, 5000)).toBe(true)
      // The one that let go hears nothing more; the one still holding does.
      expect(first.length).toBe(before)

      offSecond()
      const settled = second.length
      writeFileSync(join(dir, 'c.txt'), 'x', 'utf8')
      await new Promise((resolve) => setTimeout(resolve, 500))
      expect(second.length).toBe(settled)
    } finally {
      await watchers.stop()
    }
  }, 20000)
})

describe('watchGitFolder', () => {
  it('reports a real change in a real repository, with no window open', async () => {
    // The point of this test: `git-change` has to work when nothing has the git
    // panel open, which is the whole reason `holdGitWatch` exists. Nothing here
    // touches a `WebContents`.
    await run('git', ['init', '-q'], { cwd: dir })
    await run('git', ['config', 'user.email', 'test@example.com'], { cwd: dir })
    await run('git', ['config', 'user.name', 'Test'], { cwd: dir })
    writeFileSync(join(dir, 'first.txt'), 'one', 'utf8')

    let changes = 0
    const off = watchGitFolder(dir, () => {
      changes += 1
    })
    try {
      // Let the first read seed the watch, so what follows is a change rather
      // than the initial state.
      await new Promise((resolve) => setTimeout(resolve, 1500))
      const before = changes
      writeFileSync(join(dir, 'second.txt'), 'two', 'utf8')
      // Staging rewrites `.git/index`, which is what the watch's signature is
      // built from — so this is noticed on the next second rather than on the
      // slower full-refresh backstop.
      await run('git', ['add', 'second.txt'], { cwd: dir })
      expect(await until(() => changes > before, 15000)).toBe(true)
    } finally {
      off()
    }
  }, 40000)

  it('stops reporting once released', async () => {
    await run('git', ['init', '-q'], { cwd: dir })
    await run('git', ['config', 'user.email', 'test@example.com'], { cwd: dir })
    await run('git', ['config', 'user.name', 'Test'], { cwd: dir })

    let changes = 0
    const off = watchGitFolder(dir, () => {
      changes += 1
    })
    await new Promise((resolve) => setTimeout(resolve, 1500))
    off()
    const settled = changes

    writeFileSync(join(dir, 'later.txt'), 'x', 'utf8')
    await run('git', ['add', 'later.txt'], { cwd: dir })
    await new Promise((resolve) => setTimeout(resolve, 3000))
    expect(changes).toBe(settled)
  }, 40000)
})

describe('the alert source', () => {
  /**
   * There is no push side to alerts, and there deliberately still is not: the
   * panel asks and `alerts.ts` answers. What the routine engine subscribes to
   * is that answer, as it is produced — so this test runs a real scan through
   * the real channel and checks the report arrives.
   *
   * The consequence is worth stating because the engine has to report it: on a
   * machine where nothing ever asks for alerts, no report is produced and no
   * `alert` routine fires. That is a real limitation of subscribing rather than
   * scanning, and it is the reason every routine carries the last time its
   * source said anything.
   */
  it('hands each report to an observer as the channel produces it', async () => {
    const reports: AlertReport[] = []
    const handlers = new Map<string, (event: IpcMainInvokeEvent, ...args: never[]) => unknown>()
    const ipcMain = {
      handle: (channel: string, handler: (event: IpcMainInvokeEvent, ...args: never[]) => unknown) => {
        handlers.set(channel, handler)
      },
    } as unknown as IpcMain

    registerAlertsIpc(ipcMain, {
      // Pointed at the scratch directory so the scan reads no real transcripts.
      configDir: join(dir, 'claude'),
      deviceHomes: null,
      onReport: (report) => reports.push(report),
    })

    const handler = handlers.get(ALERTS_CHANNEL)
    expect(handler).toBeDefined()
    const answered = (await handler?.(
      {} as IpcMainInvokeEvent,
      ...([dir] as never[]),
    )) as AlertReport

    expect(reports).toHaveLength(1)
    // The observer is handed the same report the caller gets, not a copy that
    // could disagree with what is on screen.
    expect(reports[0]).toBe(answered)
    expect(reports[0].projectPath).toBe(dir)
  }, 40000)
})
