/**
 * The relay, as a process.
 *
 * Everything interesting is in `rendezvous.ts`; this file only decides what the
 * process listens on, how it is told to stop, and what it says while running.
 *
 * ## No TLS here, on purpose
 *
 * The relay speaks plain HTTP and expects a reverse proxy in front terminating
 * TLS — Traefik, in the deployment this ships to. Two reasons, and neither is
 * laziness: certificate renewal is a solved problem in the proxy and an
 * unsolved one in every application that has ever tried it, and the container
 * then needs no certificate on disk and no privileged port.
 *
 * It also means the relay never sees a private key of any kind, which is a
 * pleasant echo of the fact that it never sees a session key either.
 *
 * ## What it prints, and what it must never print
 *
 * Host ids are the addresses of people's machines. They are unguessable
 * precisely so that knowing one is meaningful, so they are not logged — not on
 * connect, not on error, not at debug level, because there is no debug level.
 * The counters below are cardinal numbers and nothing else.
 */

import { createRelayServer } from './rendezvous'

const port = Number(process.env.PORT ?? 8080)
const host = process.env.HOST ?? '0.0.0.0'

/**
 * `0.0.0.0` is correct *here* and would be a serious bug in the desktop app.
 *
 * Worth stating plainly because the app's own remote server refuses to bind it
 * and says so loudly. The difference is what is behind the socket: there, a PTY
 * on someone's laptop; here, a switchboard that cannot read the calls it
 * connects. This process is meant to be reachable from the internet — that is
 * its entire function — and it is fronted by a proxy that terminates TLS.
 */
const relay = createRelayServer({
  heartbeatMs: Number(process.env.HEARTBEAT_MS ?? 30_000),
  maxGuestsPerHost: Number(process.env.MAX_GUESTS_PER_HOST ?? 8),
  maxHosts: Number(process.env.MAX_HOSTS ?? 5_000),
})

relay.server.on('clientError', (_error, socket) => socket.destroy())

relay.server.listen(port, host, () => {
  console.log(`relay listening on ${host}:${port}`)
})

/**
 * Stopping cleanly matters more than usual for this process.
 *
 * Every connection it holds is someone's live terminal session. `server.close()`
 * stops accepting new sockets but leaves existing ones alone, so a deploy does
 * not cut anybody off mid-command; the container platform's own grace period
 * decides how long that politeness lasts. Hosts reconnect on their own.
 */
let stopping = false
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    if (stopping) return
    stopping = true
    const { hosts, guests } = relay.rendezvous.stats()
    console.log(`${signal}: closing the listener, ${hosts} host(s) and ${guests} guest(s) still connected`)
    void relay.close().then(() => process.exit(0))
  })
}

// An unhandled rejection would otherwise take the process down on Node 20+, and
// with it every session it is carrying, for something as small as a socket that
// closed at an awkward moment.
process.on('unhandledRejection', (reason) => {
  console.error('unhandled rejection:', reason instanceof Error ? reason.message : String(reason))
})

/*
 * There is deliberately no periodic "still alive" log here.
 *
 * An earlier version printed the connection counts every five minutes. Nothing
 * consumed it: `/healthz` already answers the same question on demand, and the
 * container platform already knows whether the process is running. A timer
 * whose output nobody reads is pure cost — it wakes the event loop, it fills a
 * log nobody greps, and it scales with uptime rather than with anything
 * happening.
 *
 * The heartbeats that remain in `rendezvous.ts` are a different thing and are
 * not optional: a WebSocket through NAT dies silently when the mapping expires
 * after 30–60 seconds of quiet, and TCP keepalive defaults to hours. Those
 * timers keep sessions alive. This one only kept a log warm.
 */
