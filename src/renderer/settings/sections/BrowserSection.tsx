import { useCallback, useEffect, useMemo, useState } from 'react'
import { Button, Group, Notice, SectionHead, SettingList } from '../controls'
import { sectionMeta, stringSetting } from '../settings-schema'
// The one shared byte formatter in the renderer. There are four others in this
// codebase and every one of them is a copy; this module is a leaf with no JSX,
// which is why it is the one worth importing across a folder boundary.
import { formatBytes } from '../../components/relative-time'
// The browser's own half of profiles and saved logins, imported across the same
// folder boundary and for the same reason: it is a leaf with no JSX, it is the
// single place either feature is reached from, and a second resolver here would
// be a second thing to keep in step with the preload.
import {
  loginLabel,
  passwordsAvailable,
  profilesAvailable,
  readLoginList,
  readPasswordStoreState,
  readProfileState,
  resolveAccountsApi,
  type AccountsApi,
  type PasswordStoreState,
  type ProfileState,
  type SavedLoginSummary,
} from '../../browser/accounts-bridge'
import {
  errorText,
  missingChannelNote,
  toBrowsers,
  toBrowserStored,
  toClearResult,
  toCookieImportReport,
  toCookieImportStatus,
  toCookieSources,
  toScanResult,
  type BrowserStored,
  type CookieImportStatus,
  type CookieSource,
  type DetectedBrowser,
  type DevUrl,
  type SectionProps,
  type SettingsBridge,
} from '../settings-bridge'

/**
 * Browser — the built-in tab, what it opens with, what it keeps, and who it
 * keeps it for.
 *
 * ## The pane is now shaped like the three things he asked for
 *
 *   > "Browser — start page, cookies, and profile settings, so people get the
 *   > browser's own features."
 *
 * Everything on it was already about one of those three, and none of it said so:
 * the two settings rows sat in a heap at the top, above three headed blocks
 * about importing, importing, and isolation. So the headings are now the three
 * subjects, and each row and block sits under the one it belongs to. Nothing was
 * added to make the shape work and nothing was dropped to make it fit.
 *
 * **Start page** takes the address row *and* the address scanner, which is what
 * the scanner has always been for — every entry it finds ends in a "Use it"
 * button that writes this exact setting. It was a separate headed block with its
 * own explanation, three hundred pixels from the field it fills in.
 *
 * **Cookies and sign-ins** takes the keep-between-runs switch and the import.
 *
 * **Profiles** is the third, and it is a real manager now. It was a paragraph
 * saying there was one profile and a throwaway one per tab, which was true when
 * it was written and stopped being true the same week: `browser-profiles.ts`
 * builds a profile out of a **persistent Electron session partition** —
 * `session.fromPartition('persist:…')`, a separate cookie jar, `localStorage`,
 * IndexedDB and cache, written to its own directory — which is the same
 * mechanism Chromium itself uses for a profile, reached through Electron's API.
 * So the pane manages them: switch, add, rename, delete.
 *
 * The one thing it can do that the browser's own top-right menu cannot is
 * **rename**, and that is not an accident of who built what. A menu you open
 * while browsing is for switching; the place you go to *manage* something is
 * the settings pane, and that is where the destructive and the fiddly belong.
 *
 * **Saved passwords** is the fourth, and it belongs under profiles because it is
 * the same question asked twice — which set of logins is in play. The renderer
 * never sees a password and there is no shape here that could carry one:
 * `SavedLoginSummary` has no such field, and Copy is answered with a boolean by
 * the main process, which writes the clipboard itself. See `browser-passwords.ts`
 * for why that rule is absolute.
 *
 * **What the browser has kept** is the last heading and it carries the numbers —
 * see `keptSummary`.
 *
 * ## Three separate things, and they are deliberately not one button
 *
 * **Addresses** come out of another browser's bookmarks, history and open tabs
 * so a start page does not have to be retyped. It is a read-only look at those
 * files and it asks for nothing — `chrome-import.ts` is read-only by design.
 *
 * **Cookies** are a different act with a different cost. Chromium encrypts its
 * cookie store with a key in the login keychain, so importing means asking
 * macOS for another application's secret, and macOS puts a dialog on screen
 * naming this app. That has to be a button somebody pressed, never a
 * side-effect of opening this panel — so nothing here calls
 * `importBrowserCookies` on mount, and the panel says what will happen before
 * it happens.
 *
 * **Isolation** is the counterweight. Once cookies have been imported, every
 * tab is signed in as whoever Chrome was signed in as, which is wrong often
 * enough that the browser toolbar carries a per-tab switch out of it. This
 * panel explains that switch rather than duplicating it: it is per tab, so it
 * belongs on the tab.
 */

const SOURCE_LABEL: Record<DevUrl['source'], string> = {
  bookmark: 'Bookmark',
  history: 'History',
  session: 'Open tab',
}

/**
 * The one Full Disk Access warning, however many browsers are behind it.
 *
 * There were three, and they were word-for-word identical except for the
 * browser's name — three paragraphs, three tinted blocks with a rule down each
 * side, all ending "…add this app, then run the import again." The remedy is
 * one remedy: Full Disk Access is granted to *this* app once, and every blocked
 * browser becomes readable at the same moment. Repeating it per browser turned
 * one instruction into a wall and made the pane read as three separate faults.
 *
 * So the names are collected into a list and the instruction is said once.
 * A browser's own `note` is not lost when there is only one to show — that is
 * where a non-standard reason would live — and the multi-browser wording names
 * every one of them, because "some browsers" would be a warning the reader has
 * to go and check.
 *
 * Pure and exported: on a screen whose job is to say one true thing rather than
 * three copies of it, the wording is the fix, and a test that could not read it
 * would be testing the wrong half.
 */
export function blockedNote(blocked: readonly DetectedBrowser[]): string | null {
  if (blocked.length === 0) return null
  if (blocked.length === 1) {
    const only = blocked[0]
    return (
      only.note ??
      `${only.name}’s data is protected by the system. Grant Full Disk Access to read it.`
    )
  }
  const names = blocked.map((browser) => browser.name)
  const list = `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`
  return (
    `macOS will not let this app read ${list} until it is given full disk access. ` +
    'Open Privacy & Security → Full Disk Access, add this app, then run the import again. ' +
    'One grant covers all of them.'
  )
}

/**
 * What a browser button says.
 *
 * The profile count is dropped from a browser we cannot read, and that is the
 * fix for a real contradiction rather than a tidy-up. The pane advertised
 * **"Chrome (14 profiles)"** on a *disabled* segment — a count of things behind
 * a control that cannot be pressed — while the only working profile picker was
 * a bare dropdown three hundred pixels below it, in a different group. Two
 * controls about the same fourteen profiles, one dead and shouting, one live and
 * silent.
 *
 * The count is still worth saying where it means something: on a browser that
 * can be scanned, it tells you how much the button is about to look through.
 */
export function browserButtonLabel(browser: DetectedBrowser): string {
  if (browser.access === 'blocked') return browser.name
  return browser.profiles.length > 1
    ? `${browser.name} (${browser.profiles.length} profiles)`
    : browser.name
}

/**
 * The line under an address: where it came from, what it is called, and how
 * sure we are.
 *
 * `detail` is deduplicated against the source label because a session hit
 * carries `detail: 'Open tab'` and the source already reads "Open tab" — which
 * rendered as "Open tab · Open tab · approximate" the first time this was
 * looked at on screen.
 */
export function noteFor(hit: DevUrl): string {
  const parts = [SOURCE_LABEL[hit.source]]
  if (hit.title) parts.push(hit.title)
  if (hit.detail && hit.detail !== SOURCE_LABEL[hit.source]) parts.push(hit.detail)
  // Session hits are recovered by scanning a binary file rather than parsed,
  // and chrome-import says so — so this panel does too.
  if (hit.approximate) parts.push('approximate')
  return parts.join(' · ')
}

/**
 * Group the cookie sources by browser.
 *
 * A button per profile was the obvious layout and it is wrong on a real
 * machine: this one has fourteen Chrome profiles, because the numbering counts
 * every profile ever created rather than the ones that exist. Fourteen buttons
 * reading "Import from Chrome — Person 1" is not a chooser, it is a wall. So a
 * browser gets one row, and its profiles become a menu on that row.
 */
export function groupSources(sources: readonly CookieSource[]): Array<{
  browserId: string
  browserName: string
  profiles: CookieSource[]
}> {
  const byBrowser = new Map<string, { browserId: string; browserName: string; profiles: CookieSource[] }>()
  for (const source of sources) {
    const group = byBrowser.get(source.browserId)
    if (group) group.profiles.push(source)
    else {
      byBrowser.set(source.browserId, {
        browserId: source.browserId,
        browserName: source.browserName,
        profiles: [source],
      })
    }
  }
  return [...byBrowser.values()]
}

/** "3 minutes ago", "12 Aug" — enough to know whether an import is stale. */
export function whenImported(at: number | null, now: number): string {
  if (at === null || !Number.isFinite(at)) return ''
  const minutes = Math.round((now - at) / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} minute${minutes === 1 ? '' : 's'} ago`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours} hour${hours === 1 ? '' : 's'} ago`
  return new Date(at).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
}

/**
 * What the count line says.
 *
 * Two numbers, because they answer different questions and conflating them is
 * how a Clear button looks broken: `present` is how many imported cookies the
 * browser tab still holds, `recorded` is how many were ever brought in. Sites
 * expire their own cookies, so the first drifting below the second is normal
 * and worth saying out loud.
 */
export function importedCountText(status: CookieImportStatus): string {
  if (status.recorded === 0) return 'No cookies have been imported.'
  const where = status.source ? ` from ${status.source}` : ''
  if (status.present === status.recorded) {
    return `${status.present} imported cookie${status.present === 1 ? '' : 's'}${where}.`
  }
  return `${status.present} of ${status.recorded} imported cookies${where} are still here — the rest have expired.`
}

/**
 * Whether the panel should explain the operating system's permission dialog.
 *
 * The sentence — "macOS will ask your permission the first time" — used to be
 * unconditional, printed above the branch that decides whether the feature
 * exists here at all. `cookie-import.ts` answers `unsupported` for every
 * platform but darwin (the Windows DPAPI key schedule is not written), so a
 * Windows user read a paragraph about a macOS dialog and then, one line below
 * it, the notice "Importing cookies works on macOS only." Two claims that
 * cannot both be about the reader, on the same screen — the app describing
 * somebody else's computer.
 *
 * A predicate rather than moving the paragraph inside the supported arm of the
 * ternary, which renders identically. The renderer has no DOM in this repo's
 * suite — every settings test is `renderToStaticMarkup`, effects do not run,
 * and `imports` is therefore always `null` at paint — so a branch expressed
 * only as JSX position cannot be exercised from here at all. Expressed as a
 * function it can be, in both answers, in one run on a Mac. That is the same
 * trade `platform/host.ts` argues for in the main process.
 *
 * Optimistic while the status is unknown, matching the ternary below: `null`
 * means the read has not landed, and the alternative is that every macOS user
 * watches the sentence appear a moment after the pane does.
 */
export function explainsCookiePermission(
  bridge: SettingsBridge,
  imports: CookieImportStatus | null,
): boolean {
  // No channel means the build cannot import at all, so there is no permission
  // dialog to warn about — the same reason the notice below replaces the whole
  // block rather than sitting beside it.
  if (!bridge.importBrowserCookies || !bridge.browserCookieSources) return false
  return imports === null || imports.supported
}

/**
 * The whole count line: how many, and when.
 *
 * One function rather than two expressions in the JSX because the two halves
 * can contradict each other. A ledger can carry an `importedAt` with no
 * entries — a hand-edited file, or an older build that stamped one after a run
 * that wrote nothing — and the pieces then render as "No cookies have been
 * imported. Last imported just now.", which argues with itself. The time is
 * only ever shown next to something it is the time *of*.
 */
export function importedSummary(status: CookieImportStatus, now: number): string {
  const count = importedCountText(status)
  if (status.recorded === 0 || status.importedAt === null) return count
  return `${count} Last imported ${whenImported(status.importedAt, now)}.`
}

/**
 * What the Clear button is about to remove, in one line.
 *
 * The button was red, said "cannot be undone", and named no quantity at all —
 * so it asked for an irreversible decision about an unknown. These three numbers
 * have been available on the preload since the browser's own dialog was built
 * (`browser-session:info`); this pane simply never asked for them.
 *
 * Written as a sentence rather than a row of stats because the empty case is the
 * one that matters most and is the one a stat row renders worst: on a fresh
 * install "0 cookies · 0 sites · 0 B" reads as a fault, and "Nothing kept yet"
 * reads as the truth.
 */
export function keptSummary(stored: BrowserStored): string {
  const { cookieCount, domainCount, cacheBytes } = stored
  if (cookieCount === 0 && cacheBytes === 0) return 'Nothing kept yet.'
  if (cookieCount === 0) return `No cookies, and ${formatBytes(cacheBytes)} of cached pages.`
  const sites = `${domainCount} site${domainCount === 1 ? '' : 's'}`
  const cookies = `${cookieCount} cookie${cookieCount === 1 ? '' : 's'} from ${sites}`
  return cacheBytes === 0
    ? `${cookies}, and nothing cached.`
    : `${cookies}, and ${formatBytes(cacheBytes)} of cached pages.`
}

/* --------------------------------------------------- profiles and logins -- */

/**
 * The line under a profile's name.
 *
 * Two facts and they are separate ones, which is the whole reason this is a
 * function rather than a badge: the profile a new tab opens into, and the
 * profile that cannot be deleted. They coincide on a fresh install and stop
 * coinciding the moment somebody adds a second and switches to it — at which
 * point a single "Default" badge is answering the wrong question. Somebody
 * looking at this list wants to know *which one am I browsing as*, and the
 * answer has to survive being the same row or a different one.
 *
 * Empty for a profile that is neither, because a row that has nothing to say
 * should say nothing rather than "Not in use", which reads like a fault.
 */
export function profileCaption(
  profile: { id: string; isDefault: boolean },
  activeId: string,
): string {
  const parts: string[] = []
  if (profile.id === activeId) parts.push('New tabs open in this one')
  if (profile.isDefault) parts.push('Cannot be deleted')
  return parts.join(' · ')
}

/**
 * What the saved-password list says above itself.
 *
 * Names the profile every time, including when there is nothing in it. The list
 * is scoped to whichever profile is active and there is no other clue on screen
 * that it is — so "Nothing saved yet" without a name is a sentence somebody can
 * reasonably read as "this app has never saved a password", walk away from, and
 * be wrong about, because theirs are all in the other profile.
 */
export function savedSummary(count: number, profileName: string): string {
  if (count === 0) {
    return `Nothing saved in ${profileName} yet. Signing in to a site in the browser offers to remember it.`
  }
  return `${count} saved login${count === 1 ? '' : 's'} in ${profileName}.`
}

/**
 * The confirm that stands behind "Forget them all".
 *
 * It names **every profile**, and that is not padding. `browser-password:forget-all`
 * empties the whole store rather than the active profile's share of it, and a
 * button sitting under a list headed with one profile's name would otherwise be
 * read as clearing that list. The count is the store's, for the same reason
 * `keptSummary` carries one: an irreversible button that names no quantity is
 * asking for a decision about an unknown.
 */
export function forgetAllConfirmText(total: number, faulted = false): string {
  /*
   * A faulted store has a count of zero, because nothing was read out of it —
   * so the ordinary sentence would ask somebody to confirm forgetting "all 0
   * saved passwords", which is both nonsense and a lie about what is in the
   * file. What is actually being deleted is a file whose contents cannot be
   * trusted and cannot be counted, and that is what this says.
   */
  if (faulted) {
    return 'Delete the saved-login file? Its contents did not verify, so what is in it is unknown, and this cannot be undone.'
  }
  if (total === 1) return 'Forget the one saved password? This is across every profile and cannot be undone.'
  return `Forget all ${total} saved passwords? This is across every profile and cannot be undone.`
}

/**
 * One saved login, as a row.
 *
 * Its own component, and exported, for the reason `UsageBarView` is: the rule
 * that matters here is a rule about *markup* — that nothing on this row is or
 * could become a password — and a rule about markup has to be checkable by
 * rendering the markup. Inside the pane it is unreachable from a test, because
 * the list is empty until an effect has run and this project's test setup has no
 * DOM to run one in.
 *
 * `now` is passed rather than read, so "Saved 3 hours ago" is a fact about a
 * clock the caller chose. The pane hands it `Date.now()`.
 */
export function SavedLoginRow({
  entry,
  now,
  onCopy,
  onForget,
}: {
  entry: SavedLoginSummary
  now: number
  onCopy(): void
  onForget(): void
}) {
  return (
    <li className="settings-url">
      <span className="settings-url-main">
        <span className="settings-url-address">{loginLabel(entry)}</span>
        {entry.updatedAt > 0 && (
          <span className="settings-url-note">Saved {whenImported(entry.updatedAt, now)}</span>
        )}
      </span>
      {/*
        Copy, never Reveal.

        The password is put on the clipboard by the main process and is never
        sent to this side — see `browser-passwords.ts`, which keeps it in four
        places and lists the React tree as none of them. A Reveal button would
        need a channel that returns the string, and that channel is the single
        line that undoes the whole design. The title says where it goes, because
        a button that appears to do nothing is how somebody presses it four
        times.
      */}
      <Button onClick={onCopy} title="Put this password on the clipboard. It is not shown here.">
        Copy
      </Button>
      <Button tone="danger" onClick={onForget}>
        Forget
      </Button>
    </li>
  )
}

export interface BrowserSectionProps extends SectionProps {
  /**
   * Injectable, defaulting to the real preload.
   *
   * Only tests and the harness pass it. `resolveAccountsApi` already takes a
   * host for exactly this, and taking the resolved API instead of the host lets
   * a test hand over four functions rather than a fake `window.deck`.
   */
  accounts?: AccountsApi
}

export function BrowserSection({ values, save, bridge, loading, accounts }: BrowserSectionProps) {
  const meta = sectionMeta('browser')
  const [browsers, setBrowsers] = useState<DetectedBrowser[] | null>(null)
  const [urls, setUrls] = useState<DevUrl[] | null>(null)
  const [problems, setProblems] = useState<string[]>([])
  const [scanning, setScanning] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [confirmClear, setConfirmClear] = useState(false)
  /** Null until the read lands, so the summary line is absent rather than "0". */
  const [stored, setStored] = useState<BrowserStored | null>(null)

  const [sources, setSources] = useState<CookieSource[] | null>(null)
  const [imports, setImports] = useState<CookieImportStatus | null>(null)
  const [importing, setImporting] = useState<string | null>(null)
  const [importNote, setImportNote] = useState<{ text: string; ok: boolean } | null>(null)
  const [confirmForget, setConfirmForget] = useState(false)
  /** Which profile is chosen, per browser. Defaults to the first, which is Default. */
  const [chosenProfile, setChosenProfile] = useState<Record<string, string>>({})

  /*
   * Profiles and saved logins, both reached through the browser's own bridge.
   *
   * `useMemo` with no dependency rather than a module-level constant: this file
   * is imported by tests that run without a `window`, and resolving at import
   * time would bind against whatever `globalThis.deck` was at that instant —
   * which in the harness is nothing, because the stub is installed after the
   * bundle loads.
   */
  const api = useMemo(() => accounts ?? resolveAccountsApi(), [accounts])
  const hasProfiles = profilesAvailable(api)
  const hasPasswords = passwordsAvailable(api)
  /** Null until the first read lands — see the note on `stored`. */
  const [profiles, setProfiles] = useState<ProfileState | null>(null)
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null)
  const [adding, setAdding] = useState(false)
  const [draft, setDraft] = useState('')
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)
  const [profileNote, setProfileNote] = useState<string | null>(null)
  /** Null until read; distinguishes "not asked yet" from "none saved". */
  const [logins, setLogins] = useState<SavedLoginSummary[] | null>(null)
  /** Every profile's, not the active one's — what "Forget them all" acts on. */
  const [loginTotal, setLoginTotal] = useState(0)
  const [canStore, setCanStore] = useState<boolean | null>(null)
  /**
   * Where the store is and whether it verified. Null until the answer lands and
   * on a preload that has no such channel, and nothing is drawn from it then.
   */
  const [store, setStore] = useState<PasswordStoreState | null>(null)
  const [confirmForgetAll, setConfirmForgetAll] = useState(false)
  const [loginNote, setLoginNote] = useState<string | null>(null)

  const startUrl = stringSetting(values, 'browser.startUrl')

  useEffect(() => {
    if (!bridge.listBrowsers) return
    void bridge.listBrowsers().then(
      (raw) => setBrowsers(toBrowsers(raw)),
      () => setBrowsers([]),
    )
  }, [bridge])

  const scan = useCallback(
    (browserId?: string) => {
      if (!bridge.scanBrowserTabs) return
      setScanning(true)
      setStatus(null)
      // A request object, which is what `chrome-import:scan` expects; the limit
      // keeps a machine with years of history from filling the panel.
      void bridge.scanBrowserTabs({ browserId, limit: 40 }).then(
        (raw) => {
          const result = toScanResult(raw)
          setUrls(result.urls)
          setProblems(result.problems.map((problem) => problem.message))
          setScanning(false)
        },
        (cause: unknown) => {
          setStatus(errorText(cause, 'Could not read that browser.'))
          setScanning(false)
        },
      )
    },
    [bridge],
  )

  /* -- cookies. Reads only; the import itself needs a press. */
  const refreshImports = useCallback(() => {
    if (!bridge.browserCookieImportStatus) return
    void bridge.browserCookieImportStatus().then(
      (raw) => setImports(toCookieImportStatus(raw)),
      () => setImports(null),
    )
  }, [bridge])

  useEffect(() => {
    if (!bridge.browserCookieSources) return
    void bridge.browserCookieSources().then(
      (raw) => setSources(toCookieSources(raw)),
      () => setSources([]),
    )
  }, [bridge])

  useEffect(refreshImports, [refreshImports])

  const runImport = useCallback(
    (source: CookieSource) => {
      if (!bridge.importBrowserCookies) return
      setImporting(`${source.browserId}/${source.profileId}`)
      setImportNote(null)
      void bridge
        .importBrowserCookies({ browserId: source.browserId, profileId: source.profileId })
        .then(
          (raw) => {
            const report = toCookieImportReport(raw)
            setImportNote({ text: report.message, ok: report.ok })
            setImporting(null)
            refreshImports()
          },
          (cause: unknown) => {
            setImportNote({
              text: errorText(cause, 'The import stopped before it could read anything.'),
              ok: false,
            })
            setImporting(null)
          },
        )
    },
    [bridge, refreshImports],
  )

  const forgetImported = useCallback(() => {
    if (!bridge.clearImportedCookies) return
    setConfirmForget(false)
    void bridge.clearImportedCookies().then(
      (raw) => {
        const removed = typeof raw === 'object' && raw !== null ? (raw as { removed?: unknown }).removed : 0
        const count = typeof removed === 'number' ? removed : 0
        setImportNote({
          text: `Removed ${count} imported cookie${count === 1 ? '' : 's'}. Sign-ins made inside the browser tab are untouched.`,
          ok: true,
        })
        refreshImports()
      },
      (cause: unknown) => {
        setImportNote({
          text: errorText(cause, 'Could not remove the imported cookies.'),
          ok: false,
        })
      },
    )
  }, [bridge, refreshImports])

  /* -- what the tab is holding. A read, and it is what makes Clear honest. */
  const refreshStored = useCallback(() => {
    if (!bridge.browserSessionInfo) return
    void bridge.browserSessionInfo().then(
      (raw) => setStored(toBrowserStored(raw)),
      // Silent on purpose: this is a garnish on a button that works either way,
      // and a warning about a failed count would be louder than the count.
      () => setStored(null),
    )
  }, [bridge])

  useEffect(refreshStored, [refreshStored])

  const clear = useCallback(() => {
    if (!bridge.clearBrowserData) return
    setConfirmClear(false)
    void bridge.clearBrowserData().then(
      (raw) => {
        setStatus(toClearResult(raw).message)
        // The numbers above the button are now wrong by definition — they are
        // what it just removed. Re-read rather than assume zero: the clear can
        // partly fail, and a summary that reported an empty browser while
        // cookies survived would be the pane lying about the thing it is for.
        refreshStored()
      },
      (cause: unknown) => setStatus(errorText(cause, 'Could not clear the browsing data.')),
    )
  }, [bridge, refreshStored])

  /* -- profiles. Every mutation answers with the whole state, so nothing here
        composes a new list out of the old one; it takes the one the main
        process just wrote. That is what stops this pane and the browser's own
        menu drifting apart when both are open. */
  const loadProfiles = useCallback(() => {
    if (!api.browserProfiles) return
    void api.browserProfiles().then(
      (raw) => setProfiles(readProfileState(raw)),
      () => setProfiles(null),
    )
  }, [api])

  useEffect(loadProfiles, [loadProfiles])

  /**
   * Take the state a mutation answered with — or, if it cannot be read, ask
   * again rather than believing it.
   *
   * `readProfileState` answers null for anything it cannot narrow, **including
   * an empty list**, which is right: a browser always has its default profile,
   * so a reply with no profiles in it is a reply that went wrong rather than a
   * browser with none. Writing that null straight into state would empty the
   * list on screen and leave somebody looking at a pane that says they have no
   * profiles while `browser-profiles.ts` still holds them all — the pane lying
   * about the one thing it is for, which is the failure this whole pass is
   * about. Re-reading is the honest move: it asks the question again instead of
   * inventing an answer.
   */
  const applyState = useCallback(
    (raw: unknown): ProfileState | null => {
      const next = readProfileState(raw)
      if (next === null) loadProfiles()
      else setProfiles(next)
      return next
    },
    [loadProfiles],
  )

  const activeProfile = profiles?.profiles.find((entry) => entry.id === profiles.activeId) ?? null

  const activate = useCallback(
    (id: string) => {
      if (!api.browserProfileActivate) return
      setProfileNote(null)
      void api.browserProfileActivate(id).then(
        (raw) => {
          const next = applyState(raw)
          const name = next?.profiles.find((entry) => entry.id === id)?.name ?? 'it'
          // Said every time, because it is the one thing about profiles that
          // surprises people: a `WebContents`' session is fixed when it is
          // constructed, so the page already on screen keeps the profile it
          // opened in. `browser-profiles.ts` carries the physics; this is the
          // sentence that stops a working switch reading as a broken one.
          setProfileNote(`Pages opened from now on use ${name}. A page already open keeps the one it started in.`)
        },
        (cause: unknown) => setProfileNote(errorText(cause, 'Could not switch profile.')),
      )
    },
    [api],
  )

  const createProfile = useCallback(() => {
    if (!api.browserProfileCreate) return
    const name = draft
    setDraft('')
    setAdding(false)
    setProfileNote(null)
    void api.browserProfileCreate(name).then(
      (raw) => applyState(raw),
      (cause: unknown) => setProfileNote(errorText(cause, 'Could not add that profile.')),
    )
  }, [api, applyState, draft])

  const renameProfile = useCallback(
    (id: string, name: string) => {
      if (!api.browserProfileRename) return
      setRenaming(null)
      setProfileNote(null)
      void api.browserProfileRename(id, name).then(
        (raw) => applyState(raw),
        (cause: unknown) => setProfileNote(errorText(cause, 'Could not rename that profile.')),
      )
    },
    [api],
  )

  const deleteProfile = useCallback(
    (id: string) => {
      if (!api.browserProfileDelete) return
      setConfirmDelete(null)
      setProfileNote(null)
      void api.browserProfileDelete(id).then(
        (raw) => applyState(raw),
        (cause: unknown) => setProfileNote(errorText(cause, 'Could not delete that profile.')),
      )
    },
    [api],
  )

  /* -- saved logins. Scoped to the active profile, counted across all of them. */
  const loadLogins = useCallback(() => {
    const state = profiles
    if (!api.browserPasswords || state === null) return
    void api.browserPasswords(state.activeId).then(
      (raw) => setLogins(readLoginList(raw)),
      () => setLogins([]),
    )
    /*
     * And the whole store's count, which is a different number.
     *
     * "Forget them all" empties every profile — that is what the channel does —
     * so the sentence in front of it has to be able to say how many that is.
     * One call per profile because the channel answers per profile; the list is
     * a handful of entries by construction (a profile is a directory somebody
     * made by hand), so this is a handful of synchronous file reads, not a
     * scan.
     */
    void Promise.all(
      state.profiles.map((profile) =>
        api.browserPasswords?.(profile.id).then(readLoginList, () => []) ?? Promise.resolve([]),
      ),
    ).then((lists) => setLoginTotal(lists.reduce((sum, list) => sum + list.length, 0)))
  }, [api, profiles])

  useEffect(loadLogins, [loadLogins])

  /*
   * Three facts about the store, from one call where the preload has it.
   *
   * `browser-password:state` answers whether saving works, where the file is,
   * and whether that file verified. The older `:available` channel answers only
   * the first, and is kept as the fallback so a preload from before this update
   * still draws a correct — if quieter — panel rather than an empty one.
   */
  useEffect(() => {
    if (api.browserPasswordState) {
      void api.browserPasswordState().then(
        (raw) => {
          const read = readPasswordStoreState(raw)
          setStore(read)
          setCanStore(read === null ? null : read.available)
        },
        () => setStore(null),
      )
      return
    }
    if (!api.browserPasswordsAvailable) return
    void api.browserPasswordsAvailable().then(
      (value) => setCanStore(value === true),
      () => setCanStore(null),
    )
  }, [api])

  const forgetLogin = useCallback(
    (entry: SavedLoginSummary) => {
      if (!api.browserPasswordForget) return
      setLoginNote(null)
      void api.browserPasswordForget(entry.profileId, entry.origin, entry.username).then(
        () => loadLogins(),
        (cause: unknown) => setLoginNote(errorText(cause, 'Could not forget that login.')),
      )
    },
    [api, loadLogins],
  )

  const forgetAllLogins = useCallback(() => {
    if (!api.browserPasswordForgetAll) return
    setConfirmForgetAll(false)
    setLoginNote(null)
    void api.browserPasswordForgetAll().then(
      () => {
        setLoginNote('Every saved password has been removed.')
        // The file is gone, so a fault reported from it is gone too — and this
        // is the button the fault's own sentence points at. Leaving the warning
        // on screen after pressing it is a control that appears not to work.
        void api.browserPasswordState?.().then(
          (raw) => setStore(readPasswordStoreState(raw)),
          () => undefined,
        )
        loadLogins()
      },
      (cause: unknown) => setLoginNote(errorText(cause, 'Could not remove the saved passwords.')),
    )
  }, [api, loadLogins])

  const copyLogin = useCallback(
    (entry: SavedLoginSummary) => {
      if (!api.browserPasswordCopy) return
      setLoginNote(null)
      /*
       * The password does not come back. It never has and it must not start.
       *
       * The main process finds the row, writes the clipboard itself and answers
       * a boolean — so what this handler learns is *whether a copy happened*,
       * which is all a button needs to report. A channel that returned the
       * string would put a live credential into a React tree, into devtools and
       * into any future crash report, and would undo the entire design of
       * `browser-passwords.ts` in one line.
       */
      void api.browserPasswordCopy(entry.profileId, entry.origin, entry.username).then(
        (done) =>
          setLoginNote(
            done === true
              ? 'Copied to the clipboard.'
              : 'That login is no longer stored — the list has moved on.',
          ),
        (cause: unknown) => setLoginNote(errorText(cause, 'Could not copy that password.')),
      )
    },
    [api],
  )

  const blocked = browsers?.filter((browser) => browser.access === 'blocked') ?? []
  const blockedText = blockedNote(blocked)

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <Group title="Where new tabs open">
        {/*
          The address row and the thing that fills it in, under one heading.

          `omit` rather than a hand-placed control, so this stays generated: the
          two ids are named once each, in the two groups, and a browser setting
          added to the schema tomorrow lands in neither by accident rather than
          in both. `BrowserSection.test.tsx` pins that every declared row is
          drawn exactly once on this pane, which is the assertion that catches
          the third id being forgotten.
        */}
        <SettingList
          section="browser"
          values={values}
          save={save}
          disabled={loading}
          omit={['browser.persistSession']}
        />

        {/*
          One line, not three.

          What was here explained the mechanism (a read-only look at those
          files), then explained what it was *not* (signing in is separate —
          which the next heading already says). The reader needs one fact
          before pressing a button named after a browser: this only reads.
        */}
        <p className="settings-prose">
          Or take one from a browser you already use — its bookmarks, history and open tabs, read
          only.
        </p>

        {!bridge.listBrowsers || !bridge.scanBrowserTabs ? (
          <Notice tone="warn">{missingChannelNote('Reading installed browsers')}</Notice>
        ) : (
          <>
            <div className="settings-chips">
              {(browsers ?? []).map((browser) => (
                <Button
                  key={browser.id}
                  onClick={() => scan(browser.id)}
                  disabled={scanning || browser.access === 'blocked'}
                  title={
                    browser.access === 'blocked'
                      ? `This app cannot read ${browser.name}’s data yet — see below.`
                      : undefined
                  }
                >
                  {browserButtonLabel(browser)}
                </Button>
              ))}
              <Button onClick={() => scan()} disabled={scanning}>
                {scanning ? 'Looking…' : 'Every browser'}
              </Button>
            </div>

            {browsers?.length === 0 && (
              <Notice tone="info">No Chromium-based browser was found on this machine.</Notice>
            )}

            {/* One notice, one remedy — see `blockedNote`. */}
            {blockedText && <Notice tone="warn">{blockedText}</Notice>}

            {urls !== null && urls.length === 0 && !scanning && (
              <Notice tone="info">Nothing local turned up in there.</Notice>
            )}

            {urls !== null && urls.length > 0 && (
              <ul className="settings-urls">
                {urls.map((hit) => (
                  <li key={hit.url} className="settings-url">
                    <span className="settings-url-main">
                      <span className="settings-url-address">{hit.url}</span>
                      <span className="settings-url-note">
                        {noteFor(hit)}
                      </span>
                    </span>
                    <Button
                      onClick={() => {
                        save({ 'browser.startUrl': hit.url })
                        setStatus(`Start page set to ${hit.url}`)
                      }}
                      disabled={hit.url === startUrl}
                    >
                      {hit.url === startUrl ? 'Start page' : 'Use it'}
                    </Button>
                  </li>
                ))}
              </ul>
            )}

            {problems.map((problem) => (
              <Notice key={problem} tone="warn">
                {problem}
              </Notice>
            ))}
          </>
        )}
      </Group>

      <Group title="Cookies and sign-ins">
        {/* The other half of the generated rows — see the `omit` note above. */}
        <SettingList
          section="browser"
          values={values}
          save={save}
          disabled={loading}
          omit={['browser.startUrl']}
        />

        {/*
          Two paragraphs down to one, and the sentences that survived are the
          ones with a cost behind them.

          Cut: that Chromium encrypts its store with a keychain key (mechanism —
          the user meets the consequence as a system dialog either way), that
          saying no imports nothing (what "no" means needs no explanation), and
          the isolated-tab clause, which the "Per-tab isolation" block below
          says again in full.

          Kept, deliberately: the permission dialog and what a cookie *is*.
          This button hands another application's live credentials to this one,
          and a person who presses it without knowing that has been misled by
          the shortening rather than helped by it.

          The permission sentence moved *inside* the supported branch, and that
          is the whole of a Windows fix. It used to sit here, above the branch,
          asserting "macOS will ask your permission the first time" to everyone
          — so a Windows user read a sentence about a macOS dialog and then, one
          line below it, a notice saying the feature does not exist on their
          machine. Two claims that cannot both be about the reader. Inside the
          branch the noun is true by construction rather than by a platform
          check, because the branch is the platform check: `imports.supported`
          is only ever true where the key schedule is implemented, which today
          is macOS alone (`cookie-import.ts` answers `unsupported` elsewhere).
        */}
        <p className="settings-prose">
          Copies cookies from another browser so a site behind a login opens signed in. They are
          the credentials that keep you signed in, kept in this tab’s own store and never sent
          anywhere.
        </p>

        {explainsCookiePermission(bridge, imports) && (
          <p className="settings-prose">
            <strong>macOS will ask your permission</strong> the first time — nothing is read
            until you press one of these.
          </p>
        )}

        {!bridge.importBrowserCookies || !bridge.browserCookieSources ? (
          <Notice tone="warn">{missingChannelNote('Importing cookies')}</Notice>
        ) : imports !== null && !imports.supported ? (
          <Notice tone="info">Importing cookies works on macOS only.</Notice>
        ) : (
          <>
            {groupSources(sources ?? []).map((group) => {
              const chosenId = chosenProfile[group.browserId] ?? group.profiles[0].profileId
              const source =
                group.profiles.find((profile) => profile.profileId === chosenId) ?? group.profiles[0]
              const busyId = `${source.browserId}/${source.profileId}`
              return (
                <div className="settings-chips" key={group.browserId}>
                  {group.profiles.length > 1 && (
                    <span className="settings-select-wrap">
                      <select
                        className="settings-select"
                        value={source.profileId}
                        aria-label={`${group.browserName} profile to import from`}
                        disabled={importing !== null}
                        onChange={(event) =>
                          setChosenProfile((prev) => ({
                            ...prev,
                            [group.browserId]: event.target.value,
                          }))
                        }
                      >
                        {group.profiles.map((profile) => (
                          <option key={profile.profileId} value={profile.profileId}>
                            {profile.profileName === profile.profileId
                              ? profile.profileId
                              : `${profile.profileName} (${profile.profileId})`}
                          </option>
                        ))}
                      </select>
                    </span>
                  )}
                  <Button
                    onClick={() => runImport(source)}
                    disabled={importing !== null || !source.keychainItem}
                  >
                    {importing === busyId
                      ? 'Asking the keychain…'
                      : `Import from ${group.browserName}`}
                  </Button>
                </div>
              )
            })}

            {sources?.length === 0 && (
              <Notice tone="info">
                No browser with a readable cookie database. macOS protects those files until this
                app has Full Disk Access.
              </Notice>
            )}

            {sources?.some((source) => !source.keychainItem) && (
              <Notice tone="info">
                Some browsers have no import button — this machine holds no key to decrypt their
                cookies with.
              </Notice>
            )}

            {imports !== null && (
              <p className="settings-prose">{importedSummary(imports, Date.now())}</p>
            )}

            {importNote && (
              <Notice tone={importNote.ok ? 'info' : 'warn'}>{importNote.text}</Notice>
            )}

            {!bridge.clearImportedCookies ? (
              <Notice tone="warn">{missingChannelNote('Clearing imported cookies')}</Notice>
            ) : confirmForget ? (
              // Inline, for the same reason the clear below is: two modals both
              // listen for Escape, so the inner one closes the settings window.
              <div className="settings-confirm">
                <span>Remove the imported cookies? Sign-ins made inside the browser tab stay.</span>
                <Button tone="danger" onClick={forgetImported}>
                  Remove them
                </Button>
                <Button onClick={() => setConfirmForget(false)}>Keep them</Button>
              </div>
            ) : (
              <Button
                tone="danger"
                onClick={() => setConfirmForget(true)}
                disabled={(imports?.recorded ?? 0) === 0}
              >
                Clear imported cookies
              </Button>
            )}
          </>
        )}
      </Group>

      {/*
        "Profile settings", and the block now manages the profiles that exist.

        It was a paragraph explaining that there was one profile and a throwaway
        one per tab, which was true the week it was written. `browser-profiles.ts`
        landed after it and builds a profile out of a persistent Electron
        partition — its own cookie jar, storage and cache in its own directory —
        so the paragraph became a screen telling somebody a feature was absent
        while the feature sat one window away in the browser's own menu. That is
        the same failure as a dead control wearing a different hat: the pane was
        wrong rather than merely thin.

        What it says is written for *"mostly non-technical vibe coders"*, which
        rules out the word partition and rules in the consequence: signed in here,
        signed out there.
      */}
      <Group title="Profiles">
        <p className="settings-prose">
          A profile is a separate set of logins and cookies. A site you sign into in one stays
          signed out in the others.
        </p>

        {!hasProfiles ? (
          <Notice tone="warn">{missingChannelNote('Browser profiles')}</Notice>
        ) : (
          <>
            <ul className="settings-profiles">
              {(profiles?.profiles ?? []).map((profile) => {
                // Held as the value rather than a boolean so the form below
                // narrows without an assertion — the shape `AccountsSection`
                // uses for the same job on the same markup.
                const editing = renaming?.id === profile.id ? renaming : null
                const isActive = profile.id === profiles?.activeId
                const caption = profileCaption(profile, profiles?.activeId ?? '')
                return (
                  <li key={profile.id} className="settings-profile">
                    <span className="settings-profile-main">
                      {editing ? (
                        <form
                          className="settings-inline-form"
                          onSubmit={(event) => {
                            event.preventDefault()
                            renameProfile(profile.id, editing.name)
                          }}
                        >
                          <input
                            className="settings-input"
                            value={editing.name}
                            autoFocus
                            aria-label={`Name for ${profile.name}`}
                            onChange={(event) =>
                              setRenaming({ id: profile.id, name: event.target.value })
                            }
                            onKeyDown={(event) => {
                              if (event.key === 'Escape') {
                                // Stopped here, or the settings window itself
                                // takes it and closes — the same reason the
                                // confirms on this pane are inline rather than
                                // nested dialogs.
                                event.stopPropagation()
                                setRenaming(null)
                              }
                            }}
                          />
                          <Button type="submit" tone="primary">
                            Save
                          </Button>
                          <Button onClick={() => setRenaming(null)}>Cancel</Button>
                        </form>
                      ) : (
                        <>
                          <span className="settings-profile-name">{profile.name}</span>
                          {caption !== '' && <span className="settings-url-note">{caption}</span>}
                        </>
                      )}
                    </span>

                    {!editing && (
                      <span className="settings-profile-actions">
                        {/* Disabled with a reason rather than hidden. A button
                            that vanishes on the row you are looking at makes
                            the list change shape as you switch, and the reason
                            it is greyed is the answer to "which one am I in?" */}
                        <Button
                          disabled={isActive}
                          title={
                            isActive
                              ? 'New tabs already open in this profile.'
                              : 'New tabs will open in this profile.'
                          }
                          onClick={() => activate(profile.id)}
                        >
                          {isActive ? 'In use' : 'Use it'}
                        </Button>
                        <Button
                          onClick={() => setRenaming({ id: profile.id, name: profile.name })}
                        >
                          Rename
                        </Button>
                        {/* The default profile holds the partition every build
                            so far has used, so deleting it would sign somebody
                            out of everything they had before this feature
                            existed. The main process refuses; the button says
                            so instead of being refused. */}
                        {!profile.isDefault && (
                          <Button
                            tone="danger"
                            onClick={() => setConfirmDelete(profile.id)}
                            title="Delete this profile and everything signed in inside it"
                          >
                            Delete
                          </Button>
                        )}
                      </span>
                    )}

                    {confirmDelete === profile.id && (
                      <div className="settings-confirm">
                        <span>
                          Delete {profile.name}? Everything signed in inside it is signed out, and
                          this cannot be undone.
                        </span>
                        <Button tone="danger" onClick={() => deleteProfile(profile.id)}>
                          Delete it
                        </Button>
                        <Button onClick={() => setConfirmDelete(null)}>Keep it</Button>
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>

            {/*
              Directly under the list, not under the Add button below it.

              The note is almost always the answer to "what did pressing Use it
              just do", and with the button between them it sat two controls
              away from the row that caused it — close enough to read, far
              enough to look like a statement about adding a profile. It also
              carries the errors from rename and delete, which are about rows in
              the list above it for the same reason.
            */}
            {profileNote && <Notice tone="info">{profileNote}</Notice>}

            {adding ? (
              <form
                className="settings-inline-form settings-add-account"
                onSubmit={(event) => {
                  event.preventDefault()
                  createProfile()
                }}
              >
                <input
                  className="settings-input"
                  value={draft}
                  autoFocus
                  placeholder="Work"
                  aria-label="Name for the new profile"
                  onChange={(event) => setDraft(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Escape') {
                      event.stopPropagation()
                      setAdding(false)
                    }
                  }}
                />
                <Button type="submit" tone="primary">
                  Add
                </Button>
                <Button onClick={() => setAdding(false)}>Cancel</Button>
              </form>
            ) : (
              <Button onClick={() => setAdding(true)}>Add a profile</Button>
            )}
          </>
        )}

        {/*
          The per-tab switch, described rather than duplicated: it is a property
          of one tab, so it belongs on that tab and this pane's job is to say the
          word exists and where to find it.

          Cut to one sentence and a clause. What went was the mechanism — that
          the private profile is held in memory and cannot see the others — which
          the switch's own tooltip in `Toolbar.tsx` already says in full, on the
          control, at the moment somebody is deciding. What stayed is the part
          that is a surprise afterwards: it does not survive a quit, and pressing
          it reloads the page you were on.
        */}
        <p className="settings-prose">
          One tab can also have its own, thrown away on quit — the tab’s{' '}
          <strong>Shared / Isolated</strong> switch. Switching reopens the page.
        </p>
      </Group>

      {/*
        Saved passwords, under profiles because they are the same question.

        Which profile you are in decides which logins are in play, and the list
        below is the active one's — so it sits under the control that changes it
        rather than in a group of its own further down the pane.

        Nothing in this block has ever held a password and nothing in it can.
        `SavedLoginSummary` carries an origin, a username and a timestamp, and
        the button says Copy rather than Reveal because the main process writes
        the clipboard itself and answers only whether it did. See
        `browser-passwords.ts`.
      */}
      <Group title="Saved passwords">
        {!hasPasswords ? (
          <Notice tone="warn">{missingChannelNote('Saved passwords')}</Notice>
        ) : (
          <>
            {/*
              Two facts, and the second is the one that prevents a bad surprise:
              matching is exact, so a login saved for one address is never
              offered on a neighbouring one. `browser-passwords.ts` argues the
              trade at length — Chrome groups by registrable domain and this
              deliberately does not, because guessing wrong means offering a bank
              password to a subdomain somebody else controls.
            */}
            <p className="settings-prose">
              Kept in this machine’s secure store, and offered back only on the site they came
              from. A page an agent opened is never filled in automatically — the browser offers
              the login on the page instead, and it goes in when you press it.
            </p>

            {/*
              What is stored, and where it is.

              "This machine’s secure store" is a sentence that sounds like an
              answer and is not one: it names no file, nothing to look at and
              nothing to delete. This names the file, says what is in it, and
              puts a button next to it — because a path in a paragraph is
              something somebody has to select, copy and paste into a Go-to-Folder
              box, and the same information with the work already done is one
              press. See `browser-passwords.ts` for what the bytes are.
            */}
            {store !== null && store.path !== '' && (
              <p className="settings-prose">
                One file, encrypted with a key held in this machine’s login keychain:{' '}
                <code>{store.path}</code>. It holds the site, the username and the password of every
                saved login, in every profile, and nothing else.{' '}
                {store.exists && api.browserPasswordShowFile ? (
                  <Button
                    onClick={() => {
                      void api.browserPasswordShowFile?.().then(
                        (shown) =>
                          setLoginNote(
                            shown === true ? null : 'There is no file yet — nothing has been saved.',
                          ),
                        (cause: unknown) => setLoginNote(errorText(cause, 'Could not show the file.')),
                      )
                    }}
                  >
                    Show me the file
                  </Button>
                ) : null}
              </p>
            )}

            {/*
              A store that decrypted and then failed its own digest.

              Drawn instead of, and above, everything else in this block — the
              list below it is empty, and an empty list with no explanation is
              read as "nothing was ever saved", which is the one conclusion that
              makes somebody save it all again into a file being edited by
              whoever edited it last. `browser-passwords.ts` measures why an
              altered file is detectable at all.
            */}
            {store !== null && store.fault !== 'none' && (
              <Notice tone="warn">{store.message}</Notice>
            )}

            {/* `canStore` is null until the answer lands and on a machine that
                cannot be asked, and this says nothing then. A warning about
                encryption drawn on every first frame would be a fault reported
                before anything was checked. */}
            {canStore === false && (
              <Notice tone="warn">
                This machine has no secure store available, so nothing can be saved here. Passwords
                are never written to a plain file instead.
              </Notice>
            )}

            {/*
              Not while the store has faulted. The list below is empty because
              nothing was read, and "Nothing saved yet" over a warning that the
              file was altered is two sentences about one machine that cannot
              both be true — and the one somebody acts on is the reassuring one.
            */}
            {activeProfile && logins !== null && store?.fault !== 'tampered' && (
              // `unreadable` is not excluded here: there really is nothing
              // saved *on this machine*, the notice above explains the file, and
              // the summary is the line that says which profile the list below
              // belongs to.
              <p className="settings-prose">{savedSummary(logins.length, activeProfile.name)}</p>
            )}

            <ul className="settings-urls">
              {(logins ?? []).map((entry) => (
                <SavedLoginRow
                  key={`${entry.origin}|${entry.username}`}
                  entry={entry}
                  now={Date.now()}
                  onCopy={() => copyLogin(entry)}
                  onForget={() => forgetLogin(entry)}
                />
              ))}
            </ul>

            {loginNote && <Notice tone="info">{loginNote}</Notice>}

            {!api.browserPasswordForgetAll ? null : confirmForgetAll ? (
              // Inline for the same reason as the two above: a nested dialog's
              // Escape closes the settings window behind it.
              <div className="settings-confirm">
                <span>{forgetAllConfirmText(loginTotal, store?.fault === 'tampered')}</span>
                <Button tone="danger" onClick={forgetAllLogins}>
                  Forget them all
                </Button>
                <Button onClick={() => setConfirmForgetAll(false)}>Keep them</Button>
              </div>
            ) : (
              <Button
                tone="danger"
                /*
                  Enabled while the store has faulted even though the count is
                  zero — the count is zero *because* nothing was read, and this
                  button is the exact thing the fault's own sentence tells
                  somebody to press. A control a message points at and that is
                  greyed out is the worst version of a dead control.
                */
                disabled={loginTotal === 0 && store?.fault !== 'tampered'}
                title={
                  store?.fault === 'tampered'
                    ? 'Deletes the file that did not verify, so passwords can be saved again.'
                    : loginTotal === 0
                      ? 'There are no saved passwords to forget.'
                      : 'Removes every saved password, in every profile.'
                }
                onClick={() => setConfirmForgetAll(true)}
              >
                Forget all saved passwords
              </Button>
            )}
          </>
        )}
      </Group>

      <Group title="What the browser has kept">
        {/*
          The count first, then the consequence.

          The button below is red and irreversible and used to name no quantity
          at all, which is an irreversible decision about an unknown. `stored` is
          null until the read lands and on any build whose preload predates the
          channel, and the line is simply absent then — a placeholder number
          would be a made-up one.
        */}
        {stored && <p className="settings-prose">{keptSummary(stored)}</p>}
        {/* The first sentence described where a folder lives. The one that
            survived is the one with a consequence in it. */}
        <p className="settings-prose">
          Clearing signs you out of everything in the browser tab, and cannot be undone.
        </p>
        {!bridge.clearBrowserData ? (
          <Notice tone="warn">{missingChannelNote('Clearing browsing data')}</Notice>
        ) : confirmClear ? (
          // Inline rather than a nested dialog: two modals both listen for
          // Escape on the window, so dismissing the inner one would close the
          // settings window behind it.
          <div className="settings-confirm">
            <span>Clear cookies, storage and cache for the browser tab?</span>
            <Button tone="danger" onClick={clear}>
              Clear it
            </Button>
            <Button onClick={() => setConfirmClear(false)}>Keep it</Button>
          </div>
        ) : (
          <Button tone="danger" onClick={() => setConfirmClear(true)}>
            Clear stored browsing data
          </Button>
        )}
      </Group>

      {status && <Notice tone="info">{status}</Notice>}
    </>
  )
}
