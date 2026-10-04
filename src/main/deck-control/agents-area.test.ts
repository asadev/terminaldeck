import { describe, expect, it } from 'vitest'
import { ROUTINE_TIERS } from '../routines/ipc'
import { localTaskTools } from '../tasks/local-task-tools'
import { agentsCoverage } from './actions/agents'
import { agentsAreaTools, type AgentsAreaDeps } from './agents-area'
import { advertiseTool, buildCatalogue, catalogueCost, estimateTokens } from './catalogue'
import { advertisedCatalogue, describeIndex, withDescribe } from './describe-tool'

/**
 * The agents area as a whole: the shape every tool must have, and the table
 * of what a person can do pointing only at tools that exist.
 *
 * None of these reads a dep — they are about definitions — so the deps are
 * stand-ins, except `hooks.providers`, which a definition does read (it is the
 * enum the schema advertises).
 */
function definitions(): ReturnType<typeof agentsAreaTools> {
  const inert = new Proxy({}, { get: () => () => undefined })
  return agentsAreaTools({
    agents: inert,
    accounts: inert,
    mcp: inert,
    hooks: { ...(inert as object), providers: ['claude', 'codex', 'gemini'] },
    routines: inert,
    app: inert,
    setup: { ...(inert as object), fixIds: new Set<string>() },
    usage: inert,
    voice: inert,
  } as unknown as AgentsAreaDeps)
}

describe('the agents area', () => {
  const tools = definitions()
  const ids = tools.map((tool) => tool.id)

  it('gives every tool a unique id, and a wire name the API accepts', () => {
    expect(new Set(ids).size).toBe(ids.length)
    for (const tool of tools) {
      expect(tool.wire).toBe(tool.id.replace(/\./g, '_'))
      expect(`mcp__deck-control__${tool.wire}`).toMatch(/^[a-zA-Z0-9_-]{1,128}$/)
    }
  })

  it('collides with nothing the app already serves', () => {
    const builtIn = new Set(buildCatalogue().map((tool) => tool.id))
    expect(ids.filter((id) => builtIn.has(id))).toEqual([])
  })

  it('refuses unknown arguments on every schema', () => {
    // A schema that tolerated extra keys would let a model attach an argument
    // the handler silently ignores and then believe it had an effect.
    for (const tool of tools) {
      expect(tool.inputSchema.type, tool.id).toBe('object')
      expect(tool.inputSchema.additionalProperties, tool.id).toBe(false)
    }
  })

  it('holds every tool behind tools.describe, at one short line each', () => {
    /*
     * None of these is a first reach — see `agents-area.ts` — and fifty-eight
     * schemas advertised in full would be several times the whole budget. The
     * line has to be enough to choose by, and short, because it is paid on
     * every turn inside the describe tool's description.
     */
    for (const tool of tools) {
      expect(tool.index, tool.id).toBeDefined()
      expect((tool.index ?? '').length, tool.id).toBeLessThanOrEqual(100)
    }
  })

  it('adds no advertised schema to the standing listing', () => {
    const before = advertisedCatalogue(withDescribe(buildCatalogue()))
    const after = advertisedCatalogue(withDescribe([...buildCatalogue(), ...tools]))
    expect(after.length).toBe(before.length)
  })

  it('costs the standing listing what its index lines cost, and that is written down', () => {
    /*
     * Measured on this branch, 2026-10-03: 58 tools, an index of 4,479
     * characters, the longest line 89 — 1,296 estimated tokens added to every
     * turn (3,114 → 4,410 over the built-ins alone; ~5,844 → ~7,140 over the
     * whole shipped list, under the 8,000 ceiling on its own). Pinned
     * loosely so a rewrite that doubles it is visible; the catalogue-wide
     * ceiling is `catalogue-cost.test.ts`'s to enforce once every lane has
     * landed, and it is the integrator's call how the index is shared.
     */
    const added = describeIndex(tools)
    expect(tools.length).toBe(58)
    expect(added.length).toBeLessThan(6_000)
    const before = catalogueCost(advertisedCatalogue(withDescribe(buildCatalogue())))
    const after = catalogueCost(advertisedCatalogue(withDescribe([...buildCatalogue(), ...tools])))
    expect(after.tokens - before.tokens).toBeLessThanOrEqual(estimateTokens(added) + 50)
  })

  it('makes every write that changes configuration, credentials or deletes something alter', () => {
    const alter = [
      'agents.add',
      'agents.remove',
      'accounts.create',
      'accounts.rename',
      'accounts.delete',
      'accounts.set_default',
      'accounts.sign_in',
      'accounts.sign_out',
      'accounts.share_history',
      'mcp.add',
      'mcp.edit',
      'mcp.remove',
      'mcp.call',
      'mcp.install',
      'hooks.install',
      'hooks.remove',
      'hooks.sync',
      'routines.save',
      'routines.delete',
      'app.clear_log',
      'settings.reset',
      'settings.clear_browser_data',
      'updates.install',
      'readiness.fix',
      'voice.save_key',
      'voice.forget_key',
    ]
    for (const id of alter) expect(tools.find((tool) => tool.id === id)?.tier, id).toBe('alter')
  })

  it('marks every read tool read-only and nothing else', () => {
    for (const tool of tools) {
      expect(advertiseTool(tool).annotations).toMatchObject({ readOnlyHint: tool.tier === 'read' })
    }
  })

  it('puts each routine tool at the tier routines/ipc.ts wrote down for it', () => {
    // The table was written for this file to obey. Read rather than retyped.
    const channelOf: Record<string, string> = {
      'routines.list': 'routines:list',
      'routines.get': 'routines:get',
      'routines.run': 'routines:run',
      'routines.pause': 'routines:pause',
      'routines.resume': 'routines:resume',
      'routines.save': 'routines:update',
      'routines.delete': 'routines:delete',
    }
    for (const [id, channel] of Object.entries(channelOf)) {
      expect(tools.find((tool) => tool.id === id)?.tier, id).toBe(ROUTINE_TIERS[channel])
    }
    // And the one operation no tier may reach is reached by none.
    expect(Object.values(ROUTINE_TIERS).filter((tier) => tier === 'human')).toEqual(['human'])
    expect(ids.some((id) => /save_?text/i.test(id))).toBe(false)
  })

  it('points every entry in the agents table at a tool that exists', () => {
    // Your own tasks' tools are contributed beside the catalogue, like the CRM's; the table points at them too.
    const taskToolIds = localTaskTools({ local: () => null, detail: () => null, store: () => null, config: () => null, island: () => null }).map((tool) => tool.id)
    const known = new Set([...ids, ...buildCatalogue().map((tool) => tool.id), ...taskToolIds])
    const dangling = Object.entries(agentsCoverage).flatMap(([channel, entry]) => {
      if (entry === null || 'skip' in entry) return []
      const named = typeof entry.tool === 'string' ? [entry.tool] : entry.tool
      return named.filter((id) => !known.has(id)).map((id) => `${channel} → ${id}`)
    })
    expect(dangling).toEqual([])
  })

  it('leaves no tool in the area that no channel reaches', () => {
    // The other direction: a tool nothing in the table names is either a
    // capability the window does not have, or a row somebody forgot.
    const named = new Set(
      Object.values(agentsCoverage).flatMap((entry) =>
        entry === null || 'skip' in entry ? [] : typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool],
      ),
    )
    expect(ids.filter((id) => !named.has(id))).toEqual([])
  })

  it('builds no tool for the Mac speech channels, which are being removed', () => {
    expect(Object.keys(agentsCoverage).some((channel) => channel.startsWith('nspeech:'))).toBe(false)
  })
})
