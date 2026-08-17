import { describe, expect, it } from 'vitest'
import { filesPageState } from './PanelView'
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

  it('draws only the tree when the folder came back empty', () => {
    expect(filesPageState(state({ status: 'empty' }))).toBe('tree-only')
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
