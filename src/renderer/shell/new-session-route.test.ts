import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The machine half of "one route to a new session", and the control that is
 * deliberately not on a machine heading.
 *
 * ## Why these two seams are not in `wiring.test.ts`
 *
 * That file already holds the same claim for the rail's ＋, the strip's terminal
 * glyph and ⌘T — *"we just always wanted this pop-up to come up so we choose
 * which type of terminal we want to open"* — and every one of its cases is about
 * a control that starts something **here**. The two below are about a control
 * that starts something on a *different computer*, where getting it wrong costs
 * more: a press that spawns without asking picks the folder, the agent and the
 * login on a machine whose folders this app only knows because that machine
 * advertised them.
 *
 * They are a file of their own for the reason `machine-wiring.test.ts` gives
 * about the same subject: the shared suites are edited by whoever is working on
 * any part of the window, and a pass on the machine group runs beside others in
 * one tree.
 *
 * ## Why a source read rather than a mounted window
 *
 * Both props are optional. A rail handed no `onNewMachineSession` still draws
 * the ＋ on a machine heading and does nothing when it is pressed, and a dialog
 * handed no `machineId` still opens — on the machine step, asking a question the
 * press already answered. Neither is a type error and neither is visible in a
 * screenshot taken while nothing is paired, which is most screenshots. What can
 * regress is the one line in `App.tsx` that decides where each press lands, and
 * nothing about that line is visible from inside the components it feeds.
 *
 * ## What 2026-08-19 changed, and why the file did not shrink
 *
 * The block at the bottom used to pin a *second* route to the same dialog: the
 * **New session** button on a paired machine's card, and the context that
 * carried its press up to the window. The button is gone — *"we don't need this
 * new session thing here. Just disconnect and forget thing is good enough for
 * us."* — and its two assertions went red, correctly: they were guards on a
 * route that was removed on purpose.
 *
 * They are turned round rather than deleted. The defect those cases were written
 * about was never the button; it was that a session on somebody else's computer
 * could be started from a place that had not asked which folder, which agent or
 * which login. A card that opened the dialog was a fix for that. A card that
 * grows its own way there again — bridge call, opener, anything — is the defect
 * back, and the absence of one is exactly as invisible in a screenshot as the
 * presence of one was.
 */

const SRC = join(__dirname, '..', '..', '..', 'src')
const APP = readFileSync(join(SRC, 'renderer', 'App.tsx'), 'utf8')
const SIDEBAR = readFileSync(join(SRC, 'renderer', 'shell', 'Sidebar.tsx'), 'utf8')
const LINKS = readFileSync(join(SRC, 'renderer', 'machines', 'MachineLinks.tsx'), 'utf8')
const REMOTE = readFileSync(join(SRC, 'renderer', 'remote', 'RemoteSection.tsx'), 'utf8')
const OPENER = readFileSync(join(SRC, 'renderer', 'machines', 'new-session-context.ts'), 'utf8')

/**
 * The opening tag of `<Name … >`, brace-aware so a prop whose value is an inline
 * arrow function does not end the scan early. The same helper `wiring.test.ts`
 * and `machine-wiring.test.ts` use; copied rather than exported from a test
 * file, which vitest would then have to treat as a suite with no tests in it.
 */
function openingTag(source: string, name: string): string | null {
  const start = source.search(new RegExp(`<${name}[\\s/>]`))
  if (start < 0) return null
  let depth = 0
  for (let i = start; i < source.length; i++) {
    const c = source[i]
    if (c === '{') depth++
    else if (c === '}') depth--
    else if (c === '>' && depth === 0) return source.slice(start, i + 1)
  }
  return null
}

describe('a machine’s ＋ asks the same questions a project’s does', () => {
  it('opens the dialog instead of spawning on the far machine', () => {
    /*
     * `openNewSessionDialog(null, machineId)` — null folder, machine named. The
     * press has answered *which computer* and nothing else, so the dialog opens
     * on the next question rather than the first, which is the difference
     * between a shortcut and a second flow: *"New session → pick the machine →
     * pick its folder → continue."*
     *
     * The failure this pins is not hypothetical. The paired-machine card on
     * Settings → Remote still calls `createMachineSession` straight out of a
     * button and takes `folders[0]` — see the note on `openNewSessionDialog` in
     * `App.tsx`, which names it and says what closing it needs. If that press
     * ever becomes the pattern for this one too, this case is what says so.
     */
    const tag = openingTag(APP, 'Sidebar') ?? ''
    expect(tag, 'no Sidebar in App.tsx — has the shell been rewritten?').not.toBe('')
    expect(tag).toMatch(
      /onNewMachineSession=\{\s*\(machineId\)\s*=>\s*openNewSessionDialog\(\s*null,\s*machineId\s*\)\s*\}/,
    )
  })

  it('carries the machine the press named into the dialog', () => {
    /*
     * The same rule the folder already has one prop up: an intent the press
     * carried has to survive the trip, or the dialog asks again and the press
     * quietly did nothing. Without `machineId` the machine step opens with
     * nothing chosen, and Start would run the session on *this* computer — a
     * press on another machine's heading that lands here.
     */
    const tag = openingTag(APP, 'NewSessionDialog') ?? ''
    expect(tag, 'no NewSessionDialog in App.tsx').not.toBe('')
    expect(tag).toContain('machineId={newSessionMachine}')
  })
})

describe('no heading grows a Continue the wire cannot answer', () => {
  it('keeps the resume control on the project heading and nowhere else', () => {
    /*
     * He asked for three controls on a machine heading — *"continue last
     * session, new session, or close"* — and it has two. The third is absent on
     * purpose: `create` on the wire carries a cwd and a provider and no resume
     * flag, so the glyph would ask the far machine to continue and be answered
     * with a *fresh* session, silently. The long argument is beside the machine
     * heading in `Sidebar.tsx`, including what the wire would have to answer
     * before this control can exist.
     *
     * Counted rather than asserted per heading, because the shape that would
     * regress is somebody adding `resume` to the machine group or the server
     * group by copying the project group's block — which is exactly how the two
     * headings came to be written out twice in the first place.
     *
     * If you are here because this failed after adding one: the question is not
     * whether `GroupHead` accepts it. It is whether the far end can act on it
     * for the agent that session would run, and say so when it cannot.
     */
    const declared = SIDEBAR.match(/\bresume: \{/g) ?? []
    expect(
      declared.length,
      'a second heading now passes `resume` — see the machine heading’s note on what the wire owes first',
    ).toBe(1)
  })
})

/**
 * A source file with its prose taken out.
 *
 * These files argue at length about what they used to do, and the case below
 * asserts that a particular call is *gone* — so a grep over the raw text finds
 * the comment explaining the removal and reports the removal as undone.
 *
 * Block comments and whole-line `//` ones, and it stops there: a trailing `//`
 * swallowed to end-of-line would also swallow the `//` in the `http://localhost`
 * template two rows away in the file this reads, which is real code. Same
 * helper, same name, as `reachable.test.ts` and `servers/plain-words.test.ts` —
 * copied rather than exported from one of them, which vitest would then have to
 * treat as a suite with no tests in it, for the same reason `openingTag` above
 * is copied.
 */
function withoutComments(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => {
      const trimmed = line.trimStart()
      return !trimmed.startsWith('//') && !trimmed.startsWith('*')
    })
    .join('\n')
}

describe('the Machines page has no route of its own to a new session', () => {
  /*
   * The second half of the same requirement, and the one the note above
   * `openNewSessionDialog` in `App.tsx` says was still open: *"the sidebar +
   * opens [an agent] directly instead of asking session type. Everywhere should
   * ask the same thing."*
   *
   * "Everywhere" was true of the window's chrome — the rail, the strip, the
   * palette, the menu — and untrue of one button that is not in the chrome at
   * all: **New session** on a paired machine's card, on the Machines page. It
   * called `bridge.createMachineSession(machine.id, link.folders?.[0] ?? '')`
   * and a session appeared on somebody else's computer, in whichever folder that
   * machine happened to list first, under whichever agent it defaults to. That
   * was rewritten to open the window's dialog, and these cases pinned the
   * rewritten route: the card's action built from the window's opener, and the
   * page reading that opener out of a context because `PanelView` draws all ten
   * views and takes no per-view props.
   *
   * On 2026-08-19 the button itself went — *"we don't need this new session
   * thing here. Just disconnect and forget thing is good enough for us."* — so
   * what is left to pin is that the page reaches a far machine by **no** name:
   * not the bridge, not an opener, not a context. The rail's ＋ is the route
   * now, and `leaves the rail holding the only ＋…` says so in the one place
   * markup cannot.
   *
   * The two cases after it are in a stranger position and are kept deliberately.
   * They read `new-session-context.ts` and the provider in `App.tsx`, and both
   * of those are now **dead**: `grep -rn useMachineSessionOpener src/renderer`
   * finds the hook's definition and the notes recording its removal, and no call
   * site, so `MachineSessions.Provider` wraps a tree in which nobody consumes
   * it. Deleting the context, the hook and that provider is one edit in
   * `App.tsx` and is owed — it was not done here because `App.tsx` is not this
   * pass's to edit. Until it is, the two cases still hold the shape of what is
   * standing, and they fail in the two different ways that suit them. Drop the
   * provider alone and `is wired to that same function…` goes quiet rather than
   * red — it is a `toBeLessThanOrEqual(1)` over a list that would be empty,
   * which is what lets it survive a tree that has not got one. Delete
   * `new-session-context.ts` and the `readFileSync` at the top of this file
   * throws before any case runs, taking the whole suite with it. That is loud
   * and it is the right kind of loud: whoever removes the module is being told,
   * in the same commit, that these two cases go with it.
   *
   * These cases are source reads for the reason the two above are: the route is
   * a wiring decision spread over several files, and nothing about it is visible
   * in a screenshot taken while no machine is paired, which is every screenshot.
   */

  it('no longer starts one on the far machine behind the dialog’s back', () => {
    /*
     * The bridge call is *gone from this file*, not merely unused. That is the
     * assertion worth making, because the failure it guards is not somebody
     * deleting the dialog — it is somebody adding a "quick" path back beside it,
     * which is exactly how this button came to exist in the first place.
     *
     * `createMachineSession` is still the wire, and still correct: the dialog's
     * Start calls it through `useMachines.startSession`, which waits for the far
     * machine to confirm the session exists. What may not happen is a *button on
     * a card* reaching it with arguments nobody was asked for.
     */
    expect(
      withoutComments(LINKS),
      'the Machines page is spawning on the far machine again — see new-session-context.ts',
    ).not.toContain('createMachineSession')
  })

  it('does not send the press up to the window either, because there is no press', () => {
    /*
     * What stood here, until the button did not:
     *
     *     expect(LINKS).toMatch(/newSession: openNewSession \?[…]openNewSession\(machine\.id\)/)
     *     expect(REMOTE).toContain('useMachineSessionOpener')
     *     expect(REMOTE).toMatch(/openNewSession:[…]newSessionOpener\.open\(machineId\)/)
     *
     * — the card's action built from an opener the window handed down, carrying
     * `machine.id` and nothing else, and the page reading that opener out of a
     * context rather than being prop-drilled one through `PanelView`. All three
     * were true, all three were the fix for the bridge call above, and all three
     * describe code that was deleted on 2026-08-19.
     *
     * The replacement is the same claim with the sign flipped, and it is worth
     * the same lines because the shape that regresses is not "somebody puts the
     * button back". A card that opens the dialog would be harmless — it *was*
     * this file's subject for two days. What must not come back is a second way
     * to start a session on a far machine standing beside the rail's ＋: two
     * presses on one screen, and only the one you did not use asking the
     * questions. The bridge is one door back and the case above holds it; an
     * opener of this page's own is the other, and this one holds that.
     */
    expect(
      withoutComments(LINKS),
      'a machine’s card can start a session again — is that the dialog’s route, or a second one?',
    ).not.toContain('newSession')

    /*
     * Comment-stripped, and that is the whole point of reading it this way.
     *
     * The straight `expect(REMOTE).toContain('useMachineSessionOpener')` above
     * stayed **green** after the read was deleted, because the identifier
     * survives in the paragraph in `RemoteSection.tsx` that explains why it
     * went. An assertion that matches its own subject's prose is measuring the
     * explanation, not the code — worse than a red one, because it reports a
     * route as intact by quoting the note about its removal. Every case in this
     * file that asks about a *deletion* goes through `withoutComments` for that
     * reason; `no longer starts one on the far machine behind the dialog’s back`
     * above already did, which is why it survived the change and this did not.
     */
    expect(
      withoutComments(REMOTE),
      'the Machines page is reading the window’s machine opener again',
    ).not.toContain('MachineSessionOpener')
  })

  it('leaves the rail holding the only ＋ that starts one on a far machine', () => {
    /*
     * The other half of a removal, and the half a deleted test would have
     * dropped: something still has to be able to do it.
     *
     * `shell/machine-group.test.tsx` renders the rail and finds the accessible
     * name *"New session on DESKTOP-DDGMNCV"* on a machine heading, which is
     * proof the control is drawn and no proof at all of where it goes — markup
     * cannot say what a button does, which is this whole file's premise. This is
     * where it goes: one call, in one place, carrying the machine id and nothing
     * else, into the prop the first case in this file follows on into
     * `openNewSessionDialog(null, machineId)`.
     *
     * The count is asserted rather than the line alone because "the only one" is
     * the part that matters. A second call site inside the rail — on a session
     * row, on a hover control, anywhere — would be the pair of presses this file
     * exists to prevent, rebuilt inside the component that was supposed to be
     * the single answer.
     */
    expect(SIDEBAR).toMatch(/onPress: \(\) => onNewMachineSession\(group\.machineId\)/)
    const presses = SIDEBAR.match(/onNewMachineSession\(/g) ?? []
    expect(
      presses,
      'the rail asks for a machine session from more than one control — which one is the route?',
    ).toHaveLength(1)
  })

  it('cannot answer more of the dialog’s questions than the rail can', () => {
    /*
     * Both routes carry a machine id and nothing else, and that is the whole
     * invariant — not a coincidence of two call sites but a fact about the
     * interface between them, which is why the count is asserted rather than the
     * one method name.
     *
     * A second argument is how this regresses. `open(machineId, folder)` would
     * look like a convenience and would be the old defect back: the folder, the
     * agent and the login on a far machine are the three things the press must
     * *not* answer, because the person pressing it is looking at a card that
     * lists none of them.
     */
    const rail = openingTag(APP, 'Sidebar') ?? ''
    expect(rail).toMatch(
      /onNewMachineSession=\{\s*\(machineId\)\s*=>\s*openNewSessionDialog\(\s*null,\s*machineId\s*\)\s*\}/,
    )
    expect(OPENER).toMatch(/open\(machineId: string\): void/)
    const methods = OPENER.match(/^ {2}\w+\(/gm) ?? []
    expect(methods, 'the machine opener has grown a second method — what does it answer?').toHaveLength(1)
  })

  it('is wired to that same function wherever the window provides it', () => {
    /*
     * The last link in the chain, and it is one line in `App.tsx`:
     *
     *     <MachineSessions.Provider value={machineSessionOpener}>
     *
     * with `machineSessionOpener` a memo of
     * `{ open: (machineId) => openNewSessionDialog(null, machineId) }` — the
     * literal expression the rail's prop uses two cases above.
     *
     * Asserted as "every provider, if any" rather than "there is a provider",
     * because the pass that wrote the rest of this route did not own `App.tsx`
     * and could not add it; a failing test would have been a broken suite
     * describing work nobody had asked for yet. What this case *does* catch, the
     * moment the line lands, is the shape of it: a provider fed anything other
     * than `openNewSessionDialog(null, machineId)` is a second flow wearing the
     * first one's name, which is the entire defect this file exists about.
     *
     * If you are reading this because you are about to add the provider: this is
     * the case that says what it must contain, and `new-session-context.ts` says
     * why it is a context rather than a prop.
     */
    const providers = APP.match(/<MachineSessions\.Provider value=\{[^}]*\}>/g) ?? []
    expect(
      providers.length,
      'two machine openers is two answers to "where does this press go?"',
    ).toBeLessThanOrEqual(1)
    for (const provider of providers) {
      const name = provider.match(/value=\{(\w+)\}/)?.[1]
      expect(name, 'the provider takes a named opener, not an inline object').toBeTruthy()
      const built = APP.match(new RegExp(`const ${String(name)}[\\s\\S]{0,400}?\\n  \\)`))?.[0] ?? ''
      expect(built).toMatch(/openNewSessionDialog\(\s*null,\s*machineId\s*\)/)
    }
  })
})
