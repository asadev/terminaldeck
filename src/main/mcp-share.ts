import type { McpAddTransport } from './mcp-add'
import type { ConfiguredServer } from './mcp-store'

/**
 * Handing a server you added to somebody else, as a file they can read.
 *
 * ## The decision, and why it went this way for MCP and not for extensions
 *
 * The lane asked whether a person should be able to *share* what they added, and
 * the answer is different for the two halves of this store, because the two
 * halves are different kinds of thing.
 *
 * An MCP server is a **definition**: a name, a transport, one command line, and
 * a list of variable names. It is about forty bytes of decision and the thing it
 * runs is fetched from a public registry by `npx` or `uvx` or `docker` on the
 * other person's machine. That travels. It is exactly what people already paste
 * into each other's chat windows as a fenced block out of a README, and a file
 * is that paste with the mistakes taken out.
 *
 * A browser extension is **not** a definition. What was added is a folder of
 * somebody's program, or a `.crx`, and the only thing this app knows about it is
 * an absolute path on *this* machine — `/Users/asad/code/thing/dist`. Exported,
 * that names a directory the recipient does not have, and importing it would
 * either fail or, worse, find some unrelated folder at the same path and load
 * it. The honest way to share an extension is to send the `.crx` or the zip,
 * which is a thing the person already has and this app has nothing to add to. So
 * that half deliberately has no export, and this comment is the reason.
 *
 * ## What is in the file, and what is deliberately not
 *
 * Plain JSON, two spaces, one line per fact, opened in any editor. No archive,
 * no base64, nothing this app has to be running to read.
 *
 * **No values.** `env` is a list of *names*, and the file says so in a field
 * written for the human who opens it rather than for this parser. A tool
 * definition that carried somebody's `GITHUB_PERSONAL_ACCESS_TOKEN` would be a
 * credential in a file people forward, attach and commit — the one thing that
 * makes sharing a config file a bad idea in the first place. This app cannot put
 * one there because it is never given one: `configuredForStore` sends names.
 *
 * Importing therefore never completes silently. It fills in the add form, the
 * variables it named are sitting there empty, and the person presses the button.
 * That is the same shape as installing a catalogue row that needs a token, which
 * is the point — an imported server is not more trusted than a catalogue one.
 */

/* ----------------------------------------------------------------- shape -- */

/** What one exported tool definition holds. */
export interface McpToolFile {
  /** The format, so a future one can be recognised rather than guessed at. */
  terminalDeckTool: 1
  kind: 'mcp-server'
  name: string
  transport: McpAddTransport
  /** stdio only, as it would be typed. `''` otherwise. */
  command: string
  /** http/sse only. `''` otherwise. */
  url: string
  /** Variable **names**. Never values — see this file's header. */
  env: string[]
  /** Written for the person who opens the file in an editor, not for the parser. */
  note: string
}

const NOTE =
  'This is a Terminal Deck tool definition. It holds no secrets: the names under "env" are ' +
  'the variables this server needs, and their values are not in this file. Importing it opens ' +
  'the add form with these fields filled in, and nothing is written until you press the button.'

/** The filename offered in the save dialog. Safe on all three platforms. */
export function toolFileName(name: string): string {
  const safe = name.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '')
  return `${safe === '' ? 'mcp-server' : safe}.mcpserver.json`
}

/**
 * One configured server, as the text of a file.
 *
 * Takes a {@link ConfiguredServer} rather than the richer shape the edit path
 * reads, and that is the safety property rather than a convenience: the type
 * this function accepts *has no field that could hold a value*, so no future
 * edit of it can start writing one into an exported file by accident.
 */
export function toolFileText(server: ConfiguredServer): string {
  const transport = server.transport ?? 'stdio'
  const file: McpToolFile = {
    terminalDeckTool: 1,
    kind: 'mcp-server',
    name: server.name,
    transport,
    command: transport === 'stdio' ? server.commandLine : '',
    url: transport === 'stdio' ? '' : server.commandLine,
    env: [...(server.envKeys ?? [])],
    note: NOTE,
  }
  return `${JSON.stringify(file, null, 2)}\n`
}

/* ---------------------------------------------------------------- reading -- */

/** What an imported file becomes on screen: a draft, not a write. */
export interface McpToolDraft {
  name: string
  transport: McpAddTransport
  command: string
  url: string
  /** The names to draw as empty fields, so the person fills them in. */
  env: string[]
}

const TRANSPORTS: readonly McpAddTransport[] = ['stdio', 'http', 'sse']

/**
 * Read a file somebody was sent, or say why it is not one of these.
 *
 * Everything is checked rather than cast. This is a file that arrived from
 * outside — mailed, downloaded, pulled out of a repository — and the fact that
 * it is only ever turned into a *form* rather than a write is what keeps the
 * blast radius at "the form is wrong", but a parser that trusted its input would
 * put somebody else's string into a field labelled Command with the button live
 * next to it.
 *
 * The messages name the field, because the person reading them is as likely to
 * be the one who wrote the file as the one who received it.
 */
export function readToolFile(text: string): { ok: true; draft: McpToolDraft } | { ok: false; why: string } {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return { ok: false, why: 'that file is not JSON this app can read' }
  }
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, why: 'that file does not hold a tool definition' }
  }
  const record = raw as Record<string, unknown>
  if (record.kind !== 'mcp-server') {
    return { ok: false, why: 'that file is not an MCP server definition' }
  }
  const name = typeof record.name === 'string' ? record.name.trim() : ''
  if (name === '') return { ok: false, why: 'that definition has no name in it' }
  const transport = TRANSPORTS.find((one) => one === record.transport) ?? 'stdio'
  const command = typeof record.command === 'string' ? record.command.trim() : ''
  const url = typeof record.url === 'string' ? record.url.trim() : ''
  if (transport === 'stdio' && command === '') {
    return { ok: false, why: 'that definition has no command in it' }
  }
  if (transport !== 'stdio' && url === '') {
    return { ok: false, why: 'that definition has no URL in it' }
  }
  /*
   * A `KEY=value` in the file is read as the **name only**. Somebody editing an
   * exported file by hand will eventually put a value there, and the choice is
   * between carrying it into the form — where it becomes a secret that travelled
   * in a file, which is the thing this format exists not to do — and dropping
   * it, which costs one retype. It drops it.
   */
  const env = Array.isArray(record.env)
    ? record.env
        .filter((one): one is string => typeof one === 'string')
        .map((one) => one.split('=')[0]?.trim() ?? '')
        .filter((one) => one !== '')
        .slice(0, 32)
    : []
  return { ok: true, draft: { name, transport, command, url, env } }
}
