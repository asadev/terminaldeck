import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { closeWarning } from '../components/CloseSessionConfirm'

/**
 * The seams that make the machine group and the remote pill live, and the words
 * the confirmation says when one is closed.
 *
 * ## Why a source read rather than a mounted `App`
 *
 * The same reason `wiring.test.ts` gives, and this file follows its shape rather
 * than inventing one: every prop involved is optional, and optional is exactly
 * what lets a component render a plausible empty state instead of failing. A
 * `Sidebar` handed no `onCloseMachine` draws the ✕ and does nothing when it is
 * pressed; a `WorkspaceTabStrip` handed no `onEndRemote` draws no ✕ at all on a
 * remote pill. Neither is a type error and neither is visible in a screenshot
 * taken while nothing is paired — which is most screenshots.
 *
 * It is a file of its own rather than four more rows in `SEAMS` because that
 * array is edited by whoever is working on any part of the window, and this pass
 * ran beside three others in one tree.
 */

const SRC = join(__dirname, '..', '..', '..', 'src')
const APP = readFileSync(join(SRC, 'renderer', 'App.tsx'), 'utf8')

/**
 * The opening tag of `<Name … >`, brace-aware so a prop whose value is an inline
 * arrow function does not end the scan early. The same helper `wiring.test.ts`
 * uses; copied rather than exported from a test file, which vitest would then
 * have to treat as a suite with no tests in it.
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

describe('the window hands the rail and the strip what they need', () => {
  it('gives the rail a way to close a machine', () => {
    // Without it the ✕ on a machine heading is drawn — its neighbours are — and
    // presses into a default no-op. That is the exact defect this pass exists to
    // remove, arrived at from the wiring side instead of the markup side.
    const tag = openingTag(APP, 'Sidebar') ?? ''
    expect(tag, 'no <Sidebar> in App.tsx').not.toBe('')
    expect(tag).toContain('onCloseMachine')
  })

  it('gives the strip a way to end a remote session', () => {
    // Without it a remote pill has no ✕ at all — the strip refuses to draw one
    // it cannot act on — so the pill would be the one window in the bar that
    // could not be closed from the bar.
    const tag = openingTag(APP, 'WorkspaceTabStrip') ?? ''
    expect(tag, 'no <WorkspaceTabStrip> in App.tsx').not.toBe('')
    expect(tag).toContain('onEndRemote')
  })

  it('gives the strip every open window, not just this machine’s', () => {
    /*
     * `tabs={openTabs}`, which is this window's tabs plus the machines'. With
     * `tabs={tabs}` the strip compiles, renders, and silently cannot draw a
     * remote pill — which is precisely the state he was looking at when he said
     * *"I cannot drag it up there."*
     */
    const tag = openingTag(APP, 'WorkspaceTabStrip') ?? ''
    expect(tag).toContain('tabs={openTabs}')
  })

  it('marks the same tab selected in both, from one value', () => {
    // A rail highlighting one row while the strip highlights another is the
    // defect `covered` was written for wearing a third costume. One value feeds
    // both, so they cannot disagree.
    expect(openingTag(APP, 'Sidebar') ?? '').toContain('activeTabId={railActiveTabId}')
    expect(openingTag(APP, 'WorkspaceTabStrip') ?? '').toContain('activeTabId={railActiveTabId}')
  })

  it('no longer covers the strip because a remote session is open', () => {
    /*
     * `covered` tells the strip that none of its tabs is what is on screen. That
     * was true of a remote session for exactly as long as a remote session had
     * no pill. It has one now, so covering the strip would be the bar refusing
     * to point at a tab it is drawing.
     */
    const tag = openingTag(APP, 'WorkspaceTabStrip') ?? ''
    expect(tag).toContain('covered={showingPanel}')
    expect(tag).not.toContain('openMachineSession !== null')
  })
})

describe('⌘W closes what is on screen', () => {
  it('targets the remote session when one is filling the window', () => {
    /*
     * `activeTab` is the local answer and names a tab you are not looking at
     * while a remote session fills the pane — so the chord would end a session
     * on this computer with a different one's terminal in front of you. That was
     * already true before a remote session had a pill and it was already wrong;
     * the pill is what makes it fixable, because there is now a tab id to name.
     *
     * Read out of the source rather than driven, because the chord goes through
     * the menu bridge and there is no DOM in this suite. What has to stay true
     * is that the remote case is tested *first* — an `else if` in the other
     * order silently keeps the old behaviour.
     */
    const at = APP.indexOf("case 'session.close':")
    expect(at, 'the ⌘W handler has moved — this test can no longer see it').toBeGreaterThan(0)
    const handler = APP.slice(at, APP.indexOf('return true', at))
    expect(handler).toContain('if (openMachineSession) {')
    // Against the two branches rather than the two words: the paragraph above
    // them names `activeTab` while explaining why it is the wrong answer, so a
    // search over the whole slice would be reading the prose.
    expect(handler.indexOf('if (openMachineSession) {')).toBeLessThan(
      handler.indexOf('} else if (activeTab) {'),
    )
  })
})

describe('what the confirmation says about a machine', () => {
  it('names the machine and promises it stays connected', () => {
    /*
     * The one question a person actually has at this dialog is whether pressing
     * it unpairs their PC, and he answered it himself: *"it should not
     * disconnect the remote account. It will just close all of the sessions from
     * that PC."* Answering it in the confirmation costs a sentence; answering it
     * afterwards costs watching whether the machine came back.
     */
    const many = closeWarning('working', 4, 'machine')
    expect(many.headline).toBe('Closing this machine closes 4 sessions on it.')
    expect(many.detail).toContain('stays connected')
  })

  it('counts to one without saying “sessions”', () => {
    // A machine with one session running is closing one session. The plural
    // sentence would be a dialog counting to one, which is how a confirmation
    // starts reading as boilerplate.
    const one = closeWarning('working', 1, 'machine')
    expect(one.headline).toBe('This ends the session on that machine.')
    expect(one.detail).toContain('stays connected')
  })

  it('still calls a project a project', () => {
    // The subject decides the nouns and nothing else, and the default is what
    // every caller meant before there was a third one.
    expect(closeWarning('working', 4).headline).toBe('Closing this project closes 4 sessions.')
    expect(closeWarning('working', 1).headline).toBe('This session is still working.')
  })
})
