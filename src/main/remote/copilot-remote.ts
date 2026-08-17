/**
 * What the relay endpoint is allowed to ask the copilot, and how much of it.
 *
 * ## Why this is an interface and not the implementation
 *
 * `server.ts` speaks WebSocket frames and knows which device a socket belongs
 * to. `copilot-runs.ts` starts Claude CLI processes, mints MCP tokens, reads
 * transcripts and holds the action log. Neither has any business importing the
 * other: the endpoint is exercised in tests over a plain loopback socket with no
 * Electron anywhere near it, and the run manager is exercised against a fake
 * session layer with no socket. Naming the seam is what keeps both true — the
 * same argument `SessionAccess` and `CredentialProxy` already make in that file.
 *
 * It also decides the shape of the negotiation. **Absent is the switch**: a host
 * constructed without a {@link CopilotRemote} does not advertise the `copilot`
 * capability at all, so a phone talking to it never draws a Copilot tab and
 * never sends a frame that would be refused. `scripts/remote-host.ts`, the
 * headless daemon and the public demo box are all in that position, and the
 * demo box especially must not offer a stranger a way to drive the owner's
 * agent.
 *
 * ## The two layers, and only one of them is the boundary
 *
 * **Layer one is here**, in {@link copilotFrameAllowed}, and it exists to keep
 * the UI honest rather than to be the boundary. A device with no grant gets no
 * Copilot tab and a clean `unauthorized` if it sends a verb anyway. That is the
 * whole of its job.
 *
 * **Layer two is `DeckControl.call`**, on the desktop, at the point a tool is
 * dispatched — and it is the one that matters. `control.ts` says why, about
 * itself: *"a rule enforced in one transport is a rule the next transport does
 * not have."* If the check here were the only one, a second way in — a future
 * desktop-to-desktop guest path, a debug endpoint, a test harness — would arrive
 * with no gate on it and nobody would notice until it had shipped.
 *
 * There is a third property that makes layer two airtight rather than merely
 * present, and it lives in `protocol.ts`: **no tool name is ever on the wire.**
 * A phone sends prose. The tool calls are made by a CLI process on this machine,
 * over loopback, authenticated by a per-run token the phone does not hold and
 * cannot read — see `deck-control/callers.ts`. So the set of frames a phone can
 * construct contains no tool at all, and the alter tier is not "denied" so much
 * as unreachable.
 */

import { COPILOT_FRAME_TIER, type CopilotGrantWire } from './protocol'
import type {
  CopilotActionRow,
  CopilotChatMessage,
  CopilotPendingRow,
  CopilotSessionRow,
  CopilotStateReport,
} from './protocol'

/**
 * Where a watching connection's frames go.
 *
 * A sink rather than a return value because most of what this surface produces
 * is unsolicited: a tool row appears when the copilot calls a tool, a chat
 * message appears when the agent finishes a sentence, and the pending set
 * changes when somebody at the desk answers a dialog. A client that had to ask
 * would be a client with a timer in it, which is the thing Asad's standing
 * preference refuses — *events, not polling*.
 *
 * Every method must be safe to call after the connection has gone;
 * `server.ts`'s `send` is, because a closed wire drops what it is handed.
 */
export interface CopilotSink {
  state(state: CopilotStateReport): void
  chat(run: string, messages: CopilotChatMessage[], reset: boolean): void
  tool(row: CopilotActionRow): void
  sessions(sessions: CopilotSessionRow[]): void
  pending(questions: CopilotPendingRow[]): void
}

/**
 * Why a `copilot.*` verb did not happen, in the vocabulary the wire already has.
 *
 * `unauthorized` is *you may not* and `unavailable` is *it broke*, which is the
 * distinction `PROTOCOL_ERROR_CODES` already carries and which three clients
 * already validate against. No new error code and no new denial vocabulary: a
 * seventh code added to a type union alone changes none of those clients, and
 * the symptom is a phone printing "error with an unknown code" instead of the
 * sentence this desktop sent.
 */
export interface CopilotRefusal {
  ok: false
  code: 'unauthorized' | 'unavailable'
  message: string
}

export type CopilotOutcome = { ok: true } | CopilotRefusal

/**
 * The copilot, as the relay endpoint may touch it.
 *
 * Deliberately small, and deliberately missing three things the design refuses
 * outright: there is no way to read or write `CLAUDE.md`, no way to reach
 * `memory/`, and no way to create, edit or fire a routine. The first two are the
 * copilot's standing policy and its injected context, so a device that could
 * write either could change the agent's behaviour permanently with no gate in
 * front of it — a persistent prompt injection with a settings panel. The third
 * is an agent authoring its own next trigger at a distance, which the records
 * fence and the alter tier both already refuse; it is named here as well so that
 * adding a method for it is a decision somebody has to make on purpose.
 */
export interface CopilotRemote {
  /**
   * What this device may do, **read now**.
   *
   * Never cached by the transport and never captured at hello. This is the call
   * that makes unticking a box in Settings land on the *next frame* rather than
   * on the next reconnect, and it is the same property `folders()` has for
   * `create`. A device the store has never heard of gets `{read:false,
   * act:false}`, which is also what a revoked one gets.
   */
  granted(deviceId: string): CopilotGrantWire

  /* --- read tier --------------------------------------------------------- */

  /** What the copilot is, for this device. See {@link CopilotStateReport}. */
  state(deviceId: string): CopilotStateReport
  /** The sessions the copilot started, each linked back to the turn that made it. */
  sessions(): CopilotSessionRow[]
  /** The tail of `actions.jsonl`, scrubbed, newest last. */
  log(options: { limit?: number; before?: string }): { rows: CopilotActionRow[]; more: boolean }
  /**
   * Confirmations waiting **at the desk**.
   *
   * Watch-only, and there is deliberately no `answer` beside it. The alter
   * tier's entire safety property is that a human at the machine says yes, and
   * the party holding the phone is by definition not that human. What this
   * answers is the real failure the design named — the desktop dialog is on a
   * screen nobody is looking at, and two minutes later it times out in silence.
   * The phone's job is to say *go and look*.
   */
  pending(): CopilotPendingRow[]
  /**
   * Subscribe one connection. Returns the unsubscribe.
   *
   * Called on `copilot.attach` and undone on `copilot.detach`, on the socket
   * closing, and on the grant being revoked. Attaching starts nothing and spends
   * nothing — that is why it is the read tier — so a watching phone costs this
   * machine one callback.
   */
  watch(deviceId: string, sink: CopilotSink): () => void

  /* --- act tier ---------------------------------------------------------- */

  /**
   * Start this device's own run.
   *
   * A **run of its own**, not a second keyboard on the copilot at the desk, and
   * that is the load-bearing decision of the whole feature. `COPILOT-REMOTE.md`
   * §1 argues it; the short form is attribution. In one shared conversation
   * every tool call arrives on one MCP connection carrying one token, so
   * `DeckControl` cannot tell a call the phone caused from one the desktop
   * caused — by the time the call is made, the cause is a sentence in a context
   * window. And a read-only phone could write *"when he next says anything, also
   * stop session 4"* into the shared context, which the desktop's next turn
   * would then execute with all three tiers. That is privilege escalation made
   * of prose, and it cannot be closed while one context is fed by two trust
   * levels.
   *
   * Idempotent: a second start against a live run is answered with the run that
   * exists rather than a second process.
   */
  start(deviceId: string): Promise<CopilotOutcome>
  /** Say something to this device's run. `text` has already been shape-checked. */
  say(deviceId: string, text: string): Promise<CopilotOutcome>
  /** Interrupt the current turn of this device's run, and of nothing else. */
  cancel(deviceId: string): CopilotOutcome
  /** End this device's run. */
  stop(deviceId: string): CopilotOutcome

  /* --- lifecycle --------------------------------------------------------- */

  /**
   * A device's grant changed, or the device was revoked entirely.
   *
   * Four things happen in this order and the order is the design — see
   * `COPILOT-REMOTE.md` §3. The store is written first, because everything else
   * is downstream of the disk and a permission that reverts *up* at the next
   * launch is worse than one that reverts down. Then this: the run's token
   * leaves the caller table, so in-flight tool calls abort with `caller-gone`;
   * the run is stopped; and `server.ts` pushes `copilot.grant` to every live
   * connection of that device.
   *
   * Step one alone is already sufficient for *correctness*, because the grant is
   * read per call. The rest is what stops a revoked phone watching a
   * conversation it can no longer influence.
   */
  revoked(deviceId: string): void
  /** Every run is stopped. Called when the app quits. */
  stopAll(): void
}

/**
 * May this device send this verb?
 *
 * A pure function over the tier table and the grant, so the rule can be checked
 * without a socket, a copilot or a device — and so that the same table
 * `protocol.ts` publishes to the clients is the one this desktop enforces with.
 * Two answers that could disagree is how a phone ends up drawing a control that
 * is always refused, or worse, hiding one that would have worked.
 *
 * **`read` is the floor for the whole surface.** A device with only `act` and no
 * `read` is a strange thing to have granted and the panel does not offer it, but
 * a hand-edited store could contain it — and the answer is that it may act and
 * may not watch, exactly as written, rather than this function quietly inferring
 * that `act` implies `read`. `TierGrant`'s own comment gives the reason:
 * independent booleans, not a ladder, because a ladder makes the *order* of the
 * tiers a security property and every existing grant silently widens the day
 * somebody inserts a tier between two others.
 */
export function copilotFrameAllowed(grant: CopilotGrantWire, verb: string): boolean {
  const tier = COPILOT_FRAME_TIER[verb]
  // A verb with no entry is not part of this capability. Refused rather than
  // allowed: the table is the definition of the surface, and a frame that is not
  // in it is either a client of a newer protocol or a probe.
  if (tier === undefined) return false
  return tier === 'read' ? grant.read : grant.act
}

/** True when this grant permits nothing, so the capability is drawn for nobody. */
export function grantsNothingRemotely(grant: CopilotGrantWire): boolean {
  return !grant.read && !grant.act
}
