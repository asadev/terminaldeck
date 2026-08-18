import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import {
  advanceLabel,
  isLastStep,
  nextStep,
  prevStep,
  RENAME_TAKES_A_RESTART,
  SETUP_STEPS,
  startLabel,
  stepIndex,
  STEP_TITLE,
} from './copilot-setup-model'
import { DEFAULT_COPILOT_NAME, NO_IDENTITY } from '../../shared/copilot-identity'
import { profileLoginLabel } from '../accounts'

/**
 * The setup flow: its order, its skipping, and — the point of this file after
 * 2026-08-17 — how little it is allowed to say.
 *
 * ## The instruction this pins
 *
 * > *"We don't need to keep three different descriptions… nobody needs to know
 * > that there are four questions and they are skippable. There is a clear skip
 * > button so we don't need to give this explanation."*
 *
 * Every screen carried the same standing line about the flow, above the question
 * it was asking, and two of them carried a third paragraph under the box. All of
 * it was true and none of it was needed. The trouble with copy is that nothing
 * fails when it grows back one well-meant clause at a time, so the shortness is
 * pinned here the way `copy-length.test.tsx` pins the settings panes.
 *
 * ## The harness
 *
 * Rendered through `react-dom/server`, the way `dialog-render.test.tsx` renders
 * the session dialogs, because this project has no DOM in its test setup. That
 * decides what can be checked here and what cannot: effects do not run, so
 * nothing has read a file or listed an account, and nothing can be clicked. The
 * first screen is rendered directly; the order between screens is a matter of
 * pure functions, which is why they are pure functions.
 */

vi.mock('react-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-dom')>()
  return { ...actual, createPortal: (node: ReactNode) => node }
})

// The stubbed portal ignores its container, so this only has to exist.
;(globalThis as { document?: unknown }).document = { body: {} }

const { CopilotSetup } = await import('./CopilotSetup')

const noop = (): void => {}
const named = { name: 'Nova', callThem: 'Asad', addressNote: 'short answers, no preamble' }

/* ----------------------------------------------------------------- order -- */

describe('the order of the questions', () => {
  it('is four questions, and the last one is a question rather than a summary', () => {
    /*
     * The summary card is gone — *"this whole card is not required. Let's remove
     * this card overall. Just Start."* — so the flow ends on the account
     * question and its button is the one that acts. Pinned as the whole array
     * rather than as a length, because a fifth screen sneaking back in under a
     * different name is exactly the regression this catches.
     */
    expect(SETUP_STEPS).toEqual(['name', 'you', 'folder', 'account'])
    expect(isLastStep('account')).toBe(true)
  })

  it('walks forwards and backwards without falling off either end', () => {
    expect(nextStep('name')).toBe('you')
    expect(prevStep('you')).toBe('name')
    expect(prevStep('name')).toBe('name')
    expect(nextStep('account')).toBe('account')
  })

  it('has a heading for every screen, so none of them opens unnamed', () => {
    for (const step of SETUP_STEPS) expect(STEP_TITLE[step].length).toBeGreaterThan(0)
  })

  it('counts from the front, whatever it is handed', () => {
    expect(stepIndex('folder')).toBe(2)
    // An unknown step draws the first dot rather than a negative index, which
    // would be a flow that has gone backwards past its own start.
    expect(stepIndex('nowhere' as never)).toBe(0)
  })
})

describe('the button that moves on', () => {
  /*
   * One button in two states rather than two buttons. A screen carrying both
   * Skip and Continue reads as though skipping were the unusual choice, and on
   * a flow where every question is optional that would be the interface arguing
   * with the design.
   */
  it('says Skip until there is something to keep', () => {
    expect(advanceLabel('name', false, NO_IDENTITY)).toBe('Skip')
    expect(advanceLabel('name', true, named)).toBe('Continue')
  })

  it('is named after what it produces on the last screen', () => {
    expect(advanceLabel('account', true, named)).toBe('Start Nova')
    expect(startLabel(NO_IDENTITY)).toBe(`Start ${DEFAULT_COPILOT_NAME}`)
  })

  /*
   * A session is handed its instructions at `exec`. Renaming a copilot that is
   * already up cannot reach it, and a button saying "Start" over a running one
   * would be the fourth time this feature described something it does not do.
   */
  it('is a save, not a start, when one is already running', () => {
    expect(advanceLabel('account', true, named, true)).toBe('Save')
  })
})

/* --------------------------------------------------------- what it says -- */

describe('how little each screen says', () => {
  const html = renderToStaticMarkup(<CopilotSetup open onClose={noop} onDone={noop} />)

  it('has no standing description under the title', () => {
    /*
     * The line that was on all four screens. It is not shortened, it is gone:
     * `Modal` only renders `.modal-description` when it is given one, and drops
     * `aria-describedby` with it, so nothing is left pointing at an element that
     * does not exist.
     */
    expect(html).not.toContain('modal-description')
    expect(html).not.toContain('skippable')
    expect(html).not.toContain('Four questions')
  })

  it('asks the name with one sentence and nothing else', () => {
    // *"You will talk to it every day so it's worth a name… this much is
    // enough."* Said twice in the recording, which is why both halves are
    // pinned: the sentence is there, and the two paragraphs beside it are not.
    expect(html).toContain(STEP_TITLE.name)
    expect(html).toContain('You will talk to it every day, so it is worth a name.')
    expect(html).not.toContain('It appears in the sidebar')
    expect(html).not.toContain('Skip it and nothing is invented')
  })

  it('opens on an empty box, with no invented default', () => {
    expect(html).toContain('Set up your copilot')
    expect(html).toContain('value=""')
  })

  it('draws a dot per screen, so the length of the flow is visible', () => {
    expect(html.split('class="cs-dot"')).toHaveLength(SETUP_STEPS.length + 1)
  })

  it('renders nothing at all when it is not open', () => {
    expect(renderToStaticMarkup(<CopilotSetup open={false} onClose={noop} onDone={noop} />)).toBe(
      '',
    )
  })

  /**
   * The whole screen's worth of prose, counted.
   *
   * A ceiling a little above where the flow actually sits, in the spirit of
   * `copy-length.test.tsx`: the point is that a paragraph cannot quietly double,
   * not that a word may never be added. Both `.cs-says` and `.cs-quiet` are
   * counted because the complaint was about the *total* on screen — three
   * descriptions, not one long one.
   */
  it('keeps every screen under a paragraph of standing prose', () => {
    const source = readFileSync(join(__dirname, 'CopilotSetup.tsx'), 'utf8')
    // Each `<p className="cs-says">` / `cs-quiet` block, as written in the JSX,
    // with tags and expressions stripped. Read from the source rather than the
    // markup so the screens a static render cannot reach are counted too.
    const blocks = [...source.matchAll(/className="cs-(?:says|quiet)">([\s\S]*?)<\/p>/g)].map(
      (match) =>
        match[1]
          // JSX comments first — they are the longest thing inside these
          // paragraphs and none of it reaches the screen.
          .replace(/\{\/\*[\s\S]*?\*\/\}/g, ' ')
          // Then the ⓘ and its paragraph, which is the point of the ⓘ: it is
          // not on the page, so it is not part of what the screen says.
          .replace(/<HoverNote[\s\S]*?<\/HoverNote>/g, ' ')
          .replace(/\{[^}]*\}/g, ' ')
          .replace(/<[^>]*>/g, ' ')
          .trim()
          .split(/\s+/)
          .filter((word) => word !== '').length,
    )
    expect(blocks.length).toBeGreaterThan(0)
    for (const words of blocks) expect(words).toBeLessThanOrEqual(24)
  })
})

describe('the account step names no vendor', () => {
  /**
   * The fourth of the strings the completeness audit found still live on the
   * two surfaces the review names — a pop-up, in this case the last step of
   * this flow, reading **"Your own Claude Code install"**.
   *
   * It was invisible to `neutral-naming.test.ts` and always will be, because
   * there is no such string anywhere in the tree: it is composed at runtime
   * from the agent's own catalogue row, which is the *right* architecture and
   * the reason the guard cannot see it. A rule a scanner cannot enforce has to
   * be pinned where the decision is made, so it is pinned here.
   *
   * The list on that step is `claudeAccounts` — the accounts the copilot's own
   * session could actually run as — so it holds one agent's logins and the
   * agent's name separates nothing on it. Settings → Accounts is the opposite
   * case and keeps the name; the argument for both is written on
   * `profileLoginLabel`.
   */
  const own = { id: 'system', name: 'Default', provider: 'claude' as const, system: true }

  it('drops the agent from the machine’s own install, on this list only', () => {
    expect(profileLoginLabel(own, undefined, { namesTheAgent: false })).toBe('Your own install')
    // The default is unchanged, which is the half that keeps Settings → Accounts
    // able to tell three system rows apart.
    expect(profileLoginLabel(own, undefined)).toBe('Your own Claude Code install')
  })

  it('still prints the address when there is one, because that is the login', () => {
    expect(
      profileLoginLabel(own, { state: 'signed-in', account: 'a@b.co' }, { namesTheAgent: false }),
    ).toBe('a@b.co')
  })

  it('asks for the neutral form from the setup flow itself', () => {
    // The wiring, read from the source: a static render cannot reach this step,
    // and a passing label function that nobody calls is not a fixed screen.
    const source = readFileSync(join(__dirname, 'CopilotSetup.tsx'), 'utf8')
    expect(source).toContain('namesTheAgent: false')
  })
})

describe('the field that stalls people', () => {
  const html = renderToStaticMarkup(<CopilotSetup open onClose={noop} onDone={noop} />)

  it('marks "how you want to be spoken to" optional, visibly, beside the field', () => {
    /*
     * Asad, 2026-08-17: *"'How you want to be spoken to' is confusing and stalls
     * people — mark it optional, visibly, next to the field."*
     *
     * Checked in the source rather than the first screen's markup, because the
     * static render only reaches step one. What matters is that the word is in
     * the label line of *that* field and not of the one above it, which is the
     * mistake a later edit would make.
     */
    const source = readFileSync(join(__dirname, 'CopilotSetup.tsx'), 'utf8')
    // The rendered label line, not the first mention of the phrase — which is
    // inside the comment arguing for this very tag.
    const at = source.indexOf('<span className="cs-label">\n                How you want to be spoken to')
    expect(at, 'the label line has changed shape').toBeGreaterThan(-1)
    expect(source.slice(at, at + 220)).toContain('cs-optional')
    // And the field above it carries no such tag: two "optional" labels beside
    // each other would say nothing, and the first box is the one worth filling.
    const callThem = source.slice(source.indexOf('<span className="cs-label">It calls you'), at)
    expect(callThem).not.toContain('cs-optional')
    expect(html).toContain('cs-input')
  })
})

/* --------------------------------------------------- where the answers go -- */

/**
 * The separation this whole feature turns on, checked against the source.
 *
 * The answers belong in `<userData>/copilot-layer/instructions.md` — the app's
 * own storage — and never in the copilot's working directory, because that
 * folder can be one the person already had and identity on their disk is
 * identity inherited by every ordinary terminal they open there.
 * `copilot-layer-is-app-side.test.ts` holds the main-process half; this holds
 * the half that would undo it from the renderer, which is a flow reaching for a
 * different channel.
 *
 * Static rather than behavioural for the reason `wiring.test.ts` gives: there is
 * no DOM here, so the thing to check is which channel the code names.
 */
describe('the answers are written into the layer and nowhere else', () => {
  const source = readFileSync(join(__dirname, 'CopilotSetup.tsx'), 'utf8')

  it('saves through the same channel the Settings editor saves through', () => {
    expect(source).toContain('copilotWriteInstructions')
    expect(source).toContain('withCopilotIdentity')
  })

  it('never writes into the copilot’s folder', () => {
    // `copilotMemoryWrite` puts bytes into `memory/` *inside the working
    // directory* — which is the person's own folder whenever they have chosen
    // one — so this flow must not reach for it, and does not need to.
    expect(source).not.toContain('copilotMemoryWrite')
  })

  /*
   * Scaffolding is the one write that happens before the save, and it is safe
   * for a reason that lives on the other side: `scaffoldCopilotHome` writes into
   * the working directory only when that directory is the app's own, and
   * `copilot-home.test.ts` — *"writes nothing at all into a folder somebody
   * chose"* — is what holds it there. Without it, a first run would have no
   * instruction file to splice the answers into.
   */
  it('seeds the instruction file when there is not one yet', () => {
    expect(source).toContain('copilotScaffold')
  })

  /*
   * The flow ends in a Start button, so the spawn has to belong to `App.tsx`,
   * after the answers are on disk. A flow that started the session itself would
   * be spending money from inside a dialog nobody had finished.
   */
  it('starts nothing itself', () => {
    expect(source).not.toContain('ensureCopilot')
  })

  /*
   * The folder step opens a native panel, and a native panel is an `NSWindow`
   * above every pixel the renderer draws — no z-index can put a dialog over it.
   * `Modal`'s `hidden` is what steps this one aside for as long as the panel is
   * up; without it the picker's own buttons are drawn across the questions,
   * which is a defect this app has already shipped once with the New-session
   * dialog and written up at length in `Modal.tsx`.
   */
  it('steps aside for the native folder panel', () => {
    expect(source).toContain('hidden={picking}')
    expect(source).toContain('setPicking(true)')
    expect(source).toContain('.finally(() => setPicking(false))')
  })

  /*
   * Found by running the flow twice in the built app rather than by reading it.
   *
   * The dialog stays mounted while it is closed, so an account picked in the
   * first run was still selected in the second: finishing would have pinned it
   * to the folder again. Skipping a question has to mean leaving things alone,
   * and it cannot mean that while a stale selection survives the close.
   */
  it('forgets an account picked in an earlier run when it reopens', () => {
    const effect = /if \(loaded\.current\) return[\s\S]*?\n  \}, \[open, bridge\]\)/.exec(source)?.[0] ?? ''
    expect(effect, 'the open effect has changed shape').not.toBe('')
    expect(effect).toContain('setAccountId(null)')
  })

  /*
   * The one sentence the deleted summary card was carrying that had nowhere else
   * to go. It is only true while something is running, so it may only be drawn
   * then — a first run must not be told that its answers apply "next time".
   */
  it('still says a rename needs a restart, and only while one is running', () => {
    expect(source).toContain('{running && <p className="cs-quiet">{RENAME_TAKES_A_RESTART}</p>}')
    expect(RENAME_TAKES_A_RESTART).toContain('next time it starts')
  })
})

/* ------------------------------------------------------ the native panel -- */

/**
 * How the folder panel opens, which is a main-process decision and the one
 * defect on this flow that no amount of renderer copy could fix.
 *
 * Asad, 2026-08-17, watching it open: *"Why does this open like this? It should
 * open just like normal windows."* — and then the panel's own **Open** button
 * landed outside the visible area and he had to cancel and try again.
 *
 * The cause is `dialog.showOpenDialog(parentWindow, …)`. Passing a parent makes
 * the panel a **sheet** on macOS: it drops out of that window's title bar and is
 * clipped to that window's bounds, so on a window shorter than the panel the
 * buttons along its bottom edge are simply not drawn. Omitting the parent gives
 * the free-standing Open panel every other Mac application shows — which is
 * exactly "just like normal windows".
 *
 * Pinned from the renderer's own test because this flow is what opens it, and
 * because the change is a single argument that a later edit would restore
 * without noticing. `defaultPath` is asserted alongside it: `project-picker.ts`
 * measures at length why omitting *that* leaves the panel standing in whatever
 * empty directory AppKit last remembered.
 */
describe('the folder panel opens like a normal window', () => {
  const main = readFileSync(join(__dirname, '..', '..', 'main', 'index.ts'), 'utf8')
  const block = main.slice(main.indexOf('registerCopilotFolderIpc(ipcMain, {'))
  const pick = block.slice(block.indexOf('pick: async (defaultPath)'), block.indexOf('log: (entry)'))

  it('is not a sheet on the main window', () => {
    expect(pick, 'the copilot folder picker was not found').toContain('showOpenDialog')
    expect(pick).not.toContain('showOpenDialog(mainWindow')
  })

  it('still stands somewhere that is not empty', () => {
    expect(pick).toContain('defaultPath')
  })
})
