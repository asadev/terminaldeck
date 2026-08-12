import { useCallback, useEffect, useState } from 'react'
import './StartPage.css'

/**
 * What a new browser tab shows before it has a URL.
 *
 * It used to open `http://localhost:3000` unconditionally, so unless you
 * happened to be running something on that exact port the first thing the
 * panel ever showed you was Chrome's error page. Guessing one port is not
 * better than asking: this lists the dev servers actually listening right now,
 * discovered from the process table rather than probed.
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

interface Props {
  onOpen(url: string): void
  /** Injectable for tests; defaults to the preload bridge. */
  bridge?: StartPageBridge
}

type Load =
  | { state: 'loading' }
  | { state: 'ready'; ports: DevPort[] }
  | { state: 'failed'; message: string }

/** The main process returns plain JSON, so nothing here can be trusted to be typed. */
function readPorts(value: unknown): DevPort[] {
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

export function StartPage({ onOpen, bridge }: Props) {
  const api = bridge ?? (globalThis as { deck?: StartPageBridge }).deck
  const [load, setLoad] = useState<Load>({ state: 'loading' })

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

  return (
    <div className="bw-start">
      <div className="bw-start-inner">
        <h2 className="bw-start-title">Open a page</h2>

        {load.state === 'loading' && <p className="bw-start-note">Looking for dev servers…</p>}

        {load.state === 'failed' && <p className="bw-start-note">{load.message}</p>}

        {load.state === 'ready' && load.ports.length === 0 && (
          <p className="bw-start-note">
            Nothing is listening locally. Start your dev server, then refresh — or type an address
            above.
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
