import { describe, expect, it } from 'vitest'
import { changeLabel as widgetLabel } from '../dashboard/widgets'
import {
  changeLabel,
  diffModeFor,
  GROUP_STATE,
  noDiffReason,
  parseUnifiedDiff,
  unavailableView,
  type GitChangeKind,
  type GitFile,
  type GitNotRepo,
  type GitStatusResult,
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

/**
 * The page Asad found empty.
 *
 *   > *"Source control shows nothing, so make sure it shows something whatever
 *   > is necessary to show."*
 *
 * He was in `~/Templates` — a folder he had picked because it was empty — so
 * "not a repository" was the truth. What was wrong was that the truth was the
 * whole page: a title, a sentence repeating the title, and no way from there to
 * a repository. The button is the fix, and these are the two ways it can go
 * wrong once it exists.
 */
describe('what Source control shows when there is no repository', () => {
  const notRepo = (over: Partial<GitNotRepo> = {}): GitStatusResult => ({
    repo: false,
    cwd: '/work/empty',
    reason: 'not-a-repo',
    message: 'This folder is not a git repository. Source control can create one.',
    ...over,
  })

  /**
   * Both halves, because the page had been through one of them already.
   *
   * The sentence was suppressed whenever the button was drawn — a title plus a
   * button already say "no repository, and here is how to get one" — and he
   * looked at the result and said *"Source control, nothing."* Two words and a
   * button is what nothing looks like. The Overview tile one click away had the
   * missing half all along.
   */
  it('says why it is empty and offers the repository', () => {
    const view = unavailableView(notRepo({ canInit: true }), true)
    expect(view.canInit).toBe(true)
    expect(view.title).toBe('Nothing to track here')
    expect(view.message).toBe('This folder is not a git repository.')
    // And not the tile's last clause, which points at this very page.
    expect(view.message).not.toContain('Source control can create one')
  })

  it('never offers to create one over a repository git is only refusing to read', () => {
    /*
     * Dubious ownership reports `not-a-repo` — it is the same discriminant —
     * and `git init` there would create a second repository beside the one
     * already on disk. `canInit` is what separates the two, and it is set in
     * `main/git.ts` rather than guessed here.
     */
    const refused = notRepo({ message: 'git refuses this folder: dubious ownership.' })
    const view = unavailableView(refused, true)
    expect(view.canInit).toBe(false)
    // And its message survives, because that one names a way out no title can.
    expect(view.message).toContain('dubious ownership')
  })

  it('keeps the sentence when the window has no way to create one', () => {
    // An older preload with no `gitInit`. The page loses the button and must
    // not also lose the only line explaining itself.
    const view = unavailableView(notRepo({ canInit: true }), false)
    expect(view.canInit).toBe(false)
    expect(view.message).toContain('not a git repository')
  })

  it('says something for every reason git.ts can report', () => {
    for (const reason of ['not-a-repo', 'git-missing', 'no-such-folder', 'error'] as const) {
      const view = unavailableView(notRepo({ reason, canInit: false }), true)
      expect(view.title.length, reason).toBeGreaterThan(0)
      expect(view.message.length, reason).toBeGreaterThan(0)
    }
  })

  /**
   * The titles are the Overview tile's, word for word.
   *
   * They were four different words for the same four situations — "Nothing to
   * track here" on the tile, "Not a repository" on the page it links to — while
   * `widgets.tsx` carried a comment claiming they were the same. Two names for
   * one situation is how somebody comes to believe they are looking at two
   * findings.
   */
  it('uses the same four headings the Overview tile uses', () => {
    const titles = (['not-a-repo', 'git-missing', 'no-such-folder', 'error'] as const).map(
      (reason) => unavailableView(notRepo({ reason, canInit: false }), true).title,
    )
    expect(titles).toEqual([
      'Nothing to track here',
      'git is not installed',
      'That folder is gone',
      'Source control is unavailable',
    ])
  })

  it('has a title for a status that never arrived at all', () => {
    const view = unavailableView(null, true)
    expect(view.title).toBe('Source control is unavailable')
    expect(view.canInit).toBe(false)
  })
})
