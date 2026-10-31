import { describe, expect, it } from 'vitest'
import type { DriveState } from './browser-cdp'
import * as drive from './browser-drive'
import {
  MAX_PROMPT_CHARS,
  nextDriveState,
  sanitizeHandoverPrompt,
  type DriveEvent,
} from './browser-drive'

describe('the baton', () => {
  const move = (from: DriveState, kind: DriveEvent['kind']): DriveState =>
    nextDriveState(from, { kind })

  it('goes idle → agent when a tool claims the tab', () => {
    expect(move('idle', 'claimed')).toBe('agent')
    expect(move('agent', 'claimed')).toBe('agent')
  })

  it('never takes the page off the person, whatever order the calls arrive in', () => {
    // The tool layer refuses this earlier with a sentence. This is the backstop
    // that means no interleaving of a slow `browser.open` and a live handover
    // can produce it.
    expect(move('human', 'claimed')).toBe('human')
  })

  it('hands over from agent, and does nothing from idle', () => {
    expect(move('agent', 'handover')).toBe('human')
    expect(move('human', 'handover')).toBe('human')
    // A handover with nothing being driven has no page to hand over. Going to
    // `human` here would put a banner on screen asking somebody to act on a
    // tab that does not exist.
    expect(move('idle', 'handover')).toBe('idle')
  })

  it('only a person resumes, and only from human', () => {
    expect(move('human', 'resumed')).toBe('agent')
    expect(move('agent', 'resumed')).toBe('agent')
  })

  it('refuses to resurrect a drive that has already ended', () => {
    // He clicks "carry on" a beat after the tab was closed. A drive that
    // re-armed itself is the page that starts moving on its own, which
    // `DRIVING-MODE.md` §8 names as the single behaviour that would make
    // somebody uninstall.
    expect(move('idle', 'resumed')).toBe('idle')
  })

  it('ends from anywhere, including from idle', () => {
    for (const from of ['idle', 'agent', 'human'] as const) {
      expect(move(from, 'released')).toBe('idle')
    }
  })

  it('has no transition that reaches agent without a person or a tool', () => {
    // Exhaustive: the only two ways into `agent` are a tool claiming the tab
    // and a person handing it back. Anything else that ever reaches `agent`
    // would be a page that starts moving with nobody having asked.
    const reachesAgent: Array<[DriveState, DriveEvent['kind']]> = []
    for (const from of ['idle', 'agent', 'human'] as const) {
      for (const kind of ['claimed', 'handover', 'resumed', 'released'] as const) {
        if (move(from, kind) === 'agent' && from !== 'agent') reachesAgent.push([from, kind])
      }
    }
    expect(reachesAgent).toEqual([
      ['idle', 'claimed'],
      ['human', 'resumed'],
    ])
  })
})

/**
 * Nothing here tells his input from the driver's any more — 2026-08-21.
 *
 * There used to be eight tests in this place, over a `DispatchRing` that
 * correlated the events the driver announced with the events Chromium reported,
 * so that anything left over could be read as a person and park the drive. The
 * whole mechanism is deleted, because the behaviour it fed is:
 *
 *   > *"if I click inside, nothing should happen actually. It should keep giving
 *   > the access until I click here and I disconnect the browser from any of the
 *   > session."*
 *
 * This block is what is left of them, and it is deliberately a test rather than
 * a comment: the guarantee now is that **no** event exists for "the person
 * touched the page", so the way to state it is over the closed set of events the
 * baton has. If somebody adds one back, this fails.
 */
describe('a person using the page is not an event', () => {
  const move = (from: DriveState, kind: DriveEvent['kind']): DriveState =>
    nextDriveState(from, { kind })

  it('has no way to reach human except the agent asking', () => {
    const kinds: DriveEvent['kind'][] = ['claimed', 'handover', 'resumed', 'released']
    const reachesHuman = kinds.filter((kind) => move('agent', kind) === 'human')
    // `handover` is `browser.handover` — the agent asking for the person, with
    // a sentence it wrote. There is no second door, and there is no listener
    // anywhere that raises one on a click. See `browser-driver.ts`'s `watch`.
    expect(reachesHuman).toEqual(['handover'])
  })

  it('exports nothing to guess a person’s input with', () => {
    // The ring, its claim window and its type list are gone rather than left
    // switched off: a heuristic nobody consults is a thing the next reader has
    // to prove is dead.
    const module = drive as Record<string, unknown>
    expect(module.DispatchRing).toBeUndefined()
    expect(module.isTakeoverCandidate).toBeUndefined()
    expect(module.DISPATCH_CLAIM_MS).toBeUndefined()
    expect(module.MAX_ANNOUNCED).toBeUndefined()
  })
})

describe('the sentence drawn in the app’s own chrome', () => {
  it('keeps an ordinary sentence intact', () => {
    expect(sanitizeHandoverPrompt('Sign in to GitHub, then click Done.')).toBe(
      'Sign in to GitHub, then click Done.',
    )
  })

  it('flattens newlines and control characters', () => {
    expect(sanitizeHandoverPrompt('Sign in\n\nthen\tcarry on\u0000')).toBe('Sign in then carry on')
  })

  it('strips the bidirectional overrides', () => {
    /*
     * The one that is not obvious. `U+202E` reverses everything after it, so a
     * banner can be made to read as something other than what is in the action
     * log beside it — and this banner's entire job is to tell somebody what
     * they are about to type a password into.
     */
    const attack = 'Type your password into \u202Emoc.suoicilam\u202C'
    const clean = sanitizeHandoverPrompt(attack)
    expect(clean).not.toContain('\u202E')
    expect(clean).not.toContain('\u202C')
  })

  it('clamps a model that writes a paragraph', () => {
    const long = sanitizeHandoverPrompt('x'.repeat(MAX_PROMPT_CHARS * 3))
    expect(long.length).toBeLessThanOrEqual(MAX_PROMPT_CHARS + 1)
  })

  it('answers empty for anything that is not a string', () => {
    expect(sanitizeHandoverPrompt(undefined)).toBe('')
    expect(sanitizeHandoverPrompt({ toString: () => 'nope' })).toBe('')
  })
})
