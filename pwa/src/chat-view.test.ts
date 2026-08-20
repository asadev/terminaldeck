/**
 * The two rules the phone's chat view has, exercised without a DOM.
 *
 * Everything else about that screen is a shape, and a shape is checked by
 * looking at it. What is here is the pair of decisions that are wrong silently:
 * how an answer folds into what is already held, and what a bubble with no
 * timestamp prints.
 */

import { describe, expect, it } from 'vitest'
import type { CopilotChatMessage } from '../../src/main/remote/protocol'
import { bubbleTime, mergeRows } from './chat-view'

function row(id: string, text: string, role: 'you' | 'agent' = 'agent'): CopilotChatMessage {
  return { id, role, text, at: 0 }
}

describe('folding an answer into the conversation', () => {
  it('replaces a bubble by id and appends the rest', () => {
    /*
     * The id is what makes a growing answer redraw in place. Without it a reply
     * arriving in three `chat.rows` frames would stack a paragraph at a time —
     * the same defect `CopilotChatMessage.id` was added for on the copilot's own
     * conversation.
     */
    const held = [row('a', 'one'), row('b', 'two')]
    const merged = mergeRows(held, [row('b', 'two, and more'), row('c', 'three')], false)
    expect(merged.map((m) => m.text)).toEqual(['one', 'two, and more', 'three'])
    // The order a person is reading in does not move when a bubble grows.
    expect(merged.map((m) => m.id)).toEqual(['a', 'b', 'c'])
  })

  it('throws everything away on a reset, because the document changed underneath', () => {
    /*
     * `reset` means what this view holds is not a prefix of what is over there —
     * a rolled-over transcript, an account switch, a compaction. A client that
     * appended through one renders the conversation twice.
     */
    const held = [row('a', 'one'), row('b', 'two')]
    expect(mergeRows(held, [row('x', 'fresh')], true).map((m) => m.text)).toEqual(['fresh'])
    // A reset with nothing in it is a conversation that is genuinely empty now.
    expect(mergeRows(held, [], true)).toEqual([])
  })

  it('leaves what is held alone when an answer carries nothing new', () => {
    const held = [row('a', 'one')]
    expect(mergeRows(held, [], false)).toEqual(held)
    // And does not mutate the array it was given.
    const merged = mergeRows(held, [row('b', 'two')], false)
    expect(held).toHaveLength(1)
    expect(merged).toHaveLength(2)
  })
})

describe('the time on a bubble', () => {
  it('prints nothing at all for a line the transcript never dated', () => {
    /*
     * `ChatMessage.at` is 0 for a line that carried no timestamp, and a bubble
     * that printed 01:00 for it would be stating something false in the one
     * place he asked for a figure. Absent, not "unknown", not a dash — the same
     * rule the rest of this client follows.
     */
    expect(bubbleTime(0)).toBe('')
    expect(bubbleTime(-1)).toBe('')
    expect(bubbleTime(Number.NaN)).toBe('')
  })

  it('prints a time and only a time', () => {
    const printed = bubbleTime(Date.UTC(2026, 7, 20, 12, 34))
    // The locale decides 24-hour or AM/PM and the zone decides the number, so
    // what is pinned is the shape: a time, with no date anywhere in it.
    expect(printed).not.toBe('')
    expect(printed).toMatch(/\d/)
    expect(printed).not.toMatch(/2026|Aug|20\//)
  })
})
