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
    copilotReadInstructions: answer,
    copilotWriteInstructions: answer,
    copilotResetInstructions: answer,
    copilotScaffold: answer,
    copilotMemory: answer,
    copilotMemoryRead: answer,
    copilotMemoryWrite: answer,
    copilotMemoryDelete: answer,
    copilotActions: answer,
    copilotReveal: answer,
    routinesList: answer,
    routinesText: answer,
    routinesSaveText: answer,
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
      'What it can reach',
      'Routines',
    ]) {
      expect(markup, heading).toContain(heading)
    }
  })

  it('says the memory is the copilot’s own conversation, and calls that a rule', () => {
    const markup = html()
    expect(markup).toContain('One file per fact')
    // The promise worth making visible, per `COPILOT-DESIGN.md`: what it reads
    // out of another session is evidence it reports on, never a fact it keeps.
    expect(markup).toContain('never another session')
    expect(markup).toContain('evidence it reports on')
    /*
     * And which *kind* of promise it is. While the copilot was jailed, other
     * sessions' transcripts sat outside its boundary, so this could be told as
     * something the machine enforced — and even then it was only half true,
     * because `sessions.transcript` handed them over by design. It is now a rule
     * in its instructions and nothing else, and a screen that let a reader go on
     * believing otherwise would be the defect this whole feature keeps hunting.
     */
    expect(markup).toContain('a rule in its instructions rather than something the machine refuses')
  })

  it('says where the action log lives and why that is the right way round', () => {
    const markup = html()
    expect(markup).toContain('kept outside the copilot')
    // The mechanism, not just the placement. An audit log the audited party can
    // append to, edit or delete is not one — and the copilot's single way to add
    // a line is a tool call that is itself recorded.
    expect(markup).toContain('log.note')
  })

  it('says out loud that the copilot is not sandboxed, before it names any refusal', () => {
    /*
     * The reversal, pinned on the screen as well as in the code.
     *
     * This block used to promise "a boundary the operating system holds" and
     * list four things the copilot could not reach, ending with the person's
     * keychain. Every one of those was true, and the boundary is gone — it made
     * the copilot start signed out and unable to read a line of their code.
     *
     * A screen that kept those sentences would be the worst possible outcome of
     * this change: a person reading Settings and believing their assistant is
     * held inside something it is not. So the uncomfortable fact leads, and the
     * three real refusals follow it.
     */
    const markup = html()
    expect(markup).toContain('not a sandboxed one')
    expect(markup).toContain('not sandboxed')
    expect(markup).not.toContain('A boundary the operating system holds')
    expect(markup).not.toContain('Cannot reach at all')
  })

  it('names the records it still cannot touch, and counts them correctly', () => {
    /*
     * The count is asserted because it has already been wrong on screen. The
     * fence was three paths for its whole life and became five when the remote
     * copilot grant and the paired-device trust store joined it — a store the
     * copilot can write is a permission the copilot grants itself — and the
     * paragraph above the list went on saying "three" while the list below it
     * rendered five. A screen that contradicts itself two lines apart is worse
     * than one that says nothing.
     */
    const markup = html()
    expect(markup).toContain('Five paths, and only five')
    expect(markup).toContain('an automation loop with no human in it')
    expect(markup).toContain('a record its subject can compose is worth nothing')
    expect(markup).toContain('a permission an agent can grant itself is not a permission')
  })

  it('separates Claude Code’s own prompts from this app’s confirmation', () => {
    /*
     * Two permission systems that look like one. Claude Code's prompts follow
     * the person's own `permissions.defaultMode`; this app's confirmation is
     * asked by the desktop after the tier check and cannot be reached from that
     * file at all. Somebody who turns off the first and believes they turned off
     * the second — or who sees the second and assumes the first is on — has been
     * misled by this screen, so this screen has to say it.
     */
    const markup = html()
    expect(markup).toContain('~/.claude/settings.json')
    expect(markup).toContain('This app does not change that setting in either direction')
    expect(markup).toContain('Nothing in your Claude Code settings turns it off')
    // And the old half-truth is gone: under a bypassing default the CLI does
    // not ask before it edits a file, so the screen must not say it does.
    expect(markup).not.toContain('Anything it cannot undo, it asks about first')
  })

  it('says routines are kept where the copilot cannot write them', () => {
    const markup = html()
    expect(markup).toContain('cannot reach them')
    expect(markup).toContain('the confirmation a person is owed')
  })

  it('says the account is one of yours rather than a login the copilot keeps', () => {
    const markup = html()
    expect(markup).toContain('One of the accounts in Accounts')
    expect(markup).toContain('rather than having a login of its own')
    expect(markup).not.toContain('Pinned to a login of its own')
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

  it('has no way to create a routine, only to edit one that exists', () => {
    /*
     * The editor added on 2026-08-17 gave this pane a routine `Save`, and the
     * guarantee had to be restated rather than dropped. Two halves survive:
     *
     *  - **The Armed switch still never writes to the file.** `enabled:` is a
     *    line in a file somebody wrote; the switch pauses, which is engine state
     *    kept beside the file. What changed is that a person can now change that
     *    line themselves, in a box, on a press — which is not the app editing
     *    their work to record a preference of its own.
     *  - **The pane cannot bring a routine into existence.** Creating one is an
     *    alter-tier act, and the strongest form that guarantee takes is that
     *    there is no method on the bridge for it: no create, nothing to wire
     *    wrongly later.
     */
    const bridge = readFileSync(join(SRC, 'renderer/settings/sections/copilot-bridge.ts'), 'utf8')
    const block = bridge.slice(bridge.indexOf('interface CopilotBridge'), bridge.indexOf('const BRIDGE_METHODS'))
    expect(block).toContain('routinesPause')
    expect(block).toContain('routinesResume')
    expect(block).toContain('routinesSaveText')
    expect(block).not.toContain('routinesCreate')

    // And the switch's own handler pauses rather than saving, which is the half
    // a reader of the bridge alone could not check.
    const switchHandler = SOURCE.slice(SOURCE.indexOf('act(`routine-arm:'))
    expect(switchHandler.slice(0, switchHandler.indexOf('}),'))).not.toContain('SaveText')
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

  it('never invents a refusal it could not read', () => {
    /*
     * The booleans that feed a sentence about safety default to the answer that
     * makes no claim. A build that answered `true` for a field it did not
     * receive would print "the routines and the action log are held against it"
     * and "the copilot cannot write this log" on the strength of a missing key.
     *
     * It matters more since the copilot stopped being sandboxed: the fence is
     * the *only* thing standing in front of those files now, so a pane that
     * claims it on a machine where it does not hold is the one wrong answer.
     */
    const state = toCopilotState({ paths: { root: '/tmp/copilot' } })
    expect(state?.records.enforced).toBe(false)
    expect(state?.records.kind).toBe('none')
    expect(state?.records.paths).toEqual([])
    expect(state?.profile).toBeNull()
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

/* ------------------------------------------------------------- editable -- */

describe('the three files a person can change here', () => {
  const EDITOR = readFileSync(join(SRC, 'renderer/settings/sections/CopilotEditor.tsx'), 'utf8')

  it('gives all three files an editor, and the log none', () => {
    /*
     * Asad, 2026-08-17: *"none of them is clickable or editable … I should be
     * able to click and make changes and click save."* Three `FileEditor`s and
     * no more: the instruction file, one memory, one routine.
     *
     * Counted in the source rather than in the markup, because
     * `renderToStaticMarkup` runs no effects — so nothing has been read off
     * disk, and every one of these boxes correctly draws its "reading…" or
     * "there is no file yet" state instead. `CopilotEditor.test.tsx` exercises
     * the box itself against props.
     */
    expect(SOURCE.match(/<FileEditor/g) ?? []).toHaveLength(3)
    expect(SOURCE).toContain('label="CLAUDE.md"')
  })

  it('draws the state it is really in before anything has been read', () => {
    // And the state a static render *is* in has to be honest rather than an
    // empty box over a file nobody has looked at — a box somebody would type
    // into and save.
    const markup = withDeck(fakeDeck(), () => renderToStaticMarkup(<CopilotSection />))
    expect(markup).toContain('The file does not exist')
    expect(markup).not.toContain('copilot-editor-box')
  })

  it('says a changed CLAUDE.md applies at the next start, not mid-conversation', () => {
    /*
     * The claim the whole feature stands or falls on. The CLI reads the file as
     * the session spawns and never again, so an editor that let somebody save
     * and walk away believing the running copilot had changed would be worse
     * than no editor at all. Both branches are pinned: the sentence at rest, and
     * the Restart offered while something is running.
     */
    expect(SOURCE).toContain('the next time it starts')
    expect(SOURCE).toContain('restart it to hand it the new one')
    expect(SOURCE).toContain("act('restart'")
    // A stop *and* a start, because there is no reload to call.
    const restart = SOURCE.slice(SOURCE.indexOf("act('restart'"))
    expect(restart.slice(0, 400)).toContain('stopCopilot')
    expect(restart.slice(0, 400)).toContain('ensureCopilot')
  })

  it('never lets a truncated memory be saved back over the whole file', () => {
    /*
     * The one way an editor on this pane could destroy data, and it is quiet:
     * `readMemoryFact` stops at 256 KB, so a Save from a box holding the head of
     * a longer file would write exactly that head. The reader already reports
     * `truncated`; this is the pane refusing to act on it, with the sentence
     * saying where to go instead.
     */
    expect(SOURCE).toContain('truncated')
    expect(SOURCE).toContain('throw the rest of it away')
  })

  it('says a saved routine takes effect straight away, unlike the other two', () => {
    // Three editors, three different answers to "when does this apply", and the
    // pane is not allowed to be quiet about any of them.
    expect(SOURCE).toContain('the next time this routine fires, it fires on the new file')
    expect(SOURCE).toContain('its memory is read as the session spawns')
  })

  it('makes every editor state when its edit takes effect', () => {
    // `effect` is required on the component rather than optional, so a fourth
    // editor added later cannot be silent about this by omission.
    const props = EDITOR.slice(EDITOR.indexOf('interface FileEditorProps'), EDITOR.indexOf('export function FileEditor'))
    expect(props).toContain('effect: string')
    expect(props).not.toContain('effect?:')
  })

  it('disables Save with a reason rather than leaving it inert', () => {
    // The pane's house rule, inside the shared editor: every reason a Save
    // cannot act is a string that is rendered, not a bare boolean guard.
    expect(EDITOR).toContain('saveBecause: string | null')
    expect(EDITOR).toContain('{saveBecause}')
  })

  it('goes clean the moment a save lands, rather than staying dirty', () => {
    /*
     * A real defect, caught on the rendered pane rather than in a test: after a
     * successful memory save the box still said "Unsaved." and Save was still
     * blue, because the editor compares its draft against the text the section
     * last *read* — and that read happened when the fact was opened. Somebody
     * seeing that presses Save again and then doubts the first press.
     *
     * All three writers write verbatim, so the bytes just sent are the bytes on
     * disk and there is nothing to re-read. One assertion per editor.
     */
    expect(SOURCE.match(/setText\(next\)/g) ?? []).toHaveLength(3)
  })

  it('keeps a half-typed draft through a reload that changed nothing', () => {
    /*
     * The pane re-reads everything after every action, so a box controlled
     * directly by the loaded text would lose an edit in progress every time
     * somebody deleted a memory elsewhere on the pane. A draft survives a reload
     * that brought back the same bytes and yields to one that did not, because
     * keeping it there would mean saving over somebody else's write.
     */
    expect(EDITOR).toContain('seen.current !== text')
  })
})

describe('the action log stays read-only', () => {
  it('has no editor and no channel behind one', () => {
    /*
     * Deliberate, and the reason is the paragraph the pane already prints about
     * it: the log is the one artefact a person can check a claim against. A
     * person editing it would not break the "the audited party cannot compose
     * it" claim — a person is not the audited party — but it would destroy what
     * the file is *for*. So there is no Save under it, and the bridge has no
     * method that could be wired to one.
     */
    const log = SOURCE.slice(SOURCE.indexOf('function ActionsGroup'), SOURCE.indexOf('function ReachGroup'))
    expect(log).not.toContain('FileEditor')
    expect(log).not.toContain('Save')

    const bridge = readFileSync(join(SRC, 'renderer/settings/sections/copilot-bridge.ts'), 'utf8')
    const block = bridge.slice(bridge.indexOf('interface CopilotBridge'), bridge.indexOf('const BRIDGE_METHODS'))
    expect(block).toContain('copilotActions')
    expect(block).not.toContain('copilotActionsWrite')
    expect(block).not.toContain('copilotActionsAppend')
  })
})
