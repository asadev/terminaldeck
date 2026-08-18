import { describe, expect, it } from 'vitest'
import { changeLabel as widgetLabel } from '../dashboard/widgets'
import {
  changeLabel,
  diffModeFor,
  GROUP_STATE,
  noDiffReason,
  parseUnifiedDiff,
  type GitChangeKind,
  type GitFile,
} from './GitPanel'

/**
 * The status column, in words.
 *
 * Source control and the Overview git tile both used to print the letter git
 * prints, so an untracked file arrived as a bare `?` and the whole column read
 * as an error. Asad: *"what are these question marks? Is this normal? Is this
 * like for all of the other tools are also doing like this?"* — a fair question
 * about a column that answers nothing without a manual.
 *
 * The word is now the column, and the letter has moved into the row's tooltip.
 * These tests exist because the two screens hold two copies of the same table:
 * the dashboard cannot import this module for a value without pulling
 * `GitPanel.css` into its bundle, so the copy is deliberate — and the last test
 * here is the thing that stops the two from drifting apart.
 */
describe('the git status column reads as a word', () => {
  it('names every kind git.ts can produce', () => {
    expect(changeLabel('untracked', '?')).toBe('Untracked')
    expect(changeLabel('modified', 'M')).toBe('Modified')
    expect(changeLabel('added', 'A')).toBe('Added')
    expect(changeLabel('deleted', 'D')).toBe('Deleted')
    expect(changeLabel('renamed', 'R')).toBe('Renamed')
    expect(changeLabel('copied', 'C')).toBe('Copied')
    expect(changeLabel('typechange', 'T')).toBe('Type')
    expect(changeLabel('conflicted', 'UU')).toBe('Conflict')
  })

  it('never renders a bare question mark for an untracked file', () => {
    // The regression, stated as the thing that must not come back.
    expect(changeLabel('untracked', '?')).not.toBe('?')
  })

  it('keeps git’s own letter when the code is one this app does not know', () => {
    // An unrecognised code is a fact. Inventing English for it would be a
    // guess, and this is the one place where the letter is the honest answer.
    expect(changeLabel('unknown', 'X')).toBe('X')
    expect(changeLabel('unknown', ' Y ')).toBe('Y')
    expect(changeLabel('unknown', '')).toBe('?')
  })

  it('says the same thing on the dashboard tile as it does here', () => {
    const kinds: GitChangeKind[] = [
      'added',
      'modified',
      'deleted',
      'renamed',
      'copied',
      'typechange',
      'untracked',
      'conflicted',
      'unknown',
    ]
    for (const kind of kinds) {
      expect({ kind, word: widgetLabel(kind, '?') }).toEqual({
        kind,
        word: changeLabel(kind, '?'),
      })
    }
  })
})

/**
 * Source control shows the change, on Source control.
 *
 * The report: *"If I click on source control, click on something, it takes me
 * to files."* It did, and it had to — every row called `onSelectFile`, whose
 * only implementation opens the Files page, because this panel had no way to
 * render a diff. It had one all along: `git:diff` was registered in the main
 * process and exposed on the preload as `gitDiff`, with **zero callers in the
 * whole renderer**.
 *
 * These pin the three pure decisions the pane is built on. They fail if the
 * diff pane is removed, because the functions go with it.
 */
describe('the diff a row opens', () => {
  it('asks git the question the file’s group actually answers', () => {
    // Getting this wrong returns an empty string, not an error — a staged-only
    // change diffed as unstaged prints nothing, and "nothing" is
    // indistinguishable from "unchanged" on screen.
    expect(diffModeFor('staged')).toEqual({ staged: true })
    expect(diffModeFor('untracked')).toEqual({ untracked: true })
    expect(diffModeFor('unstaged')).toEqual({})
    // A conflict diffs like unstaged work: the working tree against the index.
    expect(diffModeFor('conflicted')).toEqual({})
  })

  it('drops git’s file header and keeps the hunk line', () => {
    // `diff --git`, `index …` and the `---`/`+++` pair say the file's name three
    // more times, in a language his audience does not read; the pane's heading
    // already says it once. The `@@` line is the only piece of that furniture
    // carrying information the heading does not — where in the file you are.
    const kinds = parseUnifiedDiff(
      ['diff --git a/x b/x', 'index 1..2 100644', '--- a/x', '+++ b/x', '@@ -1 +1 @@', '-a', '+b'].join('\n'),
    ).map((l) => l.kind)
    expect(kinds.filter((k) => k === 'meta')).toHaveLength(4)
    expect(kinds).toContain('hunk')
  })

  it('says where a change is waiting without repeating the list heading', () => {
    // "Modified · changes" and "Untracked · untracked" — the group's own label,
    // lowercased, standing in for a fact about the file.
    expect(GROUP_STATE.untracked).toBe('not tracked yet')
    expect(GROUP_STATE.staged).toBe('ready to commit')
    expect(GROUP_STATE.unstaged).toBe('not staged yet')
    expect(GROUP_STATE.conflicted).toBe('needs resolving')
    for (const state of Object.values(GROUP_STATE)) {
      expect(['changes', 'staged', 'untracked', 'conflicts']).not.toContain(state)
    }
  })

  it('never paints the file’s own name red and green', () => {
    // `---` and `+++` start with the same characters as a removal and an
    // addition. Classified as content they tint the header of every diff.
    const lines = parseUnifiedDiff(
      [
        'diff --git a/src/app.ts b/src/app.ts',
        'index 1111111..2222222 100644',
        '--- a/src/app.ts',
        '+++ b/src/app.ts',
        '@@ -1,3 +1,3 @@',
        ' const a = 1',
        '-const b = 2',
        '+const b = 3',
        '',
      ].join('\n'),
    )
    expect(lines.map((line) => line.kind)).toEqual([
      'meta',
      'meta',
      'meta',
      'meta',
      'hunk',
      'context',
      'del',
      'add',
    ])
    // The marker character is the list's, not the text's — it is rendered in
    // its own column so a line can be copied without it.
    expect(lines[6].text).toBe('const b = 2')
    expect(lines[7].text).toBe('const b = 3')
    expect(lines[5].text).toBe('const a = 1')
  })

  it('drops the terminating newline rather than inventing a last empty line', () => {
    expect(parseUnifiedDiff('')).toEqual([])
    expect(parseUnifiedDiff('+one\n')).toEqual([{ kind: 'add', text: 'one' }])
  })

  const file = (over: Partial<GitFile>): GitFile => ({
    path: 'src/app.ts',
    origPath: null,
    group: 'unstaged',
    code: ' M',
    kind: 'modified',
    score: null,
    insertions: 1,
    deletions: 1,
    binary: false,
    ...over,
  })

  it('says why a folder and a binary have no diff, instead of showing an empty pane', () => {
    // git lists an untracked directory as one entry ending in `/`. Asking for a
    // diff of it returns '', which would read as "no changes" — false, and
    // contradicting the row two centimetres to the left that says Untracked.
    expect(noDiffReason(file({ path: 'business/', kind: 'untracked' }))).toContain('folder')
    expect(noDiffReason(file({ binary: true }))).toContain('binary')
    // A text file that did change has no reason — it gets a diff.
    expect(noDiffReason(file({}))).toBeNull()
  })
})
