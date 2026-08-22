import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { asView, resolveBridge, type Machine, type MachineLinkState, type MachinesBridge, type MachinesView } from './types'

/**
 * The other machines, read by the **window** rather than by a settings panel.
 *
 * ## Why this exists
 *
 * Everything about reaching another machine used to live inside Settings →
 * Remote: the list, the connect button, the folder picker, and a terminal pane
 * that only existed while that panel was open. Asad, looking at it:
 *
 *   > *"The Remote page is for connecting only, not controlling. This is shit.
 *   > This is completely super basic."*
 *
 * and, the sentence that decides the shape of this file:
 *
 *   > *"Remote sessions belong in the sidebar, alongside local ones. Starting
 *   > one should go: New session → pick the machine → pick its folder →
 *   > continue."*
 *
 * A sidebar cannot read a settings panel's state. So the machines view has to
 * be owned one level up, by the window, and handed to whatever draws it — the
 * rail, the pane, the New Session dialog — which is exactly what this hook is.
 * The settings panel keeps its own copy, deliberately: it is a different screen
 * with its own busy states and its own pairing flow, and merging them would put
 * a settings form's lifecycle inside the window's.
 *
 * ## What it deliberately does not do
 *
 * It does not connect, pair, forget or rename. Those are decisions, they live on
 * the Remote screen, and a hook that offered them would put "forget this
 * machine" one render away from the sidebar. What it offers is the read, plus
 * the two verbs the sidebar genuinely needs — start a session on a machine, and
 * subscribe to a session's bytes.
 *
 * ## Connecting is not a button here
 *
 * `listMachines` reports each link's state, and the main process dials on its
 * own. A machine that is `offline` is drawn as offline and its sessions are not
 * listed, because there is nothing to list — not because the window is waiting
 * to be told to connect. Anything else would be the toggle this product has
 * spent a week removing, one layer down.
 */

/** One machine and the link to it, paired up for a caller that draws both. */
export interface MachineWithLink {
  machine: Machine
  link: MachineLinkState | null
}

export interface MachinesRead {
  /** False when this build's preload has no machine channels at all. */
  wired: boolean
  machines: MachineWithLink[]
  /**
   * What this computer is called, for the lists that draw it beside the others.
   *
   * `''` until the first read lands and on any build whose preload predates the
   * field, which is why every caller passes it through a fallback rather than
   * printing it raw — see `hereName` in `browser/machines-bridge.ts`.
   */
  here: string
  /** The bridge, for the panes and the dialog. Null when the build has none. */
  bridge: MachinesBridge | null
  /** Ask for the list again. Harmless to call when nothing has changed. */
  reread(): void
  /**
   * Start a session on one machine, and answer with its id once it exists.
   *
   * Null when the far machine refused, when it did not produce a session inside
   * {@link START_TIMEOUT_MS}, or when this build has no machine channels.
   *
   * ## Why this waits rather than returning what the call returned
   *
   * `machines:create` answers `boolean` — *the request was sent* — because that
   * is genuinely all the main process knows at that moment. The session is made
   * on the other computer: the far end resolves a login shell's PATH, probes
   * which agent CLIs are installed and spawns a pty, and the answer comes back
   * later as a `created` frame that lands in the link's session list.
   *
   * So a caller that wanted to *open* what it just started had two choices:
   * believe the boolean and open nothing, or watch for the row. The first is the
   * shape of bug this codebase keeps producing — a press that reports success
   * and leaves the screen unchanged — so this watches.
   *
   * The wait is deliberately for a **new** id rather than for "the newest one",
   * because two people can be starting sessions on the same machine and the
   * newest row may be somebody else's.
   */
  startSession(machineId: string, cwd: string, provider: string): Promise<string | null>
  /**
   * End one session on one machine, and answer whether the request left here.
   *
   * ## Why this waits for nothing, where {@link startSession} waits
   *
   * They are asymmetric on purpose. Starting a session has to wait, because the
   * caller wants to *open* the thing it just made and the id is minted on the
   * other computer — so believing the boolean would mean opening nothing.
   * Ending one has nothing to open afterwards. The row leaves the list the
   * moment the far machine's `closed` frame lands, `machines:state` pushes it,
   * and every screen drawing that list redraws itself. A promise that resolved
   * when the row went would be a second path to the same fact, and the screen
   * would already have updated before anybody awaited it.
   *
   * False means the request never left: this build has no machine channels, the
   * machine is not linked, or it never advertised `close`. Callers draw the
   * control off `capabilities` rather than off this, so a false here is a
   * genuine surprise and is worth reporting rather than swallowing — see
   * `closeMachine` in `App.tsx`, which counts them.
   */
  closeSession(machineId: string, sessionId: string): Promise<boolean>
}

/**
 * Machines whose sessions can be listed and started right now.
 *
 * Exported and pure, because it is the rule behind both the sidebar's section
 * and the New Session dialog's machine list, and those two disagreeing would be
 * a machine you can pick in the dialog and cannot see in the rail.
 *
 * `online` is the only state that qualifies. `awaiting-approval` looks close
 * enough to be tempting and is not: it means the far machine has not let this
 * one in yet, so every verb it offers would be refused with a sentence a person
 * cannot act on from here.
 */
export function reachableMachines(view: MachinesView): MachineWithLink[] {
  return view.machines
    .map((machine) => ({
      machine,
      link: view.links.find((link) => link.id === machine.id) ?? null,
    }))
    .filter((row) => row.link?.state === 'online')
}

/*
 * `REREAD_MS = 4000` was here — a four-second poll described in its own
 * comment as a backstop for "the rest" of what the pushes did not cover. His
 * rule, quoted in that very comment, is *"events, not polling — they make the
 * system heavier"*, so on 2026-08-22 the rest was enumerated instead of
 * backstopped, and every item turned out to be a missing event, not a reason
 * to poll:
 *
 *  - link state, sessions, folders, ports, a machine's copilot — every
 *    `publish` in `remote/machines/guest.ts` lands in `announce()` and pushes
 *    `machines:state`. Always covered.
 *  - pair, forget, rename — announced by their own handlers. Always covered.
 *  - the browser-driving grant (`machines:drive-windows`) — answered only to
 *    its caller until now; its handler announces too.
 *  - the relay link coming up, which is what clears the pairing screen's
 *    `blocked` sentence on a machine with nothing paired yet (no links, so no
 *    `machines:state` was ever going to fire) — pushed on
 *    `remote:connections` now, the channel that already means "the remote
 *    picture moved". Subscribed to below as a bare nudge.
 *
 * With the list closed, the timer had nothing left to catch, and a timer that
 * catches nothing is load on every window for the length of every session.
 */

/**
 * How long to wait for a started session to appear.
 *
 * Starting one on the far machine is two `execFile` calls and a spawn, over a
 * relay, so it is tens to hundreds of milliseconds on a good link and
 * occasionally a second or two on a bad one. Twelve seconds is long enough that
 * a slow network is not mistaken for a refusal, and short enough that a person
 * is not left watching a dialog that has already closed.
 *
 * Timing out is not an error and is not reported as one. The session may well
 * have started — it is on another computer, and this end losing interest does
 * not stop it — so the rail simply fills a moment later, which is the honest
 * outcome and the one a person can act on.
 */
const START_TIMEOUT_MS = 12_000

export function useMachines(provided?: MachinesBridge): MachinesRead {
  const bridge = useMemo(() => resolveBridge(provided) ?? null, [provided])
  const [view, setView] = useState<MachinesView>({ machines: [], links: [], here: '', blocked: null })
  const alive = useRef(true)

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const reread = useCallback(() => {
    if (!bridge) return
    void bridge
      .listMachines()
      .then((raw) => {
        if (alive.current) setView(asView(raw))
      })
      .catch(() => {
        // Left as it was rather than emptied. A read that failed is not evidence
        // that the machines went away, and a rail that dropped its rows on one
        // bad answer would look like the far machine had disconnected.
      })
  }, [bridge])

  useEffect(() => {
    if (!bridge) return
    reread()
    const off = bridge.onMachinesState((raw) => {
      if (alive.current) setView(asView(raw))
    })
    /*
     * The one fact `machines:state` cannot carry on its own: `blocked` is
     * computed from the relay's state, and a machine with nothing paired has
     * no link to publish when the relay comes up. The nudge's payload is
     * ignored — one read is one source of truth — and the re-read is rare by
     * nature: pairings, approvals, and the relay connecting or dropping.
     * Optional-chained because an older preload has no such channel, and that
     * build simply keeps the coverage the pushes above give it.
     */
    const offRemote = bridge.onRemoteConnections?.(() => reread())
    return () => {
      off()
      offRemote?.()
    }
  }, [bridge, reread])

  /**
   * The session ids on each machine, as a ref.
   *
   * A ref rather than reading `view` inside {@link startSession}: that closure
   * would capture whichever render created it, and the whole point of the wait
   * is to compare against the state *at the moment of the call* and then against
   * every state after it. React state cannot answer the second half from inside
   * a promise; this can, because the effect below writes it on every push.
   */
  const seen = useRef(new Map<string, Set<string>>())
  useEffect(() => {
    const next = new Map<string, Set<string>>()
    for (const link of view.links) next.set(link.id, new Set(link.sessions.map((s) => s.id)))
    seen.current = next
  }, [view])

  const startSession = useCallback(
    async (machineId: string, cwd: string, provider: string): Promise<string | null> => {
      if (!bridge) return null
      const before = new Set(seen.current.get(machineId) ?? [])
      const sent = await bridge.createMachineSession(machineId, cwd, provider).catch(() => false)
      // False means the request never left — the machine is not linked, or the
      // id names nothing. There is no session coming, so there is nothing to
      // wait for.
      if (sent !== true) return null

      return await new Promise<string | null>((settle) => {
        let done = false
        const finish = (id: string | null): void => {
          if (done) return
          done = true
          clearTimeout(timer)
          off()
          settle(id)
        }
        const look = (raw: unknown): void => {
          const next = asView(raw)
          const link = next.links.find((one) => one.id === machineId)
          if (!link) return
          const fresh = link.sessions.find((session) => !before.has(session.id))
          if (fresh) finish(fresh.id)
        }
        const off = bridge.onMachinesState(look)
        const timer = setTimeout(() => finish(null), START_TIMEOUT_MS)
        // And one read straight away, in case the `created` frame landed between
        // the call resolving and this subscription being made. Without it a fast
        // machine on a local network is the case that never opens.
        void bridge.listMachines().then(look).catch(() => undefined)
      })
    },
    [bridge],
  )

  const closeSession = useCallback(
    async (machineId: string, sessionId: string): Promise<boolean> => {
      if (!bridge) return false
      // `=== true` rather than a truthiness test, for the reason every other
      // read of this bridge narrows: the channel is typed `unknown` on purpose,
      // and an older preload answering `undefined` must not read as success.
      return (await bridge.closeMachineSession(machineId, sessionId).catch(() => false)) === true
    },
    [bridge],
  )

  return {
    wired: bridge !== null,
    machines: reachableMachines(view),
    here: view.here,
    bridge,
    reread,
    startSession,
    closeSession,
  }
}
