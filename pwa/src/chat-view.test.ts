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
import { SUBMIT_GAP_MS } from '../../src/renderer/chat/attach/mentions'
import { bubbleTime, ChatComposer, mergeRows } from './chat-view'

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

/**
 * The one rule in the composer that is wrong silently.
 *
 * A single write of `text + '\r'` looks correct, typechecks, and does nothing at
 * all for any message past about half a line: the CLI reads a chunk of 64 bytes
 * or more as *pasted text*, where a carriage return is a newline rather than
 * submit. The words appear in the agent's input box and sit there. So what is
 * pinned here is that the return leaves as its **own** write, after the gap, and
 * that a message carrying an `@` keeps the trailing space that closes the
 * completion popup — without which the Enter is eaten by the popup instead.
 *
 * Exercised through a stub DOM rather than a real one, because this client has
 * no DOM in the suite. It is the smallest surface that runs the class: the
 * builder touches `createElement`, and `send()` is what is being measured.
 */
describe('the composer’s writes', () => {
  interface Stub {
    written: string[]
    waits: number[]
    field: { value: string }
    press: () => Promise<void>
  }

  function composer(live = true): Stub {
    const written: string[] = []
    const waits: number[] = []
    // A textarea and a button are the only two elements built, and both are only
    // ever read for `value`, `disabled` and their listeners.
    const made: Record<string, unknown>[] = []
    const document = {
      createElement(): Record<string, unknown> {
        const node: Record<string, unknown> = {
          value: '',
          rows: 0,
          disabled: false,
          className: '',
          type: '',
          title: '',
          style: {},
          scrollHeight: 20,
          listeners: {} as Record<string, (event: unknown) => void>,
          setAttribute() {},
          append() {},
          focus() {},
        }
        node.addEventListener = (name: string, handler: (event: unknown) => void) => {
          ;(node.listeners as Record<string, (event: unknown) => void>)[name] = handler
        }
        made.push(node)
        return node
      },
      createElementNS(): Record<string, unknown> {
        return { setAttribute() {}, append() {} }
      },
    }
    const held = globalThis.document
    ;(globalThis as { document?: unknown }).document = document
    const built = new ChatComposer({
      write: (data) => written.push(data),
      live: () => live,
      wait: async (ms) => {
        waits.push(ms)
      },
    })
    void built
    ;(globalThis as { document?: unknown }).document = held
    // element, field, button — in construction order.
    const field = made[1] as unknown as { value: string }
    const button = made[2] as unknown as {
      listeners: Record<string, () => Promise<void> | void>
    }
    return {
      written,
      waits,
      field,
      press: async () => {
        await button.listeners.click?.()
        // The click handler is `void this.send()`, so the promise it starts is
        // not the one awaited above. One turn of the microtask queue is what the
        // two `await`s inside `send` need.
        await Promise.resolve()
        await Promise.resolve()
      },
    }
  }

  it('sends the line and the return as two writes, a gap apart', async () => {
    const stub = composer()
    stub.field.value = 'run the tests'
    await stub.press()
    expect(stub.written).toEqual(['run the tests', '\r'])
    expect(stub.waits).toEqual([SUBMIT_GAP_MS])
  })

  it('keeps the space that closes the completion popup', async () => {
    const stub = composer()
    stub.field.value = 'look at @"src/main.ts"'
    await stub.press()
    expect(stub.written[0]).toBe('look at @"src/main.ts" ')
  })

  it('sends nothing at all over a dead socket', async () => {
    const stub = composer(false)
    stub.field.value = 'anybody there'
    await stub.press()
    expect(stub.written).toEqual([])
  })

  it('trims, and refuses a message that is only whitespace', async () => {
    const stub = composer()
    stub.field.value = '   \n  '
    await stub.press()
    expect(stub.written).toEqual([])
    stub.field.value = '  hello  '
    await stub.press()
    expect(stub.written).toEqual(['hello', '\r'])
  })
})
