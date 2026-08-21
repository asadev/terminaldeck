/**
 * The two verbs the browser needs from a server, and the connection they hold.
 *
 * ## What was missing, and why it counted as a defect
 *
 * The servers feature landed with a control room, a shell and an action layer,
 * and without the one thing a person does with a server all day: open what it
 * is serving. Asked directly —
 *
 *   > *"does it also cover to open sessions, and local browsers in server"*
 *
 * — the answer was no, and the rule that makes that a defect rather than a
 * missing extra has been repeated three nights running:
 *
 *   > *"Keep the same one browser window for every device… **shape of the
 *   > application should not be changing for local and remote devices.** It
 *   > should act like that same."*
 *
 * A server is one of those machines. So it takes its place in the picker the
 * relay path already put beside the address bar, `localhost` means it while it
 * is chosen, and its ports open as ordinary pages in the same tabs. There is no
 * second browser, no second kind of tab, and — this is the part that had to be
 * decided rather than assumed — **no second vocabulary**: what these two
 * channels answer is byte-compatible with what `machines:ports` and
 * `machines:reach` answer, so the window has one code path with one branch in
 * it rather than two features that look alike.
 *
 * ## The two questions, and where each answer comes from
 *
 * `servers:ports` — *what is listening over there, and may we open it?* Both
 * halves are measured and neither is guessed:
 *
 *  - **What is listening** comes from the probe that already runs, which asks
 *    `ss`, falls back to `netstat`, and answers *"this server has no tool
 *    installed for listing what is listening"* when it has neither. That third
 *    state is the house style for this whole area and it is carried through to
 *    the screen rather than flattened into an empty list, because "nothing is
 *    listening" and "we cannot tell" send a person to two different places.
 *  - **May we open it** comes from `askWhetherItForwards` in `forward.ts`,
 *    which asks the server itself. `AllowTcpForwarding no` is real and common,
 *    and a picker row that looked available and then failed on a click is the
 *    control this project keeps deleting.
 *
 * `servers:reach` — *give this port an address on this computer.* The answer is
 * a plain `http://` URL on this machine's loopback, which the window opens the
 * way it opens anything. The pipe behind it is `localhost-reach.ts`, unchanged,
 * with `forward.ts` standing in for the machine at the far end.
 *
 * ## What holds the connection open, and for how long
 *
 * §5.4 of `SERVERS-DESIGN.md` sets the rule — *the page holds the connection
 * while it is open and lets go when it closes* — and there is no timer
 * anywhere in this feature, because his standing rule is **events, not
 * polling**.
 *
 * Asking what is listening is a question with an end, so it holds a connection
 * for exactly as long as it takes and lets go. Reaching a port is not: the
 * listener it opens on this machine has to keep answering for as long as
 * somebody is reading the page it serves, so the connection is held from the
 * first reach until the connection itself goes or the app quits. That is the
 * same bargain the relay path makes — `localhost-reach.ts` says in as many
 * words that it has no idle reaper, because a page that dies while somebody is
 * reading it is worse than a socket that stays open — and it is one connection
 * per server, reference-counted alongside the server page's own, so a browser
 * tab and a control room looking at the same machine share one.
 */

import { createRemoteReach, type ReachAnswer, type RemoteReach } from '../localhost-reach'
import { isExcluded } from '../../shared/not-a-page'
import { problemFor } from './connection'
import type { ListenerFact, ServerFacts } from './facts'
import {
  askWhetherItForwards,
  createSshTunnelHost,
  forwardOn,
  type ForwardingConnection,
  type SshTunnelHost,
} from './forward'

/**
 * The registrar, narrowed to what this module uses.
 *
 * Declared here rather than imported from `ipc.ts` for the reason that file
 * gives for its own copy: a module that took Electron's `IpcMain` could not be
 * exercised without Electron, and the whole point of a seam this narrow is that
 * a test can hold both sides of it.
 */
export interface InvokeRegistrar {
  handle(channel: string, listener: (event: unknown, ...args: unknown[]) => unknown): void
}

/** One port on a server, in the shape the browser's start page already draws. */
export interface ServerPort {
  port: number
  /** What the server said is holding it — `nginx`, `docker-proxy`, or ''. */
  process: string
  /** True when the server would not say what holds it, and only the number is known. */
  guessed: boolean
  /**
   * Always false, and it is a fact rather than a default.
   *
   * The fold this feeds hides ports *this app* is holding, and this app is
   * never running on somebody's server — it does not run there, which is the
   * definition of a server in §1.1. So the fold is empty for a server and never
   * drawn, which is correct rather than convenient.
   */
  ours: false
}

/**
 * What came back from asking a server what it is serving.
 *
 * `ok: false` is the picker row's refusal — it is not connected, or it will not
 * forward — and it is a sentence rather than a flag for the reason every
 * refusal in this feature is: the four ways this fails send a person to four
 * different places.
 *
 * `cannot` on the success branch is the third state kept intact. The server is
 * reachable and will forward, and it has no way to tell us what is listening on
 * it — so an address can still be typed, and the list under it says why it is
 * empty instead of implying that nothing is running.
 */
export type ServerPortsAnswer =
  | { ok: true; ports: ServerPort[]; cannot: string | null }
  | { ok: false; message: string }

export interface ServerReachDeps {
  /** Every server this app knows. Only the id and the name are read. */
  servers(): readonly { id: string; name: string }[]
  /**
   * Hold a connection for the length of `fn` and hand over its client.
   *
   * `ServerConnections.withConnection` in the app. Reference-counted there, so
   * a hold taken here joins whatever the server's own page already has open
   * rather than dialling a second time.
   */
  withConnection<T>(serverId: string, fn: (client: ForwardingConnection) => Promise<T>): Promise<T>
  /** One probe round trip. Only `listeners` is read out of it. */
  facts(serverId: string): Promise<ServerFacts>
  /**
   * Every listener this desktop was serving for that server has just been
   * closed, by something other than a browser window asking - the connection
   * died, or the app is going down.
   *
   * The browser's tunnel ledger keeps the rows a window's address bar reads its
   * machine chip off, and a row for a listener that is already gone is a chip
   * naming a server whose pages have stopped answering. Optional, for the same
   * reason the paired-machine half's is: a caller with no browser has nothing
   * to tell.
   */
  tunnelsDropped?(serverId: string): void
}

export interface ServerReachIpc {
  /** Drop every listener and let go of every connection. For shutdown. */
  stop(): void
  /** Ports currently served for one server. For a test, and for a panel later. */
  openPorts(serverId: string): number[]
  /**
   * Give a port on that server an address on this computer - the same act
   * `servers:reach` performs, in process.
   *
   * Exposed for the browser's tunnel ledger (`src/main/browser-reach.ts`),
   * which counts the windows reading each listener so the last one out is what
   * closes it. It needs to open and close one itself, and going back out
   * through `ipcMain` would be a second path into this module's own map.
   */
  reach(serverId: string, port: number): Promise<ReachAnswer>
  /** Hand that port back. True when this desktop is no longer serving it here. */
  closeReach(serverId: string, port: number): boolean
}

/**
 * What is listening, as the browser draws a port.
 *
 * Two things happen here and both are decisions rather than tidying.
 *
 * **Duplicates collapse.** A server that binds a port on both address families
 * reports it twice — the test box lists `0.0.0.0:8000` and `[::]:8000` as two
 * rows for one container — and a list that showed both would offer the same
 * page twice with no way to tell which was which. The address itself is dropped
 * with them: which family a service is bound to is answered by trying it, in
 * `forward.ts`, which walks both. A column of `0.0.0.0` on a screen for
 * somebody who has never touched a server is the definition of a word that
 * tells them nothing.
 *
 * **A port whose owner the server would not name is kept, and marked.** An
 * ordinary sign-in cannot see another account's programs, so the name is empty
 * for a great many rows on a real machine; dropping those would hide most of
 * what a shared server is running. `guessed` is what the start page already
 * uses to sort them last and label them, which is the behaviour this machine's
 * own scan has had all along.
 */
export function portsFrom(listeners: readonly ListenerFact[]): ServerPort[] {
  const byPort = new Map<number, ServerPort>()
  for (const listener of listeners) {
    /*
     * **A port whose holder does not answer browsers is not offered at all.**
     *
     * On the walk of 2026-08-18 this list offered `:22 sshd` and
     * `:53 systemd-resolve` as pages to open on somebody's server. Pressing the
     * first gets an identification string and a closed socket; the second does
     * not speak HTTP in any form. Both are the dead control §4.1 forbids, and
     * worse than dead — a row here reads as *"your server has a page here."*
     *
     * The rule is `dev-ports.ts`'s own, moved to `shared/not-a-page.ts` so that
     * one list serves both machines. Until this line the server list had no
     * filter of any kind, which is the whole defect: the scan that runs on this
     * computer has excluded `sshd` since it was written.
     *
     * Unnamed holders still come through — see the paragraph above about a
     * sign-in that cannot see another account's programs. We do not know what
     * they are, and refusing on a suspicion loses most of what a shared server
     * is running.
     */
    if (listener.program !== '' && isExcluded(listener.program)) continue
    const existing = byPort.get(listener.port)
    if (existing) {
      // Keep the first that could name what holds it. Two rows for one port are
      // the same service twice, and one of them may be the one that knew.
      if (existing.guessed && listener.program !== '') {
        byPort.set(listener.port, {
          port: listener.port,
          process: listener.program,
          guessed: false,
          ours: false,
        })
      }
      continue
    }
    byPort.set(listener.port, {
      port: listener.port,
      process: listener.program,
      guessed: listener.program === '',
      ours: false,
    })
  }
  // Named first and then by number, which is the order `readPorts` in
  // `StartPage.tsx` puts this machine's own scan in. One list, one order.
  return [...byPort.values()].sort(
    (a, b) => Number(a.guessed) - Number(b.guessed) || a.port - b.port,
  )
}

/* ------------------------------------------------------------- the module -- */

interface Held {
  reach: RemoteReach
  host: SshTunnelHost
  /** Let the connection go. Idempotent. */
  release(): void
}

export function registerServerReachIpc(
  ipcMain: InvokeRegistrar,
  deps: ServerReachDeps,
): ServerReachIpc {
  /** Servers being dialled, or already dialled, so a second click joins the first. */
  const held = new Map<string, Promise<Held | { ok: false; message: string }>>()
  /**
   * The same holds once they exist, readable without waiting.
   *
   * A second map rather than reading through the promise, because
   * {@link ServerReachIpc.openPorts} answers a caller that cannot wait — and a
   * promise read with `.then` inside a synchronous function returns whatever
   * the variable held before the callback ran, which is always the empty
   * default. That is a control that reports nothing while claiming to count,
   * which is precisely the shape of the bug this codebase keeps finding.
   */
  const live = new Map<string, Held>()

  function nameOf(serverId: string): string | null {
    return deps.servers().find((server) => server.id === serverId)?.name ?? null
  }

  /**
   * Open — or join — the long-lived hold for one server.
   *
   * The hold is a `withConnection` whose body never finishes on its own: it
   * hands the client over and then waits on a promise that only `release`
   * settles. That is deliberately the *existing* seam rather than a new method
   * on `ServerConnections`, because the reference counting that lets a browser
   * tab and a server page share one socket is written there, once, and a second
   * way in would be a second thing to keep in step with it.
   *
   * Both objects are made inside, because they are two ends of one
   * conversation: the reach speaks tunnel frames into the host, the host
   * answers them back into the reach, and neither is meaningful without the
   * connection they were built around. If the dial fails, what is cached is the
   * *sentence*, so a second click gets the reason rather than a second dial.
   */
  function holdFor(serverId: string, name: string): Promise<Held | { ok: false; message: string }> {
    const existing = held.get(serverId)
    if (existing) return existing

    const opened = new Promise<Held | { ok: false; message: string }>((settle) => {
      let letGo: (() => void) | null = null
      let gone = false

      const release = (): void => {
        if (gone) return
        gone = true
        held.delete(serverId)
        live.delete(serverId)
        letGo?.()
      }

      const running = deps.withConnection(serverId, (client) => {
        let host: SshTunnelHost | null = null
        /*
         * `false` while the host is still being built is not a hypothetical
         * ordering worry: `createRemoteReach` is handed this `send` and could
         * in principle call it during construction, and a `false` there means
         * "that machine is not connected right now", which is a true sentence
         * rather than a crash.
         */
        const reach = createRemoteReach({
          send: (message) => {
            if (host === null) return false
            host.handle(message)
            return true
          },
        })
        host = createSshTunnelHost({
          forward: forwardOn(client),
          send: (message) => reach.handle(message),
          name,
        })

        /*
         * The connection dying takes every page it was serving with it.
         *
         * Not tidying-up: the connection is the only thing that could still be
         * carrying those bytes, so every page open on one of these listeners is
         * already dead. Closing the listener turns a page that hangs into a
         * page that says the connection was refused, which a browser can
         * explain and a hang cannot. The same reasoning, in the same words, as
         * the relay path's own drop in `remote/machines/ipc.ts`.
         */
        client.on('close', () => {
          reach.closeAll('The connection to that server dropped, so its pages are no longer being served here.')
          host?.closeAll()
          release()
          // And the browser, whose rows are the only place those listeners were
          // ever named. After the close, not instead of it.
          deps.tunnelsDropped?.(serverId)
        })

        const connection: Held = { reach, host, release }
        live.set(serverId, connection)
        settle(connection)
        return new Promise<void>((resolve) => {
          letGo = resolve
          if (gone) resolve()
        })
      })

      running.catch((error: unknown) => {
        held.delete(serverId)
        live.delete(serverId)
        gone = true
        settle({ ok: false, message: problemFor(error).sentence })
      })
    })

    held.set(serverId, opened)
    return opened
  }

  /**
   * Ask a server what it is serving, and whether it will let us open any of it.
   *
   * One connection for both questions rather than two. The probe opens its own
   * — `ServerConnections` reference-counts, so it joins this one instead of
   * dialling again — and the forwarding question needs the client in hand, so
   * the outer hold is what keeps the socket alive across both and what lets go
   * of it when the answer is complete. A server nobody is reading a page from
   * is not left dialled.
   */
  ipcMain.handle('servers:ports', async (_event, id: unknown): Promise<ServerPortsAnswer> => {
    if (typeof id !== 'string') return { ok: false, message: 'That is not a server.' }
    const name = nameOf(id)
    if (name === null) return { ok: false, message: 'This app does not know that server.' }

    try {
      return await deps.withConnection(id, async (client): Promise<ServerPortsAnswer> => {
        const facts = await deps.facts(id)
        const listeners = facts.listeners
        const ports = listeners.known === 'yes' ? portsFrom(listeners.value) : []
        const forwards = await askWhetherItForwards(forwardOn(client), {
          listening: ports.map((entry) => entry.port),
        })
        // A refusal is the row's own sentence and it disables the row, because
        // there is genuinely nothing behind it to click.
        if (forwards.known === 'no') return { ok: false, message: forwards.why }
        /*
         * Two different "we could not tell"s, and the forwarding one is said
         * first because it is the one that changes what the row can do.
         *
         * Neither of them disables anything, and that is the third state doing
         * its job: not knowing whether a server refuses is not the same as
         * knowing that it does, and a row greyed out on a maybe would hide a
         * working feature. An address can still be typed; if the server does
         * refuse, the attempt says so in the sentence written beside the
         * refusal.
         */
        const cannot =
          forwards.known === 'cannot'
            ? `${name} could not be asked whether it allows this: ${forwards.why}`
            : listeners.known === 'cannot'
              ? listeners.why
              : null
        return { ok: true, ports, cannot }
      })
    } catch (error) {
      return { ok: false, message: problemFor(error).sentence }
    }
  })

  /*
   * The two halves of a server's localhost, as functions rather than as handler
   * bodies, because each now has two callers: the channel below, and the
   * browser's tunnel ledger in `src/main/browser-reach.ts`, which counts the
   * windows reading a listener so that the last one out is what closes it.
   */
  async function openReach(serverId: string, port: number): Promise<ReachAnswer> {
    const name = nameOf(serverId)
    if (name === null) return { ok: false, message: 'This app does not know that server.' }
    const connection = await holdFor(serverId, name)
    if ('ok' in connection) return connection
    return connection.reach.open(port)
  }

  function closeReach(serverId: string, port: number): boolean {
    const connection = live.get(serverId)
    // A server nobody has dialled is `true` for the same reason an unknown
    // machine is on the relay channel: nothing of this desktop's is standing on
    // that number, which is the entire question being asked.
    return connection ? connection.reach.close(port) : true
  }

  /**
   * Give one port on a server an address in this window's browser.
   *
   * The same answer shape `machines:reach` returns, deliberately and exactly:
   * `{ ok: true, url, port, localPort, sameNumber }` or `{ ok: false, message }`.
   * The window narrows both with the same `readReach`, draws both with the same
   * badge, and warns about a changed port number with the same sentence. Two
   * shapes here would have been two of everything up there.
   */
  ipcMain.handle(
    'servers:reach',
    async (_event, id: unknown, port: unknown): Promise<ReachAnswer> => {
      if (typeof id !== 'string' || typeof port !== 'number') {
        return { ok: false, message: 'That is not a server and a port.' }
      }
      return openReach(id, port)
    },
  )

  /**
   * Hand one of its ports back, so that number means this computer again.
   *
   * The same channel the relay path grew for the same reason, and byte-for-byte
   * the same answer — a boolean. `localhost-reach.ts` keeps the far port's own
   * *number* on this machine whenever it was free, so while a tunnel is up
   * `localhost:8000` here is the server's 8000; the browser's machine picker
   * moving a page back onto this computer has to give the number up before it
   * can send the page anywhere.
   *
   * A server nobody has dialled is `true` for the same reason an unknown
   * machine is on the other channel: nothing of this desktop's is standing on
   * that number, which is the entire question being asked.
   *
   * The connection itself is **not** let go here. A server holds one for as
   * long as any page of its is open, and this closes one listener rather than
   * saying that nobody is reading anything of that server's any more.
   */
  ipcMain.handle('servers:reach:close', (_event, id: unknown, port: unknown): boolean => {
    if (typeof id !== 'string' || typeof port !== 'number') return false
    return closeReach(id, port)
  })

  return {
    reach: openReach,
    closeReach,
    stop(): void {
      for (const connection of [...live.values()]) {
        connection.reach.closeAll('This desktop is shutting down.')
        connection.host.closeAll()
        // Last, because `release` is what lets go of the connection, and the
        // two calls above still need it to send their closing frames.
        connection.release()
      }
      live.clear()
      held.clear()
    },

    openPorts(serverId: string): number[] {
      return live.get(serverId)?.host.openPorts() ?? []
    },
  }
}
