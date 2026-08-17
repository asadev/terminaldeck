import { describe, expect, it } from 'vitest'
import {
  AUTO_SELECTION,
  EMPTY_SELECTION,
  resolveActiveTab,
  showTabSelection,
} from './tab-selection'
import type { WorkspaceTab } from './workspace-tabs'

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
