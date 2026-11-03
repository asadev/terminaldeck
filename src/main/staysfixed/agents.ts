import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { delimiter, dirname, join } from 'node:path'
import { STAYS_FIXED_SERVER } from '../../shared/stays-fixed'
import { preloadUrl, type EngineHome } from './engine'

/**
 * Giving agent sessions the Stays Fixed MCP server, per project, per launch.
 *
 * ## What the owner asked for, and the constraint that shapes it
 *
 * *"Agents get it automatically"*: a session started in a project that is set
 * up can call `staysfixed_check` right after editing, and every agent this app
 * runs gets it — Claude Code, Codex and Gemini, never only one. And the app must
 * never silently rewrite the owner's global agent configs.
 *
 * Those two are reconciled the way this app already gives sessions its own
 * browser verbs (`deck-control/session-tools.ts`): **on the session's own
 * command line**, composed at launch, written into nothing the agent owns. No
 * `~/.claude.json`, no `~/.codex/config.toml`, no `~/.gemini/settings.json`, no
 * `.mcp.json` committed into somebody's repository. Turn the switch off and the
 * next session simply starts without it; there is nothing to clean up, because
 * nothing was ever written anywhere but this app's own userData. The consent is
 * the switch on the project's Stays Fixed page — on by default once the project
 * is set up, which is itself a thing a person did on purpose.
 *
 * `mcp-add.ts` is the app's other way of adding a server, and it is deliberately
 * not used here: it writes through `claude mcp add` into Claude Code's own files,
 * which is right for a server a person chose to install for themselves and wrong
 * for one this app hands out per project — and it reaches Claude Code only.
 *
 * ## How each agent takes a per-run server, as measured
 *
 *  - **Claude Code**: `--mcp-config <file>`. The flag is variadic and repeatable
 *    (commander's `_concatValue`, read out of the 2.1.287 binary), so it adds to
 *    the browser-verbs file a session may already carry rather than replacing
 *    it, and — without `--strict-mcp-config` — to whatever the person configured.
 *  - **Codex**: `-c mcp_servers.staysfixed.<key>=<TOML>`, Codex's own override
 *    for any `config.toml` value. Checked with codex-cli 0.159.3 against a
 *    scratch `CODEX_HOME`: `codex -c … mcp list --json` lists the server with
 *    the command, the arguments and the environment exactly as given, before or
 *    after a subcommand. `session-tools.ts` says Codex has no per-run override;
 *    that was true of a command line a *person* types on a server, and is not
 *    true of one this app composes.
 *  - **Gemini CLI**: `GEMINI_CLI_SYSTEM_DEFAULTS_PATH`. Gemini merges four
 *    settings files — system defaults, user, workspace, system — and the first
 *    is the lowest layer and can be moved by that variable
 *    (`packages/cli/src/config/settings.ts`, `getSystemDefaultsPath`); its
 *    `mcpServers` are merged key by key (`MergeStrategy.SHALLOW_MERGE` in
 *    `settingsSchema.ts`), so the person's own servers stay and this one is
 *    added. If the machine already has a system-defaults file, its contents are
 *    carried into ours, so pointing the variable elsewhere hides nothing; if
 *    that file cannot be read as JSON the variable is not set at all, rather
 *    than hide something somebody put there.
 *
 * A custom agent somebody added by hand is a command this app has never read,
 * and a plain shell has no agent in it; neither is given anything.
 *
 * ## What the server is
 *
 * `staysfixed mcp`, the engine's own MCP server — capabilities, intent, check,
 * explain, prove, waive, coverage — started by this app's executable as Node
 * (see `engine.ts`) with `--cwd` naming the project, so it answers about the
 * right folder whatever directory the agent started it from. It runs the same
 * pinned copy the page runs, so an agent and a person see the same engine.
 */

export interface AgentLaunch {
  args: string[]
  env: Record<string, string>
}

export interface AgentServerDeps {
  home: EngineHome
  /** This app's executable. */
  executable: string
  /** The Node shim (`engine.ts`), or null where there is none. */
  shim: string | null
  /** The login shell's PATH, already resolved. */
  loginPath: string
  /** Where this module may write the per-project files: `<userData>/staysfixed/agents`. */
  dir: string
  platform?: NodeJS.Platform
  env?: NodeJS.ProcessEnv
  /** File access, injected so a test needs no disk. */
  fs?: { exists(path: string): boolean; read(path: string): string; write(path: string, text: string): void; mkdir(path: string): void }
}

/** How long one tool call may take. A check of a website with an old build booted live is minutes, not seconds. */
export const TOOL_TIMEOUT_SECONDS = 900

/** The server, as every agent's configuration spells a stdio server: a command, arguments, environment. */
export function serverSpec(root: string, deps: Pick<AgentServerDeps, 'home' | 'executable' | 'shim' | 'loginPath'>): {
  command: string
  args: string[]
  env: Record<string, string>
} {
  const path = [deps.loginPath, deps.shim === null ? '' : dirname(deps.shim)].filter((part) => part !== '').join(delimiter)
  const env: Record<string, string> = { ELECTRON_RUN_AS_NODE: '1' }
  if (deps.shim !== null) env.TD_SF_EXEC_PATH = deps.shim
  if (path !== '') env.PATH = path
  return {
    command: deps.executable,
    args: ['--import', preloadUrl(), deps.home.bin, 'mcp', '--cwd', root],
    env,
  }
}

/* ------------------------------------------------------------------ TOML -- */

/**
 * A TOML basic string. JSON's escapes are a subset of TOML's (`\"`, `\\`,
 * `\n`, `\uXXXX`), so `JSON.stringify` writes a valid one.
 */
export function tomlString(value: string): string {
  return JSON.stringify(value)
}

export function tomlArray(values: readonly string[]): string {
  return `[${values.map(tomlString).join(',')}]`
}

export function tomlTable(values: Readonly<Record<string, string>>): string {
  const keyOf = (key: string): string => (/^[A-Za-z0-9_-]+$/.test(key) ? key : tomlString(key))
  return `{${Object.entries(values)
    .map(([key, value]) => `${keyOf(key)}=${tomlString(value)}`)
    .join(',')}}`
}

/* ----------------------------------------------------------------- each -- */

function nodeFs(): NonNullable<AgentServerDeps['fs']> {
  return {
    exists: (path) => existsSync(path),
    read: (path) => readFileSync(path, 'utf8'),
    write: (path, text) => writeFileSync(path, text, { mode: 0o600 }),
    mkdir: (path) => mkdirSync(path, { recursive: true }),
  }
}

function slug(root: string): string {
  return createHash('sha256').update(root).digest('hex').slice(0, 16)
}

/** Write `text` to `file` unless it already says exactly that. Null when the folder cannot be written. */
function keep(fs: NonNullable<AgentServerDeps['fs']>, dir: string, name: string, text: string): string | null {
  const file = join(dir, name)
  try {
    fs.mkdir(dir)
    let current = ''
    try {
      current = fs.exists(file) ? fs.read(file) : ''
    } catch {
      current = ''
    }
    if (current !== text) fs.write(file, text)
    return file
  } catch {
    return null
  }
}

/**
 * Where Gemini looks for system defaults when nothing moves it — the file a
 * person or an administrator may already have, and whose contents ours carries.
 */
export function geminiDefaultsPath(env: NodeJS.ProcessEnv, platform: NodeJS.Platform): string {
  if (env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH) return env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH
  const settings =
    env.GEMINI_CLI_SYSTEM_SETTINGS_PATH ||
    (platform === 'darwin'
      ? '/Library/Application Support/GeminiCli/settings.json'
      : platform === 'win32'
        ? 'C:\\ProgramData\\gemini-cli\\settings.json'
        : '/etc/gemini-cli/settings.json')
  return join(dirname(settings), 'system-defaults.json')
}

/**
 * What a session of `provider` started in `root` is launched with, or null.
 *
 * Null for every agent that cannot be given it, and for any of them when the
 * file it needs cannot be written: a session started without the tool is a
 * session exactly as it was before, which is the right failure.
 */
export function agentLaunch(provider: string, root: string, deps: AgentServerDeps): AgentLaunch | null {
  const fs = deps.fs ?? nodeFs()
  const server = serverSpec(root, deps)
  if (provider === 'claude') {
    const text = `${JSON.stringify({ mcpServers: { [STAYS_FIXED_SERVER]: { type: 'stdio', ...server } } }, null, 2)}\n`
    const file = keep(fs, deps.dir, `claude-${slug(root)}.json`, text)
    return file === null ? null : { args: ['--mcp-config', file], env: {} }
  }
  if (provider === 'codex') {
    const at = `mcp_servers.${STAYS_FIXED_SERVER}`
    return {
      args: [
        '-c',
        `${at}.command=${tomlString(server.command)}`,
        '-c',
        `${at}.args=${tomlArray(server.args)}`,
        '-c',
        `${at}.env=${tomlTable(server.env)}`,
        '-c',
        `${at}.tool_timeout_sec=${TOOL_TIMEOUT_SECONDS}`,
      ],
      env: {},
    }
  }
  if (provider === 'gemini') {
    const theirs = geminiDefaultsPath(deps.env ?? process.env, deps.platform ?? process.platform)
    let base: Record<string, unknown> = {}
    if (fs.exists(theirs)) {
      try {
        const parsed = JSON.parse(fs.read(theirs)) as unknown
        if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
        base = parsed as Record<string, unknown>
      } catch {
        return null
      }
    }
    const servers = typeof base.mcpServers === 'object' && base.mcpServers !== null ? (base.mcpServers as Record<string, unknown>) : {}
    const merged = {
      ...base,
      mcpServers: { ...servers, [STAYS_FIXED_SERVER]: { ...server, timeout: TOOL_TIMEOUT_SECONDS * 1000 } },
    }
    const file = keep(fs, deps.dir, `gemini-${slug(root)}.json`, `${JSON.stringify(merged, null, 2)}\n`)
    return file === null ? null : { args: [], env: { GEMINI_CLI_SYSTEM_DEFAULTS_PATH: file } }
  }
  return null
}
