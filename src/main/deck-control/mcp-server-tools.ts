/**
 * The MCP servers the coding agents use — the Agents pane's MCP section, as tools.
 *
 * Not to be confused with *this* app's own MCP server, which is the thing
 * serving these tools. These are the third-party servers a person has
 * configured for Claude Code — a filesystem server, a GitHub server, a
 * database — and everything a person can do to them by hand is here: list them,
 * add one, change one, remove one, connect to one and see its tools, call one
 * of its tools, browse the MCP store and install from it, and export or import
 * a definition to share.
 *
 * ## Same functions, same owner of the file
 *
 * The writes never touch `~/.claude.json` from here: `mcp-add.ts` shells out to
 * `claude mcp add` / `remove`, because that file is another application's live
 * database. Every dep below is the function the matching `mcp:*` channel calls
 * (`mcp-client.ts` names them for exactly this), and each write is checked by
 * that module's own resolver in `precheck` — so a malformed request is refused
 * before a person is shown a dialog for it, with the sentence the form would
 * have printed.
 *
 * ## Secrets, in both directions
 *
 * **Out:** a configured server carries environment variables, and those are
 * where API keys live. `mcp.list` hands back their *names* and never their
 * values, and every other string in the listing — arguments, URLs — goes
 * through `redact.ts`, because `--token abc…` and `?key=…` are both things
 * people paste into a command line. The export is variable names only, which is
 * what `mcp-share.ts` already writes.
 *
 * **In:** adding a server or installing from the store often means *giving* it
 * a key. That is fine — using a credential is the job — and {@link
 * redactEnvValues} takes the values out of the arguments before the action log
 * writes them down, because the log matches secrets by key name and a key
 * called `GITHUB_TOKEN` inside an object called `env` is one level deeper than
 * that pass looks.
 *
 * ## Tiers
 *
 * Reading the configuration, the store and a shared file is `read`. Connecting
 * spawns the command the person configured, which is the ordinary `act` of
 * using what is set up. Adding, changing, removing and installing are `alter`.
 * **Calling a tool on another server is `alter` too**, and that is the one that
 * needs arguing: nothing here can know what a third-party tool does. It may
 * read a file or it may send an email, and a server's own claim that a tool is
 * read-only is that server's claim, not a fact this app can check. So a person
 * sees which server, which tool and which arguments, and says yes.
 */

import { readToolFile } from '../mcp-share'
import { resolveRequest, resolveRemoveRequest, type McpAddResult } from '../mcp-add'
import { resolveEditRequest } from '../mcp-edit'
import { resolveInstall, type McpStoreResult, type McpStoreView } from '../mcp-store'
import type { McpCallResult, McpInventory, McpServerStatus } from '../mcp-client'
import { redactValue } from '../redact'
import { BadArgument, requireKnownFolder, type JsonSchema, type ToolContext, type ToolSpec } from './catalogue'
import { messageOf, oneOf, optRecord, optStr, str, withoutSecrets } from './agents-area-args'
import { Refused } from './surface'

export interface McpServerToolDeps {
  /** `listMcpServers` — every configured server with its live connection state. */
  list(projectPath: string | null): McpServerStatus[]
  /** `addMcpServer` — `claude mcp add`. */
  add(request: unknown): Promise<McpAddResult>
  /** `editConfiguredMcpServer` — a remove and an add, keeping any value left blank. */
  edit(request: unknown): Promise<McpAddResult>
  /** `removeMcpServer` — `claude mcp remove`. */
  remove(request: unknown): Promise<McpAddResult>
  /** `mcpServerInventory` — connects if needed, then lists tools, resources and prompts. */
  inventory(id: string, projectPath: string | null): Promise<McpInventory>
  /** `disconnectMcpServer`. */
  disconnect(id: string): Promise<McpServerStatus | null>
  /** `callMcpTool`. */
  call(id: string, tool: string, args: Record<string, unknown>, projectPath: string | null): Promise<McpCallResult>
  /** `mcpStoreView`. */
  store(projectPath: string | null): Promise<McpStoreView>
  /** `mcpStoreInstall`. */
  install(request: unknown): Promise<McpStoreResult>
  /** `mcpToolFile` — the shareable definition, names only. */
  toolFile(name: string, scope: string, projectPath: string | null): { name: string; fileName: string; text: string } | null
}

const SCOPES = ['user', 'project', 'local'] as const
const TRANSPORTS = ['stdio', 'http', 'sse'] as const

/**
 * Secrets out, paths left alone.
 *
 * A path in a server's arguments is something a model reads back and *sends*
 * to `mcp.edit`; folded to `/Users/<user>/…` it would rewrite the server to
 * point at a folder that does not exist.
 */
const NO_IDENTITY_FOLD = { keepIdentity: true }

/**
 * One configured server, as a model may see it.
 *
 * Environment variables become their names. Everything else that is free text
 * — arguments, the URL, the stderr tail a failed spawn left — goes through the
 * redactor, which knows token shapes, `Authorization:` headers and credentials
 * in URLs. The stderr tail matters more than it looks: a server that crashed
 * printing its own configuration is a common way for a key to end up on screen.
 */
export function serverView(status: McpServerStatus): Record<string, unknown> {
  const { env, ...rest } = status
  return {
    ...redactValue(rest, NO_IDENTITY_FOLD),
    envKeys: Object.keys(env ?? {}).sort(),
  }
}

/**
 * The arguments with every value under `env`, `headers` and `values` replaced.
 *
 * Exported so its test can pin the one property that matters: the *names*
 * survive, so the log can still say which variables a server was given.
 */
export function redactEnvValues(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...args }
  for (const field of ['env', 'headers', 'values']) {
    const value = out[field]
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      out[field] = Object.fromEntries(Object.keys(value).map((key) => [key, '[redacted]']))
    }
  }
  const next = out['next']
  if (typeof next === 'object' && next !== null && !Array.isArray(next)) {
    out['next'] = redactEnvValues(next as Record<string, unknown>)
  }
  return out
}

/** An optional open folder, held to the same rule every folder argument is. */
function folder(args: Record<string, unknown>, context: ToolContext): string | null {
  const path = optStr(args, 'projectPath')
  return path === null ? null : requireKnownFolder(context.surface, path)
}

/**
 * `KEY=value` / `Name: value` lines, which is what the add form sends.
 *
 * Taken as an object from a model rather than as a list of lines, because an
 * object cannot carry the same key twice and cannot carry a line with no `=` —
 * two mistakes the line format makes possible and the resolver then has to
 * refuse.
 */
function extrasOf(transport: string, env: Record<string, unknown> | null, headers: Record<string, unknown> | null): string[] {
  const source = transport === 'stdio' ? env : headers
  if (source === null) return []
  return Object.entries(source).map(([key, value]) => {
    if (typeof value !== 'string') throw new BadArgument(`${key} must be a string`)
    return transport === 'stdio' ? `${key}=${value}` : `${key}: ${value}`
  })
}

/** An `McpAddRequest` from tool arguments, ready for `resolveRequest`. */
function addRequestOf(input: Record<string, unknown>, projectPath: string | null): Record<string, unknown> {
  const transport = typeof input['transport'] === 'string' ? (input['transport'] as string) : 'stdio'
  return {
    name: input['name'],
    scope: input['scope'] ?? 'user',
    transport,
    command: input['command'] ?? '',
    url: input['url'] ?? '',
    extras: extrasOf(transport, optRecord(input, 'env'), optRecord(input, 'headers')),
    projectPath,
  }
}

/** Run one of the CLI's own resolvers and turn its sentence into a refusal a model can fix. */
function checked<T>(resolve: () => T): T {
  try {
    return resolve()
  } catch (error) {
    throw new BadArgument(messageOf(error))
  }
}

/** A failed write, said as a refusal with the CLI's own sentence. */
function landed(result: { ok: boolean; message: string }, what: string): { ok: true; message: string } {
  if (!result.ok) throw new Refused('not-permitted', `${what} did not happen: ${result.message}`)
  return { ok: true, message: result.message }
}

const DEFINITION_PROPERTIES = {
  name: { type: 'string', description: 'Letters, numbers, dots, dashes, underscores.' },
  scope: {
    type: 'string',
    enum: [...SCOPES],
    description: 'user: every folder. project: shared in the folder’s .mcp.json. local: this folder, only you.',
  },
  transport: { type: 'string', enum: [...TRANSPORTS], description: 'stdio runs a command; http/sse is a URL.' },
  command: { type: 'string', description: 'stdio: the command line that starts it, e.g. npx -y @scope/server.' },
  url: { type: 'string', description: 'http/sse: the server URL.' },
  env: { type: 'object', description: 'stdio: environment variables, name → value.' },
  headers: { type: 'object', description: 'http/sse: request headers, name → value.' },
} as const

const SERVER_REF: JsonSchema = {
  type: 'object',
  properties: {
    name: { type: 'string' },
    scope: { type: 'string', enum: [...SCOPES] },
    projectPath: { type: 'string', description: 'The open folder, for project and local scope.' },
  },
  required: ['name', 'scope'],
  additionalProperties: false,
}

export function mcpServerTools(deps: McpServerToolDeps): ToolSpec[] {
  return [
    {
      id: 'mcp.list',
      wire: 'mcp_list',
      tier: 'read',
      title: 'List the agents’ MCP servers',
      description:
        'The MCP servers configured for the coding agents on this computer — user-wide ones, plus a folder’s ' +
        'own when projectPath is given — with how each is reached, whether Claude Code would load it, and ' +
        'whether this app is connected to it now. Environment variables are listed by name only; values are ' +
        'never returned. The id of each is what mcp.connect and mcp.call take.',
      index: 'List the MCP servers configured for the coding agents, and which are connected.',
      inputSchema: {
        type: 'object',
        properties: { projectPath: { type: 'string', description: 'An open folder, to include its own servers.' } },
        additionalProperties: false,
      },
      summary: (args) => `List MCP servers${optStr(args, 'projectPath') === null ? '' : ` for ${optStr(args, 'projectPath')}`}`,
      run: async (args, context) => {
        const servers = deps.list(folder(args, context)).map(serverView)
        return { value: { servers }, summary: { servers: servers.length } }
      },
    },

    {
      id: 'mcp.add',
      wire: 'mcp_add',
      tier: 'alter',
      title: 'Add an MCP server',
      description:
        'Add an MCP server to the agents’ configuration, through Claude Code’s own `claude mcp add`, so the next ' +
        'session can use it. A command (stdio) or a URL (http/sse); give any keys it needs in env or headers — ' +
        'they are written to the agent’s config and are never shown back. Project and local scope need ' +
        'projectPath. Checked before the person is asked to confirm.',
      index: 'Add an MCP server for the coding agents, by command or URL.',
      inputSchema: {
        type: 'object',
        properties: { ...DEFINITION_PROPERTIES, projectPath: { type: 'string' } },
        required: ['name', 'scope', 'transport'],
        additionalProperties: false,
      },
      redactArgs: redactEnvValues,
      precheck: (args, context) => {
        checked(() => resolveRequest(addRequestOf(args, folder(args, context))))
      },
      summary: (args) => {
        const how = args['transport'] === 'stdio' ? `runs ${optStr(args, 'command') ?? '?'}` : `at ${optStr(args, 'url') ?? '?'}`
        const env = optRecordSafe(args, args['transport'] === 'stdio' ? 'env' : 'headers')
        const given = env.length === 0 ? '' : `, given ${env.join(', ')}`
        return `Add the ${optStr(args, 'scope') ?? 'user'} MCP server ${optStr(args, 'name') ?? '?'}, which ${how}${given}`
      },
      run: async (args, context) => {
        const request = checked(() => resolveRequest(addRequestOf(args, folder(args, context))))
        const done = landed(await deps.add(request), 'the add')
        return { value: done, summary: { name: request.name, scope: request.scope, transport: request.transport } }
      },
    },

    {
      id: 'mcp.edit',
      wire: 'mcp_edit',
      tier: 'alter',
      title: 'Change an MCP server',
      description:
        'Change a configured MCP server: its command or URL, its name, its scope, its variables. Send the whole ' +
        'new definition in next (mcp.list shows the current one). A variable given an empty value keeps the ' +
        'value already saved, so a key never has to be typed again; leave a variable out to drop it.',
      index: 'Change a configured MCP server, keeping saved keys you leave blank.',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'The server as it is now.' },
          scope: { type: 'string', enum: [...SCOPES] },
          projectPath: { type: 'string' },
          next: { type: 'object', properties: DEFINITION_PROPERTIES, description: 'What it becomes.' },
        },
        required: ['name', 'scope', 'next'],
        additionalProperties: false,
      },
      redactArgs: redactEnvValues,
      precheck: (args, context) => {
        checked(() => resolveEditRequest(editRequestOf(args, folder(args, context))))
      },
      summary: (args) => `Change the ${optStr(args, 'scope') ?? '?'} MCP server ${optStr(args, 'name') ?? '?'}`,
      run: async (args, context) => {
        const request = editRequestOf(args, folder(args, context))
        const done = landed(await deps.edit(request), 'the change')
        return { value: done, summary: { name: request.name, scope: request.scope } }
      },
    },

    {
      id: 'mcp.remove',
      wire: 'mcp_remove',
      tier: 'alter',
      title: 'Remove an MCP server',
      description:
        'Remove a configured MCP server, through `claude mcp remove`, from exactly the scope named — a user ' +
        'server and a project server of the same name are different servers. Its saved keys go with it.',
      index: 'Remove a configured MCP server.',
      inputSchema: SERVER_REF,
      precheck: (args, context) => {
        checked(() => resolveRemoveRequest({ ...args, projectPath: folder(args, context) }))
      },
      summary: (args) => `Remove the ${optStr(args, 'scope') ?? '?'} MCP server ${optStr(args, 'name') ?? '?'} and its saved keys`,
      run: async (args, context) => {
        const request = checked(() => resolveRemoveRequest({ ...args, projectPath: folder(args, context) }))
        const done = landed(await deps.remove(request), 'the removal')
        return { value: done, summary: { name: request.name, scope: request.scope } }
      },
    },

    {
      id: 'mcp.connect',
      wire: 'mcp_connect',
      tier: 'act',
      title: 'Connect to an MCP server',
      description:
        'Start a configured MCP server (or reuse the connection this app already has) and list what it offers: ' +
        'its tools with their input schemas, its resources and its prompts. This runs the command the person ' +
        'configured. A server that fails to start comes back with its error and the end of what it printed.',
      index: 'Connect to a configured MCP server and list its tools, resources and prompts.',
      inputSchema: {
        type: 'object',
        properties: {
          serverId: { type: 'string', description: 'The id from mcp.list, like user:github.' },
          projectPath: { type: 'string' },
        },
        required: ['serverId'],
        additionalProperties: false,
      },
      summary: (args) => `Connect to the MCP server ${optStr(args, 'serverId') ?? '?'}`,
      run: async (args, context) => {
        const inventory = await deps.inventory(str(args, 'serverId'), folder(args, context))
        const { status, ...offers } = inventory
        return {
          value: { status: serverView(status), ...offers },
          summary: { serverId: inventory.serverId, state: status.state, tools: inventory.tools.length },
        }
      },
    },

    {
      id: 'mcp.disconnect',
      wire: 'mcp_disconnect',
      tier: 'act',
      title: 'Disconnect from an MCP server',
      description: 'Close this app’s connection to an MCP server and stop the process it started for it.',
      index: 'Close this app’s connection to an MCP server.',
      inputSchema: {
        type: 'object',
        properties: { serverId: { type: 'string' } },
        required: ['serverId'],
        additionalProperties: false,
      },
      summary: (args) => `Disconnect from the MCP server ${optStr(args, 'serverId') ?? '?'}`,
      run: async (args) => {
        const id = str(args, 'serverId')
        const status = await deps.disconnect(id)
        return {
          value: status === null ? { serverId: id, wasConnected: false } : { wasConnected: true, status: serverView(status) },
          summary: { serverId: id, wasConnected: status !== null },
        }
      },
    },

    {
      id: 'mcp.call',
      wire: 'mcp_call',
      tier: 'alter',
      title: 'Call a tool on an MCP server',
      description:
        'Call one tool on one of the agents’ MCP servers and return its result, connecting first if needed. ' +
        'Call mcp.connect first for the tool names and their argument schemas. Nothing here can know what a ' +
        'third-party tool does, so every call is confirmed by the person, with the server, the tool and the ' +
        'arguments in front of them. Large results are cut short and say so.',
      index: 'Call a tool on one of the agents’ MCP servers (the person confirms each call).',
      inputSchema: {
        type: 'object',
        properties: {
          serverId: { type: 'string' },
          tool: { type: 'string' },
          arguments: { type: 'object', description: 'The tool’s arguments, per its input schema.' },
          projectPath: { type: 'string' },
        },
        required: ['serverId', 'tool'],
        additionalProperties: false,
      },
      summary: (args) => {
        const given = optRecordSafe(args, 'arguments')
        return `Call ${optStr(args, 'tool') ?? '?'} on the MCP server ${optStr(args, 'serverId') ?? '?'}${given.length === 0 ? '' : ` with ${given.join(', ')}`}`
      },
      run: async (args, context) => {
        const id = str(args, 'serverId')
        const tool = str(args, 'tool')
        const result = await deps.call(id, tool, optRecord(args, 'arguments') ?? {}, folder(args, context))
        return {
          value: result,
          summary: { serverId: id, tool, ok: result.ok, ms: result.durationMs, truncated: result.truncated },
        }
      },
    },

    {
      id: 'mcp.store',
      wire: 'mcp_store',
      tier: 'read',
      title: 'Browse the MCP store',
      description:
        'The catalogue of MCP servers that can be installed for the agents, each with what it costs, what it ' +
        'needs filled in (its inputs), whether this computer has the runtime it needs, and whether it is ' +
        'already installed. Install one with mcp.install.',
      index: 'Browse the catalogue of MCP servers that can be installed for the agents.',
      inputSchema: {
        type: 'object',
        properties: { projectPath: { type: 'string', description: 'An open folder, for project-scoped installs.' } },
        additionalProperties: false,
      },
      summary: () => 'Browse the MCP store',
      run: async (args, context) => {
        const view = await deps.store(folder(args, context))
        return { value: redactValue(view, NO_IDENTITY_FOLD), summary: { rows: view.rows.length } }
      },
    },

    {
      id: 'mcp.install',
      wire: 'mcp_install',
      tier: 'alter',
      title: 'Install an MCP server from the store',
      description:
        'Install one row of the MCP store for the agents. Fill its inputs in values (input key → value), as ' +
        'mcp.store lists them; a key already set in the login shell can be left out. Keys given here are written ' +
        'to the agent’s config and never shown back. The person confirms it.',
      index: 'Install an MCP server from the store, filling in what it needs.',
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'The row id from mcp.store.' },
          scope: { type: 'string', enum: [...SCOPES] },
          projectPath: { type: 'string' },
          values: { type: 'object', description: 'Input key → value.' },
        },
        required: ['id'],
        additionalProperties: false,
      },
      redactArgs: redactEnvValues,
      precheck: (args, context) => {
        checked(() => resolveInstall({ ...args, projectPath: folder(args, context) }))
      },
      summary: (args) => {
        const given = optRecordSafe(args, 'values')
        return `Install ${optStr(args, 'id') ?? '?'} from the MCP store (${optStr(args, 'scope') ?? 'user'} scope)${given.length === 0 ? '' : `, given ${given.join(', ')}`}`
      },
      run: async (args, context) => {
        const request = checked(() => resolveInstall({ ...args, projectPath: folder(args, context) }))
        const done = landed(await deps.install(request), 'the install')
        return { value: done, summary: { id: request.id, scope: request.scope } }
      },
    },

    {
      id: 'mcp.export',
      wire: 'mcp_export',
      tier: 'read',
      title: 'Export an MCP server definition',
      description:
        'The shareable file for one configured server, as text: how it is started and the NAMES of the ' +
        'variables it needs, never their values — whoever receives it fills those in. Save it or send it; ' +
        'mcp.import reads one back.',
      index: 'Get a shareable definition of a configured MCP server (no secret values).',
      inputSchema: SERVER_REF,
      summary: (args) => `Export the MCP server ${optStr(args, 'name') ?? '?'}`,
      run: async (args, context) => {
        const scope = oneOf(args, 'scope', SCOPES)
        const file = deps.toolFile(str(args, 'name'), scope, folder(args, context))
        if (file === null) throw new Refused('not-permitted', 'that server is not in the configuration. mcp.list shows them.')
        return { value: file, summary: { name: file.name } }
      },
    },

    {
      id: 'mcp.import',
      wire: 'mcp_import',
      tier: 'read',
      title: 'Read a shared MCP server definition',
      description:
        'Read a shared MCP server file (the text mcp.export produces) and turn it into a draft: its name, how ' +
        'it is reached, and the variables it needs with no values. Nothing is written — pass the draft to ' +
        'mcp.add, filling the variables in, to actually add it.',
      index: 'Turn a shared MCP server file into a draft for mcp.add. Writes nothing.',
      inputSchema: {
        type: 'object',
        properties: { text: { type: 'string', description: 'The file’s contents.' } },
        required: ['text'],
        additionalProperties: false,
      },
      summary: () => 'Read a shared MCP server definition',
      run: async (args) => {
        const read = readToolFile(str(args, 'text'))
        if (!read.ok) throw new BadArgument(`that is not a server definition: ${read.why}`)
        return { value: withoutSecrets({ draft: read.draft }), summary: { name: read.draft.name } }
      },
    },
  ]
}

/** The key names of an object argument, for a confirmation sentence. Never the values. */
function optRecordSafe(args: Record<string, unknown>, key: string): string[] {
  const value = args[key]
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? Object.keys(value) : []
}

/** An `McpEditRequest` from tool arguments. The new definition defaults to the old name and scope. */
function editRequestOf(
  args: Record<string, unknown>,
  projectPath: string | null,
): { name: string; scope: string; projectPath: string | null; next: Record<string, unknown> } {
  const name = str(args, 'name')
  const scope = oneOf(args, 'scope', SCOPES)
  const next = optRecord(args, 'next') ?? {}
  return {
    name,
    scope,
    projectPath,
    next: addRequestOf({ name, scope, ...next }, projectPath),
  }
}
