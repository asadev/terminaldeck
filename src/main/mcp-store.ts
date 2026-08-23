import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { promisify } from 'node:util'
import {
  addMcpServer,
  tokenizeCommand,
  type McpAddResult,
  type McpAddScope,
  type McpAddTransport,
} from './mcp-add'
import {
  catalogueEntry,
  environmentKeys,
  MCP_CATALOGUE,
  requiredRuntimes,
  RUNTIME_BINARY,
  RUNTIME_NEEDS,
  type McpCatalogue,
  type McpCatalogueEntry,
  type McpCatalogueInput,
  type McpCategory,
  type McpCost,
  type McpOrigin,
  type McpRuntime,
} from './mcp-catalogue'
import { customBinaries, customRows } from './mcp-custom'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { firstLookupPath, lookupSpec } from './platform/lookup'
import { loginEnvSpec, parseEnvNames } from './platform/login-env'
import { loginPath } from './providers'

const run = promisify(execFile)

/**
 * The MCP store's engine: what can be installed here, and installing it.
 *
 * ## The shape is the browser store's, deliberately
 *
 * `browser-extensions.ts` and its catalogue answer the same three questions for
 * the browser — *what is on offer, what is already on, what cannot work here* —
 * and Asad's ask was explicitly *"one like in our MCP store"*, meaning the two
 * should read as one product. So the vocabulary is copied on purpose: a row has
 * a state, a row that cannot work says so **and offers no button**, and every
 * refusal lands on the row that caused it rather than in a banner.
 *
 * ## What "cannot work here" means for an MCP server
 *
 * The browser store can be definitive — it loaded the extension into this app's
 * Electron and watched it. This store cannot, and does not pretend to. What it
 * *can* measure on this machine is the one thing that decides whether a row can
 * even begin: whether `npx`, `uvx` or `docker` is on the PATH. That is a real
 * check with a real answer, it is done with the same `which`/`where.exe` this
 * app already uses everywhere else, and it is the difference between a row that
 * installs and then fails at every spawn and a row that says *docker is not on
 * this machine* before you press anything.
 *
 * It is deliberately the only capability claim made. A row does not say the
 * server works, because nothing here watched it work.
 *
 * ## Secrets: two places, and only one of them is a copy
 *
 * A token can live in exactly two places where the process that needs it will
 * find it, and this store offers both because they are genuinely different
 * trades rather than a preference:
 *
 *  1. **In your login shell.** `providers.ts` starts every agent CLI through a
 *     login shell on POSIX, and an MCP server is a child of that agent, so it
 *     inherits. Nothing is written down by this app at all. Offered **only when
 *     the variable was actually found** — see `platform/login-env.ts` for why a
 *     blind offer would be a dead control — and the row carries the one honest
 *     caveat that comes with it, below.
 *
 *  2. **In the configuration**, as `-e KEY=value` through `claude mcp add`. That
 *     is plain text in `~/.claude.json`, a file the CLI creates mode 0600, and
 *     the row says exactly that before the button is pressed rather than after.
 *
 * There is no third option, and the third option is the one worth explaining
 * because it looks like the right answer. Electron's `safeStorage` encrypts
 * secrets **this application owns and later reads back itself**. Nothing here
 * reads the value back: the process that needs it is an MCP server spawned by
 * the agent CLI, out of a config file this app does not control the reading of.
 * A secret sealed into this app's own store would be a secret nothing can
 * decrypt at the moment it is needed — a call that compiles, runs, and leaves
 * the server unauthenticated. `platform/credential-store.ts` already writes this
 * argument down for agent logins, in almost the same words, and it is the same
 * argument. Encrypting something we do not hold is not a thing that can be done.
 *
 * ## The gap that comes with inheriting, said out loud
 *
 * A server whose key comes from the login shell works when a **session** starts
 * it, because the session is a login shell. Opening the same server from the
 * MCP page's Installed tab starts it from *this app's* process instead, and a
 * macOS app launched from Finder does not carry a login shell's variables. So
 * such a server can report a missing key on that page while working perfectly in
 * a session. That is real, it is not fixed here, and {@link inheritanceCaveat}
 * is the sentence the row prints so nobody has to discover it.
 */

/* ------------------------------------------------------------------ types -- */

export type McpStoreState =
  /** Not in the configuration, and installable here. */
  | 'available'
  /** In the configuration, and it is this row. */
  | 'installed'
  /** A server of this name exists and is not this row. Nothing is offered. */
  | 'taken'
  /** The runtime it needs is not on this machine. No Install. */
  | 'unavailable'

export interface McpStoreInput extends McpCatalogueInput {
  /**
   * Whether this name is exported by the login shell, so its value need never
   * be written down. False for every `arg` input by construction — a command
   * line argument cannot come from the environment.
   */
  inEnvironment: boolean
}

/**
 * Which shelf a row sits on.
 *
 * The catalogue's thirteen, plus one this catalogue can never contain:
 * `your-own` is where a server somebody typed themselves goes, and it exists
 * because such a server has no subject this app is entitled to guess at. Filing
 * a hand-written command under *Time, testing and odds and ends* would be this
 * app describing a program it has never read. The browser store already spells
 * its equivalent shelf the same way, and the two stores are meant to read as one
 * product.
 *
 * Widened here rather than in `mcp-catalogue.ts` on purpose: no catalogue entry
 * may ever carry it, and the type that catalogue is written against is what says
 * so.
 */
export type McpStoreCategory = McpCategory | 'your-own'

/**
 * What a row costs to use, as the *store* may report it.
 *
 * The catalogue's four, plus the one answer only a row nobody catalogued can
 * give. `unknown` is not a fifth kind of price: it is *this app has not measured
 * what your server costs and is not going to guess*, which is the only honest
 * thing to say about a command somebody typed. `store/storefront.ts` argues the
 * same five values for both stores, and the browser half already carries
 * `unknown` for exactly this row.
 *
 * Widened here for the same reason {@link McpStoreCategory} is — no catalogue
 * entry may ever hold it.
 */
export type McpStoreCost = McpCost | 'unknown'

export interface McpStoreRow {
  id: string
  name: string
  summary: string
  /** Which shelf it sits on, so the store browses by subject rather than state. */
  category: McpStoreCategory
  /** Words to search on that are in neither the name nor the summary. */
  tags: string[]
  homepage: string
  registry: string
  licence: string
  version: string
  runtime: McpRuntime
  /** The binary the runtime needs, so the row can name what was looked for. */
  runtimeBinary: string
  origin: McpOrigin
  /** What using it costs, from the catalogue. See {@link McpStoreCost}. */
  cost: McpStoreCost
  /** The price reality in one sentence, or `''` for a row that is simply free. */
  costNote: string
  /** The command as it would be written, placeholders and all. */
  command: string
  inputs: McpStoreInput[]
  state: McpStoreState
  /** Which scope it is installed in. `''` unless installed. */
  scope: '' | McpAddScope
  /**
   * True for a server that is in the configuration and in no catalogue — one
   * somebody added themselves.
   *
   * A field rather than a sixth {@link McpOrigin}, because `origin` is a fact
   * the *catalogue* establishes about a project — reference, vendor, hosted,
   * archived on a dated day — and a server this app has never heard of has no
   * such fact. Widening that union would also have put a value into
   * `mcp-catalogue.ts` that no catalogue entry can ever hold.
   */
  custom: boolean
  /** How it is reached, which for a custom row decides what "how it runs" means. */
  transport: McpAddTransport
  /**
   * The names of the environment variables it carries. Never the values.
   *
   * On the row so a server you added says what it is holding, and in the edit
   * form so a field can offer to keep what is already saved. `configuredForStore`
   * is deliberately lossy about everything else for the same reason it is lossy
   * here: a value has no business on a wire that only needs a name.
   */
  envKeys: string[]
  /**
   * How this one runs, in a sentence, when the three-runtime vocabulary cannot
   * say it. `''` on every catalogue row, which uses `RUNTIME_WORDS`.
   *
   * A custom server can be `docker`, or `uvx`, or `/opt/homebrew/bin/my-server`,
   * or an HTTPS URL. "npx — fetched from npm the first time it runs" is true of
   * most catalogue rows and would be a straight lie under any of the others.
   */
  runsWords: string
  /**
   * The binary this row needs was looked for on this machine and not found.
   *
   * Separate from `state` because the two coincide only for catalogue rows. A
   * custom server whose runtime is missing is still *installed* — it is in the
   * configuration, it will fail when Claude Code tries to start it — so it keeps
   * its Remove and says the problem in a sentence instead of becoming a row with
   * no controls.
   */
  runtimeMissing: boolean
  /** The command line of the server already wearing this name, when `taken`. */
  taken: string
  /**
   * Why this row has no Install button, in a sentence. `''` when it has one.
   *
   * A row is never merely greyed out: something that cannot be installed says
   * what is missing, which is the difference between a store that looks broken
   * and a machine that is missing a runtime.
   */
  blocked: string
  caveat: string
  /** The key of the mark the store draws, or `''`. See `McpCatalogueEntry.logo`. */
  logo: string
}

export interface McpRuntimeReport {
  id: McpRuntime
  binary: string
  found: boolean
  /** Where it was found, so the claim is checkable. `''` when not found. */
  path: string
  /** What to install when it was not. */
  needs: string
}

export type McpEnvironmentSource =
  /** Names read from an interactive login shell. */
  | 'login-shell'
  /** Names from this process's own environment — the Windows answer. */
  | 'process'
  /** The shell could not be asked; no name is claimed either way. */
  | 'unavailable'

export interface McpStoreView {
  rows: McpStoreRow[]
  runtimes: McpRuntimeReport[]
  /**
   * The CLI that writes the configuration. Nothing installs without it, so this
   * is reported once at the top rather than as one identical failure per row.
   */
  writer: { found: boolean; path: string }
  environmentSource: McpEnvironmentSource
  /** The folder the page is scoped to, echoed back so the view is checkable. */
  projectPath: string
}

/** What one server already in the configuration looks like from here. */
export interface ConfiguredServer {
  name: string
  scope: McpAddScope
  /**
   * The command as it would be typed, or the URL.
   *
   * Quoted rather than space-joined — see `quoteArgv` in `mcp-add.ts`. It is
   * used for the token test that decides whether a configured server *is* a
   * catalogue row, and it is what a custom row prints and what the edit form
   * starts from, so it has to survive being read back.
   */
  commandLine: string
  /** How it is reached. Absent from a caller too old to send it, read as stdio. */
  transport?: McpAddTransport
  /**
   * The environment variable names it carries, never the values.
   *
   * Optional so a caller that has not been updated still type-checks; absent is
   * read as none, which is what a build without this field could report anyway.
   */
  envKeys?: readonly string[]
}

/**
 * One binary, looked for on this machine.
 *
 * The same three fields {@link McpRuntimeReport} carries without the `id`,
 * because a custom server's runtime is whatever the person typed and there is no
 * enum it belongs to. `docker` and `/opt/homebrew/bin/my-server` are answered
 * the same way and by the same probe.
 */
export interface McpBinaryReport {
  binary: string
  found: boolean
  /** Where it was found, so the claim is checkable. `''` when it was not. */
  path: string
}

/* --------------------------------------------------------------- probing -- */

/** Injectable so every test runs without touching the machine. */
export interface McpStoreDeps {
  exec?(
    file: string,
    args: string[],
    options: { env: NodeJS.ProcessEnv; timeout: number; windowsHide: boolean },
  ): Promise<{ stdout: string; stderr: string }>
  path?(): Promise<string>
  platform?: Platform
  /**
   * The write itself, injectable as one function rather than as `mcp-add.ts`'s
   * own deps.
   *
   * Those two have different option shapes — the add spawn carries a `cwd`,
   * because two of the three scopes are addressed by it, and a `which` probe has
   * no business having one — so threading a single `exec` through both would
   * mean a stub that has to satisfy the wider signature to test the narrower
   * path. One seam per thing being replaced.
   */
  add?(request: unknown): Promise<McpAddResult>
  /**
   * Whether a file is there. Replaced in tests, and only ever asked about a
   * command a person typed that already contains a path separator — see
   * {@link probeBinaries}.
   */
  exists?(file: string): boolean
}

/**
 * A `which` is either instant or the PATH is a network mount. Five seconds is
 * both generous and finite; a store that hangs on a probe is a store that never
 * opens.
 */
const PROBE_TIMEOUT_MS = 5_000

/**
 * The login shell is slower — it sources the user's whole profile — and this is
 * the same shell `loginPath` already spawns at startup. Ten seconds.
 */
const ENV_TIMEOUT_MS = 10_000

function execFor(deps: McpStoreDeps): NonNullable<McpStoreDeps['exec']> {
  return (
    deps.exec ??
    ((file, args, options) =>
      run(file, args, options).then(({ stdout, stderr }) => ({
        stdout: String(stdout),
        stderr: String(stderr),
      })))
  )
}

/**
 * Where a binary is, or `''`.
 *
 * Never throws: `which` exits non-zero for "not found", which `execFile` turns
 * into a rejection, and a rejected probe is an answer rather than a failure.
 */
async function probeBinary(
  bin: string,
  env: NodeJS.ProcessEnv,
  platform: Platform,
  deps: McpStoreDeps,
): Promise<string> {
  const spec = lookupSpec(platform, bin)
  try {
    const { stdout } = await execFor(deps)(spec.command, spec.args, {
      env,
      timeout: PROBE_TIMEOUT_MS,
      windowsHide: true,
    })
    return firstLookupPath(stdout) ?? ''
  } catch {
    return ''
  }
}

/**
 * Which of the catalogue's environment variable names the user's shell exports.
 *
 * Names only — never values; see `platform/login-env.ts`. On Windows there is
 * no login shell to ask and this process's own environment *is* the user's, so
 * that is what is read, and the source is reported so the UI can say which
 * happened rather than implying one.
 */
export async function readEnvironmentNames(
  keys: readonly string[],
  platform: Platform,
  env: NodeJS.ProcessEnv,
  deps: McpStoreDeps,
): Promise<{ names: Set<string>; source: McpEnvironmentSource }> {
  const spec = loginEnvSpec(platform, env as Record<string, string | undefined>)
  const wanted = new Set(keys)
  if (spec === null) {
    const here = new Set(Object.keys(env).filter((key) => (env[key] ?? '') !== ''))
    return { names: new Set([...wanted].filter((key) => here.has(key))), source: 'process' }
  }
  try {
    const { stdout } = await execFor(deps)(spec.command, spec.args, {
      env,
      timeout: ENV_TIMEOUT_MS,
      windowsHide: true,
    })
    const found = parseEnvNames(stdout)
    return { names: new Set([...wanted].filter((key) => found.has(key))), source: 'login-shell' }
  } catch {
    // A shell that could not be asked means nothing is *known*, which is not the
    // same as nothing being there. Claiming "not set" from a failed probe would
    // push somebody into pasting a token they did not need to.
    return { names: new Set(), source: 'unavailable' }
  }
}

/**
 * Look for whatever the custom servers' commands name, on this machine.
 *
 * Kept out of {@link readStoreFacts} on purpose, and the reason is that
 * function's own deduplication note: it shares one in-flight promise between
 * concurrent reads, which is right for a fixed question — *where are npx, uvx,
 * docker and claude* — and wrong for one whose answer depends on which project
 * is open. Two tabs asking about two different configurations would have shared
 * one answer, and the second would have been about the first one's servers.
 *
 * ## Why an absolute path is not asked of `which`
 *
 * A hand-written server is very often `/Users/me/code/thing/serve`, and `which`
 * answers about names on the PATH. POSIX `which` happens to echo an absolute
 * path back whether or not it exists on some systems, and Windows `where` treats
 * one as a pattern — so the one shape people most often type is the one the
 * probe is least reliable about. Anything with a separator in it is therefore
 * asked of the filesystem instead, which is the question actually being asked.
 */
export async function probeBinaries(
  servers: readonly ConfiguredServer[],
  deps: McpStoreDeps = {},
): Promise<McpBinaryReport[]> {
  const wanted = customBinaries(servers)
  if (wanted.length === 0) return []
  const platform = deps.platform ?? currentPlatform()
  const path = await (deps.path ?? loginPath)()
  const env = withPath(process.env, path, platform)
  const exists = deps.exists ?? ((file: string) => existsSync(file))
  return Promise.all(
    wanted.map(async (binary): Promise<McpBinaryReport> => {
      if (/[\\/]/.test(binary)) {
        const there = exists(binary)
        return { binary, found: there, path: there ? binary : '' }
      }
      const found = await probeBinary(binary, env, platform, deps)
      return { binary, found: found !== '', path: found }
    }),
  )
}

/* ----------------------------------------------------------- the view -- */

/**
 * The sentence a row prints when its key would be inherited rather than written.
 *
 * Exported and used in exactly one place so the caveat cannot drift from the
 * behaviour it describes. See this file's header for why the gap exists.
 */
export function inheritanceCaveat(key: string): string {
  return (
    `${key} is already set in your login shell, where sessions run, so installing it here writes ` +
    'nothing down. One thing that comes with that: opening this server from the Installed tab ' +
    'starts it from this app rather than from a shell, and this app may not carry that variable — ' +
    'so it can report a missing key there while working in a session.'
  )
}

/**
 * Turn the catalogue plus three measurements into the rows the panel draws.
 *
 * Pure — every input is a parameter — because this is where every decision the
 * store makes actually happens, and a decision reachable only through three
 * child processes is a decision nothing can test.
 */
export function buildStoreView(input: {
  catalogue?: McpCatalogue
  configured: readonly ConfiguredServer[]
  runtimes: readonly McpRuntimeReport[]
  environment: ReadonlySet<string>
  environmentSource: McpEnvironmentSource
  writer: { found: boolean; path: string }
  projectPath: string | null
  /**
   * Whatever the *custom* servers' commands name, looked for on this machine.
   *
   * Separate from `runtimes` because those three are a closed set the catalogue
   * declares and these are whatever somebody typed. Optional so every existing
   * caller and test still compiles: absent means nothing was looked for, and
   * `customRunsWords` says exactly that rather than reporting a binary missing
   * on the strength of a probe nobody ran.
   */
  binaries?: readonly McpBinaryReport[]
}): McpStoreView {
  const catalogue = input.catalogue ?? MCP_CATALOGUE
  const byRuntime = new Map(input.runtimes.map((report) => [report.id, report]))
  /*
   * `scope:name` for every configured server a catalogue row actually *is* — the
   * token test below, not merely the name. What is left over is what somebody
   * added themselves, and it becomes a row of its own; see `mcp-custom.ts`.
   */
  const claimed = new Set<string>()

  const rows = catalogue.map((entry): McpStoreRow => {
    const runtime = byRuntime.get(entry.runtime)
    const mine = input.configured.find((server) => server.name === entry.name)
    const isMine = mine !== undefined && mine.commandLine.includes(entry.token)
    if (isMine && mine) claimed.add(`${mine.scope}:${mine.name}`)

    const inputs = entry.inputs.map((field): McpStoreInput => ({
      ...field,
      // An `arg` is part of the command line, so the environment cannot supply
      // it. Saying `false` here rather than leaving it to the UI is what stops a
      // "use the one in your shell" offer appearing on a field that would ignore
      // it.
      inEnvironment: field.into === 'env' && input.environment.has(field.key),
    }))

    let state: McpStoreState = 'available'
    let blocked = ''
    if (isMine) {
      state = 'installed'
    } else if (mine !== undefined) {
      state = 'taken'
      blocked =
        `A server called ${entry.name} is already configured and it is not this one. ` +
        'Remove it, or add this under another name from “Add your own”.'
    } else if (runtime === undefined || !runtime.found) {
      state = 'unavailable'
      blocked = `${RUNTIME_BINARY[entry.runtime]} is not on this machine. It needs ${RUNTIME_NEEDS[entry.runtime]}`
    } else if (!input.writer.found) {
      // Not `unavailable`: the machine can run this server perfectly well, it is
      // *writing the configuration* that is impossible. Different problem, so a
      // different sentence — and the store says it once at the top too.
      blocked =
        'Claude Code’s command line tool is what writes this configuration, and it was not found ' +
        'on this machine.'
    }

    return {
      id: entry.id,
      name: entry.name,
      summary: entry.summary,
      category: entry.category,
      tags: [...entry.tags],
      homepage: entry.homepage,
      registry: entry.registry,
      licence: entry.licence,
      version: entry.version,
      runtime: entry.runtime,
      runtimeBinary: RUNTIME_BINARY[entry.runtime],
      origin: entry.origin,
      /*
       * Price travels with the row and is not worked out here from anything
       * else. A store that inferred it — *"this one takes a secret, so it must
       * cost money"* — would call Notion paid and Google Maps free, and those
       * are both wrong in the direction that matters.
       */
      cost: entry.cost,
      costNote: entry.costNote,
      /*
       * An installed row shows **what is actually in the configuration**, not
       * the template it came from.
       *
       * Rendering it and looking at it is what caught this: the installed
       * `filesystem` row printed `npx -y @modelcontextprotocol/server-filesystem
       * ${ROOT}` — a placeholder, on a row whose whole claim is that it is
       * already configured, next to a Remove button. The one thing a person
       * wants from that row is *which directory did I point it at*, and the
       * template cannot answer.
       *
       * It is the same disclosure the servers list next door already makes for
       * every configured server, `formatCommand` included, so the postgres row's
       * connection string is no more exposed here than it is there — and that
       * row's own hint says outright that a password in it cannot be kept out of
       * the configuration file.
       */
      command: isMine && mine ? mine.commandLine : entry.command,
      inputs,
      state,
      scope: isMine && mine ? mine.scope : '',
      custom: false,
      /* Every catalogue row is a command on this machine — `installFromCatalogue`
         writes `transport: 'stdio'` and there is no other path into one. */
      transport: 'stdio',
      /* The catalogue declares *which* variables a row takes, in `inputs`, with
         labels and hints. Repeating the bare keys here would be the same fact
         twice in two vocabularies. This field is what a row with no catalogue
         entry behind it has instead. */
      envKeys: [],
      /* `RUNTIME_WORDS` says it for these three. See `McpStoreRow.runsWords`. */
      runsWords: '',
      runtimeMissing: runtime === undefined || !runtime.found,
      taken: state === 'taken' && mine ? mine.commandLine : '',
      blocked,
      caveat: entry.caveat ?? '',
      logo: entry.logo ?? '',
    }
  })

  return {
    /*
     * The catalogue first, then everything in the configuration it did not
     * claim. Order here is not the drawing order — the panel shelves and sorts
     * — but a stable one keeps a test readable.
     */
    rows: [...rows, ...customRows(input.configured, claimed, input.binaries ?? [])],
    runtimes: [...input.runtimes],
    writer: input.writer,
    environmentSource: input.environmentSource,
    projectPath: input.projectPath ?? '',
  }
}

/* ---------------------------------------------------------- the install -- */

export interface McpInstallRequest {
  id: string
  scope: McpAddScope
  projectPath: string | null
  /** Input key → what was typed. A key that is absent or blank was not filled. */
  values: Record<string, string>
}

/**
 * What crossed the bridge, as an install, or why it is not one.
 *
 * The same posture as `mcp-add.ts`'s own resolver — everything is `unknown` on
 * this side — and the messages are written for the person looking at the form.
 */
export function resolveInstall(raw: unknown): { id: string; scope: McpAddScope; projectPath: string | null; values: Record<string, string> } {
  if (typeof raw !== 'object' || raw === null) throw new Error('Nothing to install.')
  const request = raw as Record<string, unknown>
  const id = typeof request.id === 'string' ? request.id : ''
  if (id === '') throw new Error('Nothing to install.')
  const scope: McpAddScope =
    request.scope === 'project' || request.scope === 'local' ? request.scope : 'user'
  const projectPath =
    typeof request.projectPath === 'string' && request.projectPath !== '' ? request.projectPath : null
  const values: Record<string, string> = {}
  if (typeof request.values === 'object' && request.values !== null) {
    for (const [key, value] of Object.entries(request.values as Record<string, unknown>)) {
      if (typeof value === 'string') values[key] = value.trim()
    }
  }
  return { id, scope, projectPath, values }
}

/**
 * The command line and the `-e` list for one catalogue row, filled in.
 *
 * Pure and exported because this is the part that can be silently wrong: an
 * unsubstituted `${ROOT}` produces a filesystem server rooted at a literal
 * dollar-brace, which starts, answers, and reads nothing — a working-looking
 * failure. So a placeholder that was not filled is an error here rather than a
 * string that survives into a config file.
 *
 * ## Why a blank `env` input is not an error
 *
 * Because a blank one may be the *better* answer: the variable is already in the
 * login shell and writing a second copy into a config file is strictly worse.
 * `available` tells this function which keys those are — it is the measured set
 * from {@link readEnvironmentNames}, never a guess — and a required field that
 * is neither typed nor present is refused by name.
 */
export function buildInstall(
  entry: McpCatalogueEntry,
  values: Record<string, string>,
  available: ReadonlySet<string>,
): { command: string; extras: string[]; inherited: string[] } {
  let command = entry.command
  const extras: string[] = []
  const inherited: string[] = []

  for (const field of entry.inputs) {
    const typed = (values[field.key] ?? '').trim()

    if (field.into === 'arg') {
      if (typed === '') {
        if (field.required) throw new Error(`${entry.name} needs ${field.label.toLowerCase()}.`)
        // An optional argument that was not given: drop the placeholder rather
        // than leave `${KEY}` on the command line.
        command = command.split('${' + field.key + '}').join('').replace(/\s{2,}/g, ' ').trim()
        continue
      }
      if (!command.includes('${' + field.key + '}')) {
        throw new Error(`This build cannot fill ${field.key} for ${entry.name}.`)
      }
      // Quoted, because the commonest value here is a macOS path with a space
      // in it and `tokenizeCommand` follows shell quoting rules. A value that
      // contains a double quote is refused rather than escaped: nothing here
      // goes through a shell, so this is not an injection guard, it is a
      // tokenizer that would split the argument in the wrong place.
      if (typed.includes('"')) throw new Error(`${field.label} cannot contain a double quote.`)
      command = command.split('${' + field.key + '}').join(`"${typed}"`)
      continue
    }

    if (typed !== '') {
      // A newline would end the `KEY=value` entry and start something else in
      // the extras list; a token never has one, and a pasted one that does is a
      // paste that went wrong.
      if (/[\r\n]/.test(typed)) throw new Error(`${field.label} cannot contain a line break.`)
      extras.push(`${field.key}=${typed}`)
      continue
    }
    if (available.has(field.key)) {
      inherited.push(field.key)
      continue
    }
    if (field.required) throw new Error(`${entry.name} needs ${field.label.toLowerCase()}.`)
  }

  if (command.includes('${')) {
    throw new Error(`Something in ${entry.name}’s command was not filled in.`)
  }
  // Cheap proof that what was built is a command and not a sentence. It is the
  // same tokenizer the add path uses, so a value that would fail there fails
  // here, where the message can still name the field.
  if (tokenizeCommand(command).length === 0) throw new Error(`${entry.name} has no command.`)

  return { command, extras, inherited }
}

export interface McpStoreResult {
  ok: boolean
  message: string
}

/**
 * Install one catalogue row, through the same CLI everything else writes with.
 *
 * The runtime is re-probed here rather than trusted from the view the renderer
 * was looking at, because that view may be minutes old and `docker` may have
 * been quit in between. A store that installs a row it has already drawn as
 * unavailable is the dead control with an extra step.
 */
export async function installFromCatalogue(
  raw: unknown,
  configured: readonly ConfiguredServer[],
  deps: McpStoreDeps = {},
): Promise<McpStoreResult> {
  let request: ReturnType<typeof resolveInstall>
  let entry: McpCatalogueEntry | null
  try {
    request = resolveInstall(raw)
    entry = catalogueEntry(request.id)
  } catch (cause) {
    return { ok: false, message: cause instanceof Error ? cause.message : String(cause) }
  }
  if (entry === null) return { ok: false, message: 'This build has no such server.' }
  // Bound to a const so it narrows inside the closures below; `entry` is a
  // `let` and TypeScript will not carry a narrowing of one into a callback.
  const chosen = entry

  const clash = configured.find((server) => server.name === chosen.name)
  if (clash && !clash.commandLine.includes(chosen.token)) {
    return {
      ok: false,
      message: `A server called ${chosen.name} is already configured and it is not this one. Nothing was changed.`,
    }
  }

  const platform = deps.platform ?? currentPlatform()
  const path = await (deps.path ?? loginPath)()
  const env = withPath(process.env, path, platform)
  const binary = RUNTIME_BINARY[chosen.runtime]
  const found = await probeBinary(binary, env, platform, deps)
  if (found === '') {
    return {
      ok: false,
      message: `${binary} is not on this machine, so this server could not start. It needs ${RUNTIME_NEEDS[chosen.runtime]}`,
    }
  }

  const { names } = await readEnvironmentNames(environmentKeys(), platform, env, deps)

  let built: ReturnType<typeof buildInstall>
  try {
    built = buildInstall(chosen, request.values, names)
  } catch (cause) {
    return { ok: false, message: cause instanceof Error ? cause.message : String(cause) }
  }

  const write = deps.add ?? ((payload: unknown) => addMcpServer(payload, { path: deps.path }))
  const result = await write({
    name: chosen.name,
    scope: request.scope,
    transport: 'stdio',
    command: built.command,
    url: '',
    extras: built.extras,
    projectPath: request.projectPath,
  })
  if (!result.ok) return result

  // What the row is entitled to know afterwards, and nothing else. The CLI's own
  // two lines are replaced rather than echoed — `McpInspector` learned that
  // lesson once already, when they were concatenated into an ungrammatical
  // paragraph that stayed on screen for the rest of the session.
  const inherited =
    built.inherited.length === 0
      ? ''
      : ` ${built.inherited.join(' and ')} was left to your login shell, so nothing was written down for it.`
  const written =
    built.extras.length === 0
      ? ''
      : ` ${built.extras.map((entryText) => entryText.split('=')[0]).join(' and ')} was written into your ${request.scope} configuration in plain text.`
  return { ok: true, message: `Added ${chosen.name}.${inherited}${written}` }
}

/* ------------------------------------------------------------ the report -- */

/**
 * Everything the store needs from this machine, measured.
 *
 * Three `which` calls and one login shell, in parallel, once per read of the
 * page. The alternative — probing per row — is one spawn per row for the same
 * three answers, which is thirty-nine of them today and more with every row.
 */
/**
 * The real probe currently in flight, or null.
 *
 * Only ever set on the unstubbed path — `deps.exec` present means a test, and a
 * module-level promise shared between tests is a test that passes because
 * another one ran first.
 *
 * Deduplicated rather than **memoised**, and the difference is the whole point.
 * `loginPath` memoises for the life of the process because a PATH that changed
 * after launch is not visible to this process anyway. This is the opposite: the
 * question is *is my token exported yet*, and somebody who has just added a line
 * to their `.zshrc` and pressed Reload has to be answered by a shell that was
 * started after they saved it. So a second read always re-asks, and only two
 * reads racing each other — a tab switch and an impatient Reload — share one
 * spawn instead of starting two shells that each source a whole profile.
 */
let probeInFlight: Promise<{
  runtimes: McpRuntimeReport[]
  writer: { found: boolean; path: string }
  environment: Set<string>
  environmentSource: McpEnvironmentSource
}> | null = null

export async function readStoreFacts(
  deps: McpStoreDeps = {},
  catalogue: McpCatalogue = MCP_CATALOGUE,
): Promise<{
  runtimes: McpRuntimeReport[]
  writer: { found: boolean; path: string }
  environment: Set<string>
  environmentSource: McpEnvironmentSource
}> {
  if (deps.exec === undefined && probeInFlight !== null) return probeInFlight
  const started = probeFacts(deps, catalogue)
  if (deps.exec !== undefined) return started
  probeInFlight = started
  try {
    return await started
  } finally {
    probeInFlight = null
  }
}

async function probeFacts(
  deps: McpStoreDeps,
  catalogue: McpCatalogue,
): Promise<{
  runtimes: McpRuntimeReport[]
  writer: { found: boolean; path: string }
  environment: Set<string>
  environmentSource: McpEnvironmentSource
}> {
  const platform = deps.platform ?? currentPlatform()
  const path = await (deps.path ?? loginPath)()
  const env = withPath(process.env, path, platform)

  const wanted = requiredRuntimes(catalogue)
  const [paths, writerPath, environment] = await Promise.all([
    Promise.all(wanted.map((id) => probeBinary(RUNTIME_BINARY[id], env, platform, deps))),
    probeBinary('claude', env, platform, deps),
    readEnvironmentNames(environmentKeys(catalogue), platform, env, deps),
  ])

  return {
    runtimes: wanted.map((id, index) => ({
      id,
      binary: RUNTIME_BINARY[id],
      found: paths[index] !== '',
      path: paths[index],
      needs: RUNTIME_NEEDS[id],
    })),
    writer: { found: writerPath !== '', path: writerPath },
    environment: environment.names,
    environmentSource: environment.source,
  }
}
