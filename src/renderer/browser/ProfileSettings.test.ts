import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { PROFILE_AVATARS } from './ProfileSettings'

/**
 * What is inside a profile, once it has a section of its own.
 *
 *   > *"And now profiles doesn't have any kind of settings, I think, so they
 *   > should have proper settings, proper section, just like Google Chrome."*
 *
 * Held as source for the reason `HistoryPanel.test.ts` gives — this is a `Modal`
 * and `createPortal` throws under the only rendering this project's test run
 * does. The half worth pinning is which controls are here and which deliberately
 * are not: the second list is the one that keeps this section honest, because
 * Chrome's flyout carries four rows this app has nothing behind.
 */
const source = readFileSync(join(__dirname, 'ProfileSettings.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('the section a profile opens into', () => {
  it('renames it', () => {
    expect(onScreen).toContain('browserProfileRename')
    expect(onScreen).toContain('aria-label="Profile name"')
  })

  it('changes its badge, and can put it back to the letter', () => {
    expect(onScreen).toContain('browserProfileAvatar')
    // The way out of an avatar somebody picked: the empty string is the badge
    // `profile-badge.ts` has always drawn.
    expect(onScreen).toContain("setAvatar('')")
  })

  it('offers a badge that fits in the circle it is drawn in', () => {
    for (const glyph of PROFILE_AVATARS) {
      expect([...glyph]).toHaveLength(1)
    }
  })

  it('lists that profile’s saved logins, with copy and forget', () => {
    expect(onScreen).toContain('api.browserPasswords(profileId)')
    expect(onScreen).toContain('browserPasswordCopy')
    expect(onScreen).toContain('browserPasswordForget')
  })

  it('never offers to reveal a password', () => {
    // The password is put on the clipboard by the main process and never crosses
    // into this tree — `browser-passwords.ts` is the whole argument.
    expect(onScreen).not.toContain('Reveal')
    expect(onScreen).not.toMatch(/\bentry\.password\b/)
  })

  it('opens that profile’s site data and that profile’s history, by id', () => {
    expect(onScreen).toContain('onSiteData(profile.id)')
    expect(onScreen).toContain('onHistory(profile.id)')
  })

  it('draws no History row where the preload cannot answer for one', () => {
    // Absent rather than disabled: disabled says "not now", and the truth in
    // such a build is "not at all".
    expect(onScreen).toContain('onHistory && historyAvailable(api)')
  })

  it('arms Delete, and never offers it for the default profile', () => {
    expect(onScreen).toContain('!profile.isDefault')
    expect(onScreen).toContain('setArming(true)')
  })
})

describe('what it does not pretend to have', () => {
  /*
   * Chrome's profile flyout — f_0094, the frame he was pointing at — carries a
   * Google account, "Sync Is On", and autofill of addresses and payment methods.
   * This app has none of those, so this section draws none of them. A row that
   * opens nothing is the defect the whole review is about, and it is easier to
   * add one here by copying Chrome's list than by deciding to.
   */
  it.each(['Sync', 'Google Account', 'Extensions', 'Payment', 'Addresses'])(
    'draws no %s row',
    (word) => {
      expect(onScreen).not.toContain(word)
    },
  )
})
