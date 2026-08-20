/**
 * Reading what another machine says about its copilot — kept away from the
 * component so the rules can be tested without a DOM.
 *
 * Everything crosses the bridge as `unknown`, which is this repo's rule for a
 * feature type: duplicating the wire's interfaces in `shared/types.ts` is how
 * the two come to drift. So this file is the one place that decides what a frame
 * from another computer is allowed to mean here, and every field is checked
 * rather than trusted — the far end may be an older build, a newer one, or a
 * machine mid-reconnect sending a half-formed view.
 */

/** One bubble of a copilot conversation, as this window draws it. */
export interface RemoteBubble {
  id: string
  role: 'you' | 'agent'
  text: string
  at: number
}

/** A `copilot.chat` frame, narrowed. */
export interface RemoteChat {
  messages: RemoteBubble[]
  /** The far end is restating the conversation from the beginning. */
  reset: boolean
}

/**
 * What is running over there, as `CopilotStateReport` carries it.
 *
 * `desk` and `run` are two different processes and this keeps them apart, which
 * is the one thing this screen can get wrong that somebody would act on: `desk`
 * is the copilot pinned in the sidebar at that machine's own keyboard, and `run`
 * is **this** device's own run there — the only one it can talk to.
 */
export interface RemoteReport {
  desk: 'stopped' | 'starting' | 'running'
  run: string | null
  profile: string | null
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function bubble(value: unknown): RemoteBubble | null {
  const row = record(value)
  if (!row) return null
  if (typeof row.id !== 'string' || row.id === '') return null
  if (typeof row.text !== 'string') return null
  // Anything that is not the copilot's own voice is drawn as this side's, which
  // is the safe direction: an unrecognised role rendered as the agent would put
  // words in the copilot's mouth.
  const role = row.role === 'agent' ? 'agent' : 'you'
  return { id: row.id, role, text: row.text, at: typeof row.at === 'number' ? row.at : 0 }
}

export function readChatFrame(value: unknown): RemoteChat | null {
  const frame = record(value)
  if (!frame) return null
  const raw = frame.messages
  if (!Array.isArray(raw)) return null
  const messages: RemoteBubble[] = []
  for (const entry of raw) {
    const parsed = bubble(entry)
    if (parsed) messages.push(parsed)
  }
  return { messages, reset: frame.reset === true }
}

export function readStateReport(value: unknown): RemoteReport | null {
  const state = record(value)
  if (!state) return null
  const desk = state.desk
  if (desk !== 'stopped' && desk !== 'starting' && desk !== 'running') return null
  return {
    desk,
    // A run id or nothing. `undefined` and a non-string both mean "it has not
    // said", and the honest reading of that is the same as "no run" — which is
    // the state that draws a Start button rather than a composer that cannot
    // reach anything.
    run: typeof state.run === 'string' && state.run !== '' ? state.run : null,
    profile: typeof state.profile === 'string' && state.profile !== '' ? state.profile : null,
  }
}

/**
 * Fold one `copilot.chat` frame into what is already on screen.
 *
 * Three rules, and the second is the one that would otherwise produce visible
 * duplicates. A frame carrying `reset` replaces the conversation, because the
 * far end is restating it from the beginning — after a reconnect, or after a run
 * was replaced. Otherwise a message whose `id` is already here **replaces** that
 * message rather than being appended: `protocol.ts` says the id is *"stable
 * across reads, so an extended message replaces rather than duplicates"*, which
 * is how a bubble grows while the agent is still writing it. Everything else is
 * appended in the order it arrived.
 */
export function applyChat(
  current: readonly RemoteBubble[],
  chat: RemoteChat,
): RemoteBubble[] {
  if (chat.reset) return [...chat.messages]
  const next = [...current]
  for (const message of chat.messages) {
    const at = next.findIndex((existing) => existing.id === message.id)
    if (at === -1) next.push(message)
    else next[at] = message
  }
  return next
}
