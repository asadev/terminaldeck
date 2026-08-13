import { describe, expect, it } from 'vitest'
import {
  chooseRoute,
  directPairingLink,
  isHostId,
  isHostKey,
  isPairingToken,
  isRelayUrl,
  MAX_TOKEN_LENGTH,
  pairingPaths,
  pairingRoutes,
  relayPairingLink,
} from './pairing-link'

/**
 * The link, checked the way the things that read it will read it.
 *
 * Nothing in this repository's test suite runs the iOS or Android parser, so a
 * desktop that emits a link neither of them accepts would pass every test here
 * and fail on the first phone. The two readers below are those parsers'
 * *mechanisms* rather than their code: the iOS one reads
 * `URLComponents.queryItems`, which is a query and never a fragment, and the
 * Android one splits on `#` first and `?` second and percent-decodes by hand.
 * Anything this file emits has to survive both, and the point of writing them
 * out is that a change to the shape breaks here rather than in an app store.
 */

const HOST_ID = 'AXGK7VAEYZHKTTVUKZ4U9HZQ7J'
const HOST_KEY = 'Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhmb29iYXI'
const RELAY = 'wss://relay.terminaldeck.dev'
const TOKEN = 'Kf3-9_aZ4tQxLm2Nv8Rw0Yb6Sd1Hg5Jc7Pe3Uk9Zn2A'

const IDENTITY = { url: RELAY, hostId: HOST_ID, publicKey: HOST_KEY }

/** What `URLComponents(url:).queryItems` gives the Swift parser. */
function readAsIos(link: string): Record<string, string> | null {
  const url = new URL(link)
  if (url.protocol !== 'terminaldeck:') return null
  // `terminaldeck://pair?…` parses with "pair" as the host.
  if (url.host !== 'pair') return null
  return Object.fromEntries(url.searchParams)
}

/** What `PairingCodes.parse` in Kotlin does: fragment, else query, else bare. */
function readAsAndroid(link: string): Record<string, string> | null {
  const body =
    link.split('#').slice(1).join('#') ||
    link.split('?').slice(1).join('?') ||
    (link.includes('=') ? link : '')
  if (body === '') return null
  const params: Record<string, string> = {}
  for (const pair of body.split('&')) {
    const at = pair.indexOf('=')
    if (at <= 0) continue
    const name = pair.slice(0, at)
    // A repeated parameter is not a link we wrote.
    if (name in params) return null
    params[name] = decodeURIComponent(pair.slice(at + 1).replace(/\+/g, ' '))
  }
  return params
}

describe('the relay link', () => {
  const link = relayPairingLink(IDENTITY, TOKEN)

  it('is a deep link into this app, not an address a browser would open', () => {
    // A phone with no app installed must fail at "nothing handles this link"
    // rather than at a web page that cannot pair.
    expect(link).toMatch(/^terminaldeck:\/\/pair\?/)
  })

  it('carries where to knock, who will answer, and the one-time token', () => {
    const parsed = readAsIos(link ?? '')
    expect(parsed).toEqual({ v: '1', r: RELAY, h: HOST_ID, k: HOST_KEY, t: TOKEN })
  })

  it('reads the same through the other client’s parser', () => {
    // The two disagree about where parameters live — iOS reads a query, Android
    // prefers a fragment — and this is the shape that satisfies both.
    expect(readAsAndroid(link ?? '')).toEqual(readAsIos(link ?? ''))
  })

  it('percent-encodes the relay address rather than leaving `://` raw in a query', () => {
    expect(link).toContain('r=wss%3A%2F%2Frelay.terminaldeck.dev')
  })

  it('leaves base64url alone, because encoding it would change the key', () => {
    const key = 'ab-de_ghijklmnopqrstuvwxyz0123456789ABCDEF_'
    expect(relayPairingLink({ ...IDENTITY, publicKey: key }, TOKEN)).toContain(`k=${key}`)
  })

  it('is null rather than half a link when a part cannot be one', () => {
    // Every one of these would scan, parse on the phone, and fail with a
    // sentence about a machine that does not exist.
    expect(relayPairingLink({ ...IDENTITY, hostId: '' }, TOKEN)).toBeNull()
    expect(relayPairingLink({ ...IDENTITY, hostId: `${HOST_ID}A` }, TOKEN)).toBeNull()
    expect(relayPairingLink({ ...IDENTITY, hostId: HOST_ID.replace('A', '0') }, TOKEN)).toBeNull()
    expect(relayPairingLink({ ...IDENTITY, publicKey: '' }, TOKEN)).toBeNull()
    expect(relayPairingLink({ ...IDENTITY, publicKey: HOST_KEY.slice(0, 20) }, TOKEN)).toBeNull()
    expect(relayPairingLink({ ...IDENTITY, url: 'https://relay.example' }, TOKEN)).toBeNull()
    expect(relayPairingLink(IDENTITY, '')).toBeNull()
    expect(relayPairingLink(IDENTITY, 'two words')).toBeNull()
  })

  it('accepts the loopback relay the client allows, so that path stays testable', () => {
    expect(relayPairingLink({ ...IDENTITY, url: 'ws://127.0.0.1:8788' }, TOKEN)).toContain(
      'r=ws%3A%2F%2F127.0.0.1%3A8788',
    )
  })
})

describe('the tailnet link', () => {
  it('names the parameter, because the PWA reads the fragment as a query string', () => {
    // A bare `#<token>` arrives in `readPairToken` as a parameter *name* with no
    // value, and reads as no token at all — the QR scans and the phone shows
    // the pair screen as if nothing had been read.
    expect(directPairingLink('https://host.ts.net', 'abc')).toBe('https://host.ts.net/#t=abc')
    expect(directPairingLink('https://host.ts.net/', 'abc')).toBe('https://host.ts.net/#t=abc')
    expect(directPairingLink('https://host.ts.net:8443/', 'abc')).toBe(
      'https://host.ts.net:8443/#t=abc',
    )
  })

  it('replaces an existing fragment rather than nesting one inside it', () => {
    // Two hashes would make the token part of the first one's value, and the
    // phone would send a token that is not the token.
    expect(directPairingLink('https://host.ts.net/#stale', 'abc')).toBe(
      'https://host.ts.net/#t=abc',
    )
  })

  it('escapes the token, so a `+` in one never arrives as a space', () => {
    expect(directPairingLink('https://host.ts.net', 'a+b')).toBe('https://host.ts.net/#t=a%2Bb')
  })

  it('is null for anything that is not an address a phone can open', () => {
    expect(directPairingLink('', 'abc')).toBeNull()
    expect(directPairingLink('host.ts.net', 'abc')).toBeNull()
    expect(directPairingLink('wss://host.ts.net', 'abc')).toBeNull()
    expect(directPairingLink('https://host.ts.net', '')).toBeNull()
  })
})

describe('the pieces', () => {
  it('knows a host id from something that only looks like one', () => {
    expect(isHostId(HOST_ID)).toBe(true)
    // No `0`/`O` and no `1`/`I` in the alphabet: they are the two pairs a person
    // reading a code off a screen gets wrong.
    expect(isHostId(HOST_ID.replace('A', 'I'))).toBe(false)
    expect(isHostId(HOST_ID.toLowerCase())).toBe(false)
    expect(isHostId(HOST_ID.slice(1))).toBe(false)
  })

  it('takes a 32-byte key with or without its padding, and nothing else', () => {
    expect(isHostKey(HOST_KEY)).toBe(true)
    expect(isHostKey(`${HOST_KEY}=`)).toBe(true)
    expect(isHostKey(`${HOST_KEY}AA`)).toBe(false)
    expect(isHostKey(HOST_KEY.replace('Z', '+'))).toBe(false)
  })

  it('takes only a WebSocket address for the relay', () => {
    expect(isRelayUrl(RELAY)).toBe(true)
    expect(isRelayUrl('ws://127.0.0.1:8788')).toBe(true)
    expect(isRelayUrl('https://relay.terminaldeck.dev')).toBe(false)
    expect(isRelayUrl('wss://')).toBe(false)
  })

  it('bounds the token without pinning its alphabet', () => {
    // What a token looks like belongs to `device-auth.ts`; a charset check here
    // would be this panel refusing a token the main process had just minted.
    expect(isPairingToken('a'.repeat(MAX_TOKEN_LENGTH))).toBe(true)
    expect(isPairingToken('a'.repeat(MAX_TOKEN_LENGTH + 1))).toBe(false)
    expect(isPairingToken('abc.def-ghi_jkl')).toBe(true)
    expect(isPairingToken('')).toBe(false)
    expect(isPairingToken('abc def')).toBe(false)
    expect(isPairingToken('abc\tdef')).toBe(false)
    expect(isPairingToken(`abc${String.fromCharCode(0)}def`)).toBe(false)
  })
})

describe('which route a code is offered on', () => {
  const relay = { ...IDENTITY, connected: true }
  const url = 'https://mac.tailnet.ts.net:8443'

  it('offers the relay first, because the code is the endpoint the phone keeps', () => {
    // Pair over the tailnet and the phone reaches this Mac from the tailnet and
    // nowhere else, which is a surprise waiting at an airport.
    const routes = pairingRoutes({ relay, url }, TOKEN)
    expect(routes.map((route) => route.kind)).toEqual(['relay', 'direct'])
  })

  it('offers the tailnet alone when the relay is not connected', () => {
    const routes = pairingRoutes({ relay: { ...relay, connected: false }, url }, TOKEN)
    expect(routes.map((route) => route.kind)).toEqual(['direct'])
  })

  it('offers the relay alone when there is no tailnet address, which is the whole point', () => {
    const routes = pairingRoutes({ relay, url: null }, TOKEN)
    expect(routes.map((route) => route.kind)).toEqual(['relay'])
    expect(routes[0].link).toContain(HOST_ID)
  })

  it('offers nothing rather than a code for a path that is down', () => {
    expect(pairingRoutes({ relay: null, url: null }, TOKEN)).toEqual([])
    expect(pairingRoutes({ relay: { ...relay, connected: false }, url: null }, TOKEN)).toEqual([])
  })

  it('drops a relay that is connected but has not published an identity yet', () => {
    // `relayFor` reports exactly this while the link is starting, and a link
    // built from it would carry an empty host id.
    const blank = { url: RELAY, hostId: '', publicKey: '', connected: true }
    expect(pairingRoutes({ relay: blank, url: null }, TOKEN)).toEqual([])
  })

  it('knows whether pressing Pair can lead anywhere before a token exists', () => {
    // The button is drawn before the code is minted, so this is the question it
    // is disabled on — and it must not need a token to answer.
    expect(pairingPaths({ relay, url })).toEqual(['relay', 'direct'])
    expect(pairingPaths({ relay, url: null })).toEqual(['relay'])
    expect(pairingPaths({ relay: { ...relay, connected: false }, url })).toEqual(['direct'])
    expect(pairingPaths({ relay: null, url: null })).toEqual([])
  })

  it('falls back when the chosen path disappears while the code is on screen', () => {
    const routes = pairingRoutes({ relay: null, url }, TOKEN)
    expect(chooseRoute(routes, 'relay')?.kind).toBe('direct')
    expect(chooseRoute(routes, null)?.kind).toBe('direct')
    expect(chooseRoute([], 'direct')).toBeNull()
  })

  it('keeps the chosen path when it is still there', () => {
    const routes = pairingRoutes({ relay, url }, TOKEN)
    expect(chooseRoute(routes, 'direct')?.kind).toBe('direct')
  })
})
