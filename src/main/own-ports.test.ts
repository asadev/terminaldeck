import { createServer, type Server } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { claimOwnPort, ownPorts, releaseOwnPort, resetOwnPortsForTests } from './own-ports'
import { createTunnelHub, type TunnelPort } from './remote/tunnel'
import type { ServerMessage } from './remote/protocol'

/**
 * The app's own loopback listeners, and the tunnel that must not offer them.
 *
 * `remote/tunnel.ts` lets a paired phone tap any loopback port something on this
 * machine is serving. That is the feature. What it must never offer is one of
 * *our* control planes — `deck-control`, which is the copilot's whole tool
 * surface, and `hook-server`, where the agent CLIs report. Both sit on loopback
 * behind a bearer token, and neither should be resting on that token to decide
 * who may reach it: a phone that got one would be driving the copilot with no
 * per-device grant consulted and every call logged as `local`.
 *
 * Against a **real socket**, like `tunnel.test.ts` and for the reason stated
 * there. The same real port is used for both halves and the only thing that
 * changes between them is whether it has been claimed, so nothing here can pass
 * by testing a different port than it refused.
 */

const started: Server[] = []

afterEach(async () => {
  resetOwnPortsForTests()
  await Promise.all(
    started.splice(0).map((server) => new Promise<void>((settle) => server.close(() => settle()))),
  )
})

/** A real loopback server on a port the OS picked. */
async function listen(): Promise<number> {
  const server = createServer((socket) => socket.end())
  started.push(server)
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', () => settle()))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  return address.port
}

function hub(port: number, sent: ServerMessage[]) {
  const scanned: TunnelPort[] = [
    { port, process: 'Terminal Deck', guessed: false, families: { v4: true, v6: false } },
  ]
  return createTunnelHub({
    scan: async () => scanned,
    send: (message) => sent.push(message),
    // Read at hub construction, exactly as `remote/server.ts` does when a phone
    // connects: `[...options.reservedPorts, ...ownPorts()]`.
    reserved: ownPorts(),
  })
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 50))
}

describe('the registry', () => {
  it('remembers a claim and forgets a release', () => {
    claimOwnPort(4567)
    expect(ownPorts()).toEqual([4567])
    releaseOwnPort(4567)
    // Released rather than left: the number goes back to the OS when a server
    // stops, and a stale claim would refuse somebody a tunnel to whatever gets
    // it next.
    expect(ownPorts()).toEqual([])
  })

  it('ignores a port that is not one', () => {
    claimOwnPort(0)
    claimOwnPort(-1)
    claimOwnPort(1.5)
    expect(ownPorts()).toEqual([])
  })
})

describe('a phone is not offered this app’s own ports', () => {
  it('leaves a claimed port out of the list it sends', async () => {
    const port = await listen()
    const sent: ServerMessage[] = []
    claimOwnPort(port)

    hub(port, sent).handle({ t: 'ports' })
    await settle()

    const ports = sent.find((message) => message.t === 'ports')
    expect(ports).toBeDefined()
    expect((ports as { ports: Array<{ port: number }> }).ports).toEqual([])
  })

  it('refuses to dial one even when the phone names it directly', async () => {
    // The half that matters. A phone that already knows the number — because it
    // saw the port before this landed, or guessed — is still refused.
    const port = await listen()
    const sent: ServerMessage[] = []
    claimOwnPort(port)

    hub(port, sent).handle({ t: 'tunnel.open', id: 't1', port })
    await settle()

    expect(sent.some((message) => message.t === 'tunnel.opened')).toBe(false)
    expect(sent.find((message) => message.t === 'tunnel.closed')).toBeDefined()
  })

  it('still opens a tunnel to the very same port when it is somebody else’s', async () => {
    /*
     * The positive control, and it is the assertion that stops this from being
     * satisfiable by breaking the feature. Same port, same scan, same hub — the
     * only difference is the claim.
     */
    const port = await listen()
    const sent: ServerMessage[] = []

    hub(port, sent).handle({ t: 'tunnel.open', id: 't2', port })
    await settle()

    expect(sent.some((message) => message.t === 'tunnel.opened')).toBe(true)
  })
})
