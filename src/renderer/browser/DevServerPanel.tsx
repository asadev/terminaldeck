import { useCallback, useEffect, useState } from 'react'

/**
 * "The localhost link is not up" — the button that fixes it, where the links are.
 *
 * ## Why it sits on the start page
 *
 * Directly under the list of ports that *are* listening, because the two halves
 * answer the same question and the person asking it is looking at one screen.
 * The list above says what is running; this says what could be. Putting it in a
 * settings pane, or behind a menu, would mean the moment somebody discovers
 * nothing is on `:5173` is the moment they have to go somewhere else.
 *
 * ## One row per project, and the rows come from real files
 *
 * Not one button overall and not one per port. `src/main/dev-server.ts` argues
 * that at length; the short version is that a dev server is a script in a
 * project's `package.json`, so the project is the only unit that can have a
 * button, and the port does not exist until the thing is up.
 *
 * A project whose `package.json` declares no `dev`, `start` or `serve` is
 * **not drawn at all**. The main process reports it as `no-dev-script` and this
 * filters it out, which is the whole of "if no dev script can be found, offer no
 * button" on this side. A row with a greyed-out button would be worse than no
 * row: it is a promise that some future click might work.
 *
 * ## And nothing here draws itself unless the main process can serve it
 *
 * Every method on the bridge is optional and the component returns `null` when
 * they are missing. That is not defensive habit — it is the same negotiation the
 * phone gets from `welcome.capabilities`, applied to the window: a build whose
 * preload does not expose this feature must not paint a control for it.
 */

/**
 * Mirrors `DevServerState` in `src/main/dev-server.ts`.
 *
 * The field names are not a choice. `dev-server.contract.test.ts` compares this
 * declaration against that one as source text, because the renderer may not
 * import from `src/main` and a mismatch across an `unknown` seam is invisible to
 * the type checker — which is exactly how the port list once rendered every row
 * as a bare number with no process name and nothing failed.
 */
export interface DevServerView {
  folder: string
  status: string
  script?: string
  command?: string
  sessionId?: string
  port?: number
  url?: string
  note?: string
  message?: string
}

export interface DevServerBridge {
  /** Every open project's dev-server state. */
  devServers?(): Promise<unknown>
  /** Start one. Answers with `starting`; the rest arrives on the subscription. */
  startDevServer?(folder: string): Promise<unknown>
  /** Pushed state changes. Returns an unsubscribe function, like every other `on*`. */
  onDevServerState?(callback: (state: unknown) => void): () => void
}

interface Props {
  /** Open a URL in this browser tab — the same call a port row makes. */
  onOpen(url: string): void
  /** Injectable for tests; defaults to the preload bridge. */
  bridge?: DevServerBridge
}

/** The statuses this component knows how to draw. Anything else is dropped. */
const KNOWN = new Set(['no-dev-script', 'idle', 'starting', 'ready', 'failed'])

/**
 * The main process returns plain JSON, so nothing here can be trusted to be
 * typed — the same rule `readPorts` follows one file over.
 *
 * A row with an unrecognised status is dropped rather than drawn as something
 * else. This build knows five; a future main process that adds a sixth should
 * produce a missing row in an old window, not a row that lies about which state
 * it is in.
 */
export function readDevServer(value: unknown): DevServerView | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  if (typeof record.folder !== 'string' || record.folder === '') return null
  if (typeof record.status !== 'string' || !KNOWN.has(record.status)) return null
  const row: DevServerView = { folder: record.folder, status: record.status }
  if (typeof record.script === 'string') row.script = record.script
  if (typeof record.command === 'string') row.command = record.command
  if (typeof record.sessionId === 'string') row.sessionId = record.sessionId
  if (typeof record.port === 'number' && Number.isFinite(record.port)) row.port = record.port
  if (typeof record.url === 'string') row.url = record.url
  if (typeof record.note === 'string') row.note = record.note
  if (typeof record.message === 'string') row.message = record.message
  return row
}

export function readDevServers(value: unknown): DevServerView[] {
  if (!Array.isArray(value)) return []
  const rows: DevServerView[] = []
  for (const entry of value) {
    const row = readDevServer(entry)
    // Filtered here rather than at render time. A folder with no dev script is a
    // real answer from the main process and a row this panel must never draw;
    // dropping it once, at the edge, means no later branch can forget to.
    if (row && row.status !== 'no-dev-script') rows.push(row)
  }
  return rows
}

/**
 * The last component of a path, for the row's label.
 *
 * Both separators, because a Windows project path arrives with backslashes and
 * this code runs in a renderer that has no `path` module. The whole folder is
 * still shown — in the `title`, so it is available on hover without a row that
 * is mostly the parts of a path nobody is choosing between.
 */
export function projectName(folder: string): string {
  const parts = folder.split(/[\\/]/).filter((part) => part !== '')
  return parts[parts.length - 1] ?? folder
}

/**
 * Fold one pushed row into the list, keyed by folder.
 *
 * **Replaces rather than patches**, and that is the load-bearing line in this
 * file. The main process sends the whole state every time and its fields are not
 * independent — `port` and `url` exist only on `ready`, `message` only on
 * `failed` — so a merge that kept the fields the new state did not mention would
 * leave a stale `url` under a row that had gone back to idle. An address for a
 * server that is not there is the one wrong thing this panel can show, and it is
 * exactly what the tidier-looking `{...old, ...new}` produces.
 *
 * A folder that has lost its dev script loses its row, for the same reason it
 * never gained one: there is nothing to press.
 *
 * Pure, and exported, so the rule can be held to a test without a DOM.
 */
export function mergeRow(current: readonly DevServerView[], incoming: DevServerView): DevServerView[] {
  const next = current.filter((row) => row.folder !== incoming.folder)
  if (incoming.status === 'no-dev-script') return next
  next.push(incoming)
  // Sorted by name so a row does not jump to the end of the list the moment
  // somebody presses its button.
  return next.sort((a, b) => projectName(a.folder).localeCompare(projectName(b.folder)))
}

export function DevServerPanel({ onOpen, bridge }: Props) {
  const api = bridge ?? (globalThis as { deck?: DevServerBridge }).deck
  const list = api?.devServers
  const startOne = api?.startDevServer
  const subscribe = api?.onDevServerState
  const [rows, setRows] = useState<DevServerView[]>([])

  const apply = useCallback((incoming: DevServerView): void => {
    setRows((current) => mergeRow(current, incoming))
  }, [])

  useEffect(() => {
    if (!list) return
    let live = true
    list()
      .then((value) => {
        if (live) setRows(readDevServers(value))
      })
      .catch(() => {
        // Nothing is drawn rather than an error being reported. This is a second
        // way to do something the page already offers — the address bar and the
        // port list are both above it — so a panel that could not load itself
        // should get out of the way rather than take up the screen explaining.
        if (live) setRows([])
      })
    return () => {
      live = false
    }
  }, [list])

  useEffect(() => {
    if (!subscribe) return
    return subscribe((value) => {
      const row = readDevServer(value)
      if (row) apply(row)
    })
  }, [subscribe, apply])

  const press = (folder: string): void => {
    if (!startOne) return
    void startOne(folder)
      .then((value) => {
        const row = readDevServer(value)
        if (row) apply(row)
      })
      .catch(() => {
        // The push subscription is the real channel and a start that threw here
        // has still either started something or not. Saying "it failed" from a
        // rejected promise would be this component guessing at an outcome the
        // main process is about to report properly.
      })
  }

  // Nothing to serve it, or nothing to serve. Either way this is not a section.
  if (!list || !startOne || rows.length === 0) return null

  return (
    <>
      <p className="bw-start-note">Not running yet — start one:</p>
      <ul className="bw-start-list">
        {rows.map((row) => (
          <li key={row.folder}>
            <DevServerRow row={row} onOpen={onOpen} onStart={() => press(row.folder)} />
          </li>
        ))}
      </ul>
    </>
  )
}

/**
 * One project, in whichever of the four drawable states it is in.
 *
 * Split out so each state is a return rather than a chain of ternaries in the
 * middle of a list. The four are visibly different on purpose — a person
 * glancing at this has to be able to tell "press me" from "wait" from "it is up"
 * from "it did not work" without reading any of the words.
 *
 * Exported because it is the only part of this file a test can look at: there is
 * no DOM in this project's test run, so effects never fire and the panel above
 * renders empty by construction. This takes its row as a prop and can therefore
 * be held to its markup in all four states, which is the half that has to be
 * right anyway.
 */
export function DevServerRow({
  row,
  onOpen,
  onStart,
}: {
  row: DevServerView
  onOpen(url: string): void
  onStart(): void
}) {
  const name = projectName(row.folder)

  if (row.status === 'ready' && row.url && row.port !== undefined) {
    return (
      <button
        type="button"
        className="bw-start-port"
        title={row.folder}
        aria-label={`Open ${name} on localhost port ${row.port}`}
        onClick={() => onOpen(row.url as string)}
      >
        <span className="bw-start-port-num">:{row.port}</span>
        <span className="bw-start-port-cmd">{name}</span>
        <span className="bw-dev-tag bw-dev-tag-ready">running</span>
      </button>
    )
  }

  if (row.status === 'starting') {
    return (
      <div className="bw-dev-row bw-dev-row-busy" title={row.folder}>
        <span className="bw-dev-spinner" aria-hidden="true" />
        <span className="bw-dev-name">{name}</span>
        {/*
          The server's own latest line, which is what makes a slow boot read as
          progress. It is process output, so it is drawn as text and nothing
          else — never parsed, never interpreted, never turned into a percentage
          this app made up.
        */}
        <span className="bw-dev-note" role="status">
          {row.note ?? 'Starting…'}
        </span>
      </div>
    )
  }

  if (row.status === 'failed') {
    return (
      <div className="bw-dev-row" title={row.folder}>
        <span className="bw-dev-name">{name}</span>
        <span className="bw-dev-note bw-dev-note-failed" role="status">
          {row.message ?? 'It did not start.'}
        </span>
        <button type="button" className="bw-dev-start" onClick={onStart}>
          Try again
        </button>
      </div>
    )
  }

  return (
    <div className="bw-dev-row" title={row.folder}>
      <span className="bw-dev-name">{name}</span>
      {/* The exact command, so nobody has to trust this app about what it ran. */}
      <span className="bw-dev-cmd">{row.command}</span>
      <button type="button" className="bw-dev-start" onClick={onStart} aria-label={`Start ${name}`}>
        Start
      </button>
    </div>
  )
}
