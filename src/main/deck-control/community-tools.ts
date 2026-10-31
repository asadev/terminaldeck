import type { CommunityItemRow, CommunityViewOut } from '../community-view'
import type { InstallChoice, StoreResult } from '../store-install'
import { TIER_WORDS, type StoreTier } from '../../shared/store-manifest'
import { actionOf, escalateBy, notASession, optStr, str } from './browser-area-kit'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `store.community` — the Store's Community department: things other people
 * published, and installing or removing them.
 *
 * ## The sentence this tool must say out loud
 *
 * **Installing an item runs someone else's work on this Mac.** A skill is text
 * an agent reads and may follow; an MCP server is a program an agent starts; a
 * hook is a script an agent runs at named moments; a routine drives a session on
 * a schedule. Every one of those is a stranger's instructions or a stranger's
 * code, put where this Mac's agents will act on it. The Store's own sheet says so
 * before Install, with the item's tier — *"Text only — nothing runs"*, *"Ships
 * scripts the agent may run"*, *"Runs a program on this machine"* — and so does
 * this tool, in its description, in every row it lists, and in the sentence on
 * the confirmation a person answers. An install is `alter`, always, and a person
 * reads the tier before saying yes.
 *
 * What it does not do is install anything the panel would not: it calls the
 * installer the panel's button calls (`communityInstall` in
 * `store-install-ipc.ts`), so the signature check, the digest pin, the tier
 * recomputed from the bytes that actually arrived, and the ledger that makes
 * Remove able to undo it are all the same ones. A copilot asking does not get a
 * second, looser installer.
 *
 * ## The values an install may carry
 *
 * An MCP server can declare inputs — an API key, a path, a word — and the sheet
 * asks for them. So does this tool, through `values`, and those values are often
 * secrets. They are never written to the action log: {@link redactValues}
 * replaces each with its length before `scrubArgs` sees the row, for the reason
 * `browser.step` does the same to what is typed into a page.
 */

export interface CommunityToolDeps {
  view(): Promise<CommunityViewOut>
  install(id: string, choice: InstallChoice): Promise<StoreResult>
  remove(id: string): Promise<StoreResult>
}

const ACTIONS = ['list', 'install', 'remove'] as const
type Action = (typeof ACTIONS)[number]

const TIERS: Readonly<Record<Action, Tier>> = { list: 'read', install: 'alter', remove: 'alter' }

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...ACTIONS], description: 'Default list.' },
    item: { type: 'string', description: 'For install and remove: the item id from the list.' },
    kind: { type: 'string', description: 'For list: only one kind — skill, instructions, mcp, hooks, routine, extension, tool.' },
    query: { type: 'string', description: 'For list: only items whose name, summary or tags contain this.' },
    agents: {
      type: 'array',
      items: { type: 'string' },
      description: 'For install: which agents to install it into (claude, codex, gemini). Omit for every one it supports.',
    },
    values: {
      type: 'object',
      description: 'For install of an mcp item: its declared inputs by key, such as an API key. Never logged.',
    },
    folder: { type: 'string', description: 'For install of a routine: the folder it runs in.' },
  },
  additionalProperties: false,
}

/** The tier's sentence, from the one table every screen reads it from. */
function tierWords(tier: number): string {
  return TIER_WORDS[(tier === 1 || tier === 2 || tier === 3 ? tier : 3) as StoreTier]
}

function rowOut(item: CommunityItemRow): Record<string, unknown> {
  return {
    item: item.id,
    name: item.name,
    kind: item.kind,
    publisher: item.publisher || item.handle,
    summary: item.summary,
    version: item.version,
    state: item.state,
    ...(item.installedVersion === '' ? {} : { installedVersion: item.installedVersion }),
    whatItRuns: tierWords(item.tier),
    agents: item.agents,
    needs: item.needs,
    ...(item.missing.length === 0 ? {} : { missingHere: item.missing }),
    reaches: item.network,
    writes: item.lands,
    ...(item.variables.length === 0 ? {} : { asksFor: item.variables }),
    ...(item.trigger === '' ? {} : { runsWhen: item.trigger }),
    cost: item.cost,
    licence: item.licence,
    repo: item.repo,
    ...(item.message === '' ? {} : { message: item.message }),
  }
}

/** Every value replaced by its length — see the header. */
export function redactValues(args: Record<string, unknown>): Record<string, unknown> {
  const values = args.values
  if (typeof values !== 'object' || values === null || Array.isArray(values)) return args
  const hidden: Record<string, string> = {}
  for (const [key, value] of Object.entries(values as Record<string, unknown>)) {
    hidden[key] = typeof value === 'string' ? `[${value.length} characters]` : '[not text]'
  }
  return { ...args, values: hidden }
}

function choiceOf(args: Record<string, unknown>): InstallChoice {
  const choice: InstallChoice = {}
  if (args.agents !== undefined) {
    if (!Array.isArray(args.agents) || args.agents.some((one) => typeof one !== 'string')) {
      throw new Refused('not-permitted', 'agents must be a list of agent names: claude, codex, gemini')
    }
    choice.agents = args.agents as string[]
  }
  if (args.values !== undefined) {
    const raw = args.values
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
      throw new Refused('not-permitted', 'values must be an object of the item’s inputs by key')
    }
    const values: Record<string, string> = {}
    for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
      if (typeof value !== 'string') throw new Refused('not-permitted', `values.${key} must be text`)
      values[key] = value
    }
    choice.values = values
  }
  const folder = optStr(args, 'folder')
  if (folder !== null) choice.folder = folder
  return choice
}

export function communityTools(deps: CommunityToolDeps): ToolSpec[] {
  /*
   * The last listing, kept for one purpose: the confirmation sentence. A
   * summary is synchronous and the shelf is a fetch, so the dialog names the
   * item and its tier from what this tool last saw rather than from nothing.
   * A call that names an item nobody has listed still gets a true sentence —
   * the id, and that it runs someone else's work.
   */
  let seen: readonly CommunityItemRow[] = []

  return [
    {
      id: 'store.community',
      wire: 'store_community',
      tier: 'read',
      title: 'The Store’s Community shelf',
      description:
        'The Store’s Community department: skills, instructions, MCP servers, hooks and routines other ' +
        'people published. "list" (the default) gives each item — what it is, who published it, what it ' +
        'needs, which sites it reaches, where it writes, whether it is installed, and in plain words what ' +
        'it runs on this Mac (kind and query narrow it). "install" installs one into this Mac’s agents ' +
        '(item; agents, values for an MCP server’s inputs, folder for a routine). Installing runs someone ' +
        'else’s work on this Mac — their instructions or their program — so the person is asked first and ' +
        'shown what it runs. "remove" takes an installed item away again, everything it wrote included.',
      index:
        'Store’s Community shelf of other people’s skills, MCP servers, hooks: list, install (runs their code; asks), remove.',
      inputSchema: SCHEMA,
      escalate: escalateBy(TIERS, 'list'),
      redactArgs: redactValues,
      precheck: (args, context: ToolContext) => {
        notASession(context, 'store.community')
        const action = actionOf(args, ACTIONS, 'list')
        if (action === 'list') return
        str(args, 'item')
        if (action === 'install') choiceOf(args)
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'list'
        const id = typeof args.item === 'string' ? args.item : '?'
        const row = seen.find((one) => one.id === id)
        const name = row ? `${row.name} by ${row.publisher || row.handle}` : id
        if (action === 'install') {
          return `Install ${name} from the Store — this runs someone else's work on this Mac (${row ? tierWords(row.tier) : 'what it runs is shown on its page'})`
        }
        if (action === 'remove') return `Remove ${name} and everything its install wrote`
        return 'List the Store’s Community shelf'
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, ACTIONS, 'list')
        if (action === 'list') {
          const view = await deps.view()
          seen = view.items
          const kind = optStr(args, 'kind')
          const query = optStr(args, 'query')?.toLowerCase() ?? null
          const items = view.items
            .filter((item) => kind === null || item.kind === kind)
            .filter(
              (item) =>
                query === null ||
                item.name.toLowerCase().includes(query) ||
                item.summary.toLowerCase().includes(query) ||
                item.tags.some((tag) => tag.toLowerCase().includes(query)),
            )
            .map(rowOut)
          return {
            value: {
              items,
              from: view.from === 'store' ? 'fetched now' : `the copy kept ${view.at}`,
              ...(view.stale === '' ? {} : { stale: view.stale }),
              ...(view.problem === '' ? {} : { problem: view.problem }),
              agentsHere: view.agents.map((agent) => ({ agent: agent.id, name: agent.name, found: agent.found })),
            },
            summary: { items: items.length },
          }
        }
        const id = str(args, 'item')
        const result = action === 'install' ? await deps.install(id, choiceOf(args)) : await deps.remove(id)
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return {
          value: { item: id, [action === 'install' ? 'installed' : 'removed']: true, message: result.message },
          summary: { item: id },
        }
      },
    },
  ]
}
