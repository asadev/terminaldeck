import {
  binaryNote,
  binaryProblem,
  resolveAgentBinaries,
  type AgentBinary,
} from './agent-binaries'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { currentPlatform, withPath } from './platform/host'
import { firstLookupPath, lookupSpec } from './platform/lookup'
import { loginPath, PROVIDERS } from './providers'
import { plannedTargets, type StoreItemView, type StoreView } from './store-install'
import type { StoreRow } from './store-index'
import {
  composeMcpCommand,
  MANIFEST_AGENTS,
  type ManifestAgent,
  type StoreNeed,
} from '../shared/store-manifest'

/**
 * The one place the community store's facts are turned into the answer a screen
 * reads.
 *
 * ## Why a projection and not the installer's own view
 *
 * `store-install.ts` answers in the shape the *installer* thinks in: a catalogue
 * row, the state it is in, and the ledger record beside it. A screen needs
 * something different — flat fields it can draw without knowing what a ledger
 * is, plus three answers only this process can give: which agent command line
 * tools are actually on this machine, which of an item's stated needs are not,
 * and the exact folders an install would write into.
 *
 * Putting that translation here rather than in the renderer is the rule this app
 * keeps everywhere: a sentence lives once, beside the code that makes it true. A
 * renderer that worked out "Claude Code is not installed" would be a second
 * opinion built from less evidence than the module that just tried to run it.
 *
 * ## Why nothing here decides anything
 *
 * Every judgement — did the signature check out, does the tier the bytes
 * recomputed to match the row, is this item withdrawn — is already settled by
 * the time a `StoreView` exists. This file measures the machine and rearranges
 * words. It never re-reads a catalogue and it never overrides a state.
 */

const run = promisify(execFile)

/* --------------------------------------------------------------- the shape -- */

/** One agent, and whether its command line tool is really here. */
export interface CommunityAgentRow {
  id: ManifestAgent
  name: string
  found: boolean
  /** One short line, or `''`. Never a paragraph — the sheet draws it as a line. */
  note: string
}

/** One catalogue row, flattened into what a screen draws. */
export interface CommunityItemRow {
  id: string
  publisher: string
  handle: string
  profileUrl: string
  kind: string
  name: string
  summary: string
  version: string
  licence: string
  tags: readonly string[]
  agents: readonly ManifestAgent[]
  tier: number
  needs: readonly string[]
  missing: readonly string[]
  cost: string
  costNote: string
  delivery: string
  offsiteUrl: string
  repo: string
  commit: string
  artifactUrl: string
  sha256: string
  bytes: number
  network: readonly string[]
  updatedAt: string
  stars: number
  openIssues: number
  ratingScore: number
  ratingCount: number
  state: string
  installedVersion: string
  message: string
  reason: string
  lands: readonly string[]
  command: string
  variables: readonly string[]
  trigger: string
  reach: readonly string[]
  logo: string
}

/** Everything `community:list` answers. */
export interface CommunityViewOut {
  from: 'store' | 'kept'
  at: string
  stale: string
  because: string
  problem: string
  items: CommunityItemRow[]
  folder: string
  agents: CommunityAgentRow[]
}

/* ------------------------------------------------------------ the machine -- */

/**
 * The needs that are a question about this machine rather than about a person.
 *
 * `node` and `python` are things a computer either has on its PATH or does not.
 * `api-key` and `account` are five minutes and a browser away, and grading them
 * the same would put a red line on half the shop for something nobody is
 * blocked by. `runs-scripts` is a warning about what the item does, never a
 * thing to go and install, so it is never reported missing — the tier sentence
 * is where that fact belongs and it is already on the row.
 *
 * `local-app` is deliberately absent too: the row says an item needs "another
 * program" without naming which one, so there is nothing here to look for. A
 * red line we cannot substantiate is worse than no line.
 */
const RUNTIME_BINARY: Readonly<Partial<Record<StoreNeed, string>>> = Object.freeze({
  node: 'node',
  python: 'python3',
})

export interface MachineProbe {
  /** Whether a bare command name resolves to something runnable on this PATH. */
  onPath(bin: string): Promise<boolean>
  /** The agent command line tools, as `agent-binaries.ts` found them. */
  agents(): Promise<Record<ManifestAgent, AgentBinary>>
}

/** The real probe: the login shell's PATH, and the module that already does this. */
export function machineProbe(): MachineProbe {
  let runtimes: Promise<Set<string>> | null = null

  const measure = async (): Promise<Set<string>> => {
    const platform = currentPlatform()
    const env = withPath(process.env, await loginPath(platform), platform)
    const found = new Set<string>()
    await Promise.all(
      Object.values(RUNTIME_BINARY).map(async (bin) => {
        const spec = lookupSpec(platform, bin)
        try {
          // `which` / `where.exe` through `execFile`, the same two commands
          // `agent-binaries.ts` asks with — never a shell, and the binary name
          // is an argument rather than something interpolated into a string.
          const { stdout } = await run(spec.command, spec.args, {
            env,
            windowsHide: true,
            timeout: 4000,
          })
          if (firstLookupPath(stdout) !== null) found.add(bin)
        } catch {
          /* A non-zero exit *is* the "not installed" answer. */
        }
      }),
    )
    return found
  }

  return {
    async onPath(bin: string): Promise<boolean> {
      runtimes ??= measure()
      return (await runtimes).has(bin)
    },
    async agents(): Promise<Record<ManifestAgent, AgentBinary>> {
      const all = await resolveAgentBinaries({ path: await loginPath() })
      return { claude: all.claude, codex: all.codex, gemini: all.gemini }
    },
  }
}

/**
 * Of the needs this row states, the ones this machine does not have.
 *
 * Measured, never assumed. A row that says it needs Python and finds Python gets
 * no line at all, which is the point: the only red text in this department is
 * red because something was actually looked for and not found.
 */
export async function missingNeeds(
  needs: readonly string[],
  probe: MachineProbe,
): Promise<string[]> {
  const missing: string[] = []
  for (const need of needs) {
    const bin = RUNTIME_BINARY[need as StoreNeed]
    if (bin === undefined) continue
    if (!(await probe.onPath(bin))) missing.push(need)
  }
  return missing
}

/* ------------------------------------------------------------ the sentences -- */

/**
 * The line beside an agent's name in the install sheet.
 *
 * `binaryProblem` is the sentence this app already prints everywhere else an
 * agent is missing — one line, in the user's terms, ending in something to
 * type — and reusing it means the store and the session picker cannot start
 * saying different things about the same machine. `binaryNote` covers the odd
 * case where the copy on PATH will not start and another one will.
 */
export function agentLine(binary: AgentBinary | undefined): string {
  if (binary === undefined) return ''
  return binaryProblem(binary) ?? binaryNote(binary) ?? ''
}

function agentRows(found: Record<ManifestAgent, AgentBinary>): CommunityAgentRow[] {
  /*
   * All three, always, whatever is on the machine. `found` is the thing being
   * reported and a missing row would report it by absence — which is the one
   * shape house rule four forbids. The renderer builds its own list of three for
   * the same reason; this one carries the measurement.
   */
  return MANIFEST_AGENTS.map((id) => ({
    id,
    name: PROVIDERS[id].label,
    found: found[id]?.runnable !== null && found[id] !== undefined,
    note: agentLine(found[id]),
  }))
}

/**
 * Where an item's publisher can be read about.
 *
 * Built from the row's own pinned host and publisher rather than taken as a
 * field, because a profile link a publisher types is a link a publisher chooses,
 * and this one can only ever point at the account that owns the repository the
 * bytes came out of. Milestone 3 replaces it with a Commons profile; until that
 * exists, the honest page is the one on the host.
 */
export function profileUrlOf(row: StoreRow): string {
  if (row.publisher === '' || row.source.host === '') return ''
  return `https://${row.source.host}/${row.publisher}`
}

/** For an `mcp` row: the command this app's own code composes. Never the row's. */
function commandOf(row: StoreRow): string {
  return row.install !== null && row.install.kind === 'mcp' ? composeMcpCommand(row.install) : ''
}

/** For an `mcp` row: the variable NAMES it asks for. Never a value. */
function variablesOf(row: StoreRow): string[] {
  if (row.install === null || row.install.kind !== 'mcp') return []
  return row.install.inputs.map((input) => input.key)
}

/** For an `extension` row: the hosts it declares it may reach. */
function reachOf(row: StoreRow): string[] {
  if (row.install === null || row.install.kind !== 'extension') return []
  return [...row.install.reach]
}

/* ------------------------------------------------------------ the projection -- */

export interface ProjectDeps {
  userData: string
  probe: MachineProbe
}

/** One item, flattened. Exported for the test that pins the shape. */
export async function projectItem(
  item: StoreItemView,
  agents: readonly CommunityAgentRow[],
  deps: ProjectDeps,
): Promise<CommunityItemRow> {
  const row = item.row
  /*
   * The folders an install would write into, worked out by the function the
   * installers themselves call. The sheet in front of the Install button has to
   * name real paths, and a sheet that described them in general terms would be a
   * sheet nobody can check — so this is deliberately not a second table.
   *
   * The agents it is asked about are the honest default the sheet opens with:
   * the ones both on this machine and named by the publisher.
   */
  const forInstall = agents
    .filter((one) => one.found && row.agents.includes(one.id))
    .map((one) => one.id)
  return {
    id: row.id,
    publisher: row.publisher,
    handle: row.publisher,
    profileUrl: profileUrlOf(row),
    kind: row.kind,
    name: row.name,
    summary: row.summary,
    version: row.version,
    licence: row.licence,
    tags: row.tags,
    agents: row.agents,
    tier: row.tier,
    needs: row.needs,
    missing: await missingNeeds(row.needs, deps.probe),
    cost: row.cost,
    costNote: row.costNote ?? '',
    delivery: row.delivery,
    /*
     * An off-site listing has no link in this version, and this is where that
     * shows. The row grammar carries no outbound URL yet — the manifest's
     * `pricing.url` holds one and the index does not restate it — so rather than
     * point the "Get it from" button at the repository and call that the same
     * thing, it points nowhere and the button draws nothing. There are no
     * off-site rows in this catalogue; the field is here so the seam is visible
     * rather than discovered.
     */
    offsiteUrl: '',
    repo: row.source.repo,
    commit: row.source.commit,
    artifactUrl: row.artifact?.url ?? '',
    sha256: row.artifact?.sha256 ?? '',
    bytes: row.artifact?.bytes ?? 0,
    network: row.network,
    /*
     * The repository's own push date, not the listing's.
     *
     * The row draws this string inside GitHub's cluster — `★ 279,022 · updated
     * today · 331 open` — so every number in that line has to be GitHub's or the
     * line is three facts about two different things. The catalogue's own
     * `updatedAt` is when the *listing* was written, which for a seed catalogue
     * is the day it was hand-made; drawing it here made a skill last touched in
     * August read as "updated today", which is the store telling somebody a
     * stranger's work is fresher than it is. When there are no repository stats
     * there is no date either, and the row draws none.
     */
    updatedAt: row.repoStats?.pushedAt ?? '',
    stars: row.repoStats?.stars ?? -1,
    openIssues: row.repoStats?.openIssues ?? -1,
    /* Ratings are people, and people live in a database nobody has stood up yet.
       Zero rather than an invented number: the row draws no chip under five. */
    ratingScore: 0,
    ratingCount: 0,
    state: item.state,
    installedVersion: item.installed?.version ?? '',
    message: item.note ?? '',
    /* The withdrawal reason and the state's sentence are the same string here:
       `stateOf` writes one sentence that already begins "Withdrawn". Two fields
       carrying two different wordings of one fact is how they come to disagree. */
    reason: item.state === 'withdrawn' ? (item.note ?? '') : '',
    lands: plannedTargets(
      { kind: row.kind, publisher: row.publisher, id: row.id },
      forInstall,
      Object.fromEntries(agents.map((one) => [one.id, ''])) as Record<ManifestAgent, string>,
      deps.userData,
    ),
    command: commandOf(row),
    variables: variablesOf(row),
    /* A routine's triggers live inside the routine file, which is inside an
       archive nobody has downloaded yet. Naming one from the row would be this
       app guessing on the publisher's behalf. The sheet's real promise about a
       routine — that it arrives switched off — does not depend on it. */
    trigger: '',
    reach: reachOf(row),
    logo: row.icon ?? '',
  }
}

/** The whole answer `community:list` gives a screen. */
export async function projectView(
  view: StoreView,
  userData: string,
  probe: MachineProbe,
): Promise<CommunityViewOut> {
  const agents = agentRows(await probe.agents())
  const deps: ProjectDeps = { userData, probe }
  const homes = view.homes
  const items = await Promise.all(
    view.items.map(async (item) => {
      const projected = await projectItem(item, agents, deps)
      /* The real homes, put back after `projectItem` worked out which agents are
         being written into. Two passes rather than one because the folders and
         the agents are decided by different questions. */
      return {
        ...projected,
        lands: plannedTargets(
          { kind: item.row.kind, publisher: item.row.publisher, id: item.row.id },
          agents.filter((one) => one.found && item.row.agents.includes(one.id)).map((one) => one.id),
          homes,
          userData,
        ),
      }
    }),
  )
  return {
    from: view.from === 'kept' ? 'kept' : 'store',
    at: view.at ?? '',
    stale: view.stale ?? '',
    because: view.because ?? '',
    problem: view.ok ? '' : (view.why ?? 'The community store could not be read.'),
    items,
    folder: view.folder,
    agents,
  }
}
