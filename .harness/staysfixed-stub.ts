/**
 * The Stays Fixed page's half of the stubbed preload.
 *
 * Built from **real engine output**, not invented shapes: the check, the
 * machine survey and the refusal are the JSON Stays Fixed 0.15.0 printed on a
 * real small project (`src/main/staysfixed/fixtures/`, trimmed and with the
 * paths scrubbed), passed through the main process's own reader
 * (`src/main/staysfixed/read.ts`). So what the page draws here is what it
 * draws in the app, word for word. The two pictures are the ones that check
 * kept: the shop's front page on the build marked as good, and after the button
 * was renamed and recoloured.
 *
 * Shapes are `src/preload/index.ts`'s, per `WIRING-staysfixed.md`: `on*`
 * returns an unsubscribe function, everything else a promise. One difference,
 * said rather than hidden: the app hands pictures over as `data:` URLs, and this
 * hands over the files' URLs on the harness server — the page puts either in an
 * `<img src>`.
 *
 * `?sf=` picks the first screen: `notsetup` (the default), `nogit`,
 * `unavailable`, `clean`, `differences`, `running`. Pressing the buttons moves
 * between them the way the app does: Set up → set up with nothing checked; Run
 * check → the engine's real steps, then the differences; Mark this build as
 * good → refused for those differences, then "anyway" → marked.
 */

import webCheck from '../src/main/staysfixed/fixtures/web-check-regression.json'
import cleanCheck from '../src/main/staysfixed/fixtures/cli-check-clean.json'
import coldCheck from '../src/main/staysfixed/fixtures/cli-check-cold.json'
import shipCut from '../src/main/staysfixed/fixtures/ship-cut.json'
import doctor from '../src/main/staysfixed/fixtures/doctor.json'
import shipRefused from '../src/main/staysfixed/fixtures/ship-refused.json'
import shipForced from '../src/main/staysfixed/fixtures/ship-forced.json'
import { picturesFor, readinessFromDoctor, toMarkOutcome, toResults } from '../src/main/staysfixed/read'

const mode = new URLSearchParams(location.search).get('sf') ?? 'notsetup'
const listeners = new Set<(projectPath: string) => void>()
let lastPath = ''

const PICTURES = [
  'git-76e2ab57c913-single-the-front-page-the-front-page-end.png',
  'work-0f72dd0e31b2-a-the-front-page-the-front-page-end.png',
]

/** The real reader over the real check, with pictures where `picturesFor` finds them. */
function shown(raw: unknown, ago: number) {
  const results = toResults(raw)
  const at = new Date(Date.now() - ago).toISOString()
  const verdict = raw as { candidate?: { id?: string }; reference?: { id?: string } }
  const pictures: Record<string, Array<{ journey: string; before: string | null; after: string | null }>> = {}
  for (const difference of results.differences) {
    const found = picturesFor(difference, PICTURES, verdict.candidate?.id ?? '', verdict.reference?.id || null)
      .map((entry) => ({
        journey: entry.journey,
        before: entry.before ? `/staysfixed/${entry.before}` : null,
        after: entry.after ? `/staysfixed/${entry.after}` : null,
      }))
      .filter((entry) => entry.before || entry.after)
    if (found.length > 0) pictures[difference.id] = found
  }
  return { ...results, at, pictures }
}

const STEPS = [
  'Checking that nothing which already worked has changed.',
  'Comparing against 1.0.0.',
  'Walking open each of the 2 addresses this app answers on.',
  '22 things looked at, 0 of which this build cannot answer the same way twice.',
  'This build gives the same answer twice, everywhere.',
  'Booting 1.0.0 and walking 2 journeys again, to see which of these are real.',
  'All 4 survived the old build being run again.',
  '4 differences are 1 actual finding.',
]

const state = {
  available: mode !== 'unavailable',
  setUp: ['clean', 'differences', 'running'].includes(mode),
  git: mode !== 'nogit',
  agents: true,
  last: mode === 'clean' ? shown(cleanCheck, 6 * 60_000) : mode === 'differences' ? shown(webCheck, 3 * 60_000) : null,
  running: mode === 'running' ? { startedAt: Date.now() - 34_000, step: STEPS[5], steps: 6, by: 'Hoot' } : null as null | { startedAt: number; step: string; steps: number; by: string },
  marked: mode === 'clean' || mode === 'differences' || mode === 'running',
  markedAt: Date.now() - 2 * 86_400_000,
  forced: false,
  timer: 0 as number | ReturnType<typeof setInterval>,
}

function tell(): void {
  for (const listener of listeners) listener(lastPath)
}

function status(projectPath: string) {
  lastPath = projectPath
  return {
    projectPath,
    available: state.available,
    unavailable: state.available ? null : 'Stays Fixed is not part of this build.',
    versionNote: '',
    setUp: state.setUp,
    configFile: state.setUp ? 'staysfixed.config.js' : null,
    git: state.git,
    agents: state.setUp && state.agents,
    guards: state.setUp
      ? [
          {
            name: 'the basket button still adds the mug',
            because: 'A renamed id broke the button and nobody noticed for two days.',
            file: '.staysfixed/guards/the-basket-button-still-adds-the-mug.js',
          },
        ]
      : [],
    guardProblem: null,
    reference: state.setUp && state.marked
      ? { buildId: 'git-76e2ab57c913', name: state.forced ? '1.0.0 with uncommitted changes' : '1.0.0', setAt: new Date(state.markedAt).toISOString(), setBy: 'staysfixed ship', forced: state.forced }
      : null,
    last: state.setUp ? state.last : null,
    running: state.running,
  }
}

function readiness() {
  const raw = state.git ? doctor : { ...doctor, project: { ...doctor.project, isGitRepo: false } }
  return readinessFromDoctor(raw)
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export const staysFixedStub = {
  staysFixedStatus: async (projectPath: string) => status(projectPath),
  staysFixedReadiness: async () => {
    await wait(1200)
    return { ok: true, readiness: readiness() }
  },
  staysFixedSetup: async () => {
    await wait(1400)
    state.setUp = true
    state.last = null
    tell()
    return { ok: true, wrote: ['staysfixed.config.js', '.gitignore'], problem: null, readiness: null }
  },
  staysFixedCheck: async () => {
    if (!state.running) {
      state.running = { startedAt: Date.now(), step: STEPS[0], steps: 1, by: 'you' }
      tell()
      await new Promise<void>((resolve) => {
        let step = 1
        state.timer = setInterval(() => {
          if (!state.running) {
            clearInterval(state.timer)
            resolve()
            return
          }
          if (step >= STEPS.length) {
            clearInterval(state.timer)
            resolve()
            return
          }
          state.running = { ...state.running, step: STEPS[step], steps: step + 1 }
          step += 1
          tell()
        }, 700)
      })
    }
    if (!state.running) {
      const stopped = { ...toResults({ error: { message: 'You stopped the check.' } }), at: new Date().toISOString(), pictures: {} }
      state.last = stopped
      tell()
      return { ok: true, results: stopped }
    }
    state.running = null
    // Nothing marked as good yet is the cold start: the first check compares
    // nothing, exactly as the engine says. After that, the renamed button.
    state.last = state.marked ? shown(webCheck, 0) : shown(coldCheck, 0)
    tell()
    return { ok: true, results: state.last }
  },
  staysFixedStop: async () => {
    const was = state.running !== null
    state.running = null
    tell()
    return was
  },
  staysFixedResults: async (_projectPath: string, full: boolean) => {
    if (!state.last) return null
    if (!full) return state.last
    const raw = state.last.verdict === 'clean' ? cleanCheck : webCheck
    return { ...shown(raw, 0), ...toResults(raw, state.last.at, { full: true }), pictures: state.last.pictures }
  },
  staysFixedMarkGood: async (_projectPath: string, anyway: boolean) => {
    await wait(500)
    if (!state.last) return toMarkOutcome({ ok: true, cut: false, decision: { state: 'never-checked' }, refused: 'This build has not been checked.' }, null)
    if (state.last.verdict === 'differences' && !anyway) return toMarkOutcome(shipRefused, null)
    if (state.last.verdict === 'not-compared') {
      state.marked = true
      state.markedAt = Date.now()
      tell()
      return toMarkOutcome(shipCut, null)
    }
    state.forced = state.last?.verdict === 'differences'
    state.marked = true
    state.markedAt = Date.now()
    tell()
    return toMarkOutcome(state.forced ? shipForced : { ...shipForced, decision: { state: 'clean' } }, null)
  },
  staysFixedAgents: async (projectPath: string, on: boolean) => {
    state.agents = on
    return status(projectPath)
  },
  onStaysFixedChanged: (callback: (projectPath: string) => void) => {
    listeners.add(callback)
    return () => listeners.delete(callback)
  },
}
