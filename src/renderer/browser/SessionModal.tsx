import { useCallback, useEffect, useState } from 'react'
import { HoverNote } from '../components/HoverNote'
import { Modal } from '../components/Modal'
import type { BrowserBridge, BrowserSessionInfo, CookieDomain } from './bridge'

interface Props {
  open: boolean
  bridge: BrowserBridge
  /**
   * Whose jar this is. `''` means the profile that is switched on.
   *
   * The dialog used to have no way to ask about anything else, which is the
   * limitation the profile menu inherited: a row could not say what it held
   * because nothing under it could answer. Every call below carries it.
   */
  profileId?: string
  /** That profile's name, drawn as the badge in the header. */
  profileName?: string
  onClose(): void
  /**
   * True when the tab this was opened from is on a partition of its own.
   *
   * Everything below reads the *shared* session, which is the only one with
   * anything worth managing — an isolated tab's jar is in memory and dies with
   * the tab. Saying nothing would be the misleading part: the dialog would list
   * cookies the tab in front of it cannot see, under a Clear button that does
   * not touch what that tab is signed into.
   */
  isolated?: boolean
}

/** Bytes, rounded the way a person reads them. */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  const units = ['B', 'kB', 'MB', 'GB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`
}

/**
 * What the browser has kept, and how to throw it away.
 *
 * ## Why there are no cookie values here
 *
 * There is nothing to reveal. The main process strips values before the list
 * crosses the bridge, because those values *are* the logins this panel exists
 * to explain — putting them in a React tree to be shown behind a "reveal"
 * button would mean the app now holds every session token the user has, in a
 * place a crash report can reach.
 *
 * ## Why opening this hides the page
 *
 * The guest view is a native layer above the whole React tree, so a dialog
 * would open underneath the website. The workspace parks the view while this is
 * open and puts it back on close; that is why this component takes no children
 * and does its own loading — it exists for exactly as long as the page is
 * hidden, and the shorter that is, the better.
 */
export function SessionModal({
  open,
  bridge,
  profileId = '',
  profileName = '',
  onClose,
  isolated = false,
}: Props) {
  const [info, setInfo] = useState<BrowserSessionInfo | null>(null)
  const [domains, setDomains] = useState<CookieDomain[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setError(null)
    try {
      const [nextInfo, nextDomains] = await Promise.all([
        bridge.browserSessionInfo(profileId),
        bridge.browserCookies(profileId),
      ])
      setInfo(nextInfo)
      setDomains(nextDomains)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause))
    }
  }, [bridge, profileId])

  useEffect(() => {
    if (!open) return
    void load()
  }, [open, load])

  const run = async (work: () => Promise<unknown>): Promise<void> => {
    setBusy(true)
    try {
      await work()
      await load()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      open={open}
      // Whose jar, in the title, because this dialog is opened from a row in the
      // profile menu and there is more than one of them now. The sentence that
      // stood under it — where the data is kept and that it survives a restart —
      // is the *"long description"* rule, and the facts it stated are already
      // the `On disk` row and the `kept on disk` count below it.
      title={profileName === '' ? 'Cookies and site data' : `Cookies and site data — ${profileName}`}
      onClose={onClose}
      size="lg"
      footer={
        <>
          <button type="button" className="bw-text-button" disabled={busy} onClick={() => void load()}>
            Refresh
          </button>
          <button
            type="button"
            className="bw-danger"
            disabled={busy}
            onClick={() =>
              void run(async () => {
                await bridge.browserClearCookies(undefined, profileId)
                await bridge.browserClearStorage(undefined, profileId)
                await bridge.browserClearCache(profileId)
              })
            }
          >
            Sign out of everything
          </button>
        </>
      }
    >
      {error && <p className="bw-error">{error}</p>}

      {/* Three sentences stood here saying that an isolated tab's jar is in
          memory, on a partition of its own, and cannot be cleared from this
          dialog. Two words say which tab this is not about, and the explanation
          is behind the same ⓘ the Settings window uses — *"if somewhere it's
          very required, give the i icon like other ones, information icon in
          the settings, same way."* */}
      {isolated && (
        <p className="bw-muted">
          <span className="bw-tagpill">Isolated tab</span>
          <HoverNote label="Isolated tab">
            Its cookies are held in memory, on a partition of its own, and thrown away when the tab
            closes. Nothing below is what it is using.
          </HoverNote>
        </p>
      )}

      {info && (
        <dl className="bw-facts">
          <div>
            <dt>Partition</dt>
            <dd>
              <code>{info.partition}</code>
            </dd>
          </div>
          <div>
            <dt>Survives a restart</dt>
            <dd>{info.persistent ? 'Yes' : 'No'}</dd>
          </div>
          <div>
            <dt>On disk</dt>
            <dd>
              {info.storageExists ? (
                <code title={info.storagePath}>{info.storagePath}</code>
              ) : (
                'Nothing written yet'
              )}
            </dd>
          </div>
          <div>
            <dt>Cookies</dt>
            <dd>
              {info.cookieCount} across {info.domainCount} site
              {info.domainCount === 1 ? '' : 's'}
            </dd>
          </div>
          <div>
            <dt>Cache</dt>
            <dd>{formatBytes(info.cacheBytes)}</dd>
          </div>
        </dl>
      )}

      {domains.length === 0 ? (
        <p className="bw-muted">Nothing yet.</p>
      ) : (
        <ul className="bw-domains">
          {domains.map((domain) => (
            <li key={domain.domain}>
              <div className="bw-domain-head">
                <strong>{domain.domain}</strong>
                <span className="bw-muted">
                  {domain.cookies.length} cookie{domain.cookies.length === 1 ? '' : 's'}
                  {domain.persistent > 0 && `, ${domain.persistent} kept on disk`}
                </span>
                <span className="bw-spacer" />
                <button
                  type="button"
                  className="bw-text-button"
                  disabled={busy}
                  onClick={() =>
                    void run(async () => {
                      await bridge.browserClearCookies(domain.domain, profileId)
                      await bridge.browserClearStorage(domain.domain, profileId)
                    })
                  }
                >
                  Clear
                </button>
              </div>
              <ul className="bw-cookies">
                {domain.cookies.map((cookie) => (
                  <li key={`${cookie.name}-${cookie.path}`}>
                    <code>{cookie.name}</code>
                    <span className="bw-muted">{cookie.path}</span>
                    {cookie.secure && <span className="bw-tagpill">secure</span>}
                    {cookie.httpOnly && <span className="bw-tagpill">httpOnly</span>}
                    <span className="bw-muted">
                      {cookie.session ? 'this session' : 'kept'} · {formatBytes(cookie.valueBytes)}
                    </span>
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ul>
      )}
    </Modal>
  )
}
