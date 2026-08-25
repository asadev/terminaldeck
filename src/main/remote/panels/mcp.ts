import { isAbsolute } from 'node:path'
import { addMcpServer, quoteArgv, removeMcpServer, type McpAddScope, type McpAddTransport } from '../../mcp-add'
import { loadServers, type McpServerConfig } from '../../mcp-client'
import { editMcpServer, type McpEditDeps, type McpExisting } from '../../mcp-edit'
import type { PanelAction, PanelField, PanelRow, PanelScope } from '../protocol'
import type { Panel, PanelActionRequest, PanelPayload, PanelRequest } from './contract'

/**
 * The MCP servers panel: what is configured for a folder, and the six things a
 * person does to one.
 *
 * ## What this replaces, and why the stand-in was wrong twice
 *
 * `server.ts` answered this panel from a local `readMcpServers()` that opened
 * `.mcp.json`, `.claude/settings.json` and `.claude/settings.local.json` under
 * the folder in view. Two defects, and the second is the interesting one:
 *
 *  1. It had no verbs. *"All the features and options to edit or add or
 *     whatever the actions we have in the desktop app should be in mobile app
 *     too."*
 *  2. **It read the wrong files.** Only the first of those three ever holds an
 *     `mcpServers` key — `mcp-client.ts` says so from a measurement, *"`~/
 *     .claude/settings.json` carries no `mcpServers` key, so we do not invent
 *     one"* — and the file that holds most people's servers was not on the list
 *     at all. User scope lives in `~/.claude.json` under `mcpServers`, and the
 *     project-private `local` scope lives in the same file under
 *     `projects[<folder>].mcpServers`. A phone looking at a folder with no
 *     `.mcp.json` was told *"No MCP servers are configured"* while the desktop,
 *     three feet away, listed a dozen.
 *
 * So the read is `loadServers` from `mcp-client.ts` — the same function the
 * desktop's own `mcp:list` calls. It reads all three scopes, applies Claude
 * Code's approval gates to shared `.mcp.json` servers, expands `${VAR}`
 * references and resolves the precedence rule (local beats project beats user)
 * so one name is one row. None of that is re-derived here.
 *
 * ## Nothing in this file needs Electron, and that is the point
 *
 * The Store panel threw on a headless host and the phone said *"This machine
 * could not answer that panel."* Every dependency here is a file read or a
 * child process: `loadServers` is `readFileSync` and `JSON.parse`, and the three
 * writes shell out to `claude mcp …` for the reason `mcp-add.ts` sets out at
 * length — `~/.claude.json` is another application's live 70KB database and is
 * not ours to read-modify-write. There is no `app`, no window, no
 * `safeStorage`. A failure that does happen anyway — an unreadable config, a
 * missing CLI — comes back as a `note` or a `notice` in a sentence, never as a
 * throw.
 *
 * ## Six of the fourteen channels, and why the other eight are not here
 *
 * The desktop's MCP surface is `mcp:list`, `add`, `edit`, `remove`, `connect`,
 * `disconnect`, `store`, `store-install`, `inventory`, `import`, `export`,
 * `call`, `read-resource` and `get-prompt`. The six above the line are here.
 *
 *  - `call`, `read-resource`, `get-prompt` are an **agent's** verbs, not a
 *    person's. Each takes a tool name plus an arbitrary JSON argument object
 *    shaped by that server's own schema — which is why the desktop has
 *    `McpSchemaForm.tsx` generating a form from the schema — and answers with an
 *    arbitrary JSON result. A `PanelField` is a text box and a `PanelRow` is one
 *    line, so the honest phone version of these is not a smaller version of the
 *    desktop's, it is a different feature. Half of one is worse than none.
 *  - `inventory` is a read rather than a write, and it is left out for the same
 *    shape reason: it answers with three nested lists (tools, resources,
 *    prompts) whose only use is feeding the three channels above. A screen of
 *    tool names nothing can be done to answers *what can this server do* with a
 *    list of nouns.
 *  - `store` and `store-install` are the **Store panel**, which is its own
 *    module beside this one. A catalogue rendered twice is a catalogue that
 *    drifts.
 *  - `import` and `export` move a `.tool` file through an Electron save/open
 *    dialog — `McpIpcDeps.chooseSaveFile` and `chooseToolFile`. There is no
 *    dialog on a headless host and no way to hand the phone the file over this
 *    frame, so the pair is left where the file picker is.
 *
 * ## The environment box, and the one gesture the wire could not carry
 *
 * The desktop edits variables in a textarea, one `KEY=value` per line, and its
 * rules are: a blank value keeps what is saved, and **deleting the line drops
 * the variable**. That textarea cannot cross this wire — the codec refuses a
 * control character in a field value, and `\n` is one — so each variable gets
 * its own field, prefilled with `KEY=` and nothing after it.
 *
 * That prefill is what makes every gesture survive the transposition:
 *
 *  - leave the box as it is  → `KEY=`      → `mergeEnvironment` keeps the saved value
 *  - type after the `=`      → `KEY=new`   → replaced
 *  - clear the whole box     → ` `         → dropped, exactly as deleting the line does
 *
 * The value itself never crosses the wire in either direction. `loadServers`
 * has it, the merge happens in this process, and the phone is sent the key only
 * — the same asymmetry `configuredForStore` keeps for the desktop's renderer.
 *
 * An HTTP or SSE server's **headers** are the one thing an edit cannot
 * preserve, on the phone as on the desktop: this app's reader has never read
 * headers back out of the configuration, so there is nothing to prefill and
 * saving replaces them with whatever is in the box. The field says so rather
 * than dropping them quietly.
 *
 * ## Two shapes this panel asks for that `PanelField` cannot draw
 *
 * A `PanelField` is a text box, so the two places the desktop uses a `<select>`
 * become prefilled text: the three legal scope words go in the field's *label*,
 * where they are always drawn, and the box arrives holding `user` — the same
 * default `McpStore.tsx` opens with. The transport is not asked at all; it is
 * read off the shape, which is what `parseServerEntry` already does with
 * configuration written in the wild (*"a `command` means stdio, a `url` means
 * HTTP"*). The cost is exact and worth naming: a server can be added over the
 * phone as stdio or HTTP but not as SSE, the transport the specification
 * replaced with streamable HTTP. An SSE server that is already configured keeps
 * its transport through an edit.
 */

/* ------------------------------------------------------------------ deps -- */

/**
 * The live connections this host is holding, when it holds any.
 *
 * Structurally the three methods of `McpPool` that a person's screen needs, so
 * the desktop's own pool satisfies it without an adapter — but declared here as
 * the narrow shape rather than imported, because the module-level pool in
 * `mcp-client.ts` is private to that file and a second one is not a substitute:
 * a pool of our own would spawn a second copy of every server the phone
 * connects, and the window three feet away would still say *not connected*. So
 * this is injected and never defaulted, and a host that passes nothing gets a
 * panel that lists, adds, edits and removes and does not claim to know what is
 * running.
 */
export interface McpPanelPool {
  connect(server: McpServerConfig): Promise<{ state: string; error: string | null }>
  disconnect(id: string): Promise<{ state: string; error: string | null } | null>
  getStatus(id: string): { state: string; error: string | null } | null
}

export interface McpPanelDeps {
  /**
   * Every server configured for a folder. Defaults to `loadServers`, which is
   * files on disk and dials nothing — a panel that connected to each server to
   * draw a list would take as long as the slowest one and could hang on a
   * broken entry.
   */
  list?(projectPath: string | null): McpServerConfig[]
  pool?: McpPanelPool
  /**
   * Handed to `mcp-add.ts` and `mcp-edit.ts` for the three writes. A test gives
   * `exec` and `path` and no process is spawned; a host gives nothing and the
   * real `claude mcp …` runs. `read` is filled in from `list` below unless the
   * caller has its own.
   */
  writes?: McpEditDeps
}

/* --------------------------------------------------------------- shaping -- */

/** The action ids this panel offers. Nothing else is honoured. */
const ADD = 'add'
const EDIT = 'edit'
const REMOVE = 'remove'
const CONNECT = 'connect'
const DISCONNECT = 'disconnect'

const ENV_FIELD = /^env\.(\d+)$/
const SCOPES: readonly McpAddScope[] = ['user', 'project', 'local']

/**
 * How many environment fields a form may carry.
 *
 * `MAX_PANEL_FIELDS` in `protocol.ts` refuses a `panel.act` carrying more than
 * twenty-four, and it is not exported, so the number is repeated here with the
 * four fixed fields and the one blank slot subtracted. A form the host built
 * larger than the codec accepts is a Save button that fails on the way back.
 */
const MAX_ENV_FIELDS = 24 - 4 - 1

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause)
}

/**
 * What a server runs, as one line.
 *
 * Quoted rather than space-joined, and the difference is not cosmetic: a server
 * pointed at `/Users/me/My Folder` is two arguments in the configuration, and
 * joined with a space it reads back as two different ones — so the row would
 * print a command nobody configured and the edit form would start from it.
 * `quoteArgv` is the tokenizer's inverse and is round-tripped by a test in
 * `mcp-add.test.ts`. This mirrors `configuredForStore` in `mcp-client.ts`,
 * which is private to that file.
 */
function commandLineOf(server: McpServerConfig): string {
  return server.transport === 'stdio'
    ? quoteArgv([server.command ?? '', ...server.args].filter((part) => part !== ''))
    : (server.url ?? '')
}

/**
 * The line under a server's name.
 *
 * A row that cannot work shows **why** instead of what it runs, because the
 * command is one tap away in Edit and the reason is nowhere else at all. A
 * failed connection's error wins over a configuration one because it is the
 * newer fact.
 *
 * `unsupported` is deliberately not in this chain. It is set on every HTTP and
 * SSE server — *"Claude Code dials HTTP servers itself, so this panel cannot
 * inspect it"* — and it describes this app's inspector rather than the server,
 * so putting it here would replace the URL of every working remote server with
 * a sentence about us. It decides whether Connect is offered instead.
 */
function detailOf(server: McpServerConfig, live: { error: string | null } | null): string {
  return live?.error ?? server.disabledReason ?? commandLineOf(server)
}

/**
 * The traffic light.
 *
 * Connected, configured-but-not-connected, failed — in that order, from the
 * pool. A host holding no pool has no opinion about what is running, and an
 * amber light meaning *not connected* on a machine where nothing can connect
 * would report the absence of a feature as a fault; there, only the
 * configuration's own verdict is drawn, which is `enabled: false` — a shared
 * `.mcp.json` server nobody has approved yet, or one rejected outright.
 */
function statusOf(server: McpServerConfig, live: { state: string } | null, pooled: boolean): string | undefined {
  if (live?.state === 'ready') return 'ok'
  if (live?.state === 'failed') return 'bad'
  if (!server.enabled) return 'warn'
  return pooled ? 'warn' : undefined
}

/**
 * One form, used by both Add and Edit.
 *
 * *"Editing is the same form prefilled from the row"* — so it is the same
 * builder, and Edit differs only in what it is handed. Both boxes are offered
 * in both cases: on Add because the host cannot know which of the two the
 * person means, and on Edit because pointing a stdio server at a URL is a
 * change somebody is entitled to make from the same screen they made it on.
 */
function formFields(draft: {
  name: string
  command: string
  url: string
  scope: McpAddScope
  envKeys: readonly string[]
  stdio: boolean
  projectPath: string | null
}): PanelField[] {
  const fields: PanelField[] = [
    { id: 'name', label: 'Name', value: draft.name, placeholder: 'filesystem', required: true },
    {
      id: 'command',
      label: 'Command',
      value: draft.command,
      placeholder: 'npx -y @modelcontextprotocol/server-filesystem ~/Documents',
    },
    {
      id: 'url',
      label: 'URL',
      value: draft.url,
      placeholder: 'https://example.com/mcp — fill this in instead of the command',
    },
    {
      // The three words live in the label because `PanelField` has no choice
      // list and a prefilled box never shows its placeholder. They are three
      // different files with three different lifetimes, which is why the
      // desktop spends a hover note on them: `user` is every project,
      // `local` is this folder and is not committed, `project` writes
      // `.mcp.json` beside the code and comes back needing an approval.
      id: 'scope',
      /*
       * **A picker now, not a spelling test.**
       *
       * This was a text box with the three legal words written into its label,
       * because `PanelField` had no way to say *one of these*. It has `choices`
       * since 2026-08-25, so the label goes back to naming the field and the
       * legal answers are the control itself — which also means a typo is no
       * longer a refusal a person has to decipher.
       *
       * Without a project in view there is exactly one legal scope, and a
       * picker with one position is a label: it is still sent as `choices` so
       * the phone draws it as a settled value rather than an empty box.
       */
      label: 'Save it for',
      value: draft.scope,
      choices: draft.projectPath === null ? ['user'] : ['user', 'project', 'local'],
      required: true,
    },
  ]

  for (const key of draft.envKeys.slice(0, MAX_ENV_FIELDS)) {
    fields.push({
      id: `env.${fields.length}`,
      label: key,
      value: `${key}=`,
      placeholder: 'Leave this to keep the saved value, or clear the box to drop it',
    })
  }
  fields.push({
    id: `env.${fields.length}`,
    label: draft.stdio ? 'Environment variable' : 'Header',
    placeholder: draft.stdio
      ? 'API_KEY=…'
      : 'Authorization: Bearer … — headers are not read back, so saving replaces them',
  })
  return fields
}

function addAction(scope: McpAddScope, projectPath: string | null): PanelAction {
  return {
    id: ADD,
    label: 'Add a server',
    fields: formFields({ name: '', command: '', url: '', scope, envKeys: [], stdio: true, projectPath }),
  }
}

function rowActions(
  server: McpServerConfig,
  live: { state: string } | null,
  pool: McpPanelPool | undefined,
  projectPath: string | null,
): PanelAction[] {
  const actions: PanelAction[] = []

  if (pool && server.unsupported === null) {
    const held = live?.state === 'ready' || live?.state === 'connecting'
    actions.push(
      held
        ? { id: DISCONNECT, label: 'Disconnect' }
        : { id: CONNECT, label: 'Connect' },
    )
  }

  const stdio = server.transport === 'stdio'
  actions.push({
    id: EDIT,
    label: 'Edit',
    fields: formFields({
      name: server.name,
      command: stdio ? commandLineOf(server) : '',
      url: stdio ? '' : (server.url ?? ''),
      scope: server.scope,
      // Keys only, sorted. The values stay in this process — see the header.
      // A non-stdio server has none to show: headers are not read back.
      envKeys: stdio ? Object.keys(server.env).sort() : [],
      stdio,
      projectPath,
    }),
  })

  actions.push({
    id: REMOVE,
    label: 'Remove',
    kind: 'destructive',
    confirm:
      server.scope === 'project'
        ? `${server.name} comes out of .mcp.json, which is committed — everyone on this project loses it.`
        : `${server.name} comes out of your configuration. Anything it was carrying goes with it.`,
  })

  return actions
}

/* ----------------------------------------------------------------- panel -- */

/**
 * The panel `server.ts` serves for `mcp`.
 *
 * `deps` is three things: where the list comes from, the pool this host is
 * holding, and what the writes are handed. A desktop passes its pool; a
 * headless host passes nothing and gets everything except Connect.
 */
export function mcpPanel(deps: McpPanelDeps = {}): Panel {
  const list = (projectPath: string | null): McpServerConfig[] => (deps.list ?? loadServers)(projectPath)

  /**
   * One configured server as `editMcpServer` needs it — values included.
   *
   * The same mapping `existingForEdit` does in `mcp-client.ts`, written again
   * because that function is private to that file. It is a field mapping and
   * no parsing: the parsing is `loadServers`, once, for both of them.
   */
  const readExisting = (name: string, scope: McpAddScope, projectPath: string | null): McpExisting | null => {
    const found = list(projectPath).find((server) => server.name === name && server.scope === scope)
    if (found === undefined) return null
    const stdio = found.transport === 'stdio'
    return {
      name: found.name,
      scope: found.scope,
      transport: found.transport,
      command: stdio ? commandLineOf(found) : '',
      url: stdio ? '' : (found.url ?? ''),
      env: { ...found.env },
    }
  }

  const writes: McpEditDeps = { read: readExisting, ...deps.writes }

  /**
   * Everything this panel answers with, read fresh.
   *
   * Both `read` and `act` end here, which is the contract's rule — *"an action
   * answers with the panel"* — and it is also what makes an action's result
   * impossible to disagree with: the row a person just edited is re-read from
   * disk rather than patched in memory.
   */
  const payload = (request: PanelRequest, notice?: string): PanelPayload => {
    const path = request.path
    const projectPath = isAbsolute(path) ? path : null
    const said = notice === undefined ? {} : { notice }

    let all: McpServerConfig[]
    try {
      all = list(projectPath)
    } catch (cause) {
      /*
       * A read that fails is still a screen, and it still offers the one thing
       * somebody came here to do — Add goes through the CLI and does not depend
       * on this read having worked. The alternative is the sentence this whole
       * rewrite exists to delete: "This machine could not answer that panel."
       */
      return {
        path,
        note: `The MCP configuration for ${path} could not be read. ${messageOf(cause)}`,
        ...said,
        actions: [addAction('user', projectPath)],
        rows: [],
      }
    }

    const scope = SCOPES.find((one) => one === request.scope)
    const query = (request.query ?? '').trim().toLowerCase()
    const shown = all.filter((server) => {
      if (scope && server.scope !== scope) return false
      if (query === '') return true
      return server.name.toLowerCase().includes(query) || commandLineOf(server).toLowerCase().includes(query)
    })

    const rows: PanelRow[] = shown.map((server) => {
      const live = deps.pool?.getStatus(server.id) ?? null
      return {
        title: server.name,
        detail: detailOf(server, live),
        value: `${server.scope} · ${server.transport}`,
        status: statusOf(server, live, deps.pool !== undefined),
        id: server.id,
        actions: rowActions(server, live, deps.pool, projectPath),
      }
    })

    let note: string | undefined
    if (all.length === 0) note = `No MCP servers are configured for ${path}.`
    else if (rows.length === 0) {
      note =
        query === ''
          ? `Nothing here is saved at ${scope} scope.`
          : `No configured server matches “${request.query}”.`
    }

    /*
     * The chips are the scope axis, worded as the row's own value word rather
     * than as the desktop's "All projects" / "This project only". Those answer
     * *where does this get saved*, which is a form's question; a filter asks
     * *which bucket is this*, and a chip that does not read like the word on
     * the row it filters to is a chip somebody has to translate. Offered only
     * once there is something to filter.
     */
    const scopes: PanelScope[] | undefined =
      all.length === 0
        ? undefined
        : [
            { id: 'all', label: 'All', on: scope === undefined },
            ...SCOPES.map((one) => ({ id: one, label: one, on: scope === one })),
          ]

    return {
      path,
      ...(note === undefined ? {} : { note }),
      ...said,
      ...(scopes === undefined ? {} : { scopes }),
      /*
       * The form opens on the scope being looked at, which saves a decision in
       * the common case — except with no project in view, where `local` and
       * `project` are addressed by a working directory that is not there and
       * `resolveRequest` refuses both. Prefilling one of them there would set
       * somebody up to fail on Save.
       */
      actions: [addAction(projectPath === null ? 'user' : (scope ?? 'user'), projectPath)],
      rows,
    }
  }

  /** What a form's `env.n` boxes came back as, in the order they were drawn. */
  const extrasFrom = (fields: Record<string, string>): string[] =>
    Object.keys(fields)
      .map((key) => ENV_FIELD.exec(key))
      .filter((match): match is RegExpExecArray => match !== null)
      .sort((a, b) => Number(a[1]) - Number(b[1]))
      .map((match) => fields[match[0]].trim())
      .filter((line) => line !== '')

  const perform = async (request: PanelActionRequest, projectPath: string | null): Promise<string> => {
    const fields = request.fields ?? {}
    const name = (fields.name ?? '').trim()
    const command = (fields.command ?? '').trim()
    const url = (fields.url ?? '').trim()
    const scope = (fields.scope ?? '').trim()

    if (request.action === ADD) {
      // Refused here rather than by `resolveRequest`, which would answer an
      // empty form with "Give the command that starts the server" and say
      // nothing about the URL box sitting beside it.
      if (command === '' && url === '') return 'Give the command that starts the server, or its URL.'
      const added = await addMcpServer(
        {
          name,
          scope,
          // Read off the shape, exactly as `parseServerEntry` reads it out of
          // a configuration file somebody else wrote. See the header for the
          // one transport this cannot express.
          transport: command === '' ? 'http' : 'stdio',
          command,
          url,
          extras: extrasFrom(fields),
          projectPath,
        },
        writes,
      )
      return added.message
    }

    /*
     * A row action is re-resolved against the configuration as it is now, not
     * against the list the phone was drawing. A server removed from the desktop
     * while somebody held this screen open is then a sentence rather than a
     * write aimed at a name that is gone.
     */
    const server = list(projectPath).find((one) => one.id === request.id)
    if (server === undefined) return 'That server is not in this configuration any more.'

    switch (request.action) {
      case EDIT: {
        if (command === '' && url === '') return 'Give the command that starts the server, or its URL.'
        const stdio = command !== ''
        const changed = await editMcpServer(
          {
            name: server.name,
            scope: server.scope,
            next: {
              name,
              scope,
              // An SSE server keeps its transport through an edit; only the
              // switch between a command and a URL changes it.
              transport: stdio ? 'stdio' : nonStdioTransport(server.transport),
              command,
              url,
              extras: extrasFrom(fields),
              projectPath,
            },
          },
          writes,
        )
        return changed.message
      }
      case REMOVE:
        return (await removeMcpServer({ name: server.name, scope: server.scope, projectPath }, writes)).message
      case CONNECT: {
        const pool = deps.pool
        if (pool === undefined) return 'This machine is not holding MCP connections, so there is nothing to connect.'
        const live = await pool.connect(server)
        if (live.state === 'ready') return `${server.name} is connected.`
        return `${server.name} did not connect. ${live.error ?? 'It gave no reason.'}`
      }
      case DISCONNECT: {
        const pool = deps.pool
        if (pool === undefined) return 'This machine is not holding MCP connections, so there is nothing to disconnect.'
        await pool.disconnect(server.id)
        return `${server.name} is disconnected.`
      }
      default:
        return 'That is not something this panel offers.'
    }
  }

  return {
    async read(request: PanelRequest): Promise<PanelPayload> {
      return payload(request)
    },

    async act(request: PanelActionRequest): Promise<PanelPayload> {
      const projectPath = isAbsolute(request.path) ? request.path : null
      let notice: string
      try {
        notice = await perform(request, projectPath)
      } catch (cause) {
        // The three writes already answer with a sentence rather than throwing,
        // so reaching here means a dependency did — a pool whose connect
        // rejected, a `list` that could not read. It is still a redraw with a
        // line on it, because a panel that threw is a phone with nothing on it.
        notice = messageOf(cause)
      }
      /*
       * **The filter is dropped on purpose**, and that is now a choice rather
       * than a limit.
       *
       * `panel.act` carried no `scope` when this was written, so an unfiltered
       * redraw was the only answer available. The frame carries both `scope` and
       * `query` since — the readiness panel needs them, because a fix applied
       * under one agent's scope must answer under that same scope — and this
       * panel still ignores them, which is the right answer here for a reason
       * the other panel does not share: **the server somebody has just added is
       * very often not in the scope they were looking at.** Adding a `user`
       * server while filtered to `project` and being shown an unchanged list is
       * a write that looks like it failed.
       *
       * `payload` reads `request.path` and nothing else, so the drop is in the
       * call rather than in a branch.
       */
      return payload(request, notice)
    },
  }
}

/** `sse` survives an edit; anything else that is not a command becomes HTTP. */
function nonStdioTransport(transport: McpServerConfig['transport']): McpAddTransport {
  return transport === 'sse' ? 'sse' : 'http'
}
