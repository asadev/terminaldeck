import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  describeSchema,
  initialValues,
  McpSchemaForm,
  missingRequired,
  pruneArguments,
} from './McpSchemaForm'
import { McpAddForm, type McpAddResult } from './McpAddForm'
import { panelSpec } from '../shell/panels'
import { PageEmpty, PageNote } from './PageEmpty'
import './McpInspector.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/mcp-client.ts`, duplicated rather than
 * imported because the renderer tsconfig does not include `src/main`. Same
 * arrangement as `ReadinessPanel`; when the orchestrator lifts them into
 * `src/shared/types.ts` this block goes away and the imports point there.
 */
export type McpScope = 'user' | 'project' | 'local'
export type McpTransportKind = 'stdio' | 'http' | 'sse'
export type McpConnectionState = 'idle' | 'connecting' | 'ready' | 'failed' | 'closed'

export interface McpServerStatus {
  id: string
  name: string
  scope: McpScope
  transport: McpTransportKind
  command: string | null
  args: string[]
  url: string | null
  source: string
  enabled: boolean
  disabledReason: string | null
  unsupported: string | null
  state: McpConnectionState
  error: string | null
  serverInfo: { name: string; version: string } | null
  capabilities: string[]
  instructions: string | null
  pid: number | null
  connectedAt: number | null
  stderr: string
}

export interface McpToolInfo {
  name: string
  title: string | null
  description: string | null
  inputSchema: unknown
  outputSchema: unknown
}

export interface McpResourceInfo {
  uri: string
  name: string
  title: string | null
  description: string | null
  mimeType: string | null
}

export interface McpResourceTemplateInfo {
  uriTemplate: string
  name: string
  title: string | null
  description: string | null
  mimeType: string | null
}

export interface McpPromptInfo {
  name: string
  title: string | null
  description: string | null
  arguments: Array<{ name: string; description: string | null; required: boolean }>
}

export interface McpInventory {
  serverId: string
  tools: McpToolInfo[]
  resources: McpResourceInfo[]
  resourceTemplates: McpResourceTemplateInfo[]
  prompts: McpPromptInfo[]
  errors: Record<string, string>
  status: McpServerStatus
}

export interface McpCallResult {
  ok: boolean
  result: unknown
  error: string | null
  durationMs: number
  truncated: boolean
}

/** The slice of the preload bridge this panel needs. */
export interface McpBridge {
  listMcpServers(projectPath?: string | null): Promise<McpServerStatus[]>
  /**
   * The only writing call in this panel. It hands the request over as-is
   * because two of the three MCP scopes are decided by the directory the write
   * happens in, so the project path is part of the request rather than context
   * alongside it.
   */
  addMcpServer(request: Record<string, unknown>): Promise<McpAddResult>
  connectMcpServer(id: string, projectPath?: string | null): Promise<McpServerStatus>
  disconnectMcpServer(id: string): Promise<McpServerStatus | null>
  mcpInventory(id: string, projectPath?: string | null): Promise<McpInventory>
  callMcpTool(
    id: string,
    tool: string,
    args: Record<string, unknown>,
    projectPath?: string | null,
  ): Promise<McpCallResult>
  onMcpState(cb: (status: McpServerStatus) => void): () => void
}

export interface McpInspectorProps {
  /** Absolute path of the open project, so project- and local-scope servers appear. */
  projectPath?: string | null
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: McpBridge
}

/* ---------------------------------------------------------------- helpers -- */

const BRIDGE_METHODS = [
  'listMcpServers',
  'addMcpServer',
  'connectMcpServer',
  'disconnectMcpServer',
  'mcpInventory',
  'callMcpTool',
  'onMcpState',
] as const

/**
 * Read defensively: MCP is wired into the preload separately, so the panel has
 * to explain itself rather than crash if it mounts before that landed.
 */
function resolveBridge(): McpBridge | null {
  // Tests render this to static markup, where there is no window at all.
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Record<string, unknown> }).deck
  if (!host) return null
  if (BRIDGE_METHODS.some((method) => typeof host[method] !== 'function')) return null
  return host as unknown as McpBridge
}

export const STATE_LABEL: Record<McpConnectionState, string> = {
  idle: 'Not connected',
  connecting: 'Connecting',
  ready: 'Connected',
  failed: 'Failed',
  closed: 'Exited',
}

/** One readable line for what would actually be run. */
export function formatCommand(server: McpServerStatus): string {
  if (server.transport !== 'stdio') return server.url ?? ''
  // `args` is defensive rather than decorative: this renders a status pushed
  // over IPC, and a main process one version behind sends a shape this file's
  // types only promise. A spread of `undefined` throws and blanks the panel.
  const args = Array.isArray(server.args) ? server.args : []
  return [server.command ?? '', ...args].join(' ').trim()
}

/** Pull the plain text out of a tool result so the common case is readable. */
export function resultText(result: unknown): string | null {
  if (typeof result !== 'object' || result === null) return null
  const content = (result as { content?: unknown }).content
  if (!Array.isArray(content)) return null
  const parts = content
    .filter((block): block is { type: string; text: string } => {
      if (typeof block !== 'object' || block === null) return false
      const candidate = block as { type?: unknown; text?: unknown }
      return candidate.type === 'text' && typeof candidate.text === 'string'
    })
    .map((block) => block.text)
  return parts.length > 0 ? parts.join('\n') : null
}

function prettyJson(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2) ?? String(value)
  } catch {
    return String(value)
  }
}

type SectionKey = 'tools' | 'resources' | 'prompts'

interface InventoryState {
  loading: boolean
  data: McpInventory | null
  error: string | null
}

/* ------------------------------------------------------------- tool caller -- */

export interface ToolRowProps {
  tool: McpToolInfo
  disabled: boolean
  onCall(tool: McpToolInfo, args: Record<string, unknown>): Promise<McpCallResult>
}

export function ToolRow({ tool, disabled, onCall }: ToolRowProps) {
  const [open, setOpen] = useState(false)
  const description = useMemo(() => describeSchema(tool.inputSchema), [tool.inputSchema])
  const [values, setValues] = useState<Record<string, unknown>>(() => initialValues(description.fields))
  const [invalid, setInvalid] = useState<string[]>([])
  const [running, setRunning] = useState(false)
  const [result, setResult] = useState<McpCallResult | null>(null)

  const missing = missingRequired(description.fields, values)
  const blocked = missing.length > 0 || invalid.length > 0
  const onInvalidChange = useCallback((names: string[]) => setInvalid(names), [])

  const run = async (): Promise<void> => {
    setRunning(true)
    try {
      setResult(await onCall(tool, pruneArguments(values)))
    } catch (err) {
      setResult({
        ok: false,
        result: null,
        error: err instanceof Error ? err.message : String(err),
        durationMs: 0,
        truncated: false,
      })
    } finally {
      setRunning(false)
    }
  }

  const text = result?.ok ? resultText(result.result) : null

  return (
    <li className="mcp-item" data-open={open}>
      <button type="button" className="mcp-item-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="mcp-item-name">{tool.name}</span>
        {tool.title && tool.title !== tool.name && <span className="mcp-item-title">{tool.title}</span>}
        {/* The head's one-liner is elided; the body shows the description in
            full. Rendering both at once reads as the same sentence twice. */}
        {!open && <span className="mcp-item-summary">{tool.description ?? 'No description'}</span>}
      </button>

      {open && (
        <div className="mcp-item-body">
          {tool.description && <p className="mcp-item-description">{tool.description}</p>}

          <McpSchemaForm
            schema={tool.inputSchema}
            values={values}
            onChange={setValues}
            onInvalidChange={onInvalidChange}
            disabled={disabled || running}
            idPrefix={`tool-${tool.name}`}
          />

          <div className="mcp-run-row">
            <button
              type="button"
              className="mcp-run"
              disabled={disabled || running || blocked}
              onClick={() => void run()}
            >
              {running ? 'Running…' : 'Run tool'}
            </button>
            {missing.length > 0 && <span className="mcp-run-hint">Needs {missing.join(', ')}</span>}
            {invalid.length > 0 && <span className="mcp-run-hint">Fix the JSON in {invalid.join(', ')}</span>}
            {result && !running && (
              <span className="mcp-run-hint">
                {result.ok ? 'Succeeded' : 'Failed'} in {result.durationMs}ms
              </span>
            )}
          </div>

          {result && (
            <div className="mcp-result" data-ok={result.ok}>
              {result.error && <p className="mcp-result-error">{result.error}</p>}
              {text && <pre className="mcp-pre">{text}</pre>}
              {result.ok && (
                <details className="mcp-details">
                  <summary>Raw result{result.truncated ? ' (truncated)' : ''}</summary>
                  <pre className="mcp-pre">{prettyJson(result.result)}</pre>
                </details>
              )}
            </div>
          )}

          <details className="mcp-details">
            <summary>Input schema</summary>
            <pre className="mcp-pre">{prettyJson(tool.inputSchema)}</pre>
          </details>
          {tool.outputSchema != null && (
            <details className="mcp-details">
              <summary>Output schema</summary>
              <pre className="mcp-pre">{prettyJson(tool.outputSchema)}</pre>
            </details>
          )}
        </div>
      )}
    </li>
  )
}

/* ----------------------------------------------------------------- panel -- */

export function McpInspector({ projectPath = null, bridge }: McpInspectorProps) {
  const api = useMemo(() => bridge ?? resolveBridge(), [bridge])

  const [servers, setServers] = useState<McpServerStatus[]>([])
  const [loading, setLoading] = useState(true)
  const [listError, setListError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string | null>(null)
  const [section, setSection] = useState<SectionKey>('tools')
  const [inventories, setInventories] = useState<Record<string, InventoryState>>({})
  const [adding, setAdding] = useState(false)
  // Kept after the form closes: the CLI's own "Added X to local config" line is
  // the only confirmation that the write landed somewhere the user expected,
  // and closing the form on top of it would throw that away.
  const [added, setAdded] = useState<string | null>(null)

  /**
   * Ticket for the newest list request. Switching projects, or an impatient
   * second click on Reload, leaves two reads in flight; whichever the main
   * process answers last would otherwise win, and a slow read of the old
   * project would repaint over the new one's servers. Only the latest ticket
   * is allowed to write.
   */
  const listTicket = useRef(0)
  const inventoryTickets = useRef<Record<string, number>>({})

  const refresh = useCallback(async (): Promise<void> => {
    if (!api) {
      setLoading(false)
      return
    }
    const ticket = (listTicket.current += 1)
    setLoading(true)
    try {
      const next = await api.listMcpServers(projectPath)
      if (listTicket.current !== ticket) return
      setServers(next)
      setListError(null)
    } catch (err) {
      if (listTicket.current !== ticket) return
      setListError(err instanceof Error ? err.message : String(err))
    } finally {
      if (listTicket.current === ticket) setLoading(false)
    }
  }, [api, projectPath])

  useEffect(() => {
    void refresh()
  }, [refresh])

  // Inventories belong to the project they were read for; keeping them across a
  // switch would show one project's tools under another's server list.
  useEffect(() => {
    setInventories({})
    setExpanded(null)
    inventoryTickets.current = {}
  }, [projectPath])

  // One subscription for every row: a server that dies mid-session must go red
  // without the user touching anything.
  useEffect(() => {
    if (!api) return
    const unsubscribe = api.onMcpState((status) => {
      setServers((current) => current.map((server) => (server.id === status.id ? { ...server, ...status } : server)))
    })
    // A bridge that forgets to return its unsubscriber would make React throw
    // during cleanup and take the panel down on unmount.
    return () => {
      if (typeof unsubscribe === 'function') unsubscribe()
    }
  }, [api])

  const loadInventory = useCallback(
    async (id: string): Promise<void> => {
      if (!api) return
      const ticket = (inventoryTickets.current[id] ?? 0) + 1
      inventoryTickets.current[id] = ticket
      setInventories((current) => ({ ...current, [id]: { loading: true, data: current[id]?.data ?? null, error: null } }))
      try {
        const data = await api.mcpInventory(id, projectPath)
        if (inventoryTickets.current[id] !== ticket) return
        setInventories((current) => ({ ...current, [id]: { loading: false, data, error: null } }))
        setServers((current) => current.map((server) => (server.id === id ? { ...server, ...data.status } : server)))
      } catch (err) {
        if (inventoryTickets.current[id] !== ticket) return
        setInventories((current) => ({
          ...current,
          // Keep whatever was already listed: a failed refresh should not empty
          // a panel the user was reading.
          [id]: { loading: false, data: current[id]?.data ?? null, error: err instanceof Error ? err.message : String(err) },
        }))
      }
    },
    [api, projectPath],
  )

  const toggle = (server: McpServerStatus): void => {
    if (expanded === server.id) {
      setExpanded(null)
      return
    }
    setExpanded(server.id)
    setSection('tools')
    // Expanding is the connect gesture: a server nobody opened stays unspawned.
    // A read already in flight is left alone — re-collapsing and re-expanding
    // while a cold `npx` server downloads itself would otherwise queue a second
    // spawn of the same server behind the first.
    const held = inventories[server.id]
    if (!held?.data && !held?.loading && !server.unsupported) void loadInventory(server.id)
  }

  const disconnect = async (id: string): Promise<void> => {
    if (!api) return
    // Retire any listing in flight, so its result cannot land after the
    // disconnect and leave the panel showing tools for a server that is gone.
    inventoryTickets.current[id] = (inventoryTickets.current[id] ?? 0) + 1
    await api.disconnectMcpServer(id)
    setInventories((current) => ({ ...current, [id]: { loading: false, data: null, error: null } }))
    setExpanded((current) => (current === id ? null : current))
    void refresh()
  }

  const callTool = useCallback(
    (id: string) =>
      async (tool: McpToolInfo, args: Record<string, unknown>): Promise<McpCallResult> => {
        if (!api) throw new Error('Not connected to the main process.')
        return api.callMcpTool(id, tool.name, args, projectPath)
      },
    [api, projectPath],
  )

  if (!api) {
    return (
      <div className="mcp">
        <PageEmpty icon={panelSpec('mcp').icon} title="MCP is not available here">
          This window was opened without the MCP bridge, so there is nothing for this page to
          read.
        </PageEmpty>
      </div>
    )
  }

  /*
   * Nothing configured, nothing being typed, nothing being read.
   *
   * It is worth a name because it decides where the *one* Add affordance goes.
   * The panel used to draw two: a chip in the header, and an empty state under
   * it whose entire body was "Add one with the button above" — a caption about
   * a control, on the screen the control is on. While the list is empty the
   * empty state owns the action, in the accent, on the page's own centre line;
   * once there is a list to work with the header owns it, because an empty
   * state is no longer on screen to hold it.
   */
  const blank = !loading && servers.length === 0 && !listError && !adding

  return (
    <div className="mcp">
      {/*
        The intro and the Reload button stand down while the page is a blank.

        They are a left-aligned paragraph and a button pinned to the far right
        of the window; the empty state under them is a centred block. Nothing on
        the page shared an edge with anything else. With no servers there is
        also nothing for either of them to be about — the empty state says what
        an MCP server is and offers the same two ways to get one — so the page
        becomes one composition instead of three alignments.
      */}
      {!blank && (
      <header className="mcp-head">
        <div>
          {/* Both halves of this are load-bearing. Adding works from here now,
              so it says so; removing still does not, and a panel that stays
              quiet about the thing it cannot do reads as broken rather than as
              limited — which is the whole reason the Add button exists. */}
          <p className="mcp-subheading">
            These come from your Claude Code configuration. Adding one here writes to that same
            configuration, so Claude Code picks it up too. To remove one, run{' '}
            <code>claude mcp remove</code>.
          </p>
        </div>
        <div className="mcp-head-actions">
          {!blank && (
            <button
              type="button"
              className="mcp-add-open"
              onClick={() => {
                setAdding((open) => !open)
                setAdded(null)
              }}
            >
              {adding ? 'Close' : 'Add server'}
            </button>
          )}
          <button type="button" className="mcp-refresh" onClick={() => void refresh()} disabled={loading}>
            {loading ? 'Reading…' : 'Reload'}
          </button>
        </div>
      </header>
      )}

      {adding && (
        <McpAddForm
          projectPath={projectPath}
          onSubmit={(request) => api.addMcpServer(request)}
          onAdded={(message) => {
            setAdding(false)
            setAdded(message)
            void refresh()
          }}
          onCancel={() => setAdding(false)}
        />
      )}

      {added && !adding && <p className="mcp-added">{added}</p>}

      {listError && <p className="mcp-error">{listError}</p>}

      {loading && servers.length === 0 && !listError && (
        <PageNote page busy>
          Reading your MCP configuration…
        </PageNote>
      )}

      {/* This used to read "Add one with `claude mcp add`, then reload", with a
          comment arguing the action belonged in the CLI because this app reads
          that file and does not write it. The second half was true and the
          conclusion was not: the CLI writes it, and we can ask the CLI.
          (The backticks were once printed literally here — a markdown source
          file leaking into a window.) Hidden while the form is open, where it
          would be telling the user to do what they are already doing.

          It carries the action itself rather than pointing at the button above
          it. "Add one with the button above" is an empty state describing the
          furniture instead of offering the thing it is describing — and it is
          the same sentence said twice on one screen, once as a button and once
          as a caption about that button. */}
      {blank && (
        <PageEmpty
          icon={panelSpec('mcp').icon}
          title="No MCP servers configured"
          action={{
            label: 'Add a server',
            primary: true,
            onClick: () => {
              setAdding(true)
              setAdded(null)
            },
          }}
          hint={
            <>
              Or run <code>claude mcp add</code> in a terminal.
            </>
          }
          /* The reload the header would have carried, kept where the rest of
             the page is: somebody who has just added a server from a terminal
             needs it, and it is the only reason to reread an empty list. */
          extra={
            <button type="button" className="mcp-refresh" onClick={() => void refresh()} disabled={loading}>
              {loading ? 'Reading…' : 'Reload'}
            </button>
          }
        >
          An MCP server is a tool your agents can reach — a database, a browser, an API.
        </PageEmpty>
      )}

      <ul className="mcp-servers">
        {servers.map((server) => {
          const open = expanded === server.id
          const inventory = inventories[server.id]
          // Hoisted to a local so it narrows inside the callbacks below. The
          // property read `inventory.data` does not, which is what the cast
          // that used to sit on `countFor` was hiding.
          const data = inventory?.data ?? null
          return (
            <li className="mcp-server" key={server.id} data-state={server.state} data-open={open}>
              <div className="mcp-server-head">
                <button
                  type="button"
                  className="mcp-server-toggle"
                  aria-expanded={open}
                  onClick={() => toggle(server)}
                >
                  <span className="mcp-dot" data-state={server.state} aria-hidden="true" />
                  <span className="mcp-server-name">{server.name}</span>
                  <span className="mcp-tag" data-scope={server.scope}>
                    {server.scope}
                  </span>
                  <span className="mcp-tag">{server.transport}</span>
                  {!server.enabled && <span className="mcp-tag" data-warn="true">disabled</span>}
                  <span className="mcp-server-state">{STATE_LABEL[server.state]}</span>
                </button>

                {server.state === 'ready' && (
                  <button type="button" className="mcp-server-action" onClick={() => void disconnect(server.id)}>
                    Disconnect
                  </button>
                )}
              </div>

              <p className="mcp-server-command" title={server.source}>
                {formatCommand(server) || '—'}
              </p>

              {server.disabledReason && <p className="mcp-note">{server.disabledReason}</p>}
              {server.unsupported && <p className="mcp-note">{server.unsupported}</p>}
              {server.error && <p className="mcp-error">{server.error}</p>}

              {open && (
                <div className="mcp-server-body">
                  {server.serverInfo && (
                    <p className="mcp-meta">
                      {server.serverInfo.name} {server.serverInfo.version}
                      {server.pid !== null && <span className="mcp-meta-dim"> · pid {server.pid}</span>}
                      {server.capabilities.length > 0 && (
                        <span className="mcp-meta-dim"> · {server.capabilities.join(', ')}</span>
                      )}
                    </p>
                  )}
                  {server.instructions && <p className="mcp-instructions">{server.instructions}</p>}

                  {(server.stderr ?? '').trim().length > 0 && (
                    <details className="mcp-details">
                      <summary>Server output</summary>
                      <pre className="mcp-pre">{server.stderr}</pre>
                    </details>
                  )}

                  {inventory?.loading && <p className="mcp-note">Starting the server…</p>}
                  {inventory?.error && <p className="mcp-error">{inventory.error}</p>}

                  {data && (
                    <>
                      <div className="mcp-tabs" role="tablist">
                        {(['tools', 'resources', 'prompts'] as SectionKey[]).map((key) => (
                          <button
                            key={key}
                            type="button"
                            role="tab"
                            className="mcp-tab"
                            aria-selected={section === key}
                            onClick={() => setSection(key)}
                          >
                            {key}
                            <span className="mcp-count">{countFor(data, key)}</span>
                          </button>
                        ))}
                        <button
                          type="button"
                          className="mcp-server-action"
                          onClick={() => void loadInventory(server.id)}
                        >
                          Refresh
                        </button>
                      </div>

                      {/* `resourceTemplates` and `server` are real failures
                          that belong to no tab, so keying the message on the
                          section alone hid them entirely. */}
                      {sectionErrors(data.errors, section).map((message) => (
                        <p className="mcp-error" key={message}>
                          {message}
                        </p>
                      ))}

                      {section === 'tools' && (
                        <ul className="mcp-items">
                          {data.tools.length === 0 && <li className="mcp-note">No tools.</li>}
                          {data.tools.map((tool) => (
                            <ToolRow
                              key={tool.name}
                              tool={tool}
                              disabled={server.state !== 'ready'}
                              onCall={callTool(server.id)}
                            />
                          ))}
                        </ul>
                      )}

                      {section === 'resources' && (
                        <ul className="mcp-items">
                          {data.resources.length === 0 &&
                            data.resourceTemplates.length === 0 && <li className="mcp-note">No resources.</li>}
                          {data.resources.map((resource) => (
                            <li className="mcp-item" key={resource.uri}>
                              <div className="mcp-item-head" role="presentation">
                                <span className="mcp-item-name">{resource.name}</span>
                                <span className="mcp-item-summary">{resource.uri}</span>
                                {resource.mimeType && <span className="mcp-tag">{resource.mimeType}</span>}
                              </div>
                              {resource.description && <p className="mcp-item-description">{resource.description}</p>}
                            </li>
                          ))}
                          {data.resourceTemplates.map((template) => (
                            <li className="mcp-item" key={template.uriTemplate}>
                              <div className="mcp-item-head" role="presentation">
                                <span className="mcp-item-name">{template.name}</span>
                                <span className="mcp-item-summary">{template.uriTemplate}</span>
                                <span className="mcp-tag">template</span>
                              </div>
                              {template.description && <p className="mcp-item-description">{template.description}</p>}
                            </li>
                          ))}
                        </ul>
                      )}

                      {section === 'prompts' && (
                        <ul className="mcp-items">
                          {data.prompts.length === 0 && <li className="mcp-note">No prompts.</li>}
                          {data.prompts.map((prompt) => (
                            <li className="mcp-item" key={prompt.name}>
                              <div className="mcp-item-head" role="presentation">
                                <span className="mcp-item-name">{prompt.name}</span>
                                <span className="mcp-item-summary">{prompt.description ?? 'No description'}</span>
                              </div>
                              {prompt.arguments.length > 0 && (
                                <ul className="mcp-args">
                                  {prompt.arguments.map((arg) => (
                                    <li key={arg.name}>
                                      <code>{arg.name}</code>
                                      {arg.required && <span className="mcp-field-required">*</span>}
                                      {arg.description && <span className="mcp-meta-dim"> {arg.description}</span>}
                                    </li>
                                  ))}
                                </ul>
                              )}
                            </li>
                          ))}
                        </ul>
                      )}
                    </>
                  )}
                </div>
              )}
            </li>
          )
        })}
      </ul>
    </div>
  )
}

/** Resources and their templates are one tab, so the count has to add them up. */
export function countFor(inventory: McpInventory, section: SectionKey): number {
  if (section === 'tools') return inventory.tools.length
  if (section === 'prompts') return inventory.prompts.length
  return inventory.resources.length + inventory.resourceTemplates.length
}

/** Which of `inventory.errors` the given tab should show. */
const SECTION_ERROR_KEYS: Record<SectionKey, string[]> = {
  tools: ['tools'],
  // Templates share the resources tab, so their failure has to surface there.
  resources: ['resources', 'resourceTemplates'],
  prompts: ['prompts'],
}

/**
 * Messages for one tab, plus anything that belongs to no tab at all.
 *
 * The whole-server failures (`errors.server`) and the template listing were
 * being written into `errors` and then never read, because the panel looked up
 * exactly one key by the tab's own name. A section that fails silently is worse
 * than one that fails loudly.
 */
export function sectionErrors(errors: Record<string, string>, section: SectionKey): string[] {
  const owned = new Set(Object.values(SECTION_ERROR_KEYS).flat())
  const mine = SECTION_ERROR_KEYS[section]
  const messages: string[] = []
  for (const [key, message] of Object.entries(errors)) {
    if (!message) continue
    if (mine.includes(key) || !owned.has(key)) messages.push(message)
  }
  return [...new Set(messages)]
}
