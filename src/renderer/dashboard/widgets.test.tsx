import { describe, expect, it } from 'vitest'
import type { GitFile, GitFileGroup } from '../components/GitPanel'
import { getWidgetDefinition, listWidgetDefinitions, readSection, visibleGitFiles } from './widgets'
import { WIDGET_TYPES } from './layout'

/**
 * The widgets themselves need a DOM and a preload bridge, neither of which this
 * suite has. What it can test is the logic that decides *what* a widget claims:
 * how many rows it is hiding, and what it keys them on. Both were wrong, and
 * both are wrong in the quiet way — the widget renders, it just lies.
 */

function file(path: string, group: GitFileGroup): GitFile {
  return {
    path,
    origPath: null,
    group,
    code: group === 'conflicted' ? 'UU' : 'M ',
    kind: 'modified',
    score: null,
    insertions: null,
    deletions: null,
    binary: false,
  }
}

function status(counts: Partial<Record<GitFileGroup, number>>) {
  const group = (name: GitFileGroup): GitFile[] =>
    Array.from({ length: counts[name] ?? 0 }, (_, i) => file(`${name}/${i}.ts`, name))
  return {
    conflicted: group('conflicted'),
    staged: group('staged'),
    unstaged: group('unstaged'),
    untracked: group('untracked'),
  }
}

describe('visibleGitFiles', () => {
  it('shows everything and hides nothing when the list fits', () => {
    const { shown, hidden } = visibleGitFiles(status({ staged: 3, untracked: 2 }))
    expect(shown).toHaveLength(5)
    expect(hidden).toBe(0)
  })

  it('counts conflicts in the overflow, not just the other three groups', () => {
    // Regression. The rendered list has always led with conflicts, but the
    // "…and N more" figure was summed from staged + unstaged + untracked only.
    // With 5 conflicts and 38 other changes the list showed 40 of 43 and the
    // note never appeared — three files silently gone from a repo mid-merge.
    const { shown, hidden } = visibleGitFiles(
      status({ conflicted: 5, staged: 20, unstaged: 10, untracked: 8 }),
    )
    expect(shown).toHaveLength(40)
    expect(hidden).toBe(3)
  })

  it('never disagrees with its own list, at any group mix', () => {
    for (const conflicted of [0, 1, 7, 45]) {
      for (const staged of [0, 3, 39]) {
        const source = status({ conflicted, staged, unstaged: 4, untracked: 2 })
        const total = conflicted + staged + 4 + 2
        const { shown, hidden } = visibleGitFiles(source)
        expect(shown.length + hidden).toBe(total)
        expect(hidden).toBeGreaterThanOrEqual(0)
      }
    }
  })

  it('puts conflicts first, because they are what blocks the user', () => {
    const { shown } = visibleGitFiles(status({ conflicted: 2, staged: 2 }))
    expect(shown.map((f) => f.group)).toEqual(['conflicted', 'conflicted', 'staged', 'staged'])
  })

  it('survives an empty repo and a nonsense limit', () => {
    expect(visibleGitFiles(status({}))).toEqual({ shown: [], hidden: 0 })
    expect(visibleGitFiles(status({ staged: 3 }), 0)).toEqual({ shown: [], hidden: 3 })
    expect(visibleGitFiles(status({ staged: 3 }), -5).hidden).toBe(3)
  })
})

describe('readSection', () => {
  const section = (value: unknown[]) => ({ pulls: { ok: true, value } })

  it('gives every row a distinct key even when entries carry no number', () => {
    // Regression: keys were `${kind}-${number || index}`, which falls back to
    // the index exactly when the number is missing — and an index collides with
    // whatever real number happens to equal it. `#1` first, then a numberless
    // entry at index 1, and both keyed `pr-1`; React reuses one row for the
    // other and the wrong title lands on the wrong number.
    const { items } = readSection(section([{ number: 1, title: 'PR 1' }, { title: 'no number' }]), 'pulls', 'pr')
    expect(items).toHaveLength(2)
    expect(new Set(items.map((i) => i.key)).size).toBe(2)
  })

  it('keeps keys distinct across a realistic mixed page', () => {
    const value = [{ number: 3 }, { number: 1 }, { title: 'no number' }, { number: 2 }]
    const { items } = readSection(section(value), 'pulls', 'pr')
    expect(new Set(items.map((i) => i.key)).size).toBe(4)
  })

  it('does not collide across the two sections it merges', () => {
    const prs = readSection(section([{ number: 1 }]), 'pulls', 'pr')
    const issues = readSection({ issues: { ok: true, value: [{ number: 1 }] } }, 'issues', 'issue')
    expect(new Set([...prs.items, ...issues.items].map((i) => i.key)).size).toBe(2)
  })

  it('still reports the real number for display', () => {
    const { items } = readSection(section([{ number: 412, title: 'Fix the thing' }]), 'pulls', 'pr')
    expect(items[0]).toMatchObject({ number: 412, title: 'Fix the thing', kind: 'pr' })
  })

  it('surfaces a section that failed rather than reading it as empty', () => {
    const failed = readSection({ issues: { ok: false, message: 'gh auth login required' } }, 'issues', 'issue')
    expect(failed).toEqual({ items: [], error: 'gh auth login required' })
  })

  it('treats a missing section as absent, not as a failure', () => {
    expect(readSection({}, 'pulls', 'pr')).toEqual({ items: [], error: null })
  })

  it('drops junk entries instead of rendering `undefined`', () => {
    const { items } = readSection(section([null, 'nope', 7, { title: 'real' }]), 'pulls', 'pr')
    expect(items).toHaveLength(1)
    expect(items[0].title).toBe('real')
  })
})

describe('registry', () => {
  it('has a definition for every type the picker offers', () => {
    expect(listWidgetDefinitions().map((d) => d.type)).toEqual([...WIDGET_TYPES])
  })

  it('does not resolve inherited object properties as widgets', () => {
    expect(getWidgetDefinition('constructor' as never)).toBeUndefined()
    expect(getWidgetDefinition('toString' as never)).toBeUndefined()
  })
})
