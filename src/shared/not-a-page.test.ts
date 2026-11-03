import { describe, expect, it } from 'vitest'
import { isExcluded } from './not-a-page'

/**
 * One list, both machines — and the four rows the walk of 2026-08-18 found
 * being offered as pages a person could open.
 *
 * Two of them came from a server (`sshd`, `systemd-resolve`) and two from this
 * Mac (`adb`, `sharingd`). The server ones were offered because
 * `servers/reach.ts` had no filter at all; the local ones because nobody had
 * met them before. Both are fixed by the same table now.
 */

describe('the ports that are not pages', () => {
  it('covers what the walk found on a server', () => {
    // Exactly the spellings in `reach.test.ts`'s fixture, which are the strings
    // the real box printed. `comm` is clamped to fifteen characters on Linux,
    // so `systemd-resolved` arrives with its last letter missing.
    expect(isExcluded('sshd')).toBe(true)
    expect(isExcluded('systemd-resolve')).toBe(true)
  })

  it('covers what the walk found on this Mac', () => {
    expect(isExcluded('adb')).toBe(true)
    expect(isExcluded('sharingd')).toBe(true)
  })

  it('still lets through everything somebody might actually be serving', () => {
    /*
     * The direction that costs more to get wrong. A list that hides a person's
     * own dev server is a feature that appears broken, and guessing which
     * frameworks people use is exactly the assumption rule 4 forbids.
     */
    for (const name of ['node', 'python3', 'ruby', 'caddy', 'nginx', 'bun', 'deno', 'gunicorn', 'unicorn']) {
      expect(isExcluded(name), name).toBe(false)
    }
  })

  it('says nothing about a holder the machine would not name', () => {
    // We do not know what it is, and refusing on a suspicion loses most of what
    // a shared server is running.
    expect(isExcluded('')).toBe(false)
  })

  it('still catches the three spellings one name arrives in', () => {
    // The clamp and the first-word rules this table was written around: field
    // -mode lsof prints `Google Chrome` where the column output printed
    // `Google`, and clamps `ControlCenter` to nine characters.
    expect(isExcluded('Google Chrome')).toBe(true)
    expect(isExcluded('ControlCenter')).toBe(true)
  })
})
