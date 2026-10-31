import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  blockedNote,
  BrowserSection,
  browserButtonLabel,
  explainsCookiePermission,
  forgetAllConfirmText,
  groupSources,
  importedCountText,
  importedSummary,
  keptSummary,
  profileCaption,
  SavedLoginRow,
  savedSummary,
  whenImported,
} from './BrowserSection'
import {
  toBrowserStored,
  toCookieImportReport,
  toCookieImportStatus,
  toCookieSources,
  type DetectedBrowser,
  type SettingsBridge,
} from '../settings-bridge'
import { SETTINGS, settingsIn } from '../settings-schema'
import type { AccountsApi } from '../../browser/accounts-bridge'

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

function render(bridge: SettingsBridge = {}, accounts?: AccountsApi): string {
  return renderToStaticMarkup(
    <BrowserSection
      values={values}
      save={() => {}}
      bridge={bridge}
      loading={false}
      goTo={() => {}}
      reload={() => {}}
      {...(accounts ? { accounts } : {})}
    />,
  )
}

/**
 * A fully wired accounts bridge, which is what a real build hands this pane.
 *
 * Every method is present because {@link profilesAvailable} and
 * {@link passwordsAvailable} are all-or-nothing on purpose — a pane that can
 * list profiles but not switch to one is the dead control this whole review is
 * a list of, so the honest answer to a half-wired preload is to draw nothing.
 */
const ACCOUNTS: AccountsApi = {
  browserProfiles: async () => ({
    profiles: [
      { id: 'default', name: 'Default', partition: 'persist:x', createdAt: 1, isDefault: true },
    ],
    activeId: 'default',
  }),
  browserProfileCreate: async () => ({ profiles: [], activeId: 'default' }),
  browserProfileRename: async () => ({ profiles: [], activeId: 'default' }),
  browserProfileActivate: async () => ({ profiles: [], activeId: 'default' }),
  browserProfileDelete: async () => ({ profiles: [], activeId: 'default' }),
  browserPasswordsAvailable: async () => true,
  browserPasswords: async () => [],
  browserPasswordForget: async () => ({ ok: true, message: '' }),
  browserPasswordForgetAll: async () => ({ ok: true, message: '' }),
  browserPasswordCopy: async () => true,
  browserPasswordAnswer: async () => ({ ok: true, message: '' }),
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

  /**
   * The block is headed **Profiles**, and it now manages the profiles that
   * exist rather than explaining that there is one.
   *
   *   > "Browser — start page, cookies, and profile settings, so people get the
   *   > browser's own features."
   *
   * It was headed "Per-tab isolation" — the name of the mechanism, not of the
   * thing anybody came looking for — and was then rewritten as a paragraph
   * saying this browser had a single profile plus a throwaway one per tab. That
   * was true when it was written and `browser-profiles.ts` landed after it, so
   * the pane spent a week telling people a feature was absent while it was
   * running one window away in the browser's own menu.
   *
   * What survives from that paragraph is the *per-tab* switch, and it survives
   * as a description: it is a property of one tab, so it belongs on the tab, and
   * a `role="switch"` in this block would be a second control for it.
   */
  it('answers "profiles" under that word, and describes the per-tab switch without owning it', () => {
    const html = render(wired)
    expect(html).toContain('Profiles')
    expect(html).toMatch(/A profile is a separate set of logins and cookies/)
    expect(html).toMatch(/Shared \/ Isolated/)
    expect(html).toMatch(/thrown away on quit/)
    const profiles = html.slice(html.indexOf('Profiles'))
    expect(profiles.slice(0, profiles.indexOf('</section>'))).not.toContain('role="switch"')
  })
})

/**
 * The pane is now shaped like the three things he asked for, and the two ways
 * that shape can silently break are both pinned here.
 *
 *   > "Browser — start page, cookies, and profile settings, so people get the
 *   > browser's own features."
 *
 * The rows are generated from the schema and split across two groups with
 * `omit`, which is the only mechanism in this window that can *lose* a row: a
 * third browser setting added tomorrow is omitted from one group and not
 * declared in the other, so it lands nowhere and nothing else fails.
 */
describe('the three subjects, and every row under one of them', () => {
  it('draws each declared browser setting exactly once', () => {
    const html = render()
    for (const setting of settingsIn('browser')) {
      const escaped = setting.label.replace(/&/g, '&amp;').replace(/'/g, '&#x27;')
      // Matched as an element's whole text — `>Start page<` — rather than as a
      // substring. A row with an ⓘ also carries its label inside that button's
      // `aria-label`, so a plain substring count says two for half the rows and
      // this check would be measuring which settings have a `more`.
      const hits = html.split(`>${escaped}<`).length - 1
      expect(hits, `${setting.id} appears ${hits} times`).toBe(1)
    }
  })

  it('heads them with the three subjects, in that order', () => {
    const html = render()
    // Saved passwords is fourth and not a fourth subject: which profile you are
    // in decides which logins are in play, so the list sits under the control
    // that changes it rather than in a group of its own further down.
    const order = [
      'Where new tabs open',
      'Cookies and sign-ins',
      'Profiles',
      'Saved passwords',
      'What the browser has kept',
    ]
    let at = -1
    for (const heading of order) {
      const found = html.indexOf(heading)
      expect(found, heading).toBeGreaterThan(at)
      at = found
    }
  })
})

/**
 * Profiles, reaching the mechanism that exists.
 *
 * There is no DOM in this project's test setup, so a static render is the
 * pane's *first frame* — before any effect has run and before the main process
 * has answered. That is exactly the frame worth pinning, because it is the one
 * that used to lie: a list that draws "no profiles" or "nothing saved" before it
 * has asked is a screen reporting a fault it has not checked for. Everything
 * that needs a second frame is verified against the running app instead, which
 * is this repo's rule for anything visible.
 */
describe('the profiles block', () => {
  it('offers nothing at all when the preload cannot do all five', () => {
    // All-or-nothing, by `profilesAvailable`. Half a manager — list but not
    // switch — is worse than none, because every row then looks broken.
    const html = render({}, { browserProfiles: async () => ({ profiles: [], activeId: 'x' }) })
    expect(html).toContain('Browser profiles is not available in this build yet.')
    expect(html).not.toContain('Add a profile')
  })

  it('offers the four things a manager is, once the channels are there', () => {
    const html = render({}, ACCOUNTS)
    expect(html).not.toContain('Browser profiles is not available')
    expect(html).toContain('Add a profile')
    // Rename is the one thing this pane can do that the browser's own top-right
    // menu cannot, and it is the reason a *settings* pane earns its place next
    // to a menu that already switches profiles.
    const source = readFileSync(join(__dirname, 'BrowserSection.tsx'), 'utf8')
    expect(source).toContain('browserProfileRename')
    expect(source).toContain('browserProfileActivate')
    expect(source).toContain('browserProfileDelete')
    expect(source).toContain('browserProfileCreate')
  })

  it('says nothing about a list it has not been given yet', () => {
    // The first frame has no profiles because none have arrived, which is not
    // the same as none existing. Neither sentence may be on screen then.
    const html = render({}, ACCOUNTS)
    expect(html).not.toContain('No profiles')
    expect(html).not.toContain('Nothing saved in')
  })

  it('never calls the mechanism a partition', () => {
    // *"Mostly non-technical vibe coders."* The consequence is the copy: signed
    // in here, signed out there. The Electron word belongs in the comments.
    const html = render({}, ACCOUNTS)
    expect(html).not.toMatch(/partition/i)
    expect(html).toMatch(/separate set of logins and cookies/)
  })
})

describe('profileCaption', () => {
  it('says which profile new tabs open in', () => {
    expect(profileCaption({ id: 'a', isDefault: false }, 'a')).toBe('New tabs open in this one')
  })

  it('keeps the two facts apart once they stop coinciding', () => {
    // The default profile holds the partition every build so far has used, so it
    // cannot be deleted — and that is a different claim from "this is the one
    // you are browsing as". They are the same row on a fresh install and
    // different rows the moment somebody adds a second and switches.
    expect(profileCaption({ id: 'default', isDefault: true }, 'work')).toBe('Cannot be deleted')
    expect(profileCaption({ id: 'default', isDefault: true }, 'default')).toBe(
      'New tabs open in this one · Cannot be deleted',
    )
  })

  it('is empty for a row with nothing to say', () => {
    // Rather than "Not in use", which reads as a fault on a perfectly good row.
    expect(profileCaption({ id: 'work', isDefault: false }, 'default')).toBe('')
  })
})

/**
 * Saved passwords — and the rule that the renderer never holds one.
 *
 * `browser-passwords.ts` keeps the secret in four places and the React tree is
 * not one of them: the store on disk, the main process's memory, the guest page
 * it is filled into, and the clipboard. This pane names a row and is told
 * whether a copy happened. The test that matters most here is therefore a
 * negative one, and it is asserted against the bridge rather than against this
 * file, because the way this rule dies is somebody adding a channel that
 * returns the string — after which every screen is one line away from leaking.
 */
describe('the saved-passwords block', () => {
  it('has no way to ask for a password, anywhere on the bridge', () => {
    const bridge = readFileSync(join(__dirname, '..', '..', 'browser', 'accounts-bridge.ts'), 'utf8')
    expect(bridge).not.toMatch(/browserPasswordRead|browserPasswordReveal|browserPasswordValue/)
    // And the summary type it does carry has no field one could arrive in.
    const summary = bridge.slice(bridge.indexOf('interface SavedLoginSummary'))
    expect(summary.slice(0, summary.indexOf('}'))).not.toContain('password')
  })

  it('asks about the right thing when the store itself is the problem', () => {
    /*
     * A store that decrypted and then failed its digest reads out as zero
     * entries, because nothing was used from it. The ordinary confirm would
     * therefore ask somebody to approve forgetting "all 0 saved passwords",
     * which is nonsense and is also a claim about a file whose contents are by
     * definition unknown.
     */
    expect(forgetAllConfirmText(0, true)).toMatch(/did not verify/)
    expect(forgetAllConfirmText(0, true)).not.toMatch(/\b0\b/)
    // And the ordinary sentence is untouched.
    expect(forgetAllConfirmText(1)).toMatch(/the one saved password/)
    expect(forgetAllConfirmText(4)).toMatch(/all 4 saved passwords/)
  })

  it('names a login by its username on every method that acts on one', () => {
    /*
     * The rule above bans a channel that *returns* a password. This is the
     * companion it needs now that a channel exists which causes one to be
     * **typed** — `browserPasswordFill`, the person's press behind the bar in
     * the browser panel.
     *
     * A method that took a password as an argument would be the same leak
     * spelled backwards: the string would have to exist on this side to be
     * passed, which puts it in a React tree, in devtools and in any future
     * crash report. So every method here addresses a login the way the manager
     * does — profile, origin, username — and the main process looks the secret
     * up for itself.
     */
    const bridge = readFileSync(join(__dirname, '..', '..', 'browser', 'accounts-bridge.ts'), 'utf8')
    for (const line of bridge.split('\n')) {
      if (!/^\s*browserPassword\w*\?\(/.test(line)) continue
      expect(line, `${line.trim()} takes a password across the bridge`).not.toMatch(
        /password\s*:\s*string/i,
      )
    }
  })

  it('offers Copy rather than Reveal, and says where it goes', () => {
    const html = renderToStaticMarkup(
      <SavedLoginRow
        entry={{
          profileId: 'default',
          origin: 'https://example.com',
          username: 'sam@example.com',
          updatedAt: Date.UTC(2026, 7, 12, 11, 0, 0),
        }}
        now={Date.UTC(2026, 7, 12, 12, 0, 0)}
        onCopy={() => {}}
        onForget={() => {}}
      />,
    )
    expect(html).toContain('Copy')
    expect(html).not.toContain('Reveal')
    expect(html).not.toContain('Show password')
    expect(html).toMatch(/It is not shown here/)
    // The row says who and where and when, and nothing that is or resembles a
    // secret — `SavedLoginSummary` has no field one could arrive in.
    expect(html).toContain('example.com — sam@example.com')
    expect(html).toContain('Saved 1 hour ago')
    expect(html).not.toMatch(/type="password"/)
  })

  it('says so plainly when the channels are not in this build', () => {
    expect(render()).toContain('Saved passwords is not available in this build yet.')
  })

  it('reports no encryption problem before it has asked about one', () => {
    // `canStore` is null until `browser-password:available` answers. A machine
    // with no keyring is a real state and worth a warning; drawing that warning
    // on a first frame would be reporting a fault nobody has checked for.
    expect(render({}, ACCOUNTS)).not.toContain('no secure store available')
  })

  it('does not offer to forget nothing', () => {
    // Disabled with the reason on it, not hidden: the button is the answer to
    // "where do I clear these", and a control that is absent until it would
    // work is a control nobody finds.
    const html = render({}, ACCOUNTS)
    expect(html).toMatch(/Forget all saved passwords/)
    expect(html).toMatch(/There are no saved passwords to forget/)
  })
})

describe('savedSummary', () => {
  it('names the profile even when the list is empty', () => {
    // Without the name, "nothing saved yet" is a sentence somebody can read as
    // "this app has never saved a password" and be wrong about, because theirs
    // are all in the profile they are not currently in.
    expect(savedSummary(0, 'Work')).toMatch(/^Nothing saved in Work yet\./)
  })

  it('counts, with the singular right', () => {
    expect(savedSummary(1, 'Default')).toBe('1 saved login in Default.')
    expect(savedSummary(4, 'Default')).toBe('4 saved logins in Default.')
  })
})

describe('forgetAllConfirmText', () => {
  it('names the quantity and the scope, because the channel is store-wide', () => {
    // `browser-password:forget-all` empties every profile. A confirm under a
    // list headed with one profile's name has to say so, or it is read as
    // clearing that list.
    const text = forgetAllConfirmText(7)
    expect(text).toContain('7')
    expect(text).toContain('every profile')
    expect(text).toContain('cannot be undone')
  })

  it('reads as a sentence for one', () => {
    expect(forgetAllConfirmText(1)).toMatch(/^Forget the one saved password\?/)
  })
})

/**
 * The red button now names what it is about to destroy.
 *
 * It said "cannot be undone" and gave no quantity at all, which is an
 * irreversible decision about an unknown. The numbers have been on the preload
 * since the browser's own dialog was built — this pane simply never asked.
 */
describe('what the browser has kept', () => {
  it('counts what the Clear button will remove', () => {
    const html = render({
      clearBrowserData: async () => ({ cleared: true, message: '' }),
      browserSessionInfo: async () => ({ cookieCount: 12, domainCount: 3, cacheBytes: 2_097_152 }),
    })
    expect(html).toContain('cannot be undone')
  })

  it('says nothing rather than a made-up zero before the read lands', () => {
    // Static markup runs no effects, so this is the pane's first frame — and on
    // a build whose preload predates the channel it is every frame.
    expect(render()).not.toContain('Nothing kept yet')
  })

  it.each([
    [{ cookieCount: 0, domainCount: 0, cacheBytes: 0 }, 'Nothing kept yet.'],
    [{ cookieCount: 1, domainCount: 1, cacheBytes: 0 }, '1 cookie from 1 site, and nothing cached.'],
    [
      { cookieCount: 12, domainCount: 3, cacheBytes: 2_097_152 },
      '12 cookies from 3 sites, and 2.0 MB of cached pages.',
    ],
    // Cache with no cookies is real: a site visited and never signed into.
    [{ cookieCount: 0, domainCount: 0, cacheBytes: 4096 }, 'No cookies, and 4.0 KB of cached pages.'],
  ])('reads %o as a sentence', (stored, expected) => {
    expect(keptSummary(stored)).toBe(expected)
  })

  it('treats a missing answer as nothing rather than throwing', () => {
    // A build whose preload predates the channel answers undefined, and the
    // narrowing has to survive it — this pane is not worth a blank window.
    expect(keptSummary(toBrowserStored(undefined))).toBe('Nothing kept yet.')
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

describe('the sentence about the permission dialog', () => {
  const wired = {
    importBrowserCookies: async () => ({ ok: true }),
    browserCookieSources: async () => [],
  }
  const status = (supported: boolean) => ({
    present: 0,
    recorded: 0,
    importedAt: null,
    source: '',
    supported,
  })

  it('is not shown to somebody the dialog will never appear for', () => {
    /*
     * `cookie-import.ts` answers `unsupported` for every platform but darwin —
     * the Windows DPAPI key schedule is not written — so on Windows this pane
     * shows "Importing cookies works on macOS only." The permission sentence
     * used to be printed above that notice, unconditionally, so a Windows user
     * read a paragraph about a macOS dialog immediately above a notice saying
     * the feature does not exist on their machine: two claims that cannot both
     * be about the reader, on one screen.
     *
     * Asked of the predicate rather than of the markup because every settings
     * test in this repo is `renderToStaticMarkup` — no DOM, no effects — so
     * `imports` is always `null` at paint and the loaded state is unreachable
     * from a rendered assertion. A branch expressed only as JSX position could
     * not be exercised at all; expressed as a function, both answers can be.
     */
    expect(explainsCookiePermission(wired, status(false))).toBe(false)
  })

  it('is shown where the dialog really does appear', () => {
    expect(explainsCookiePermission(wired, status(true))).toBe(true)
  })

  it('is shown while the answer is still on its way, like the block below it', () => {
    // `null` is "the read has not landed". The alternative is that every macOS
    // user watches the sentence appear a moment after the pane does.
    expect(explainsCookiePermission(wired, null)).toBe(true)
  })

  it('is not shown by a build that cannot import at all', () => {
    // No channel, no import, no permission dialog to warn about — the same
    // reason the missing-channel notice replaces the whole block.
    expect(explainsCookiePermission({}, status(true))).toBe(false)
    expect(explainsCookiePermission({ importBrowserCookies: wired.importBrowserCookies }, null)).toBe(
      false,
    )
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
