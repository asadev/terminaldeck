import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { agentLabel, asChatUpdate, serverChatBridge, serverChatWired } from './server-chat'
import type { ServersBridge } from './types'

/**
 * The adapter that lets one chat view read a conversation off a server.
 *
 * Three things are worth an exercised test here and the rest is prose:
 *
 *  1. **It is keyed on the shell.** Every call has to carry the id the main
 *     process holds the reader under, and `closeChat` in particular is handed a
 *     *path on the server* by `ChatView` and must ignore it — letting the path
 *     decide would close a reader belonging to a different terminal on the same
 *     box.
 *  2. **A build without the channel says so before a control is drawn.** The
 *     mode switch asks `serverChatWired`, and the answer is what stands between
 *     an honest refusal and a Chat segment that opens an empty pane.
 *  3. **What arrives is narrowed, not cast.** It crosses a preload boundary as
 *     `unknown`, and a malformed answer has to become "nothing came back" rather
 *     than a bubble with `undefined` in it.
 */

function bridgeWith(overrides: Partial<ServersBridge>): ServersBridge {
  return overrides as ServersBridge
}

describe('whether this build can read one at all', () => {
  it('is false when any of the three channels is missing', () => {
    expect(serverChatWired(null)).toBe(false)
    expect(serverChatWired(bridgeWith({}))).toBe(false)
    expect(
      serverChatWired(
        bridgeWith({ loadServerChat: async () => null, tailServerChat: async () => null }),
      ),
    ).toBe(false)
  })

  it('is true only with all three', () => {
    expect(
      serverChatWired(
        bridgeWith({
          loadServerChat: async () => null,
          tailServerChat: async () => null,
          closeServerChat: async () => null,
        }),
      ),
    ).toBe(true)
  })
})

describe('the bridge one chat pane is given', () => {
  it('names the shell on every call, and ignores the path handed to close', () => {
    const load = vi.fn(async () => null)
    const tail = vi.fn(async () => null)
    const close = vi.fn(async () => null)
    const chat = serverChatBridge(
      bridgeWith({ loadServerChat: load, tailServerChat: tail, closeServerChat: close }),
      'srv-1 abc',
    )

    void chat.loadChat({})
    void chat.tailChat({})
    // What `ChatView` hands back is the `transcriptPath` of the last update —
    // a path on the *server*. The reader is held under the shell's id.
    chat.closeChat('/home/me/.claude/projects/p/x.jsonl')

    expect(load).toHaveBeenCalledWith('srv-1 abc')
    expect(tail).toHaveBeenCalledWith('srv-1 abc')
    expect(close).toHaveBeenCalledWith('srv-1 abc')
  })

  it('answers nothing-found rather than throwing when the channel is absent', async () => {
    // Reachable in a build whose preload is older than these channels: the mode
    // switch should have refused first, and a pane that got here anyway must
    // draw an empty state instead of taking the window down through the error
    // boundary.
    const chat = serverChatBridge(bridgeWith({}), 'srv-1 abc')
    expect((await chat.loadChat({})).found).toBe(false)
    expect((await chat.tailChat({})).messages).toEqual([])
  })
})

describe('what crosses the boundary is narrowed', () => {
  it('is null when there is no list of messages on it', () => {
    expect(asChatUpdate(null)).toBeNull()
    expect(asChatUpdate({ found: true })).toBeNull()
    expect(asChatUpdate('nope')).toBeNull()
  })

  it('drops a message with no text rather than drawing an empty turn', () => {
    // An empty bubble in a conversation reads as something that failed to load.
    const update = asChatUpdate({
      messages: [
        { id: 'a', role: 'agent', text: '' },
        { id: 'b', role: 'you', text: 'hello', at: 5 },
        { id: '', role: 'you', text: 'no id' },
        { id: 'c', role: 'nobody', text: 'wrong role' },
      ],
      found: true,
      transcriptPath: '/p/x.jsonl',
    })
    expect(update?.messages).toEqual([{ id: 'b', role: 'you', text: 'hello', at: 5 }])
  })

  it('carries the two facts only a far reading has', () => {
    const update = asChatUpdate({
      messages: [],
      found: true,
      startedMidFile: true,
      unattributable: { candidates: 2, competing: 1 },
    })
    expect(update?.startedMidFile).toBe(true)
    expect(update?.unattributable).toEqual({ candidates: 2, competing: 1 })
  })

  it('leaves them off when the far end said nothing about them', () => {
    // A bridge that never sets them has to behave exactly as this pane always
    // has, or every local conversation grows a caption it did not earn.
    const update = asChatUpdate({ messages: [], found: true })
    expect(update?.startedMidFile).toBe(false)
    expect(update?.unattributable).toBeUndefined()
  })
})

describe('the agent named on the sign-in line', () => {
  it('uses the catalogue’s own name', () => {
    expect(agentLabel('claude')).toBe('Claude Code')
  })

  it('prints an id it has never heard of rather than nothing', () => {
    // The probe on the far end can be newer than this build, and a name is a
    // better thing to show somebody than a blank.
    expect(agentLabel('something-new')).toBe('something-new')
  })
})

/* ------------------------------------------------------- what the pane asks for -- */

const PANE = readFileSync(join(__dirname, 'ServerChatPane.tsx'), 'utf8')
const VIEW = readFileSync(join(__dirname, '..', '..', 'components', 'ChatView.tsx'), 'utf8')

/**
 * Source assertions, because the claims are about *props* and this project has
 * no DOM in its tests: `renderToStaticMarkup` never runs an effect, so the two
 * states these props exist to produce — a conversation entered late, and one
 * that could not be attributed — cannot be reached by rendering.
 */
describe('the pane the window mounts over a server terminal', () => {
  it('asks the bridge for a session rather than for a file on somebody else’s disk', () => {
    expect(PANE).toContain('conversationKey={shellId}')
    // And `ChatView` has to route that through as its own request, or the pane
    // silently falls back to attributing a folder on *this* machine.
    expect(VIEW).toContain('? { key: conversationKey }')
    expect(VIEW).toContain("const scoped = session != null && !transcriptPath && !conversationKey")
  })

  it('withdraws the attach menu, because a path here is a path on the wrong computer', () => {
    // `session-transfer.ts`'s rule, and the report behind it: *"it will send the
    // path of my current PC instead of the server where actually session is
    // running."* There is no form of the result that fixes it.
    expect(PANE).toContain('noAttachReason=')
  })

  it('stops asking the server anything while it is not being looked at, or while it is live', () => {
    /*
     * A local conversation rides an `fs.watch`; a server rides a `tail -f`
     * running over there, forwarded on `servers:chat:changed`. Two things
     * switch the timer off and both are load-bearing:
     *
     *  - `visible`, so a pane mounted on a background tab keeps what it has read
     *    and asks nothing — a timer per far machine is what the servers design
     *    bans.
     *  - `feed !== 'live'`, which is the whole of *"events, not polling"*. It
     *    stays a timer while nothing has been attributed yet and on a server
     *    whose `tail` will not follow, which are the two cases where the only
     *    honest alternative is a stale pane.
     */
    expect(PANE).toContain("refreshMs={visible && feed !== 'live' ? 3000 : 0}")
    expect(PANE).toContain('subscribe={subscribe}')
  })

  it('says which feed it is on rather than looking the same either way', () => {
    // "As it is written" and "up to three seconds stale" are indistinguishable
    // on screen right until somebody is waiting on a reply and wondering whether
    // the machine has stopped.
    expect(PANE).toContain("data-feed={feed ?? 'unknown'}")
    expect(PANE).toContain('className="server-chat-feed"')
    expect(PANE).toContain('Live — this server sends each reply as it is written.')
    // And nothing is claimed before there is an answer: `null` draws no line at
    // all, rather than a caption that corrects itself half a second later.
    expect(PANE).toContain('{feed === null ? null : (')
  })

  it('tells the far end to stop streaming while nobody is looking', () => {
    // The pane is mounted while it is hidden — unmounting drops the reader and
    // coming back would be the whole tail window across the link again — and its
    // promise has always been that a hidden one asks nothing. That now has to be
    // said out loud, because the far end can talk first.
    expect(PANE).toContain('void bridge.watchServerChat?.(shellId, visible)')
    expect(PANE).toContain('}, [bridge, shellId, visible])')
  })

  it('rides the push through the same reader the timer used', () => {
    // The payload is *that* the conversation moved, never the conversation. One
    // reader, one dedupe set, one place a `/clear` is noticed — a push that
    // carried its own bubbles would be a second way for a conversation to reach
    // a pane, and the two would drift.
    expect(VIEW).toContain('const stop = subscribe(tail)')
  })

  it('says “I cannot tell” ahead of “there is nothing”', () => {
    /*
     * Order matters and is easy to get wrong by tidying. `found` is false in
     * both cases, so an `unattributable` check placed after it would never be
     * reached — and the pane would tell somebody staring at a busy terminal
     * that their session has said nothing.
     */
    const ladder = /const state: ChatEmptyState \| null =[\s\S]*?\n {4}: null\n/.exec(VIEW)?.[0] ?? ''
    expect(ladder, 'the empty-state ladder has changed shape').not.toBe('')
    expect(ladder.indexOf('unattributable !== null')).toBeGreaterThan(-1)
    expect(ladder.indexOf('unattributable !== null')).toBeLessThan(ladder.indexOf("found === false"))
  })

  it('captions a conversation it entered late rather than showing a fragment as the whole', () => {
    expect(VIEW).toContain('className="cv-partial"')
    expect(VIEW).toContain('setPartial(update.startedMidFile === true)')
  })
})
