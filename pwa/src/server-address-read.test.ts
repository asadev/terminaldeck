import { describe, expect, it } from 'vitest'
import { MAX_ADDRESS_LENGTH, readServerAddress } from './server-address'

/**
 * The paste that starts a sign-in, read every way a machine might have printed
 * it and refused every way it can be wrong.
 *
 * The point of these is not the encodings. It is that **one** decision — is this
 * a usable relay endpoint — is made by `asEndpoint` and by nothing else, so a
 * host id in the wrong alphabet or a key that is thirty-one bytes is refused
 * here for exactly the same reason it is refused coming back out of storage.
 * Every fixture below is built from the three facts rather than pasted as a
 * literal, so a fixture cannot drift into being valid on its own.
 */

const RELAY = 'wss://relay.terminaldeck.dev'
const HOST_ID = 'ABCDEFGHJKLMNPQRSTUVWXYZ23'

/** Thirty-two bytes whose standard base64 contains both `+` and `/`. */
const KEY_BYTES = Buffer.from([0xfb, 0xff, 0x3e, 0x3f, ...Array.from({ length: 28 }, (_, at) => at)])
const KEY = KEY_BYTES.toString('base64')
const KEY_URL = KEY.replace(/\+/g, '-').replace(/\//g, '_')

const ADDRESS = { kind: 'relay', url: RELAY, hostId: HOST_ID, hostKey: KEY }
const JSON_TEXT = JSON.stringify(ADDRESS)
const BLOB = Buffer.from(JSON_TEXT, 'utf8').toString('base64')

/** The endpoint every reading below has to land on. */
function expectFound(raw: string): void {
  const read = readServerAddress(raw)
  expect(read.ok, `did not read: ${raw.slice(0, 60)}`).toBe(true)
  if (!read.ok) throw new Error('unreachable')
  expect(read.endpoint.url).toBe(RELAY)
  expect(read.endpoint.hostId).toBe(HOST_ID)
  // The key is kept in whichever alphabet it arrived in — `hostKeyBytes` reads
  // both — so what is asserted is the bytes, not the spelling.
  expect(Buffer.from(read.endpoint.hostKey.replace(/-/g, '+').replace(/_/g, '/'), 'base64')).toEqual(KEY_BYTES)
}

describe('the shapes a printed server address arrives in', () => {
  it('reads the object as plain JSON', () => {
    expectFound(JSON_TEXT)
  })

  it('reads it pretty-printed, which is what a console log looks like', () => {
    expectFound(JSON.stringify(ADDRESS, null, 2))
  })

  it('reads it base64, which is what fits on one line', () => {
    expectFound(BLOB)
  })

  it('reads it base64url, folding the two characters buffer would drop', () => {
    expectFound(BLOB.replace(/\+/g, '-').replace(/\//g, '_'))
  })

  it('reads it with a scheme in front, however the machine spelled one', () => {
    expectFound(`terminaldeck://${BLOB}`)
    expectFound(`terminaldeck:${BLOB}`)
    expectFound(`td1:${BLOB}`)
  })

  it('reads it after a fragment, which is where a link would put it', () => {
    expectFound(`https://terminaldeck.dev/add#${BLOB}`)
  })

  it('reads it through a line wrap, because a terminal wraps at eighty columns', () => {
    const wrapped = `${BLOB.slice(0, 80)}\n${BLOB.slice(80, 160)}\n  ${BLOB.slice(160)}`
    expectFound(wrapped)
  })

  it('reads a query string, in the short spellings and the long ones', () => {
    expectFound(`terminaldeck://server?r=${encodeURIComponent(RELAY)}&h=${HOST_ID}&k=${KEY_URL}`)
    expectFound(
      `terminaldeck://server?relayUrl=${encodeURIComponent(RELAY)}&hostId=${HOST_ID}&hostKey=${encodeURIComponent(KEY)}`,
    )
  })

  it('reads a rendezvous offer verbatim, which spells the key publicKey', () => {
    // `machines/ipc.ts` and `rendezvous.ts` both use this spelling, so a machine
    // that prints its own offer is understood rather than refused for a name.
    expectFound(JSON.stringify({ t: 'machine', relayUrl: RELAY, hostId: HOST_ID, publicKey: KEY, name: 'basil' }))
  })

  it('survives what a copy takes with it', () => {
    expectFound(`  "${JSON_TEXT}"  `)
    expectFound(`<${BLOB}>`)
    expectFound(`\`${BLOB}\``)
  })
})

describe('what is not a server address', () => {
  it('says a blank field is blank rather than wrong', () => {
    // Two faults rather than one, because the sentence differs and so does what
    // the screen should do about it.
    expect(readServerAddress('')).toEqual({ ok: false, fault: 'empty' })
    expect(readServerAddress('   \n  ')).toEqual({ ok: false, fault: 'empty' })
  })

  it('refuses a host id on its own, which is the whole reason this exists', () => {
    // A host id is BASE32(SHA-256(secret)). There is no key in it, and IK cannot
    // start without one — a form that accepted this would have a dead button.
    expect(readServerAddress(HOST_ID).ok).toBe(false)
  })

  it('refuses a host id in the wrong alphabet', () => {
    const confusable = { ...ADDRESS, hostId: 'ABCDEFGHIJKLMNOPQRSTUVWXY0' }
    expect(readServerAddress(JSON.stringify(confusable)).ok).toBe(false)
  })

  it('refuses a key that is not thirty-two bytes', () => {
    const short = { ...ADDRESS, hostKey: KEY_BYTES.subarray(0, 31).toString('base64') }
    expect(readServerAddress(JSON.stringify(short)).ok).toBe(false)
  })

  it('refuses a relay that is not a websocket address', () => {
    expect(readServerAddress(JSON.stringify({ ...ADDRESS, url: 'https://relay.terminaldeck.dev' })).ok).toBe(false)
  })

  it('refuses an address with a fact missing', () => {
    expect(readServerAddress(JSON.stringify({ kind: 'relay', url: RELAY, hostId: HOST_ID })).ok).toBe(false)
    expect(readServerAddress(JSON.stringify({ kind: 'relay', hostId: HOST_ID, hostKey: KEY })).ok).toBe(false)
  })

  it('refuses ordinary prose without reading it as base64', () => {
    expect(readServerAddress('paste your server address here').ok).toBe(false)
    expect(readServerAddress('482913').ok).toBe(false)
  })

  it('refuses a paste too large to be one, rather than truncating it', () => {
    // Truncating would mean saying "that is not an address" about something this
    // client cut in half.
    expect(readServerAddress(`${BLOB}${'A'.repeat(MAX_ADDRESS_LENGTH)}`)).toEqual({ ok: false, fault: 'unreadable' })
  })
})
