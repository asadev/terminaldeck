import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import type { BrowserBridge, BrowserSessionInfo, CookieDomain } from './bridge'

interface Props {
  open: boolean
  bridge: BrowserBridge
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
export function SessionModal({ open, bridge, onClose, isolated = false }: Props) {
  const [info, setInfo] = useState<BrowserSessionInfo | null>(null)
  const [domains, setDomains] = useState<CookieDomain[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setError(null)
    try {
      const [nextInfo, nextDomains] = await Promise.all([
        bridge.browserSessionInfo(),
        bridge.browserCookies(),
      ])
      setInfo(nextInfo)
      setDomains(nextDomains)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause))
    }
  }, [bridge])

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
      title="Cookies and site data"
      description="Kept in the browser's own session, separate from the app, and across restarts."
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
                await bridge.browserClearCookies()
                await bridge.browserClearStorage()
                await bridge.browserClearCache()
              })
            }
          >
            Sign out of everything
          </button>
        </>
      }
    >
      {error && <p className="bw-error">{error}</p>}

      {isolated && (
        <p className="bw-muted">
          This tab is <strong>Isolated</strong>, so none of the below is what it is using. Its
          cookies are held in memory on a partition of its own and are thrown away when the tab
          closes — there is nothing here to clear for it.
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
            <dd>{info.persistent ? 'Yes' : 'No — this is a bug, tell someone'}</dd>
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
        <p className="bw-muted">No cookies yet. Sign in to a site and it will show up here.</p>
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
                      await bridge.browserClearCookies(domain.domain)
                      await bridge.browserClearStorage(domain.domain)
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
