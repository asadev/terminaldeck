import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { SERVER_ADDRESS_VERSION, formatServerAddress } from './server-address'

/**
 * The **generator** for the address fixture Swift and Kotlin read, and the pin
 * that fails when it goes stale.
 *
 * ## Why a generated file rather than a string typed into each suite
 *
 * Because a string typed into each suite is exactly what shipped a dead feature.
 * The host encoder and the three client screens were written in parallel; every
 * one of the four suites was thorough, every one of them built its fixtures from
 * the three facts rather than pasting a literal — and all three clients refused
 * the real address on paste, because building a fixture "from the three facts"
 * means building it from *that file's idea* of the encoding. Nothing had ever
 * fed the encoder's output into a reader.
 *
 * TypeScript can close that hole by importing `formatServerAddress`, and
 * `pwa/src/server-address-seam.test.ts` does. Swift and Kotlin cannot import it.
 * The nearest thing available to them is a fixture **generated from the real
 * encoder** and checked, on every `vitest run`, against what that encoder
 * produces today. So the chain is:
 *
 *   - this file computes the address by calling the encoder;
 *   - it renders the two fixture files and asserts the ones on disk match;
 *   - `ServerAddressTests` and `ServerAddressTest` parse only that constant.
 *
 * Change the format and this test goes red immediately. Regenerate, and the two
 * mobile suites go red until their parsers agree with the new format. There is
 * no arrangement of edits that leaves a client silently unable to read what a
 * host prints — which is the property that was missing.
 *
 * ## Writing source from a test
 *
 * Only when asked, and the ask is an environment variable. This is a snapshot in
 * the sense `vitest -u` means it: the checked-in bytes are the artefact, the
 * assertion is the gate, and the update is a deliberate command a person runs —
 *
 *     TD_WRITE_ADDRESS_FIXTURES=1 npx vitest run src/shared/server-address-fixture.test.ts
 *
 * — which is also the line printed in the header of both generated files, since
 * whoever reads one of them next will be looking for exactly that.
 */

const WRITE = process.env.TD_WRITE_ADDRESS_FIXTURES === '1'

const REGENERATE = 'TD_WRITE_ADDRESS_FIXTURES=1 npx vitest run src/shared/server-address-fixture.test.ts'

/**
 * One machine, described the way a host describes itself.
 *
 * The host id is in the relay's base32 and the key is thirty-two bytes that are
 * all different, so a decoder that dropped a character or shifted a byte
 * produces visibly other bytes rather than the same run repeated. The values
 * are otherwise arbitrary: what is under test is the *encoding*, and the facts
 * only have to be ones the encoder will accept.
 */
const RELAY_URL = 'wss://relay.terminaldeck.dev'
const HOST_ID = 'KZ2J9AWGK8BWGQUEZDYKW5RS22'
const KEY_BYTES = Array.from({ length: 32 }, (_, at) => ((at + 1) * 7) % 256)

const ADDRESS = formatServerAddress({
  url: RELAY_URL,
  hostId: HOST_ID,
  hostKey: Buffer.from(KEY_BYTES).toString('base64url'),
})

// `formatServerAddress` answers null when a host cannot describe itself, which
// is the honest answer for a machine with no relay link and a bug in a fixture.
// Thrown at module scope rather than asserted in a case, so a broken fixture
// fails loudly and once instead of four times with `!` scattered through the file.
if (ADDRESS === null) {
  throw new Error('the fixture parts are not three facts a host could print — fix them, not the encoder')
}

const HEADER = [
  'GENERATED FILE — do not edit by hand.',
  '',
  `Regenerate with:  ${REGENERATE}`,
  '',
  'The one string in here is the literal output of formatServerAddress() in',
  'src/shared/server-address.ts — the function a host calls to print its own',
  'address. It is generated rather than typed because a typed one is what let',
  'every client ship a parser that refused every real address: four suites, all',
  'green, none of which had ever seen what the encoder actually writes.',
  '',
  'src/shared/server-address-fixture.test.ts re-derives this file on every',
  '`vitest run` and fails if the bytes below are not what the encoder produces',
  'today, so the format cannot move without this fixture and the two mobile',
  'suites that read it moving with it.',
]

function swiftFixture(address: string): string {
  const body = [
    ...HEADER.map((line) => (line === '' ? '//' : `// ${line}`)),
    '',
    'import Foundation',
    '',
    'enum ServerAddressFixture {',
    '',
    '    /// Exactly what a host prints, for the machine described below.',
    `    static let printedByAHost = "${address}"`,
    '',
    `    static let relayURL = "${RELAY_URL}"`,
    '',
    `    static let hostId = "${HOST_ID}"`,
    '',
    '    /// The thirty-two key bytes behind that token.',
    `    static let hostKey = Data([${KEY_BYTES.join(', ')}] as [UInt8])`,
    '',
    '    /// The format version the token announces.',
    `    static let version = ${SERVER_ADDRESS_VERSION}`,
    '}',
  ]
  return `${body.join('\n')}\n`
}

function kotlinFixture(address: string): string {
  const body = [
    ...HEADER.map((line) => (line === '' ? '//' : `// ${line}`)),
    '',
    'package dev.terminaldeck.android.signin',
    '',
    'object ServerAddressFixture {',
    '',
    '    /** Exactly what a host prints, for the machine described below. */',
    `    const val PRINTED_BY_A_HOST = "${address}"`,
    '',
    `    const val RELAY_URL = "${RELAY_URL}"`,
    '',
    `    const val HOST_ID = "${HOST_ID}"`,
    '',
    '    /** The thirty-two key bytes behind that token. */',
    `    val HOST_KEY: ByteArray = byteArrayOf(${KEY_BYTES.map((byte) => `${byte - (byte > 127 ? 256 : 0)}`).join(', ')})`,
    '',
    '    /** The format version the token announces. */',
    `    const val VERSION = ${SERVER_ADDRESS_VERSION}`,
    '}',
  ]
  return `${body.join('\n')}\n`
}

const FIXTURES: ReadonlyArray<{ what: string; path: string; render: (address: string) => string }> = [
  {
    what: 'iOS',
    path: fileURLToPath(new URL('../../ios/Tests/ServerAddressFixture.swift', import.meta.url)),
    render: swiftFixture,
  },
  {
    what: 'Android',
    path: fileURLToPath(
      new URL('../../android/app/src/test/java/dev/terminaldeck/android/signin/ServerAddressFixture.kt', import.meta.url),
    ),
    render: kotlinFixture,
  },
]

describe('the address fixture Swift and Kotlin read', () => {
  it('is one unbroken token announcing the version this build writes', () => {
    expect(ADDRESS).toMatch(new RegExp(`^srv${SERVER_ADDRESS_VERSION}\\.[A-Za-z0-9_-]+$`))
  })

  it('carries a key that exercises both characters the browser Buffer drops', () => {
    // `-` and `_`, and they have to be in the **key**, not in the token around
    // it. The outer body cannot contain either: base64 of ASCII text only
    // reaches sextet 62 or 63 when the source byte is `>`, `?`, `~` or DEL, and
    // JSON of these three facts holds none of them. So a fixture that asserted
    // the token itself contained a `-` would be asserting something the format
    // can never produce, and the trap it was meant to guard would go untested.
    //
    // The key is the string every client folds by hand — the `buffer` package
    // behind the browser does not know the name `base64url`, does not refuse
    // it, and silently *drops* those two characters rather than translating
    // them, which is a key two bytes short and a handshake that fails with
    // nothing on screen.
    const key = Buffer.from(KEY_BYTES).toString('base64url')
    expect(key).toContain('-')
    expect(key).toContain('_')
    expect(new Set(KEY_BYTES).size).toBe(32)
    expect(Buffer.from(ADDRESS.slice('srv1.'.length), 'base64').toString('utf8')).toContain(key)
  })

  for (const { what, path, render } of FIXTURES) {
    it(`is what the ${what} suite has on disk`, () => {
      const wanted = render(ADDRESS)
      if (WRITE) writeFileSync(path, wanted)
      const found = readFileSync(path, 'utf8')
      expect(found, `${what}'s address fixture is stale — regenerate it:\n    ${REGENERATE}\n`).toBe(wanted)
    })
  }
})
