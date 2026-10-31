import { describe, expect, it } from 'vitest'
import { QUIT_BUTTONS, plannedQuit, quitAnswer, quitQuestion } from './resident'
import type { SessionMeta } from '../shared/types'

/**
 * The three lines of this feature that must not be wrong, tested away from
 * Electron.
 *
 * Everything else in `resident.ts` is a `Tray` and a dialog and cannot be
 * exercised without a running app. These three can, and they are the ones where
 * being wrong is silent: a quit that keeps agents running when the person asked
 * to stop them, a background process holding nothing, or a button index off by
 * one so "Stop Everything" keeps everything.
 */

function meta(id: string): SessionMeta {
  return {
    id,
    cwd: `/tmp/${id}`,
    title: id,
    provider: 'claude',
    exitCode: null,
    createdAt: 0,
  }
}

describe('what a quit means', () => {
  it('quits outright when there is nothing running, whatever was remembered', () => {
    // The case that would otherwise leave a process in the background with a
    // tray icon reading "0 sessions running" — visible, pointless, and exactly
    // the thing this must not become.
    expect(plannedQuit(0, 'keep')).toBe('stop')
    expect(plannedQuit(0, 'ask')).toBe('stop')
    expect(plannedQuit(0, 'stop')).toBe('stop')
  })

  it('asks by default, and only when there is something to lose', () => {
    expect(plannedQuit(1, 'ask')).toBe('ask')
    expect(plannedQuit(4, 'ask')).toBe('ask')
  })

  it('honours a remembered answer in both directions', () => {
    expect(plannedQuit(2, 'keep')).toBe('keep')
    expect(plannedQuit(2, 'stop')).toBe('stop')
  })
})

describe('the buttons', () => {
  it('maps each button to the thing it is labelled', () => {
    expect(QUIT_BUTTONS[0]).toBe('Keep Them Running')
    expect(quitAnswer(0)).toBe('keep')
    expect(QUIT_BUTTONS[1]).toBe('Stop Everything')
    expect(quitAnswer(1)).toBe('stop')
    expect(QUIT_BUTTONS[2]).toBe('Cancel')
    expect(quitAnswer(2)).toBe('cancel')
  })

  it('treats a dismissed dialog as a cancel rather than as a decision', () => {
    // Electron reports `cancelId` for a dialog closed with Escape or the window
    // button; anything else arriving here is a version of the same thing, and
    // the safe reading of "no answer" is "do not quit".
    expect(quitAnswer(-1)).toBe('cancel')
    expect(quitAnswer(99)).toBe('cancel')
  })
})

describe('what the person is told', () => {
  it('counts the sessions rather than saying "some"', () => {
    expect(quitQuestion([meta('a')]).message).toBe('One session is still running.')
    expect(quitQuestion([meta('a'), meta('b')]).message).toBe('2 sessions are still running.')
  })

  it('names the menu bar, because that is the only way back to them', () => {
    expect(quitQuestion([meta('a')]).detail).toContain('menu bar')
  })
})
