import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  blockedNote,
  BrowserSection,
  browserButtonLabel,
  groupSources,
  importedCountText,
  importedSummary,
  whenImported,
} from './BrowserSection'
import {
  toCookieImportReport,
  toCookieImportStatus,
  toCookieSources,
  type DetectedBrowser,
  type SettingsBridge,
} from '../settings-bridge'
import { SETTINGS } from '../settings-schema'

/**
 * The cookie-import block, as far as static markup reaches.
 *
 * The two things worth pinning here are both about what the panel *says*.
 * Importing cookies puts a system permission dialog on screen and copies live
 * session credentials, so the panel has to warn before the press rather than
 * explain afterwards — and the count line has to distinguish "no cookies were
 * imported" from "they were imported and the sites have since expired them",
 * because those look identical and only one of them is a problem.
 */

const values = Object.fromEntries(SETTINGS.map((setting) => [setting.id, setting.default]))

function render(bridge: SettingsBridge = {}): string {
  return renderToStaticMarkup(
    <BrowserSection
      values={values}
      save={() => {}}
      bridge={bridge}
      loading={false}
      goTo={() => {}}
      reload={() => {}}
    />,
  )
}

describe('the cookie import block', () => {
  const wired: SettingsBridge = {
    browserCookieSources: async () => [],
    browserCookieImportStatus: async () => ({ present: 0, recorded: 0, supported: true }),
    importBrowserCookies: async () => ({ ok: true }),
    clearImportedCookies: async () => ({ removed: 0 }),
  }

  /**
   * The block was two paragraphs and is one. Both warnings survived the cut on
   * purpose — a shorter panel that leaves somebody unaware that a system
   * permission dialog is coming, or that what is being copied is a live
   * credential, is a worse panel rather than a tidier one. Asserted as the
   * lower-case clause it now is, because the sentence it used to start was
   * folded into the one before it.
   */
  it('warns that macOS will ask, before anything is pressed', () => {
    const html = render(wired)
    expect(html).toMatch(/macOS will ask/)
    expect(html).toMatch(/nothing is read until you press/)
    expect(html).toMatch(/credentials that keep you signed in/)
  })

  it('says what an isolated tab does with them, which is the surprise afterwards', () => {
    expect(render(wired)).toMatch(/Isolated/)
  })

  it('offers the clear action', () => {
    expect(render(wired)).toContain('Clear imported cookies')
  })

  it('says so plainly when the channels are not in this build', () => {
    // A settings panel that renders a dead button is how a feature looks broken
    // rather than absent.
    expect(render({})).toContain('Importing cookies is not available in this build yet.')
  })

  it('explains per-tab isolation without pretending to own the switch', () => {
    const html = render(wired)
    expect(html).toContain('Per-tab isolation')
    expect(html).toMatch(/Shared \/ Isolated/)
    expect(html).toMatch(/thrown away when the\s+app quits/)
  })
})

describe('groupSources', () => {
  it('collapses a browser’s profiles onto one row', () => {
    // This machine has fourteen Chrome profiles — the numbering counts every
    // profile ever created — so one button each is a wall, not a chooser.
    const profiles = ['Default', 'Profile 2', 'Profile 13', 'Profile 40'].map((profileId) => ({
      browserId: 'chrome',
      browserName: 'Chrome',
      profileId,
      profileName: profileId,
      keychainItem: true,
    }))
    const grouped = groupSources([
      ...profiles,
      {
        browserId: 'brave',
        browserName: 'Brave',
        profileId: 'Default',
        profileName: 'Default',
        keychainItem: false,
      },
    ])
    expect(grouped.map((group) => group.browserId)).toEqual(['chrome', 'brave'])
    expect(grouped[0].profiles).toHaveLength(4)
    expect(grouped[1].profiles).toHaveLength(1)
  })

  it('keeps the order it was given, so Default stays first', () => {
    const grouped = groupSources([
      { browserId: 'chrome', browserName: 'Chrome', profileId: 'Default', profileName: 'D', keychainItem: true },
      { browserId: 'chrome', browserName: 'Chrome', profileId: 'Profile 2', profileName: 'W', keychainItem: true },
    ])
    expect(grouped[0].profiles[0].profileId).toBe('Default')
  })

  it('is empty for nothing, rather than one empty group', () => {
    expect(groupSources([])).toEqual([])
  })
})

describe('importedCountText', () => {
  const base = { present: 0, recorded: 0, importedAt: null, source: '', supported: true }

  it('says nothing has been imported rather than showing a zero', () => {
    expect(importedCountText(base)).toBe('No cookies have been imported.')
  })

  it('names the source when everything is still there', () => {
    expect(importedCountText({ ...base, present: 12, recorded: 12, source: 'Chrome' })).toBe(
      '12 imported cookies from Chrome.',
    )
  })

  it('explains the gap rather than leaving it looking like a failed clear', () => {
    const text = importedCountText({ ...base, present: 4, recorded: 12, source: 'Chrome' })
    expect(text).toContain('4 of 12')
    expect(text).toMatch(/expired/)
  })

  it('gets the singular right', () => {
    expect(importedCountText({ ...base, present: 1, recorded: 1 })).toBe('1 imported cookie.')
  })
})

describe('importedSummary', () => {
  const now = Date.UTC(2026, 7, 12, 12, 0, 0)
  const base = { present: 0, recorded: 0, importedAt: null, source: '', supported: true }

  it('never pairs "nothing imported" with a time it was imported', () => {
    // An import that decrypted rows and had every one refused used to stamp the
    // ledger anyway, and the panel then read "No cookies have been imported.
    // Last imported just now." — a sentence that contradicts itself.
    const text = importedSummary({ ...base, importedAt: now - 30_000 }, now)
    expect(text).toBe('No cookies have been imported.')
    expect(text).not.toMatch(/Last imported/)
  })

  it('shows the time when there is something for it to be the time of', () => {
    const text = importedSummary(
      { ...base, present: 12, recorded: 12, source: 'Chrome', importedAt: now - 5 * 60_000 },
      now,
    )
    expect(text).toBe('12 imported cookies from Chrome. Last imported 5 minutes ago.')
  })

  it('leaves the time off when the ledger has no time', () => {
    expect(importedSummary({ ...base, present: 1, recorded: 1 }, now)).toBe('1 imported cookie.')
  })
})

describe('whenImported', () => {
  const now = Date.UTC(2026, 7, 12, 12, 0, 0)

  it('is empty when nothing has been imported', () => {
    expect(whenImported(null, now)).toBe('')
  })

  it('reads in whichever unit is legible', () => {
    expect(whenImported(now - 10_000, now)).toBe('just now')
    expect(whenImported(now - 5 * 60_000, now)).toBe('5 minutes ago')
    expect(whenImported(now - 3 * 3_600_000, now)).toBe('3 hours ago')
    expect(whenImported(now - 5 * 86_400_000, now)).toMatch(/\d/)
  })
})

describe('narrowing what the main process sends', () => {
  it('drops a source with no browser or profile id rather than rendering a blank button', () => {
    const sources = toCookieSources([
      { browserId: 'chrome', profileId: 'Default', browserName: 'Chrome', keychainItem: true },
      { browserName: 'Nameless' },
      'nope',
    ])
    expect(sources).toHaveLength(1)
    expect(sources[0].profileName).toBe('Default')
  })

  it('defaults `supported` to false, so nothing promises an import that cannot run', () => {
    expect(toCookieImportStatus({}).supported).toBe(false)
    expect(toCookieImportStatus(null).present).toBe(0)
  })

  it('always produces a message, because the panel renders it unconditionally', () => {
    expect(toCookieImportReport({}).message).not.toBe('')
    expect(toCookieImportReport(undefined).ok).toBe(false)
  })

  it('keeps the keychain outcome, which separates "none" from "you said no"', () => {
    expect(toCookieImportReport({ keychain: 'denied' }).keychain).toBe('denied')
    expect(toCookieImportReport({ keychain: 7 }).keychain).toBeNull()
  })
})

/* ------------------------------------------------- the blocked-browser copy -- */

/**
 * Three identical warnings, and a count advertised on a dead control.
 *
 * Both were live on this machine. `/Applications` holds Google Chrome and no
 * other browser, `mdfind` finds no Edge or Brave bundle anywhere — and this pane
 * still printed a Full Disk Access paragraph for each of Chrome, Edge and Brave,
 * word for word the same but for the name, because the two uninstalled browsers
 * left protected directories behind. Above them sat "Chrome (14 profiles)" on a
 * segment that could not be pressed, while the real profile picker was three
 * hundred pixels lower in another group.
 */
describe('what the pane says about a browser it cannot read', () => {
  const browser = (over: Partial<DetectedBrowser>): DetectedBrowser => ({
    id: 'chrome',
    name: 'Chrome',
    userDataDir: '/x',
    access: 'ok',
    profiles: [],
    ...over,
  })

  it('says the remedy once, and names every browser it applies to', () => {
    const note = blockedNote([
      browser({ id: 'chrome', name: 'Chrome', access: 'blocked' }),
      browser({ id: 'edge', name: 'Edge', access: 'blocked' }),
      browser({ id: 'brave', name: 'Brave', access: 'blocked' }),
    ])
    expect(note).toContain('Chrome, Edge and Brave')
    // One instruction, not three.
    expect(note?.match(/Full Disk Access/g)).toHaveLength(1)
    expect(note).toContain('One grant covers all of them')
  })

  it('keeps a single browser’s own reason rather than a generic one', () => {
    const note = blockedNote([
      browser({ access: 'blocked', note: 'Chrome’s Local State could not be read (EPERM).' }),
    ])
    expect(note).toBe('Chrome’s Local State could not be read (EPERM).')
  })

  it('says nothing when nothing is blocked', () => {
    expect(blockedNote([])).toBe(null)
  })

  it('does not advertise profiles behind a segment that cannot be pressed', () => {
    const profiles = Array.from({ length: 14 }, (_, i) => ({
      browserId: 'chrome' as const,
      browserName: 'Chrome',
      id: `Profile ${i}`,
      name: `Profile ${i}`,
      path: `/x/Profile ${i}`,
      access: 'blocked' as const,
    }))
    expect(browserButtonLabel(browser({ access: 'blocked', profiles }))).toBe('Chrome')
    // And still says it where the button works and the number means something.
    expect(browserButtonLabel(browser({ access: 'ok', profiles }))).toBe('Chrome (14 profiles)')
  })
})
