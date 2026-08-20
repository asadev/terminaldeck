import { describe, expect, it } from 'vitest'
import { applyChat, readChatFrame, readStateReport } from './remote-copilot-model'

/**
 * Reading another machine's copilot.
 *
 * Two things are being pinned here and they fail in opposite directions. The
 * readers must be **suspicious**: everything arrives from a computer that may be
 * an older build, a newer one, or mid-reconnect, and a half-formed frame trusted
 * here becomes a page that throws. {@link applyChat} must be **exact**: it is the
 * one rule that decides whether a bubble the agent is still writing grows in
 * place or appears three times.
 */

const bubble = (id: string, text: string, role: 'you' | 'agent' = 'agent') => ({ id, role, text, at: 1 })

describe('reading a chat frame', () => {
  it('takes the messages it can read and drops the ones it cannot', () => {
    const frame = readChatFrame({
      run: 'r1',
      messages: [bubble('a', 'hello'), { id: '', text: 'no id' }, { id: 'c' }, bubble('d', 'bye')],
    })
    expect(frame?.messages.map((message) => message.id)).toEqual(['a', 'd'])
  })

  it('draws an unrecognised role as this side, never as the copilot', () => {
    // The safe direction. A role nobody knows, rendered as the agent, would be
    // this window putting words in the copilot's mouth.
    const frame = readChatFrame({ messages: [{ id: 'a', role: 'system', text: 'x' }] })
    expect(frame?.messages[0].role).toBe('you')
  })

  it('is nothing at all when there is no message list', () => {
    expect(readChatFrame({ run: 'r1' })).toBeNull()
    expect(readChatFrame(null)).toBeNull()
    expect(readChatFrame('copilot.chat')).toBeNull()
  })
})

describe('reading the state report', () => {
  it('keeps the desk and this device’s own run apart', () => {
    // The one thing this screen can get wrong that somebody would act on: the
    // desk copilot is that machine's own, and the run is the only one we can
    // talk to. A page that read `desk: running` as "there is a copilot for me"
    // would draw a composer with nothing behind it.
    const report = readStateReport({ desk: 'running', run: null, profile: 'a@b.c' })
    expect(report).toEqual({ desk: 'running', run: null, profile: 'a@b.c' })
  })

  it('reads a missing or unusable run as no run', () => {
    expect(readStateReport({ desk: 'running', run: '' })?.run).toBeNull()
    expect(readStateReport({ desk: 'running' })?.run).toBeNull()
    expect(readStateReport({ desk: 'running', run: 7 })?.run).toBeNull()
  })

  it('refuses a report whose desk state is not one of the three', () => {
    expect(readStateReport({ desk: 'busy', run: 'r1' })).toBeNull()
    expect(readStateReport({ run: 'r1' })).toBeNull()
  })
})

describe('folding a frame into what is on screen', () => {
  it('appends what is new', () => {
    const after = applyChat([bubble('a', 'one')], { messages: [bubble('b', 'two')], reset: false })
    expect(after.map((message) => message.id)).toEqual(['a', 'b'])
  })

  it('replaces a message it already has, rather than showing it twice', () => {
    /*
     * This is what a bubble growing while the agent writes looks like on the
     * wire: the same `id`, more text. `protocol.ts` says the id is *"stable
     * across reads, so an extended message replaces rather than duplicates"* —
     * appending would print every prefix of the answer down the page.
     */
    const after = applyChat([bubble('a', 'Look'), bubble('b', 'x')], {
      messages: [bubble('a', 'Looking at the diff now')],
      reset: false,
    })
    expect(after).toHaveLength(2)
    expect(after[0].text).toBe('Looking at the diff now')
    // And in place: a message that jumped to the bottom when it was extended
    // would reorder the conversation under somebody reading it.
    expect(after.map((message) => message.id)).toEqual(['a', 'b'])
  })

  it('starts again when the far end says it is restating', () => {
    // After a reconnect, or after the run was replaced. Merging would leave the
    // previous run's conversation above the new one under one heading.
    const after = applyChat([bubble('a', 'old'), bubble('b', 'older')], {
      messages: [bubble('z', 'fresh')],
      reset: true,
    })
    expect(after.map((message) => message.id)).toEqual(['z'])
  })
})
