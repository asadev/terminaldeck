import { useCallback, useEffect, useRef, useState } from 'react'
import { Button } from '../../settings/controls'
import { asHostControlWire, type HostControlWire } from './types'
import type { MachinesBridge } from '../types'

/**
 * **Manage the host over the relay** — status, restart, stop — on the server
 * page, when the server is a connected machine.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A server page reaches one box by two roads: an SSH address it was added with,
 * and the relay it is paired over. Asad's SSH address is a Tailscale name
 * (`imza-pc-wsl`) that drops on its own — and when it does, the SSH survey on
 * this page reports the box unreachable while every session on it is still
 * running over the public relay. So the status a headless server has no screen to
 * show, and the restart/stop it has no screen to press, are answered here over
 * the relay whenever the server is a connected machine, independent of whether
 * its SSH address answers.
 *
 * This is the desktop port of iOS `HostRelayControlView`, reaching the same wire
 * (`host.control`) through the same `MachineLink.hostStatus / hostRestart /
 * hostStop`. It draws **nothing** over a machine that is not connected or that
 * does not advertise the capability — the caller in `ServerHost` makes that
 * decision, and passes only a live machine that speaks it — so an SSH-only server
 * is exactly as it was.
 *
 * There is no Start here on purpose: a stopped host is not connected over the
 * relay, so there is nothing on this wire to start — that stays on the SSH page.
 *
 * ## What restart and stop do, and why there is no push
 *
 * A restart or a stop drops the very connection the answer travels on. So the
 * host answers with a `note` **first** and acts after — this card shows that
 * note, and then the connection goes. A `null` answer is therefore the ordinary
 * outcome of a restart, not a failure: the reconnection is the real signal, and
 * `Check again` re-reads once the host is back. There is no unsolicited "host
 * changed" frame; a restarted host simply reconnects.
 */

/**
 * One plain line under the status: how long it has been up, and what a restart
 * will do — in the person's words, never the supervisor's name.
 *
 * The `managed` fact is real and measured, but `plain-words.test.ts` bans naming
 * the mechanism on these screens — nobody arrives holding the word for what keeps
 * a program running. So the consequence is stated and the name is not: a machine
 * that comes back on its own says so, and one that has to be re-launched says
 * that, and neither says how.
 */
export function managedDetail(state: HostControlWire): string {
  const parts: string[] = []
  if (state.uptimeSeconds > 0) parts.push(`up for ${spell(state.uptimeSeconds)}`)
  if (state.managed === 'systemd') {
    parts.push('it comes back on its own after a restart')
  } else if (state.managed === 'direct') {
    parts.push('it is re-launched after a restart')
  }
  return parts.length === 0 ? 'Reached over the relay.' : parts.join(' · ')
}

/** Uptime as one plain phrase, largest unit that reads as more than one. */
export function spell(seconds: number): string {
  const days = Math.floor(seconds / 86400)
  if (days >= 1) return days === 1 ? '1 day' : `${days} days`
  const hours = Math.floor(seconds / 3600)
  if (hours >= 1) return hours === 1 ? '1 hour' : `${hours} hours`
  const minutes = Math.max(1, Math.floor(seconds / 60))
  return minutes === 1 ? '1 minute' : `${minutes} minutes`
}

export function ServerHostRelayControl({
  machineId,
  bridge,
}: {
  machineId: string
  /** The machines bridge, resolved once by the page. Null takes the card away. */
  bridge: MachinesBridge | null
}) {
  const [state, setState] = useState<HostControlWire | null>(null)
  const [working, setWorking] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const [timedOut, setTimedOut] = useState(false)
  const alive = useRef(true)

  const read = useCallback(() => {
    // Optional-chained: a preload older than these channels simply has no method
    // here, and the caller has already checked the far machine advertised the
    // capability. Either absence draws nothing rather than a dead control.
    const ask = bridge?.readMachineHost
    if (!ask) return
    void ask.call(bridge, machineId).then(
      (raw) => {
        const wire = asHostControlWire(raw)
        if (!alive.current || wire === null) return
        setState(wire)
        // A plain status carries no note; only a restart/stop does, so a read
        // that finds none must not wipe the one a verb just set.
        if (wire.note !== null) setNote(wire.note)
      },
      () => {
        // A read that threw is not evidence the host stopped — leave the last
        // status on screen, exactly as the machine list does on a failed read.
      },
    )
  }, [bridge, machineId])

  // Read once when the card appears, and again whenever the machine it is about
  // changes. There is no poll: the status is read here and re-read on the verb
  // buttons or `Check again`, which is the pull-to-refresh path iOS has.
  useEffect(() => {
    alive.current = true
    read()
    return () => {
      alive.current = false
    }
  }, [read])

  const runVerb = useCallback(
    (verb: ((id: string) => Promise<unknown>) | undefined) => {
      if (!verb || working) return
      setWorking(true)
      setTimedOut(false)
      setNote(null)
      void verb.call(bridge, machineId).then(
        (raw) => {
          if (!alive.current) return
          setWorking(false)
          const wire = asHostControlWire(raw)
          if (wire === null) {
            // No word came back. Not a failure: a restart drops the connection as
            // it acts, so the confirmation races the drop. The host is on its way
            // back — see the header — and `Check again` re-reads once it is.
            setTimedOut(true)
            return
          }
          setState(wire)
          setNote(wire.note)
        },
        () => {
          if (alive.current) {
            setWorking(false)
            setTimedOut(true)
          }
        },
      )
    },
    [bridge, machineId, working],
  )

  if (!bridge?.readMachineHost) return null

  return (
    <section className="servers-setup servers-host">
      <h3 className="servers-setup-heading">The host, over the relay</h3>

      {state !== null ? (
        <div className="servers-setup-top">
          <p className="servers-setup-say">
            {/* It answered over the relay, so it is running — the whole point of
                the card is that this is true even when the SSH survey above could
                not say so. */}
            {state.version === '' ? 'Running.' : `Running ${state.version}.`}
          </p>
        </div>
      ) : (
        <p className="servers-setup-say">Reaching the host over the relay…</p>
      )}

      {state !== null && <p className="servers-card-why">{managedDetail(state)}</p>}

      <p className="servers-card-why">
        Reached over the relay, so these work even when this server’s address is offline.
      </p>

      <div className="servers-card-actions">
        <Button tone="primary" disabled={working} onClick={() => runVerb(bridge.restartMachineHost)}>
          {working ? 'Working…' : 'Restart it'}
        </Button>
        <Button tone="danger" disabled={working} onClick={() => runVerb(bridge.stopMachineHost)}>
          Stop
        </Button>
        <Button disabled={working} onClick={read}>
          Check again
        </Button>
      </div>

      {note !== null && <p className="servers-card-why">{note}</p>}
      {timedOut && (
        <p className="servers-card-why">
          {/* Not "it failed": a restart drops the connection as it acts, so the
              confirmation can race the drop. It is coming back — press Check again
              in a moment. */}
          No word came back before the connection dropped — the host may be on its way back up.
          Press Check again in a moment.
        </p>
      )}
    </section>
  )
}
