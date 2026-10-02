import type { AddServerDraft, ServerResult } from '../servers/ipc'
import type { KeyFileOffer } from '../servers/keyfiles'
import type { ServerSummary } from '../servers/actions'
import { SETUP_AGENTS } from '../servers/setup'
import { CONTROL_IDS } from '../remote/protocol'
import {
  bool,
  hereOnly,
  int,
  KEY_NAMES,
  keysFrom,
  pressKeys,
  typeLine,
  oneOf,
  optBool,
  optStr,
  sendableFile,
  str,
  strList,
  verbOf,
} from './area-shared'
import { BadArgument, sanitizeSendText, type ToolOutput, type ToolSpec } from './catalogue'
import type { ChannelCall } from './channel-tap'
import { Refused } from './surface'

/**
 * Everything else a person does in the server room, beside the three tools
 * `servers/tools.ts` already has.
 *
 * ## What was there, and what this adds
 *
 * `servers.look`, `servers.logs` and `servers.control` are the copilot's way to
 * read a server and to do one of six named things to one site, app or database
 * on it — each with a consequence sentence, a class and a way back, and a
 * per-server grant that can lower `alter` to `act`. They are unchanged, and
 * `no-run-tool.test.ts` still pins that list at three.
 *
 * What a person can also do, and the copilot could not, is the rest of the
 * server's page: add one, rename or forget it, choose its key, see its folders
 * and ports, put an agent or the host program on it, and open its terminal.
 * Asad's ask for this release was that *"everything that I can do manually
 * should be able to do through the MCP"*, so this file is the rest of that page,
 * in four definitions:
 *
 *  - **`servers.details`** — read. Setup, host, ports, folders, the start-in
 *    folder, the grant, the key files on offer, what an action would do, the
 *    open terminals and one terminal's screen.
 *  - **`servers.ports`** — act. Give a server's port an address here, and back.
 *  - **`servers.manage`** — alter. Add, rename, forget, keys, start-in, the
 *    window grant, upload, install and sign in an agent, install and pair the
 *    host.
 *  - **`servers.shell`** — alter. The terminal.
 *
 * ## The terminal, and the decision it reverses
 *
 * `SERVERS-DESIGN.md` §6.1 said *"There is no `servers.run`, and there will not
 * be one in v1,"* because *"an arbitrary-command tool is the whole machine, and
 * it makes every rule above decorative."* That reasoning is right about what a
 * terminal is, and it is still what governs the three named tools: they stay
 * closed lists, and the grant still lowers only them.
 *
 * What changed is the ask. 0.16.0 is explicitly *everything a person can do*,
 * and a person can open that terminal and type. So the terminal is here, on the
 * terms the design document set for anything this sharp:
 *
 *  - **`alter`, every call, always.** No grant lowers it — §6.2: *"A grant
 *    covers the `act` tier only. It never covers zone three: not the terminal."*
 *    `servers.shell` never consults `ServerGrants` at all.
 *  - **The dialog shows exactly what will be typed,** whole. Text longer than
 *    {@link MAX_SHELL_CHARS} is refused before the dialog rather than shortened
 *    in it, so a person can never approve a line they were not shown.
 *  - **One line per call.** No newlines inside the text — `sanitizeSendText`,
 *    the same rule `sessions.send` follows — so one approval is one command.
 *  - **Only the person at this computer.** {@link hereOnly}.
 *  - **Its description says what it is**, in the words a model reads first:
 *    whatever is typed runs with that account's full power and has no undo.
 *
 * The cost §6.1 accepted — *"the copilot cannot fix a server in a way we did not
 * anticipate"* — is no longer paid. The price instead is a person reading a
 * command before it runs, which is the price a person pays when they type it.
 *
 * ## The two things that never come back
 *
 * `servers:key-read` hands the renderer a **private key's text** so it can go
 * into the add form. Here the key is read and handed straight to `servers:add`
 * inside this process; it is never in a result, and never in the log. And a
 * password or passphrase given to `add` is redacted from the log by name.
 */

/* ------------------------------------------------------------ the wire --- */

type Answer<T> = ServerResult<T>

export type ServerChannels = {
  'servers:list': { args: []; result: ServerSummary[] }
  'servers:preview': { args: [string, string, string]; result: Answer<{ preview: unknown }> }
  'servers:setup:look': { args: [string]; result: Answer<{ rows: unknown[] }> }
  'servers:setup:state': { args: [string, string]; result: unknown }
  'servers:host:look': { args: [string]; result: Answer<{ offer: unknown }> }
  'servers:host:state': { args: [string]; result: unknown }
  'servers:ports': { args: [string]; result: unknown }
  'servers:folder': { args: [string, string]; result: unknown }
  'servers:start-in': { args: [string]; result: { path: string | null } }
  'servers:grant-state': { args: [string]; result: unknown }
  'servers:keys': { args: []; result: KeyFileOffer[] }
  'servers:key-read': { args: [string]; result: { ok: true; key: string } | { ok: false; sentence: string } }
  'servers:key-pick': { args: []; result: KeyFileOffer | null }
  'servers:controls:read': { args: [string]; result: unknown }
  'servers:controls:apply': { args: [string, string, string]; result: unknown }
  'servers:shell:account': { args: [string]; result: unknown }
  'servers:shell:open': { args: [string, number, number, string]; result: Answer<{ shellId: string }> }
  'servers:shell:write': { args: [string, string]; result: { written: boolean } }
  'servers:shell:close': { args: [string]; result: { closed: boolean } }
  'servers:reach': { args: [string, number]; result: unknown }
  'servers:reach:close': { args: [string, number]; result: boolean }
  'servers:close': { args: [string]; result: { closed: boolean } }
  'servers:setup:cancel': { args: [string]; result: { cancelled: boolean } }
  'servers:host:cancel': { args: [string]; result: { cancelled: boolean } }
  'servers:add': {
    args: [AddServerDraft]
    result: { ok: true; id: string; savedSignIn: boolean; note: string } | { ok: false; kind: string; sentence: string }
  }
  'servers:rename': { args: [string, string]; result: { renamed: boolean } }
  'servers:forget': { args: [string]; result: { forgotten: boolean } }
  'servers:revoke': { args: [string]; result: { revoked: boolean } }
  'servers:start-in:set': { args: [string, string]; result: { saved: boolean } }
  'servers:drive-windows': { args: [string, boolean]; result: { drivesWindows: boolean } }
  'servers:upload': { args: [string, string]; result: { ok: true; path: string } | { ok: false; message: string } }
  'servers:setup:install': { args: [string, string, string]; result: Answer<{ state: { step: string } }> }
  'servers:setup:signin': { args: [string, string, string]; result: Answer<{ state: { step: string } }> }
  'servers:setup:signout': { args: [string, string, string]; result: Answer<{ state: { step: string } }> }
  'servers:setup:remove': { args: [string, string]; result: Answer<{ state: { step: string } }> }
  'servers:host:install': { args: [string, string]; result: Answer<{ state: { step: string } }> }
  'servers:host:pair': { args: [string, string]; result: Answer<{ state: { step: string } }> }
  'servers:host:link': { args: [string, string]; result: Answer<{ state: { step: string } }> }
  'servers:host:remove': { args: [string, boolean]; result: Answer<{ state: { step: string } }> }
}

export interface ServerRoomToolsDeps {
  call: ChannelCall<ServerChannels>
  /** `ServersIpc.openShells` — every terminal open on a server now. */
  openShells(): Array<{ shellId: string; serverId: string; openedAt: number | null }>
  /** `ServersIpc.shellScreen` — the screen each shell's own shadow terminal holds. */
  shellScreen(shellId: string): Promise<string | null>
  /** This app's data folder, which nothing is ever uploaded out of. */
  userData(): string
}

/* ------------------------------------------------------------- limits ---- */

/** Longest line `servers.shell` types in one call — short enough that the dialog shows all of it. */
export const MAX_SHELL_CHARS = 1000
/** The size a terminal opened by a tool is given — the size a copilot-started local session gets. */
const SHELL_COLS = 120
const SHELL_ROWS = 30

const ABOUT = ['setup', 'host', 'ports', 'folder', 'start-in', 'grant', 'keys', 'preview', 'shells', 'shell'] as const
const PORT_VERBS = ['open-here', 'close-here', 'disconnect', 'cancel-setup', 'cancel-host'] as const
const SHELL_VERBS = ['open', 'type', 'keys', 'set', 'close'] as const
const MANAGE_VERBS = [
  'add',
  'rename',
  'forget',
  'revoke',
  'set-start-in',
  'allow-windows',
  'upload',
  'install-agent',
  'sign-in-agent',
  'sign-out-agent',
  'remove-agent',
  'install-host',
  'pair-host',
  'link-host',
  'remove-host',
] as const
type ManageVerb = (typeof MANAGE_VERBS)[number]

/** Steps after which nothing is still using the terminal it ran in. */
const FINISHED = new Set(['done', 'failed', 'idle'])

/* ----------------------------------------------------------- the tools --- */

export function serverRoomTools(deps: ServerRoomToolsDeps): ToolSpec[] {
  let lastServers: ServerSummary[] | null = null

  const servers = async (): Promise<ServerSummary[]> => {
    lastServers = await deps.call('servers:list')
    return lastServers
  }

  const nameOf = (serverId: string): string => lastServers?.find((row) => row.id === serverId)?.name ?? serverId

  const knownIfListed = (serverId: string): void => {
    if (lastServers === null || lastServers.some((row) => row.id === serverId)) return
    throw new Refused('not-permitted', `There is no server with the id ${serverId} in this app. servers.look lists them.`)
  }

  const requireServer = async (serverId: string): Promise<void> => {
    if (!(await servers()).some((row) => row.id === serverId)) {
      throw new Refused('not-permitted', `There is no server with the id ${serverId} in this app. servers.look lists them.`)
    }
  }

  const shellOf = (shellId: string): { shellId: string; serverId: string } => {
    const found = deps.openShells().find((row) => row.shellId === shellId)
    if (found === undefined) {
      throw new Refused(
        'not-permitted',
        `No terminal ${shellId} is open. servers.details with about "shells" lists the open ones; servers.shell with do "open" opens one.`,
      )
    }
    return found
  }

  /** A `ServerResult` that said no, as a refusal carrying the server's own sentence. */
  const unwrap = <T>(answer: Answer<T>): T & { ok: true } => {
    if (!answer.ok) throw new Refused('not-permitted', answer.sentence)
    return answer
  }

  /* ---------------------------------------------------------- details ----- */

  const details: ToolSpec = {
    id: 'servers.details',
    wire: 'servers_details',
    tier: 'read',
    title: 'Read more about a server',
    description:
      'Everything on a server’s page beyond what servers.look shows. about: "setup" (which coding agents are on ' +
      'it, and whether each can be installed or signed in); "host" (whether this app’s host program is on it, ' +
      'running and linked); "ports" (what it listens on); "folder" (list a folder on it — path, default its home); ' +
      '"start-in" (the folder its terminals open in); "grant" (whether you have been given control of it, and ' +
      'until when); "keys" (the SSH key files on this computer that a server can be added with — names only, ' +
      'never their contents); "preview" (the exact sentence and consequence of one servers.control action, cardId ' +
      'and action); "shells" (terminals open on servers now); "shell" (one terminal’s screen, its agent’s model and ' +
      'who it is signed in as — shellId).',
    index:
      'More on a server: agent setup, host, ports, folders, SSH keys, your grant, an action’s preview, terminal screens.',
    inputSchema: {
      type: 'object',
      properties: {
        about: { type: 'string', enum: [...ABOUT] },
        serverId: { type: 'string', description: 'Every about except keys, shells and shell.' },
        path: { type: 'string', description: 'folder: the folder on the server. Default: its home.' },
        cardId: { type: 'string', description: 'preview: from servers.look.' },
        action: { type: 'string', description: 'preview: one of the actions servers.control takes.' },
        shellId: { type: 'string', description: 'shell: from about "shells".' },
      },
      required: ['about'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Reading a server’s page')
      const about = oneOf(args, 'about', ABOUT)
      if (about !== 'keys' && about !== 'shells' && about !== 'shell') knownIfListed(str(args, 'serverId'))
      if (about === 'preview') {
        str(args, 'cardId')
        str(args, 'action')
      }
      if (about === 'shell') shellOf(str(args, 'shellId'))
    },
    summary: (args) => {
      const about = typeof args.about === 'string' ? args.about : '?'
      if (about === 'keys') return 'List the SSH key files on this computer'
      if (about === 'shells') return 'List the terminals open on servers'
      if (about === 'shell') return `Read the terminal ${String(args.shellId)}`
      return `Read the ${about} of ${nameOf(typeof args.serverId === 'string' ? args.serverId : '?')}`
    },
    run: async (args): Promise<ToolOutput> => {
      const about = oneOf(args, 'about', ABOUT)

      if (about === 'keys') {
        const keys = await deps.call('servers:keys')
        return {
          value: {
            keys: keys.map((key) => ({ path: key.path, name: key.name, what: key.what, needsPassphrase: key.locked })),
            note: 'servers.manage with do "add" and keyPath set to one of these signs in with it. Only files listed here can be used.',
          },
          summary: { keys: keys.length },
        }
      }
      if (about === 'shells') {
        const open = deps.openShells()
        await servers()
        return {
          value: { shells: open.map((row) => ({ ...row, server: nameOf(row.serverId) })) },
          summary: { shells: open.length },
        }
      }
      if (about === 'shell') {
        const shell = shellOf(str(args, 'shellId'))
        const [screen, controls, account] = await Promise.all([
          deps.shellScreen(shell.shellId),
          deps.call('servers:controls:read', shell.shellId),
          deps.call('servers:shell:account', shell.shellId),
        ])
        return {
          value: { ...shell, server: nameOf(shell.serverId), screen, controls, signedIn: account },
          summary: { shellId: shell.shellId, screen: screen !== null },
        }
      }

      const serverId = str(args, 'serverId')
      await requireServer(serverId)
      switch (about) {
        case 'setup': {
          const answer = unwrap(await deps.call('servers:setup:look', serverId))
          return { value: { serverId, agents: answer.rows }, summary: { serverId, agents: answer.rows.length } }
        }
        case 'host': {
          const answer = unwrap(await deps.call('servers:host:look', serverId))
          return { value: { serverId, host: answer.offer }, summary: { serverId } }
        }
        case 'ports':
          return { value: { serverId, ports: await deps.call('servers:ports', serverId) }, summary: { serverId } }
        case 'folder': {
          const answer = await deps.call('servers:folder', serverId, optStr(args, 'path') ?? '')
          return { value: answer, summary: { serverId } }
        }
        case 'start-in':
          return { value: { serverId, ...(await deps.call('servers:start-in', serverId)) }, summary: { serverId } }
        case 'grant':
          return { value: { serverId, grant: await deps.call('servers:grant-state', serverId) }, summary: { serverId } }
        default: {
          const answer = unwrap(await deps.call('servers:preview', serverId, str(args, 'cardId'), str(args, 'action')))
          return { value: { serverId, preview: answer.preview }, summary: { serverId, action: str(args, 'action') } }
        }
      }
    },
  }

  /* ---------------------------------------------------------- ports ------- */

  const ports: ToolSpec = {
    id: 'servers.ports',
    wire: 'servers_ports',
    tier: 'act',
    title: 'Reach a server’s port, or let go of a server',
    description:
      'Routine connection work on a server. do: "open-here" gives one of its ports an http address on this ' +
      'computer and returns the URL (servers.details about "ports" lists them); "close-here" hands it back; ' +
      '"disconnect" closes this app’s connection to the server once you are finished with it (its terminals stay ' +
      'open); "cancel-setup" and "cancel-host" stop an agent or host install that is in progress.',
    index: 'Give a server port an address here, disconnect from a server, or cancel an install.',
    inputSchema: {
      type: 'object',
      properties: {
        serverId: { type: 'string' },
        do: { type: 'string', enum: [...PORT_VERBS] },
        port: { type: 'integer', description: 'open-here and close-here.' },
      },
      required: ['serverId', 'do'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Connecting to a server')
      knownIfListed(str(args, 'serverId'))
      const verb = oneOf(args, 'do', PORT_VERBS)
      if (verb === 'open-here' || verb === 'close-here') int(args, 'port', 1, 65535)
    },
    summary: (args) => {
      const server = nameOf(typeof args.serverId === 'string' ? args.serverId : '?')
      switch (verbOf(args)) {
        case 'open-here':
          return `Give port ${String(args.port)} on ${server} an address on this computer`
        case 'close-here':
          return `Stop serving port ${String(args.port)} of ${server} here`
        case 'disconnect':
          return `Close this app’s connection to ${server}`
        case 'cancel-setup':
          return `Cancel the agent install in progress on ${server}`
        default:
          return `Cancel the host install in progress on ${server}`
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const serverId = str(args, 'serverId')
      const verb = oneOf(args, 'do', PORT_VERBS)
      await requireServer(serverId)
      switch (verb) {
        case 'open-here': {
          const port = int(args, 'port', 1, 65535)
          const answer = (await deps.call('servers:reach', serverId, port)) as { ok?: boolean; message?: string } | null
          if (answer?.ok !== true) throw new Refused('not-permitted', answer?.message ?? 'That port could not be reached.')
          return { value: answer, summary: { serverId, port } }
        }
        case 'close-here': {
          const port = int(args, 'port', 1, 65535)
          return { value: { serverId, port, closed: await deps.call('servers:reach:close', serverId, port) }, summary: { serverId, port } }
        }
        case 'disconnect':
          return { value: { serverId, ...(await deps.call('servers:close', serverId)) }, summary: { serverId } }
        case 'cancel-setup':
          return { value: { serverId, ...(await deps.call('servers:setup:cancel', serverId)) }, summary: { serverId } }
        default:
          return { value: { serverId, ...(await deps.call('servers:host:cancel', serverId)) }, summary: { serverId } }
      }
    },
  }

  /* ---------------------------------------------------------- shell ------- */

  const shell: ToolSpec = {
    id: 'servers.shell',
    wire: 'servers_shell',
    tier: 'alter',
    title: 'Type into a terminal on a server',
    description:
      'A real terminal on a server, signed in as that server’s account. Whatever you type runs with that ' +
      'account’s full power and cannot be undone — prefer servers.control’s named actions when one fits. Every ' +
      'call asks the person first and shows them exactly what will be typed; being given control of a server does ' +
      'not change that. do: "open" a terminal (folder optional) and get its shellId; "type" one line of text ' +
      `(submit presses return, default true; at most ${MAX_SHELL_CHARS} characters, no newlines); "keys" presses ` +
      'named keys such as enter, ctrl-c, up; "set" changes the model, effort, fast or permission mode of the agent ' +
      'running in it; "close" it. Read what it shows with servers.details about "shell".',
    index:
      'A real terminal on a server: open, type a line, press keys, close. Every call asks the person.',
    inputSchema: {
      type: 'object',
      properties: {
        do: { type: 'string', enum: [...SHELL_VERBS] },
        serverId: { type: 'string', description: 'open.' },
        folder: { type: 'string', description: 'open: the folder to start in. Default: the server’s start-in folder.' },
        shellId: { type: 'string', description: 'Every do except open.' },
        text: { type: 'string', description: 'type: one line, printable characters only.' },
        submit: { type: 'boolean', description: 'type: press return afterwards. Default true.' },
        keys: {
          type: 'array',
          items: { type: 'string' },
          description: `keys: pressed in order — ${KEY_NAMES.join(', ')}, or one printable character.`,
        },
        control: { type: 'string', enum: [...CONTROL_IDS], description: 'set.' },
        value: { type: 'string', description: 'set.' },
      },
      required: ['do'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'A terminal on a server')
      const verb = oneOf(args, 'do', SHELL_VERBS)
      if (verb === 'open') {
        knownIfListed(str(args, 'serverId'))
        return
      }
      shellOf(str(args, 'shellId'))
      if (verb === 'type') {
        const text = sanitizeSendText(str(args, 'text'))
        if (text.length > MAX_SHELL_CHARS) {
          throw new BadArgument(
            `text must be ${MAX_SHELL_CHARS} characters or fewer, so the person can read all of it before it runs; got ${text.length}`,
          )
        }
      }
      if (verb === 'keys') keysFrom(strList(args, 'keys'))
      if (verb === 'set') {
        oneOf(args, 'control', CONTROL_IDS)
        str(args, 'value')
      }
    },
    /*
     * Whole, never shortened: the precheck has already refused anything too long
     * to show. A consent sentence that elided the end of a command would be a
     * person approving a line they did not read.
     */
    summary: (args) => {
      const where = (): string => {
        const shellId = typeof args.shellId === 'string' ? args.shellId : ''
        const found = deps.openShells().find((row) => row.shellId === shellId)
        return found === undefined ? `the terminal ${shellId}` : `the terminal on ${nameOf(found.serverId)}`
      }
      switch (verbOf(args)) {
        case 'open': {
          const folder = typeof args.folder === 'string' && args.folder !== '' ? ` in ${args.folder}` : ''
          return `Open a terminal on ${nameOf(String(args.serverId))}${folder}. Anything typed into it runs as that server’s account.`
        }
        case 'type':
          return `Type into ${where()}: ${String(args.text)}${args.submit === false ? '' : ' — and press return, which runs it'}`
        case 'keys':
          return `Press ${Array.isArray(args.keys) ? args.keys.join(', ') : '?'} in ${where()}`
        case 'set':
          return `Set ${String(args.control)} to ${String(args.value)} for the agent in ${where()}`
        default:
          return `Close ${where()}`
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const verb = oneOf(args, 'do', SHELL_VERBS)
      if (verb === 'open') {
        const serverId = str(args, 'serverId')
        await requireServer(serverId)
        const opened = unwrap(await deps.call('servers:shell:open', serverId, SHELL_COLS, SHELL_ROWS, optStr(args, 'folder') ?? ''))
        return {
          value: { serverId, shellId: opened.shellId, note: 'Read it with servers.details about "shell".' },
          summary: { serverId, shellId: opened.shellId },
        }
      }
      const { shellId, serverId } = shellOf(str(args, 'shellId'))
      if (verb === 'close') {
        return { value: { shellId, ...(await deps.call('servers:shell:close', shellId)) }, summary: { serverId, shellId } }
      }
      if (verb === 'set') {
        const control = oneOf(args, 'control', CONTROL_IDS)
        const answer = await deps.call('servers:controls:apply', shellId, control, str(args, 'value'))
        if ((answer as { ok?: unknown } | null)?.ok !== true) {
          throw new Refused('not-permitted', (answer as { message?: string } | null)?.message ?? 'That did not change.')
        }
        return { value: answer, summary: { serverId, shellId, control, value: str(args, 'value') } }
      }
      const text = verb === 'type' ? sanitizeSendText(str(args, 'text')) : null
      /*
       * One write per piece, with the measured gap between — the line, then its
       * Enter. At a bare shell prompt one write would do, but this terminal is
       * the one a person runs `claude` in on that server, and an agent CLI reads
       * a line and its return arriving together as a paste and never sends it.
       * See `session-typing.ts`.
       */
      const write = async (data: string): Promise<void> => {
        const written = await deps.call('servers:shell:write', shellId, data)
        if (!written.written) throw new Refused('not-permitted', 'That terminal closed before anything was typed.')
      }
      if (text === null) await pressKeys(write, keysFrom(strList(args, 'keys')))
      else await typeLine(write, text, optBool(args, 'submit', true))
      return {
        value: { shellId, typed: true, note: 'servers.details about "shell" shows what it printed.' },
        // Kept whole in the log, on purpose: what was run on a server is exactly
        // what a person must be able to read back afterwards.
        summary: { serverId, shellId, ...(text === null ? { keys: strList(args, 'keys') } : { text, submitted: optBool(args, 'submit', true) }) },
      }
    },
  }

  /* ---------------------------------------------------------- manage ------ */

  const AGENT_VERBS: readonly ManageVerb[] = ['install-agent', 'sign-in-agent', 'sign-out-agent', 'remove-agent']
  const NEEDS_SHELL: readonly ManageVerb[] = ['install-agent', 'sign-in-agent', 'sign-out-agent', 'install-host', 'pair-host', 'link-host']

  /**
   * Run one flow that types into a terminal, in the person's own terminal when
   * they named one, otherwise in one opened for it.
   *
   * A terminal opened here is closed afterwards **only once the flow is
   * finished**: closing a server's terminal cancels any setup in progress on it
   * (`dropShell` in `servers/ipc.ts`), and an install chains straight into its
   * sign-in. So an unfinished flow keeps its terminal and says which one.
   */
  const inShell = async (
    serverId: string,
    named: string | null,
    flow: (shellId: string) => Promise<Answer<{ state: { step: string } }>>,
  ): Promise<ToolOutput> => {
    const shellId =
      named ?? unwrap(await deps.call('servers:shell:open', serverId, SHELL_COLS, SHELL_ROWS, '')).shellId
    const state = unwrap(await flow(shellId)).state
    const finished = FINISHED.has(state.step)
    if (named === null && finished) await deps.call('servers:shell:close', shellId)
    return {
      value: {
        serverId,
        state,
        ...(finished
          ? {}
          : {
              shellId,
              note:
                'Still going, in this terminal. Watch it with servers.details about "shell"; closing it cancels what is running.',
            }),
      },
      summary: { serverId, step: state.step },
    }
  }

  const manage: ToolSpec = {
    id: 'servers.manage',
    wire: 'servers_manage',
    tier: 'alter',
    title: 'Add, change or set up a server',
    description:
      'Change the server list and what is installed on a server. Every call asks the person first. do: "add" a ' +
      'server (address, username, and either keyPath — a key file listed by servers.details about "keys", or ' +
      '"choose" to let the person pick one — or ' +
      'password; passphrase for a locked key; name and port optional); "rename"; "forget" it (its sign-in is ' +
      'deleted from this computer); "revoke" any control the person gave you over it; "set-start-in" the folder ' +
      'its terminals open in (empty to clear); "allow-windows" lets sessions on it drive browser windows here; ' +
      '"upload" a file from this computer to it; "install-agent", "sign-in-agent", "sign-out-agent", ' +
      '"remove-agent" for agent claude, codex or gemini; "install-host", "pair-host", "link-host" (link this ' +
      'computer to the host on it), "remove-host" (alsoData to delete its data too). Flows that type into a ' +
      'terminal use shellId when given, so the person can watch, and open their own otherwise.',
    index:
      'Add, rename or forget a server; upload to it; install or sign in an agent or the host on it.',
    inputSchema: {
      type: 'object',
      properties: {
        do: { type: 'string', enum: [...MANAGE_VERBS] },
        serverId: { type: 'string', description: 'Every do except add.' },
        address: { type: 'string', description: 'add: hostname or IP.' },
        username: { type: 'string', description: 'add.' },
        name: { type: 'string', description: 'add (optional) and rename.' },
        port: { type: 'integer', description: 'add: SSH port. Default 22.' },
        keyPath: {
          type: 'string',
          description: 'add: a path from servers.details about "keys", or "choose" to have the person pick the file on this computer.',
        },
        password: { type: 'string', description: 'add: the account password, when not signing in with a key.' },
        passphrase: { type: 'string', description: 'add: the key’s passphrase, when it has one.' },
        remember: { type: 'boolean', description: 'add: keep the sign-in after the app closes. Default true.' },
        folder: { type: 'string', description: 'set-start-in.' },
        allowed: { type: 'boolean', description: 'allow-windows.' },
        path: { type: 'string', description: 'upload: absolute path of a file on this computer.' },
        agent: { type: 'string', enum: [...SETUP_AGENTS], description: 'The agent verbs.' },
        shellId: { type: 'string', description: 'Terminal flows: run in this open terminal.' },
        alsoData: { type: 'boolean', description: 'remove-host: also delete its data.' },
      },
      required: ['do'],
      additionalProperties: false,
    },
    redactArgs: (args) => ({
      ...args,
      // `password` is caught by the log's own key-name pass; `passphrase` is not,
      // and it unlocks a private key, so it is named here.
      ...(args.passphrase === undefined ? {} : { passphrase: '[redacted]' }),
      ...(args.password === undefined ? {} : { password: '[redacted]' }),
    }),
    precheck: (args, context) => {
      hereOnly(context.caller, 'Changing a server')
      const verb = oneOf(args, 'do', MANAGE_VERBS)
      if (verb === 'add') {
        str(args, 'address')
        str(args, 'username')
        if (args.port !== undefined) int(args, 'port', 1, 65535)
        const key = optStr(args, 'keyPath')
        const password = optStr(args, 'password')
        if ((key === null) === (password === null)) throw new BadArgument('add needs exactly one of keyPath or password')
        return
      }
      knownIfListed(str(args, 'serverId'))
      if (verb === 'rename') str(args, 'name')
      if (verb === 'allow-windows') bool(args, 'allowed')
      if (verb === 'upload') sendableFile(str(args, 'path'), [deps.userData()])
      if (AGENT_VERBS.includes(verb)) oneOf(args, 'agent', SETUP_AGENTS)
      const shellId = optStr(args, 'shellId')
      if (shellId !== null) {
        if (!NEEDS_SHELL.includes(verb)) throw new BadArgument(`${verb} does not use a terminal; leave shellId out`)
        if (shellOf(shellId).serverId !== args.serverId) throw new BadArgument('that terminal is on a different server')
      }
    },
    summary: (args) => {
      const server = nameOf(typeof args.serverId === 'string' ? args.serverId : '?')
      const agent = typeof args.agent === 'string' ? args.agent : '?'
      switch (verbOf(args) as ManageVerb) {
        case 'add':
          return `Add the server ${String(args.username)}@${String(args.address)}${typeof args.port === 'number' ? `:${args.port}` : ''}, signing in with ${
            args.keyPath === 'choose'
              ? 'a key file you choose in the window that opens'
              : typeof args.keyPath === 'string'
                ? `the key ${args.keyPath}`
                : 'a password'
          }`
        case 'rename':
          return `Rename ${server} to “${String(args.name)}”`
        case 'forget':
          return `Forget ${server}: its sign-in is deleted from this computer and its terminals close`
        case 'revoke':
          return `Take back any control you were given over ${server}`
        case 'set-start-in':
          return typeof args.folder === 'string' && args.folder !== ''
            ? `Open ${server}’s terminals in ${args.folder}`
            : `Open ${server}’s terminals in its home folder`
        case 'allow-windows':
          return args.allowed === true
            ? `Let sessions on ${server} drive browser windows in this app`
            : `Stop sessions on ${server} driving browser windows in this app`
        case 'upload':
          return `Copy ${String(args.path)} from this computer onto ${server}`
        case 'install-agent':
          return `Install ${agent} on ${server}, in its account’s own home folder`
        case 'sign-in-agent':
          return `Sign ${agent} in on ${server}`
        case 'sign-out-agent':
          return `Sign ${agent} out on ${server}`
        case 'remove-agent':
          return `Remove ${agent} from ${server}`
        case 'install-host':
          return `Install this app’s host program on ${server}, so its sessions can be reached from here and from paired devices`
        case 'pair-host':
          return `Show a code on ${server}’s host for a phone or another computer to pair with it`
        case 'link-host':
          return `Link this computer to the host on ${server}, so it appears in this app’s machines`
        case 'remove-host':
          return args.alsoData === true
            ? `Remove the host program from ${server}, and delete its data`
            : `Remove the host program from ${server}, keeping its data`
        default:
          return `Change ${server}`
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const verb = oneOf(args, 'do', MANAGE_VERBS)

      if (verb === 'add') {
        const keyPath = optStr(args, 'keyPath')
        let draft: AddServerDraft
        if (keyPath !== null) {
          /*
           * The key is read through the same guard the window's add form uses —
           * only a file `servers:keys` offered, or one the person chose in the
           * Mac's own file panel, may be read — and goes straight into the draft.
           * It is never part of anything this returns.
           */
          let path = keyPath
          if (keyPath === 'choose') {
            const chosen = await deps.call('servers:key-pick')
            if (chosen === null) throw new Refused('not-permitted', 'No key file was chosen, or the file chosen is not a private key.')
            path = chosen.path
          } else {
            await deps.call('servers:keys')
          }
          const read = await deps.call('servers:key-read', path)
          if (!read.ok) throw new Refused('not-permitted', read.sentence)
          draft = { method: 'key', key: read.key, passphrase: optStr(args, 'passphrase') ?? undefined } as AddServerDraft
        } else {
          draft = { method: 'password', password: str(args, 'password') } as AddServerDraft
        }
        draft = {
          ...draft,
          address: str(args, 'address'),
          username: str(args, 'username'),
          ...(optStr(args, 'name') === null ? {} : { name: str(args, 'name') }),
          ...(args.port === undefined ? {} : { port: int(args, 'port', 1, 65535) }),
          remember: optBool(args, 'remember', true),
        }
        const added = await deps.call('servers:add', draft)
        if (!added.ok) throw new Refused('not-permitted', added.sentence)
        await servers()
        return { value: added, summary: { serverId: added.id, savedSignIn: added.savedSignIn } }
      }

      const serverId = str(args, 'serverId')
      await requireServer(serverId)
      const shellId = optStr(args, 'shellId')
      switch (verb) {
        case 'rename': {
          const name = str(args, 'name')
          return { value: { serverId, ...(await deps.call('servers:rename', serverId, name)) }, summary: { serverId, name } }
        }
        case 'forget': {
          const answer = await deps.call('servers:forget', serverId)
          await servers()
          return { value: { serverId, ...answer }, summary: { serverId } }
        }
        case 'revoke':
          return { value: { serverId, ...(await deps.call('servers:revoke', serverId)) }, summary: { serverId } }
        case 'set-start-in': {
          const folder = optStr(args, 'folder') ?? ''
          return { value: { serverId, ...(await deps.call('servers:start-in:set', serverId, folder)) }, summary: { serverId, folder } }
        }
        case 'allow-windows': {
          const allowed = bool(args, 'allowed')
          return { value: { serverId, ...(await deps.call('servers:drive-windows', serverId, allowed)) }, summary: { serverId, allowed } }
        }
        case 'upload': {
          const path = sendableFile(str(args, 'path'), [deps.userData()])
          const answer = await deps.call('servers:upload', serverId, path)
          if (!answer.ok) throw new Refused('not-permitted', answer.message)
          return { value: { serverId, path: answer.path }, summary: { serverId, from: path } }
        }
        case 'install-agent':
        case 'sign-in-agent':
        case 'sign-out-agent': {
          const agent = oneOf(args, 'agent', SETUP_AGENTS)
          const channel =
            verb === 'install-agent' ? 'servers:setup:install' : verb === 'sign-in-agent' ? 'servers:setup:signin' : 'servers:setup:signout'
          return inShell(serverId, shellId, (shell) => deps.call(channel, serverId, agent, shell))
        }
        case 'remove-agent': {
          const agent = oneOf(args, 'agent', SETUP_AGENTS)
          const state = unwrap(await deps.call('servers:setup:remove', serverId, agent)).state
          return { value: { serverId, state }, summary: { serverId, step: state.step } }
        }
        case 'install-host':
          return inShell(serverId, shellId, (shell) => deps.call('servers:host:install', serverId, shell))
        case 'pair-host':
          return inShell(serverId, shellId, (shell) => deps.call('servers:host:pair', serverId, shell))
        case 'link-host':
          return inShell(serverId, shellId, (shell) => deps.call('servers:host:link', serverId, shell))
        default: {
          const state = unwrap(await deps.call('servers:host:remove', serverId, optBool(args, 'alsoData', false))).state
          return { value: { serverId, state }, summary: { serverId, step: state.step } }
        }
      }
    },
  }

  return [details, ports, manage, shell]
}

/** Every id this file contributes. */
export const SERVER_ROOM_TOOL_IDS = ['servers.details', 'servers.ports', 'servers.manage', 'servers.shell'] as const
