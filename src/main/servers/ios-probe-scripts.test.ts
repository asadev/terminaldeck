/**
 * The two survey scripts, in Swift, generated from the ones the desktop runs.
 *
 * ## Why generate rather than hand-copy
 *
 * The phone now signs into a server over SSH itself, so it needs the same two
 * questions this app has always asked a server: `PROBE_SCRIPT` — what this
 * machine is and what it is running — and `HOST_PROBE` — whether the headless
 * host is on it. Swift cannot import TypeScript, so the alternative to
 * generating them was a second copy pasted into a `.swift` file, and a second
 * copy of a 150-line shell script is a copy that silently stops matching the
 * parser on the other side. That is not hypothetical for these two in
 * particular: both are *interpolated* — `PROBE_SCRIPT` splices in the agent
 * environment probe and `HOST_PROBE` splices in `BRAND.id` — so a hand-copy is
 * wrong the moment either of those changes, and wrong in a way nothing on the
 * desktop would notice.
 *
 * So the TypeScript stays the one source, this test is the generator, and the
 * committed Swift file is its output:
 *
 *     WRITE_IOS_PROBE=1 npx vitest run ios-probe-scripts
 *
 * Run without that variable — which is every ordinary run and every CI run — it
 * asserts the file on disk is exactly what it would have written. Drift fails
 * the suite on the side that caused it.
 *
 * ## Why a raw Swift string
 *
 * `#"""…"""#`, not `"""…"""`. Both scripts are full of backslashes that mean
 * something to `awk` and nothing to Swift — `\t`, `\/`, `\\|` — and in an
 * ordinary Swift string literal `\/` is not an escape sequence at all, so the
 * file would not compile. A raw literal takes every byte as written, which is
 * the only correct treatment for a shell script.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { HOST_PROBE } from './host'
import { PROBE_SCRIPT } from './probe.sh'

const SWIFT_FILE = join(
  __dirname,
  '..',
  '..',
  '..',
  'ios',
  'TerminalDeck',
  'Servers',
  'ProbeScripts.swift',
)

function swiftSource(): string {
  return `/*
 * GENERATED FILE — do not edit by hand.
 *
 * The two scripts the phone runs over SSH, generated from the ones the desktop
 * runs, by \`src/main/servers/ios-probe-scripts.test.ts\`. That test also checks
 * this file still matches, so an edit here fails the desktop suite rather than
 * quietly making the two sides disagree.
 *
 *     WRITE_IOS_PROBE=1 npx vitest run ios-probe-scripts
 *
 * Raw string literals, because both scripts are full of backslashes that belong
 * to \`awk\` and would be read as Swift escapes in an ordinary literal.
 */

enum ProbeScripts {
    /// \`src/main/servers/probe.sh.ts\` — what this machine is, and what it runs.
    static let server = #"""
${PROBE_SCRIPT}
"""#

    /// \`src/main/servers/host.ts\` — is the headless host on it, and could it be.
    static let host = #"""
${HOST_PROBE}
"""#
}
`
}

describe('the probe scripts the phone runs', () => {
  it('is the same script on both sides', () => {
    const expected = swiftSource()
    if (process.env.WRITE_IOS_PROBE === '1') {
      writeFileSync(SWIFT_FILE, expected)
    }
    expect(readFileSync(SWIFT_FILE, 'utf8')).toBe(expected)
  })

  it('carries nothing a raw Swift literal cannot hold', () => {
    // The one sequence that would end a `#"""` literal early. Neither script has
    // it today; this is the guard for the day somebody adds one to the shell.
    expect(PROBE_SCRIPT).not.toContain('"""#')
    expect(HOST_PROBE).not.toContain('"""#')
  })
})
