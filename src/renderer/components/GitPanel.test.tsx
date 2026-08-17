import { describe, expect, it } from 'vitest'
import { changeLabel as widgetLabel } from '../dashboard/widgets'
import { changeLabel, type GitChangeKind } from './GitPanel'

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
