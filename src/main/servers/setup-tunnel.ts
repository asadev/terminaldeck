/**
 * One socket on this Mac's loopback, carried to the same number on the server.
 *
 * ## Why this exists at all, and why the number has to match
 *
 * `claude auth login` on a headless machine starts an ordinary OAuth loopback
 * listener **on that machine**, on a random number, and bakes that number into
 * the `redirect_uri` it sends to Anthropic. So when the browser on this Mac
 * finishes the approval, Anthropic redirects it to
 * `http://localhost:<that number>/callback?code=…` — and on this Mac there is
 * nothing there.
 *
 * This module puts something there: a listener on the identical number whose
 * every connection is carried down the existing SSH connection to the server's
 * own loopback. The redirect arrives at `claude`'s own listener, `claude`
 * exchanges the code with its own PKCE verifier and writes its own credential.
 *
 * That is the whole reason the feature complies with `ACCOUNT-MODEL.md` —
 * *"this app never holds the credential"*. The authorization code is carried as
 * **bytes on a socket**. It is never parsed here, never assigned to a field,
 * never logged, and never typed into anything. Reading it out of the browser
 * and typing it into the terminal is the tempting shortcut and it is the one
 * thing `DRIVABLE-BROWSER.md` §7 forbids by name: *"the agent never types into
 * a password, one-time-code or file field… It never reads one back."*
 *
 * The number matching is not a preference. It is in the `redirect_uri` that was
 * already sent to Anthropic before this listener existed, so a different local
 * number reaches nothing. If this Mac has that number taken, the answer is to
 * cancel the sign-in on the server and start it again — it picks a new random
 * one — rather than to bind somewhere else and hope.
 *
 * ## Why not `createSshTunnelHost`
 *
 * That one, in `forward.ts:466`, speaks the phone relay's frame protocol to a
 * paired device. This is raw TCP between a local listener and a remote port on
 * one connection, which is a different shape entirely, and reusing it would
 * mean wrapping an OAuth redirect in a message envelope that nothing on the
 * other end unwraps.
 */

import { createServer, type Server, type Socket } from 'node:net'
import type { ForwardChannel, Forwarder } from './forward'

/** Everything binds here. Never `0.0.0.0` — this is one browser on this Mac. */
const LOOPBACK = '127.0.0.1'

/** One live tunnel, for as long as a sign-in is being attempted. */
export interface SetupTunnel {
  /** The same number on both ends. Stated rather than derived, so a caller can say it. */
  port: number
  /**
   * Something came down it.
   *
   * The one event this feature waits on. It is the browser's redirect arriving,
   * which means the approval happened and the server's own login is now
   * finishing — so it is the moment to ask the server whether it is signed in,
   * rather than asking on a timer. His standing rule: events, not polling.
   */
  onCarried(listener: () => void): void
  close(): void
}

export type TunnelResult =
  | { ok: true; tunnel: SetupTunnel }
  /** This Mac already has that number. The sign-in is restarted for a new one. */
  | { ok: false; why: 'taken'; message: string }
  /** Anything else. The person is offered the by-hand path instead. */
  | { ok: false; why: 'refused'; message: string }

/**
 * Open the listener, or say plainly why not.
 *
 * Nothing is forwarded until a connection actually arrives, so opening this
 * costs the server nothing and a sign-in that is abandoned before the browser
 * is touched never opens a channel at all.
 */
export function openSetupTunnel(port: number, forward: Forwarder): Promise<TunnelResult> {
  return new Promise<TunnelResult>((resolve) => {
    let settled = false
    const carried: Array<() => void> = []
    const sockets = new Set<Socket>()

    const server: Server = createServer((socket) => {
      sockets.add(socket)
      socket.on('close', () => sockets.delete(socket))
      for (const listener of carried) listener()
      void carry(socket, port, forward)
    })

    server.on('error', (error: NodeJS.ErrnoException) => {
      if (settled) return
      settled = true
      if (error.code === 'EADDRINUSE') {
        resolve({
          ok: false,
          why: 'taken',
          message: 'Something on this computer is already using that.',
        })
        return
      }
      resolve({ ok: false, why: 'refused', message: error.message })
    })

    server.listen(port, LOOPBACK, () => {
      if (settled) return
      settled = true
      resolve({
        ok: true,
        tunnel: {
          port,
          onCarried: (listener) => carried.push(listener),
          close: () => {
            /*
             * Both halves, and the sockets first. A listener that stops
             * accepting while a connection is still open leaves the browser
             * hanging on a request nothing will ever answer, which reads to the
             * person as the sign-in having frozen rather than having ended.
             */
            for (const socket of sockets) socket.destroy()
            sockets.clear()
            server.close()
          },
        },
      })
    })
  })
}

/**
 * Join one local connection to one channel on the server.
 *
 * Deliberately plain. The whole traffic of an OAuth redirect is a small `GET`
 * and a `302`, so there is no flow control worth writing here — but every one
 * of the four ways either end can finish is handled, because the half that is
 * missed is the one that leaves a socket open on somebody's machine after the
 * window is closed.
 */
async function carry(socket: Socket, port: number, forward: Forwarder): Promise<void> {
  const result = await forward(LOOPBACK, port)
  if (!result.ok) {
    socket.destroy()
    return
  }
  const channel: ForwardChannel = result.channel
  socket.on('data', (chunk) => channel.write(chunk, () => undefined))
  channel.on('data', (chunk) => socket.write(chunk))
  socket.on('end', () => channel.end())
  channel.on('end', () => socket.end())
  socket.on('error', () => channel.destroy())
  channel.on('error', () => socket.destroy())
  socket.on('close', () => channel.destroy())
  channel.on('close', () => socket.destroy())
}
