import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  describeSchema,
  initialValues,
  McpSchemaForm,
  missingRequired,
  pruneArguments,
} from './McpSchemaForm'
import { McpAddForm, type McpAddResult } from './McpAddForm'
import { readFailure, withDeadline } from '../deadline'
import { recall, remember } from '../panel-cache'
import { rowDetail } from '../chat/attach/McpServers'
import { useMachines } from '../machines/useMachines'
import { thisMachine } from '../platform'
import { panelSpec } from '../shell/panels'
import { PageEmpty, PageNote } from './PageEmpty'
import { PageScope } from './PageScope'
import { Pill, PillRow } from './Pill'
import { HoverNote } from './HoverNote'
import { reportableMachines, useMachineServers, type MachineTarget } from './mcp-machines'
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
  /**
   * The other write, and the reason this page is a control panel rather than
   * half of one. Same shape as the add — the scope and the project path are
   * part of the request, because two of the three scopes are decided by the
   * directory the CLI is run in.
   */
  removeMcpServer(request: Record<string, unknown>): Promise<McpAddResult>
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
  'removeMcpServer',
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

/**
 * How long reading the configuration has to take.
 *
 * The read shells out to the Claude CLI, so it is a child process rather than
 * a file — which is exactly why it can hang: a CLI waiting on a network call,
 * a prompt nobody can answer, a binary that never execs. This page printed
 * "Reading your MCP configuration…" for the rest of the session when it did.
 * Twelve seconds is generous for a config read and finite, which is the point.
 */
const LIST_DEADLINE_MS = 12_000

/**
 * How long connecting to one server and listing what it exposes has to take.
 *
 * Much longer, and deliberately: expanding a row *spawns* the server, and a
 * cold `npx` one downloads itself first. Forty-five seconds is the difference
 * between a slow first connection and one that is never going to happen.
 */
const INVENTORY_DEADLINE_MS = 45_000

/**
 * How long the configuration stays good for without re-reading.
 *
 * Thirty seconds: the file is edited by `claude mcp add` and by hand, neither
 * of which happens while somebody is tabbing between this page and a terminal,
 * and Reload is right there for the moment it does.
 */
const SERVERS_FRESH_MS = 30_000

/**
 * The folder this page is reading, in one word.
 *
 * ## Why a page about a config file has to name a folder
 *
 * Asad, on this view: *"On MCP servers did nothing."* It was not doing nothing
 * — it was reading a *different* folder from the one he had open in the rail,
 * and saying "No servers yet" about it. Two of the three MCP scopes are keyed
 * on a working directory (`mcp-add.ts` spells out which), so "no servers" and
 * "wrong folder" are the same sentence on this page unless the folder is on it.
 * Source control puts its branch on the page for the same reason.
 *
 * The name, not the path: the path is 60 characters of prose and lives in the
 * `title`, where it costs nothing until it is wanted.
 */
function folderName(path: string | null): string {
  if (!path) return ''
  const parts = path.split(/[\\/]/).filter((part) => part !== '')
  return parts[parts.length - 1] ?? path
}

function serversKey(projectPath: string | null): string {
  return `mcp:servers:${projectPath ?? ''}`
}

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

/**
 * Which machine this page is a report on.
 *
 * Asad, with a PC and a server both connected and neither of them anywhere on
 * this page: *"Here also maybe we need to see which MCP servers or which
 * machine connected."*
 *
 * The pills exist only when there is a second machine to be — *"a dropdown only
 * when some exist. Hide it when empty"*, his most repeated note — and
 * `reportableMachines` decides which ones qualify, so a pill can never be
 * offered for a machine the reader would then have to be apologised to about.
 * See `mcp-machines.ts` for the three conditions and for what does and does not
 * cross the wire.
 *
 * Its own component because both halves of this page draw it, and because a row
 * of pills nobody can click in a static render is a thing worth having a test
 * of.
 */
export function MachinePills({
  targets,
  pick,
  onPick,
}: {
  targets: readonly MachineTarget[]
  pick: string | null
  onPick(machineId: string | null): void
}) {
  if (targets.length === 0) return null
  const here = thisMachine()
  return (
    <PillRow label="Which machine’s servers to show" lead="Report on">
      <Pill on={pick === null} title={`The configuration on ${here}`} onClick={() => onPick(null)}>
        {here}
      </Pill>
      {targets.map((entry) => (
        <Pill
          key={entry.machineId}
          on={pick === entry.machineId}
          title={`Read the configuration on ${entry.name}, for the folder ${entry.sessionTitle} runs in`}
          onClick={() => onPick(entry.machineId)}
        >
          {entry.name}
        </Pill>
      ))}
    </PillRow>
  )
}

/**
 * One paired machine's MCP servers, on this page rather than only inside that
 * machine's session.
 *
 * ## What it can say, and what it deliberately cannot
 *
 * Everything here is read-only, and that is a property of the wire rather than
 * a decision about the design. What crosses is the *list* — the six fields
 * `McpRow` carries — because that is what `ControlsReadingWire.connectors`
 * carries. Opening a server spawns a process on the machine that owns it;
 * adding or removing one runs the CLI in a directory on that machine. Neither
 * has a frame, so neither has a button: a row that expanded into nothing, or a
 * Remove that reached the wrong computer, is the dead control this window is
 * not allowed to have.
 *
 * ## Why it names a session
 *
 * Two of the three MCP scopes are keyed on a working directory — `mcp-add.ts`
 * spells out which — so "that machine's servers" is not a question with one
 * answer. What the far end resolves is *that session's folder*, and saying
 * which one is the difference between a list and a list you can check. It is
 * the same reason this page has named its own folder since it was written.
 */
function MachineServerList({ target }: { target: MachineTarget }) {
  const { status, rows, reload } = useMachineServers(target)

  const reloadButton = (
    <button type="button" className="mcp-refresh" onClick={reload} disabled={status === 'loading'}>
      {status === 'loading' ? 'Reading…' : 'Reload'}
    </button>
  )

  return (
    <>
      {/* The machine, the folder it resolved for, and which session it asked
          through — the three facts that make the list checkable. */}
      <PageScope
        path={target.cwd === '' ? null : target.cwd}
        machine={target.name}
        detail={`through ${target.sessionTitle}`}
      />

      {status === 'loading' ? (
        <PageNote page busy>
          Asking {target.name}…
        </PageNote>
      ) : status === 'unanswered' ? (
        <PageEmpty
          icon={panelSpec('mcp').icon}
          title={`${target.name} did not answer`}
          action={{ label: 'Try again', onClick: reload, primary: true }}
        >
          {/* Not "no servers": a machine that said nothing and a machine with
              none configured are different facts, and reporting the first as
              the second tells somebody their PC has no servers because a relay
              round trip went missing. */}
          The link to it is up, but nothing came back for that session.
        </PageEmpty>
      ) : rows.length === 0 ? (
        <PageEmpty
          icon={panelSpec('mcp').icon}
          title="No servers there"
          extra={reloadButton}
          hint={
            <span className="mcp-folder" title={target.cwd}>
              {folderName(target.cwd)}
            </span>
          }
        >
          Nothing is configured for that folder on {target.name}.
        </PageEmpty>
      ) : (
        <>
          <header className="mcp-head">
            <div className="mcp-subheading">
              <HoverNote label="Where these come from">
                {`Read on ${target.name}, from the configuration that applies to that session’s folder. Adding, removing and opening a server happen on the machine that runs it.`}
              </HoverNote>
            </div>
            <div className="mcp-head-actions">{reloadButton}</div>
          </header>
          <ul className="mcp-servers">
            {rows.map((row) => (
              <li className="mcp-server" key={row.id} data-state="idle">
                <div className="mcp-server-head">
                  {/* A row, not a button. Nothing on this page can open a
                      server on another machine, so nothing here looks like it
                      can — see the note on this component. */}
                  <span className="mcp-server-static">
                    <span className="mcp-dot" data-state="idle" aria-hidden="true" />
                    <span className="mcp-server-name">{row.name}</span>
                    {row.scope ? (
                      <span className="mcp-tag" data-scope={row.scope}>
                        {row.scope}
                      </span>
                    ) : null}
                    {row.transport ? <span className="mcp-tag">{row.transport}</span> : null}
                    {!row.enabled && (
                      <span className="mcp-tag" data-warn="true">
                        disabled
                      </span>
                    )}
                    {/* Whose server this is, on the row itself — the whole of
                        *"we need to see which MCP servers or which machine"*. */}
                    <span className="mcp-tag" data-machine="true">
                      {target.name}
                    </span>
                  </span>
                </div>
                <p className="mcp-server-command">{rowDetail(row) || '—'}</p>
              </li>
            ))}
          </ul>
        </>
      )}
    </>
  )
}

export function McpInspector({ projectPath = null, bridge }: McpInspectorProps) {
  const api = useMemo(() => bridge ?? resolveBridge(), [bridge])

  const [servers, setServers] = useState<McpServerStatus[]>([])
  const [loading, setLoading] = useState(true)
  const [listError, setListError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string | null>(null)
  const [section, setSection] = useState<SectionKey>('tools')
  const [inventories, setInventories] = useState<Record<string, InventoryState>>({})
  const [adding, setAdding] = useState(false)
  /**
   * Which machine's servers are on screen, or null for this one.
   *
   * Asad: *"as soon as we connect to one machine, that machine's things should
   * come here and start showing here… instead of the remote session."* This is
   * the choice that does it, and it is state rather than a route because it is
   * a question about what you are reading now — a page that came back pointed
   * at a PC that has since been unplugged would be worse than one that starts
   * where the folder is.
   */
  const [machinePick, setMachinePick] = useState<string | null>(null)

  /**
   * Ticket for the newest list request. Switching projects, or an impatient
   * second click on Reload, leaves two reads in flight; whichever the main
   * process answers last would otherwise win, and a slow read of the old
   * project would repaint over the new one's servers. Only the latest ticket
   * is allowed to write.
   */
  /** Which row's Remove is waiting for its second press, and any refusal. */
  const [removing, setRemoving] = useState<string | null>(null)
  const [removeError, setRemoveError] = useState<Record<string, string>>({})

  const listTicket = useRef(0)
  const inventoryTickets = useRef<Record<string, number>>({})

  const refresh = useCallback(
    /**
     * `seeded` is a re-read behind a list that is already on screen: the cache
     * gave us the servers this project had a moment ago and we are checking
     * them. No spinner, and a failure leaves the rows where they are.
     */
    async (seeded = false): Promise<void> => {
      if (!api) {
        setLoading(false)
        return
      }
      const ticket = (listTicket.current += 1)
      if (!seeded) setLoading(true)
      try {
        const next = await withDeadline(
          api.listMcpServers(projectPath),
          'Reading your MCP configuration',
          LIST_DEADLINE_MS,
        )
        if (listTicket.current !== ticket) return
        remember(serversKey(projectPath), next)
        setServers(next)
        setListError(null)
      } catch (err) {
        if (listTicket.current !== ticket || seeded) return
        setListError(readFailure(err))
      } finally {
        if (listTicket.current === ticket) setLoading(false)
      }
    },
    [api, projectPath],
  )

  useEffect(() => {
    /*
     * The servers this project had last time, before anything is asked for.
     *
     * Reading the configuration means asking the Claude CLI, which is a child
     * process; the shell unmounts this page every time a session takes the
     * window, so a trip out and back used to spawn it again and print
     * "Reading your MCP configuration…" over a list that had not changed.
     */
    const held = recall<McpServerStatus[]>(serversKey(projectPath), SERVERS_FRESH_MS)
    if (held) {
      setServers(held.value)
      setListError(null)
      setLoading(false)
      if (held.fresh) return
    }
    void refresh(Boolean(held))
  }, [refresh, projectPath])

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
        const data = await withDeadline(
          api.mcpInventory(id, projectPath),
          `Connecting to ${id}`,
          INVENTORY_DEADLINE_MS,
        )
        if (inventoryTickets.current[id] !== ticket) return
        setInventories((current) => ({ ...current, [id]: { loading: false, data, error: null } }))
        setServers((current) => current.map((server) => (server.id === id ? { ...server, ...data.status } : server)))
      } catch (err) {
        if (inventoryTickets.current[id] !== ticket) return
        setInventories((current) => ({
          ...current,
          // Keep whatever was already listed: a failed refresh should not empty
          // a panel the user was reading.
          [id]: { loading: false, data: current[id]?.data ?? null, error: readFailure(err) },
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

  /**
   * The row whose Remove is armed, and what the last attempt said.
   *
   * Armed rather than immediate, because this deletes a line out of another
   * application's configuration and there is no undo anywhere in this app. It
   * is the same two-press shape the GitHub card uses for Disconnect — the
   * second press is the danger-coloured one — rather than a modal, which would
   * be a second pattern for the same question.
   */
  const remove = async (server: McpServerStatus): Promise<void> => {
    if (!api) return
    setRemoving(null)
    setRemoveError((current) => ({ ...current, [server.id]: '' }))
    const result = await api.removeMcpServer({
      name: server.name,
      scope: server.scope,
      projectPath: projectPath ?? null,
    })
    if (!result.ok) {
      setRemoveError((current) => ({ ...current, [server.id]: result.message }))
      return
    }
    // The row leaving is the confirmation. Nothing is printed on success.
    setExpanded((current) => (current === server.id ? null : current))
    setRemoveError((current) => ({ ...current, [server.id]: '' }))
    void refresh()
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
          This window was opened without the MCP bridge.
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
  /*
   * The machines this page could report on, and the one it is reporting on.
   *
   * `useMachines` is the window's own read of the estate — the same hook the
   * rail and the New Session dialog use — so this page cannot come to disagree
   * with them about which machines are connected. The target is derived from
   * the pick rather than stored beside it, which is what makes a machine going
   * offline put the page back on this one instead of leaving it pointed at a
   * pill that is no longer there.
   */
  const estate = useMachines()
  const targets = useMemo(() => reportableMachines(estate.machines), [estate.machines])
  const target = targets.find((entry) => entry.machineId === machinePick) ?? null
  /** What to call this computer on a pill and on a row. */
  const here = thisMachine()

  /*
   * A machine's page instead of this one's, and an early return rather than a
   * branch wrapped around four hundred lines of markup.
   *
   * Every hook above has run by here, which is the only thing that makes this
   * safe — and it is what keeps the local half of the page exactly the markup
   * it was, rather than the same markup one indent deeper inside a ternary.
   */
  if (target !== null) {
    return (
      <div className="mcp">
        <MachinePills targets={targets} pick={target.machineId} onPick={setMachinePick} />
        <MachineServerList target={target} />
      </div>
    )
  }

  const blank = !loading && servers.length === 0 && !listError && !adding

  return (
    <div className="mcp">
      {/* Null, always: past the return above, the page is this machine's. */}
      <MachinePills targets={targets} pick={null} onPick={setMachinePick} />
      {/* What this list is: the configuration on this machine, for this folder.
          The page has named the folder since *"On MCP servers did nothing"* —
          it was reading a different one from the rail's — and it names the
          machine now for the same reason, one connected PC later. */}
      <PageScope path={projectPath} />
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
        <div className="mcp-subheading">
          {/*
            The sentence that used to stand here is behind the dot now.

            It said where the list comes from and that removing a server had to
            happen in a terminal. The first half is still here; the second half
            is gone because it is no longer true — every row carries a Remove
            now, and a page that sends its reader to a terminal to undo what its
            own button just did was the *"did nothing"* he was looking at.
            Asad, this round: *"I don't want any kind of long descriptions
            anywhere. Just if somewhere it's very required, give the i icon
            like other ones, information icon in the settings, same way."*
            `HoverNote` is that icon, and this is the same component Settings
            uses, so it behaves identically.
          */}
          <HoverNote label="Where these come from">
            {'Read from your Claude Code configuration.'}
          </HoverNote>
          {/* Which folder the list above is about — see `folderName`. */}
          {projectPath && (
            <span className="mcp-folder" title={projectPath}>
              {folderName(projectPath)}
            </span>
          )}
        </div>
        <div className="mcp-head-actions">
          {!blank && (
            <button
              type="button"
              className="mcp-add-open"
              /* Which machine it lands on, before it is pressed. A server is
                 added by running the CLI in a folder, which happens on the
                 machine that owns the file — so with a paired machine on the
                 pills beside this button, "Add server" is a question this
                 button has to answer rather than leave open. */
              title={`Adds to the configuration on ${here}`}
              onClick={() => setAdding((open) => !open)}
            >
              {adding ? 'Close' : targets.length > 0 ? `Add server on ${here}` : 'Add server'}
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
          onAdded={() => {
            setAdding(false)
            void refresh()
          }}
          onCancel={() => setAdding(false)}
        />
      )}

      {/*
        Nothing here any more.

        A green banner used to sit on the page for the rest of the session
        reading *"Added stdio MCP server auditprobe with command: node … to user
        config File modified: /Users/apple/.claude.json"* — the CLI's two lines
        concatenated into one ungrammatical paragraph, never dismissed. The row
        appearing in the list below is the confirmation, and it is the one that
        is still true a minute later. A failure still reaches the user: the form
        prints what the CLI refused with, in the form, where the fields are.
      */}

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
          /* Three words. It was "No MCP servers configured" over a sentence
             defining what an MCP server is — a definition, on the page called
             MCP servers, read by somebody who navigated there. */
          title="No servers yet"
          action={{
            label: targets.length > 0 ? `Add a server on ${here}` : 'Add a server',
            primary: true,
            onClick: () => setAdding(true),
          }}
          /* The reload the header would have carried, kept where the rest of
             the page is: somebody who has just added a server from a terminal
             needs it, and it is the only reason to reread an empty list. */
          extra={
            <button type="button" className="mcp-refresh" onClick={() => void refresh()} disabled={loading}>
              {loading ? 'Reading…' : 'Reload'}
            </button>
          }
          /* The folder it just read and found nothing in. Without it "No
             servers yet" and "you are looking at the wrong folder" are the same
             three words — see `folderName`. */
          hint={
            projectPath ? (
              <span className="mcp-folder" title={projectPath}>
                {folderName(projectPath)}
              </span>
            ) : undefined
          }
        />
      )}

      <ul className="mcp-servers">
        {servers.map((server) => {
          const open = expanded === server.id
          const inventory = inventories[server.id]
          // Hoisted to a local so it narrows inside the callbacks below. The
          // property read `inventory.data` does not, which is what the cast
          // that used to sit on `countFor` was hiding.
          const data = inventory?.data ?? null
          /** The one sentence this row has behind its dot, if it has one. */
          const why = server.disabledReason ?? server.unsupported
          return (
            <li className="mcp-server" key={server.id} data-state={server.state} data-open={open}>
              <div className="mcp-server-head">
                {/*
                  An HTTP or SSE server cannot be opened, so its row is not a
                  control that looks like one.

                  `mcp-client.ts` marks every non-stdio server `unsupported`,
                  and `toggle` has always skipped the connect for those — so the
                  row expanded to an empty body and nothing else happened. That
                  is the dead click this app is not allowed to have, and the
                  reason is already printed on the row itself two lines below.
                */}
                <button
                  type="button"
                  className="mcp-server-toggle"
                  aria-expanded={server.unsupported ? undefined : open}
                  disabled={Boolean(server.unsupported)}
                  title={server.unsupported ?? undefined}
                  onClick={() => toggle(server)}
                >
                  <span className="mcp-dot" data-state={server.state} aria-hidden="true" />
                  <span className="mcp-server-name">{server.name}</span>
                  <span className="mcp-tag" data-scope={server.scope}>
                    {server.scope}
                  </span>
                  <span className="mcp-tag">{server.transport}</span>
                  {!server.enabled && <span className="mcp-tag" data-warn="true">disabled</span>}
                  {/* Whose server this is. It is always this computer on this
                      half of the page — the pills above switch the other half —
                      and saying so is what makes a two-machine estate readable:
                      *"here also maybe we need to see which MCP servers or
                      which machine connected."* Drawn only once there is
                      another machine to be confused with, so a person with one
                      computer is not told which computer they are on. */}
                  {targets.length > 0 && (
                    <span className="mcp-tag" data-machine="true">
                      {here}
                    </span>
                  )}
                  <span className="mcp-server-state">{STATE_LABEL[server.state]}</span>
                </button>

                {server.state === 'ready' && (
                  <button type="button" className="mcp-server-action" onClick={() => void disconnect(server.id)}>
                    Disconnect
                  </button>
                )}

                {/*
                  Remove, in two presses.

                  The page could add a server and not take one away, and the
                  note above it sent the reader to a terminal to do it. This app
                  already writes that file — through the CLI that owns it, which
                  is exactly how `claude mcp remove` gets run here — so the
                  control belongs on the row it is about.
                */}
                {removing === server.id ? (
                  <>
                    <button
                      type="button"
                      className="mcp-server-action"
                      data-danger="true"
                      onClick={() => void remove(server)}
                    >
                      Remove
                    </button>
                    <button type="button" className="mcp-server-action" onClick={() => setRemoving(null)}>
                      Keep
                    </button>
                  </>
                ) : (
                  <button
                    type="button"
                    className="mcp-server-action"
                    title={`Remove ${server.name} from your ${server.scope} configuration`}
                    onClick={() => setRemoving(server.id)}
                  >
                    Remove
                  </button>
                )}
              </div>

              <p className="mcp-server-command" title={server.source}>
                {formatCommand(server) || '—'}
              </p>

              {/*
                Two sentences used to hang under every row that had one — *"Not
                approved for this project yet."* under a `disabled` tag that had
                already said it, and *"Claude Code dials HTTP servers itself…"*
                under a row that was already unpressable and already carried
                that line in its `title`. His rule, this round: *"I don't want
                any kind of long descriptions anywhere. Just if somewhere it's
                very required, give the i icon."* The tag is the fact and the
                dot is the why.

                The error stays on the page. It is not a description of how the
                app works — it is what this particular server said when it was
                dialled, it changes from run to run, and a failure nobody can
                see without hovering is a failure the page is hiding.
              */}
              {why !== null && (
                <p className="mcp-note">
                  <HoverNote label={server.disabledReason ? 'Why it is off' : 'Why it cannot be opened'}>
                    {why}
                  </HoverNote>
                </p>
              )}
              {server.error && <p className="mcp-error">{server.error}</p>}
              {/* Only ever what the CLI refused with. A removal that worked
                  says nothing — the row is gone. */}
              {removeError[server.id] && <p className="mcp-error">{removeError[server.id]}</p>}

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
