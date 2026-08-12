import { useEffect, useMemo, useState } from 'react'
// Relative, not '@shared/brand': vitest runs without the electron-vite alias
// config, so a test that imports this component cannot resolve the alias.
import { BRAND } from '../../../shared/brand'

/**
 * The MCP servers this session can already reach, listed read-only.
 *
 * Read-only is the honest ceiling here, and it follows from what chat mode is.
 * The only channel to the agent is characters typed into its terminal, and
 * there is no keystroke that makes the CLI call an MCP tool on the user's
 * behalf — the agent decides that, mid-turn, from the conversation. Deck *can*
 * dial these servers itself (the inspector does), but a tool called
 * from this app would run outside the session the user is talking to and would
 * not appear in the transcript, so a "Run" button here would be a different
 * feature wearing this one's clothes.
 *
 * What a typed message genuinely does is aim the agent: MCP tools are named
 * `mcp__<server>__<tool>`, so putting that prefix in the prompt names the
 * server unambiguously. That is what a row inserts.
 *
 * The list itself is the user's own configuration — `src/main/mcp-client.ts`
 * reads the same `~/.claude.json` the CLI does — so a server added with
 * `claude mcp add` shows up here without being entered twice.
 */

/** Channel this surface needs. Already on the bridge. */
export interface McpListBridge {
  listMcpServers(projectPath?: string | null): Promise<unknown>
}

export interface McpRow {
  id: string
  name: string
  scope: string
  transport: string
  enabled: boolean
  /** Why the CLI would not load it, when it would not. */
  disabledReason: string | null
}

type Load = { state: 'loading' } | { state: 'ready'; rows: McpRow[] } | { state: 'failed' }

interface Props {
  root: string
  onInsert: (text: string) => void
  onBack: () => void
  bridge?: McpListBridge
}

/**
 * Coerce the status list, which crosses the preload as `unknown`.
 *
 * Exported for its own test: the shapes here come from a module the renderer
 * cannot import, so the only way to keep the two honest is to state what is
 * read and check that a partial row degrades instead of throwing.
 */
export function readServers(response: unknown): McpRow[] | null {
  if (!Array.isArray(response)) return null
  const rows: McpRow[] = []
  for (const entry of response) {
    if (!entry || typeof entry !== 'object') continue
    const server = entry as Record<string, unknown>
    if (typeof server.id !== 'string' || typeof server.name !== 'string') continue
    rows.push({
      id: server.id,
      name: server.name,
      scope: typeof server.scope === 'string' ? server.scope : 'user',
      transport: typeof server.transport === 'string' ? server.transport : 'stdio',
      enabled: server.enabled !== false,
      disabledReason: typeof server.disabledReason === 'string' ? server.disabledReason : null,
    })
  }
  return rows
}

/** The namespace every tool on a server shares. */
export function toolPrefix(name: string): string {
  return `mcp__${name}__`
}

function resolveBridge(injected?: McpListBridge): McpListBridge | null {
  if (injected) return injected
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<McpListBridge> }).deck
  return host && typeof host.listMcpServers === 'function' ? (host as McpListBridge) : null
}

export function McpServers({ root, onInsert, onBack, bridge }: Props) {
  const resolved = resolveBridge(bridge)
  const [load, setLoad] = useState<Load>({ state: 'loading' })

  useEffect(() => {
    if (!resolved) {
      setLoad({ state: 'failed' })
      return
    }
    let live = true
    void resolved
      .listMcpServers(root === '' ? null : root)
      .then((response) => {
        if (!live) return
        const rows = readServers(response)
        setLoad(rows ? { state: 'ready', rows } : { state: 'failed' })
      })
      .catch(() => {
        if (live) setLoad({ state: 'failed' })
      })
    return () => {
      live = false
    }
  }, [resolved, root])

  const rows = useMemo(() => (load.state === 'ready' ? load.rows : []), [load])

  return (
    <div className="at-panel">
      <div className="at-head">
        <button type="button" className="at-back" onClick={onBack} aria-label="Back to the attach menu">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
            <path d="M15 6l-6 6 6 6" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <span className="at-title">Connectors</span>
      </div>

      {load.state === 'loading' ? <p className="at-note">Reading your MCP configuration…</p> : null}
      {load.state === 'failed' ? (
        <p className="at-note">The MCP server list is not available in this build.</p>
      ) : null}

      {load.state === 'ready' && rows.length === 0 ? (
        <p className="at-note">
          No MCP servers configured. Add one with <code>claude mcp add</code> and it appears here.
        </p>
      ) : null}

      {rows.length > 0 ? (
        <>
          <ul className="at-list" aria-label="Configured MCP servers">
            {rows.map((row) => (
              <li key={row.id}>
                <button
                  type="button"
                  className="at-row at-row-mcp"
                  onClick={() => onInsert(toolPrefix(row.name))}
                  title={`Put ${toolPrefix(row.name)} in the message`}
                >
                  <span className={`at-dot${row.enabled ? '' : ' at-dot-off'}`} aria-hidden="true" />
                  <span className="at-row-name">{row.name}</span>
                  <span className="at-row-dir">
                    {row.disabledReason ?? `${row.scope} · ${row.transport}`}
                  </span>
                </button>
              </li>
            ))}
          </ul>
          <p className="at-note at-note-quiet">
            Naming a server puts <code>mcp__…__</code> in your message so the agent knows which tools to
            reach for. It runs them inside the session — {BRAND.name} does not call them for you.
          </p>
        </>
      ) : null}
    </div>
  )
}
