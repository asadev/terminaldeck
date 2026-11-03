/**
 * Tests for the sealed channel.
 *
 * Crypto is the one place in this repo where "it worked when I tried it" is
 * worth nothing: a handshake that derives the wrong keys fails loudly, but one
 * that derives *weak* keys, reuses a nonce or accepts an unpaired device passes
 * every happy-path test ever written. So most of what follows is attacks, and
 * the happy path is four lines.
 *
 * Each `expect(...).toThrow()` below is a specific thing an attacker would try.
 */

import { describe, expect, it } from 'vitest'
import {
  NOISE_NAME,
  SEALED_VERSION,
  fingerprint,
  finishHandshake,
  generateStatic,
  respondToHandshake,
  secretBytes,
  startHandshake,
} from './sealed'

/** A paired pair: a Mac and a device that knows its public key. */
function paired() {
  const mac = generateStatic()
  const device = generateStatic()
  const known = (key: Buffer) => key.equals(device.publicKey)
  return { mac, device, known }
}

/** Runs a full handshake and hands back both ends. */
function connect() {
  const { mac, device, known } = paired()
  const started = startHandshake(device, mac.publicKey)
  const answered = respondToHandshake(mac, started.message, known)
  const client = finishHandshake(started.pending, answered.reply)
  return { mac, device, known, client, server: answered.transport, answered }
}

describe('key generation', () => {
  it('produces raw 32-byte X25519 keys, not DER', () => {
    const { publicKey, privateKey } = generateStatic()
    expect(publicKey).toHaveLength(32)
    expect(privateKey).toHaveLength(32)
  })

  it('never repeats a key', () => {
    const keys = new Set(Array.from({ length: 50 }, () => generateStatic().publicKey.toString('hex')))
    expect(keys.size).toBe(50)
  })
})

describe('handshake', () => {
  it('agrees on keys and talks both ways', () => {
    const { client, server } = connect()
    expect(server.receiveText(client.sendText('ls -la'))).toBe('ls -la')
    expect(client.receiveText(server.sendText('total 0\r\n'))).toBe('total 0\r\n')
  })

  it('tells the responder which device authenticated', () => {
    const { device, answered } = connect()
    expect(answered.devicePublicKey.equals(device.publicKey)).toBe(true)
  })

  it('derives the same channel binding on both ends', () => {
    const { client, server } = connect()
    expect(client.channelBinding.equals(server.channelBinding)).toBe(true)
    expect(client.channelBinding).toHaveLength(32)
  })

  it('hides the device identity from anyone watching the wire', () => {
    const { mac, device } = paired()
    const { message } = startHandshake(device, mac.publicKey)
    // The static key is sent encrypted, so it must not appear in the clear.
    expect(message.includes(device.publicKey)).toBe(false)
  })

  it('gives two connections between the same pair different keys', () => {
    const { mac, device, known } = paired()
    const first = startHandshake(device, mac.publicKey)
    const second = startHandshake(device, mac.publicKey)
    const a = respondToHandshake(mac, first.message, known)
    const b = respondToHandshake(mac, second.message, known)
    // Forward secrecy in observable form: same identities, different sessions.
    expect(a.transport.channelBinding.equals(b.transport.channelBinding)).toBe(false)
  })
})

describe('handshake refusals', () => {
  it('refuses a device it has never paired with', () => {
    const { mac } = paired()
    const stranger = generateStatic()
    const { message } = startHandshake(stranger, mac.publicKey)
    expect(() => respondToHandshake(mac, message, () => false)).toThrow(/authentication/)
  })

  it('refuses a device whose static key was swapped for another paired one', () => {
    const { mac, device } = paired()
    const other = generateStatic()
    const { message } = startHandshake(other, mac.publicKey)
    // Even a callback that trusts everything cannot rescue it: the encrypted
    // static key is bound to the transcript, so `device` cannot be substituted.
    const answered = respondToHandshake(mac, message, () => true)
    expect(answered.devicePublicKey.equals(device.publicKey)).toBe(false)
    expect(answered.devicePublicKey.equals(other.publicKey)).toBe(true)
  })

  it('refuses a handshake aimed at a different Mac', () => {
    const { device } = paired()
    const intended = generateStatic()
    const impostor = generateStatic()
    const { message } = startHandshake(device, intended.publicKey)
    expect(() => respondToHandshake(impostor, message, () => true)).toThrow(/authentication/)
  })

  it('refuses a tampered handshake message', () => {
    const { mac, device, known } = paired()
    const { message } = startHandshake(device, mac.publicKey)
    for (const index of [0, 31, 32, message.length - 1]) {
      const bent = Buffer.from(message)
      bent[index] ^= 0x01
      expect(() => respondToHandshake(mac, bent, known)).toThrow()
    }
  })

  it('refuses handshake messages of the wrong length', () => {
    const { mac, device, known } = paired()
    const { message } = startHandshake(device, mac.publicKey)
    expect(() => respondToHandshake(mac, message.subarray(0, 60), known)).toThrow(/length/)
    expect(() => respondToHandshake(mac, Buffer.concat([message, Buffer.alloc(1)]), known)).toThrow(
      /length/,
    )
  })

  it('refuses an all-zero ephemeral key (low-order point)', () => {
    const { mac, device, known } = paired()
    const { message } = startHandshake(device, mac.publicKey)
    const zeroed = Buffer.concat([Buffer.alloc(32), message.subarray(32)])
    expect(() => respondToHandshake(mac, zeroed, known)).toThrow(/low-order|authentication/)
  })

  it('refuses a forged reply to the initiator', () => {
    const { mac, device, known } = paired()
    const started = startHandshake(device, mac.publicKey)
    const answered = respondToHandshake(mac, started.message, known)
    const bent = Buffer.from(answered.reply)
    bent[bent.length - 1] ^= 0x01
    expect(() => finishHandshake(started.pending, bent)).toThrow(/authentication/)
  })

  it('refuses a reply from a Mac that does not hold the static key', () => {
    const { mac, device, known } = paired()
    const started = startHandshake(device, mac.publicKey)
    const impostor = generateStatic()
    // The impostor answers a handshake it could not decrypt, so it must guess.
    const forged = respondToHandshake(impostor, startHandshake(device, impostor.publicKey).message, known)
    expect(() => finishHandshake(started.pending, forged.reply)).toThrow(/authentication/)
  })

  it('refuses a reply of the wrong length', () => {
    const { mac, device, known } = paired()
    const started = startHandshake(device, mac.publicKey)
    const answered = respondToHandshake(mac, started.message, known)
    expect(() => finishHandshake(started.pending, answered.reply.subarray(0, 40))).toThrow(/length/)
  })
})

describe('transport', () => {
  it('keeps order across many messages', () => {
    const { client, server } = connect()
    for (let i = 0; i < 200; i += 1) {
      expect(server.receiveText(client.sendText(`line ${i}`))).toBe(`line ${i}`)
    }
  })

  it('produces different ciphertext for the same plaintext', () => {
    const { client } = connect()
    const first = client.send(Buffer.from('same'))
    const second = client.send(Buffer.from('same'))
    // Equal ciphertexts would mean a repeated nonce, which is the whole game.
    expect(first.equals(second)).toBe(false)
  })

  it('refuses a replayed frame', () => {
    const { client, server } = connect()
    const frame = client.sendText('whoami')
    expect(server.receiveText(frame)).toBe('whoami')
    expect(() => server.receive(frame)).toThrow(/authentication/)
  })

  it('refuses a reordered frame', () => {
    const { client, server } = connect()
    const first = client.sendText('one')
    const second = client.sendText('two')
    expect(() => server.receive(second)).toThrow(/authentication/)
    // And the counter did not advance on the failure, so the real next frame
    // still opens. A forged frame must not desynchronise an honest connection.
    expect(server.receiveText(first)).toBe('one')
    expect(server.receiveText(second)).toBe('two')
  })

  it('refuses a frame with a flipped bit anywhere', () => {
    const { client, server } = connect()
    const frame = client.sendText('rm -rf /')
    for (let index = 0; index < frame.length; index += 1) {
      const bent = Buffer.from(frame)
      bent[index] ^= 0x80
      expect(() => server.receive(bent)).toThrow(/authentication/)
    }
  })

  it('refuses a truncated frame', () => {
    const { client, server } = connect()
    const frame = client.sendText('hello')
    expect(() => server.receive(frame.subarray(0, frame.length - 1))).toThrow(/authentication/)
    expect(() => server.receive(Buffer.alloc(0))).toThrow(/authentication/)
  })

  it('does not let the other direction decrypt its own traffic', () => {
    const { client, server } = connect()
    const frame = client.sendText('secret')
    // Keys are directional. A client frame must be opaque to another client.
    expect(() => client.receive(frame)).toThrow(/authentication/)
    expect(server.receiveText(frame)).toBe('secret')
  })

  it('carries binary and large payloads unchanged', () => {
    const { client, server } = connect()
    const big = secretBytes(64 * 1024)
    expect(server.receive(client.send(big)).equals(big)).toBe(true)
    expect(server.receive(client.send(Buffer.alloc(0))).length).toBe(0)
  })

  it('adds only the authentication tag to the payload size', () => {
    const { client } = connect()
    expect(client.send(Buffer.alloc(100))).toHaveLength(116)
  })
})

describe('fingerprints', () => {
  it('is stable for a key and different across keys', () => {
    const a = generateStatic().publicKey
    const b = generateStatic().publicKey
    expect(fingerprint(a)).toBe(fingerprint(a))
    expect(fingerprint(a)).not.toBe(fingerprint(b))
  })

  it('reads aloud without ambiguous characters', () => {
    for (let i = 0; i < 30; i += 1) {
      const value = fingerprint(generateStatic().publicKey)
      expect(value).toMatch(/^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4})*$/)
      expect(value).not.toMatch(/[01OI]/)
    }
  })
})

describe('protocol identity', () => {
  it('names the exact suite, so a mismatched client cannot negotiate down', () => {
    expect(NOISE_NAME).toBe('Noise_IK_25519_ChaChaPoly_SHA256')
    expect(SEALED_VERSION).toBe(1)
  })
})
