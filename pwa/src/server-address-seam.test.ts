import { describe, expect, it } from 'vitest'
import {
  SERVER_ADDRESS_PREFIX,
  SERVER_ADDRESS_VERSION,
  formatServerAddress,
} from '../../src/shared/server-address'
import { asEndpoint } from './endpoint'
import { readServerAddress } from './server-address'

/**
 * The seam: what a host **prints**, read by what a phone **runs**.
 *
 * ## Why this file is not more tests for `readServerAddress`
 *
 * `server-address-read.test.ts` next to it is thorough and every one of its
 * fixtures is built from the three facts rather than pasted as a literal — and
 * the reader still refused every real address, because a fixture built from the
 * three facts is a fixture built from *this file's idea* of the encoding. The
 * encoder and the three client screens were written in parallel, so nothing had
 * ever fed one into the other; the host wrote `srv1.` in front of its base64 and
 * the reader knew about a `scheme:` prefix and nothing else. Result:
 *
 *     readServerAddress(<the string a host prints>) -> { ok: false, fault: 'unreadable' }
 *     asEndpoint(...)                               -> { kind: 'direct' }
 *
 * Every phone would have refused the address on paste. The pairing feature was
 * dead on arrival, behind a green suite, in a build that contained all of its
 * wire.
 *
 * So the rule here is the only one that could have caught it: **no literal
 * address appears in this file.** Every string under test comes out of
 * `formatServerAddress`, the function a host calls. A hand-typed fixture is
 * what let the bug exist, and a hand-typed fixture cannot be the thing that
 * pins the fix.
 */

/** The three facts, spelled as `RelayState` spells them on a host. */
const PARTS = {
  url: 'wss://relay.terminaldeck.dev',
  hostId: 'KZ2J9AWGK8BWGQUEZDYKW5RS22',
  // Thirty-two bytes, all different, whose base64url contains both `-` and `_`
  // — the two characters the browser's `Buffer` shim silently drops. A key made
  // of a repeated byte would survive a decoder that has that bug.
  hostKey: Buffer.from(Array.from({ length: 32 }, (_, at) => ((at + 1) * 7) % 256)).toString('base64url'),
}

/** What a host prints. Not a literal — the encoder's own output. */
const ADDRESS = formatServerAddress(PARTS)

// Null is what a host with no relay link answers, and it would make every case
// below vacuous. Thrown at module scope so a broken fixture fails once, loudly,
// rather than being cast away with a `!` at each use.
if (ADDRESS === null) {
  throw new Error('the parts above are not three facts a host could print — fix them, not the encoder')
}

describe('the address a host prints, read by this client', () => {
  it('is the shape a host prints, so the rest of this file is about something', () => {
    expect(ADDRESS.startsWith(SERVER_ADDRESS_PREFIX)).toBe(true)
  })

  it('is accepted exactly as printed', () => {
    const read = readServerAddress(ADDRESS)
    expect(read.ok, `this client refused the real host address: ${JSON.stringify(read)}`).toBe(true)
  })

  it('resolves to a dialable relay endpoint rather than falling back to direct', () => {
    // The failure had two halves and this is the second: `asEndpoint` answers
    // `direct` for anything it cannot read, so a refused address does not look
    // like an error downstream — it looks like a client pointed at the page it
    // was served from, dialling nothing.
    const read = readServerAddress(ADDRESS)
    if (!read.ok) throw new Error(`refused: ${JSON.stringify(read)}`)
    expect(asEndpoint(read.endpoint)).toEqual({
      kind: 'relay',
      url: PARTS.url,
      hostId: PARTS.hostId,
      hostKey: PARTS.hostKey,
    })
  })

  it('carries the key through byte for byte, in either alphabet it is asked for', () => {
    // The `-`/`_` fold, which is the trap the encoder's own header warns about:
    // the browser `Buffer` is the `buffer` package, which does not know
    // `base64url` and silently *drops* those two characters.
    const read = readServerAddress(ADDRESS)
    if (!read.ok) throw new Error('refused')
    const bytes = Buffer.from(read.endpoint.hostKey.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
    expect(bytes).toEqual(Buffer.from(Array.from({ length: 32 }, (_, at) => ((at + 1) * 7) % 256)))
    expect(PARTS.hostKey).toContain('-')
    expect(PARTS.hostKey).toContain('_')
  })
})

describe('the ways that printed address survives being moved by hand', () => {
  const accepts = (raw: string): void => {
    const read = readServerAddress(raw)
    expect(read.ok, `refused: ${JSON.stringify(read)}`).toBe(true)
  }

  it('with the newline a terminal paste brings', () => {
    accepts(`  ${ADDRESS}\n`)
  })

  it('inside the block `terminaldeck address` prints around it', () => {
    // `renderAddress` in src/headless/cli.ts, near enough: a heading, the token
    // indented under it, and the two sentences that travel with it. A finger on
    // a phone selects all of that.
    accepts(
      [
        'Server address',
        `  ${ADDRESS}`,
        '',
        '  Paste it into the app on a phone or another computer: Add a server, then',
        '  sign in with a username and password or key this machine already accepts.',
        '',
        '  This address is not a secret. It holds a public key and a public name at a',
        '  relay, and it grants nothing on its own.',
      ].join('\n'),
    )
  })

  it('wrapped at eighty columns, which is what a narrow terminal does to it', () => {
    accepts(`${ADDRESS.slice(0, 80)}\n${ADDRESS.slice(80, 160)}\n${ADDRESS.slice(160)}`)
  })

  it('with the quotes a copy out of a shell one-liner takes with it', () => {
    accepts(`"${ADDRESS}"`)
    accepts(`<${ADDRESS}>`)
  })
})

describe('an address this build cannot read', () => {
  it('refuses a token whose tail a selection left behind', () => {
    // Base64 decoding ignores what it does not recognise, so a shortened body
    // decodes to *something*. Refused, not half-read into an endpoint.
    expect(readServerAddress(ADDRESS.slice(0, ADDRESS.length - 6))).toEqual({
      ok: false,
      fault: 'unreadable',
    })
  })

  it('names a version it does not know rather than calling it unreadable', () => {
    // The whole point of a version in the prefix: an address from a newer host
    // is a diagnosable situation — update this app — and it must not arrive as
    // the same sentence a line of prose gets.
    const future = ADDRESS.replace(SERVER_ADDRESS_PREFIX, `srv${SERVER_ADDRESS_VERSION + 1}.`)
    expect(readServerAddress(future)).toEqual({ ok: false, fault: 'version', version: SERVER_ADDRESS_VERSION + 1 })
  })

  it('says the same about a future token pasted inside its block', () => {
    const future = ADDRESS.replace(SERVER_ADDRESS_PREFIX, 'srv9.')
    expect(readServerAddress(`Server address\n  ${future}\n\n  Paste it into the app.`)).toEqual({
      ok: false,
      fault: 'version',
      version: 9,
    })
  })

  it('does not read a full stop in ordinary prose as a version announcement', () => {
    // The body has to be base64url and long enough that no accident reaches it,
    // because "your app is too old" told to somebody who pasted the wrong thing
    // is worse than no sentence at all.
    expect(readServerAddress('srv1.')).toEqual({ ok: false, fault: 'unreadable' })
    expect(readServerAddress('srv2.zip')).toEqual({ ok: false, fault: 'unreadable' })
    expect(readServerAddress('the file is at srv1.example.com/thing')).toEqual({
      ok: false,
      fault: 'unreadable',
    })
  })
})
