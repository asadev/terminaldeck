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
 * **A row was dropped for failing this**, and has since come back. On
 * 2026-08-22 `@sentry/mcp-server` was real and its README named no environment
 * variable at all, so there was no honest way to fill in what it needs; guessing
 * `SENTRY_ACCESS_TOKEN` would have produced a row that installs, starts and
 * fails on its first call. On **2026-08-23** the same README names
 * `SENTRY_ACCESS_TOKEN` outright, in three places, so the row exists — and it is
 * worth noticing that the fix was the project documenting itself rather than
 * this file relaxing.
 *
 * ## The widening round, 2026-08-23
 *
 * Twenty-one rows were added the day after, against the same registries and by
 * the same rules, because a store of eighteen open-source servers was not what
 * was asked for:
 *
 *   > *"maybe some other tools paid ones too not just open source … and also all
 *   > other regular tools too like google's ones or like this."*
 *
 * What that round is actually worth is the candidates that did **not** survive
 * it, because every one of them would have looked perfectly plausible in this
 * file:
 *
 *  - **Linear**'s widely-documented `https://mcp.linear.app/sse` answers `404`.
 *    Its `/mcp` endpoint answers `401`, which is a live server asking to be
 *    signed in to, so that is the one on the row.
 *  - **Cloudflare**'s `docs.` and `observability.` `/sse` endpoints both answer
 *    `410 Gone`. Their `/mcp` siblings answer, so the row points there.
 *  - **Browserbase**'s server repository is `archived: true` on GitHub. There is
 *    no row for it at all rather than a row quietly pointing at an abandoned
 *    one.
 *  - **Exa**'s npm package is still published and its own README no longer
 *    documents it; the hosted endpoint replaced it, so the row is the endpoint.
 *
 * Each was checked by asking the thing itself — an HTTP request to the endpoint,
 * `api.github.com` for the archived flag — rather than by reading a blog post
 * about it.
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

/**
 * Which shelf a row sits on, so thirty-nine servers browse instead of scrolling.
 *
 * ## Why these nine and not the obvious ones
 *
 * The tempting split is by **runtime** — npx, uvx, docker — because that is a
 * field already on every row and it partitions perfectly. It is also useless:
 * nobody has ever wanted "the Python ones". The other tempting split is by
 * **origin**, and that one is already a facet of its own, so making it the
 * shelves too would mean one fact drawn twice and a store with a single axis.
 *
 * These are by **what the server does for you**, which is the question somebody
 * opens a store with. Four were added in the widening round — *Issues, projects
 * and tickets*, *Hosting, cloud and what is running*, *Design* and *Payments and
 * customers* — because Jira, Cloudflare, Figma and Stripe had no honest home
 * among the first nine, and a shelf called *Other* would have been the store
 * admitting it had stopped thinking. *Chat and messaging* became *Mail, chat and
 * calendars* the same day, because Gmail and Calendar arrived and the old name
 * would have made a person looking for their inbox scroll past it. Each row names one and only one, for the reason
 * `browser-extension-catalogue.ts` gives about its own: *"a row that appeared
 * under three headings would make a catalogue of thirty-six look like a
 * catalogue of sixty, and a store overstating its own size is the first thing
 * that makes the rest of it unbelievable."*
 *
 * Two shelves hold one row each — `files` and `messaging` — and they were left
 * alone rather than merged into a bin called *Other*. `filesystem` is the server
 * most people install first and folding it in with the SQL ones would bury it
 * under a heading nobody looking for it would read; `slack` has no honest
 * neighbour in this catalogue and inventing one would be a shelf that means
 * nothing the day a second chat server arrives.
 */
export type McpCategory =
  | 'files'
  | 'code'
  | 'work'
  | 'data'
  | 'cloud'
  | 'web'
  | 'browser'
  | 'knowledge'
  | 'design'
  | 'business'
  | 'thinking'
  | 'messaging'
  | 'utility'

/** The shelves, in the order the store draws them, with the name each wears. */
export const MCP_CATEGORIES: readonly { id: McpCategory; name: string }[] = [
  { id: 'files', name: 'Files on this machine' },
  { id: 'code', name: 'Code and repositories' },
  { id: 'work', name: 'Issues, projects and tickets' },
  { id: 'data', name: 'Databases' },
  { id: 'cloud', name: 'Hosting, cloud and what is running' },
  { id: 'web', name: 'Searching and reading the web' },
  { id: 'browser', name: 'Driving a browser' },
  { id: 'knowledge', name: 'Notes and documentation' },
  { id: 'design', name: 'Design' },
  { id: 'business', name: 'Payments and customers' },
  { id: 'thinking', name: 'What the agent remembers' },
  { id: 'messaging', name: 'Mail, chat and calendars' },
  { id: 'utility', name: 'Time, testing and odds and ends' },
]

/**
 * Where the row comes from, which is a fact about its maintenance.
 *
 * ## Why `vendor` and `hosted` were added
 *
 * Asad, widening the catalogue: *"all other regular tools too like google's ones
 * or like this"*. Once the store holds Stripe's own server next to somebody's
 * weekend project, *third party* stops meaning anything — it was answering
 * *"who is not the protocol's reference implementation"*, which is a question
 * about this catalogue's history rather than about the row.
 *
 * `hosted` is a different kind of fact again and the one most worth saying out
 * loud: the row installs a small local proxy (`mcp-remote`) and the server
 * itself runs on the vendor's machines. Nothing about it is on this disk, the
 * tools it offers can change without any version here changing, and what the
 * agent sends it leaves this machine. That is not a licence question and it is
 * not a maintenance question — it is *where does the code that answers actually
 * run*, and the browser store would never let a row stay quiet about that.
 */
export type McpOrigin =
  /** In `modelcontextprotocol/servers` today. */
  | 'reference'
  /** In `modelcontextprotocol/servers-archived`, a repository GitHub reports archived. */
  | 'reference-archived'
  /** Published by the company whose product it talks to, and it runs here. */
  | 'vendor'
  /** The company's own server, running on their machines. This row installs a proxy to it. */
  | 'hosted'
  /** Somebody else's project, maintained by them. */
  | 'third-party'

/**
 * What using the server costs, once it is installed. See `store/storefront.ts`
 * for the argument; this is the main process's copy of the same four values.
 *
 * The catalogue is nearly all MIT and that is now the *least* useful thing on a
 * row: `tavily-mcp` is MIT and does nothing without a key that is billed, and
 * `@sentry/mcp-server` is not open source at all. Licence answers *may I read
 * the code*; this answers *will it work tomorrow without a card*, and they are
 * not the same question.
 */
export type McpCost =
  /** Nothing to pay and nobody to sign up with. */
  | 'free'
  /** Free to use; it does nothing until you sign in somewhere, and that account is free. */
  | 'account'
  /** Free to a limit, then billed. A free tier you can genuinely start on. */
  | 'metered'
  /** Money before it does its job at all. No usable free tier. */
  | 'paid'

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
  /** Which shelf it sits on. One, never three. */
  category: McpCategory
  /**
   * Words somebody might type that are nowhere in the name or the summary.
   *
   * `postgres` is called `postgres`, but nobody types that looking for *sql*,
   * and `brave-search` says nothing about *web search* in either field. Search
   * over name and summary alone answers those with an empty list, which reads as
   * a store that does not have the thing rather than one that was asked wrong.
   */
  tags: readonly string[]
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
  /** What using it costs. See {@link McpCost}. */
  cost: McpCost
  /**
   * The price reality in one sentence, on the row, **before** the button.
   *
   * Required for everything that is not {@link McpCost.free}, and
   * `mcp-catalogue.test.ts` fails a row that skips it. The rule it enforces is
   * the one Asad set: *never imply free when a key costs money*. `free` may
   * carry one too, and two rows do — Honey's browser-store sibling has the same
   * shape of fact, where nothing is charged to you and somebody is still being
   * paid.
   */
  costNote: string
  /**
   * Which mark the store draws on this row, as a key into
   * `renderer/store/logo-data.ts`.
   *
   * A key rather than the picture, for the reason `ExtensionEntry.logo` gives:
   * the row crosses the IPC bridge every time the store opens, and the picture
   * is already in the renderer's own bundle.
   *
   * Not a per-row key either. Six of the rows below share
   * `modelcontextprotocol`, and that is the true answer rather than a shortcut:
   * `filesystem`, `memory`, `sequential-thinking`, `everything`, `fetch` and
   * `time` are one project's reference servers, published together out of one
   * repository, and the Model Context Protocol mark identifies all six exactly
   * as well as it identifies any of them. Drawing six different invented marks
   * would be this store making up six brands that do not exist.
   *
   * **Optional, and it stays optional** — see `ExtensionEntry.logo`. A row with
   * none draws the monogram in `StoreLogo.tsx`.
   *
   * `node scripts/store-logos.mjs` is what fetched the pictures and what
   * refreshes them; `--check` names any whose upstream bytes have moved. The
   * marks are third-party trademarks shown to identify the products, and the
   * generated module's header carries the notice and the removal undertaking.
   */
  logo?: string
  /**
   * Something true about this row that pressing Install does not fix.
   * Rendered verbatim on the row, above the button. `null` when there is none.
   */
  caveat: string | null
}

export type McpCatalogue = readonly McpCatalogueEntry[]

/* -------------------------------------------------------------- catalogue -- */

/**
 * What a `hosted` row is actually installing, said on every one of them.
 *
 * The row's licence and version are `mcp-remote`'s, because those are the only
 * bytes that reach this machine. Printing the vendor's name next to a licence
 * field and leaving it at that would suggest this app had checked something
 * about the server, and it has not: there is nothing to check, because the
 * server is not here.
 */
const HOSTED_NOTE =
  'What installs here is mcp-remote, a small MIT proxy — the licence and version on this row are ' +
  'its, because they are the only bytes that land on this machine. The server itself runs on the ' +
  'vendor’s, is not published, and its tools can change without any version here changing. The ' +
  'first run opens a browser to sign you in.'

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
    category: 'files',
    tags: ['files', 'directory', 'folder', 'read', 'write', 'search', 'disk', 'local'],
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
    logo: 'modelcontextprotocol',
    cost: 'free',
    costNote: '',
    caveat: null,
  },
  {
    id: 'memory',
    name: 'memory',
    summary: 'A knowledge graph the agent writes to and reads back, kept in one JSON file.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/memory',
    category: 'thinking',
    tags: ['knowledge graph', 'remember', 'recall', 'notes', 'entities'],
    licence: 'MIT',
    version: '2026.7.4',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-memory',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-memory',
    token: '@modelcontextprotocol/server-memory',
    inputs: [],
    origin: 'reference',
    logo: 'modelcontextprotocol',
    cost: 'free',
    costNote: '',
    caveat: null,
  },
  {
    id: 'sequential-thinking',
    name: 'sequential-thinking',
    summary: 'Lets the agent break a problem into numbered steps it can revise as it goes.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking',
    category: 'thinking',
    tags: ['reasoning', 'plan', 'steps', 'think', 'revise'],
    licence: 'MIT',
    version: '2026.7.4',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-sequential-thinking',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-sequential-thinking',
    token: '@modelcontextprotocol/server-sequential-thinking',
    inputs: [],
    origin: 'reference',
    logo: 'modelcontextprotocol',
    cost: 'free',
    costNote: '',
    caveat: null,
  },
  {
    id: 'everything',
    name: 'everything',
    summary: 'The protocol’s own test server — one of every tool, resource and prompt kind.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/everything',
    category: 'utility',
    tags: ['test', 'demo', 'example', 'protocol', 'reference'],
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-everything',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-everything',
    token: '@modelcontextprotocol/server-everything',
    inputs: [],
    origin: 'reference',
    logo: 'modelcontextprotocol',
    cost: 'free',
    costNote: '',
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
    category: 'code',
    tags: ['repository', 'commit', 'diff', 'branch', 'version control', 'staging'],
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
    logo: 'git',
    cost: 'free',
    costNote: '',
    caveat: 'It can commit. Point it at a repository you are willing to have written to.',
  },
  {
    id: 'fetch',
    name: 'fetch',
    summary: 'Fetches a URL and converts the page to markdown for the agent to read.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/fetch',
    category: 'web',
    tags: ['url', 'http', 'markdown', 'read a page', 'scrape'],
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://pypi.org/project/mcp-server-fetch/',
    runtime: 'python',
    command: 'uvx mcp-server-fetch',
    token: 'mcp-server-fetch',
    inputs: [],
    origin: 'reference',
    logo: 'modelcontextprotocol',
    cost: 'free',
    costNote: '',
    caveat: 'It reaches the open internet from this machine, at the agent’s choosing.',
  },
  {
    id: 'time',
    name: 'time',
    summary: 'The current time in any zone, and conversions between zones.',
    homepage: 'https://github.com/modelcontextprotocol/servers/tree/main/src/time',
    category: 'utility',
    tags: ['clock', 'timezone', 'date', 'convert', 'utc'],
    licence: 'MIT',
    version: '2026.8.18',
    registry: 'https://pypi.org/project/mcp-server-time/',
    runtime: 'python',
    command: 'uvx mcp-server-time',
    token: 'mcp-server-time',
    inputs: [],
    origin: 'reference',
    logo: 'modelcontextprotocol',
    cost: 'free',
    costNote: '',
    caveat: null,
  },

  /* -------------------------------------------------------- third party -- */
  {
    id: 'playwright',
    name: 'playwright',
    summary: 'Drives a real browser — clicks, types, reads the page as an accessibility tree.',
    homepage: 'https://github.com/microsoft/playwright-mcp',
    category: 'browser',
    tags: [
      'browser', 'automation', 'click', 'type', 'screenshot', 'accessibility tree', 'end to end',
    ],
    licence: 'Apache-2.0',
    version: '0.0.79',
    registry: 'https://www.npmjs.com/package/@playwright/mcp',
    runtime: 'node',
    command: 'npx -y @playwright/mcp@latest',
    token: '@playwright/mcp',
    inputs: [],
    logo: 'playwright',
    origin: 'vendor',
    cost: 'free',
    costNote: '',
    caveat:
      'The first run downloads a browser build, which is hundreds of megabytes and takes a while ' +
      'before the server answers anything.',
  },
  {
    id: 'github',
    name: 'github',
    summary: 'GitHub’s own server: issues, pull requests, code search, actions, releases.',
    homepage: 'https://github.com/github/github-mcp-server',
    category: 'code',
    tags: ['issues', 'pull requests', 'repository', 'actions', 'releases', 'code search', 'pr'],
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
    logo: 'github',
    origin: 'vendor',
    cost: 'account',
    costNote:
      'Free. It needs a GitHub personal access token, and a free GitHub account can make one — ' +
      'what the token can do is whatever you grant it.',
    caveat:
      'It runs in a container, so Docker has to be running as well as installed. The invocation ' +
      'here is the one GitHub’s own README gives for this app’s CLI.',
  },
  {
    id: 'notion',
    name: 'notion',
    summary: 'Notion’s own server: search, read and write pages and databases.',
    homepage: 'https://github.com/makenotion/notion-mcp-server',
    category: 'knowledge',
    tags: ['notes', 'wiki', 'pages', 'database', 'documents'],
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
    logo: 'notion',
    origin: 'vendor',
    cost: 'account',
    costNote:'Free. It needs an integration token, which Notion’s free personal plan can create.',
    caveat: null,
  },
  {
    id: 'context7',
    name: 'context7',
    summary: 'Up-to-date documentation for a library, fetched by name and version.',
    homepage: 'https://github.com/upstash/context7',
    category: 'knowledge',
    tags: ['documentation', 'docs', 'library', 'api reference', 'versions'],
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
    logo: 'context7',
    origin: 'vendor',
    cost: 'free',
    costNote:
      'Free without a key, at Upstash’s lower rate limit. The optional key comes from Upstash ' +
      'and this catalogue did not check what one costs.',
    caveat: 'It sends the library name you ask about to Upstash’s service.',
  },
  {
    id: 'tavily',
    name: 'tavily',
    summary: 'Web search and page extraction through Tavily’s API.',
    homepage: 'https://github.com/tavily-ai/tavily-mcp',
    category: 'web',
    tags: ['search', 'web search', 'extract', 'research', 'answers'],
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
    logo: 'tavily',
    origin: 'vendor',
    cost: 'metered',
    costNote:
      'Free to install and it does nothing free: every search is billed to the key. Tavily’s ' +
      'free tier is a metered allowance — the row’s own field says so, because it runs out.',
    caveat: 'Every search leaves this machine and is billed to that key.',
  },
  {
    id: 'firecrawl',
    name: 'firecrawl',
    summary: 'Scrapes and crawls sites, returning markdown, through Firecrawl’s API.',
    homepage: 'https://github.com/firecrawl/firecrawl-mcp-server',
    category: 'web',
    tags: ['scrape', 'crawl', 'markdown', 'website', 'extract'],
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
    logo: 'firecrawl',
    origin: 'vendor',
    cost: 'metered',
    costNote:
      'Free to install and metered to use. Pages are fetched by Firecrawl’s servers and billed ' +
      'to the key, so a crawl left running is a bill.',
    caveat: 'Pages are fetched by Firecrawl’s servers, not by this machine, and are billed to that key.',
  },

  /* ------------------------------------ what people actually asked for, 2026-08-23 -- */
  /*
   * The widening round. Asad, re-reading both stores:
   *
   *   > *"should allow custom tools and store, and maybe some other tools paid
   *   > ones too not just open source … and also all other regular tools too
   *   > like google's ones or like this."*
   *
   * Every row below was checked on **2026-08-23**, and the checking is what the
   * section is worth: four candidates did not survive it. Linear's documented
   * `/sse` endpoint answers 404 and its `/mcp` one answers 401, so this store
   * points at the second; both of Cloudflare's `/sse` endpoints answer 410 Gone;
   * Browserbase's server repository is archived, so it is not here at all; and
   * Exa's npm package has been superseded by its own hosted endpoint, which its
   * README now documents instead.
   */
  {
    id: 'chrome-devtools',
    name: 'chrome-devtools',
    summary: 'Google’s own server for Chrome: navigate and click a real browser, and read performance traces, console output and network requests back.',
    homepage: 'https://github.com/ChromeDevTools/chrome-devtools-mcp',
    category: 'browser',
    tags: ['google', 'chrome', 'devtools', 'performance', 'trace', 'console', 'network'],
    licence: 'Apache-2.0',
    version: '1.7.0',
    registry: 'https://www.npmjs.com/package/chrome-devtools-mcp',
    runtime: 'node',
    command: 'npx -y chrome-devtools-mcp@latest',
    token: 'chrome-devtools-mcp',
    inputs: [],
    origin: 'vendor',
    cost: 'free',
    costNote: '',
    caveat:
      'It drives a real Chrome on this machine. Whatever it does there — pages, cookies, the ' +
      'sessions you are signed into — it does in that browser, not in a sandbox.',
  },
  {
    id: 'stripe',
    name: 'stripe',
    summary: 'Stripe’s own server: customers, payments, invoices, subscriptions and refunds.',
    homepage: 'https://github.com/stripe/ai/tree/main/tools/modelcontextprotocol',
    category: 'business',
    tags: ['payments', 'billing', 'invoices', 'subscriptions', 'refunds', 'customers', 'checkout'],
    licence: 'MIT',
    version: '0.3.3',
    registry: 'https://www.npmjs.com/package/@stripe/mcp',
    runtime: 'node',
    command: 'npx -y @stripe/mcp',
    token: '@stripe/mcp',
    inputs: [
      {
        key: 'STRIPE_SECRET_KEY',
        label: 'Secret key',
        hint: 'dashboard.stripe.com/apikeys. Its README names this variable. A restricted key is what decides which tools work — the server can do whatever the key can.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'vendor',
    cost: 'account',
    costNote:
      'The server is free and a Stripe account costs nothing to open; Stripe takes its fee per ' +
      'payment, not for this.',
    caveat:
      'The key is the whole of its authority. A live secret key means every tool acts on real ' +
      'money in a real account — Stripe’s test keys exist for precisely this situation.',
  },
  {
    id: 'hubspot',
    name: 'hubspot',
    summary: 'HubSpot’s own server: contacts, companies, deals, tickets and the properties on them.',
    homepage: 'https://developers.hubspot.com/mcp',
    category: 'business',
    tags: ['crm', 'contacts', 'deals', 'companies', 'tickets', 'sales', 'pipeline'],
    licence: 'MIT',
    version: '0.4.0',
    registry: 'https://www.npmjs.com/package/@hubspot/mcp-server',
    runtime: 'node',
    command: 'npx -y @hubspot/mcp-server',
    token: '@hubspot/mcp-server',
    inputs: [
      {
        key: 'PRIVATE_APP_ACCESS_TOKEN',
        label: 'Private app token',
        hint: 'Settings → Integrations → Private Apps in HubSpot. Its README names this variable; the scopes you tick are what it can do.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'vendor',
    cost: 'account',
    costNote:
      'Free. A HubSpot free CRM account can create the private app this needs; the paid tiers ' +
      'buy seats and features, not this server.',
    caveat:
      'HubSpot ships this as a beta, under its Early Adopter Program terms, and the version here ' +
      'was published in June 2025 — it is their package, and it is not moving quickly.',
  },
  {
    id: 'sentry',
    name: 'sentry',
    summary: 'Sentry’s own server: issues, events, releases and the stack traces underneath them.',
    homepage: 'https://github.com/getsentry/sentry-mcp',
    category: 'cloud',
    tags: ['errors', 'issues', 'stack trace', 'monitoring', 'releases', 'crash', 'exceptions'],
    licence: 'FSL-1.1-ALv2',
    version: '0.37.0',
    registry: 'https://www.npmjs.com/package/@sentry/mcp-server',
    runtime: 'node',
    command: 'npx -y @sentry/mcp-server',
    token: '@sentry/mcp-server',
    inputs: [
      {
        key: 'SENTRY_ACCESS_TOKEN',
        label: 'Auth token',
        hint: 'sentry.io → Settings → Auth Tokens. Its README names this variable.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
      {
        key: 'SENTRY_HOST',
        label: 'Self-hosted host',
        hint: 'Only for a Sentry you run yourself. Left blank it talks to sentry.io.',
        kind: 'text',
        into: 'env',
        required: false,
      },
    ],
    origin: 'vendor',
    cost: 'account',
    costNote:
      'Free. Sentry’s developer plan costs nothing and can issue the token; the paid plans buy ' +
      'event volume, not this server.',
    caveat:
      'The one row here that is not open source. FSL-1.1-ALv2 is Sentry’s Functional Source ' +
      'License: the code is readable and it becomes Apache-2.0 two years after each release, ' +
      'which is a different thing from being free software today.',
  },
  {
    id: 'azure',
    name: 'azure',
    summary: 'Microsoft’s own server for Azure: subscriptions, resource groups, storage, databases and logs.',
    homepage: 'https://github.com/microsoft/mcp',
    category: 'cloud',
    tags: ['microsoft', 'cloud', 'subscription', 'resource group', 'storage', 'kusto', 'deployment'],
    licence: 'MIT',
    version: '3.0.0-beta.37',
    registry: 'https://www.npmjs.com/package/@azure/mcp',
    runtime: 'node',
    command: 'npx -y @azure/mcp@latest server start',
    token: '@azure/mcp',
    inputs: [],
    origin: 'vendor',
    cost: 'metered',
    costNote:
      'The server is free; Azure is not. Everything it reaches sits on a subscription that ' +
      'bills, and a tool that creates a resource has created a billable one.',
    caveat:
      'The version published on the day this was checked is a beta — 3.0.0-beta.37 — and ' +
      'Microsoft ships it as one. It signs in as whatever Azure identity this machine already ' +
      'has, so it can do whatever that account can.',
  },
  {
    id: 'cloudflare',
    name: 'cloudflare',
    summary: 'Cloudflare’s own hosted server for Workers bindings — KV, R2, D1 and Hyperdrive.',
    homepage: 'https://github.com/cloudflare/mcp-server-cloudflare',
    category: 'cloud',
    tags: ['workers', 'kv', 'r2', 'd1', 'hyperdrive', 'edge', 'cdn'],
    licence: 'MIT',
    version: '0.1.43',
    registry: 'https://www.npmjs.com/package/mcp-remote',
    runtime: 'node',
    command: 'npx -y mcp-remote https://bindings.mcp.cloudflare.com/mcp',
    token: 'bindings.mcp.cloudflare.com',
    inputs: [],
    origin: 'hosted',
    cost: 'account',
    costNote:
      'Free. A Cloudflare account costs nothing; what you build on it is billed by Cloudflare’s ' +
      'own plans rather than by this.',
    caveat:
      HOSTED_NOTE +
      ' Cloudflare’s /sse endpoints have been retired — the two this catalogue tried answer 410 ' +
      'Gone — so this row points at the /mcp one, which answered on the day it was checked.',
  },
  {
    id: 'supabase',
    name: 'supabase',
    summary: 'Supabase’s own server: tables, migrations, edge functions and project settings.',
    homepage: 'https://github.com/supabase/mcp',
    category: 'data',
    tags: ['postgres', 'database', 'sql', 'migrations', 'edge functions', 'backend', 'project'],
    licence: 'Apache-2.0',
    version: '0.11.0',
    registry: 'https://www.npmjs.com/package/@supabase/mcp-server-supabase',
    runtime: 'node',
    command: 'npx -y @supabase/mcp-server-supabase --read-only --project-ref ${PROJECT_REF}',
    token: '@supabase/mcp-server-supabase',
    inputs: [
      {
        key: 'SUPABASE_ACCESS_TOKEN',
        label: 'Personal access token',
        hint: 'supabase.com/dashboard/account/tokens. The server’s own source reads this name.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
      {
        key: 'PROJECT_REF',
        label: 'Project reference',
        hint: 'The reference in the project’s dashboard URL. Naming one holds the server to that project instead of the whole account.',
        kind: 'text',
        into: 'arg',
        required: true,
      },
    ],
    origin: 'vendor',
    cost: 'account',
    costNote:
      'Free. Supabase’s free tier can issue the token and hold the project; its paid plans buy ' +
      'database size, not this.',
    caveat:
      '--read-only is on that command line on purpose: take it off and the same token can write ' +
      'to and migrate a live database. Supabase now also runs a hosted server at ' +
      'mcp.supabase.com — this row is the local one, which is what this store can write a ' +
      'command for.',
  },
  {
    id: 'mongodb',
    name: 'mongodb',
    summary: 'MongoDB’s own server: collections, documents, indexes and aggregations.',
    homepage: 'https://github.com/mongodb-js/mongodb-mcp-server',
    category: 'data',
    tags: ['database', 'nosql', 'documents', 'collections', 'aggregation', 'atlas', 'query'],
    licence: 'Apache-2.0',
    version: '2.1.0',
    registry: 'https://www.npmjs.com/package/mongodb-mcp-server',
    runtime: 'node',
    command: 'npx -y mongodb-mcp-server --readOnly',
    token: 'mongodb-mcp-server',
    inputs: [
      {
        key: 'MDB_MCP_CONNECTION_STRING',
        label: 'Connection string',
        hint: 'mongodb:// or a mongodb+srv:// Atlas string. Its README names this variable; a password inside it is written into the configuration.',
        kind: 'text',
        into: 'env',
        required: true,
      },
    ],
    origin: 'vendor',
    cost: 'free',
    costNote:
      'The server is free and so is a MongoDB running on this machine. A hosted Atlas cluster is ' +
      'Atlas’s own price, and its free tier can serve this.',
    caveat:
      '--readOnly is on that command line on purpose: without it, the same connection string can ' +
      'drop a collection.',
  },
  {
    id: 'postgres-mcp',
    name: 'postgres-mcp',
    summary: 'A maintained Postgres server: SQL, schema, index advice and slow-query analysis.',
    homepage: 'https://github.com/crystaldba/postgres-mcp',
    category: 'data',
    tags: ['sql', 'postgresql', 'database', 'query', 'index', 'explain', 'tuning', 'maintained'],
    licence: 'MIT',
    version: '0.3.0',
    registry: 'https://pypi.org/project/postgres-mcp/',
    runtime: 'python',
    command: 'uvx postgres-mcp --access-mode=restricted',
    token: 'postgres-mcp',
    inputs: [
      {
        key: 'DATABASE_URI',
        label: 'Connection string',
        hint: 'postgresql://user:password@host/database. Its README names this variable — and unlike the archived postgres row below, that puts the password in a variable rather than on the command line.',
        kind: 'text',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    cost: 'free',
    costNote: '',
    caveat:
      '--access-mode=restricted is on that command line on purpose: it holds the server to ' +
      'read-only, and taking it off lets the same connection string write.',
  },
  {
    id: 'airtable',
    name: 'airtable',
    summary: 'Reads and writes Airtable bases — records, fields and table schemas.',
    homepage: 'https://github.com/domdomegg/airtable-mcp-server',
    category: 'data',
    tags: ['airtable', 'base', 'records', 'spreadsheet', 'table', 'rows'],
    licence: 'MIT',
    version: '1.14.0',
    registry: 'https://www.npmjs.com/package/airtable-mcp-server',
    runtime: 'node',
    command: 'npx -y airtable-mcp-server',
    token: 'airtable-mcp-server',
    inputs: [
      {
        key: 'AIRTABLE_API_KEY',
        label: 'Personal access token',
        hint: 'airtable.com/create/tokens. Its README names this variable; the scopes you grant are what it can do.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    cost: 'account',
    costNote:
      'Free. Airtable’s free plan can issue the token; its paid plans buy records and ' +
      'automations, not this.',
    caveat: 'It writes as well as reads, and the token’s scopes are the only limit on that.',
  },
  {
    id: 'bigquery',
    name: 'bigquery',
    summary: 'Runs SQL against BigQuery and describes the datasets and tables in a project.',
    homepage: 'https://github.com/LucasHild/mcp-server-bigquery',
    category: 'data',
    tags: ['google', 'sql', 'warehouse', 'query', 'dataset', 'analytics', 'gcp'],
    licence: 'MIT',
    version: '0.3.2',
    registry: 'https://pypi.org/project/mcp-server-bigquery/',
    runtime: 'python',
    command: 'uvx mcp-server-bigquery --project ${PROJECT} --location ${LOCATION}',
    token: 'mcp-server-bigquery',
    inputs: [
      {
        key: 'PROJECT',
        label: 'Project id',
        hint: 'The Google Cloud project that owns the datasets.',
        kind: 'text',
        into: 'arg',
        required: true,
      },
      {
        key: 'LOCATION',
        label: 'Location',
        hint: 'Where the datasets live — US, EU, europe-west2.',
        kind: 'text',
        into: 'arg',
        required: true,
      },
    ],
    origin: 'third-party',
    cost: 'metered',
    costNote:
      'The server is free; BigQuery bills by bytes scanned. A query the agent writes badly is a ' +
      'query you are billed for, and the free monthly terabyte is all that stands between them.',
    caveat:
      'Not Google’s own — LucasHild’s, MIT, and its last commit when this row was checked was ' +
      'March 2026. It signs in with this machine’s Google Cloud credentials.',
  },
  {
    id: 'google-analytics',
    name: 'google-analytics',
    summary: 'Google’s own server for Analytics 4 — reports, dimensions and metrics from a property.',
    homepage: 'https://github.com/googleanalytics/google-analytics-mcp',
    category: 'data',
    tags: ['google', 'analytics', 'ga4', 'reports', 'traffic', 'metrics', 'dimensions'],
    licence: 'Apache-2.0',
    version: '0.7.0',
    registry: 'https://pypi.org/project/analytics-mcp/',
    runtime: 'python',
    command: 'uvx analytics-mcp',
    token: 'analytics-mcp',
    inputs: [
      {
        key: 'GOOGLE_APPLICATION_CREDENTIALS',
        label: 'Credentials file',
        hint: 'Optional. Left blank it uses whatever `gcloud auth application-default login` set up on this machine.',
        kind: 'path',
        into: 'env',
        required: false,
      },
      {
        key: 'GOOGLE_PROJECT_ID',
        label: 'Google Cloud project',
        hint: 'Optional. The project the credentials belong to — its README’s own configuration sets this beside the credentials file.',
        kind: 'text',
        into: 'env',
        required: false,
      },
    ],
    origin: 'vendor',
    cost: 'account',
    costNote:
      'Free. The Analytics Data API costs nothing at ordinary volumes, and the Google Cloud ' +
      'project that holds the credentials is free to create.',
    caveat:
      'It signs in through Google Cloud application default credentials, so nothing here works ' +
      'until those exist for an account that can read the property.',
  },
  {
    id: 'google-workspace',
    name: 'google-workspace',
    summary: 'Gmail, Calendar, Drive and Docs behind one server, through Google’s own OAuth.',
    homepage: 'https://github.com/taylorwilsdon/google_workspace_mcp',
    category: 'messaging',
    tags: ['google', 'gmail', 'mail', 'calendar', 'drive', 'docs', 'sheets', 'workspace'],
    licence: 'MIT',
    version: '1.25.0',
    registry: 'https://pypi.org/project/workspace-mcp/',
    runtime: 'python',
    command: 'uvx workspace-mcp --tool-tier core',
    token: 'workspace-mcp',
    inputs: [
      {
        key: 'GOOGLE_OAUTH_CLIENT_ID',
        label: 'OAuth client id',
        hint: 'From a Google Cloud OAuth client. Its README names this variable.',
        kind: 'text',
        into: 'env',
        required: true,
      },
      {
        key: 'GOOGLE_OAUTH_CLIENT_SECRET',
        label: 'OAuth client secret',
        hint: 'From the same client. Its README names this variable.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    cost: 'account',
    costNote:
      'Free. A Google account costs nothing and so does the Google Cloud project — the project ' +
      'is only there to hold the OAuth client these two values come from.',
    caveat:
      'Not Google’s own. It reaches a real mailbox and a real calendar: once you have granted ' +
      'it, it can send mail and move events, not only read them.',
  },
  {
    id: 'figma',
    name: 'figma',
    summary: 'Reads a Figma file’s layout, styles and components, so a design can be built from its real values.',
    homepage: 'https://github.com/GLips/Figma-Context-MCP',
    category: 'design',
    tags: ['design', 'frames', 'components', 'styles', 'mockup', 'ui', 'layout'],
    licence: 'MIT',
    version: '0.13.2',
    registry: 'https://www.npmjs.com/package/figma-developer-mcp',
    runtime: 'node',
    command: 'npx -y figma-developer-mcp --stdio',
    token: 'figma-developer-mcp',
    inputs: [
      {
        key: 'FIGMA_API_KEY',
        label: 'Personal access token',
        hint: 'Figma → Settings → Personal access tokens. Its README names this variable.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'third-party',
    cost: 'account',
    costNote:
      'Free. A Figma starter account costs nothing and can issue the token; the paid seats buy ' +
      'editing, not API reads.',
    caveat: 'Not Figma’s own server — Framelink’s, MIT.',
  },
  {
    id: 'atlassian',
    name: 'atlassian',
    summary: 'Atlassian’s own hosted server: Jira issues and Confluence pages.',
    homepage: 'https://www.atlassian.com/platform/remote-mcp-server',
    category: 'work',
    tags: ['jira', 'confluence', 'issues', 'tickets', 'sprint', 'wiki', 'backlog'],
    licence: 'MIT',
    version: '0.1.43',
    registry: 'https://www.npmjs.com/package/mcp-remote',
    runtime: 'node',
    command: 'npx -y mcp-remote https://mcp.atlassian.com/v1/sse',
    token: 'mcp.atlassian.com',
    inputs: [],
    origin: 'hosted',
    cost: 'account',
    costNote:
      'Free. Atlassian’s free Jira and Confluence tiers can sign in to this; the paid tiers buy ' +
      'seats, not this server.',
    caveat: HOSTED_NOTE,
  },
  {
    id: 'linear',
    name: 'linear',
    summary: 'Linear’s own hosted server: issues, projects, cycles and comments.',
    homepage: 'https://linear.app/docs/mcp',
    category: 'work',
    tags: ['issues', 'tickets', 'projects', 'cycles', 'roadmap', 'backlog', 'tracker'],
    licence: 'MIT',
    version: '0.1.43',
    registry: 'https://www.npmjs.com/package/mcp-remote',
    runtime: 'node',
    command: 'npx -y mcp-remote https://mcp.linear.app/mcp',
    token: 'mcp.linear.app',
    inputs: [],
    origin: 'hosted',
    cost: 'account',
    costNote: 'Free. Linear’s free workspace can sign in to this.',
    caveat:
      HOSTED_NOTE +
      ' The /sse endpoint this was widely documented with answers 404 now; the /mcp one above ' +
      'answered on the day it was checked.',
  },
  {
    id: 'exa',
    name: 'exa',
    summary: 'Exa’s own hosted server: neural web search, page fetching and multi-step research.',
    homepage: 'https://github.com/exa-labs/exa-mcp-server',
    category: 'web',
    tags: ['search', 'web search', 'research', 'neural', 'crawl', 'answers'],
    licence: 'MIT',
    version: '0.1.43',
    registry: 'https://www.npmjs.com/package/mcp-remote',
    runtime: 'node',
    command: 'npx -y mcp-remote https://mcp.exa.ai/mcp',
    token: 'mcp.exa.ai',
    inputs: [],
    origin: 'hosted',
    cost: 'metered',
    costNote:
      'Free to a limit, then paid. Searches are billed to the Exa account you sign in with, so ' +
      'this is free to try and not free to keep using.',
    caveat:
      HOSTED_NOTE +
      ' Exa still publishes an npm package, and its own README now points at this hosted ' +
      'endpoint instead.',
  },
  {
    id: 'apify',
    name: 'apify',
    summary: 'Apify’s own hosted server: runs Actors that scrape sites and hand back structured data.',
    homepage: 'https://github.com/apify/apify-mcp-server',
    category: 'web',
    tags: ['scrape', 'crawl', 'actors', 'extract', 'dataset', 'automation'],
    licence: 'MIT',
    version: '0.1.43',
    registry: 'https://www.npmjs.com/package/mcp-remote',
    runtime: 'node',
    command: 'npx -y mcp-remote https://mcp.apify.com',
    token: 'mcp.apify.com',
    inputs: [],
    origin: 'hosted',
    cost: 'metered',
    costNote:
      'Free to a limit, then paid. Apify’s free plan includes a monthly allowance of platform ' +
      'credit and bills past it, and every Actor the agent runs spends some of it.',
    caveat:
      HOSTED_NOTE +
      ' The scraping runs on Apify’s machines and is charged to the account you sign in with.',
  },
  {
    id: 'perplexity',
    name: 'perplexity',
    summary: 'Asks Perplexity’s Sonar models a question and returns the answer with its citations.',
    homepage: 'https://github.com/perplexityai/modelcontextprotocol',
    category: 'web',
    tags: ['search', 'research', 'answers', 'citations', 'sonar', 'ask'],
    licence: 'MIT',
    version: '0.1.3',
    registry: 'https://www.npmjs.com/package/server-perplexity-ask',
    runtime: 'node',
    command: 'npx -y server-perplexity-ask',
    token: 'server-perplexity-ask',
    inputs: [
      {
        key: 'PERPLEXITY_API_KEY',
        label: 'API key',
        hint: 'From Perplexity’s API settings. Its README names this variable.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'vendor',
    cost: 'paid',
    costNote:
      'Paid, and the only row here that is. Perplexity’s API is billed against credit bought up ' +
      'front — there is no free allowance to start on, so this does nothing until the key has ' +
      'money behind it. A Pro subscription includes a monthly API credit, and that subscription ' +
      'is itself paid.',
    caveat:
      'Every question leaves this machine and is charged to that key. The npm package still ' +
      'names github.com/modelcontextprotocol/servers as its repository, which is a leftover — ' +
      'the project is Perplexity’s own, at the address on this row.',
  },
  /* ---------------------------------------------------------- archived -- */
  {
    id: 'sqlite',
    name: 'sqlite',
    summary: 'Queries a SQLite database file and describes its schema.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/sqlite',
    category: 'data',
    tags: ['sql', 'database', 'query', 'schema', 'db file'],
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
    logo: 'sqlite',
    cost: 'free',
    costNote: '',
    caveat: ARCHIVED_NOTE + ' It can write, not only read.',
  },
  {
    id: 'postgres',
    name: 'postgres',
    summary: 'Runs read-only SQL against a Postgres database and reads its schema.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/postgres',
    category: 'data',
    tags: ['sql', 'database', 'query', 'schema', 'postgresql', 'read only'],
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
    logo: 'postgres',
    cost: 'free',
    costNote: '',
    caveat:
      ARCHIVED_NOTE +
      ' And the connection string is an argument, not a variable, so a password in it cannot be ' +
      'kept out of the configuration file. The postgres-mcp row is the maintained answer to the ' +
      'same question and takes its connection string in a variable — install that one unless you ' +
      'specifically want this.',
  },
  {
    id: 'slack',
    name: 'slack',
    summary: 'Reads channels and threads in a Slack workspace and posts messages.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/slack',
    category: 'messaging',
    tags: ['chat', 'messages', 'channels', 'threads', 'workspace'],
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
    logo: 'slack',
    cost: 'account',
    costNote:
      'Free. It needs a bot token from a Slack app installed into a workspace, which a free ' +
      'Slack workspace can create.',
    caveat: ARCHIVED_NOTE + ' It can post as the bot, not only read.',
  },
  {
    id: 'brave-search',
    name: 'brave-search',
    summary: 'Web and local search through the Brave Search API.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/brave-search',
    category: 'web',
    tags: ['search', 'web search', 'local search', 'maps'],
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
    logo: 'brave',
    cost: 'metered',
    costNote:
      'Free to install. The Brave Search API has a free tier and bills past it, so the key is ' +
      'what costs, not this.',
    caveat: ARCHIVED_NOTE,
  },
  {
    id: 'puppeteer',
    name: 'puppeteer',
    summary: 'Drives a headless Chrome — navigate, click, type, screenshot.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/puppeteer',
    category: 'browser',
    tags: ['browser', 'headless chrome', 'automation', 'click', 'type', 'screenshot'],
    licence: 'MIT',
    version: '2025.5.12',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-puppeteer',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-puppeteer',
    token: '@modelcontextprotocol/server-puppeteer',
    inputs: [],
    origin: 'reference-archived',
    logo: 'puppeteer',
    cost: 'free',
    costNote: '',
    caveat:
      ARCHIVED_NOTE +
      ' The playwright row above is the maintained answer to the same question — install that one ' +
      'unless you specifically want this.',
  },
  {
    id: 'google-drive',
    name: 'google-drive',
    summary: 'Lists, searches and reads files in Google Drive, converting Docs and Sheets on the way out.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/gdrive',
    category: 'files',
    tags: ['google', 'drive', 'files', 'documents', 'spreadsheet', 'cloud storage', 'search'],
    licence: 'MIT',
    version: '2025.1.14',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-gdrive',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-gdrive',
    token: '@modelcontextprotocol/server-gdrive',
    inputs: [
      {
        key: 'GDRIVE_CREDENTIALS_PATH',
        label: 'Saved credentials file',
        hint: 'The file its own `auth` run writes. Its README names this variable.',
        kind: 'path',
        into: 'env',
        required: true,
      },
      {
        key: 'GDRIVE_OAUTH_PATH',
        label: 'OAuth keys file',
        hint: 'gcp-oauth.keys.json, from a Google Cloud OAuth client. Only needed while authorising.',
        kind: 'path',
        into: 'env',
        required: false,
      },
    ],
    origin: 'reference-archived',
    cost: 'account',
    costNote:
      'Free. A Google account costs nothing, and so does the Google Cloud project the OAuth ' +
      'client has to live in.',
    caveat:
      ARCHIVED_NOTE +
      ' And it does not start usefully until it has been authorised once by hand: its own README ' +
      'has you run it with `auth` and a Google Cloud OAuth keys file before the configured ' +
      'command has anything to read.',
  },
  {
    id: 'google-maps',
    name: 'google-maps',
    summary: 'Geocoding, directions, distances and place search through the Google Maps Platform.',
    homepage: 'https://github.com/modelcontextprotocol/servers-archived/tree/main/src/google-maps',
    category: 'web',
    tags: ['google', 'maps', 'directions', 'places', 'geocode', 'distance', 'location'],
    licence: 'MIT',
    version: '0.6.2',
    registry: 'https://www.npmjs.com/package/@modelcontextprotocol/server-google-maps',
    runtime: 'node',
    command: 'npx -y @modelcontextprotocol/server-google-maps',
    token: '@modelcontextprotocol/server-google-maps',
    inputs: [
      {
        key: 'GOOGLE_MAPS_API_KEY',
        label: 'API key',
        hint: 'From the Google Maps Platform console. Its README names this variable.',
        kind: 'secret',
        into: 'env',
        required: true,
      },
    ],
    origin: 'reference-archived',
    cost: 'metered',
    costNote:
      'Free to a limit, then paid. Google Maps Platform bills per request against a monthly ' +
      'credit, and a key on a project with billing switched off answers nothing at all.',
    caveat: ARCHIVED_NOTE,
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
 * for thirty-nine rows, and the answer is a property of the machine rather than
 * of the row.
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
