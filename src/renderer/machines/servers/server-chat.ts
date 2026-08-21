import { useCallback, useEffect, useState } from 'react'
import { AGENT_CATALOG } from '../../../shared/agent-catalog'
import { isProviderId } from '../../preferences'
import type { ChatBridge, ChatMessage, ChatUpdate } from '../../components/ChatView'
import type { ServersBridge } from './types'

/**
 * A terminal on a server, read as a conversation.
 *
 * ## Why this is an adapter and not a second chat view
 *
 * Because there is one conversation renderer in this app and there is going to
 * go on being one. `ChatView` already knows how to merge an appended message
 * into a bubble, how to stay pinned to the bottom only while somebody is at the
 * bottom, what to say when a session has not spoken yet, and what a `/clear`
 * looks like from the outside. All of that is about *bubbles*, and a bubble is
 * a bubble whichever computer wrote it — so what a server needs is not another
 * view, it is another way of getting the bubbles.
 *
 * `ChatView` already takes one: `bridge`, three methods, injectable since it was
 * written. {@link serverChatBridge} is the third implementation of it after this
 * machine's preload and the copilot's, and it is the whole of what makes a
 * server terminal's chat pane work.
 *
 * ## What it is keyed on, and why not a path
 *
 * A shell, by the id the far end minted for it. Which file on that server is
 * *this* terminal's conversation depends on when the shell was opened, measured
 * against each transcript's own first line, and only the main process holds
 * either half of that — see `src/main/servers/chat.ts`. So this side hands over
 * a handle and is told what was resolved; it never names a file on somebody
 * else's disk, which is also the reason there is no path here for a renderer
 * bug to point somewhere it should not.
 */

/* --------------------------------------------------------------- narrowing -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/**
 * One bubble off the wire, or null.
 *
 * Narrowed rather than cast for the reason every other mirror in this folder is:
 * what arrives is `unknown`, and a cast is a promise about a process this one
 * cannot see. A message with no text is dropped rather than rendered as an empty
 * turn — an empty bubble in a conversation reads as something that failed to
 * load.
 */
function asMessage(value: unknown): ChatMessage | null {
  if (!isRecord(value)) return null
  const id = text(value.id)
  const role = value.role === 'you' ? 'you' : value.role === 'agent' ? 'agent' : null
  const body = text(value.text)
  if (id === '' || role === null || body === '') return null
  return { id, role, text: body, at: typeof value.at === 'number' ? value.at : 0 }
}

/**
 * A whole update off the wire, or null when nothing usable arrived.
 *
 * Null and not an empty update: `ChatView` tells the two apart. An update it
 * cannot read leaves the pane saying it found nothing, which is right for a
 * build whose preload has no such channel — and an update that *did* arrive and
 * says the conversation is empty is a different sentence.
 */
export function asChatUpdate(value: unknown): ChatUpdate | null {
  if (!isRecord(value) || !Array.isArray(value.messages)) return null
  const unattributable = isRecord(value.unattributable) ? value.unattributable : null
  return {
    transcriptPath: text(value.transcriptPath),
    sessionId: text(value.sessionId),
    cwd: text(value.cwd),
    messages: value.messages.map(asMessage).filter((one): one is ChatMessage => one !== null),
    reset: value.reset === true,
    cursor: typeof value.cursor === 'number' ? value.cursor : 0,
    found: value.found === true,
    complete: value.complete !== false,
    updatedAt: typeof value.updatedAt === 'number' ? value.updatedAt : Date.now(),
    startedMidFile: value.startedMidFile === true,
    ...(unattributable === null
      ? {}
      : {
          unattributable: {
            candidates: typeof unattributable.candidates === 'number' ? unattributable.candidates : 0,
            competing: typeof unattributable.competing === 'number' ? unattributable.competing : 0,
          },
        }),
  }
}

/* ----------------------------------------------------------------- the bridge -- */

/**
 * Whether this build can read a conversation off a server at all.
 *
 * Asked before the mode switch offers Chat for a server terminal, so that a
 * preload older than these channels keeps the refusal it always had instead of
 * offering a segment that opens an empty pane. A control that cannot act must
 * not be drawn.
 */
export function serverChatWired(bridge: ServersBridge | null): boolean {
  return (
    typeof bridge?.loadServerChat === 'function' &&
    typeof bridge.tailServerChat === 'function' &&
    typeof bridge.closeServerChat === 'function'
  )
}

/**
 * The three methods `ChatView` asks for, pointed at one shell on one server.
 *
 * `closeChat` ignores the path it is handed. `ChatView` passes back whatever
 * `transcriptPath` the last update carried — a path on the *server* — and the
 * thing being closed here is the reader, which the main process holds under the
 * shell's id. Letting the path decide would mean this window could close a
 * reader belonging to a different terminal on the same box.
 *
 * A rejected call becomes null rather than propagating: `ChatView` reads null as
 * "nothing came back" and draws its own empty state, which is the honest
 * rendering of a server that stopped answering. The terminal beside this pane is
 * saying the same thing far more loudly.
 */
export function serverChatBridge(bridge: ServersBridge, shellId: string): ChatBridge {
  return {
    async loadChat() {
      const load = bridge.loadServerChat
      if (typeof load !== 'function') return emptyUpdate()
      return asChatUpdate(await load(shellId)) ?? emptyUpdate()
    },
    async tailChat() {
      const tail = bridge.tailServerChat
      if (typeof tail !== 'function') return emptyUpdate()
      return asChatUpdate(await tail(shellId)) ?? emptyUpdate()
    },
    closeChat() {
      void bridge.closeServerChat?.(shellId)
    },
  }
}

/* --------------------------------------------------------------- the push -- */

/**
 * How a server's conversation is being kept current. Mirrors `ChatFeed` in
 * `main/servers/chat.ts`, narrowed off the wire rather than cast.
 */
export type ServerChatFeed = 'live' | 'polled'

/**
 * Ride the main process's push for one shell, and learn which feed it is on.
 *
 * ## Why a hook and not a prop on the pane
 *
 * Because two different things need the answer and they need it at different
 * moments. `ChatView` needs the *event* — read what was appended, now — and the
 * pane needs the *state*, both to say which feed is in use and to decide whether
 * the three-second timer still has a job. Splitting them would mean two
 * subscriptions to one channel.
 *
 * ## Why the feed starts as null and not as `polled`
 *
 * Because nothing has been claimed yet. The main process decides when it has
 * tried to put a `tail -f` on the far end, and that is a round trip away; a pane
 * that announced "on a timer" for the first half-second and then corrected
 * itself would be a flicker of a sentence nobody can read. Null draws no line at
 * all, which is the honest rendering of "not yet known".
 *
 * A build whose preload has no such channel never leaves null, and that is also
 * right: it *is* on a timer, and it says so through `refreshMs` continuing to
 * run rather than through a caption about a feature it does not have.
 */
export function useServerChatPush(
  bridge: ServersBridge,
  shellId: string,
): { feed: ServerChatFeed | null; subscribe: (onChange: () => void) => (() => void) | null } {
  const [feed, setFeed] = useState<ServerChatFeed | null>(null)
  // Reset when the pane is pointed at a different terminal: the last shell's
  // feed says nothing about this one's server.
  useEffect(() => setFeed(null), [bridge, shellId])
  const subscribe = useCallback(
    (onChange: () => void) => {
      const on = bridge.onServerChatChanged
      if (typeof on !== 'function') return null
      return on((payload) => {
        if (!isRecord(payload) || payload.shellId !== shellId) return
        if (payload.feed === 'live' || payload.feed === 'polled') setFeed(payload.feed)
        onChange()
      })
    },
    [bridge, shellId],
  )
  return { feed, subscribe }
}

/** What a build with no such channel answers: nothing found, nothing claimed. */
function emptyUpdate(): ChatUpdate {
  return {
    transcriptPath: '',
    sessionId: '',
    cwd: '',
    messages: [],
    reset: false,
    cursor: 0,
    found: false,
    complete: true,
    updatedAt: Date.now(),
  }
}

/* ------------------------------------------------------------- the sign-in -- */

/**
 * The sign-in a coding agent started in that shell would run as.
 *
 * ## Why this is a sentence and not an account chip
 *
 * Every other session in this app can name the account it is running under
 * because this app started it. Nothing on the SSH side carries that: a
 * transcript line records `cwd`, `gitBranch`, `version` and its own `sessionId`
 * and says nothing whatever about a login, and this app did not spawn whatever
 * is in that terminal. There is no switch to offer either — changing which
 * account a server's agent uses is `claude /login` over there, in a browser on
 * that machine.
 *
 * So an account *chip* on a server terminal's bar would be a menu with nothing
 * to act on, which is the one thing this bar is not allowed to grow. What is
 * true is a fact about the **home directory the shell landed in**, and the bar
 * states it as that.
 *
 * ## And it is free
 *
 * The main process reads it out of the probe the server page already runs, so
 * this is one round trip per server per launch at worst and none at all for a
 * server anybody has opened. Asked once per shell, on mount, and not re-asked:
 * a sign-in on somebody's server changes when they sign in again over there, not
 * while a bar is on screen, so a timer here would be a poll for an answer that
 * does not move.
 */
export interface ServerSignIn {
  /** `claude`, `codex` or `gemini` — whichever of them had a login to report. */
  agentId: string
  /** The address that agent's own `auth status` answered with. */
  account: string
}

export function useServerSignIn(
  bridge: ServersBridge | null,
  shellId: string | null,
): ServerSignIn | null {
  const [signIn, setSignIn] = useState<ServerSignIn | null>(null)
  useEffect(() => {
    const ask = bridge?.serverShellAccount
    if (typeof ask !== 'function' || shellId === null || shellId === '') {
      setSignIn(null)
      return
    }
    let alive = true
    setSignIn(null)
    void ask(shellId)
      .then((answer) => {
        if (!alive || !isRecord(answer)) return
        const account = text(answer.account)
        const agentId = text(answer.agentId)
        if (account === '' || agentId === '') return
        setSignIn({ agentId, account })
      })
      .catch(() => {
        // A server that will not answer has nothing to say about its sign-ins,
        // and the chip is then absent rather than empty — the same silent
        // degrade the connectors chip beside it makes.
      })
    return () => {
      alive = false
    }
  }, [bridge, shellId])
  return signIn
}

/**
 * An agent's own name, for the sign-in line on the bar.
 *
 * Through the catalogue rather than a second table, because the catalogue is
 * where every other surface in this app gets the same three names and a fourth
 * copy of them is a fourth place to be renamed. An id the catalogue does not
 * know is printed as it arrived: the probe on the far end could be newer than
 * this build, and `codex` is a better thing to show somebody than nothing.
 */
export function agentLabel(agentId: string): string {
  return isProviderId(agentId) ? AGENT_CATALOG[agentId].label : agentId
}
