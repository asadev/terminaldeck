import { useCallback, useMemo, useState } from 'react'
import { RemoteSection } from '../remote/RemoteSection'
import { useAt } from '../schedule'
import { AddServer } from './servers/AddServer'
import { ServerPage } from './servers/ServerPage'
import { ServersSection } from './servers/ServersSection'
import { useServerSessionOpener } from './servers/session-context'
import { useServers } from './servers/useServers'
import { nextAgeChange } from './servers/words'
import {
  asAddResult,
  asKeyOffer,
  asKeyOffers,
  asKeyText,
  type AddServerDraft,
  type AddServerFailure,
  type ServerState,
  type ServersBridge,
} from './servers/types'
import type { KeyChooser } from './servers/AddServer'
import './servers/servers.css'

/**
 * Machines — everything that is not this computer.
 *
 * ## Why one page and two kinds
 *
 * The rail used to say **Remote**, and it meant one thing: the phones and
 * computers you have paired with this one. It now says **Machines**, and it
 * covers two:
 *
 *  - **your own devices** — the ones you also sit at, which run this app on the
 *    far end and are paired with a six-digit code;
 *  - **servers** — the ones nobody sits at, which do not run this app and never
 *    will, and are reached by an address and a sign-in.
 *
 * The line between them is a fact anybody can check rather than a matter of
 * taste: *a device runs this app on the far end, a server does not*. That is
 * also why the two ways in cannot be merged — a code is minted by the app at the
 * other end, which presupposes there is one, and a server has nothing there to
 * mint anything. Two ceremonies, one page, and the page says which is which.
 *
 * ## No new row in the rail
 *
 * This is the whole placement requirement, in his words: *"we will place it
 * somewhere without making our tool more busy UI, so make a placement to reach
 * to its own private area."* So servers went **inside** a row that already
 * existed rather than beside it. Nothing was added to the sidebar; one label
 * changed.
 *
 * ## A server's page takes over the content
 *
 * It does not become a window and it does not become a view the sidebar can
 * travel to. A shell on a server is not a session — no transcript, no account,
 * no model, no cost — so a pill in the window strip would carry a cluster of
 * controls that all do nothing, which is a defect this app has already had once
 * and removed. Taking over this panel's content needs no shared file and no new
 * id, and Back returns to exactly where it left.
 *
 * ## Why what each server said is held here
 *
 * One level above the page that measured it, so that leaving a server does not
 * throw away what it told us. That is what lets the list show *"Everything's
 * running — as of 20 minutes ago"* against a machine nothing is currently
 * connected to, which is the honest alternative to either connecting to
 * everything or showing nothing at all.
 *
 * ## The clock here is a single appointment, not a tick
 *
 * The ages on this screen — *as of 20 minutes ago*, *allowed for another 40
 * minutes* — have to change or they are lies. What they must not be is an
 * interval: a per-second repaint of a list is the timer-shaped cost this whole
 * area is arranged to avoid. So the soonest moment any visible label stops being
 * true is computed, one timeout is set for it, and nothing runs in between.
 */

type View = { kind: 'list' } | { kind: 'add' } | { kind: 'server'; id: string }

interface Props {
  /** Defaults to the real bridge. Passed by tests, and by nothing else. */
  bridge?: ServersBridge
}

export function MachinesPanel({ bridge: supplied }: Props = {}) {
  const { wired, missing, servers, bridge, reading, problem, reread } = useServers(supplied)
  /* The window's list of terminals open on servers, or null when this panel is
     drawn outside a window — a test, the harness. See `session-context.ts`. */
  const opener = useServerSessionOpener()
  const [view, setView] = useState<View>({ kind: 'list' })
  const [states, setStates] = useState<Map<string, ServerState>>(() => new Map())
  const [adding, setAdding] = useState(false)
  const [addError, setAddError] = useState<string | null>(null)
  const [addReason, setAddReason] = useState<AddServerFailure | null>(null)
  const [now, setNow] = useState(() => Date.now())

  const remember = useCallback((state: ServerState) => {
    setStates((before) => {
      const next = new Map(before)
      next.set(state.id, state)
      return next
    })
  }, [])

  /*
   * The next moment something on screen would start reading wrong.
   *
   * Every measurement and every grant expiry contributes one candidate, and the
   * earliest wins. A screen with nothing aged on it schedules nothing at all,
   * which is the ordinary case: a list of servers nobody has opened has no ages
   * in it.
   */
  const nextChange = useMemo(() => {
    let soonest: number | null = null
    const consider = (when: number): void => {
      if (when > now && (soonest === null || when < soonest)) soonest = when
    }
    for (const state of states.values()) {
      if (state.view !== undefined && state.view.measuredAt > 0) {
        consider(nextAgeChange(state.view.measuredAt, now))
      }
      if (state.grant != null) consider(state.grant.expiresAt)
    }
    return soonest
  }, [states, now])

  useAt(nextChange, () => setNow(Date.now()))

  const submit = useCallback(
    (draft: AddServerDraft) => {
      if (!bridge) return
      setAdding(true)
      setAddError(null)
      bridge.addServer(draft).then(
        (raw) => {
          const result = asAddResult(raw)
          setAdding(false)
          if (result.ok) {
            setAddReason(null)
            // Straight to the server that was just added, because adding one is
            // never the goal — looking at it is. A form that congratulates you
            // and returns you to a list makes you go and find the thing you just
            // made.
            setView({ kind: 'server', id: result.id })
            reread()
            return
          }
          setAddReason(result.reason)
          setAddError(result.message)
        },
        () => {
          setAdding(false)
          setAddReason('unknown')
          setAddError('That attempt did not come back. Check the address and try it again.')
        },
      )
    },
    [bridge, reread],
  )

  /*
   * The key routes, wired only when the bridge has all three.
   *
   * `undefined` is a real answer here and the form draws itself smaller for it:
   * a build whose preload predates these channels would otherwise offer a list
   * that can only ever be empty and a panel that never opens. §4.1 — a control
   * that cannot act is absent, not drawn hopefully.
   */
  const keys = useMemo<KeyChooser | undefined>(() => {
    const list = bridge?.serverKeys
    const pick = bridge?.pickServerKey
    const read = bridge?.readServerKey
    if (!bridge || list === undefined || pick === undefined || read === undefined) return undefined
    return {
      list: () => list.call(bridge).then(asKeyOffers),
      pick: () => pick.call(bridge).then(asKeyOffer),
      read: (path: string) => read.call(bridge, path).then(asKeyText),
    }
  }, [bridge])

  const forget = useCallback(
    (id: string) => {
      setView({ kind: 'list' })
      setStates((before) => {
        const next = new Map(before)
        next.delete(id)
        return next
      })
      if (bridge) void bridge.forgetServer(id).then(reread, reread)
    },
    [bridge, reread],
  )

  const rename = useCallback(
    (id: string, name: string) => {
      if (bridge) void bridge.renameServer(id, name).then(reread, reread)
      /*
       * And tell the window, which is holding any terminals open on this server
       * and printing this name on four surfaces it cannot re-read from here.
       *
       * Pushed at the moment of the press rather than left to be discovered,
       * which is the standing rule for this whole area: *"events, not polling."*
       * Without it the rail heading keeps the old name until the last terminal
       * on that server is closed.
       */
      opener?.renamed(id, name)
    },
    [bridge, opener, reread],
  )

  if (view.kind === 'add') {
    return (
      <AddServer
        busy={adding}
        error={addError}
        reason={addReason}
        keys={keys}
        onSubmit={submit}
        onCancel={() => {
          setAddError(null)
          setAddReason(null)
          setView({ kind: 'list' })
        }}
      />
    )
  }

  if (view.kind === 'server') {
    const server = servers.find((entry) => entry.id === view.id)
    // A server that has left the list while its page was open — forgotten in
    // another window, or never really added — has no page to show. Falling back
    // to the list is the only honest thing: the alternative is a page with a
    // name on it and nothing behind it.
    if (server !== undefined) {
      return (
        <ServerPage
          server={server}
          state={states.get(server.id)}
          bridge={bridge}
          now={now}
          onState={remember}
          onBack={() => setView({ kind: 'list' })}
          onForget={forget}
          onRename={rename}
        />
      )
    }
  }

  return (
    <>
      <ServersSection
        wired={wired}
        missing={missing}
        reading={reading}
        problem={problem}
        servers={servers}
        states={states}
        now={now}
        onOpen={(id) => setView({ kind: 'server', id })}
        onAdd={() => {
          setAddError(null)
          setAddReason(null)
          setView({ kind: 'add' })
        }}
        onRetry={reread}
      />

      <section className="machines-kind">
        <h4 className="settings-group-title">Your own devices</h4>
        <p className="settings-prose">
          {/*
            The distinction, stated once where both kinds are on screen together,
            because it is the thing that tells somebody which half to use. It is
            deliberately a checkable fact and not a description of purpose: you
            sit at one of these, and there is a copy of this app on it.
          */}
          Computers and phones of your own, running this app too. You pair one with a six-digit code
          shown on both screens — there is no address to type and no sign-in.
        </p>
        <RemoteSection />
      </section>
    </>
  )
}
