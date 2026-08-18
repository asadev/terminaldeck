import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
import { sectionsFor } from '../settings-schema'
import { CopilotSection, hasNeverStarted, logTrustLine } from './CopilotSection'
import {
  INTERACTIVE_SETTING,
  resolveCopilotBridge,
  toActionLog,
  toCopilotState,
  toInteractiveDriving,
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
    // The one stored value this pane owns. See "the switch that decides whether
    // it shows its work" at the foot of this file.
    getSettings: answer,
    setSettings: answer,
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
      'Its files',
      'The action log',
      'What it can reach',
      'Routines',
    ]) {
      expect(markup, heading).toContain(heading)
    }
  })

  it('says the memory is the copilot’s own conversation, and calls that a rule', () => {
    /*
     * Asserted against the source rather than the rendered page, because this
     * paragraph moved behind the ⓘ when the memory list became a folder button —
     * and a `HoverNote` renders nothing until somebody hovers it, which is the
     * whole point of it. The claim is still made, in the same words, one hover
     * from the row it is about.
     *
     * The promise itself, per `COPILOT-DESIGN.md`: what it reads out of another
     * session is evidence it reports on, never a fact it keeps. And which *kind*
     * of promise it is — while the copilot was jailed this could be told as
     * something the machine enforced, and it is now a rule in its instructions
     * and nothing else. A screen that let a reader go on believing otherwise
     * would be the defect this whole feature keeps hunting.
     */
    expect(SOURCE).toContain('One file per fact')
    expect(SOURCE).toContain('never another session')
    expect(SOURCE).toContain('evidence it reports on')
    expect(SOURCE).toContain('a rule in its instructions rather than something the machine')
    // And the row it hangs off is on the page, with its one button.
    expect(html()).toContain('Its memory')
  })

  it('says where the action log lives and why that is the right way round', () => {
    // Behind the ⓘ now — see the memory case above for why this reads the
    // source. The mechanism, not just the placement: an audit log the audited
    // party can append to, edit or delete is not one, and the copilot's single
    // way to add a line is a tool call that is itself recorded.
    expect(SOURCE).toContain('kept outside the copilot')
    expect(SOURCE).toContain('log.note')
    // What stays on the page with the list closed: whether the file can be
    // trusted at all. Hiding *that* behind the same button would hide it exactly
    // when it matters.
    expect(html()).toContain('The action log')
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

  it('separates the CLI’s own prompts from this app’s confirmation', () => {
    /*
     * Two permission systems that look like one. The CLI's prompts follow the
     * person's own `permissions.defaultMode`; this app's confirmation is asked
     * by the desktop after the tier check and cannot be reached from that file
     * at all. Somebody who turns off the first and believes they turned off the
     * second — or who sees the second and assumes the first is on — has been
     * misled by this screen, so this screen has to say it.
     *
     * The path stays and the vendor name goes, which is the naming sweep's line
     * drawn on the one paragraph where it is genuinely hard: told only that
     * "some settings file" governs their prompts, nobody can go and change it,
     * so the prose describes the actor by category and the `<code>` discloses
     * where the file is. `src/neutral-naming.test.ts` holds both halves.
     */
    const markup = html()
    expect(markup).toContain('~/.claude/settings.json')
    expect(markup).toContain('This app does not change that setting in either direction')
    expect(markup).toContain('The CLI the copilot runs on has prompts of its own')
    expect(markup).toContain('Nothing in that settings file turns it off')
    // And the old half-truth is gone: under a bypassing default the CLI does
    // not ask before it edits a file, so the screen must not say it does.
    expect(markup).not.toContain('Anything it cannot undo, it asks about first')
  })

  it('says routines are kept where the copilot cannot write them', () => {
    // The heading line is on the page; the mechanism is behind the ⓘ.
    expect(html()).toContain('cannot reach them')
    expect(SOURCE).toContain('may read and cannot write')
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

describe('the files, and the one button on each row that acts', () => {
  const EDITOR = readFileSync(join(SRC, 'renderer/settings/sections/CopilotEditor.tsx'), 'utf8')
  const markup = (): string => withDeck(fakeDeck(), () => renderToStaticMarkup(<CopilotSection />))

  /**
   * The instruction this whole block was rebuilt around.
   *
   *   > *"Every file needs an Edit button beside it, opening the same editor
   *   > style already used, and saving."*
   *   > *"This is busy for nothing, for no sensible reason."*
   *
   * The pane used to draw an ordered list of absolute paths with no controls on
   * any of them, then a second list of the same memory files with an editor
   * each. Now every row carries exactly one button and the boxes are behind it.
   */
  it('gives every file a button, and the right verb for what the app can do to it', () => {
    const html = markup()
    // Edit for the file a person owns and this app writes.
    expect(html).toContain('>Edit</button>')
    // View for the two it generates: they are shown in full and cannot be
    // hand-edited, because they describe what is wired rather than an opinion.
    expect(html).toContain('>View</button>')
    // Open for the folder that is not this app's to write into.
    expect(html).toContain('>Open the folder</button>')
  })

  it('opens nothing until a button is pressed', () => {
    /*
     * Two textareas used to be on screen the moment the pane opened — the
     * instruction file and the generated tool list — which is most of why it was
     * a screen and a half long. They are behind their own buttons now, and the
     * read that fills them happens on the press rather than on mount.
     */
    expect(markup()).not.toContain('copilot-editor-box')
  })

  it('never lists memory as files, and offers the folder instead', () => {
    /*
     * Asad, 2026-08-17: *"Memory is the exception — do not list dated files. One
     * Open folder button… They don't need to edit memories. They need to edit the
     * character, identity and that related stuff only."*
     *
     * Checked against a report holding three real memories, because the failure
     * to catch is the populated pane rather than the empty one. Nothing that
     * renders may name a memory file, and there is no writer or deleter left in
     * the source to bring the list back by accident.
     */
    const html = markup()
    expect(html).toContain('Its memory')
    expect(html).toContain('Open the folder')
    expect(SOURCE).not.toContain('copilotMemoryWrite')
    expect(SOURCE).not.toContain('copilotMemoryDelete')
    expect(SOURCE).not.toContain('copilotMemoryRead')
    // And the count is drawn from the report rather than a list being mapped.
    expect(SOURCE).toContain('memory?.facts.length')
  })

  it('has two editors and no more: its instructions, and one routine', () => {
    /*
     * Counted in the source rather than in the markup, because
     * `renderToStaticMarkup` runs no effects and both boxes are closed anyway.
     * `CopilotEditor.test.tsx` exercises the box itself against props.
     */
    expect(SOURCE.match(/<FileEditor/g) ?? []).toHaveLength(2)
    /*
     * No box on this pane spells a filename out; each derives its label from the
     * path it is actually pointed at. The instructions editor used to be
     * `label="CLAUDE.md"` — a brand on a control that has nothing to do with any
     * one agent, and the wrong file besides: the box edits
     * `<userData>/copilot-layer/instructions.md`, so a screen reader announced a
     * filename that is not on disk anywhere.
     */
    expect(SOURCE).not.toContain('label="CLAUDE.md"')
    expect(SOURCE.match(/label=\{baseName\(/g) ?? []).toHaveLength(4)
  })

  it('says a changed instruction file applies at the next start, not mid-conversation', () => {
    /*
     * The claim the whole feature stands or falls on. The CLI is handed the file
     * as the session spawns and never again, so an editor that let somebody save
     * and walk away believing the running copilot had changed would be worse than
     * no editor at all. Both branches are pinned: the sentence at rest, and the
     * Restart offered while something is running.
     */
    expect(SOURCE).toContain('the next time it starts')
    expect(SOURCE).toContain('restart it to hand it the new one')
    expect(SOURCE).toContain("act('restart'")
    // A stop *and* a start, because there is no reload to call.
    const restart = SOURCE.slice(SOURCE.indexOf("act('restart'"))
    expect(restart.slice(0, 400)).toContain('stopCopilot')
    expect(restart.slice(0, 400)).toContain('ensureCopilot')
  })

  it('says a saved routine takes effect straight away, unlike the instructions', () => {
    // Two editors, two different answers to "when does this apply", and the pane
    // is not allowed to be quiet about either.
    expect(SOURCE).toContain('the next time this routine fires, it fires on the new file')
  })

  it('makes every editor state when its edit takes effect', () => {
    // `effect` is required on the component rather than optional, so a third
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
     * successful save the box still said "Unsaved." and Save was still blue,
     * because the editor compares its draft against the text the section last
     * *read*. Somebody seeing that presses Save again and then doubts the first
     * press. Both writers write verbatim, so the bytes just sent are the bytes on
     * disk and there is nothing to re-read.
     */
    expect(SOURCE).toContain('yours.accept(next)')
    expect(SOURCE).toContain('setText(next)')
  })

  it('keeps a half-typed draft through a reload that changed nothing', () => {
    /*
     * The pane re-reads everything after every action, so a box controlled
     * directly by the loaded text would lose an edit in progress every time
     * something else on the pane finished. A draft survives a reload that brought
     * back the same bytes and yields to one that did not, because keeping it
     * there would mean saving over somebody else's write.
     */
    expect(EDITOR).toContain('seen.current !== text')
  })
})

describe('the ⓘ opens a popup rather than growing the pane', () => {
  /**
   * Asad, 2026-08-17: *"the ⓘ dot shows its detail **on hover, as a popup** —
   * not by expanding the pane downward."*
   *
   * The disclosure this replaced (`Info` + `useMore` + `MoreBody`) inserted the
   * paragraph into the flow, so reading the second explanation on a six-block
   * pane moved the third somewhere else. Pinned in the source because a static
   * render draws no popup at all — which is itself the point: nothing of it is
   * on the page until somebody hovers.
   */
  it('uses HoverNote, and none of the expanding controls', () => {
    expect(SOURCE).toContain('HoverNote')
    expect(SOURCE).not.toContain('MoreBody')
    expect(SOURCE).not.toContain('useMore')
    expect(SOURCE).not.toMatch(/<Info\b/)
  })

  it('draws no explanation body on the page itself', () => {
    const html = withDeck(fakeDeck(), () => renderToStaticMarkup(<CopilotSection />))
    expect(html).not.toContain('settings-info-body')
  })

  /**
   * A popup nobody can read is worse than a paragraph. These are hover-sized —
   * a ceiling a little above where they actually sit, in the spirit of
   * `copy-length.test.tsx`: the point is that one cannot quietly double.
   */
  it('keeps every popup short enough to read in one', () => {
    for (const [, text] of SOURCE.matchAll(/more=\{\s*([\s\S]*?)\n\s*\}/g)) {
      const words = text
        .replace(/'\s*\+\s*\n?\s*'/g, ' ')
        .replace(/[`'"]/g, ' ')
        .trim()
        .split(/\s+/)
        .filter((word) => word !== '').length
      expect(words).toBeLessThanOrEqual(60)
    }
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

describe('the switch that decides whether it shows its work', () => {
  /**
   * Asad, 2026-08-17, asking for it by name and for both halves of it:
   *
   *   > *"Interactive mode ON — the visible scan. Interactive mode OFF — it does
   *   > the work in the background and returns the final answer normally, with
   *   > none of the driving."*
   *
   * Both modes are required, which makes the switch required: a feature with two
   * intended states and one door into them has one state in practice. The one
   * door it had was *"Don't show me next time"* in the scan panel — the right
   * place to turn it off, and no place at all to turn it back on. Somebody who
   * pressed it once had silently given up the feature.
   */
  const markup = (): string => withDeck(fakeDeck(), () => renderToStaticMarkup(<CopilotSection />))

  it('is on the pane, in his words', () => {
    expect(markup()).toContain('Show me what it is looking at')
  })

  it('writes the key the main process reads before it stages a scan', () => {
    /*
     * The strongest thing this file can pin. The two constants live on opposite
     * sides of a bridge that carries `unknown`, so a rename on one side is not a
     * compile error and not a test failure anywhere else — it is a switch that
     * moves and changes nothing, which is precisely the class of defect this
     * whole pass is about.
     */
    const tool = readFileSync(join(SRC, 'main/deck-control/tour-tool.ts'), 'utf8')
    const key = /INTERACTIVE_KEY = '([^']+)'/.exec(tool)?.[1]
    expect(key).toBe(INTERACTIVE_SETTING)
    expect(INTERACTIVE_SETTING).toBe('copilot.interactive')
  })

  it('reads the default exactly as the main process reads it', () => {
    /*
     * Anything other than an explicit `false` is on. The key is deliberately not
     * in the settings schema — this pane is handed none of the settings window's
     * values, so there is no schema row to carry a default — and `settings-extra`
     * keeps keys it does not know without filling one in. So the default lives in
     * whoever reads the value, and two readers with two defaults would put a
     * switch on screen that disagrees with the behaviour it describes.
     */
    expect(toInteractiveDriving({ values: {} })).toBe(true)
    expect(toInteractiveDriving({ values: { [INTERACTIVE_SETTING]: false } })).toBe(false)
    expect(toInteractiveDriving({ values: { [INTERACTIVE_SETTING]: true } })).toBe(true)
    // The bare map as well as the envelope, because `settings:get` has answered
    // with both shapes across builds.
    expect(toInteractiveDriving({ [INTERACTIVE_SETTING]: false })).toBe(false)
    // Nothing readable at all is the documented default rather than off, which
    // would silently withdraw the feature from somebody who never chose to.
    expect(toInteractiveDriving(null)).toBe(true)
  })

  it('does not offer a control it cannot act with', () => {
    /*
     * The house rule for this pane, and the rule for this whole pass: a control
     * that cannot act is removed, or disabled with a stated reason. With no
     * settings channel in the preload the switch is disabled and the row says
     * why, rather than sitting there looking live.
     */
    const noSettings = { ...fakeDeck() }
    delete noSettings.setSettings
    delete noSettings.getSettings
    const html = withDeck(noSettings, () => renderToStaticMarkup(<CopilotSection />))
    expect(html).toContain('Show me what it is looking at')
    expect(html).toContain('no settings channel wired into its preload')
    expect(html).toContain('disabled=""')
  })
})
