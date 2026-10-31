import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { readFailure, withDeadline } from '../../deadline'
import {
  asGrant,
  asPreview,
  asRefusal,
  asServers,
  asView,
  missingServerMethods,
  resolveServersBridge,
  succeeded,
  type ActionPreview,
  type Server,
  type ServerState,
  type ServersBridge,
} from './types'

/**
 * The servers, read by the window.
 *
 * ## Nothing here runs on a timer, and that is the design
 *
 * The standing rule this obeys is Asad's: **events, not polling** — *"webhooks,
 * APIs, push over crons and timers; they make the system heavier."* So:
 *
 *  - the stored list is read **once** when the area opens, and again only after
 *    something a person did could have changed it;
 *  - **no server is connected to unless somebody is looking at its page**, and
 *    the connection ends when they leave it;
 *  - a **refresh is a press**, not a tick, and there is exactly one of those, in
 *    the corner of the page it refreshes;
 *  - an action that changed something re-measures, because a press happened —
 *    which is the opposite of a timer rather than an exception to the rule. A
 *    card that still says "running" after somebody stopped it is a lie the page
 *    told about work the page did.
 *
 * The consequence is worth stating plainly, because it will otherwise be
 * "fixed" by somebody who reads a stale number as a bug: **a server's page can
 * be showing facts from twenty minutes ago, and that is correct.** The age is on
 * screen next to them. Making it live would mean a timer per server, running
 * against machines nobody is looking at.
 *
 * ## Why the list costs nothing when it is closed
 *
 * A row is a stored name, an address and a username. Drawing it dials nothing. A
 * server nobody has opened during this launch shows no state at all rather than
 * a fabricated one — there is no "probably fine" on this screen, because
 * "probably" is exactly the word that turns a status page into a page that lies.
 */

/** What a screen gets from {@link useServers}. */
export interface ServersRead {
  /** False when this build's preload carries no server channels at all. */
  wired: boolean
  /** Which channels a half-wired build is missing, so a notice can name them. */
  missing: string[]
  servers: Server[]
  /** The bridge, for the pages and the terminal. Null when the build has none. */
  bridge: ServersBridge | null
  /** True until the first read has settled one way or the other. */
  reading: boolean
  /** Why the read failed, in a sentence. Null while it has not. */
  problem: string | null
  /** Ask for the list again. Harmless when nothing has changed. */
  reread(): void
}

/**
 * How long a read may take before the screen stops saying "reading" and starts
 * saying what went wrong.
 *
 * A loading line with nothing behind it stood on this app's Remote panel for the
 * length of a recording once, with nothing to press. Every terminal state on a
 * screen needs a way out of it, and a deadline is what turns a hang into one.
 */
export const READ_DEADLINE_MS = 8000

/**
 * How long a server has to answer before the page says it did not.
 *
 * Longer than a list read by a wide margin, because this one crosses the
 * internet to a machine that may be asleep, and the honest failure — *"that
 * address didn't answer"* — is one somebody should only see after actually
 * waiting.
 */
export const LOOK_DEADLINE_MS = 45_000

export function useServers(supplied?: ServersBridge): ServersRead {
  // Resolved once. An unstable bridge would restart every effect below on each
  // render, which on a subscription means dropping and re-adding a listener in
  // the frame an update arrives in.
  const bridge = useMemo(() => resolveServersBridge(supplied), [supplied])
  const missing = useMemo(() => (bridge === null ? missingServerMethods() : []), [bridge])

  const [servers, setServers] = useState<Server[]>([])
  const [reading, setReading] = useState(bridge !== null)
  const [problem, setProblem] = useState<string | null>(null)

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const reread = useCallback(() => {
    if (!bridge) return
    setReading(true)
    withDeadline(bridge.listServers(), 'reading your servers', READ_DEADLINE_MS).then(
      (raw) => {
        if (!alive.current) return
        setServers(asServers(raw))
        setProblem(null)
        setReading(false)
      },
      (error: unknown) => {
        if (!alive.current) return
        setProblem(readFailure(error))
        setReading(false)
      },
    )
  }, [bridge])

  useEffect(() => {
    if (!bridge) {
      setReading(false)
      return
    }
    reread()
  }, [bridge, reread])

  return { wired: bridge !== null, missing, servers, bridge, reading, problem, reread }
}

/**
 * Hold one server's connection open for exactly as long as its page is on
 * screen, and keep what it said.
 *
 * This is where "connect when the page opens, disconnect when it closes" is
 * actually implemented. The close is not best-effort politeness: without it,
 * somebody who visited four servers this morning is holding four connections to
 * machines they are no longer looking at — which is precisely the standing
 * background cost the events-not-polling rule exists to prevent, and, unlike a
 * timer, nothing on screen would show it.
 *
 * ## Why every action is previewed as the page opens
 *
 * Because the sentence describing what a button will do is written on the other
 * side of the bridge, and it has to be in hand *before* anybody presses
 * anything. Asking for it costs nothing — it is answered from the facts already
 * measured, with no round trip to the server — and the alternative is a
 * renderer that keeps its own copy of nine labels and nine sentences, which is
 * two tables that drift.
 */
export function useServerRoom(
  bridge: ServersBridge | null,
  serverId: string | null,
  /** Where the answer goes. Held above this hook so it survives leaving the page. */
  report: (state: ServerState) => void,
): { look(): void } {
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  // Held in a ref so that a caller passing an inline function does not restart
  // the connection on every render — which would hang up and redial the server
  // somebody is looking at, repeatedly.
  const latest = useRef(report)
  latest.current = report

  const look = useCallback(() => {
    if (!bridge || serverId === null) return
    const id = serverId
    latest.current({ id, link: 'connecting' })
    withDeadline(bridge.lookAtServer(id), 'reaching that server', LOOK_DEADLINE_MS).then(
      async (raw) => {
        if (!alive.current) return
        if (!succeeded(raw)) {
          const refusal = asRefusal(raw)
          latest.current({
            id,
            link: 'failed',
            problem: refusal.sentence,
            identityChanged: refusal.identityChanged,
            ...(refusal.identity === undefined ? {} : { identity: refusal.identity }),
          })
          return
        }
        const view = asView((raw as { view?: unknown }).view)
        if (view === null) {
          latest.current({ id, link: 'failed', problem: 'That server answered with nothing we could read.' })
          return
        }

        /*
         * One preview per offered action, all at once.
         *
         * `Promise.all` rather than a loop with awaits: these are answered from
         * facts already in hand, so they are cheap and independent, and running
         * them in sequence would make a page with six cards take six round trips
         * to draw its buttons.
         */
        const previews: Record<string, ActionPreview[]> = {}
        await Promise.all(
          view.cards.map(async (card) => {
            const wanted = view.offered[card.id] ?? []
            const answers = await Promise.all(
              wanted.map((actionId) =>
                bridge.previewServerAction(id, card.id, actionId).then(
                  (reply) =>
                    succeeded(reply) ? asPreview((reply as { preview?: unknown }).preview) : null,
                  // A preview that fails is one button that is not drawn, not a
                  // page that fails to draw. The others are unaffected.
                  () => null,
                ),
              ),
            )
            previews[card.id] = answers.filter((entry): entry is ActionPreview => entry !== null)
          }),
        )

        const grant = await bridge.serverGrantState(id).then(asGrant, () => null)
        if (!alive.current) return
        latest.current({ id, link: 'ready', view, previews, grant })
      },
      (error: unknown) => {
        if (!alive.current) return
        latest.current({ id, link: 'failed', problem: readFailure(error) })
      },
    )
  }, [bridge, serverId])

  useEffect(() => {
    if (!bridge || serverId === null) return
    look()
    return () => {
      void bridge.closeServer(serverId)
    }
  }, [bridge, serverId, look])

  return { look }
}
