import { readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js'
import { ErrorCode, McpError } from '@modelcontextprotocol/sdk/types.js'
import { BRAND } from '../shared/brand'
import { currentPlatform, envPath, isPathKey, withPath, type Platform } from './platform/host'
import { loginPath } from './providers'
import { onWebContentsDestroyed } from './web-contents-teardown'

/**
 * MCP client + inspector backend.
 *
 * Two halves, deliberately kept apart:
 *
 *  1. **Config discovery** — pure functions over JSON that already exists on
 *     this machine. We read the *user's* Claude Code MCP configuration rather
 *     than keeping a second list of our own: a server the user added with
 *     `claude mcp add` must show up here without being re-entered, and a list
 *     of our own would silently drift out of date the moment they edit theirs.
 *
 *  2. **The connection pool** — one MCP `Client` per server, every call wrapped
 *     in a wall-clock timeout. An MCP server is an arbitrary process the user
 *     configured; it can fail to spawn, spawn and never speak, or die halfway
 *     through a listing. None of those may hang the app.
 *
 * Verified against the real files on this machine:
 *  - `~/.claude.json` holds `mcpServers` (user scope) and, per project,
 *    `projects[<abs path>].mcpServers` plus `enabledMcpjsonServers` /
 *    `disabledMcpjsonServers`.
 *  - With `CLAUDE_CONFIG_DIR` set, that file moves to
 *    `$CLAUDE_CONFIG_DIR/.claude.json` — confirmed by running the CLI against a
 *    throwaway config dir and watching it create exactly that file.
 *  - `~/.claude/settings.json` carries no `mcpServers` key, so we do not invent
 *    one; it only contributes the project-scope approval gates.
 */

/* ------------------------------------------------------------------ types -- */

/** Where a server definition came from. Precedence is local > project > user. */
export type McpScope = 'user' | 'project' | 'local'

/** Wire protocol a server speaks. Only `stdio` is dialable from here. */
export type McpTransportKind = 'stdio' | 'http' | 'sse'

export type McpConnectionState = 'idle' | 'connecting' | 'ready' | 'failed' | 'closed'

export interface McpServerConfig {
  /** Stable key for IPC: `<scope>:<name>`. */
  id: string
  name: string
  scope: McpScope
  transport: McpTransportKind
  /** stdio only. */
  command: string | null
  args: string[]
  env: Record<string, string>
  cwd: string | null
  /** http/sse only. */
  url: string | null
  /** Absolute path of the file this definition was read from. */
  source: string
  /** Whether Claude Code itself would load this server. */
  enabled: boolean
  /** Why it would not, when `enabled` is false. */
  disabledReason: string | null
  /** Why this inspector cannot dial it, when it cannot. */
  unsupported: string | null
}

export interface McpServerStatus extends McpServerConfig {
  state: McpConnectionState
  error: string | null
  serverInfo: { name: string; version: string } | null
  capabilities: string[]
  instructions: string | null
  pid: number | null
  connectedAt: number | null
  /** Tail of the server's stderr — the only clue when a spawn fails. */
  stderr: string
}

export interface McpToolInfo {
  name: string
  title: string | null
  description: string | null
  /** Raw JSON Schema, handed to the renderer untouched so the form can adapt. */
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
  /**
   * Per-section failures. A server whose `resources/list` blows up must still
   * show its tools — one broken section is not a broken panel.
   */
  errors: Record<string, string>
  status: McpServerStatus
}

export interface McpCallResult {
  ok: boolean
  /** Whole `CallToolResult` on success, so the panel can show structured content. */
  result: unknown
  error: string | null
  durationMs: number
  /** Set when the payload was too large to hand across the bridge. */
  truncated: boolean
}

/* -------------------------------------------------------------- constants -- */

export interface McpTimeouts {
  /**
   * First run of an `npx`-launched server downloads the package before it says
   * a word, which on a cold cache is comfortably past ten seconds. Twenty is
   * long enough not to punish that and short enough that a wedged server is
   * obvious.
   */
  connectMs: number
  /** Listings are cheap; anything this slow is a server in trouble. */
  listMs: number
  /** Tool calls do real work — network, files, a browser — so they get a minute. */
  callMs: number
  /** A close that hangs must not block quit; we abandon the process instead. */
  closeMs: number
}

export const DEFAULT_TIMEOUTS: McpTimeouts = {
  connectMs: 20_000,
  listMs: 15_000,
  callMs: 60_000,
  closeMs: 3_000,
}

/**
 * Merge caller overrides over the defaults, ignoring anything that is not a
 * usable duration.
 *
 * A plain spread would let `{ connectMs: undefined }` through — which is exactly
 * what an options object built from optional fields produces — and
 * `setTimeout(fn, undefined)` fires on the next tick, turning every connection
 * into an instant timeout. Zero and negatives do the same, so they are refused
 * too.
 */
export function resolveTimeouts(overrides: Partial<McpTimeouts> = {}): McpTimeouts {
  const merged = { ...DEFAULT_TIMEOUTS }
  for (const key of Object.keys(DEFAULT_TIMEOUTS) as Array<keyof McpTimeouts>) {
    const value = overrides[key]
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) merged[key] = value
  }
  return merged
}

/** Paging guard: a server that always returns a cursor must not loop forever. */
const MAX_PAGES = 50

/** Config files are hand-written; anything larger is not one. */
const MAX_CONFIG_BYTES = 4 * 1024 * 1024

/** Enough stderr to hold a stack trace, not enough to bloat every status push. */
const STDERR_TAIL_CHARS = 8_000

/** Tool results cross the IPC bridge and get rendered; cap the pathological ones. */
const MAX_RESULT_CHARS = 512 * 1024

/* ------------------------------------------------------- config discovery -- */

/**
 * Path of Claude Code's main JSON config.
 *
 * Note the asymmetry, which is real and was checked: by default the file is
 * `~/.claude.json` — a sibling of `~/.claude/`, not inside it — but when
 * `CLAUDE_CONFIG_DIR` is set it lives *inside* that directory. Deriving it from
 * `claudeConfigDir()` in `transcript.ts` would therefore look for
 * `~/.claude/.claude.json` and find nothing on a default install.
 */
export function claudeJsonPath(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.CLAUDE_CONFIG_DIR?.trim()
  return override && override.length > 0 ? join(override, '.claude.json') : join(homedir(), '.claude.json')
}

/** Directory holding `settings.json`. Mirrors `transcript.ts`'s resolution. */
export function claudeSettingsDir(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.CLAUDE_CONFIG_DIR?.trim()
  return override && override.length > 0 ? override : join(homedir(), '.claude')
}

/** Project-scope definitions, committed alongside the code they serve. */
export function projectMcpJsonPath(projectPath: string): string {
  return join(projectPath, '.mcp.json')
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Read a JSON file, returning null for every failure mode.
 *
 * Config files are edited by hand and by other tools; a half-written or
 * truncated one is a normal Tuesday. The inspector's job is to show what it can
 * find, so a bad file costs its own servers and nothing else.
 */
export function readJsonFile(path: string): unknown {
  try {
    const stats = statSync(path)
    // Not a regular file means not a config. The check earns its place on
    // FIFOs: `readFileSync` on one blocks until somebody writes, and this runs
    // on the main process's only thread, so a `.mcp.json` that was not a file
    // would freeze the whole app rather than fail.
    if (!stats.isFile()) {
      console.error('[mcp] ignoring a config path that is not a regular file:', path)
      return null
    }
    if (stats.size > MAX_CONFIG_BYTES) {
      console.error(`[mcp] ignoring an oversized config file (${stats.size} bytes):`, path)
      return null
    }
    return JSON.parse(readFileSync(path, 'utf8')) as unknown
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.error('[mcp] unreadable config, skipping:', path, err)
    }
    return null
  }
}

/**
 * Expand `${VAR}` and `${VAR:-fallback}` references the way Claude Code does in
 * `.mcp.json`, so a shared project file can reference a secret without holding
 * one.
 *
 * An unresolvable reference is left as written rather than replaced with an
 * empty string: a server started with `Authorization: Bearer ` fails with a
 * baffling 401, whereas one started with the literal `${API_KEY}` fails in a way
 * that names the missing variable.
 */
export function expandEnvRefs(value: string, env: NodeJS.ProcessEnv = process.env): string {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (whole, name: string, fallback?: string) => {
    const found = env[name]
    if (found !== undefined && found !== '') return found
    if (fallback !== undefined) return fallback
    return whole
  })
}

function stringMap(value: unknown, env: NodeJS.ProcessEnv): Record<string, string> {
  if (!isRecord(value)) return {}
  const out: Record<string, string> = {}
  for (const [key, raw] of Object.entries(value)) {
    // Numbers and booleans appear in hand-written config often enough to be
    // worth coercing rather than dropping — a dropped env var fails opaquely.
    if (typeof raw === 'string') out[key] = expandEnvRefs(raw, env)
    else if (typeof raw === 'number' || typeof raw === 'boolean') out[key] = String(raw)
  }
  return out
}

function stringArray(value: unknown, env: NodeJS.ProcessEnv): string[] {
  if (!Array.isArray(value)) return []
  return value
    .filter((item): item is string | number => typeof item === 'string' || typeof item === 'number')
    .map((item) => expandEnvRefs(String(item), env))
}

/**
 * Turn one entry of an `mcpServers` object into a config.
 *
 * `type` is optional in the wild — the shape decides: a `command` means stdio, a
 * `url` means HTTP. Returning null (rather than throwing) keeps one malformed
 * entry from hiding every well-formed one beside it.
 */
export function parseServerEntry(
  name: string,
  raw: unknown,
  scope: McpScope,
  source: string,
  env: NodeJS.ProcessEnv = process.env,
): McpServerConfig | null {
  if (typeof name !== 'string' || name.trim().length === 0) return null
  if (!isRecord(raw)) return null

  const declared = typeof raw.type === 'string' ? raw.type.toLowerCase() : ''
  const command = typeof raw.command === 'string' && raw.command.trim().length > 0 ? raw.command.trim() : null
  const url = typeof raw.url === 'string' && raw.url.trim().length > 0 ? raw.url.trim() : null

  let transport: McpTransportKind
  if (declared === 'stdio' || declared === 'http' || declared === 'sse') transport = declared
  else if (command) transport = 'stdio'
  else if (url) transport = 'http'
  else return null

  // A definition that names neither a command nor a URL cannot start anything.
  if (transport === 'stdio' && !command) return null
  if (transport !== 'stdio' && !url) return null

  const cwd = typeof raw.cwd === 'string' && raw.cwd.trim().length > 0 ? expandEnvRefs(raw.cwd.trim(), env) : null

  return {
    id: `${scope}:${name}`,
    name,
    scope,
    transport,
    command: command ? expandEnvRefs(command, env) : null,
    args: stringArray(raw.args, env),
    env: stringMap(raw.env, env),
    cwd,
    url,
    source,
    enabled: true,
    disabledReason: null,
    unsupported:
      transport === 'stdio'
        ? null
        : `${transport.toUpperCase()} servers are configured here but dialled by Claude Code itself — this inspector speaks stdio only.`,
  }
}

/** Parse a whole `mcpServers` map. Order follows the file, so diffs read simply. */
export function parseServerMap(
  raw: unknown,
  scope: McpScope,
  source: string,
  env: NodeJS.ProcessEnv = process.env,
): McpServerConfig[] {
  if (!isRecord(raw)) return []
  const out: McpServerConfig[] = []
  for (const [name, entry] of Object.entries(raw)) {
    const parsed = parseServerEntry(name, entry, scope, source, env)
    if (parsed) out.push(parsed)
  }
  return out
}

/** The approval gates Claude Code applies to `.mcp.json` servers. */
export interface ProjectGates {
  enabled: string[]
  disabled: string[]
  enableAll: boolean
}

export function readProjectGates(claudeJson: unknown, settings: unknown, projectPath: string | null): ProjectGates {
  const gates: ProjectGates = { enabled: [], disabled: [], enableAll: false }

  const collect = (source: unknown): void => {
    if (!isRecord(source)) return
    if (Array.isArray(source.enabledMcpjsonServers)) {
      gates.enabled.push(...source.enabledMcpjsonServers.filter((n): n is string => typeof n === 'string'))
    }
    if (Array.isArray(source.disabledMcpjsonServers)) {
      gates.disabled.push(...source.disabledMcpjsonServers.filter((n): n is string => typeof n === 'string'))
    }
    if (source.enableAllProjectMcpServers === true) gates.enableAll = true
  }

  collect(settings)
  if (projectPath && isRecord(claudeJson) && isRecord(claudeJson.projects)) {
    collect(claudeJson.projects[resolve(projectPath)])
  }
  return gates
}

/**
 * Apply the gates. A project-scope server nobody has approved yet is reported
 * as disabled-pending rather than hidden — "why isn't my server here?" is a
 * worse question to leave the user with than one greyed row.
 */
export function applyProjectGates(servers: McpServerConfig[], gates: ProjectGates): McpServerConfig[] {
  return servers.map((server) => {
    if (server.scope !== 'project') return server
    if (gates.disabled.includes(server.name)) {
      return { ...server, enabled: false, disabledReason: 'Rejected for this project in Claude Code.' }
    }
    if (gates.enabled.includes(server.name) || gates.enableAll) return server
    return { ...server, enabled: false, disabledReason: 'Not approved for this project yet.' }
  })
}

/**
 * Merge the three scopes. Later entries win, matching Claude Code's own
 * precedence (local overrides project overrides user), and the loser is dropped
 * rather than shown twice — two rows with the same name and different commands
 * is exactly the confusion the precedence rule exists to remove.
 */
export function mergeByPrecedence(...groups: McpServerConfig[][]): McpServerConfig[] {
  const byName = new Map<string, McpServerConfig>()
  for (const group of groups) {
    for (const server of group) byName.set(server.name, server)
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name))
}

export interface RawConfigSources {
  claudeJson: unknown
  settings: unknown
  projectMcpJson: unknown
  projectPath: string | null
  claudeJsonPath: string
  projectMcpJsonPath: string | null
  env?: NodeJS.ProcessEnv
}

/** Pure core of discovery: everything below this is file reading. */
export function collectServersFrom(sources: RawConfigSources): McpServerConfig[] {
  const env = sources.env ?? process.env
  const claudeJson = isRecord(sources.claudeJson) ? sources.claudeJson : {}

  const user = parseServerMap(claudeJson.mcpServers, 'user', sources.claudeJsonPath, env)

  const project = sources.projectMcpJsonPath
    ? parseServerMap(
        isRecord(sources.projectMcpJson) ? sources.projectMcpJson.mcpServers : null,
        'project',
        sources.projectMcpJsonPath,
        env,
      )
    : []

  let local: McpServerConfig[] = []
  if (sources.projectPath && isRecord(claudeJson.projects)) {
    const entry = claudeJson.projects[resolve(sources.projectPath)]
    if (isRecord(entry)) {
      local = parseServerMap(entry.mcpServers, 'local', sources.claudeJsonPath, env)
    }
  }

  const gates = readProjectGates(claudeJson, sources.settings, sources.projectPath)
  return mergeByPrecedence(user, applyProjectGates(project, gates), local)
}

/** Read every configured server, optionally scoped to a project folder. */
export function loadServers(projectPath?: string | null, env: NodeJS.ProcessEnv = process.env): McpServerConfig[] {
  const configPath = claudeJsonPath(env)
  const settingsPath = join(claudeSettingsDir(env), 'settings.json')
  const project = projectPath && isAbsolute(projectPath) ? resolve(projectPath) : null
  const mcpJsonPath = project ? projectMcpJsonPath(project) : null

  return collectServersFrom({
    claudeJson: readJsonFile(configPath),
    settings: readJsonFile(settingsPath),
    projectMcpJson: mcpJsonPath ? readJsonFile(mcpJsonPath) : null,
    projectPath: project,
    claudeJsonPath: configPath,
    projectMcpJsonPath: mcpJsonPath,
    env,
  })
}

/* ------------------------------------------------------------- timeouts -- */

/**
 * Race a promise against the clock.
 *
 * The loser keeps running — there is no cancelling an in-flight spawn — so it
 * gets a no-op catch attached. Without it a rejection arriving after the race
 * has been decided surfaces as an unhandled rejection and, under Electron's
 * default, can take the process with it.
 */
export function withTimeout<T>(work: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  void work.catch(() => undefined)
  return Promise.race([
    work,
    new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms)
    }),
  ]).finally(() => clearTimeout(timer)) as Promise<T>
}

/**
 * A JSON-RPC "method not found" means the server simply does not implement an
 * optional listing. `McpError` carries the numeric code; the string check is a
 * fallback for servers whose error reaches us as a plain Error.
 */
export function isMethodNotFound(err: unknown): boolean {
  if (err instanceof McpError) return err.code === ErrorCode.MethodNotFound
  if (typeof err === 'object' && err !== null && 'code' in err) {
    return (err as { code?: unknown }).code === ErrorCode.MethodNotFound
  }
  return err instanceof Error && /-32601/.test(err.message)
}

function messageOf(err: unknown): string {
  if (err instanceof Error) return err.message
  if (typeof err === 'string') return err
  return String(err)
}

function optionalString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null
}

/* --------------------------------------------------------- the connection -- */

interface Live {
  client: Client
  status: McpServerStatus
  /** Set while we are closing on purpose, so onclose does not report a crash. */
  intentionalClose: boolean
  /** Unhooks the stderr reader, so a dead entry stops being written to. */
  detachStderr(): void
}

export interface McpPoolDeps {
  /** Injected in tests so no real process is ever spawned. */
  createTransport?(server: McpServerConfig, env: Record<string, string>): Transport
  /** Injected in tests to skip the login-shell probe. */
  resolveEnv?(server: McpServerConfig): Promise<Record<string, string>>
  onStatusChange?(status: McpServerStatus): void
  /** Shortened in tests so the timeout paths can be exercised in milliseconds. */
  timeouts?: Partial<McpTimeouts>
}

function initialStatus(server: McpServerConfig): McpServerStatus {
  return {
    ...server,
    state: 'idle',
    error: null,
    serverInfo: null,
    capabilities: [],
    instructions: null,
    pid: null,
    connectedAt: null,
    stderr: '',
  }
}

/**
 * Default environment for a spawned server.
 *
 * The login-shell PATH is the load-bearing part. A GUI Electron app inherits a
 * minimal PATH — the SDK's own `getDefaultEnvironment()` hands through exactly
 * what the process already had — so `npx`, `uvx`, `bun` and anything installed
 * by nvm or Homebrew are simply not there, and every stdio server configured
 * the normal way would fail to spawn with ENOENT.
 *
 * The single write of PATH goes through `withPath` rather than a literal key in
 * the spread. On Windows the inherited variable is spelled `Path`, so
 * `{ ...base, PATH: path }` hands the child *both* spellings and leaves it to
 * `CreateProcess` which one it searches — which is exactly the failure this is
 * trying to prevent, since a stdio server that cannot find `npx` never starts.
 * `withPath` drops every spelling and writes one back. See `platform/host.ts`.
 *
 * A server config may set its own PATH, and that still wins: it is merged in
 * first and then collapsed to a single key, so the caller's spelling — `PATH`
 * in a config file written on any OS — reaches Windows as the one `Path` the
 * child will actually read.
 */
async function defaultEnv(
  server: McpServerConfig,
  platform: Platform = currentPlatform(),
): Promise<Record<string, string>> {
  const path = await loginPath()
  const base: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) {
    if (typeof value === 'string') base[key] = value
  }
  const configured = Object.keys(server.env).some((key) => isPathKey(key, platform))
  return withPath(
    { ...base, ...server.env },
    configured ? envPath(server.env, platform) : path,
    platform,
  )
}

export class McpPool {
  private readonly live = new Map<string, Live>()
  /**
   * Connections currently being opened, so overlapping callers share one.
   *
   * Without this, a second `connect()` arriving during a handshake tore the
   * first one down and started its own — and the first one's failure handler
   * then deleted the *second* one's entry from `live`, leaving a spawned child
   * process nobody held a handle to (never closed, not even on quit) while
   * `inventory()` reported "Not connected" for a server that was in fact ready.
   * Two clicks on Refresh were enough to hit it.
   */
  private readonly opening = new Map<string, Promise<McpServerStatus>>()
  private readonly timeouts: McpTimeouts

  constructor(private readonly deps: McpPoolDeps = {}) {
    this.timeouts = resolveTimeouts(deps.timeouts)
  }

  /** Current status for a set of configs, live where we hold a connection. */
  statusFor(servers: McpServerConfig[]): McpServerStatus[] {
    return servers.map((server) => {
      const held = this.live.get(server.id)
      // Re-spread the config so an edited command or arg list shows through
      // without needing a reconnect to be noticed.
      return held ? { ...held.status, ...server, ...pickRuntime(held.status) } : initialStatus(server)
    })
  }

  getStatus(id: string): McpServerStatus | null {
    return this.live.get(id)?.status ?? null
  }

  private publish(status: McpServerStatus): void {
    this.deps.onStatusChange?.(status)
  }

  private appendStderr(live: Live, chunk: string): void {
    const next = live.status.stderr + chunk
    live.status.stderr = next.length > STDERR_TAIL_CHARS ? next.slice(next.length - STDERR_TAIL_CHARS) : next
  }

  /**
   * Connect, or hand back the connection we already hold.
   *
   * Every failure path ends with the transport closed and a status carrying the
   * reason. Nothing here is allowed to reject into IPC without first leaving the
   * pool in a state the panel can render.
   */
  async connect(server: McpServerConfig): Promise<McpServerStatus> {
    // Everything up to `opening.set` runs synchronously, so no second caller
    // can slip past the check and start a rival handshake.
    const inFlight = this.opening.get(server.id)
    if (inFlight) return inFlight

    const held = this.live.get(server.id)
    if (held && held.status.state === 'ready') return held.status

    const work = this.openConnection(server)
    this.opening.set(server.id, work)
    try {
      return await work
    } finally {
      if (this.opening.get(server.id) === work) this.opening.delete(server.id)
    }
  }

  private async openConnection(server: McpServerConfig): Promise<McpServerStatus> {
    const existing = this.live.get(server.id)
    if (existing) await this.disconnect(server.id)

    if (server.unsupported) {
      const status = { ...initialStatus(server), state: 'failed' as const, error: server.unsupported }
      this.publish(status)
      return status
    }

    const status: McpServerStatus = { ...initialStatus(server), state: 'connecting' }
    this.publish(status)

    let transport: Transport
    let env: Record<string, string>
    try {
      env = await (this.deps.resolveEnv ?? defaultEnv)(server)
      transport = (this.deps.createTransport ?? createStdioTransport)(server, env)
    } catch (err) {
      const failed = { ...status, state: 'failed' as const, error: messageOf(err) }
      this.publish(failed)
      return failed
    }

    const client = new Client(
      { name: BRAND.id, version: '0.1.0' },
      // We answer no sampling/elicitation requests, so advertising those would
      // invite a server to ask something we can never answer.
      { capabilities: {} },
    )

    const entry: Live = { client, status, intentionalClose: false, detachStderr: () => undefined }
    this.live.set(server.id, entry)

    // stderr is where a server that fails to start says why; without it a
    // spawn failure reads as a bare timeout. The listener is detachable so an
    // abandoned process cannot keep writing into an entry we have dropped.
    const stderrStream = (transport as { stderr?: NodeJS.ReadableStream | null }).stderr
    if (stderrStream) {
      const onStderr = (chunk: Buffer | string): void => this.appendStderr(entry, chunk.toString())
      stderrStream.on('data', onStderr)
      entry.detachStderr = () => stderrStream.off?.('data', onStderr)
    }

    // These go on the client, not the transport. `Protocol.connect()`
    // reassigns `transport.onclose`/`onerror`/`onmessage` to its own handlers,
    // so anything installed on the transport before connecting is silently
    // thrown away — a crashed server would then never be noticed. The client
    // re-emits both through its own callbacks.
    client.onerror = (err) => {
      // Tearing a connection down makes the SDK try, and fail, to send a
      // cancellation. Recording "Failed to send cancellation: Not connected"
      // under a server we deliberately killed reads as a second fault.
      if (entry.intentionalClose) return
      this.appendStderr(entry, `\n[transport] ${messageOf(err)}`)
    }
    client.onclose = () => {
      // Only a connection that came up can crash. A close during the handshake
      // is the SDK tidying up after a failed initialize, and the connect path
      // below reports that with a far better message.
      if (entry.intentionalClose || entry.status.state !== 'ready') return
      // The server died on its own. Keep the stderr, drop the handle so the
      // next call reconnects instead of writing into a dead pipe.
      entry.status = {
        ...entry.status,
        state: 'closed',
        error: entry.status.error ?? 'The server exited.',
        pid: null,
      }
      entry.detachStderr()
      // Only drop the handle if it is still ours — never someone else's.
      if (this.live.get(server.id) === entry) this.live.delete(server.id)
      this.publish(entry.status)
    }

    try {
      await withTimeout(
        client.connect(transport, { timeout: this.timeouts.connectMs }),
        this.timeouts.connectMs,
        `Connecting to ${server.name}`,
      )
    } catch (err) {
      entry.intentionalClose = true
      entry.detachStderr()
      // Close through the client: `Protocol` records the transport before it
      // starts it, so this reaps the child process even when the failure was
      // the spawn itself, and it clears the SDK's pending-request timers.
      await this.forceClose(client)
      if (this.live.get(server.id) === entry) this.live.delete(server.id)
      const failed: McpServerStatus = {
        ...entry.status,
        state: 'failed',
        error: messageOf(err),
        pid: null,
      }
      this.publish(failed)
      return failed
    }

    const info = client.getServerVersion()
    const caps = client.getServerCapabilities() ?? {}
    entry.status = {
      ...entry.status,
      state: 'ready',
      error: null,
      serverInfo: info ? { name: info.name, version: info.version } : null,
      capabilities: Object.keys(caps),
      instructions: optionalString(client.getInstructions()),
      pid: (transport as { pid?: number | null }).pid ?? null,
      connectedAt: Date.now(),
    }
    this.publish(entry.status)
    return entry.status
  }

  /** Close a connection we opened. Safe to call for one we never had. */
  async disconnect(id: string): Promise<McpServerStatus | null> {
    const entry = this.live.get(id)
    if (!entry) return null
    entry.intentionalClose = true
    entry.detachStderr()
    this.live.delete(id)
    await this.forceClose(entry.client)
    const status: McpServerStatus = { ...entry.status, state: 'idle', pid: null, connectedAt: null, error: null }
    this.publish(status)
    return status
  }

  async disconnectAll(): Promise<void> {
    // Settle the handshakes first. A server still resolving its environment is
    // not in `live` yet, so closing only what `live` holds would let it finish
    // spawning after quit began and leave the child process behind.
    await Promise.allSettled([...this.opening.values()])
    await Promise.all([...this.live.keys()].map((id) => this.disconnect(id)))
  }

  /**
   * `close()` on a wedged transport can itself hang — it waits for a process
   * that is not listening. Quit must not wait for that, so we give it a short
   * window and then abandon it.
   */
  private async forceClose(closable: { close(): Promise<void> }): Promise<void> {
    try {
      await withTimeout(closable.close(), this.timeouts.closeMs, 'Closing the connection')
    } catch (err) {
      console.error('[mcp] a connection would not close cleanly:', messageOf(err))
    }
  }

  private require(id: string): Live {
    const entry = this.live.get(id)
    if (!entry || entry.status.state !== 'ready') throw new Error('Not connected.')
    return entry
  }

  /**
   * Everything a server offers, in one round trip from the panel's point of
   * view. Sections are gated on advertised capabilities: the SDK throws
   * client-side for a method the server never claimed, and surfacing
   * "Server does not support resources" as an error would make every
   * tools-only server look broken.
   */
  async inventory(server: McpServerConfig): Promise<McpInventory> {
    const status = await this.connect(server)
    const inventory: McpInventory = {
      serverId: server.id,
      tools: [],
      resources: [],
      resourceTemplates: [],
      prompts: [],
      errors: {},
      status,
    }
    if (status.state !== 'ready') return inventory

    // Not `require()`: a server can die between the handshake and this line,
    // and a throw here rejects the `mcp:inventory` handler, which the panel
    // shows as a bare error where a partly-filled inventory would do.
    const entry = this.live.get(server.id)
    if (!entry || entry.status.state !== 'ready') {
      inventory.errors.server = 'The server exited before it could be listed.'
      inventory.status = this.getStatus(server.id) ?? { ...status, state: 'closed' }
      return inventory
    }
    const caps = new Set(status.capabilities)

    if (caps.has('tools')) {
      await this.section(inventory, 'tools', async () => {
        inventory.tools = await paginate(
          (cursor) => entry.client.listTools({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.tools.map(toToolInfo),
        )
      })
    }
    if (caps.has('resources')) {
      await this.section(inventory, 'resources', async () => {
        inventory.resources = await paginate(
          (cursor) => entry.client.listResources({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.resources.map(toResourceInfo),
        )
      })
      await this.section(inventory, 'resourceTemplates', async () => {
        inventory.resourceTemplates = await paginate(
          (cursor) => entry.client.listResourceTemplates({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.resourceTemplates.map(toResourceTemplateInfo),
        )
      })
    }
    if (caps.has('prompts')) {
      await this.section(inventory, 'prompts', async () => {
        inventory.prompts = await paginate(
          (cursor) => entry.client.listPrompts({ cursor }, { timeout: this.timeouts.listMs }),
          (page) => page.prompts.map(toPromptInfo),
        )
      })
    }

    inventory.status = this.getStatus(server.id) ?? status
    return inventory
  }

  private async section(inventory: McpInventory, key: string, work: () => Promise<void>): Promise<void> {
    try {
      await withTimeout(work(), this.timeouts.listMs, `Listing ${key}`)
    } catch (err) {
      // Verified against a real server: one that advertises `resources` but
      // implements only `resources/list` answers the templates call with
      // -32601. That is "there are none", not a fault, and reporting it painted
      // a red error across a perfectly healthy server.
      if (isMethodNotFound(err)) return
      inventory.errors[key] = messageOf(err)
    }
  }

  /** Invoke a tool by hand from the inspector. */
  async callTool(server: McpServerConfig, name: string, args: Record<string, unknown>): Promise<McpCallResult> {
    const started = Date.now()
    const status = await this.connect(server)
    if (status.state !== 'ready') {
      return { ok: false, result: null, error: status.error ?? 'Not connected.', durationMs: Date.now() - started, truncated: false }
    }

    try {
      const entry = this.require(server.id)
      const raw = await withTimeout(
        entry.client.callTool({ name, arguments: args }, undefined, { timeout: this.timeouts.callMs }),
        this.timeouts.callMs,
        `Calling ${name}`,
      )
      const { value, truncated } = capPayload(raw)
      return { ok: true, result: value, error: null, durationMs: Date.now() - started, truncated }
    } catch (err) {
      return { ok: false, result: null, error: messageOf(err), durationMs: Date.now() - started, truncated: false }
    }
  }

  async readResource(server: McpServerConfig, uri: string): Promise<McpCallResult> {
    return this.simpleCall(server, `Reading ${uri}`, (client) =>
      client.readResource({ uri }, { timeout: this.timeouts.listMs }),
    )
  }

  async getPrompt(server: McpServerConfig, name: string, args: Record<string, string>): Promise<McpCallResult> {
    return this.simpleCall(server, `Rendering ${name}`, (client) =>
      client.getPrompt({ name, arguments: args }, { timeout: this.timeouts.listMs }),
    )
  }

  private async simpleCall(
    server: McpServerConfig,
    label: string,
    work: (client: Client) => Promise<unknown>,
  ): Promise<McpCallResult> {
    const started = Date.now()
    const status = await this.connect(server)
    if (status.state !== 'ready') {
      return { ok: false, result: null, error: status.error ?? 'Not connected.', durationMs: Date.now() - started, truncated: false }
    }
    try {
      const entry = this.require(server.id)
      const raw = await withTimeout(work(entry.client), this.timeouts.listMs, label)
      const { value, truncated } = capPayload(raw)
      return { ok: true, result: value, error: null, durationMs: Date.now() - started, truncated }
    } catch (err) {
      return { ok: false, result: null, error: messageOf(err), durationMs: Date.now() - started, truncated: false }
    }
  }
}

/** Runtime fields survive a config re-read; config fields are refreshed from disk. */
function pickRuntime(status: McpServerStatus): Partial<McpServerStatus> {
  return {
    state: status.state,
    error: status.error,
    serverInfo: status.serverInfo,
    capabilities: status.capabilities,
    instructions: status.instructions,
    pid: status.pid,
    connectedAt: status.connectedAt,
    stderr: status.stderr,
  }
}

function createStdioTransport(server: McpServerConfig, env: Record<string, string>): Transport {
  if (!server.command) throw new Error('This server has no command to run.')
  return new StdioClientTransport({
    command: server.command,
    args: server.args,
    env,
    cwd: server.cwd ?? undefined,
    // Piped rather than inherited: inheriting dumps a server's chatter into the
    // app's own stderr where the user will never see it.
    stderr: 'pipe',
  })
}

interface Page {
  nextCursor?: string
}

/** Walk a paginated listing, with a hard page cap. */
async function paginate<TPage extends Page, TItem>(
  fetchPage: (cursor: string | undefined) => Promise<TPage>,
  select: (page: TPage) => TItem[],
): Promise<TItem[]> {
  const items: TItem[] = []
  // A server that hands back the cursor it was given would otherwise be walked
  // MAX_PAGES times, duplicating its whole listing on every lap. Stopping on a
  // repeat catches that immediately instead of after fifty round trips.
  const seen = new Set<string>()
  let cursor: string | undefined
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const result = await fetchPage(cursor)
    items.push(...select(result))
    if (!result.nextCursor) return items
    if (seen.has(result.nextCursor)) {
      console.error('[mcp] stopped paging: the server repeated a cursor')
      return items
    }
    seen.add(result.nextCursor)
    cursor = result.nextCursor
  }
  console.error('[mcp] stopped paging after', MAX_PAGES, 'pages')
  return items
}

interface NamedThing {
  name: string
  title?: string
  description?: string
}

function toToolInfo(tool: NamedThing & { inputSchema?: unknown; outputSchema?: unknown }): McpToolInfo {
  return {
    name: tool.name,
    title: optionalString(tool.title),
    description: optionalString(tool.description),
    inputSchema: tool.inputSchema ?? null,
    outputSchema: tool.outputSchema ?? null,
  }
}

function toResourceInfo(resource: NamedThing & { uri: string; mimeType?: string }): McpResourceInfo {
  return {
    uri: resource.uri,
    name: resource.name,
    title: optionalString(resource.title),
    description: optionalString(resource.description),
    mimeType: optionalString(resource.mimeType),
  }
}

function toResourceTemplateInfo(
  template: NamedThing & { uriTemplate: string; mimeType?: string },
): McpResourceTemplateInfo {
  return {
    uriTemplate: template.uriTemplate,
    name: template.name,
    title: optionalString(template.title),
    description: optionalString(template.description),
    mimeType: optionalString(template.mimeType),
  }
}

function toPromptInfo(
  prompt: NamedThing & { arguments?: Array<{ name: string; description?: string; required?: boolean }> },
): McpPromptInfo {
  return {
    name: prompt.name,
    title: optionalString(prompt.title),
    description: optionalString(prompt.description),
    arguments: (prompt.arguments ?? []).map((arg) => ({
      name: arg.name,
      description: optionalString(arg.description),
      required: arg.required === true,
    })),
  }
}

/**
 * Guard the bridge. A tool that returns a whole file tree or a base64 video will
 * otherwise be serialised twice — once for IPC, once for rendering — and lock
 * the UI. We hand back a readable stand-in instead.
 */
export function capPayload(value: unknown): { value: unknown; truncated: boolean } {
  let json: string
  try {
    json = JSON.stringify(value) ?? ''
  } catch {
    // Circular or otherwise unserialisable: it would fail on the bridge anyway.
    return { value: { note: 'The result could not be serialised.' }, truncated: true }
  }
  if (json.length <= MAX_RESULT_CHARS) return { value, truncated: false }
  return {
    value: {
      note: `The result was ${json.length} characters; showing the first ${MAX_RESULT_CHARS}.`,
      preview: json.slice(0, MAX_RESULT_CHARS),
    },
    truncated: true,
  }
}

/* ------------------------------------------------------------------- ipc -- */

const STATE_CHANNEL = 'mcp:state'

const pool = new McpPool({ onStatusChange: (status) => broadcast(status) })

const subscribers = new Set<Electron.WebContents>()

let ipcRegistered = false

/** Test seam: forget that the channels were claimed. Not used in the app. */
export function resetMcpIpcForTests(): void {
  ipcRegistered = false
  subscribers.clear()
}

function broadcast(status: McpServerStatus): void {
  for (const contents of subscribers) {
    if (contents.isDestroyed()) {
      subscribers.delete(contents)
      continue
    }
    try {
      contents.send(STATE_CHANNEL, status)
    } catch (err) {
      subscribers.delete(contents)
      console.error('[mcp] dropping a dead subscriber:', messageOf(err))
    }
  }
}

function optionalProjectPath(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0) return null
  if (!isAbsolute(value)) throw new Error('mcp: a project path must be absolute')
  return resolve(value)
}

/**
 * Look a server up by id from the config on disk.
 *
 * The renderer never gets to name a command — it names a server that is already
 * in the user's own configuration, and we read the command from there. That is
 * the whole security story for this feature: a compromised renderer cannot turn
 * `mcp:connect` into arbitrary process execution.
 */
function findServer(id: unknown, projectPath: string | null): McpServerConfig {
  if (typeof id !== 'string' || id.length === 0) throw new Error('mcp: a server id is required')
  const found = loadServers(projectPath).find((server) => server.id === id)
  if (!found) throw new Error(`mcp: no configured server with id ${id}`)
  return found
}

function argsObject(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null) return {}
  if (!isRecord(value)) throw new Error('mcp: tool arguments must be an object')
  return value
}

function stringArgs(value: unknown): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, raw] of Object.entries(argsObject(value))) {
    if (typeof raw === 'string') out[key] = raw
    else if (raw !== undefined && raw !== null) out[key] = String(raw)
  }
  return out
}

/**
 * Wire the MCP channels into the main process.
 * Call once during startup: `registerMcpIpc(ipcMain)`.
 *
 * Channels:
 *  - `mcp:list`          (projectPath?)                    -> McpServerStatus[]
 *  - `mcp:connect`       (serverId, projectPath?)          -> McpServerStatus
 *  - `mcp:disconnect`    (serverId)                        -> McpServerStatus | null
 *  - `mcp:inventory`     (serverId, projectPath?)          -> McpInventory
 *  - `mcp:call`          (serverId, tool, args, project?)  -> McpCallResult
 *  - `mcp:read-resource` (serverId, uri, projectPath?)     -> McpCallResult
 *  - `mcp:get-prompt`    (serverId, name, args, project?)  -> McpCallResult
 *  - pushes `mcp:state` (McpServerStatus) whenever a connection changes state.
 */
export function registerMcpIpc(ipcMain: Electron.IpcMain): void {
  // `ipcMain.handle` throws on a duplicate channel, so a second call — a hot
  // reload of the main process, or two call sites that each think they own
  // startup — would take the whole app down before a window ever opened.
  if (ipcRegistered) return
  ipcRegistered = true

  ipcMain.handle('mcp:list', (event, projectPath?: unknown) => {
    // Subscribing here rather than on a separate channel means a panel that can
    // read the list is always also receiving its updates.
    const contents = event.sender
    subscribers.add(contents)
    onWebContentsDestroyed(contents, 'mcp', () => subscribers.delete(contents))
    return pool.statusFor(loadServers(optionalProjectPath(projectPath)))
  })

  ipcMain.handle('mcp:connect', (_e, id: unknown, projectPath?: unknown) =>
    pool.connect(findServer(id, optionalProjectPath(projectPath))),
  )

  ipcMain.handle('mcp:disconnect', (_e, id: unknown) => {
    if (typeof id !== 'string') throw new Error('mcp: a server id is required')
    return pool.disconnect(id)
  })

  ipcMain.handle('mcp:inventory', (_e, id: unknown, projectPath?: unknown) => {
    const project = optionalProjectPath(projectPath)
    return pool.inventory(findServer(id, project))
  })

  ipcMain.handle('mcp:call', (_e, id: unknown, tool: unknown, args: unknown, projectPath?: unknown) => {
    if (typeof tool !== 'string' || tool.length === 0) throw new Error('mcp: a tool name is required')
    return pool.callTool(findServer(id, optionalProjectPath(projectPath)), tool, argsObject(args))
  })

  ipcMain.handle('mcp:read-resource', (_e, id: unknown, uri: unknown, projectPath?: unknown) => {
    if (typeof uri !== 'string' || uri.length === 0) throw new Error('mcp: a resource uri is required')
    return pool.readResource(findServer(id, optionalProjectPath(projectPath)), uri)
  })

  ipcMain.handle('mcp:get-prompt', (_e, id: unknown, name: unknown, args: unknown, projectPath?: unknown) => {
    if (typeof name !== 'string' || name.length === 0) throw new Error('mcp: a prompt name is required')
    return pool.getPrompt(findServer(id, optionalProjectPath(projectPath)), name, stringArgs(args))
  })
}

/** Close every server we started. Call from `before-quit`. */
export async function stopAllMcpServers(): Promise<void> {
  await pool.disconnectAll()
}
