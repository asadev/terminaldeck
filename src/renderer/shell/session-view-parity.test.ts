import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * One view of a session, whichever computer it is running on.
 *
 * ## The complaint
 *
 * Asad, 2026-08-21, pointing at a terminal on his office server:
 *
 *   > *"Like I cannot even split"* … *"I cannot make it to the chat view"* …
 *   > *"This conversation happened 1,000 times now. Like every time I tell you I
 *   > want exactly same identical view of every type of session inside,
 *   > including remote session, including local session"*
 *
 * The two buttons were drawn and refused, each with a written sentence. The
 * sentences were true about the wiring: chat read a transcript file on the far
 * machine's disk, and split arranged panes that were filled from this window's
 * own session list only. This file pins what changed and — as importantly —
 * what did not, because the shape of the fix is a pile of small invariants that
 * each look like tidying and are not.
 *
 * **Half of the complaint was answered by deletion.** Chat mode was removed
 * from every client on 2026-08-26 — *"I don't think so it can work smoothly so
 * it's better to completely remove this"* — so there is no longer a second view
 * for a remote session to be missing. What survives here is the other half, and
 * it is the half that was structural: a pane holds a session on any of the
 * three computers, and the window has one name for what is on screen.
 *
 * Written against the source text, like the other wiring files here. What it is
 * checking is *which expression is wired to which*, and that is exactly the
 * class of mistake a render test cannot see: the app rendered perfectly well
 * while the mode switch read one session and wrote another.
 */

const APP = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

describe('what is on screen has one name', () => {
  /*
   * `focusedId` is the *local* answer — the focused pane's tab while split, the
   * selected tab otherwise — and it was also the only answer. Everything about
   * how the window is drawn was keyed on it, including the per-session view
   * state the mode switch read and wrote. With a session on a paired machine or
   * a terminal on a server filling the pane, that is the id of a session **that
   * is not on screen**, so a control in the bar acted on something behind what
   * he was looking at and nothing on screen moved.
   *
   * The per-session half of that state went with chat mode. What is left is
   * one question — is this window split — which is a fact about the window and
   * cannot be read off the wrong session at all.
   */
  it('reads the window and nothing per-session', () => {
    expect(APP).toContain("const mode: WorkspaceMode = splitting ? 'split' : 'terminal'")
    expect(APP, 'the per-session view map is back').not.toContain('sessionView[')
  })

  it('writes only the window, and lands the collapse where you were', () => {
    const setMode = /const setMode = useCallback\([\s\S]*?\n {2}\)/.exec(APP)?.[0] ?? ''
    expect(setMode, 'setMode has changed shape').not.toBe('')
    expect(setMode).toContain('splitPanes()')
    expect(setMode).toContain('closeSplit()')
    expect(setMode, 'a per-session mode is being written again').not.toContain('setSessionView')
  })

  it('resolves that name from the window and the layout, in one place', () => {
    const shown = /const shownTabId: string \| null = [\s\S]*?\n\n/.exec(APP)?.[0] ?? ''
    expect(shown, 'shownTabId has changed shape').not.toBe('')
    // Split, the panes already name what they hold on whichever computer, so
    // the focused pane is the whole answer.
    expect(shown).toContain('splitting')
    expect(shown).toContain('machineTabId(openMachineSession.machineId, openMachineSession.sessionId)')
    expect(shown).toContain('openServerSession')
  })

  it('gives the rail and the strip that same one name', () => {
    // A window where the highlighted row and the highlighted pill disagree is
    // the defect `covered` was written for, in a third costume.
    expect(APP).toContain('const railActiveTabId = shownTabId ?? activeTab?.id ?? null')
  })
})

describe('a pane can hold a session on any of the three computers', () => {
  it('looks a pane’s tab up in every open window, not only this one’s', () => {
    /*
     * `tabs` is this window's own sessions and pages. A pane holding a session
     * on a paired machine or a terminal on a server found nothing in it, so it
     * drew "Nothing in this pane yet" over a live terminal — which is why the
     * refusal on the split button was honest at the time.
     */
    expect(APP).toContain(
      "const paneTab = tabId ? openTabs.find((entry) => entry.id === tabId) ?? null : null",
    )
  })

  it('seeds a new split from what is on screen, wherever it is running', () => {
    expect(APP).toContain('seedSplit(openTabsRef.current, shownTabId)')
  })

  it('prunes a pane against a list that knows about all three', () => {
    /*
     * `pruneClosedPanes` closes a pane whose window is not in the list it is
     * handed, so the list has to be the authority on what exists. Handed `tabs`
     * it would close a remote pane on the very next render.
     */
    expect(APP).toContain('pruneClosedPanes(current, panePruneRef.current)')
  })

  it('keeps a pane whose machine has merely stopped answering', () => {
    /*
     * `machineTabs` is built from each machine's *live* roster, so a link that
     * drops for three seconds empties it — and pruning on that would tear a
     * hand-made layout apart every time the relay reconnected. A machine that
     * *is* answering and says the session is gone is believed, because then its
     * tab is genuinely absent while the machine is in the list.
     */
    const list = /const panePruneList: readonly \{ id: string \}\[\] = \[[\s\S]*?\n {2}\]/.exec(APP)?.[0] ?? ''
    expect(list, 'panePruneList has changed shape').not.toBe('')
    expect(list).toContain('...openTabs')
    expect(list).toContain('machineSessionPanes')
    expect(list).toContain('return !row?.link')
  })

  it('mounts the far terminal for a pane that holds one', () => {
    /*
     * `openMachineSession` is the unsplit window's answer and is cleared on the
     * way into a split, so without this a remote session dropped into a pane
     * would have a bar, a hole and nothing to fill it.
     */
    const effect = /const paneMachineIds = [\s\S]*?\n {2}\}, \[paneMachineIds\]\)/.exec(APP)?.[0] ?? ''
    expect(effect, 'the pane-held machine mount has changed shape').not.toBe('')
    expect(effect).toContain('readMachineTabId(id)')
    expect(effect).toContain('setMachineSessionPanes')
  })

  it('draws an empty body and lets the mounted terminal stand in it', () => {
    /*
     * The terminal is not moved into the pane, and that is the load-bearing
     * half: unmounting a remote session detaches from the far machine and
     * replays its whole scrollback on the way back, and unmounting a server
     * pane closes the SSH shell for real. So the pane leaves a hole and the
     * always-mounted terminal is given its rectangle.
     */
    expect(APP).toContain('<div className="pane-remote-slot" {...{ [SLOT_ATTR]: elsewhere.tab.id }} />')
    /*
     * Measured once per server tab. It was handed to two panes while a terminal
     * on a server also had a conversation drawn in the same rectangle; the
     * conversation went with chat mode, so there is one now — and it is still
     * read from one place, because two `slotStyle` calls for one hole is two
     * chances for the pair to be given different rectangles.
     */
    expect(APP).toContain('const box = slotStyle(paneSlots[entry.tabId])')
    expect((APP.match(/\bbox=\{box\}/g) ?? []).length).toBe(1)
    expect(APP).toContain('style={slotStyle(paneSlots[machineTabId(pane.machineId, pane.sessionId)])}')
  })

  it('still mounts exactly two control clusters', () => {
    /*
     * A guest pane's controls and the window's bar are the same component with
     * a different `target`, and that is the whole claim of sameness: three call
     * sites would be three things to keep in step, and the first to drift would
     * be the remote one nobody looks at.
     */
    const mounts = APP.match(/<SessionControls\b[\s\S]*?\/>/g) ?? []
    expect(mounts.length, 'a control-cluster mount has appeared or gone').toBe(2)
    expect(APP).toContain('target={paneControls.target}')
  })
})

describe('the window and the layout never both claim the frame', () => {
  it('hands the window over to the panes on the way into a split', () => {
    /*
     * `openMachineSession` / `openServerSession` are the *unsplit* window's way
     * of saying "this fills the frame". Leaving them set through a split meant
     * `heading` and every pane's visibility disagreeing about whether the far
     * terminal was the whole window or one of two panes.
     */
    const split = /const splitPanes = useCallback\(\(\) => \{[\s\S]*?\n {2}\}, \[/.exec(APP)?.[0] ?? ''
    expect(split, 'splitPanes has changed shape').not.toBe('')
    expect(split).toContain('setOpenMachineSession(null)')
    expect(split).toContain('setOpenServerSession(null)')
  })

  it('lands the collapsed window on the pane you were working in', () => {
    /*
     * Without this, collapsing a split whose focused pane held a terminal on a
     * server left `openServerSession` null and the unsplit window fell back to
     * whatever local tab happened to be active — the session you had been
     * typing into replaced by one you had not chosen.
     */
    const close = /const closeSplit = useCallback\(\(\) => \{[\s\S]*?\n {2}\}, \[/.exec(APP)?.[0] ?? ''
    expect(close, 'closeSplit has changed shape').not.toBe('')
    expect(close).toContain('paneForTab(shownTabId)')
    expect(close).toContain('setOpenMachineSession(landing.machine)')
    expect(close).toContain('setOpenServerSession(landing.server)')
  })

  it('fills the focused pane when a far session is picked while split', () => {
    /*
     * The rail is a list of what you have open, not a layout editor. A click
     * that took the whole frame back would be the list undoing the arrangement
     * — and taking the frame is what this did unconditionally, which is half of
     * why a remote session could not be *put* in a pane at all.
     */
    const select = /const selectTab = useCallback\([\s\S]*?\n {2}\)/.exec(APP)?.[0] ?? ''
    expect(select, 'selectTab has changed shape').not.toBe('')
    const routed = select.match(/if \(isSplit\(panesRef\.current\)\) \{/g) ?? []
    expect(routed.length, 'one of the two far-session routes does not reach a pane').toBe(2)
  })

  it('lets the split be drawn at all while a far session is open', () => {
    // `mainView` is the only thing that mounts `SplitView`, so returning null
    // above it for a server session meant a window with a mode switch reading
    // Split and nothing under it.
    expect(APP).toContain('if (!splitting && openServerSession !== null) return null')
    expect(APP).toContain('if (!splitting && openMachineSession !== null && machines.bridge !== null) return null')
  })
})

describe('what the mode switch refuses now', () => {
  it('refuses nothing at all, because there is nothing left it cannot do', () => {
    /*
     * There were two sentences here and both were about chat: a build with no
     * channel for reading a transcript off a server, and a terminal the server
     * had not answered for yet. Chat mode is gone, and split arranges this
     * window's own panes over whatever they are holding — so the control has
     * no state in which it has to explain itself, and the `unavailable` prop is
     * passed by nobody.
     */
    const mount = /<ModeSwitch[\s\S]*?\/>/.exec(APP)?.[0] ?? ''
    expect(mount, 'the mode switch mount has changed shape').not.toBe('')
    expect(mount).toContain('splitOffer={!features.on(\'split\')}')
    expect(mount, 'a refusal table is back').not.toContain('unavailable')
    expect(APP, 'modesBlocked is back').not.toContain('modesBlocked')
  })
})
