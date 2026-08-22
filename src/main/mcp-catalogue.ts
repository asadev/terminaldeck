/**
 * The MCP servers this app offers to install, and what each one was checked
 * against.
 *
 * ## Why there is a store at all
 *
 * There was an MCP *page* — it read the configuration, dialled what it found,
 * listed the tools, and let you type a command in by hand. What it never had was
 * anything to browse. Asad, re-scanning the product:
 *
 *   > *"add one like in our MCP store … directly for the overall terminal deck
 *   > to connect with through MCPs or whatever, install download buttons … most
 *   > probably most of the open sourced one … people like to use their own kind
 *   > of extension … they can just click and attach their own things to this
 *   > application."*
 *
 * Two halves, and both are load-bearing. The catalogue is the *"click"* half —
 * the servers everybody ends up pasting out of a README, offered as rows. The
 * add-your-own form is the *"their own things"* half, and it is not a fallback
 * for what the catalogue lacks: it is the point. A store that only installed
 * what its author chose would be the closed thing he was arguing against.
 *
 * ## Why a list this app ships rather than one it fetches
 *
 * The same argument `browser-extension-catalogue.ts` makes, and for once it is
 * *weaker* here in one respect and stronger in another, so it is worth saying
 * which.
 *
 * Weaker: nothing here is downloaded by this app. A row's install writes a
 * command into a config file; the bytes arrive later, from npm or PyPI or a
 * container registry, fetched by `npx`/`uvx`/`docker` under their own integrity
 * rules. There is no artifact for this app to pin a sha256 to, and pretending
 * otherwise — printing a fingerprint for something we never fetch — would be
 * exactly the decoration the browser store refuses.
 *
 * Stronger: what a row promises is a *package name and an invocation*, and
 * those are the thing a person is trusting when they press Install. A catalogue
 * fetched at runtime would be a list of commands to run, arriving over the
 * network, that this app would then write into the user's agent configuration.
 * That is a remote-code-execution channel with a friendly name. It ships in the
 * app's own bytes or it does not exist.
 *
 * ## What was actually checked, and when
 *
 * Every row below was verified on **2026-08-22** against the real registry — not
 * from memory, and not from a README this app has never opened:
 *
 *  - each npm row by `registry.npmjs.org/<name>/latest`, which is where its
 *    `version` and `licence` come from, verbatim;
 *  - each PyPI row by `pypi.org/pypi/<name>/json`, likewise;
 *  - each row's environment variable names by reading that package's own README
 *    out of the registry and extracting the identifiers it documents — so
 *    `NOTION_TOKEN`, `TAVILY_API_KEY`, `FIRECRAWL_API_KEY`, `CONTEXT7_API_KEY`,
 *    `SLACK_BOT_TOKEN`, `SLACK_TEAM_ID`, `BRAVE_API_KEY` and
 *    `GITHUB_PERSONAL_ACCESS_TOKEN` are the packages' own spellings rather than
 *    plausible ones;
 *  - `origin` by `api.github.com`: `modelcontextprotocol/servers` currently
 *    holds `everything, fetch, filesystem, git, memory, sequentialthinking,
 *    time`, and `modelcontextprotocol/servers-archived` — a repository GitHub
 *    reports as `archived: true` — holds `brave-search, github, postgres,
 *    puppeteer, slack, sqlite` among others. That is the whole basis for the
 *    `reference` / `reference-archived` split, and it is a fact with a date on
 *    it rather than a judgement.
 *
 * **A row was dropped for failing this.** `@sentry/mcp-server` is real, and its
 * README names no environment variable at all, so there was no honest way to
 * fill in what it needs. Guessing `SENTRY_ACCESS_TOKEN` would have produced a
 * row that installs, starts, and fails on its first call — which is the failure
 * mode this file exists to prevent. It is absent rather than approximated.
 *
 * ## What a row does *not* claim
 *
 * Nothing here was watched working, and no row says it was. The browser
 * extension catalogue can promise that, because it loads the artifact into this
 * app's own Electron and watches it; here the artifact is a process fetched from
 * a registry at spawn time and run by the *agent*, not by this app. So a row
 * states what it is, where it comes from, what it needs and how it is run — all
 * checkable before pressing anything — and stops there. `mcp-store.ts` adds the
 * one thing that can be measured on this machine: whether the runtime it needs
 * exists here.
 */

/* ------------------------------------------------------------------ types -- */

/** What has to be on the machine for a row to start at all. */
export type McpRuntime = 'node' | 'python' | 'docker'

/**
 * Which binary each runtime is, for a `which`/`where.exe` probe.
 *
 * `npx` and `uvx` rather than `node` and `python`: the row's command line names
 * those, and a machine with `node` but no `npx` — a stripped container, an old
 * Node — would pass a probe of the wrong name and fail at spawn.
 */
export const RUNTIME_BINARY: Readonly<Record<McpRuntime, string>> = {
  node: 'npx',
  python: 'uvx',
  docker: 'docker',
}

/** What to install when the probe finds nothing, in one sentence, per runtime. */
export const RUNTIME_NEEDS: Readonly<Record<McpRuntime, string>> = {
  node: 'Node.js, which is what provides npx.',
  python: 'uv, which is what provides uvx (astral.sh/uv).',
  docker: 'Docker, and it has to be running, not only installed.',
}

/** A value a row needs before it can work. */
export type McpInputKind =
  /** A token or key. Never printed back once written, and never logged. */
  | 'secret'
  /** A directory or file on this machine. */
  | 'path'
  /** Anything else — a team id, a connection string. */
  | 'text'

export interface McpCatalogueInput {
  /**
   * The environment variable's name, or the placeholder's name in `command`.
   * Constrained to shell-identifier characters by `mcp-catalogue.test.ts`,
   * because it reaches `KEY=value` on a command line.
   */
  key: string
  label: string
  /** Where to get it, or what it should look like. Shown under the field. */
  hint: string
  kind: McpInputKind
  /**
   * `env` becomes `-e KEY=value`; `arg` replaces `${KEY}` inside `command`.
   *
   * The distinction is not cosmetic. An `env` value can also be supplied by the
   * user's login shell and never written down at all — see `mcp-store.ts` — and
   * an `arg` value cannot, because it is part of the command line itself.
   */
  into: 'env' | 'arg'
  /** A row with an unfilled required input offers no Install, and says why. */
  required: boolean
}

/** Where the row comes from, which is a fact about its maintenance. */
export type McpOrigin =
  /** In `modelcontextprotocol/servers` today. */
  | 'reference'
  /** In `modelcontextprotocol/servers-archived`, a repository GitHub reports archived. */
  | 'reference-archived'
  /** Somebody else's project, maintained by them. */
  | 'third-party'

export interface McpCatalogueEntry {
  /** Stable key for IPC. Never shown. */
  id: string
  /**
   * The name the server is written into the configuration under, and therefore
   * the name a session calls its tools by. Short, because it is typed.
   */
  name: string
  /** One honest line. What it does, not what it is good for. */
  summary: string
  /** The project. Every row has one and every row shows it. */
  homepage: string
  /** Read from the registry on the date in this file's header, verbatim. */
  licence: string
  /** Likewise. The row prints it so "how old is this" is answerable on sight. */
  version: string
  /** Where the package is, so the row can name the registry entry itself. */
  registry: string
  runtime: McpRuntime
  /**
   * The command line, with `${KEY}` placeholders for `arg` inputs.
   *
   * Written the way a person would type it, because that is what it is: it goes
   * through `tokenizeCommand` in `mcp-add.ts` and then into `execFile`'s argv,
   * never through a shell.
   */
  command: string
  /**
   * The one substring that identifies this server in a command line already in
   * the configuration.
   *
   * This is how a row knows it is installed, and why it is a field rather than
   * something derived. The obvious derivation — "the first argument that is not
   * a flag" — reads `@modelcontextprotocol/server-filesystem` correctly and then
   * reads `run` out of `docker run -i --rm … ghcr.io/github/github-mcp-server`,
   * which matches nothing and would leave GitHub reporting itself uninstalled
   * forever. Naming it outright costs one line per row and is pinned by
   * `mcp-catalogue.test.ts`, which fails if a token is not actually in its own
   * command.
   *
   * It is also what separates *installed* from *taken*: a server called `github`
   * whose command line does not contain this token is somebody else's server
   * wearing the same name, and overwriting it is not this store's business.
   */
  token: string
  inputs: readonly McpCatalogueInput[]
  origin: McpOrigin
  /**
   * Something true about this row that pressing Install does not fix.
   * Rendered verbatim on the row, above the button. `null` when there is none.
   */
  caveat: string | null
}

export type McpCatalogue = readonly McpCatalogueEntry[]

/* -------------------------------------------------------------- catalogue -- */

const ARCHIVED_NOTE =
  'This one now lives in modelcontextprotocol/servers-archived, which GitHub reports as an ' +
  'archived repository. It still installs and still runs; nobody is fixing it. The maintained ' +
  'reference servers published in the last month, this one has not.'

export const MCP_CATALOGUE: McpCatalogue = [
  /* --------------------------------------------- reference servers, node -- */
  {
    id: 'filesystem',
    name: 'filesystem',
    summary: 'Reads, writes and searches files, under directories you name and nowhere else.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem',
    licence: 'MIT',
    version: '2026.7.10',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-filesystem ${ROOT}',
    token: '@modelcontextprotocol/server-filesystem',
    inputs: [
      {
        key: 'ROOT',
        label: 'Directory it may touch',
        hint: 'An absolute path. It cannot read or write outside this, which is the point of naming it.',
        kind: 'path',
        into: 'arg',
        required: true,
      },
    ],
    origin: 'reference',
    caveat: null,
  },
  {
    id: 'memory',
    name: 'memory',
    summary: 'A knowledge graph the agent writes to and reads back, kept in one JSON file.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/memory',
    licence: 'MIT',
    version: '2026.7.4',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-memory',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-memory',
    token: '@modelcontextprotocol/server-memory',
    inputs: [],
    origin: 'reference',
    caveat: null,
  },
  {
    id: 'sequential-thinking',
    name: 'sequential-thinking',
    summary: 'Lets the agent break a problem into numbered steps it can revise as it goes.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking',
    licence: 'MIT',
    version: '2026.7.4',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-sequential-thinking',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-sequential-thinking',
    token: '@modelcontextprotocol/server-sequential-thinking',
    inputs: [],
    origin: 'reference',
    caveat: null,
  },
  {
    id: 'everything',
    name: 'everything',
    summary: 'The protocol’s own test server — one of every tool, resource and prompt kind.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/everything',
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-everything',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-everything',
    token: '@modelcontextprotocol/server-everything',
    inputs: [],
    origin: 'reference',
    caveat:
      'For checking that MCP works here, not for doing anything. Its tools are demonstrations — ' +
      'echo, add, a progress bar.',
  },

  /* ------------------------------------------- reference servers, python -- */
  {
    id: 'git',
    name: 'git',
    summary: 'Reads a repository’s history, diffs and branches, and can stage and commit.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/git',
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://pypi.org/project/mcp-server-git/',
    runtime: 'python',
    command: 'uvx mcp-server-git --repository ${REPO}',
    token: 'mcp-server-git',
    inputs: [
      {
        key: 'REPO',
        label: 'Repository',
        hint: 'The absolute path of a git working tree on this machine.',
        kind: 'path',
        into: 'arg',
        required: true,
      },
    ],
    origin: 'reference',
    caveat: 'It can commit. Point it at a repository you are willing to have written to.',
  },
  {
    id: 'fetch',
    name: 'fetch',
    summary: 'Fetches a URL and converts the page to markdown for the agent to read.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/fetch',
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://pypi.org/project/mcp-server-fetch/',
    runtime: 'python',
    command: 'uvx mcp-server-fetch',
    token: 'mcp-server-fetch',
    inputs: [],
    origin: 'reference',
    caveat: 'It reaches the open internet from this machine, at the agent’s choosing.',
  },
  {
    id: 'time',
    name: 'time',
    summary: 'The current time in any zone, and conversions between zones.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/time',
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://pypi.org/project/mcp-server-time/',
    runtime: 'python',
    command: 'uvx mcp-server-time',
    token: 'mcp-server-time',
    inputs: [],
    origin: 'reference',
    caveat: null,
  },

  /* -------------------------------------------------------- third party -- */
  {
    id: 'playwright',
    name: 'playwright',
    summary: 'Drives a real browser — clicks, types, reads the page as an accessibility tree.',
    homepage: 'https://github.com/microsoft/playwright-mcp',
    licence: 'Apache-2.0',
    version: '0.0.79',
    registry: 'https://www.npmjs.com/package/@playwright/mcp',
    runtime: 'node',
    command: 'npx -y @playwright/mcp@latest',
    token: '@playwright/mcp',
    inputs: [],
    origin: 'third-party',
    caveat:
      'The first run downloads a browser build, which is hundreds of megabytes and takes a while ' +
      'before the server answers anything.',
  },
  {
    id: 'github',
    name: 'github',
    summary: 'GitHub’s own server: issues, pull requests, code search, actions, releases.',
    homepage: 'https://github.com/github/github-mcp-server',
    licence: 'MIT',
    version: 'ghcr.io/github/github-mcp-server:latest',
    registry: 'https://github.com/github/github-mcp-server/pkgs/container/github-mcp-server',
    runtime: 'docker',
    command: 'docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server',
    token: 'ghcr.io/github/github-mcp-server',
    inputs: [
      {
        key: 'GITHUB_PERSONAL_ACCESS_TOKEN',
        label: 'Personal access token',
        hint: 'github.com/settings/personal-access-tokens/new — it can do whatever you grant it.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    caveat:
      'It runs in a container, so Docker has to be running as well as installed. The invocation ' +
      'here is the one GitHub’s own README gives for this app’s CLI.',
  },
  {
    id: 'notion',
    name: 'notion',
    summary: 'Notion’s own server: search, read and write pages and databases.',
    homepage: 'https://github.com/makenotion/notion-mcp-server',
    licence: 'MIT',
    version: '2.5.1',
    registry: 'https://www.npmjs.com/package/@notionhq/notion-mcp-server',
    runtime: 'node',
    command: 'npx -y @notionhq/notion-mcp-server',
    token: '@notionhq/notion-mcp-server',
    inputs: [
      {
        key: 'NOTION_TOKEN',
        label: 'Integration token',
        hint: 'From a Notion internal integration. It only sees pages you share with it.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    caveat: null,
  },
  {
    id: 'context7',
    name: 'context7',
    summary: 'Up-to-date documentation for a library, fetched by name and version.',
    homepage: 'https://github.com/upstash/context7',
    licence: 'MIT',
    version: '4.0.3',
    registry: 'https://www.npmjs.com/package/@upstash/context7-mcp',
    runtime: 'node',
    command: 'npx -y @upstash/context7-mcp',
    token: '@upstash/context7-mcp',
    inputs: [
      {
        key: 'CONTEXT7_API_KEY',
        label: 'API key',
        hint: 'Optional. Without one it works at a lower rate limit.',
        kind: 'secret',
        into: 'env',
        required: false,
      },
    ],
    origin: 'third-party',
    caveat: 'It sends the library name you ask about to Upstash’s service.',
  },
  {
    id: 'tavily',
    name: 'tavily',
    summary: 'Web search and page extraction through Tavily’s API.',
    homepage: 'https://github.com/tavily-ai/tavily-mcp',
    licence: 'MIT',
    version: '0.2.22',
    registry: 'https://www.npmjs.com/package/tavily-mcp',
    runtime: 'node',
    command: 'npx -y tavily-mcp',
    token: 'tavily-mcp',
    inputs: [
      {
        key: 'TAVILY_API_KEY',
        label: 'API key',
        hint: 'app.tavily.com — the free tier is metered, so it can run out.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    caveat: 'Every search leaves this machine and is billed to that key.',
  },
  {
    id: 'firecrawl',
    name: 'firecrawl',
    summary: 'Scrapes and crawls sites, returning markdown, through Firecrawl’s API.',
    homepage: 'https://github.com/firecrawl/firecrawl-mcp-server',
    licence: 'MIT',
    version: '3.24.0',
    registry: 'https://www.npmjs.com/package/firecrawl-mcp',
    runtime: 'node',
    command: 'npx -y firecrawl-mcp',
    token: 'firecrawl-mcp',
    inputs: [
      {
        key: 'FIRECRAWL_API_KEY',
        label: 'API key',
        hint: 'firecrawl.dev. Its README also documents FIRECRAWL_API_URL for a self-hosted instance.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    caveat: 'Pages are fetched by Firecrawl’s servers, not by this machine, and are billed to that key.',
  },

  /* ---------------------------------------------------------- archived -- */
  {
    id: 'sqlite',
    name: 'sqlite',
    summary: 'Queries a SQLite database file and describes its schema.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/sqlite',
    licence: 'MIT',
    version: '2025.4.25',
    registry: 'https://pypi.org/project/mcp-server-sqlite/',
    runtime: 'python',
    command: 'uvx mcp-server-sqlite --db-path ${DB}',
    token: 'mcp-server-sqlite',
    inputs: [
      {
        key: 'DB',
        label: 'Database file',
        hint: 'The absolute path of a .sqlite or .db file. It is created if it does not exist.',
        kind: 'path',
        into: 'arg',
        required: true,
      },
    ],
    origin: 'reference-archived',
    caveat: ARCHIVED_NOTE + ' It can write, not only read.',
  },
  {
    id: 'postgres',
    name: 'postgres',
    summary: 'Runs read-only SQL against a Postgres database and reads its schema.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/postgres',
    licence: 'MIT',
    version: '0.6.2',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-postgres',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-postgres ${DATABASE_URL}',
    token: '@modelcontextprotocol/server-postgres',
    inputs: [
      {
        key: 'DATABASE_URL',
        label: 'Connection string',
        hint: 'postgresql://user:password@host/database. It goes on the command line, so it is in the config in plain text.',
        kind: 'text',
        into: 'arg',
        required: true,
      },
    ],
    origin: 'reference-archived',
    caveat:
      ARCHIVED_NOTE +
      ' And the connection string is an argument, not a variable, so a password in it cannot be ' +
      'kept out of the configuration file.',
  },
  {
    id: 'slack',
    name: 'slack',
    summary: 'Reads channels and threads in a Slack workspace and posts messages.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/slack',
    licence: 'MIT',
    version: '2025.4.25',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-slack',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-slack',
    token: '@modelcontextprotocol/server-slack',
    inputs: [
      {
        key: 'SLACK_BOT_TOKEN',
        label: 'Bot token',
        hint: 'Starts xoxb-. From a Slack app installed into the workspace.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
      {
        key: 'SLACK_TEAM_ID',
        label: 'Team id',
        hint: 'Starts T. The workspace’s id, not its name.',
        kind: 'text',
        into: 'env',
        required: true,
      },
    ],
    origin: 'reference-archived',
    caveat: ARCHIVED_NOTE + ' It can post as the bot, not only read.',
  },
  {
    id: 'brave-search',
    name: 'brave-search',
    summary: 'Web and local search through the Brave Search API.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/brave-search',
    licence: 'MIT',
    version: '0.6.2',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-brave-search',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-brave-search',
    token: '@modelcontextprotocol/server-brave-search',
    inputs: [
      {
        key: 'BRAVE_API_KEY',
        label: 'API key',
        hint: 'brave.com/search/api — there is a free tier.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'reference-archived',
    caveat: ARCHIVED_NOTE,
  },
  {
    id: 'puppeteer',
    name: 'puppeteer',
    summary: 'Drives a headless Chrome — navigate, click, type, screenshot.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/puppeteer',
    licence: 'MIT',
    version: '2025.5.12',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-puppeteer',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-puppeteer',
    token: '@modelcontextprotocol/server-puppeteer',
    inputs: [],
    origin: 'reference-archived',
    caveat:
      ARCHIVED_NOTE +
      ' The playwright row above is the maintained answer to the same question — install that one ' +
      'unless you specifically want this.',
  },
]

/** One entry by id, or null. Exported because both the view and the install use it. */
export function catalogueEntry(id: unknown, catalogue: McpCatalogue = MCP_CATALOGUE): McpCatalogueEntry | null {
  if (typeof id !== 'string') return null
  return catalogue.find((entry) => entry.id === id) ?? null
}

/**
 * Every runtime any row needs, once.
 *
 * The store probes this set rather than one binary per row: three `which` calls
 * for nineteen rows, and the answer is a property of the machine rather than of
 * the row.
 */
export function requiredRuntimes(catalogue: McpCatalogue = MCP_CATALOGUE): McpRuntime[] {
  return [...new Set(catalogue.map((entry) => entry.runtime))]
}

/**
 * Every environment variable name any row could take a value for.
 *
 * This is what gets intersected with the login shell's names — see
 * `platform/login-env.ts`. Only `env` inputs: an `arg` value is part of the
 * command line and cannot come from the environment, so offering it would be a
 * control that does nothing.
 */
export function environmentKeys(catalogue: McpCatalogue = MCP_CATALOGUE): string[] {
  const keys = new Set<string>()
  for (const entry of catalogue) {
    for (const input of entry.inputs) {
      if (input.into === 'env') keys.add(input.key)
    }
  }
  return [...keys]
}
