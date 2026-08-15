import { execFile } from 'node:child_process'
import { homedir } from 'node:os'
import { isAbsolute, normalize } from 'node:path'
import { promisify } from 'node:util'
import { currentPlatform, withPath } from './platform/host'
import { loginPath, PROVIDERS } from './providers'

const run = promisify(execFile)

/**
 * Adding an MCP server, by asking the tool that owns the file to add it.
 *
 * ## Why this does not write the config itself
 *
 * The panel next door reads `~/.claude.json`, and the obvious way to grow an
 * Add button is to write the same file back with one more key under
 * `mcpServers`. That was the first plan and it is a bad one, for a reason that
 * is worth writing down because it is invisible until you look at the file:
 * on this machine `~/.claude.json` is seventy kilobytes, mode 0600, and holds
 * **thirty-eight projects** worth of Claude Code's entire state — onboarding
 * flags, cached experiment data, per-project history, subscription status. It
 * is not our file. It is another application's live database that happens to be
 * JSON.
 *
 * Read-modify-write on that from a second process means owning every way it can
 * go wrong: a partial write truncating it, our formatting churning a file the
 * CLI is also writing, a schema we do not understand being dropped because we
 * round-tripped it through a type we invented, and — the one that actually
 * loses data — writing it back at the same moment the CLI does. The blast
 * radius of getting that wrong is the user's whole Claude Code install, to add
 * one server.
 *
 * So the write goes through `claude mcp add`, which is the documented,
 * non-interactive command whose entire job is this, and which already knows the
 * three scopes and their three different destinations. We keep the reading —
 * which is safe, and which `mcp-client.ts` already does well — and we delegate
 * the writing to the owner. That is also what the panel has been telling users
 * to do by hand all along; this just stops making them leave the window.
 *
 * ## The three scopes really are three different files
 *
 * This is the detail that makes a naive Add button silently wrong, so it is
 * enforced in `resolveRequest` rather than left to the caller:
 *
 *   - `user`    → `mcpServers` in `~/.claude.json`. Global. Working directory
 *                 is irrelevant.
 *   - `local`   → `projects[<cwd>].mcpServers` in `~/.claude.json`. Private to
 *                 one project, and **keyed by the CLI's working directory**.
 *   - `project` → `<cwd>/.mcp.json`. Committed alongside the code.
 *
 * Two of the three are decided by where the process runs, not by a flag. Run
 * the CLI from the app's own working directory — which is `/` for a packaged
 * Mac app — and a `local` server is filed under a project that does not exist,
 * where nothing will ever read it, while the command still exits 0 and prints
 * success. So a non-`user` scope without an open project is refused up front
 * instead of being written somewhere harmless-looking.
 */

/* ----------------------------------------------------------------- types -- */

export type McpAddScope = 'user' | 'project' | 'local'
export type McpAddTransport = 'stdio' | 'http' | 'sse'

export interface McpAddRequest {
  name: string
  scope: McpAddScope
  transport: McpAddTransport
  /** stdio only: the command line as typed, e.g. `npx -y @scope/server`. */
  command: string
  /** http/sse only. */
  url: string
  /**
   * Extra `KEY=value` pairs for stdio, or `Name: value` headers for http/sse.
   * One per entry; the caller splits the textarea, not us.
   */
  extras: string[]
  /** Absolute path of the open project, or null when none is open. */
  projectPath: string | null
}

export interface McpAddResult {
  ok: boolean
  /** Shown to the user either way — a success is as worth confirming as a failure. */
  message: string
}

/* ------------------------------------------------------------ validation -- */

const SCOPES: readonly McpAddScope[] = ['user', 'project', 'local']
const TRANSPORTS: readonly McpAddTransport[] = ['stdio', 'http', 'sse']

/**
 * What a server may be called.
 *
 * Deliberately stricter than whatever the CLI would tolerate, and the leading
 * character is the reason rather than tidiness: a name beginning with `-` is
 * read by the CLI's own argument parser as a flag, so `--scope` typed into the
 * name box would not produce a badly-named server, it would rewrite the scope
 * of the command we are building. Nothing here goes through a shell, so this is
 * not about quoting; it is about a positional argument that can impersonate an
 * option.
 */
const NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

/**
 * Turn whatever crossed the bridge into a request, or say why it is not one.
 *
 * Everything the renderer sends is `unknown` on this side and is treated that
 * way. The messages are written for the person who typed the form, not for a
 * log: this is the text the panel prints under the fields.
 */
export function resolveRequest(raw: unknown): McpAddRequest {
  if (typeof raw !== 'object' || raw === null) throw new Error('Nothing to add.')
  const input = raw as Record<string, unknown>

  const name = text(input.name)
  if (name === '') throw new Error('Give the server a name.')
  if (!NAME_PATTERN.test(name)) {
    throw new Error('A name may use letters, numbers, dots, dashes and underscores, and must start with a letter or number.')
  }

  const scope = SCOPES.find((candidate) => candidate === input.scope)
  if (!scope) throw new Error('Choose where to save the server.')

  const transport = TRANSPORTS.find((candidate) => candidate === input.transport)
  if (!transport) throw new Error('Choose how the server is reached.')

  const command = text(input.command)
  const url = text(input.url)
  if (transport === 'stdio' && command === '') throw new Error('Give the command that starts the server.')
  if (transport !== 'stdio' && url === '') throw new Error('Give the server’s URL.')

  const extras = Array.isArray(input.extras)
    ? input.extras.map((entry) => text(entry)).filter((entry) => entry !== '')
    : []
  for (const entry of extras) {
    // A header is `Name: value` and an environment variable is `KEY=value`;
    // checking the separator here means a value pasted into the wrong box is
    // caught by the form rather than accepted and then quietly ignored by the
    // server it was meant for.
    if (transport === 'stdio' && !entry.includes('=')) {
      throw new Error(`Environment variables are written KEY=value — “${entry}” is not.`)
    }
    if (transport !== 'stdio' && !entry.includes(':')) {
      throw new Error(`Headers are written Name: value — “${entry}” is not.`)
    }
  }

  /*
   * `normalize`, not `resolve`, and the difference is only visible on Windows.
   *
   * The value has already passed `isAbsolute`, so there is no relative path left
   * to resolve — the two functions agree on everything except one thing:
   * `resolve` resolves against the *current working directory*, which on Windows
   * means it attaches the drive of wherever this process happens to be. A
   * caller's `/work/app` came back as `D:\work\app`, and the Windows CI release
   * build failed on it.
   *
   * Both collapse `.` and `..`, which is the only reason this call exists.
   */
  const projectPath =
    typeof input.projectPath === 'string' && input.projectPath !== '' && isAbsolute(input.projectPath)
      ? normalize(input.projectPath)
      : null

  // See the header: these two scopes are addressed by working directory, so
  // without a project there is nowhere correct to put them. Refusing beats
  // writing a server into a folder nothing will ever look in.
  if (scope !== 'user' && !projectPath) {
    throw new Error('Open a project first — only a user-scope server can be added without one.')
  }

  return { name, scope, transport, command, url, extras, projectPath }
}

/* ------------------------------------------------------------ tokenising -- */

/**
 * Split a typed command line into an argument vector.
 *
 * This exists because the command reaches us as one string — `npx -y
 * @modelcontextprotocol/server-filesystem "/Users/me/My Folder"` is what people
 * paste out of a README — and it has to reach `execFile` as a list. The naive
 * `line.split(' ')` breaks the moment a path contains a space, which on macOS
 * is most of them.
 *
 * Quoting follows the shell rules people already have in their fingers, because
 * they are pasting text written for a shell: single quotes are literal
 * throughout, double quotes allow `\"` and `\\`, and a backslash outside quotes
 * escapes the next character. Note that no shell is involved anywhere in this
 * module — the tokens go straight into `execFile`'s argv — so this parsing is a
 * convenience for the user, never a place where a `;` or a backtick could
 * acquire meaning.
 *
 * An unterminated quote throws rather than guessing, because both guesses are
 * bad: dropping the quote silently runs a command the user did not write, and
 * keeping it runs one with a stray `"` in an argument.
 */
export function tokenizeCommand(line: string): string[] {
  const out: string[] = []
  let current = ''
  // Tracked separately from `current.length` so an explicitly empty argument —
  // `--flag ""` — survives instead of being dropped as whitespace.
  let started = false
  let quote: '"' | "'" | null = null

  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i]

    if (quote === "'") {
      if (ch === "'") quote = null
      else current += ch
      continue
    }

    if (quote === '"') {
      if (ch === '\\' && (line[i + 1] === '"' || line[i + 1] === '\\')) {
        current += line[i + 1]
        i += 1
        continue
      }
      if (ch === '"') quote = null
      else current += ch
      continue
    }

    if (ch === '"' || ch === "'") {
      quote = ch
      started = true
      continue
    }
    if (ch === '\\' && i + 1 < line.length) {
      current += line[i + 1]
      i += 1
      started = true
      continue
    }
    if (/\s/.test(ch)) {
      if (started) {
        out.push(current)
        current = ''
        started = false
      }
      continue
    }
    current += ch
    started = true
  }

  if (quote) throw new Error('That command has an unclosed quote.')
  if (started) out.push(current)
  return out
}

/* -------------------------------------------------------- the command -- */

/**
 * The argument list for `claude`, ready for `execFile`.
 *
 * Pure and exported so the shape of the command is pinned by a test. Getting
 * this wrong is not a crash — it is a server written into the wrong scope, or a
 * positional argument eaten by a flag, which surfaces much later as "the server
 * I added isn't there".
 *
 * ## The ordering rule, and the one that looked right and was not
 *
 * The obvious arrangement is every option first and the positionals last, the
 * way `[options] <name> <commandOrUrl>` in the usage line reads. That was the
 * first version, and running it against the real CLI produced:
 *
 *     Invalid environment variable format: files,
 *     environment variables should be added as: -e KEY1=value1
 *
 * `-e, --env <env...>` and `-H, --header <header...>` are **variadic**, so the
 * parser keeps eating arguments until something stops it — and what it ate was
 * the server's name. This is why the CLI's own examples put `-e` *after* the
 * name rather than with the other options; it is not a style choice. So:
 *
 *  - **Non-variadic options first.** `--scope` and `--transport` take exactly
 *    one value and cannot swallow anything.
 *  - **Then the name**, before any variadic flag can reach it.
 *  - **stdio: `--` before the command.** Without it an MCP server started as
 *    `npx -y …` loses its `-y` to the CLI's own parser, and `--` is also what
 *    terminates the variadic `-e` list.
 *  - **http/sse: the URL immediately after the name**, then `-H`. There is no
 *    `--` on this path, so a header list placed earlier would swallow the URL
 *    exactly as `-e` swallowed the name.
 *
 * Both forms were run against the real `claude` against a throwaway
 * `CLAUDE_CONFIG_DIR` and the resulting `mcpServers` block was read back, so
 * this is measured rather than inferred from `--help`.
 */
export function buildAddArgs(request: McpAddRequest): string[] {
  const args = ['mcp', 'add', '--scope', request.scope]
  if (request.transport !== 'stdio') args.push('--transport', request.transport)
  args.push(request.name)

  if (request.transport === 'stdio') {
    const argv = tokenizeCommand(request.command)
    if (argv.length === 0) throw new Error('Give the command that starts the server.')
    for (const entry of request.extras) args.push('-e', entry)
    args.push('--', ...argv)
  } else {
    args.push(request.url)
    for (const entry of request.extras) args.push('-H', entry)
  }
  return args
}

/** Injectable so the test can run a stub instead of the real CLI. */
export interface McpAddDeps {
  exec?(file: string, args: string[], options: { cwd: string; env: NodeJS.ProcessEnv; timeout: number }): Promise<{ stdout: string; stderr: string }>
  path?(): Promise<string>
}

/** Writing config is quick; anything this slow is a CLI that has gone wrong. */
const ADD_TIMEOUT_MS = 30_000

/**
 * Pull something readable out of whatever `execFile` rejected with.
 *
 * `execFile` attaches the child's output to the *error object* rather than
 * throwing it — and on a timeout it kills the child and does the same — so
 * reading only `err.message` turns a CLI that explained itself perfectly well
 * into a bare "Command failed". This repository has been bitten by that exact
 * shape before, in the release scripts, where a Tailscale prompt became a
 * fifteen-second hang with no output.
 */
function outputOf(cause: unknown): string {
  if (typeof cause !== 'object' || cause === null) return ''
  const err = cause as { stderr?: unknown; stdout?: unknown }
  const parts = [err.stderr, err.stdout]
    .map((part) => (typeof part === 'string' ? part.trim() : ''))
    .filter((part) => part !== '')
  return parts.join('\n')
}

function isMissingBinary(cause: unknown): boolean {
  if (typeof cause !== 'object' || cause === null) return false
  return (cause as NodeJS.ErrnoException).code === 'ENOENT'
}

/**
 * Add the server, and report what happened in a sentence.
 *
 * Never throws for an ordinary failure: a missing CLI, a duplicate name and a
 * malformed command are all things the panel has to *show*, and an Add button
 * whose failure mode is an unhandled rejection is the silent-drop bug this
 * codebase keeps having to fix in other places.
 */
export async function addMcpServer(raw: unknown, deps: McpAddDeps = {}): Promise<McpAddResult> {
  let request: McpAddRequest
  let args: string[]
  try {
    request = resolveRequest(raw)
    args = buildAddArgs(request)
  } catch (cause) {
    return { ok: false, message: cause instanceof Error ? cause.message : String(cause) }
  }

  const exec =
    deps.exec ??
    ((file, argv, options) => run(file, argv, options).then(({ stdout, stderr }) => ({
      stdout: String(stdout),
      stderr: String(stderr),
    })))

  // The same login-shell PATH every spawned CLI gets. A GUI Electron app
  // inherits a minimal PATH, so `claude` installed by nvm, Homebrew or into
  // ~/.local/bin — which is where it is on this machine — is simply not on it,
  // and the Add button would report "not installed" to someone who has it.
  const path = await (deps.path ?? loginPath)()

  // `spawn` rather than `bin`, because on Windows an npm-installed `claude` is
  // a `.cmd` shim and `execFile` cannot run one. `PROVIDERS` already carries
  // the `cmd.exe /c` wrapper for that case and is pinned by its own test, so
  // reusing it here keeps one answer to that question instead of two. Untested
  // on Windows, like the rest of that table — nothing in this repository runs
  // there — but wrong in the same direction as everything else rather than in a
  // new one.
  const launcher = PROVIDERS.claude.spawn

  try {
    const { stdout, stderr } = await exec(launcher.command, [...launcher.args, ...args], {
      // `user` scope ignores this; the other two are addressed by it. See the
      // header — this line is the whole reason `resolveRequest` refuses a
      // non-user scope without a project.
      cwd: request.projectPath ?? homedir(),
      // Never `{ ...process.env, PATH: path }`. Windows spells the variable
      // `Path`, an object literal is case-sensitive, and spreading then writing
      // `PATH` hands the child two spellings of one variable with no rule about
      // which it reads — so the login PATH computed just above would be the one
      // ignored, on the only platform where we cannot check. `withPath` drops
      // whichever spelling is already there and writes the one this platform
      // uses. This exact line has been written eleven times in this codebase
      // and `platform/env-path.test.ts` now fails the build on it.
      env: withPath(process.env, path, currentPlatform()),
      timeout: ADD_TIMEOUT_MS,
    })
    const said = [stdout, stderr].map((part) => part.trim()).filter((part) => part !== '').join('\n')
    return {
      ok: true,
      message: said === '' ? `Added ${request.name}.` : said,
    }
  } catch (cause) {
    if (isMissingBinary(cause)) {
      return {
        ok: false,
        message:
          'Claude Code’s command line tool could not be found, and it is what writes this configuration. Install it, then try again.',
      }
    }
    const said = outputOf(cause)
    return {
      ok: false,
      message: said === '' ? (cause instanceof Error ? cause.message : String(cause)) : said,
    }
  }
}
