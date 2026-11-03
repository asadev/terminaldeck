/**
 * What one heartbeat actually costs, measured rather than remembered.
 *
 * Multi-host keeps every paired machine connected, and every connection needs a
 * keepalive or a carrier NAT reclaims it — so the honest question about the
 * feature is not "does it work" but "what does holding N sockets cost the
 * battery". This answers the half of that question which is a fact about the
 * wire, and it answers it by *running the shipping code*: the Noise handshake
 * from `src/shared/sealed.ts`, the relay envelope from `src/shared/relay-wire.ts`
 * and the frame writers from `src/shared/ws-frame.ts`, with the message built by
 * the protocol module's own `serialize`.
 *
 * It exists because the first version of the numbers in `Heartbeat.swift` and
 * `Heartbeat.kt` were written from memory, and two of them were wrong. A
 * constant nobody can re-derive is a constant that rots.
 *
 *   npx tsx scripts/keepalive-cost.ts
 *
 * The findings, and what they mean for the feature, are in
 * `docs/multi-host-battery.md`.
 */

import { serialize } from '../src/main/remote/protocol'
import { generateStatic, startHandshake, respondToHandshake, finishHandshake } from '../src/shared/sealed'
import { CHANNEL_BYTES, ENVELOPE, encodeEnvelope, withSealedVersion } from '../src/shared/relay-wire'
import { OPCODE, encodeFrame, encodeMaskedFrame } from '../src/shared/ws-frame'

/** The app's tick, and the one both clients use. Keep in step with `Heartbeat`. */
const INTERVAL_SECONDS = 25
const TICKS_PER_HOUR = 3600 / INTERVAL_SECONDS

const host = generateStatic()
const phone = generateStatic()
const start = startHandshake(phone, host.publicKey)
const answered = respondToHandshake(host, start.message, () => true)
const fromPhone = finishHandshake(start.pending, answered.reply)
const fromHost = answered.transport

/** Any 16 bytes: the channel id is fixed-width, so its contents cannot change a size. */
const channel = Buffer.alloc(CHANNEL_BYTES, 7)

/** Phone → host. A WebSocket client always masks, which costs four bytes. */
function outbound(json: string): number {
  const sealed = withSealedVersion(fromPhone.sendText(json))
  return encodeMaskedFrame(OPCODE.binary, encodeEnvelope(ENVELOPE.data, channel, sealed)).length
}

/** Host → phone. A server never masks. */
function inbound(json: string): number {
  const sealed = withSealedVersion(fromHost.sendText(json))
  return encodeFrame(OPCODE.binary, encodeEnvelope(ENVELOPE.data, channel, sealed)).length
}

const ping = serialize({ t: 'ping' })
const pong = serialize({ t: 'pong' })
const pingBytes = outbound(ping)
const pongBytes = inbound(pong)
const roundTrip = pingBytes + pongBytes

const say = (line: string): void => process.stdout.write(`${line}\n`)

say(`ping   ${ping}   ${Buffer.byteLength(ping)} B of JSON   → ${pingBytes} B on the wire`)
say(`pong   ${pong}   ${Buffer.byteLength(pong)} B of JSON   → ${pongBytes} B on the wire`)
say(`round trip: ${roundTrip} B per host per tick`)
say('')
say(`one shared ${INTERVAL_SECONDS}s tick, ${TICKS_PER_HOUR} ticks an hour:`)
say('  hosts    kB/hour    radio windows/h shared    unshared (one timer each)')
for (const hosts of [1, 2, 3, 5]) {
  const perHour = ((roundTrip * TICKS_PER_HOUR * hosts) / 1000).toFixed(1)
  say(
    `  ${String(hosts).padStart(5)}    ${perHour.padStart(7)}    ${String(TICKS_PER_HOUR).padStart(22)}` +
      `    ${String(TICKS_PER_HOUR * hosts).padStart(8)}`,
  )
}
