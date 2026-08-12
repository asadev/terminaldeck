import { useCallback, useEffect, useState } from 'react'
import { Button, Group, Notice, SectionHead, SettingList } from '../controls'
import { sectionMeta, stringSetting } from '../settings-schema'
import {
  errorText,
  missingChannelNote,
  toBrowsers,
  toClearResult,
  toScanResult,
  type DetectedBrowser,
  type DevUrl,
  type SectionProps,
} from '../settings-bridge'

/**
 * Browser — the built-in tab, what it opens with, and what it keeps.
 *
 * ## What "import from an installed browser" honestly is
 *
 * It imports the local dev addresses already in another browser's bookmarks,
 * history and open tabs, so a start page does not have to be retyped. It does
 * **not** copy cookies or logins, and this panel says so rather than implying
 * otherwise: Chromium encrypts its cookie store with a key held in the login
 * keychain, so copying the file out produces ciphertext, and prompting for the
 * keychain to decrypt another application's secrets is not something a settings
 * panel should be doing quietly. `chrome-import.ts` is deliberately read-only
 * for the same reason.
 */

const SOURCE_LABEL: Record<DevUrl['source'], string> = {
  bookmark: 'Bookmark',
  history: 'History',
  session: 'Open tab',
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

export function BrowserSection({ values, save, bridge, loading }: SectionProps) {
  const meta = sectionMeta('browser')
  const [browsers, setBrowsers] = useState<DetectedBrowser[] | null>(null)
  const [urls, setUrls] = useState<DevUrl[] | null>(null)
  const [problems, setProblems] = useState<string[]>([])
  const [scanning, setScanning] = useState(false)
  const [status, setStatus] = useState<string | null>(null)
  const [confirmClear, setConfirmClear] = useState(false)

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

  const clear = useCallback(() => {
    if (!bridge.clearBrowserData) return
    setConfirmClear(false)
    void bridge.clearBrowserData().then(
      (raw) => setStatus(toClearResult(raw).message),
      (cause: unknown) => setStatus(errorText(cause, 'Could not clear the browsing data.')),
    )
  }, [bridge])

  const blocked = browsers?.filter((browser) => browser.access === 'blocked') ?? []

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <SettingList section="browser" values={values} save={save} disabled={loading} />

      <Group title="Import from a browser you already use">
        <p className="settings-prose">
          Finds the local addresses in another browser’s bookmarks, history and open tabs so you can
          pick one as the start page. It is a read-only look at those files. Cookies and logins are
          not copied — Chromium encrypts them with a key in your login keychain, and nothing here
          asks for that.
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
                >
                  {browser.name}
                  {browser.profiles.length > 1 ? ` (${browser.profiles.length} profiles)` : ''}
                </Button>
              ))}
              <Button onClick={() => scan()} disabled={scanning}>
                {scanning ? 'Looking…' : 'Every browser'}
              </Button>
            </div>

            {browsers?.length === 0 && (
              <Notice tone="info">No Chromium-based browser was found on this machine.</Notice>
            )}

            {blocked.map((browser) => (
              <Notice key={browser.id} tone="warn">
                {browser.note ??
                  `${browser.name}’s data is protected by the system. Grant Full Disk Access to read it.`}
              </Notice>
            ))}

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

      <Group title="Stored browsing data">
        <p className="settings-prose">
          The browser tab keeps its cookies, storage and cache in its own place, separate from
          anything else on this machine. Clearing it signs you out of whatever you were signed into
          in that tab and cannot be undone.
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
