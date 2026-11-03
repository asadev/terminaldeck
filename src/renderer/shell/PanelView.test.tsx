import { describe, expect, it } from 'vitest'
import { filesBlankReason, filesPageState } from './PanelView'
import type { TreeRootState } from '../components/FileTree'

/**
 * The Files page contradicting itself, pinned.
 *
 * From the recording: the left column said **"Nothing to show."** while the
 * right one drew a `README.md` header over a blank body — at the same instant,
 * on the same screen. Neither component was wrong about itself. The tree had
 * listed the folder and found nothing; the viewer had been handed a path from
 * `App.tsx`, which holds the open file above this page and therefore keeps it
 * across a change of project.
 *
 * A page is not the sum of its parts' states. If the folder has nothing in it,
 * there is no file in it to be reading either.
 */
describe('filesPageState', () => {
  const state = (s: TreeRootState): TreeRootState => s

  /**
   * An empty folder gets the page, not a stripe.
   *
   * `tree-only` was the answer here until 2026-08-20, and the frame Asad
   * recorded is what changed it: the words "Nothing to show." in the top-left
   * of a whole window, over nothing, on a session he had deliberately started
   * in an empty folder. The tree was right and the page was useless — there was
   * no way from that screen to the one thing that would have changed it, which
   * is to stop hiding what `.gitignore` excludes. `blank` is the state that
   * hands the window to `PageEmpty` and puts that button on it.
   */
  it('gives the whole page over when the folder came back empty', () => {
    expect(filesPageState(state({ status: 'empty' }))).toBe('blank')
  })

  it('draws only the tree when the folder could not be read', () => {
    // The reason goes in the tree's own message. A file header beside it would
    // be claiming to have opened something out of a folder we cannot list.
    expect(filesPageState(state({ status: 'error', message: 'EACCES' }))).toBe('tree-only')
  })

  it('draws both once there is something in the folder', () => {
    expect(filesPageState(state({ status: 'ready', count: 12 }))).toBe('tree-and-viewer')
  })

  /**
   * Loading keeps the viewer, deliberately. The tree re-reads itself silently
   * whenever its cached copy has gone stale, and tearing the viewer down for
   * the duration would throw away the file somebody is reading every time a
   * background refresh ran.
   */
  it('keeps the viewer while the tree is still reading', () => {
    expect(filesPageState(state({ status: 'loading' }))).toBe('tree-and-viewer')
  })
})

/**
 * *"For files is empty, not showing anything."*
 *
 * No frame caught this page, so what it did is not in doubt and what it *said*
 * is: two words in the middle of a window, about a folder it never named. The
 * folder — `~/Templates` — really was empty, and being right without saying
 * what you read is indistinguishable from being broken.
 */
describe('filesBlankReason', () => {
  it('names the folder it listed', () => {
    expect(filesBlankReason('/Users/apple/Templates', false)).toContain('/Users/apple/Templates')
    expect(filesBlankReason('/Users/apple/Templates', true)).toContain('/Users/apple/Templates')
  })

  /**
   * The two empties are different facts. A folder whose every file is covered
   * by `.gitignore` — a downloads folder, a checkout mid-build — is not an
   * empty folder, and the page must not say it is while the filter is on.
   */
  it('says which pass produced the nothing', () => {
    expect(filesBlankReason('/p', false)).toContain('.gitignore')
    expect(filesBlankReason('/p', true)).toContain('ignored files included')
    expect(filesBlankReason('/p', true)).not.toContain('.gitignore')
  })
})
