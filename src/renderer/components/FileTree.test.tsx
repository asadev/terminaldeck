import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { FileTree, rootStateOf, shouldAutoOpen, type FsEntry } from './FileTree'

/**
 * There is no DOM environment in this project's test setup, so effects do not
 * run here and the auto-open cannot be driven end to end. It is split for
 * exactly that reason: *which* file to open is decided in
 * `src/main/fs-tree.ts` and tested there against a real directory, and *when*
 * the tree is allowed to open one is `shouldAutoOpen`, which is pure and is
 * tested here.
 */

const ROOT = '/Users/a/proj'

function ask(overrides: Partial<Parameters<typeof shouldAutoOpen>[0]> = {}): boolean {
  return shouldAutoOpen({
    autoSelect: true,
    dir: '',
    root: ROOT,
    openedFor: null,
    selected: null,
    ...overrides,
  })
}

describe('shouldAutoOpen', () => {
  it('opens a file when a project’s root lands with nothing selected', () => {
    // The whole point: the page arrives on content instead of on the sentence
    // "pick something from the tree and it opens here".
    expect(ask()).toBe(true)
  })

  it('never opens from a directory the reader expanded', () => {
    // Expanding `src/` must not yank the viewer to `src/index.ts`.
    expect(ask({ dir: 'src' })).toBe(false)
  })

  it('leaves an already-open file alone', () => {
    // Arriving at Files from Source control, with a changed file open, must
    // show that file rather than the README.
    expect(ask({ selected: 'src/changed.ts' })).toBe(false)
  })

  it('opens once per project, not on every re-listing', () => {
    // The root is listed again when an ignore file is edited or showIgnored is
    // toggled; neither may drag the reader back to the README.
    expect(ask({ openedFor: ROOT })).toBe(false)
    // A different project is a different question.
    expect(ask({ openedFor: '/Users/a/other' })).toBe(true)
  })

  it('does nothing at all when the caller turned it off', () => {
    // A tree used as a picker inside a dialog must not answer the question the
    // reader was asked.
    expect(ask({ autoSelect: false })).toBe(false)
  })
})

describe('FileTree', () => {
  it('is a tree a screen reader can drive', () => {
    const html = renderToStaticMarkup(<FileTree root={ROOT} />)
    expect(html).toContain('role="tree"')
    expect(html).toContain('aria-label="Project files"')
    // One tab stop, with a virtual cursor — arrows must not steal focus from
    // the terminal row by row.
    expect(html).toContain('tabindex="0"')
  })
})

/* ----------------------------------------------- one condition, one sentence -- */

/** A tree state built by hand, the way the reducer would have left it. */
function treeState(over: Partial<Parameters<typeof rootStateOf>[0]> = {}) {
  return {
    children: new Map<string, FsEntry[]>(),
    expanded: new Set<string>(),
    loading: new Set<string>(),
    errors: new Map<string, string>(),
    truncated: new Set<string>(),
    focused: null,
    ...over,
  }
}

const FILE: FsEntry = {
  name: 'README.md',
  relPath: 'README.md',
  kind: 'file',
  symlink: false,
  blocked: false,
}

/**
 * The tree used to print its three messages from three independent conditions
 * over two pieces of state, and two of them could both be true. The frame Asad
 * caught has "Nothing to show." on the left of the Files page while the right
 * half heads a README — the tree claiming a project is empty during a window
 * where it had simply not finished looking.
 */
describe('rootStateOf', () => {
  it('is loading until the root has actually been listed', () => {
    expect(rootStateOf(treeState())).toEqual({ status: 'loading' })
    expect(rootStateOf(treeState({ loading: new Set(['']) }))).toEqual({ status: 'loading' })
  })

  it('never says a project is empty before the listing has landed', () => {
    // The gap between the reducer's reset and the request that follows it, and
    // the whole of a re-read whose reply the generation guard dropped.
    expect(rootStateOf(treeState()).status).not.toBe('empty')
  })

  it('says empty only when the listing came back with nothing in it', () => {
    expect(rootStateOf(treeState({ children: new Map([['', []]]) }))).toEqual({ status: 'empty' })
  })

  it('carries the reason a failed listing failed', () => {
    const state = treeState({ errors: new Map([['', 'Reading this folder did not answer within 10 seconds.']]) })
    expect(rootStateOf(state)).toEqual({
      status: 'error',
      message: 'Reading this folder did not answer within 10 seconds.',
    })
  })

  /**
   * A background re-read must not blank a list somebody is using. The tree is
   * re-listed silently whenever the cached copy has gone stale, and a `loading`
   * answer at that moment would replace the rows with the word "Loading…".
   */
  it('stays ready while a re-read runs behind rows that are already on screen', () => {
    const state = treeState({ children: new Map([['', [FILE]]]), loading: new Set(['']) })
    expect(rootStateOf(state)).toEqual({ status: 'ready', count: 1 })
  })
})
