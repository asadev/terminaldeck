/**
 * Where the engine's events actually come from.
 *
 * `engine.ts` takes every subscription as an injected function so it can be
 * tested without a filesystem, a git binary or a window. This file is the other
 * half: the real ones, wired to the emitters this app already has.
 *
 * Keeping them apart is not tidiness. The engine is the part with the
 * interesting rules — loops, budgets, overlap — and those rules have to be
 * pinned by tests that run in milliseconds and do not depend on how quickly a
 * filesystem reports a change. The part that *does* depend on that is here, and
 * it is small enough to read in one sitting.
 *
 * ## What is subscribed to, and what had to be added
 *
 * | Trigger | Emitter |
 * |---|---|
 * | `git-change` | `git.ts`'s existing watcher, through `onGitStatusChanged` + `holdGitWatch` — both added for this, so a routine does not need the git panel to be open and does not start a second poller. |
 * | `file-change` | chokidar, the same library `transcript.ts` already tails transcripts with. Native filesystem events on macOS; no scanning. |
 * | `session-*`, `alert` | callbacks the shell already receives — see the wiring notes in `index.ts`. Nothing new is created for them. |
 */

import { watch, type FSWatcher } from 'chokidar'
import { relative, resolve, sep } from 'node:path'
import { holdGitWatch, onGitStatusChanged, releaseGitWatch } from '../git'

/**
 * Directories never worth watching for a routine.
 *
 * Small and hard-coded on purpose. `.deckignore` is the app's real answer to
 * "what should we not look at" and it is asynchronous, per-project and
 * cached — reading it here would make attaching a watcher an async operation
 * that can fail, on a path that has to work at boot. These four are the ones
 * that make the difference between watching a project and watching a build:
 * `node_modules` alone is routinely a hundred thousand inodes, and `.git`
 * changes on every command git runs, which would fire a `file-change` routine
 * for the `git-change` trigger's events.
 *
 * A routine that genuinely wants to watch inside one of these can say so — the
 * glob is matched separately, in the engine — but this app will not put a
 * recursive watch on them.
 */
const NEVER_WATCH = new Set(['.git', 'node_modules', 'out', 'dist'])

/**
 * How deep a routine's file watch goes.
 *
 * Unlimited would be correct for a normal project and catastrophic for one that
 * happens to contain a checkout of something enormous. Ten levels below the
 * project root is deeper than any source tree this repository has and shallow
 * enough that a mistake costs a bounded number of file descriptors.
 */
const MAX_WATCH_DEPTH = 10

export type Unsubscribe = () => void

/* ---------------------------------------------------------------- files -- */

interface FolderWatch {
  watcher: FSWatcher
  listeners: Set<(relativePath: string) => void>
}

/**
 * One chokidar watcher per folder, however many routines want it.
 *
 * Reference-counted rather than one per routine, for the same reason the git
 * watches are: two routines on one project would otherwise be two recursive
 * watches over the same tree, and on macOS that is two `FSEvents` streams
 * delivering the same events.
 */
export class RoutineFileWatchers {
  private readonly folders = new Map<string, FolderWatch>()
  private stopped = false

  watch(folder: string, onChange: (relativePath: string) => void): Unsubscribe {
    if (this.stopped) return () => undefined
    const root = resolve(folder)
    let entry = this.folders.get(root)

    if (!entry) {
      const watcher = watch(root, {
        ignoreInitial: true,
        persistent: true,
        // A symlink out of the project is a path out of the project, and
        // following one would put a watch somewhere the routine never named.
        followSymlinks: false,
        depth: MAX_WATCH_DEPTH,
        // No `awaitWriteFinish`. It settles a file by re-reading its size on an
        // interval, which is a poll — and the engine already coalesces bursts
        // through each routine's `quiet-for`, which is the trailing-edge debounce
        // that half-written files actually need.
        ignored: (path: string) => {
          const rel = relative(root, path)
          if (rel === '') return false
          return rel.split(sep).some((part) => NEVER_WATCH.has(part))
        },
      })
      entry = { watcher, listeners: new Set() }
      this.folders.set(root, entry)

      const fire = (path: string): void => {
        const rel = relative(root, path)
        // A path outside the root can only mean the watcher followed something
        // it should not have. Dropped rather than reported, because a routine
        // matching `**/*` would otherwise fire on it.
        if (rel === '' || rel.startsWith('..')) return
        for (const listener of entry?.listeners ?? []) {
          try {
            listener(rel)
          } catch (error) {
            console.error('[routines] a file listener threw:', error)
          }
        }
      }
      watcher.on('add', fire)
      watcher.on('change', fire)
      watcher.on('unlink', fire)
      watcher.on('addDir', fire)
      watcher.on('unlinkDir', fire)
      watcher.on('error', (error: unknown) => {
        // Loud, because a watch that died is a routine that has silently
        // stopped having a trigger — which is the failure this whole feature
        // has to be able to distinguish from a quiet week.
        console.error('[routines] the file watch on', root, 'failed:', error)
      })
    }

    entry.listeners.add(onChange)
    return () => {
      const current = this.folders.get(root)
      if (!current) return
      current.listeners.delete(onChange)
      if (current.listeners.size > 0) return
      this.folders.delete(root)
      void current.watcher.close()
    }
  }

  async stop(): Promise<void> {
    this.stopped = true
    const all = [...this.folders.values()]
    this.folders.clear()
    await Promise.all(all.map((entry) => entry.watcher.close()))
  }
}

/* ------------------------------------------------------------------ git -- */

/**
 * A git subscription for a folder, with the watcher held open behind it.
 *
 * Two halves, and both are needed. `onGitStatusChanged` is how the main process
 * hears about a change; `holdGitWatch` is what guarantees there is something
 * producing changes to hear when no git panel is open. Releasing does not stop
 * the panel's own watch if there is one — see `releaseGitWatch`.
 */
export function watchGitFolder(folder: string, onChange: () => void): Unsubscribe {
  const root = resolve(folder)
  const off = onGitStatusChanged((cwd) => {
    if (resolve(cwd) === root) onChange()
  })
  // Deliberately not awaited. The first read is a `git status` on a folder that
  // may be enormous, and arming a routine must not be able to block the boot
  // sequence behind it; the subscription above is live either way, and a change
  // that lands before the first read still arrives.
  void holdGitWatch(root).catch((error: unknown) => {
    console.error('[routines] could not watch git in', root, error)
  })
  return () => {
    off()
    releaseGitWatch(root)
  }
}
