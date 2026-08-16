/**
 * The macOS release script cannot quietly ship something weaker than it says.
 *
 * ## Why a test reads a shell script
 *
 * `scripts/mac-release-signed.sh` is the only thing standing between a tag and a
 * download that a stranger can open, and its failure mode is silence: an
 * unsigned build is byte-for-byte a normal build until somebody downloads it and
 * Gatekeeper says the app "is damaged and can't be opened". That is exactly what
 * 0.1.9 shipped — with the certificate sitting on the owner's Mac the whole
 * time, and with SIGNING-HANDOFF.md already naming this script as the thing to
 * run.
 *
 * A shell script cannot be unit tested in any satisfying way. What it *can* have
 * is a guard over the handful of lines whose removal would not break anything
 * visible, and would break the release. Each assertion below corresponds to a
 * failure that has already happened once, or to a degradation that must never
 * become automatic.
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const script = readFileSync(
  fileURLToPath(new URL('../scripts/mac-release-signed.sh', import.meta.url)),
  'utf8',
)

describe('the macOS signing script', () => {
  it('never waits on notarization without a deadline', () => {
    // `notarytool submit --wait` has no default timeout. When Apple stopped
    // answering, one electron-builder run sat waiting twenty-three hours and had
    // to be killed by hand — it was not hung, it was doing what it was told. The
    // deadline is what turns "Apple is down" from an overnight mystery into a
    // message.
    const submit = script.slice(script.indexOf('notarytool submit'))
    expect(submit).toMatch(/--timeout/)
  })

  it('only skips notarization when a human typed --signed-only', () => {
    // Signing without notarizing is a real, defensible mode — right-click > Open
    // works, where an unsigned build is a dead end that reads as a corrupt
    // download. It is defensible precisely because it is chosen. A fallback that
    // triggers itself on a failed submission would silently downgrade every
    // release the moment Apple had a bad afternoon, and nobody would notice
    // until a user complained.
    // Assignments only. `"$SIGNED_ONLY"` reads carry a `$` and are excluded by
    // the lookbehind, so this counts the places the value is *set*.
    const assignments = [...script.matchAll(/(?<![$\w])SIGNED_ONLY=(\d+)/g)].map((m) => m[1])

    // Exactly two: the default, and the one inside the argument parser.
    expect(assignments).toEqual(['0', '1'])
    expect(script).toMatch(/--signed-only\)\s*SIGNED_ONLY=1/)
  })

  it('still proves the bundle is Developer ID signed when it is not notarized', () => {
    // This is the assertion that matters most in this file. In `--signed-only`
    // mode both spctl and stapler fail correctly — there is no ticket — so they
    // are skipped. Skipping them without putting something in their place would
    // leave a mode with no signing check at all, and "signed but not notarized"
    // and "not signed" would be indistinguishable right up until a stranger
    // downloads one. That is the 0.1.9 failure, reintroduced through the door
    // built to prevent it.
    expect(script).toMatch(/Authority=Developer ID Application/)
    expect(script).toMatch(/Signature=adhoc/)
  })

  it('fails the build when any verification failed', () => {
    // The verify block sets `fail=1` rather than exiting, so that one run
    // reports every problem instead of the first. That is only safe if
    // something reads it at the end.
    expect(script).toMatch(/if \[\[ "\$fail" -ne 0 \]\]/)
    expect(script).toMatch(/do not publish this build/)
  })

  it('does not claim to have notarized when it has not', () => {
    // The closing line is what a person actually reads. If it says "notarized"
    // unconditionally then the one fact this mode exists to communicate is lost
    // at the last possible moment.
    const tail = script.slice(script.lastIndexOf('SIGNED_ONLY'))
    expect(tail).toMatch(/NOT notarized/)
  })
})
