import { useCallback, useEffect, useState, type FormEvent } from 'react'
import './StartPage.css'

/**
 * What a new browser tab shows before it has a page — and what it shows instead
 * of Chromium's error document when a page will not load.
 *
 * ## Two faults, one screen
 *
 * The panel used to open `http://localhost:3000` unconditionally, because that
 * is the default value of `browser.startUrl`. On the machine it was written on
 * something was always listening there. On his Windows PC nothing was, so the
 * very first thing Terminal Deck's browser ever showed him was Chromium's red
 * "connection refused" page — a developer artefact, in a product, with no way
 * out of it except knowing to type in the address bar above.
 *
 * So this page answers both halves of "what now":
 *
 *  - **Which localhost port?** Listed from the real process table (`lsof` on
 *    macOS and Linux, `netstat` + `tasklist` on Windows), never probed against a
 *    list of ports somebody guessed. Named where the OS names them, which is
 *    what makes the difference between a wall of numbers and a list that reads
 *    "5037 adb", "57211 Terminal".
 *  - **Or any address at all** — the field below, which is the same omnibox
 *    resolution the toolbar uses, so `localhost:5173` and `example.com` both
 *    work without a scheme.
 *
 * A failed load lands here too, with the sentence written by
 * `src/main/browser-error.ts` above the list. That is deliberate rather than
 * decorative: "nothing is listening on localhost:3000" is most useful directly
 * above the list of what IS listening.
 */

/**
 * Mirrors `DevPort` in `src/main/dev-ports.ts`. The field names are not a
 * choice: this read `command`/`likely` at first while main sent
 * `process`/`guessed`, so every row rendered as a bare port number with no
 * process beside it and nothing failed. `dev-ports.contract.test.ts` pins it.
 */
export interface DevPort {
  port: number
  /** The process holding the port, e.g. "node", "python3". */
  process: string
  /** True when the process could not be named and only the port answered. */
  guessed: boolean
}

export interface StartPageBridge {
  devPorts(force?: boolean): Promise<unknown>
}

/** A load that failed, as the main process described it. */
export interface StartPageFailure {
  /** One written sentence — see `src/main/browser-error.ts`. */
  message: string
  /** The address that failed, so Try again knows what to retry. */
  url: string
}

interface Props {
  onOpen(url: string): void
  /**
   * Present when this page is standing in for Chromium's error document rather
   * than opening a new tab. Null is the ordinary new-tab case.
   */
  failure?: StartPageFailure | null
  /** Reload the address that failed. Absent hides the button rather than disabling it. */
  onRetry?: () => void
  /** Injectable for tests; defaults to the preload bridge. */
  bridge?: StartPageBridge
}

type Load =
  | { state: 'loading' }
  | { state: 'ready'; ports: DevPort[] }
  | { state: 'failed'; message: string }

/** The main process returns plain JSON, so nothing here can be trusted to be typed. */
export function readPorts(value: unknown): DevPort[] {
  if (!Array.isArray(value)) return []
  const out: DevPort[] = []
  for (const row of value) {
    if (typeof row !== 'object' || row === null) continue
    const rec = row as Record<string, unknown>
    const port = typeof rec.port === 'number' ? rec.port : Number(rec.port)
    if (!Number.isFinite(port) || port <= 0) continue
    out.push({
      port,
      process: typeof rec.process === 'string' ? rec.process : '',
      guessed: rec.guessed === true,
    })
  }
  // Named processes first — a port we could not attribute is the least useful
  // row — then by port so the order is stable between scans.
  return out.sort((a, b) => Number(a.guessed) - Number(b.guessed) || a.port - b.port)
}

/**
 * How a port is described in one line: `5037 adb`, or the port alone.
 *
 * Exported so the wording is testable without a DOM. The process name is
 * whatever the operating system said — never prettified, never mapped through a
 * table of "known" frameworks, because a guess about somebody else's setup is
 * exactly what `dev-ports.ts` exists to avoid.
 */
export function portSummary(entry: DevPort): string {
  return entry.process ? `${entry.port} ${entry.process}` : String(entry.port)
}

export function StartPage({ onOpen, failure = null, onRetry, bridge }: Props) {
  const api = bridge ?? (globalThis as { deck?: StartPageBridge }).deck
  const [load, setLoad] = useState<Load>({ state: 'loading' })
  const [address, setAddress] = useState('')

  const scan = useCallback(
    (force: boolean) => {
      if (!api?.devPorts) {
        setLoad({ state: 'failed', message: 'Port discovery is not available in this build.' })
        return
      }
      setLoad({ state: 'loading' })
      api
        .devPorts(force)
        .then((value) => setLoad({ state: 'ready', ports: readPorts(value) }))
        .catch(() => setLoad({ state: 'failed', message: 'Could not read the open ports.' }))
    },
    [api],
  )

  useEffect(() => scan(false), [scan])

  /*
   * Rescan whenever a *different* load fails.
   *
   * The cache in `dev-ports.ts` is four seconds wide and shared, so this is one
   * `lsof` at most and usually none — and it is the moment the list is most
   * likely to be stale, because the reason a page just failed is very often
   * that the server moved to another port.
   */
  const failedUrl = failure?.url ?? ''
  useEffect(() => {
    if (failedUrl) scan(true)
  }, [failedUrl, scan])

  const submit = (event: FormEvent): void => {
    event.preventDefault()
    const typed = address.trim()
    // Resolution — scheme-less hosts, search terms, refusals — belongs to
    // `omnibox.ts` and happens in the workspace's `navigate`. Duplicating any
    // of it here would give the app two address bars that disagree.
    if (typed) onOpen(typed)
  }

  return (
    <div className="bw-start">
      <div className="bw-start-inner">
        {failure ? (
          <>
            <h2 className="bw-start-title">This page did not open</h2>
            <p className="bw-start-note bw-start-failure" role="status">
              {failure.message}
            </p>
          </>
        ) : (
          <h2 className="bw-start-title">Open a page</h2>
        )}

        <form className="bw-start-form" onSubmit={submit}>
          <input
            className="bw-start-address"
            type="text"
            value={address}
            spellCheck={false}
            autoComplete="off"
            autoCorrect="off"
            aria-label="Address"
            placeholder="localhost:5173, or any address"
            onChange={(event) => setAddress(event.target.value)}
          />
          <button type="submit" className="bw-start-go" disabled={address.trim() === ''}>
            Open
          </button>
        </form>

        {failure && onRetry && (
          <p className="bw-start-note">
            <button type="button" className="bw-start-retry" onClick={onRetry}>
              Try {failure.url} again
            </button>
          </p>
        )}

        {load.state === 'loading' && <p className="bw-start-note">Looking for dev servers…</p>}

        {load.state === 'failed' && <p className="bw-start-note">{load.message}</p>}

        {load.state === 'ready' && load.ports.length === 0 && (
          <p className="bw-start-note">
            Nothing is listening on this machine. Start your dev server, then scan again — or type
            an address above.
          </p>
        )}

        {load.state === 'ready' && load.ports.length > 0 && (
          <>
            <p className="bw-start-note">Listening on this machine right now:</p>
            <ul className="bw-start-list">
              {load.ports.map((p) => (
                <li key={p.port}>
                  <button
                    type="button"
                    className="bw-start-port"
                    aria-label={`Open localhost port ${portSummary(p)}`}
                    onClick={() => onOpen(`http://localhost:${p.port}`)}
                  >
                    <span className="bw-start-port-num">:{p.port}</span>
                    {p.process && <span className="bw-start-port-cmd">{p.process}</span>}
                    {p.guessed && <span className="bw-start-port-tag">port only</span>}
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}

        {load.state !== 'loading' && (
          <button type="button" className="bw-start-refresh" onClick={() => scan(true)}>
            Scan again
          </button>
        )}
      </div>
    </div>
  )
}
