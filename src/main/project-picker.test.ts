import { describe, expect, it } from 'vitest'
import { pickerStartDirectory, type DirectoryCheck } from './project-picker'

/**
 * The rule that keeps the macOS folder picker from opening on nothing.
 *
 * The defect these pin is not hypothetical and not subtle: four openings in a
 * recorded walkthrough, an empty file list every single time, because
 * `showOpenDialog` was given no `defaultPath` and AppKit stood the panel back
 * up in the empty folder it was left in. See the module note for the bookmark
 * read off the machine.
 */

/** Directories that exist in this fake world. Everything else does not. */
function only(...dirs: string[]): DirectoryCheck {
  const set = new Set(dirs)
  return (path) => set.has(path)
}

const HOME = '/Users/apple'

describe('pickerStartDirectory', () => {
  it('opens beside the most recently opened project', () => {
    const dir = pickerStartDirectory(
      [{ path: '/Users/apple/Projects/terminaldeck' }, { path: '/Users/apple/Code/thing' }],
      HOME,
      only('/Users/apple/Projects', '/Users/apple/Code'),
    )
    expect(dir).toBe('/Users/apple/Projects')
  })

  it('never opens in a folder that cannot contain a project', () => {
    /*
     * The whole failure, in one assertion. The parent of the newest project is
     * a directory that project lives in, so it has at least one row in it — the
     * panel structurally cannot open on an empty list the way it did on his
     * machine, where it stood in `/Users/apple/Tclaude/untitled folder`.
     */
    const projects = [{ path: '/Users/apple/Tclaude/untitled folder' }]
    const dir = pickerStartDirectory(projects, HOME, only('/Users/apple/Tclaude'))
    expect(dir).toBe('/Users/apple/Tclaude')
    expect(projects[0].path.startsWith(`${dir}/`)).toBe(true)
  })

  it('skips a project whose folder has gone, rather than pointing at it', () => {
    // An unmounted volume, or a folder the user deleted. Handing either to the
    // panel is how it opens on nothing again.
    const dir = pickerStartDirectory(
      [{ path: '/Volumes/Archive/old-app' }, { path: '/Users/apple/Projects/terminaldeck' }],
      HOME,
      only('/Users/apple/Projects'),
    )
    expect(dir).toBe('/Users/apple/Projects')
  })

  it('falls back to the home folder when nothing else survives', () => {
    expect(pickerStartDirectory([{ path: '/Volumes/Gone/x' }], HOME, only())).toBe(HOME)
    expect(pickerStartDirectory([], HOME, only())).toBe(HOME)
  })

  it('refuses a relative path from a corrupted store', () => {
    // `dirname('terminaldeck')` is `.`, and AppKit would resolve that against
    // the app bundle — a folder full of `Contents/`, which is worse than home.
    expect(pickerStartDirectory([{ path: 'terminaldeck' }], HOME, only('.'))).toBe(HOME)
  })

  it('ignores entries with no usable path instead of throwing', () => {
    const junk = [{ path: '' }, {} as { path: string }, { path: '/Users/apple/Projects/x' }]
    expect(pickerStartDirectory(junk, HOME, only('/Users/apple/Projects'))).toBe(
      '/Users/apple/Projects',
    )
  })
})
