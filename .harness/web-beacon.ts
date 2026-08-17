/**
 * Answer a six-digit code on the live relay, on behalf of the harness host.
 *
 * `scripts/remote-host.sh` runs the desktop's real remote endpoint against a
 * relay and mints pairing codes — but it does not run a **beacon**, the thing
 * that makes a typed code *findable*. On a real desktop that is `startBeacon`,
 * started when the code goes on screen and stopped when it is spent; without one
 * the browser client's `lookupMachine` finds nothing and quietly falls back to
 * the direct route, which is not the path anybody wanted tested.
 *
 * So this is the missing half of the harness and nothing more. `startBeacon` and
 * `MachineOffer` are the app's own — the same function the Machines screen calls
 * — and the only thing written here is the plumbing that hands it the host id
 * and key that `scripts/remote-host.sh` already printed to its control port.
 *
 *   npx tsx .harness/web-beacon.ts --control 8878 --relay wss://relay.terminaldeck.dev
 *
 * It prints the six digits and then holds the slot until it is killed.
 */

import { startBeacon, type MachineOffer } from '../src/main/remote/machines/rendezvous'

const args = process.argv.slice(2)
const flag = (name: string, fallback: string): string => {
  const at = args.indexOf(`--${name}`)
  return at === -1 || at + 1 >= args.length ? fallback : args[at + 1]
}

const control = flag('control', '8878')
const relayUrl = flag('relay', 'wss://relay.terminaldeck.dev')

interface HarnessState {
  hostId: string
  relay: { url: string; hostId: string; publicKey: string; connected: boolean }
}

async function main(): Promise<number> {
  const state = (await (await fetch(`http://127.0.0.1:${control}/state`)).json()) as HarnessState
  if (!state.relay.connected) {
    process.stderr.write('The harness host has not reached the relay yet.\n')
    return 1
  }

  // `/pair` answers with the whole `terminaldeck://` URI the harness prints; the
  // six digits are its `t` parameter. Minting immediately before use, because a
  // token is worth sixty seconds and one redemption.
  const minted = (await (await fetch(`http://127.0.0.1:${control}/pair`)).json()) as { uri: string }
  const code = new URL(minted.uri.replace('terminaldeck://', 'https://')).searchParams.get('t') ?? ''

  const offer: MachineOffer = {
    relayUrl: state.relay.url,
    hostId: state.relay.hostId,
    // `RelayState` publishes base64url because it goes into a URL; the offer is
    // JSON inside a sealed frame and `parseOffer` decodes plain base64. The same
    // re-encoding `offerFrom` does, for the same reason.
    publicKey: Buffer.from(state.relay.publicKey, 'base64url').toString('base64'),
    name: 'Harness host',
    platform: process.platform,
  }

  const beacon = startBeacon({ code, offer, relayUrl })
  if (beacon === null) {
    process.stderr.write(`"${code}" is not a pairing code.\n`)
    return 1
  }
  const ready = await beacon.ready()
  process.stdout.write(`${ready ? 'ready' : 'not-ready'} ${code}\n`)
  if (!ready) {
    beacon.stop()
    return 1
  }
  // Held until killed. The code is spent by the first guest that redeems it, but
  // the slot staying claimed is what lets a run be repeated without re-minting.
  process.on('SIGINT', () => {
    beacon.stop()
    process.exit(0)
  })
  await new Promise(() => undefined)
  return 0
}

void main().then((code) => {
  if (code !== 0) process.exit(code)
})
