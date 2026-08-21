import { describe, expect, it, vi } from 'vitest'
import { createWindowAsks, WINDOW_ASK_TIMEOUT_MS } from './window-asks'
import type { ServerMessage } from './protocol'

/**
 * The desk that carries a browser verb to the machine holding the window.
 *
 * Everything here is about the failure directions, because the happy path is one
 * `Map` lookup and the failures are what decide whether a person's turn hangs.
 * `credentials.ts` learned the same lesson one capability over and its own
 * comment states it: a question nobody can hear is not a slow question, and a
 * feature that takes a minute to say "your other computer is not here" is a
 * feature people stop trusting.
 */

function sent(): { frames: ServerMessage[]; heard: number } {
  return { frames: [], heard: 1 }
}

describe('asking the machine that holds the window', () => {
  it('names the device, the session and the verb, and nothing else', async () => {
    const out = sent()
    const desk = createWindowAsks()
    desk.serve({
      ask: (deviceId, message) => {
        expect(deviceId).toBe('dev-1')
        out.frames.push(message)
        return 1
      },
    })

    const answer = desk.call({
      deviceId: 'dev-1',
      sessionId: 'sess-1',
      tool: 'browser.read',
      args: '{"selector":"h1"}',
    })
    expect(out.frames).toHaveLength(1)
    const frame = out.frames[0]
    expect(frame.t).toBe('window.call')
    if (frame.t !== 'window.call') throw new Error('unreachable')
    // No window id, no tab id, no view id. The far end resolves the slot inside
    // that session's own binding, which is what stops a session naming a page
    // nobody gave it — see `browser-tools.ts`'s `boundOf`.
    expect(Object.keys(frame).sort()).toEqual(['args', 'id', 'session', 't', 'tool'])
    expect(frame.session).toBe('sess-1')
    expect(frame.tool).toBe('browser.read')

    expect(desk.answer(frame.id, { ok: true, body: '{"title":"Example"}' })).toBe(true)
    await expect(answer).resolves.toEqual({ ok: true, body: '{"title":"Example"}' })
    expect(desk.waiting).toBe(0)
  })

  it('refuses in milliseconds when nothing over there can hear it', async () => {
    const desk = createWindowAsks()
    desk.serve({ ask: () => 0 })
    const answer = await desk.call({
      deviceId: 'dev-1',
      sessionId: 'sess-1',
      tool: 'browser.read',
      args: '{}',
    })
    expect(answer.ok).toBe(false)
    // The sentence has to be actionable, because an agent told only "no" tries
    // another way in — the measured behaviour `session-verbs.ts` exists to stop.
    expect(String(JSON.parse(answer.body).message)).toMatch(/not connected/)
    expect(desk.waiting).toBe(0)
  })

  it('refuses with a sentence rather than hanging when the device says nothing', async () => {
    vi.useFakeTimers()
    try {
      const desk = createWindowAsks({ timeoutMs: 1_000 })
      desk.serve({ ask: () => 1 })
      const answer = desk.call({
        deviceId: 'dev-1',
        sessionId: 'sess-1',
        tool: 'browser.read',
        args: '{}',
      })
      expect(desk.waiting).toBe(1)
      await vi.advanceTimersByTimeAsync(1_000)
      const result = await answer
      expect(result.ok).toBe(false)
      expect(String(JSON.parse(result.body).message)).toMatch(/did not answer/)
      expect(desk.waiting).toBe(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('settles every question to a device the moment its channel goes', async () => {
    const desk = createWindowAsks()
    desk.serve({ ask: () => 1 })
    const mine = desk.call({ deviceId: 'dev-1', sessionId: 's', tool: 'browser.read', args: '{}' })
    const other = desk.call({ deviceId: 'dev-2', sessionId: 's', tool: 'browser.read', args: '{}' })
    expect(desk.waiting).toBe(2)

    desk.gone('dev-1')
    const result = await mine
    expect(result.ok).toBe(false)
    expect(String(JSON.parse(result.body).message)).toMatch(/disconnected/)
    // The other device's question is untouched: the desk is keyed by device and
    // one machine dropping must not answer for another.
    expect(desk.waiting).toBe(1)
    desk.stop()
    await expect(other).resolves.toMatchObject({ ok: false })
  })

  it('drops an answer nothing is waiting for, rather than throwing', () => {
    const desk = createWindowAsks()
    desk.serve({ ask: () => 1 })
    // What a device sends when its answer and this end's deadline crossed on the
    // wire. The tool call has already been answered; there is nothing to do and
    // nothing to complain about.
    expect(desk.answer('never-asked', { ok: true, body: '{}' })).toBe(false)
  })

  it('waits longer than the one verb that waits on a person', () => {
    /*
     * `browser.handover` returns after about forty-five seconds by design, with
     * `resumed: false` meaning the person is still working. A deadline under
     * that would make this app's most patient control the one that always
     * appears to fail — and it has to stay under the sixty seconds an MCP client
     * allows a call, or the model is told by its own timeout instead of by us.
     */
    expect(WINDOW_ASK_TIMEOUT_MS).toBeGreaterThan(45_000)
    expect(WINDOW_ASK_TIMEOUT_MS).toBeLessThan(60_000)
  })
})
