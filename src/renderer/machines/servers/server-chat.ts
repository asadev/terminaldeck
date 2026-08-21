import { useEffect, useState } from 'react'
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
 * The coding logins under a terminal on a server.
 *
 * ## Why this is a sentence and not an account chip
 *
 * Every other session in this app can name the account it is running under
 * because this app started it. Nothing on the SSH side carries that: a
 * transcript line records `cwd`, `gitBranch`, `version` and its own `sessionId`
 * and says nothing whatever about a login, and this app did not spawn whatever
 * is in that terminal. There is no switch to offer either — changing which
 * account a server's agent uses is a sign-in over there.
 *
 * So an account *chip* on a server terminal's bar would be a menu with nothing
 * to act on, which is the one thing this bar is not allowed to grow. What is
 * true is a fact about the **account that shell signed in as**, and the bar
 * states it as that.
 *
 * ## Why it is a list, and why there is always a sentence
 *
 * It answered one agent until 2026-08-21 — whichever the far end happened to
 * list first with an address on it — so a server with a Claude login and a Codex
 * login named one of them over a terminal the person runs the other in. And it
 * answered *nothing at all* in four different situations: a server nobody had
 * opened, a server that would not answer, a server with no agent on it, and a
 * server whose agents are all signed out. All four drew an empty slot, which is
 * the one thing that is never the case. Now every login is named, and each of
 * those four has its own sentence — see {@link signInLine}.
 *
 * ## And it is free
 *
 * The main process reads it out of the probe the server page already runs, so
 * this is one round trip per server per launch at worst and none at all for a
 * server anybody has opened. Asked once per shell on mount, and again only when
 * a setup on any server finishes — which is the moment, and the only moment,
 * that this app itself can have changed the answer. A sign-in somebody does on
 * that machine by hand is not an event this side can see, so there is no timer
 * here pretending otherwise.
 */
export interface ServerLogin {
  /** `claude`, `codex` or `gemini` — whichever of them reported a login. */
  agentId: string
  /** The address its own configuration named, or null where it has none. */
  account: string | null
}

export type ServerSignIn =
  | { known: 'yes'; agents: number; logins: ServerLogin[] }
  | { known: 'cannot'; why: string }

export function useServerSignIn(
  bridge: ServersBridge | null,
  shellId: string | null,
): ServerSignIn | null {
  const [signIn, setSignIn] = useState<ServerSignIn | null>(null)
  /*
   * Bumped by a finished setup, which re-runs the effect below.
   *
   * The push is the event — his standing rule paid in the one place on this bar
   * where the answer genuinely changes while nobody is looking at it. Without
   * it, signing an agent in from the settings pane left the bar over an open
   * terminal on that same server saying *not signed in* until the app was
   * relaunched, about a login the person had finished thirty seconds earlier.
   */
  const [again, setAgain] = useState(0)
  useEffect(() => {
    const listen = bridge?.onServerSetup
    if (typeof listen !== 'function') return
    return listen((raw) => {
      if (setupChangedTheAnswer(raw)) setAgain((count) => count + 1)
    })
  }, [bridge])

  useEffect(() => {
    const ask = bridge?.serverShellAccount
    if (typeof ask !== 'function' || shellId === null || shellId === '') {
      setSignIn(null)
      return
    }
    let alive = true
    void ask(shellId)
      .then((answer) => {
        if (!alive) return
        setSignIn(asServerSignIn(answer))
      })
      .catch(() => {
        if (!alive) return
        // A refusal that never reached the far end. The bar says it could not
        // ask rather than falling silent, which is the state this whole shape
        // exists to stop being drawn as blank.
        setSignIn({ known: 'cannot', why: 'This app could not ask that server.' })
      })
    return () => {
      alive = false
    }
  }, [bridge, shellId, again])
  return signIn
}

/**
 * Does this setup push mean the sign-ins on that server have changed?
 *
 * Only the two steps that change what is on the machine: `done` is a sign-in
 * that finished and `idle` is an install that was taken back off. Every other
 * push is progress — a line of an installer's output, a code appearing — and
 * re-asking on each of those would be one SSH round trip per line.
 *
 * Not narrowed to the server this shell is on, deliberately: the push carries a
 * server id and this hook holds a shell id, and turning one into the other means
 * a round trip of its own. Setting up an agent is a rare, deliberate thing, so
 * the cost of the wider net is one extra ask on a bar that is already on screen,
 * against the alternative — which was the bar going on saying *not signed in*
 * about a login somebody had just finished, until the app was relaunched.
 */
export function setupChangedTheAnswer(raw: unknown): boolean {
  if (!isRecord(raw)) return false
  return raw.step === 'done' || raw.step === 'idle'
}

/** The answer off the bridge, or null when this build cannot read it. */
export function asServerSignIn(answer: unknown): ServerSignIn | null {
  if (!isRecord(answer)) return null
  if (answer.known === 'cannot') {
    const why = text(answer.why)
    return { known: 'cannot', why: why === '' ? 'This server did not say.' : why }
  }
  if (answer.known !== 'yes') return null
  const agents = typeof answer.agents === 'number' && answer.agents >= 0 ? answer.agents : 0
  const rows = Array.isArray(answer.logins) ? answer.logins : []
  const logins: ServerLogin[] = []
  for (const row of rows) {
    if (!isRecord(row)) continue
    const agentId = text(row.agentId)
    if (agentId === '') continue
    const account = text(row.account)
    logins.push({ agentId, account: account === '' ? null : account })
  }
  return { known: 'yes', agents: Math.max(agents, logins.length), logins }
}

/** What the bar draws, and what hovering it says. */
export interface SignInWords {
  line: string
  title: string
}

/**
 * The four sentences, and which one this answer is.
 *
 * Written here rather than in `App.tsx` because it is the whole of the decision
 * and a decision worth four sentences is worth a test. The rule they follow is
 * one Asad has now made twice about this slot: it never says nothing, and it
 * never says a word that is not an account where an account is meant — *"It is
 * saying default, so never default. Whatever is actual account should be
 * visible here, never default."*
 *
 * The tooltip carries the part that will not fit and the part that is a caveat.
 * Every one of them says, in one form or another, the thing that makes this
 * different from every other account on this bar: this app did not start what is
 * running in that terminal, so this is the login the *account* holds rather than
 * the login of the session.
 */
export function signInLine(signIn: ServerSignIn, where: string): SignInWords {
  const place = where === '' ? 'this server' : where
  if (signIn.known === 'cannot') {
    return {
      line: 'Coding logins unknown',
      title: `${signIn.why} So this app cannot say which login a coding agent started in this terminal would run as.`,
    }
  }
  if (signIn.logins.length === 0) {
    if (signIn.agents === 0) {
      return {
        line: 'No coding agent here',
        title:
          `The account you signed in to ${place} as has no coding agent installed. ` +
          'Settings → Coding AI → Servers can put one there and sign it in.',
      }
    }
    return {
      line: 'No coding login here',
      title:
        `A coding agent is installed on ${place} under the account you signed in as, and none of them ` +
        'has a login. Settings → Coding AI → Servers signs one in.',
    }
  }
  const named = signIn.logins.map(
    (login) =>
      `${agentLabel(login.agentId)}${login.account === null ? ' is signed in' : ` signs in as ${login.account}`}`,
  )
  return {
    line: named.join(' · '),
    title:
      `${named.join('. ')}. That is the login the account you signed in to ${place} as holds. ` +
      'This app did not start what is running in this terminal, so it is a fact about that account rather ' +
      'than about this session.',
  }
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
