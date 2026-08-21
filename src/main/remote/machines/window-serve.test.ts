import { describe, expect, it } from 'vitest'
import { serveWindowCall, type WindowServeDeps } from './window-serve'
import type { CallResult } from '../../deck-control/control'

/**
 * The end of the wire that decides.
 *
 * A verb arriving from another machine passes two gates before this app's
 * browser moves — may that machine ask at all, and is that verb one of the six —
 * and both of them are here rather than at the sending end, because the browser
 * is here. What is *not* here is any second copy of the tier table, the
 * confirmation broker or the binding lookup: those are `deck-control`'s, reached
 * through the one dispatcher, and the last test in this file is what says so.
 */

function deck(answer: Partial<CallResult> = {}): {
  deps: WindowServeDeps
  calls: { name: string; args: unknown; caller: unknown; attended: boolean }[]
} {
  const calls: { name: string; args: unknown; caller: unknown; attended: boolean }[] = []
  const deps: WindowServeDeps = {
    allowed: () => true,
    control: () => ({
      call: async (name, args, options) => {
        calls.push({ name, args, caller: options.caller, attended: options.attended })
        return {
          ok: true,
          value: { title: 'Example' },
          error: null,
          refusal: null,
          row: {} as CallResult['row'],
          ...answer,
        }
      },
    }),
  }
  return { deps, calls }
}

const READ = { sessionId: 'sess-1', tool: 'browser.read', args: '{}' }

function said(body: string): string {
  return String((JSON.parse(body) as { message?: unknown }).message ?? '')
}

describe('who may drive a window here from another machine', () => {
  it('refuses when nobody has allowed that machine, and says where the switch is', async () => {
    const { deps, calls } = deck()
    const answer = await serveWindowCall({ ...deps, allowed: () => false }, 'machine-1', READ)
    expect(answer.ok).toBe(false)
    // Actionable, because this is the one refusal on this path a person can do
    // something about — and an agent told only "no" goes looking for another way
    // in rather than reporting it.
    expect(said(answer.body)).toMatch(/Machines/)
    // And nothing reached the dispatcher: the grant is checked before the app's
    // browser is asked anything at all.
    expect(calls).toHaveLength(0)
  })

  it('asks the store on every call rather than once when the link came up', async () => {
    const { deps } = deck()
    let allowed = false
    const live: WindowServeDeps = { ...deps, allowed: () => allowed }
    expect((await serveWindowCall(live, 'machine-1', READ)).ok).toBe(false)
    allowed = true
    expect((await serveWindowCall(live, 'machine-1', READ)).ok).toBe(true)
    allowed = false
    // The untick lands on the next call, not on the next reconnection. Same
    // property `callers.ts` gives `TokenGrant.caller` by making it a function.
    expect((await serveWindowCall(live, 'machine-1', READ)).ok).toBe(false)
  })

  it('refuses a tool that is not one of the six, in the words a missing one gets', async () => {
    const { deps, calls } = deck()
    const answer = await serveWindowCall(deps, 'machine-1', { ...READ, tool: 'sessions.start' })
    expect(answer.ok).toBe(false)
    /*
     * "There is no such tool here" rather than "that tool is not for you".
     * Driving *other sessions* is the copilot's alone — *"they should not be
     * able to find it also"* — and a refusal that confirmed the tool exists
     * would hand over by sentence what the allow-list withholds by listing.
     */
    expect(said(answer.body)).toBe('there is no such tool here.')
    expect(calls).toHaveLength(0)
  })

  it('refuses the screenshot, because its answer is a path on the wrong computer', async () => {
    const { deps, calls } = deck()
    const answer = await serveWindowCall(deps, 'machine-1', { ...READ, tool: 'browser.screenshot' })
    expect(answer.ok).toBe(false)
    // Named as the verb that does work, because a refusal an agent cannot act on
    // is one it retries unchanged.
    expect(said(answer.body)).toMatch(/browser\.read/)
    expect(calls).toHaveLength(0)
  })

  it('says the endpoint is still coming up rather than failing vaguely', async () => {
    const { deps } = deck()
    const answer = await serveWindowCall({ ...deps, control: () => null }, 'machine-1', READ)
    expect(answer.ok).toBe(false)
    expect(said(answer.body)).toMatch(/not running yet/)
  })

  it('refuses arguments that are not readable, rather than acting on an empty object', async () => {
    const { deps, calls } = deck()
    const answer = await serveWindowCall(deps, 'machine-1', { ...READ, args: 'not json' })
    expect(answer.ok).toBe(false)
    expect(calls).toHaveLength(0)
  })
})

describe('what reaches the dispatcher', () => {
  it('pairs the far machine’s session id with this end’s id for that machine', async () => {
    const { deps, calls } = deck()
    const answer = await serveWindowCall(deps, 'machine-1', { ...READ, args: '{"selector":"h1"}' })
    expect(answer).toEqual({ ok: true, body: JSON.stringify({ title: 'Example' }) })
    expect(calls).toHaveLength(1)
    expect(calls[0].name).toBe('browser.read')
    expect(calls[0].args).toEqual({ selector: 'h1' })
    /*
     * `<machineId>\0<sessionId>` is the key `browser-binding.ts` wrote when the
     * person attached the window from this app, and neither end holds the whole
     * of it: the far machine sent its own session id and cannot know what this
     * desktop calls the machine it is on, because the link id was minted here on
     * pairing.
     */
    expect(calls[0].caller).toMatchObject({
      kind: 'session',
      sessionId: 'sess-1',
      machineId: 'machine-1',
    })
    // Attended, because the person is at *this* computer looking at the window
    // this call is about. Which machine asked does not change where the browser
    // is, and a confirmation can be drawn where they are looking.
    expect(calls[0].attended).toBe(true)
  })

  it('carries the dispatcher’s own refusal back word for word', async () => {
    const { deps } = deck({ ok: false, value: null, error: 'B2 has no page in it yet' })
    const answer = await serveWindowCall(deps, 'machine-1', READ)
    expect(answer.ok).toBe(false)
    // Not reworded here. The sentences composed by the tools are the actionable
    // ones, and a second voice describing the same refusal is how two spellings
    // of one rule get shipped.
    expect(said(answer.body)).toBe('B2 has no page in it yet')
  })
})
