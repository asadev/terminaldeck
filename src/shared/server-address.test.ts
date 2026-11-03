import { describe, expect, it } from 'vitest'
import { DEFAULT_RELAY_URL } from './relay-wire'
import {
  ADDRESS_IS_NOT_A_SECRET,
  SERVER_ADDRESS_PREFIX,
  asServerAddress,
  formatServerAddress,
  hostKeyBytes,
  isServerAddress,
  parseServerAddress,
} from './server-address'

/** A host id in the relay's alphabet — 26 characters, no 0/O or 1/I. */
const HOST_ID = 'ABCDEFGHJKLMNPQRSTUVWXYZ2'.concat('3')

/** Thirty-two bytes, so the key is a key rather than a plausible-looking string. */
const KEY = Buffer.alloc(32, 7)

const PARTS = {
  url: DEFAULT_RELAY_URL,
  hostId: HOST_ID,
  hostKey: KEY.toString('base64url'),
}

describe('the fixtures this file argues from', () => {
  it('uses a host id and a key the validators would accept anyway', () => {
    expect(HOST_ID).toHaveLength(26)
    expect(hostKeyBytes(PARTS.hostKey)).toEqual(KEY)
  })
})

describe('an address a host prints', () => {
  it('round-trips the three facts a first connection needs', () => {
    const address = formatServerAddress(PARTS)
    expect(address).not.toBeNull()
    expect(parseServerAddress(address as string)).toEqual({
      kind: 'relay',
      url: DEFAULT_RELAY_URL,
      hostId: HOST_ID,
      hostKey: PARTS.hostKey,
    })
  })

  it('is one token with nothing in it a paste can break', () => {
    const address = formatServerAddress(PARTS) as string
    // No whitespace, no quoting, no characters a shell or a chat window would
    // eat: the whole point is that this survives being moved by hand.
    expect(address).toMatch(/^srv1\.[A-Za-z0-9_-]+$/)
    expect(address.startsWith(SERVER_ADDRESS_PREFIX)).toBe(true)
  })

  it('survives the whitespace a real paste arrives with', () => {
    const address = formatServerAddress(PARTS) as string
    expect(parseServerAddress(`  ${address}\n`)).toEqual(parseServerAddress(address))
  })

  it('is the same string for the same machine, whichever alphabet its key arrived in', () => {
    // `RelayState.publicKey` is base64url and a rendezvous offer spells the same
    // 32 bytes in standard base64. One machine, one address.
    const standard = formatServerAddress({ ...PARTS, hostKey: KEY.toString('base64') })
    expect(standard).toBe(formatServerAddress(PARTS))
  })
})

describe('an address a host cannot print', () => {
  it('is null rather than a broken string when there is no relay URL', () => {
    expect(formatServerAddress({ ...PARTS, url: '' })).toBeNull()
    expect(formatServerAddress({ ...PARTS, url: 'https://relay.example' })).toBeNull()
  })

  it('is null when the host id is not one', () => {
    expect(formatServerAddress({ ...PARTS, hostId: '' })).toBeNull()
    // `0` and `1` are the two characters the relay's base32 leaves out.
    expect(formatServerAddress({ ...PARTS, hostId: `0${HOST_ID.slice(1)}` })).toBeNull()
  })

  it('is null when the key is not thirty-two bytes', () => {
    expect(formatServerAddress({ ...PARTS, hostKey: '' })).toBeNull()
    expect(formatServerAddress({ ...PARTS, hostKey: Buffer.alloc(31, 7).toString('base64url') })).toBeNull()
  })
})

describe('an address that arrives damaged', () => {
  const address = formatServerAddress(PARTS) as string

  it('refuses a token whose tail was left behind by a selection', () => {
    // The failure this whole check exists for: base64 decoding *ignores* what it
    // does not recognise and shortening the body still decodes to something, so
    // without the re-encode comparison this would parse into an endpoint that
    // dials nothing.
    expect(parseServerAddress(address.slice(0, address.length - 6))).toBeNull()
  })

  it('refuses a token a line wrap put a character into', () => {
    expect(parseServerAddress(`${address}*`)).toBeNull()
    expect(parseServerAddress(`${address.slice(0, 20)} ${address.slice(20)}`)).toBeNull()
  })

  it('refuses anything that is not this format', () => {
    expect(parseServerAddress('')).toBeNull()
    expect(parseServerAddress(HOST_ID)).toBeNull()
    expect(parseServerAddress('wss://relay.example')).toBeNull()
    // A future version is refused outright rather than half-read: the prefix is
    // there so a v2 address cannot be parsed into a v1 endpoint.
    expect(parseServerAddress(address.replace('srv1.', 'srv2.'))).toBeNull()
    expect(parseServerAddress(`srv1.${'A'.repeat(5000)}`)).toBeNull()
  })

  it('refuses a well-formed token carrying something that is not an address', () => {
    const wrap = (value: unknown): string =>
      `${SERVER_ADDRESS_PREFIX}${Buffer.from(JSON.stringify(value), 'utf8')
        .toString('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '')}`

    expect(parseServerAddress(wrap({ kind: 'direct' }))).toBeNull()
    expect(parseServerAddress(wrap([PARTS]))).toBeNull()
    expect(parseServerAddress(wrap({ kind: 'relay', ...PARTS, hostKey: 'not-a-key' }))).toBeNull()
    expect(parseServerAddress(wrap('a string'))).toBeNull()
  })

  it('answers the same question through isServerAddress', () => {
    expect(isServerAddress(address)).toBe(true)
    expect(isServerAddress('srv1.')).toBe(false)
  })
})

describe('what the format promises about itself', () => {
  it('narrows an already-decoded value the same way', () => {
    expect(asServerAddress({ kind: 'relay', ...PARTS })).toEqual(parseServerAddress(formatServerAddress(PARTS) as string))
    expect(asServerAddress(null)).toBeNull()
  })

  it('says out loud that it is not a secret, because it looks like one', () => {
    expect(ADDRESS_IS_NOT_A_SECRET).toContain('not a secret')
    // The gate, named. Somebody who reads only this sentence still knows what
    // stops a stranger who has the address.
    expect(ADDRESS_IS_NOT_A_SECRET).toContain('login')
  })

  it('names the product nowhere in the format itself', () => {
    // Against a relay that is not the default one, because the default URL is a
    // *domain* — a fact about where the service is, which of course carries the
    // name. What must not carry it is the envelope: the prefix, the field names,
    // the version. A rename is then a change to `brand.ts` and not an invalidation
    // of every address ever printed.
    const elsewhere = formatServerAddress({ ...PARTS, url: 'wss://relay.example.org' }) as string
    const json = Buffer.from(
      elsewhere.slice(SERVER_ADDRESS_PREFIX.length).replace(/-/g, '+').replace(/_/g, '/'),
      'base64',
    ).toString('utf8')
    expect(json.toLowerCase()).not.toContain('terminaldeck')
    expect(SERVER_ADDRESS_PREFIX.toLowerCase()).not.toContain('deck')
  })
})
