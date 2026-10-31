/**
 * The **server** half of `ssh2`, declared for one end-to-end test and nothing else.
 *
 * ## Why it is described at all
 *
 * `reach.ssh.test.ts` proves that a server's own `localhost` reaches this
 * window's browser, and the only way to prove that without a machine on the
 * public internet is to put a real SSH server at the other end of a real
 * socket — real handshake, real key exchange, real `direct-tcpip` channels.
 * `ssh2` ships one, so the test uses it and this describes the four calls it
 * makes.
 *
 * The alternative was a stand-in that agrees with the client, and this
 * repository's own record is the argument against it: *the mechanism written
 * and the connection absent*, seven times in one week. A fake server would have
 * passed every one of those.
 *
 * ## Why it is a separate file from `ssh2.d.ts`
 *
 * Because that file has a job, stated in its own header: it is **narrower than
 * the library on purpose**, so that a connection which forgets `hostVerifier`
 * does not compile. Nothing here belongs to the app's transport, and mixing the
 * two would leave the next reader unable to tell which declarations are load
 * bearing. Ambient module declarations merge, so `ssh2` ends up with both
 * halves and neither file has to know about the other.
 *
 * **Nothing in the app may import any of this.** `host-key-checked.test.ts`
 * enforces that structurally — only `connection.ts` and `credentials.ts` may
 * name the library at all — and a `.test.ts` is outside what it scans, which is
 * exactly the line this file sits on.
 */

declare module 'ssh2' {
  import type { Duplex } from 'node:stream'

  /** What a client asked to be connected to, as the server is told it. */
  export interface TcpipRequest {
    destIP: string
    destPort: number
    srcIP: string
    srcPort: number
  }

  /** One client's side of a server. Only the events the test answers are here. */
  export interface ServerConnection {
    on(
      event: 'authentication',
      listener: (context: { accept(): void; reject(): void }) => void,
    ): this
    /**
     * A request to carry a TCP connection, which is what `forwardOut` sends.
     *
     * A server with **no listener for this** rejects the channel with
     * `ADMINISTRATIVELY_PROHIBITED` — the identical wire answer OpenSSH gives
     * when `AllowTcpForwarding` is off, read out of `lib/server.js` and then
     * measured. That is what lets the test exercise a hardened server without
     * touching anybody's settings.
     *
     * `reject()` taken while a listener *is* attached answers `CONNECT_FAILED`
     * instead, which is the server saying it tried and nothing was there.
     */
    on(
      event: 'tcpip',
      listener: (accept: () => Duplex, reject: () => void, info: TcpipRequest) => void,
    ): this
  }

  export class Server {
    constructor(
      config: { hostKeys: Array<string | Buffer> },
      onConnection: (client: ServerConnection) => void,
    )
    listen(port: number, host: string, onListening: () => void): this
    address(): { port: number } | string | null
    close(callback?: () => void): this
  }
}
