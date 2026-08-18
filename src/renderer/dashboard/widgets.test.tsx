import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import type { GitFile, GitFileGroup } from '../components/GitPanel'
import {
  cacheHitRate,
  changeLabel,
  formatPercent,
  formatTokens,
  getWidgetDefinition,
  listWidgetDefinitions,
  plural,
  readSection,
  usageLines,
  UsageReadout,
  visibleGitFiles,
  WIDGET_DEADLINE_MS,
  type UsageView,
} from './widgets'
import { isRetiredWidget, WIDGET_TYPES } from './layout'

describe('formatTokens', () => {
  it('rolls past a million into billions', () => {
    // A project with four billion cached tokens read "4622.27M" — a number
    // nobody can size at a glance, in a tile whose whole job is a glance.
    expect(formatTokens(4_622_270_000)).toBe('4.62B')
    expect(formatTokens(1_000_000_000)).toBe('1B')
  })

  it('keeps the tiers it already had', () => {
    expect(formatTokens(0)).toBe('0')
    expect(formatTokens(999)).toBe('999')
    expect(formatTokens(41_800)).toBe('41.8k')
    expect(formatTokens(1_500_000)).toBe('1.5M')
  })

  it('never rounds a tier up into the next one', () => {
    // 999_950 tokens is 1000.0k, which would print as "1000k".
    expect(formatTokens(999_950)).toBe('1M')
    expect(formatTokens(999_999_500)).toBe('1B')
  })

  it('handles a negative the same way', () => {
    expect(formatTokens(-4_622_270_000)).toBe('-4.62B')
  })
})

describe('plural', () => {
  it('does not print "1 sessions"', () => {
    expect(plural(1, 'session')).toBe('session')
    expect(plural(0, 'session')).toBe('sessions')
    expect(plural(2, 'session')).toBe('sessions')
  })

  it('takes an irregular plural when one is given', () => {
    expect(plural(1, 'is', 'are')).toBe('is')
    expect(plural(3, 'is', 'are')).toBe('are')
  })
})


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
    expect(listWidgetDefinitions().map((d) => d.type)).toEqual(
      WIDGET_TYPES.filter((type) => !isRetiredWidget(type)),
    )
  })

  /**
   * A retired type keeps its definition so a saved layout that already holds
   * the tile goes on rendering it — only the *offer* goes. Dropping the
   * definition instead would blank out somebody's arrangement on the next open.
   */
  it('keeps a definition for the type it stopped offering', () => {
    expect(listWidgetDefinitions().map((d) => d.type)).not.toContain('sessions')
    expect(getWidgetDefinition('sessions')).toBeDefined()
  })

  it('does not resolve inherited object properties as widgets', () => {
    expect(getWidgetDefinition('constructor' as never)).toBeUndefined()
    expect(getWidgetDefinition('toString' as never)).toBeUndefined()
  })
})

/* ---------------------------------------------------------- the usage tile */

/**
 * The tile shows no money at all, and this is what keeps it that way.
 *
 * It used to carry two figures, `$100–200 on plan` beside `$2 on API`, and then
 * a single `$4558 at API rates` once the plan half was deleted. Asad on the
 * survivor: *"people are using subscription and we are showing API price. So if
 * we cannot show the both, let's not show any of them completely."* The full
 * argument is at the bottom of `src/main/cost.ts`.
 *
 * These pin the absence by name — the failure mode is somebody re-adding the
 * tile and reaching for the mirror table that used to feed it, and deleting the
 * symbols is what makes that reach fail at the import rather than at review.
 */
describe('the usage tile prices nothing', () => {
  const source = readFileSync(join(__dirname, 'widgets.tsx'), 'utf8')
  const code = source.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '')

  it('exports nothing that prices anything', () => {
    for (const name of [
      'formatUsd',
      'formatRate',
      'costLines',
      'CostReadout',
      'RATES_VERIFIED_ON',
      'planKey',
      'planName',
      'PLAN_PRICES',
      'planFee',
      'billingMonths',
      'formatUsdRange',
    ]) {
      const present =
        source.includes(`export function ${name}`) ||
        source.includes(`export const ${name}`) ||
        source.includes(`export interface ${name}`)
      expect({ name, present }).toEqual({ name, present: false })
    }
  })

  it('has no currency symbol left in its code', () => {
    // Comments are stripped: this file explains at length what was deleted, and
    // the explanation necessarily writes the figures down. `$${`, `$0` and a
    // `$` beside a quote or a space are what money looks like; a bare `$` is
    // also a regex anchor and a template brace, which is why the test is not
    // one.
    expect(code).not.toMatch(/\$\$\{|\$\d|\$['"`\s]/)
  })
})

/**
 * The totals have to add up in public.
 *
 * This suite was `the API figure explains itself`, and it existed because
 * `$2.33` beside `2.07M tokens` read as a bug to anybody who knows what Opus
 * costs per million. The money is gone; the property that survives it is the
 * one that made the breakdown worth having — every line is part of one whole,
 * and the parts sum to it.
 */
describe('the token breakdown explains itself', () => {
  const tokens = { input: 2000, output: 2540, cacheWrite: 21_857, cacheRead: 30_415 }

  it('itemises the total in the order a request is recorded', () => {
    // Fixed order, not sorted by size: a statement that reorders itself between
    // two viewings is one nobody can compare.
    expect(usageLines(tokens).map((line) => line.label)).toEqual([
      'Fresh input',
      'Cache writes',
      'Cache reads',
      'Output',
    ])
  })

  it('adds back up to the total it explains', () => {
    const lines = usageLines(tokens)
    const summed = lines.reduce((total, line) => total + line.tokens, 0)
    expect(summed).toBe(tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead)
    expect(lines.reduce((total, line) => total + line.share, 0)).toBeCloseTo(1, 12)
  })

  it('gives an empty session shares of zero rather than a division by zero', () => {
    const empty = usageLines({ input: 0, output: 0, cacheWrite: 0, cacheRead: 0 })
    expect(empty.every((line) => line.share === 0)).toBe(true)
  })

  it('reports the cache hit rate that makes the counts the shape they are', () => {
    // 90% hits is the whole reason a folder shows millions of prompt tokens
    // across a couple of hundred requests.
    expect(cacheHitRate({ input: 250, output: 9999, cacheWrite: 0, cacheRead: 750 })).toBeCloseTo(
      0.75,
      10,
    )
    expect(cacheHitRate({ input: 0, output: 0, cacheWrite: 0, cacheRead: 0 })).toBe(0)
    // Output is not part of the prompt, so it cannot dilute the hit rate.
    expect(cacheHitRate({ input: 0, output: 9999, cacheWrite: 0, cacheRead: 100 })).toBe(1)
  })

  it('never rounds a real cache hit down to nothing', () => {
    expect(formatPercent(0.004)).toBe('<1%')
    expect(formatPercent(0)).toBe('0%')
    expect(formatPercent(0.9)).toBe('90%')
    expect(formatPercent(1)).toBe('100%')
  })
})

/* ------------------------------------------------------- the tile, rendered */

/**
 * The tile as a person actually reads it.
 *
 * Every figure below is verbatim from `cost:project` for this repo on this
 * machine on 2026-08-17 — 35 requests over 9 transcripts, 2,066,852 tokens of
 * which 1,920,129 were cache reads. That is the session Asad was looking at
 * when he called the tile inaccurate, so it is the one the copy has to survive
 * being read on.
 *
 * `UsageReadout` takes its data as a prop precisely so this is possible:
 * effects do not run under `renderToStaticMarkup`, so the fetching component
 * could only ever be rendered mid-load and none of the wording below would be
 * reachable.
 */
describe('the usage tile, rendered on a real project', () => {
  const DATA: UsageView = {
    tokens: { input: 70, output: 18_888, cacheWrite: 127_765, cacheRead: 1_920_129 },
    requests: 35,
    sessions: 9,
    context: {
      id: 'ec925921-12f2-47cf-b9b0-a6c06dd6dc4b',
      model: 'claude-opus-5',
      percent: 3.1836,
      tokens: 31_836,
      window: 1_000_000,
    },
    models: ['claude-opus-5', 'claude-sonnet-5'],
    scanning: false,
    truncated: false,
  }

  function render(overrides: Partial<UsageView> = {}, expanded = false): string {
    return renderToStaticMarkup(
      <UsageReadout data={{ ...DATA, ...overrides }} expanded={expanded} onToggle={() => undefined} />,
    )
  }

  it('shows no dollar figure, expanded or collapsed', () => {
    // The whole point. `$4558.00` was false for the man reading it, and no
    // label rescues a four-figure sum nobody was charged.
    for (const expanded of [false, true]) {
      const markup = render({}, expanded)
      expect(markup).not.toMatch(/[$]/)
      expect(markup).not.toMatch(/spent/i)
      expect(markup).not.toMatch(/\bcost\b/i)
      expect(markup).not.toMatch(/API rates/i)
    }
  })

  it('leads with the tokens and says where they came from, naming no tool', () => {
    const markup = render()
    expect(markup).toContain('2.07M')
    expect(markup).toContain('tokens')
    // The source, and the one word that makes the figure checkable: an API
    // request appears many times in a session record and again in every resumed
    // copy of it, so "counted once" is the claim the arithmetic has to earn.
    // See the cross-file de-duplication in `src/main/transcript.ts`.
    expect(markup).toContain('counted once, from their own session records')
    // *"You should not mention in any settings or any pop-up a specific tool or
    // LLM, because they can use some other also."*
    expect(markup).not.toMatch(/Claude|Codex|Gemini/)
  })

  it('puts the cache hit rate beside the counts it explains', () => {
    // 1,920,129 of 2,047,964 prompt tokens came from cache. Without it on
    // screen, two million tokens across thirty-five requests reads as a bug.
    const markup = render()
    expect(markup).toContain('94%')
    expect(markup).toContain('from cache')
    expect(markup).toContain('re-read each turn rather than sent again')
  })

  it('names the models the folder’s work ran on', () => {
    const markup = render()
    expect(markup).toContain('Models seen: claude-opus-5, claude-sonnet-5')
  })

  it('says which model’s window the context percent is measured against', () => {
    // PLAN-LOCAL-FIRST §G: "context window must say whose". 3% of 200k and 3%
    // of a million are the same reading of two different situations.
    const markup = render()
    expect(markup).toContain('session ec925921')
    expect(markup).toContain('on claude-opus-5')
    expect(markup).toContain('31.8k of its 1M window')
  })

  it('still names the window when the transcript never named a model', () => {
    // The old copy dropped the whole caption when the model id was missing,
    // which took the denominator with it and left a bare percentage.
    const markup = render({ context: { ...DATA.context!, model: '' } })
    expect(markup).toContain('31.8k of a 1M window')
    expect(markup).not.toContain('on claude-opus-5')
  })

  it('says nothing about a subscription plan', () => {
    // The tile used to probe the signed-in account so it could caption the API
    // figure with "this account is on Max, which is not billed per token".
    // With no figure to caption, the probe and the caption both went.
    const markup = render()
    expect(markup).not.toMatch(/\bMax\b/)
    expect(markup).not.toMatch(/\bPro\b/)
    expect(markup).not.toMatch(/per token/i)
    expect(markup).not.toMatch(/month/i)
  })

  it('itemises the counts when the tile is opened', () => {
    const markup = render({}, true)
    for (const label of ['Fresh input', 'Cache writes', 'Cache reads', 'Output', 'Total']) {
      expect(markup).toContain(label)
    }
    // Cache reads are 93% of everything this folder moved, which is the line
    // that makes the total legible.
    expect(markup).toContain('93%')
    // The four lines add back up to the headline, which is the entire job of
    // this breakdown.
    expect(markup).toContain('How 2.07M tokens is made up')
    /*
     * And nothing else.
     *
     * A thirty-five-row list of transcript ids used to follow — "The same total
     * across 35 sessions, heaviest first" — rows reading `e79f7c36 ·
     * claude-opus-4-8 · 3071 · 1.61B`. Asad: a long list of old sessions that
     * is not in the sidebar, where every row opens the same session. *"They
     * make no sense to be here, I think, in that case."*
     *
     * They could not have opened their own: `cost:project` carries no session
     * title, so a row names nothing recognisable, and `onOpenInspector` takes
     * no argument — it opens the most recently active transcript whichever row
     * is pressed. Asserted as an absence so it cannot quietly return.
     */
    expect(markup).not.toContain('heaviest first')
    expect(markup).not.toContain('widget-list-breakdown')
  })

  it('withholds the context meter entirely rather than drawing an anonymous one', () => {
    // A percent that cannot name its session is not a fact anybody can act on.
    const markup = render({ context: null })
    expect(markup).not.toContain('Context window')
  })

  it('says nothing recorded rather than a row of zeroes', () => {
    const markup = render({ requests: 0 })
    expect(markup).toContain('Nothing recorded yet')
  })

  /*
   * The claim in the headline has to match what was actually counted.
   *
   * On 2026-08-18 this tile read "Nothing recorded yet" over
   * `~/Projects/terminaldeck`, a folder holding three months of work, because
   * the scan's forty slots had all been taken by sessions that were opened and
   * closed without recording anything — the newest transcript carrying a single
   * request was number 79 of 104 by modification time. That is fixed in the main
   * process, where the cap now counts conversations that recorded something; the
   * two tests below hold the *sentence* to the same standard, so a cap that
   * still bites can never again be printed under the word "every".
   */
  it('promises "every request" only when nothing was left unread', () => {
    const markup = render({ truncated: false })
    expect(markup).toContain('every request your agents made in this folder')
    expect(markup).not.toContain('Older work not read')
  })

  it('withdraws the promise, in Artifacts’ own words, when work was left unread', () => {
    const markup = render({ truncated: true })
    expect(markup).not.toContain('every request your agents made in this folder')
    expect(markup).toContain('Older work not read')
  })

  it('does not tell somebody with a full history that they have not started yet', () => {
    // Nothing counted *and* work left unread is not an empty folder, and the
    // difference is the whole of the defect above.
    const markup = render({ requests: 0, truncated: true })
    expect(markup).toContain('Older work was not read')
    expect(markup).not.toContain('recorded its first request')
  })
})

/* ------------------------------------------------------------- git status word */

describe('git status reads as a word', () => {
  it('says Untracked rather than a bare question mark', () => {
    // His question, on a column of them: "what are these question marks?"
    expect(changeLabel('untracked', '?')).toBe('Untracked')
    expect(changeLabel('modified', 'M')).toBe('Modified')
    expect(changeLabel('added', 'A')).toBe('Added')
    expect(changeLabel('deleted', 'D')).toBe('Deleted')
    expect(changeLabel('conflicted', 'UU')).toBe('Conflict')
  })

  it('keeps git’s own letter for a code it does not recognise', () => {
    // Inventing English for something unrecognised is worse than showing what
    // git actually said.
    expect(changeLabel('unknown', 'X')).toBe('X')
    expect(changeLabel('unknown', '')).toBe('?')
  })
})

/* ------------------------------------------------------------ nothing hangs -- */

/**
 * Two of the tiles on this page were caught in the recording still saying
 * "Reading transcripts…" and "Reading the repo…" long after the page had
 * settled. `useBridgeData` had four states and could only ever *leave*
 * `loading` if the bridge's promise settled — which is not a property of
 * `ipcRenderer.invoke`.
 *
 * There is no DOM in this project's tests, so the hook cannot be driven here;
 * `deadline.test.ts` proves the mechanism and this pins the two things about it
 * that are a judgement rather than a mechanism: that a deadline exists at all,
 * and that every widget hands over its own words for the sentence it prints.
 */
describe('every widget read is bounded', () => {
  it('gives a tile long enough for a real scan and no longer', () => {
    // The cost tile totals a project's transcripts in the main process under
    // its own budget; past this it has not started rather than not finished.
    expect(WIDGET_DEADLINE_MS).toBeGreaterThanOrEqual(10_000)
    expect(WIDGET_DEADLINE_MS).toBeLessThanOrEqual(30_000)
  })

  it('names the read in the widget’s words, never a bridge method', () => {
    const source = readFileSync(join(__dirname, 'widgets.tsx'), 'utf8')
    const named = [...source.matchAll(/\{ (?:enabled: [^,]+, )?what: '([^']+)' \}/g)].map((m) => m[1])
    // One per widget that fetches. A tile added without one falls back to a
    // generic sentence, which is honest but says nothing about which tile.
    expect(named.length).toBe(5)
    for (const phrase of named) {
      expect(phrase).not.toMatch(/^(get|list|scan)[A-Z]/)
      expect(phrase.endsWith('…')).toBe(false)
    }
  })
})
