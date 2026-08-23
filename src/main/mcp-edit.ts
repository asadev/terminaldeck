import {
  addMcpServer,
  removeMcpServer,
  resolveRequest,
  type McpAddDeps,
  type McpAddRequest,
  type McpAddResult,
  type McpAddScope,
  type McpAddTransport,
} from './mcp-add'

/**
 * Changing a server you added, without retyping the parts you cannot see.
 *
 * ## Why this is not "remove it and add it again"
 *
 * That is what the panel could already be *used* to do, and it is why editing
 * needed writing: a person who added a server with an API key in it and then
 * wants to point it at a different directory would have had to delete the server
 * — taking the key with it — and type the key in again from wherever they keep
 * it. Half of them do not have it any more. So the escape hatch that exists is
 * one people are right to be afraid of, and a store whose custom half can only
 * be added and deleted is one where nobody changes anything.
 *
 * ## Where the secret is, and where it is not
 *
 * It is in the configuration, and it stays there. The renderer is sent the
 * *names* of a server's environment variables and never the values —
 * `configuredForStore` has always been deliberately lossy about that, and this
 * module is what makes that affordable: the merge happens **here**, in the
 * process that can already read the file, so a field left blank keeps whatever
 * is saved without the value ever crossing the bridge.
 *
 * The rule the form and this module share, exactly:
 *
 *  - `KEY=value` — that is the new value.
 *  - `KEY=` — keep whatever is saved. Refused if nothing is, because a variable
 *    with no value is not a variable, and writing an empty one would look like
 *    it had worked.
 *  - a key that is **not** in the box — dropped. Deleting the line is how you
 *    delete the variable, which is the only gesture that reads as deleting it.
 *
 * ## Two writes, and what happens when the second one fails
 *
 * The CLI that owns the file has `add` and `remove` and nothing that replaces,
 * so an edit is a remove followed by an add. That is a window in which the
 * server does not exist, and the failure that matters is the add failing after
 * the remove succeeded — which would delete somebody's server on their way to
 * changing it.
 *
 * So the new request is built and validated **before** anything is removed, and
 * if the add still fails the original is written back and the message says all
 * three things: what was being attempted, why it did not, and that the server
 * that was there is back. A rollback nobody is told about is indistinguishable
 * from the data loss it prevented.
 */

/* ----------------------------------------------------------------- types -- */

/** One server as it is configured right now, read by whoever owns the reader. */
export interface McpExisting {
  name: string
  scope: McpAddScope
  transport: McpAddTransport
  /** stdio: the command line, quoted so it reads back as what is in the file. */
  command: string
  /** http/sse. */
  url: string
  /** Every environment variable it carries, values included. Never leaves here. */
  env: Record<string, string>
}

export interface McpEditDeps extends McpAddDeps {
  /** The configuration, read. Injected so this module never opens a file. */
  read?(name: string, scope: McpAddScope, projectPath: string | null): McpExisting | null
  /** The two writes, injectable together so a test can watch the order. */
  add?(request: unknown): Promise<McpAddResult>
  remove?(request: unknown): Promise<McpAddResult>
}

/** Which server is being changed, and into what. */
export interface McpEditRequest {
  /** The server as it is now — its name and scope address it. */
  name: string
  scope: McpAddScope
  projectPath: string | null
  /** What it becomes. Validated by `resolveRequest`, like any other add. */
  next: McpAddRequest
}

/* ------------------------------------------------------------ the merge -- */

/** A `KEY=value` line, split at the first `=` only — values contain them. */
function splitPair(entry: string): { key: string; value: string } {
  const at = entry.indexOf('=')
  return at === -1
    ? { key: entry.trim(), value: '' }
    : { key: entry.slice(0, at).trim(), value: entry.slice(at + 1) }
}

/**
 * The environment the edited server gets, as `KEY=value` lines.
 *
 * Pure and exported because this is the whole of the "keep what is saved"
 * promise, and a promise about somebody's API key is not a thing to leave
 * implicit in a function that also spawns two processes.
 *
 * Throws — rather than dropping the line or writing an empty value — for a
 * `KEY=` whose key has nothing saved. Both silent outcomes end with a person
 * looking at a server that was written successfully and does not work.
 */
export function mergeEnvironment(
  typed: readonly string[],
  saved: Readonly<Record<string, string>>,
): string[] {
  const out: string[] = []
  for (const entry of typed) {
    const { key, value } = splitPair(entry)
    if (key === '') continue
    if (value !== '') {
      out.push(`${key}=${value}`)
      continue
    }
    const kept = saved[key]
    if (kept === undefined || kept === '') {
      throw new Error(
        `${key} has no saved value to keep. Give it one, or delete the line to drop the variable.`,
      )
    }
    out.push(`${key}=${kept}`)
  }
  return out
}

/* ------------------------------------------------------------ resolving -- */

/**
 * What crossed the bridge, as an edit, or why it is not one.
 *
 * The `next` half goes through `resolveRequest` unchanged — same name rules,
 * same scope rules, same refusal to write a project-scoped server with no
 * project open — because an edit that could produce a server an add would have
 * refused is a second, laxer front door to the same file.
 */
export function resolveEditRequest(raw: unknown): McpEditRequest {
  if (typeof raw !== 'object' || raw === null) throw new Error('Nothing to change.')
  const input = raw as Record<string, unknown>

  const name = typeof input.name === 'string' ? input.name.trim() : ''
  if (name === '') throw new Error('Name the server to change.')
  const scope = (['user', 'project', 'local'] as const).find((one) => one === input.scope)
  if (!scope) throw new Error('Say which scope the server is in.')

  const next = resolveRequest(input.next)
  const projectPath = next.projectPath
  // The server being edited is addressed by the *same* working directory the new
  // one will be written with, so a `local` original with no project open is as
  // unwritable as a `local` target would be. `resolveRequest` already refused
  // the second; this refuses the first, and for the same reason — the remove
  // would be aimed at this app's own cwd and would report success having
  // removed nothing, leaving two servers where there was one.
  if (scope !== 'user' && projectPath === null) {
    throw new Error('Open the project this server belongs to first.')
  }
  return { name, scope, projectPath, next }
}

/* -------------------------------------------------------------- the edit -- */

/** The add request that puts the original back, byte for byte. */
function restoreOf(existing: McpExisting, projectPath: string | null): McpAddRequest {
  return {
    name: existing.name,
    scope: existing.scope,
    transport: existing.transport,
    command: existing.transport === 'stdio' ? existing.command : '',
    url: existing.transport === 'stdio' ? '' : existing.url,
    extras: Object.entries(existing.env).map(([key, value]) => `${key}=${value}`),
    projectPath,
  }
}

/**
 * Change one server, and say what happened in a sentence.
 *
 * Never throws for an ordinary failure, exactly as {@link addMcpServer} does not:
 * a missing CLI, a name that is now taken, a `KEY=` with nothing behind it are
 * all things the row has to *show*.
 */
export async function editMcpServer(raw: unknown, deps: McpEditDeps = {}): Promise<McpAddResult> {
  let request: McpEditRequest
  try {
    request = resolveEditRequest(raw)
  } catch (cause) {
    return { ok: false, message: cause instanceof Error ? cause.message : String(cause) }
  }

  const read = deps.read
  if (read === undefined) return { ok: false, message: 'This build cannot read your configuration.' }
  const existing = read(request.name, request.scope, request.projectPath)
  if (existing === null) {
    return {
      ok: false,
      message: `${request.name} is not in your configuration any more. Nothing was changed.`,
    }
  }

  /*
   * Built and validated before a single write. An edit whose new command has an
   * unclosed quote must fail here, with the old server still in the file — not
   * after the remove, with nothing in it.
   */
  let extras: string[]
  try {
    extras =
      request.next.transport === 'stdio'
        ? mergeEnvironment(request.next.extras, existing.env)
        : [...request.next.extras]
  } catch (cause) {
    return { ok: false, message: cause instanceof Error ? cause.message : String(cause) }
  }
  const target: McpAddRequest = { ...request.next, extras }

  const add = deps.add ?? ((payload: unknown) => addMcpServer(payload, deps))
  const remove = deps.remove ?? ((payload: unknown) => removeMcpServer(payload, deps))

  const gone = await remove({
    name: request.name,
    scope: request.scope,
    projectPath: request.projectPath,
  })
  if (!gone.ok) return { ok: false, message: `${request.name} was not changed. ${gone.message}` }

  const written = await add(target)
  if (written.ok) {
    const renamed =
      target.name === request.name ? '' : ` It was called ${request.name} and is now ${target.name}.`
    const moved =
      target.scope === request.scope ? '' : ` It moved from ${request.scope} to ${target.scope}.`
    return { ok: true, message: `${target.name} was changed.${renamed}${moved}` }
  }

  /*
   * The one failure worth all of this. The server is gone and the replacement
   * did not land, so the original goes back — and every outcome of *that* is
   * reported too, because the difference between "your server is back" and
   * "your server is gone" is the only thing the person now needs to know.
   */
  const back = await add(restoreOf(existing, request.projectPath))
  return {
    ok: false,
    message: back.ok
      ? `${target.name} was not saved. ${written.message} ${request.name} has been put back exactly as it was.`
      : `${target.name} was not saved. ${written.message} Putting ${request.name} back also failed — ${back.message} — so it is not in your configuration right now.`,
  }
}
