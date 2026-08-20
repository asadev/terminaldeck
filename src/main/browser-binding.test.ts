import { beforeEach, describe, expect, it } from 'vitest'
import {
  attach,
  attachReserved,
  bindingFor,
  detach,
  hookContext,
  hostReset,
  reserve,
  resetForTests,
  resolve,
  sessionExited,
  sessionRemoved,
  view,
  windowClosed,
} from './browser-binding'
import { BRAND } from '../shared/brand'

/**
 * The rules a person can be told out loud, each pinned once.
 *
 * Every one of these is a sentence Asad would say — "closing B1 doesn't move
 * B2", "open goes to B1" — rather than an implementation detail, because the
 * whole feature is a vocabulary and a vocabulary that shifts underfoot is worse
 * than none.
 */

beforeEach(() => {
  resetForTests()
})

describe('numbers are facts about a session, not positions in a list', () => {
  it('closing B1 leaves B2 called B2', () => {
    attach({ sessionId: 's1', browserTabId: 'browser:1:1' })
    attach({ sessionId: 's1', browserTabId: 'browser:1:2' })
    expect(bindingFor('s1')?.windows.map((w) => w.n)).toEqual([1, 2])

    windowClosed('browser:1:1')

    expect(bindingFor('s1')?.windows.map((w) => w.n)).toEqual([2])
  })

  it('a number is never handed out twice', () => {
    attach({ sessionId: 's1', browserTabId: 'browser:1:1' })
    detach('browser:1:1')
    const second = attach({ sessionId: 's1', browserTabId: 'browser:1:2' })

    // B2, not a second B1. Reuse is only ever corrected *between* turns; within
    // one turn a reissued B1 silently redirects an agent to a page it was never
    // told about.
    expect(second.n).toBe(2)
  })

  it('two sessions may each have a B1', () => {
    expect(attach({ sessionId: 's1', browserTabId: 'a' }).n).toBe(1)
    expect(attach({ sessionId: 's2', browserTabId: 'b' }).n).toBe(1)
  })

  it('a window attached elsewhere moves rather than being refused', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    attach({ sessionId: 's2', browserTabId: 'a' })

    expect(bindingFor('s1')?.windows).toEqual([])
    expect(bindingFor('s2')?.windows.map((w) => w.browserTabId)).toEqual(['a'])
  })

  it('gives each session a colour, and repeats only past the fourth', () => {
    const colours = ['s1', 's2', 's3', 's4'].map((id) => {
      attach({ sessionId: id, browserTabId: `tab-${id}` })
      return bindingFor(id)?.colour
    })
    expect(new Set(colours).size).toBe(4)
  })
})

describe('where a URL from a session goes', () => {
  it('refuses to guess for a session this app never started', () => {
    // No `known`, so this is an id from somebody else's shell — the hook and the
    // shim are installed for the whole machine and fire for those too.
    const plan = resolve('nobody')
    expect(plan.kind).toBe('system')
    // The sentence matters as much as the refusal: the shim prints it, and a
    // person reading "false" cannot act on it.
    if (plan.kind === 'system') expect(plan.reason).toContain('default browser')
  })

  it('refuses when there is no session id at all', () => {
    expect(resolve(null).kind).toBe('system')
  })

  it('takes the lowest-numbered window, not the most recent', () => {
    attach({ sessionId: 's1', browserTabId: 'first' })
    attach({ sessionId: 's1', browserTabId: 'second' })

    const plan = resolve('s1')
    expect(plan.kind).toBe('navigate')
    if (plan.kind === 'navigate') expect(plan.window.browserTabId).toBe('first')
  })

  it('mints one when the session has none', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    detach('a')
    expect(resolve('s1').kind).toBe('new')
  })

  it('mints one for a session of ours that has never had a window', () => {
    // The first `open` in every session takes this path, and it is the whole
    // feature: without it nothing lands in the app until somebody attaches a
    // window by hand.
    expect(resolve('fresh', '', { known: true }).kind).toBe('new')
  })

  it('mints one when the caller asks for a window of its own', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    expect(resolve('s1', '', { newWindow: true }).kind).toBe('new')
  })

  it('hands the reserved number to the window that arrives', () => {
    const n = reserve('s1')
    expect(n).toBe(1)
    const bound = attachReserved({ sessionId: 's1', browserTabId: 'a', n })
    expect(bound?.n).toBe(1)
    // A second window takes 2 rather than colliding with the reservation.
    expect(attach({ sessionId: 's1', browserTabId: 'b' }).n).toBe(2)
  })

  it('refuses to attach to a number already in use', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    expect(attachReserved({ sessionId: 's1', browserTabId: 'b', n: 1 })).toBeNull()
  })
})

describe('what the agent is told', () => {
  /* What a session started by this app, on a platform the shim covers, is in. */
  const inside = { known: true, opensInApp: true }

  it('says nothing at all to a session this app did not start', () => {
    // Null becomes a 204 with no body, which is the byte-identical answer this
    // endpoint has always given — and the hook is installed for the whole
    // machine, so his own terminal `claude` arrives here too and must be told
    // nothing whatsoever.
    expect(hookContext('s1', '', { opensInApp: true })).toBeNull()
    attach({ sessionId: 's1', browserTabId: 'a' })
    detach('a')
    expect(hookContext('s1', '', { opensInApp: true })).toBeNull()
  })

  it('tells a session it started where it is running, before any window exists', () => {
    // The fact he asked for, and the one that has to arrive on boot rather than
    // when somebody opens a browser window.
    const said = hookContext('s1', '', inside) ?? ''
    expect(said).toContain(BRAND.name)
    expect(said).toContain('`open <url>`')
  })

  it('claims no route on a platform where the shim was not written', () => {
    // Windows, or a Linux box with no opener at all. It still knows where it is;
    // it is simply not told about a command that would not reach this app.
    const said = hookContext('s1', '', { known: true }) ?? ''
    expect(said).toContain(BRAND.name)
    expect(said).not.toContain('`open <url>`')
  })

  it('names every window it holds, with what that window reported', () => {
    attach({
      sessionId: 's1',
      browserTabId: 'a',
      url: 'https://dashboard.stripe.com/payments',
      title: 'Stripe Dashboard',
    })
    attach({ sessionId: 's1', browserTabId: 'b', url: 'http://localhost:5173', title: 'Vite app' })
    attach({ sessionId: 's2', browserTabId: 'c', url: 'https://elsewhere', title: 'Not ours' })

    const said = hookContext('s1', '', inside) ?? ''
    expect(said).toContain('B1 — Stripe Dashboard — https://dashboard.stripe.com/payments')
    expect(said).toContain('B2 — Vite app — http://localhost:5173')
    expect(said, 'a session is never told about another session’s window').not.toContain('Not ours')
    // The line that makes "look at B2" work without anything being typed into
    // his terminal.
    expect(said).toContain('`open <url>` goes to B1')
  })

  it('prints nothing it was not told', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    // No url and no title reported yet, so neither is invented — an em-dash with
    // nothing after it would read to an agent as a page called nothing.
    expect(hookContext('s1', '', inside)).toContain('B1\n')
  })
})

describe('lifecycle', () => {
  it('keeps a dead session’s rows and marks them', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    sessionExited('s1')
    expect(bindingFor('s1')?.ended).toBe(true)
    expect(bindingFor('s1')?.windows).toHaveLength(1)
  })

  it('drops everything when the session is removed', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    sessionRemoved('s1')
    expect(bindingFor('s1')).toBeNull()
    // And the window is free to be attached somewhere else, rather than still
    // being owned by a session that no longer exists.
    expect(attach({ sessionId: 's2', browserTabId: 'a' }).n).toBe(1)
  })

  it('drops every binding when the renderer is replaced', () => {
    attach({ sessionId: 's1', browserTabId: 'a' })
    attach({ sessionId: 's2', browserTabId: 'b' })
    hostReset()
    expect(view().sessions).toEqual([])
  })
})
