import { useCallback, useEffect, useState } from 'react'
import { Button, Group, Notice, SectionHead, SettingList } from '../controls'
import { sectionMeta, stringSetting } from '../settings-schema'
import {
  errorText,
  missingChannelNote,
  toBrowsers,
  toClearResult,
  toCookieImportReport,
  toCookieImportStatus,
  toCookieSources,
  toScanResult,
  type CookieImportStatus,
  type CookieSource,
  type DetectedBrowser,
  type DevUrl,
  type SectionProps,
} from '../settings-bridge'

/**
 * Browser — the built-in tab, what it opens with, what it keeps, and who it
 * keeps it for.
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

export function BrowserSection({ values, save, bridge, loading }: SectionProps) {
  const meta = sectionMeta('browser')
  const [browsers, setBrowsers] = useState<DetectedBrowser[] | null>(null)
  const [urls, setUrls] = useState<DevUrl[] | null>(null)
  const [problems, setProblems] = useState<string[]>([])
  const [scanning, setScanning] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [confirmClear, setConfirmClear] = useState(false)

  const [sources, setSources] = useState<CookieSource[] | null>(null)
  const [imports, setImports] = useState<CookieImportStatus | null>(null)
  const [importing, setImporting] = useState<string | null>(null)
  const [importNote, setImportNote] = useState<{ text: string; ok: boolean } | null>(null)
  const [confirmForget, setConfirmForget] = useState(false)
  /** Which profile is chosen, per browser. Defaults to the first, which is Default. */
  const [chosenProfile, setChosenProfile] = useState<Record<string, string>>({})

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

  const clear = useCallback(() => {
    if (!bridge.clearBrowserData) return
    setConfirmClear(false)
    void bridge.clearBrowserData().then(
      (raw) => setStatus(toClearResult(raw).message),
      (cause: unknown) => setStatus(errorText(cause, 'Could not clear the browsing data.')),
    )
  }, [bridge])

  const blocked = browsers?.filter((browser) => browser.access === 'blocked') ?? []
  const blockedText = blockedNote(blocked)

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <SettingList section="browser" values={values} save={save} disabled={loading} />

      <Group title="Import addresses from a browser you already use">
        {/*
          One line, not three.

          What was here explained the mechanism (a read-only look at those
          files), then explained what it was *not* (signing in is separate —
          which the next heading already says). The reader needs one fact
          before pressing a button named after a browser: this only reads.
        */}
        <p className="settings-prose">
          Local addresses from another browser’s bookmarks, history and open tabs. Read-only.
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

      <Group title="Sign-ins: cookies from Chrome">
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
        */}
        <p className="settings-prose">
          Copies cookies from another Chromium browser so a dev server behind a login opens signed
          in. They are the credentials that keep you signed in, kept in the tab’s own store and
          never sent anywhere. <strong>macOS will ask your permission</strong> the first time —
          nothing is read until you press one of these.
        </p>

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

      <Group title="Per-tab isolation">
        {/*
          The second paragraph was a use-case essay and the reason a switch
          behaves the way it does. Both are for whoever built it. What a reader
          of this pane needs is where the switch is and what it costs them —
          the reopen, and the fact that an isolated tab is genuinely blind to
          everything else.
        */}
        <p className="settings-prose">
          Every tab shares one session, which is what keeps you signed in. A tab’s{' '}
          <strong>Shared / Isolated</strong> switch gives it a cookie jar of its own — in memory,
          thrown away when the app quits, and blind to imported cookies and the other tabs.
          Switching reopens the page.
        </p>
      </Group>

      <Group title="Stored browsing data">
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
