import { describe, expect, it } from 'vitest'
import {
  AUTO_SELECTION,
  EMPTY_SELECTION,
  paneForTab,
  resolveActiveTab,
  showTabSelection,
} from './tab-selection'
import { machineTabId, serverTabId, type WorkspaceTab } from './workspace-tabs'

/**
 * The last tab has to be closable.
 *
 * *"If there are three or two windows open and I close all of them, the last one
 * I will not be able to close from the top bar."* The strip already answered
 * `select: null` for that press; what made the tab come straight back was this
 * resolution treating `null` as "show me the first thing that is open". These
 * tests are the fix, held as a property of one pure function rather than as an
 * agreement between the strip, the window and the tab bar.
 */

const tab = (id: string): WorkspaceTab => ({
  id,
  kind: 'session',
  label: id,
  closable: true,
})

const OPEN = [tab('a'), tab('b')]

describe('what the window shows', () => {
  it('shows the first thing open until somebody has chosen', () => {
    // A launch, and every reload: sessions arrive from the main process and the
    // window has to show one of them without waiting to be told which.
    expect(resolveActiveTab(AUTO_SELECTION, OPEN)?.id).toBe('a')
  })

  it('shows what was chosen', () => {
    expect(resolveActiveTab(showTabSelection('b'), OPEN)?.id).toBe('b')
  })

  it('shows nothing at all once the last tab has been taken off', () => {
    /*
     * The whole point. `null` from `removeFromStrip` is a person emptying the
     * bar, and the pane below goes to its empty state — which already exists,
     * from the per-pane chrome work, and reads "Nothing in this pane yet".
     */
    expect(resolveActiveTab(showTabSelection(null), OPEN)).toBeNull()
    expect(resolveActiveTab(EMPTY_SELECTION, OPEN)).toBeNull()
  })

  it('stays empty however many things are open', () => {
    // The failing behaviour in one line: with two sessions running, an emptied
    // window used to draw the first of them and put its tab back in the strip.
    expect(resolveActiveTab(EMPTY_SELECTION, OPEN)).toBeNull()
    expect(resolveActiveTab(EMPTY_SELECTION, [])).toBeNull()
  })

  it('falls back when the chosen tab has gone, rather than blanking', () => {
    /*
     * Not the same as an empty pane, and the difference is the reason the type
     * has three states rather than two. An agent's process exiting, or a project
     * being closed, removes a tab nobody asked to remove — blanking the window
     * there would make every crash look like the app had broken.
     */
    expect(resolveActiveTab(showTabSelection('gone'), OPEN)?.id).toBe('a')
  })

  it('has nothing to show when nothing is open', () => {
    expect(resolveActiveTab(AUTO_SELECTION, [])).toBeNull()
    expect(resolveActiveTab(showTabSelection('a'), [])).toBeNull()
  })
})

/**
 * The ✕ on the tab you are looking at, for every kind of session there is.
 *
 * Asad, 2026-08-21, inside a terminal on Office PC: *"Now if I am on this
 * session and I want to close this session from here, from top bar, I think I
 * cannot because I am inside. So either it should not matter if I am inside or
 * not."* And immediately after, the bound on it: *"If I click close, it should
 * close, but it will stay live in side panel. But from the top bar it should
 * go."*
 *
 * The press failed on exactly the sessions that are not on this computer, and
 * `paneForTab` is the missing half. The strip already demoted the tab; what kept
 * it on screen — and therefore back on the bar, because `shownTabs` always draws
 * whatever is active — was the window still holding "a session on Office PC is
 * filling the pane" in a second piece of state that the press never touched.
 *
 * Pinned here rather than in a rendered strip because it is the half no
 * screenshot shows: the tab visibly moves to the end of the row either way, and
 * only this says whether the window went with it.
 */
describe('where a tab has to be shown', () => {
  const MACHINE = machineTabId('m-1', 'r7')
  const SERVER = serverTabId('11111111-2222-3333-4444-555555555555', 'k1')

  it('puts a session on a paired machine into the machine pane', () => {
    expect(paneForTab(MACHINE)).toEqual({
      machine: { machineId: 'm-1', sessionId: 'r7' },
      server: null,
      local: false,
    })
  })

  it('puts a terminal on a server into the server pane, by tab id', () => {
    // The id, not the two halves: `App.tsx` holds this one as an id at every
    // site that reads it, and `readServerTabId` takes it apart where the halves
    // are actually wanted.
    expect(paneForTab(SERVER)).toEqual({ machine: null, server: SERVER, local: false })
  })

  it('takes both panes away for anything this window draws itself', () => {
    /*
     * A local session, the copilot and a browser page are all one answer, and
     * that answer is what was missing: without it, showing a local tab left a
     * server terminal mounted in front of it and `railActiveTabId` still
     * pointing at the tab that had just been taken off the bar.
     */
    for (const id of ['s1', 'copilot-session-1', 'browser:1755:2']) {
      expect(paneForTab(id)).toEqual({ machine: null, server: null, local: true })
    }
  })

  it('empties the window when there is nothing left to fall back to', () => {
    /*
     * `null` is `removeFromStrip` saying the bar has nothing left. A server
     * terminal still filling the pane under an empty strip is the same
     * contradiction as a tab that will not leave, seen from the other side.
     */
    expect(paneForTab(null)).toEqual({ machine: null, server: null, local: true })
  })

  it('moves the pane between machines rather than only ever clearing it', () => {
    // Taking the active server tab off the bar can land on another far session,
    // and that has to be *shown*, not merely un-hidden from the local one.
    expect(paneForTab(machineTabId('m-2', 'r9')).machine).toEqual({
      machineId: 'm-2',
      sessionId: 'r9',
    })
    expect(paneForTab(machineTabId('m-2', 'r9')).server).toBeNull()
  })

  it('reads an id that is nearly one of the far ones as local, rather than guessing', () => {
    /*
     * `readMachineTabId` and `readServerTabId` refuse a prefix with no second
     * half, and this is the consequence being stated: a malformed id routes to
     * the local answer, which draws nothing on another computer. The alternative
     * — routing a half-parsed id at a machine — is a window attaching to a
     * session that does not exist.
     */
    for (const id of ['machine ', 'machine m-1', 'server ', 'server s-1']) {
      expect(paneForTab(id).local, id).toBe(true)
    }
  })

  it('ends nothing, on any branch', () => {
    /*
     * *"it will stay live in side panel."* This function is the whole of what
     * the ✕ reaches, so the guarantee is checkable here: it is pure, it answers
     * three fields, and none of them is a verb. A future edit that made it
     * return something to close would have to change this shape.
     */
    for (const id of [null, 's1', MACHINE, SERVER]) {
      expect(Object.keys(paneForTab(id)).sort()).toEqual(['local', 'machine', 'server'])
    }
  })
})
