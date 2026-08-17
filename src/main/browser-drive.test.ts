import { describe, expect, it } from 'vitest'
import type { DriveState } from './browser-cdp'
import {
  DISPATCH_CLAIM_MS,
  DispatchRing,
  MAX_ANNOUNCED,
  MAX_PROMPT_CHARS,
  isTakeoverCandidate,
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

describe('telling his input from the driver’s', () => {
  it('only reacts to events that carry an intention', () => {
    expect(isTakeoverCandidate('mouseDown')).toBe(true)
    expect(isTakeoverCandidate('keyDown')).toBe(true)
    expect(isTakeoverCandidate('rawKeyDown')).toBe(true)
    expect(isTakeoverCandidate('char')).toBe(true)
    // Movement is deliberately not watched. One dispatched `mouseMoved` was
    // measured to produce five `mouseMove`s and a `mouseLeave` on the
    // listener, so a driver that treated a move as a takeover would park
    // itself on its own output, constantly.
    expect(isTakeoverCandidate('mouseMove')).toBe(false)
    expect(isTakeoverCandidate('mouseLeave')).toBe(false)
    expect(isTakeoverCandidate('mouseUp')).toBe(false)
    expect(isTakeoverCandidate('mouseWheel')).toBe(false)
    expect(isTakeoverCandidate(undefined)).toBe(false)
  })

  it('claims back an event the driver just sent', () => {
    const ring = new DispatchRing()
    ring.announce('mouseDown', 1_000)
    expect(ring.claim('mouseDown', 1_050)).toBe(true)
  })

  it('does not claim the same announcement twice', () => {
    // Two clicks on the same button are two entries. Without this, his click
    // landing right after the agent's would be matched against the agent's
    // announcement and the takeover would be missed.
    const ring = new DispatchRing()
    ring.announce('mouseDown', 1_000)
    expect(ring.claim('mouseDown', 1_010)).toBe(true)
    expect(ring.claim('mouseDown', 1_020)).toBe(false)
  })

  it('stops claiming once the announcement is stale', () => {
    const ring = new DispatchRing()
    ring.announce('mouseDown', 1_000)
    expect(ring.claim('mouseDown', 1_000 + DISPATCH_CLAIM_MS + 1)).toBe(false)
  })

  it('treats an event it cannot account for as the person', () => {
    // The asymmetry, stated as a test. Reading a synthetic event as human
    // parks the drive and costs a retry; reading his keystroke as synthetic
    // means the agent keeps typing while he does.
    const ring = new DispatchRing()
    ring.announce('mouseDown', 1_000)
    expect(ring.claim('keyDown', 1_010)).toBe(false)
  })

  it('does not remember events it would never watch for', () => {
    const ring = new DispatchRing()
    ring.announce('mouseMove', 1_000)
    expect(ring.size()).toBe(0)
  })

  it('is bounded, so a driver stuck in a loop cannot grow it forever', () => {
    const ring = new DispatchRing()
    for (let i = 0; i < MAX_ANNOUNCED * 3; i++) ring.announce('mouseDown', 1_000 + i)
    expect(ring.size()).toBeLessThanOrEqual(MAX_ANNOUNCED)
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
