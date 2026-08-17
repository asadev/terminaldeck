import { describe, expect, it } from 'vitest'
import {
  copilotStage,
  defaultPane,
  entryDot,
  entryTooltip,
  readCopilotSignIn,
  readCopilotState,
} from './copilot-model'

/**
 * The two decisions this file exists to hold, and both of them shipped wrong
 * elsewhere in this app before.
 *
 * **A copilot that is running and signed out opens on its terminal.** The
 * copilot keeps its login inside its own sandbox, and a sandboxed process
 * cannot reach the macOS keychain — so its first act is a login that prints a
 * URL and reads a code back. A conversation pane can do neither. Open on the
 * chat and a first-time reader gets an empty transcript over a session quietly
 * waiting for something they cannot see, which is exactly the shape of failure
 * this repository has shipped twice: something that looks broken while working.
 *
 * **`unknown` is never `signed-out`.** They send a person to two different
 * places — one to a login screen, one to a bug report — and collapsing them
 * would draw the login banner every time a probe timed out.
 */

const running = {
  status: 'running',
  sessionId: 'abc',
  paths: { root: '/u/copilot', instructions: '/u/copilot/CLAUDE.md', memory: '/u/copilot/memory', log: '/u/copilot-log', actions: '/u/copilot-log/actions.jsonl' },
  startedAt: 1,
  problem: null,
  confinement: { kind: 'seatbelt', enforced: true, reason: null },
}

describe('reading the state', () => {
  it('narrows a real answer', () => {
    const state = readCopilotState(running)
    expect(state?.status).toBe('running')
    expect(state?.sessionId).toBe('abc')
    expect(state?.paths?.root).toBe('/u/copilot')
    expect(state?.confined).toBe(true)
  })

  it('refuses anything that is not a state rather than inventing "stopped"', () => {
    // The difference matters on screen: a stopped copilot gets a Start button,
    // and a bridge that answered with nothing readable must not get one.
    for (const value of [null, undefined, 'running', 42, [], {}, { status: 'weird' }]) {
      expect(readCopilotState(value), JSON.stringify(value)).toBeNull()
    }
  })

  it('drops a half-written paths object rather than half-addressing the folder', () => {
    const state = readCopilotState({ ...running, paths: { instructions: '/x' } })
    expect(state?.paths).toBeNull()
  })

  it('reports an unproven boundary as unconfined', () => {
    const state = readCopilotState({
      ...running,
      confinement: { kind: 'seatbelt', enforced: false, reason: 'not proven' },
    })
    expect(state?.confined).toBe(false)
  })
})

describe('reading the sign-in', () => {
  it('keeps the three states apart', () => {
    expect(readCopilotSignIn({ state: 'signed-in', account: 'a@b.c', plan: 'Max' })?.state).toBe('signed-in')
    expect(readCopilotSignIn({ state: 'signed-out', account: null, plan: null })?.state).toBe('signed-out')
    expect(readCopilotSignIn({ state: 'unknown', account: null, plan: null })?.state).toBe('unknown')
  })

  it('refuses a state it does not recognise', () => {
    expect(readCopilotSignIn({ state: 'maybe' })).toBeNull()
    expect(readCopilotSignIn(null)).toBeNull()
  })
})

describe('the stage', () => {
  const state = readCopilotState(running)

  it('is first-run when it is running and signed out', () => {
    expect(copilotStage(state, { state: 'signed-out', account: null, plan: null })).toBe('first-run')
  })

  it('never turns an unreadable probe into a login', () => {
    expect(copilotStage(state, { state: 'unknown', account: null, plan: null })).toBe('unverified')
  })

  it('waits rather than guessing while the probe has not answered', () => {
    expect(copilotStage(state, null)).toBe('checking')
  })

  it('reports the machine before it reports the sign-in', () => {
    const unavailable = readCopilotState({ ...running, status: 'unavailable', problem: 'no boundary' })
    expect(copilotStage(unavailable, { state: 'signed-in', account: null, plan: null })).toBe('unavailable')
  })

  it('says stopped when nothing has been read at all', () => {
    expect(copilotStage(null, null)).toBe('stopped')
  })
})

describe('which pane opens', () => {
  it('opens the terminal on the first run, because a login needs one', () => {
    expect(defaultPane('first-run')).toBe('terminal')
  })

  it('opens the conversation everywhere else', () => {
    for (const stage of ['ready', 'unverified', 'checking', 'stopped', 'starting', 'unavailable'] as const) {
      expect(defaultPane(stage), stage).toBe('chat')
    }
  })
})

describe('the pinned row', () => {
  it('marks the first run as needing input, which is what a login is', () => {
    expect(entryDot('first-run')).toBe('input')
    expect(entryDot('starting')).toBe('working')
    expect(entryDot('ready')).toBe('idle')
  })

  it('draws no dot at all when nothing is running', () => {
    // There is no session status meaning "no process": `idle` prints **Ready**
    // beside a copilot that is not there, and `exited` claims a death that
    // never happened. So the row says nothing, and the tooltip says why.
    expect(entryDot('stopped')).toBeNull()
    expect(entryDot('unavailable')).toBeNull()
  })

  it('shows the last refusal rather than the word "stopped"', () => {
    const stopped = readCopilotState({
      ...running,
      status: 'stopped',
      sessionId: null,
      problem: 'Claude Code is not installed on this machine.',
    })
    expect(entryTooltip('stopped', stopped)).toContain('not installed')
  })

  it('still says something useful with no state at all', () => {
    expect(entryTooltip('stopped', null)).toContain('Open it to start it')
  })
})
