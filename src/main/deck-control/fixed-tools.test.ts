import { describe, expect, it } from 'vitest'
import type { FixedShownResults, StaysFixedStatus } from '../staysfixed/service'
import { askedBy, fixedTools, MAX_CHECK_WAIT_SECONDS, resultsForModel, type FixedToolDeps } from './fixed-tools'
import { contextFor, fakeSurface, toolNamed } from './sessions-lane.fixture'
import { Refused } from './surface'

/**
 * The Stays Fixed tools against fake service closures: the tiers, the owner's
 * question on marking good, the waiting, the folder rule, and that a model
 * never gets the picture bytes. The service itself is proved end to end on a
 * real project in `staysfixed/service.test.ts`.
 */

const PROJECT = '/work/api'

function results(extra: Partial<FixedShownResults> = {}): FixedShownResults {
  return {
    runId: 'r1',
    at: '2026-10-04T00:00:00.000Z',
    durationMs: 3000,
    verdict: 'differences',
    headline: '1 difference nobody asked for.',
    against: '1.0.0',
    checked: '1.0.0 with uncommitted changes',
    differences: [
      {
        id: 'f-1',
        title: 'The total changed.',
        needsPerson: true,
        needsPersonWhy: 'It touches money.',
        count: 1,
        changes: [{ what: 'What it printed.', before: 'Total: 10.00', after: 'Total: 10.0', kind: 'changed' }],
        more: 0,
        journeys: ['greet --help'],
      },
    ],
    unchanged: 'Everything else it looked at — 11 things — is unchanged.',
    notChecked: null,
    unsteady: 0,
    detail: 'The engine’s paragraph.',
    gaps: [],
    pictures: { 'f-1': [{ journey: 'greet --help', before: 'data:image/png;base64,AAAA', after: 'data:image/png;base64,BBBB' }] },
    ...extra,
  }
}

function status(extra: Partial<StaysFixedStatus> = {}): StaysFixedStatus {
  return {
    projectPath: PROJECT,
    available: true,
    unavailable: null,
    versionNote: '',
    setUp: true,
    configFile: 'staysfixed.config.js',
    git: true,
    agents: true,
    guards: [{ name: 'the total keeps its pennies', because: 'It printed 10.0 once.', file: '/x' }],
    guardProblem: null,
    reference: { buildId: 'b', name: '1.0.0', setAt: '2026-10-01T00:00:00Z', setBy: 'staysfixed ship', forced: false },
    last: results(),
    running: null,
    ...extra,
  }
}

function deps(overrides: Partial<FixedToolDeps> = {}): { deps: FixedToolDeps; calls: string[] } {
  const calls: string[] = []
  const value: FixedToolDeps = {
    status: async (project) => {
      calls.push(`status ${project}`)
      return status()
    },
    readiness: async () => ({ ready: ['web apps and sites'], gaps: [], notHere: [], summary: '', git: true }),
    setup: async (project) => {
      calls.push(`setup ${project}`)
      return { ok: true, wrote: ['staysfixed.config.js'], problem: null, readiness: null }
    },
    check: async (project, by) => {
      calls.push(`check ${project} by ${by}`)
      return results()
    },
    progress: () => null,
    stop: () => true,
    waitFor: async () => results(),
    results: () => results(),
    markGood: async (project, anyway) => {
      calls.push(`mark ${project} ${anyway}`)
      return { ok: true, marked: true, already: false, refused: null, refusedFor: null, summary: 'Marked as good.' }
    },
    setAgents: async (project, on) => {
      calls.push(`agents ${project} ${on}`)
      return status({ agents: on })
    },
    ...overrides,
  }
  return { deps: value, calls }
}

describe('the Stays Fixed tools', () => {
  it('carries the tiers the page’s buttons deserve', () => {
    const tiers = Object.fromEntries(fixedTools(deps().deps).map((spec) => [spec.id, spec.tier]))
    expect(tiers).toEqual({
      'fixed.status': 'read',
      'fixed.setup': 'alter',
      'fixed.check': 'act',
      'fixed.results': 'read',
      'fixed.stop': 'act',
      'fixed.mark_good': 'alter',
      'fixed.agents': 'alter',
    })
  })

  it('always puts marking a build as good to the owner, whatever a key’s setting says', () => {
    const mark = toolNamed(fixedTools(deps().deps), 'fixed.mark_good')
    expect(mark.ownerMustAnswer?.({ project: PROJECT })).toBe(true)
    expect(mark.summary({ project: PROJECT, anyway: true }, contextFor(fakeSurface().surface))).toMatch(/accepting the differences/)
  })

  it('holds every tool behind tools.describe with a line to choose by', () => {
    for (const spec of fixedTools(deps().deps)) {
      expect(spec.index, spec.id).toBeTruthy()
      expect(spec.wire).toBe(spec.id.replace('.', '_'))
    }
  })

  it('refuses a folder this app does not have open, before anything runs', async () => {
    const { deps: d, calls } = deps()
    const check = toolNamed(fixedTools(d), 'fixed.check')
    await expect(check.run({ project: '/etc' }, contextFor(fakeSurface().surface))).rejects.toBeInstanceOf(Refused)
    expect(calls).toEqual([])
  })

  it('answers a finished check with only its differences, and no picture bytes', async () => {
    const { deps: d, calls } = deps()
    const out = await toolNamed(fixedTools(d), 'fixed.check').run({ project: PROJECT, wait: 5 }, contextFor(fakeSurface().surface))
    const value = out.value as { verdict: string; differences: Array<{ picturesKept: number; changes: unknown[] }> }
    expect(value.verdict).toBe('differences')
    expect(value.differences[0]?.picturesKept).toBe(1)
    expect(JSON.stringify(value)).not.toContain('base64')
    expect(calls).toEqual(['check /work/api by Hoot'])
  })

  it('says a check is still running, and what to call, when it outlasts the wait', async () => {
    const { deps: d } = deps({
      check: () => new Promise(() => undefined),
      progress: () => ({ startedAt: 1, step: 'Booting 1.0.0.', steps: 4, by: 'Hoot' }),
    })
    const out = await toolNamed(fixedTools(d), 'fixed.check').run({ project: PROJECT, wait: 0 }, contextFor(fakeSurface().surface))
    expect(out.value).toMatchObject({ running: true, progress: { step: 'Booting 1.0.0.' } })
    expect(String((out.value as { next: string }).next)).toMatch(/fixed\.results/)
  })

  it('never waits longer than an AI app’s call allows', async () => {
    let waited = -1
    const { deps: d } = deps({
      waitFor: async (_project, ms) => {
        waited = ms
        return results()
      },
    })
    await toolNamed(fixedTools(d), 'fixed.results').run({ project: PROJECT, wait: 9999 }, contextFor(fakeSurface().surface))
    expect(waited).toBe(MAX_CHECK_WAIT_SECONDS * 1000)
  })

  it('gives the full report only when asked', () => {
    expect(resultsForModel(results(), true)).toHaveProperty('engineSummary', 'The engine’s paragraph.')
    expect(resultsForModel(results(), false)).not.toHaveProperty('engineSummary')
    expect(resultsForModel(null)).toMatchObject({ ran: false })
  })

  it('reads guards and the good build in plain words', async () => {
    const out = await toolNamed(fixedTools(deps().deps), 'fixed.status').run({ project: PROJECT }, contextFor(fakeSurface().surface))
    expect(out.value).toMatchObject({
      setUp: true,
      guards: [{ name: 'the total keeps its pennies', because: 'It printed 10.0 once.' }],
      markedGood: { build: '1.0.0' },
      next: 'fixed.check',
    })
  })

  it('turns the agents’ switch with a real true or false, and nothing else', async () => {
    const { deps: d, calls } = deps()
    const agents = toolNamed(fixedTools(d), 'fixed.agents')
    expect(() => agents.precheck?.({ project: PROJECT, on: 'yes' }, contextFor(fakeSurface().surface))).toThrow(/true or false/)
    await agents.run({ project: PROJECT, on: false }, contextFor(fakeSurface().surface))
    expect(calls).toEqual(['agents /work/api false'])
  })

  it('names who asked the way the page says it', () => {
    const context = contextFor(fakeSurface().surface)
    expect(askedBy(context)).toBe('Hoot')
    expect(askedBy({ ...context, caller: { kind: 'key', tiers: context.caller.tiers, keyName: 'ChatGPT' } })).toBe('ChatGPT')
  })
})
