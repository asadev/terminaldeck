import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
import { sectionsFor } from '../settings-schema'
import { CopilotSection, hasNeverStarted, logTrustLine } from './CopilotSection'
import {
  resolveCopilotBridge,
  toActionLog,
  toCopilotState,
  toMemoryReport,
  toRoutineRows,
} from './copilot-bridge'

/**
 * Settings → Copilot.
 *
 * There is no DOM in this project's test setup, so the pane is rendered to
 * static markup — the same split every other settings test uses. That renders
 * the tree without running effects, which is exactly the state this pane has to
 * be honest in anyway: nothing loaded yet, and no bridge in a build that has
 * not wired one.
 *
 * What is pinned here is not layout. It is the set of claims the pane makes on
 * screen, each of which is a promise about something on disk that a later edit
 * could quietly stop keeping:
 *
 *   - opening the pane never starts the copilot;
 *   - the memory it shows is its own conversation and never another session's;
 *   - the action log is outside the folder it may write to, and its only way to
 *     add a line is a tool call;
 *   - routines are outside its reach entirely;
 *   - the pane cannot rewrite a routine file, only pause it;
 *   - and there is no money on screen.
 */

const SRC = join(__dirname, '..', '..', '..')
const SOURCE = readFileSync(join(SRC, 'renderer/settings/sections/CopilotSection.tsx'), 'utf8')

/** A `window.deck` with every channel present, so the pane draws its full self. */
function fakeDeck(): Record<string, unknown> {
  const answer = () => Promise.resolve(null)
  return {
    copilotState: answer,
    ensureCopilot: answer,
    stopCopilot: answer,
    copilotSignIn: answer,
    copilotResetInstructions: answer,
    copilotScaffold: answer,
    copilotMemory: answer,
    copilotMemoryRead: answer,
    copilotMemoryDelete: answer,
    copilotActions: answer,
    copilotReveal: answer,
    routinesList: answer,
    routinesRun: answer,
    routinesPause: answer,
    routinesResume: answer,
    routinesDelete: answer,
  }
}

function withDeck(deck: unknown, render: () => string): string {
  const host = globalThis as unknown as { deck?: unknown }
  const had = 'deck' in host
  const before = host.deck
  host.deck = deck
  try {
    return render()
  } finally {
    if (had) host.deck = before
    else delete host.deck
  }
}

afterEach(() => {
  delete (globalThis as unknown as { deck?: unknown }).deck
})

/* --------------------------------------------------------------- wiring -- */

describe('the pane is reachable', () => {
  it('is a section of the rail on every platform', () => {
    for (const platform of ['mac', 'windows', 'other'] as const) {
      expect(sectionsFor(platform).map((section) => section.id)).toContain('copilot')
    }
  })

  it('renders when the rail entry is selected', () => {
    /*
     * End to end through the window rather than by mounting the component:
     * the failure this catches is a section declared in the schema whose id has
     * no entry in `SECTION_VIEWS`, which type-checks in neither direction and
     * has still shipped in this repository as a rail entry that draws nothing.
     */
    const html = renderToStaticMarkup(
      <SettingsPanel bridge={{}} platform="mac" initialSection="copilot" />,
    )
    expect(html).toContain('data-section="copilot" class="settings-nav-item" aria-selected="true"')
    expect(html).toContain('Copilot')
  })

  it('says so plainly when the build has no copilot channels', () => {
    // Not an empty pane, and not a spinner that never resolves. A build whose
    // preload predates this feature has to say which half is missing.
    const html = renderToStaticMarkup(
      <SettingsPanel bridge={{}} platform="mac" initialSection="copilot" />,
    )
    expect(html).toContain('no copilot channels wired')
  })
})

/* ------------------------------------------------------- what it promises -- */

describe('the claims the pane makes', () => {
  const html = (): string => withDeck(fakeDeck(), () => renderToStaticMarkup(<CopilotSection />))

  it('shows all six subjects', () => {
    const markup = html()
    for (const heading of [
      'Its session',
      'What it reads at startup',
      'Its memory',
      'The action log',
      'What it can and cannot reach',
      'Routines',
    ]) {
      expect(markup, heading).toContain(heading)
    }
  })

  it('says the memory is the copilot’s own conversation and nothing else', () => {
    const markup = html()
    expect(markup).toContain('One file per fact')
    // The promise worth making visible, per `COPILOT-DESIGN.md`: what it reads
    // out of another session is evidence it reports on, never a fact it keeps.
    expect(markup).toContain('never another session')
    expect(markup).toContain('evidence it reports on')
  })

  it('says where the action log lives and why that is the right way round', () => {
    const markup = html()
    expect(markup).toContain('kept outside the copilot')
    // The mechanism, not just the placement. An audit log the audited party can
    // append to, edit or delete is not one — and the copilot's single way to add
    // a line is a tool call that is itself recorded.
    expect(markup).toContain('log.note')
  })

  it('says the confinement is the kernel’s rather than the copilot’s good behaviour', () => {
    const markup = html()
    expect(markup).toContain('A boundary the operating system holds')
    expect(markup).toContain('Cannot reach at all')
    expect(markup).toContain('keychain')
  })

  it('says routines are kept where the copilot cannot reach them', () => {
    const markup = html()
    expect(markup).toContain('cannot reach them')
    expect(markup).toContain('the confirmation a person is owed')
  })

  it('says the account is its own rather than the one the app is using', () => {
    expect(html()).toContain('Pinned to a login of its own')
  })
})

/* ------------------------------------------------------------- the rules -- */

describe('the two rules this pane is held to', () => {
  it('puts no money on screen', () => {
    /*
     * Not a figure, not a symbol, not an estimate. Spending is named only as a
     * consequence — "starting a session spends" — because that is a fact about
     * what a button does, and a number here would be a second, worse answer to
     * a question the usage surface already answers.
     */
    const markup = withDeck(fakeDeck(), () => renderToStaticMarkup(<CopilotSection />))
    for (const symbol of ['$', '€', '£', 'USD', 'per hour of', 'cents']) {
      expect(markup, symbol).not.toContain(symbol)
    }
    /*
     * And in the source, so a string that only appears in a state this render
     * does not reach is caught too. `$` alone would match every template
     * literal in the file, so this looks for the shapes money actually takes:
     * a symbol against a digit, and the words.
     */
    expect(SOURCE).not.toMatch(/[$€£]\s?\d/)
    expect(SOURCE).not.toMatch(/\bUSD\b|\bdollars?\b|\bcents\b/i)
  })

  it('never leaves a control that cannot act without a reason beside it', () => {
    /*
     * Every `disabled` in this file is computed from a `…Because` string that is
     * null when the control works and a sentence when it does not, and that
     * sentence is rendered. A bare `disabled={!bridge.something}` would be the
     * dead control the design brief forbids, wearing the respectable clothes of
     * a guard.
     *
     * The exceptions are counted rather than forbidden: `busy !== null` and
     * `loading` are "wait a moment", not "this cannot happen", and a sentence
     * for those would be noise.
     */
    for (const guard of ['startBecause', 'stopBecause', 'resetBecause', 'switchBecause', 'runBecause']) {
      expect(SOURCE, guard).toContain(`{${guard}}`)
    }
  })
})

/* --------------------------------------------------------- what it cannot -- */

describe('what the pane deliberately cannot do', () => {
  it('does not start the copilot merely by being opened', () => {
    /*
     * Opening a settings pane must not spend somebody's money. The read path is
     * `copilot:state`, `copilot:memory`, `copilot:actions` and `routines:list`,
     * none of which starts anything — `ensureCopilot` is reachable only from the
     * Start button, which says what it does.
     */
    const from = SOURCE.indexOf('const load = useCallback(')
    const to = SOURCE.indexOf('useEffect(load, [load])')
    expect(from, 'the load callback was renamed').toBeGreaterThan(-1)
    expect(SOURCE.slice(from, to)).not.toContain('ensureCopilot')
    expect(SOURCE.slice(from, to)).not.toContain('copilotScaffold')
  })

  it('cannot rewrite a routine file, only pause one', () => {
    /*
     * `enabled:` is a line in a file a person wrote and may have hand-edited, so
     * the Armed switch writes engine state instead — pause and resume, which are
     * kept beside the file rather than in it. The strongest form that guarantee
     * can take is that the bridge has no method for the other thing: no create,
     * no update, nothing to wire wrongly later.
     */
    const bridge = readFileSync(join(SRC, 'renderer/settings/sections/copilot-bridge.ts'), 'utf8')
    const block = bridge.slice(bridge.indexOf('interface CopilotBridge'))
    expect(block).toContain('routinesPause')
    expect(block).toContain('routinesResume')
    expect(block).not.toContain('routinesCreate')
    expect(block).not.toContain('routinesUpdate')
  })
})

/* ------------------------------------------------------- the two judgements */

describe('has it ever been started', () => {
  const state = (instructions: string): never =>
    toCopilotState({ paths: { root: '/tmp/copilot' }, instructions }) as never

  it('says yes only when the instructions and the memory folder are both absent', () => {
    expect(hasNeverStarted(state('missing'), { dir: '/m', exists: false, facts: [], error: null })).toBe(true)
  })

  it('says no once either half exists', () => {
    // Somebody who deleted CLAUDE.md out of a folder full of memories has
    // certainly started it, and drawing "it has never been started" over their
    // memory list would be the pane contradicting the list beneath it.
    expect(hasNeverStarted(state('missing'), { dir: '/m', exists: true, facts: [], error: null })).toBe(false)
    expect(hasNeverStarted(state('current'), { dir: '/m', exists: false, facts: [], error: null })).toBe(false)
  })

  it('says no while nothing has been read yet', () => {
    // "Not read yet" and "never started" are different states, and only one of
    // them is worth a notice at the top of the pane.
    expect(hasNeverStarted(null, null)).toBe(false)
    expect(hasNeverStarted(state('missing'), null)).toBe(true)
  })
})

describe('whether the action log can be trusted', () => {
  const report = (outside: boolean) => ({
    dir: '/l',
    file: '/l/actions.jsonl',
    exists: true,
    bytes: 10,
    outsideCopilotFolder: outside,
    rows: [],
    more: false,
    error: null,
  })

  it('reassures only when the file really is outside the writable folder', () => {
    expect(logTrustLine(report(true))).toContain('outside every path the copilot can write to')
  })

  it('reports a defect rather than reassuring, if the log ever moves back inside', () => {
    /*
     * The branch that matters. The pane's entire claim about this file is that
     * the audited party cannot compose it; if the path moves back inside the
     * copilot's own folder, the sentence has to flip rather than go on
     * reassuring somebody about a boundary that is no longer there.
     */
    const said = logTrustLine(report(false))
    expect(said).toContain('That is a defect')
    expect(said).not.toContain('outside every path')
  })
})

/* ------------------------------------------------------------- narrowing -- */

describe('the bridge and its narrowing', () => {
  it('takes only the methods the host actually has, and calls them through it', () => {
    let sawThis: unknown = null
    const host = {
      copilotState(this: unknown) {
        sawThis = this
        return Promise.resolve(null)
      },
      // Not a function, so it must not be picked up — a build mid-wiring.
      routinesList: 3,
    }
    const bridge = resolveCopilotBridge(host)
    expect(typeof bridge.copilotState).toBe('function')
    expect(bridge.routinesList).toBeUndefined()
    void bridge.copilotState?.()
    // Called through its host rather than torn off it: a preload whose methods
    // sit on a prototype throws on `this` the first time a button is pressed,
    // and that only ever surfaces in a packaged build.
    expect(sawThis).toBe(host)
  })

  it('survives junk from the wire rather than throwing into the pane', () => {
    for (const junk of [null, undefined, 3, 'nope', [], {}]) {
      expect(() => toCopilotState(junk)).not.toThrow()
      expect(() => toMemoryReport(junk)).not.toThrow()
      expect(() => toActionLog(junk)).not.toThrow()
      expect(toRoutineRows(junk)).toEqual([])
    }
    expect(toCopilotState({})).toBeNull()
    expect(toMemoryReport({})).toBeNull()
    expect(toActionLog({})).toBeNull()
  })

  it('never invents a boundary it could not read', () => {
    /*
     * The two booleans that feed a sentence about safety default to the answer
     * that makes no claim. A build that answered `true` for a field it did not
     * receive would print "your projects are readable and unwritable" and "the
     * copilot cannot write this log" on the strength of a missing key.
     */
    const state = toCopilotState({ paths: { root: '/tmp/copilot' } })
    expect(state?.projects.enforceable).toBe(false)
    expect(state?.confinement.enforced).toBe(false)
    expect(toActionLog({ file: '/tmp/actions.jsonl' })?.outsideCopilotFolder).toBe(false)
  })

  it('reads a routine the engine paused after repeated failures', () => {
    // The case the whole routines block exists for: a paused routine and a
    // merely quiet one are indistinguishable unless the state, the reason and
    // the failure count all survive the trip.
    const [routine] = toRoutineRows([
      {
        id: 'nightly',
        name: 'Nightly sweep',
        state: 'paused',
        reason: 'Stopped after 3 failures in a row.',
        consecutiveFailures: 3,
        lastOutcome: 'failed',
        lastError: 'the session never finished',
        pausedUntil: null,
        triggers: ['when: schedule daily 02:00'],
        refusedCalls: [{ at: 1, tool: 'settings.write', reason: 'not-permitted-unattended' }],
      },
    ])
    expect(routine).toMatchObject({
      state: 'paused',
      consecutiveFailures: 3,
      lastOutcome: 'failed',
      pausedUntil: null,
    })
    expect(routine.refusedCalls[0].reason).toBe('not-permitted-unattended')
  })

  it('falls back to a state that claims nothing when the engine names one it does not know', () => {
    expect(toRoutineRows([{ id: 'x', state: 'invented' }])[0].state).toBe('unarmed')
  })
})
