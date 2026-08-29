import { describe, expect, it } from 'vitest'
import { join } from 'node:path'
import {
  agentLine,
  machineProbe,
  missingNeeds,
  profileUrlOf,
  projectItem,
  projectView,
  type CommunityAgentRow,
  type MachineProbe,
} from './community-view'
import type { StoreRow } from './store-index'
import type { StoreItemView, StoreView } from './store-install'
import type { AgentBinary } from './agent-binaries'

/* ------------------------------------------------------------- the fixtures -- */

function row(over: Partial<StoreRow> = {}): StoreRow {
  return {
    id: 'acme/thing',
    publisher: 'acme',
    listedBy: 'terminaldeck',
    kind: 'skill',
    name: 'A Thing',
    summary: 'One honest line.',
    version: '1.0.0',
    licence: 'MIT',
    category: 'code',
    tags: ['thing'],
    agents: ['claude', 'codex', 'gemini'],
    platforms: ['darwin', 'win32', 'linux'],
    tier: 1,
    needs: [],
    cost: 'free',
    costNote: null,
    delivery: 'repo',
    source: { repo: 'acme/thing', commit: 'a'.repeat(40), path: 'skills/thing', host: 'github.com' },
    artifact: { url: 'https://x/t.tgz', sha256: 'b'.repeat(64), bytes: 10, files: 1, unpacked: 20 },
    install: { kind: 'skill', dir: '.' },
    icon: null,
    ai: null,
    repoStats: null,
    network: [],
    publishedAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-08-28T00:00:00.000Z',
    ...over,
  }
}

const AGENTS: CommunityAgentRow[] = [
  { id: 'claude', name: 'Claude Code', found: true, note: '' },
  { id: 'codex', name: 'Codex CLI', found: false, note: 'Codex CLI is not installed.' },
  { id: 'gemini', name: 'Gemini CLI', found: true, note: '' },
]

function probeWith(present: readonly string[]): MachineProbe {
  return {
    onPath: async (bin) => present.includes(bin),
    agents: async () => ({
      claude: binary('claude', '/usr/bin/claude'),
      codex: binary('codex', null),
      gemini: binary('gemini', '/usr/bin/gemini'),
    }),
  }
}

function binary(id: 'claude' | 'codex' | 'gemini', runnable: string | null): AgentBinary {
  return {
    id,
    bin: id,
    onPath: runnable,
    runnable,
    version: null,
    broken: false,
    said: null,
    usedAlternate: false,
    checkedAt: 0,
  }
}

function itemView(over: Partial<StoreItemView> = {}): StoreItemView {
  return { row: row(), state: 'available', note: null, installed: null, ...over }
}

/* ------------------------------------------------------------------ tests -- */

describe('missingNeeds', () => {
  it('names a runtime this machine does not have', async () => {
    expect(await missingNeeds(['python'], probeWith(['node']))).toEqual(['python'])
  })

  it('says nothing about a runtime that is here', async () => {
    expect(await missingNeeds(['python', 'node'], probeWith(['python3', 'node']))).toEqual([])
  })

  it('never reports runs-scripts as missing, because it is not a thing to install', async () => {
    expect(await missingNeeds(['runs-scripts'], probeWith([]))).toEqual([])
  })

  it('never reports a key or an account as missing — those are five minutes away', async () => {
    expect(await missingNeeds(['api-key', 'account'], probeWith([]))).toEqual([])
  })

  it('says nothing about local-app, because the row never names which program', async () => {
    expect(await missingNeeds(['local-app'], probeWith([]))).toEqual([])
  })
})

describe('profileUrlOf', () => {
  it('points at the publisher on the host the commit is pinned on', () => {
    expect(profileUrlOf(row())).toBe('https://github.com/acme')
  })

  it('draws no link at all rather than one to nowhere', () => {
    expect(profileUrlOf(row({ publisher: '' }))).toBe('')
    expect(profileUrlOf(row({ source: { ...row().source, host: '' } }))).toBe('')
  })
})

describe('agentLine', () => {
  it('is the sentence this app already prints when an agent is missing', () => {
    expect(agentLine(binary('codex', null))).toContain('not installed')
  })

  it('is empty for an agent that is here and working', () => {
    expect(agentLine(binary('claude', '/usr/bin/claude'))).toBe('')
  })

  it('is empty rather than a guess when there is no answer at all', () => {
    expect(agentLine(undefined)).toBe('')
  })
})

describe('projectItem', () => {
  const deps = { userData: '/data', probe: probeWith(['node', 'python3']) }

  it('draws the repository’s own push date, never the listing’s', async () => {
    const out = await projectItem(
      itemView({ row: row({ repoStats: { stars: 12, openIssues: 3, pushedAt: '2026-07-01T00:00:00.000Z', readAt: '2026-08-28T00:00:00.000Z' } }) }),
      AGENTS,
      deps,
    )
    expect(out.updatedAt).toBe('2026-07-01T00:00:00.000Z')
    expect(out.stars).toBe(12)
    expect(out.openIssues).toBe(3)
  })

  it('draws no date and no counts when the indexer had none', async () => {
    const out = await projectItem(itemView(), AGENTS, deps)
    expect(out.updatedAt).toBe('')
    expect(out.stars).toBe(-1)
    expect(out.openIssues).toBe(-1)
  })

  it('names the folders for the agents that are here and claimed, and no others', async () => {
    const out = await projectItem(itemView(), AGENTS, deps)
    expect(out.lands.some((p) => p.includes('claude'))).toBe(false) // homes are blank in this pass
    expect(out.lands[0]).toBe(join('/data', 'community', 'items', 'acme.thing'))
  })

  it('composes the mcp command in our own code and never takes one from the row', async () => {
    const out = await projectItem(
      itemView({
        row: row({
          kind: 'mcp',
          tier: 3,
          install: { kind: 'mcp', runtime: 'python', package: 'ddg-mcp', args: [], inputs: [], token: 'ddg-mcp' },
        }),
      }),
      AGENTS,
      deps,
    )
    expect(out.command).toBe('uvx ddg-mcp')
  })

  it('asks for variable names and never values', async () => {
    const out = await projectItem(
      itemView({
        row: row({
          kind: 'mcp',
          tier: 3,
          install: {
            kind: 'mcp',
            runtime: 'node',
            package: 'thing',
            args: ['${input:TOKEN}'],
            inputs: [{ key: 'TOKEN', label: 'A token', hint: 'From the dashboard', kind: 'secret', into: 'env', required: true }],
            token: 'thing',
          },
        }),
      }),
      AGENTS,
      deps,
    )
    expect(out.variables).toEqual(['TOKEN'])
    expect(JSON.stringify(out)).not.toContain('secret-value')
  })

  it('carries the withdrawal reason and the state’s own sentence as one string', async () => {
    const out = await projectItem(
      itemView({ state: 'withdrawn', note: 'Withdrawn: the publisher asked.' }),
      AGENTS,
      deps,
    )
    expect(out.reason).toBe('Withdrawn: the publisher asked.')
    expect(out.message).toBe('Withdrawn: the publisher asked.')
  })

  it('leaves the reason empty for anything not withdrawn', async () => {
    const out = await projectItem(itemView({ state: 'damaged', note: 'It changed on disk.' }), AGENTS, deps)
    expect(out.reason).toBe('')
    expect(out.message).toBe('It changed on disk.')
  })

  it('says installed by naming the version on this disk, not by a state word', async () => {
    const out = await projectItem(itemView(), AGENTS, deps)
    expect(out.installedVersion).toBe('')
  })

  it('invents no rating, because nobody has rated anything yet', async () => {
    const out = await projectItem(itemView(), AGENTS, deps)
    expect(out.ratingCount).toBe(0)
    expect(out.ratingScore).toBe(0)
  })
})

describe('projectView', () => {
  const view = (over: Partial<StoreView> = {}): StoreView => ({
    ok: true,
    why: null,
    items: [itemView()],
    from: 'store',
    at: '2026-08-29T00:00:00.000Z',
    stale: null,
    because: null,
    homes: { claude: '/h/.claude', codex: '/h/.codex', gemini: '/h/.gemini' },
    folder: '/data/community/items',
    ...over,
  })

  it('names all three agents whatever is on the machine', async () => {
    const out = await projectView(view(), '/data', probeWith([]))
    expect(out.agents.map((a) => a.id)).toEqual(['claude', 'codex', 'gemini'])
    expect(out.agents.find((a) => a.id === 'codex')?.found).toBe(false)
    expect(out.agents.find((a) => a.id === 'codex')?.note).toContain('not installed')
  })

  it('puts the real homes into the folders an install would write', async () => {
    const out = await projectView(view(), '/data', probeWith([]))
    const lands = out.items[0].lands
    expect(lands).toContain(join('/h/.claude', 'skills', 'acme.thing'))
    expect(lands).toContain(join('/h/.gemini', 'skills', 'acme.thing'))
    // Codex is not on this machine, so nothing is written for it.
    expect(lands.some((p) => p.includes('.codex'))).toBe(false)
  })

  it('turns null into the empty strings the screen narrows for', async () => {
    const out = await projectView(view(), '/data', probeWith([]))
    expect(out.stale).toBe('')
    expect(out.because).toBe('')
    expect(out.problem).toBe('')
    expect(out.from).toBe('store')
  })

  it('reports a kept list as kept, with the reason it could not be refreshed', async () => {
    const out = await projectView(
      view({ from: 'kept', because: 'the store could not be reached from this machine' }),
      '/data',
      probeWith([]),
    )
    expect(out.from).toBe('kept')
    expect(out.because).toBe('the store could not be reached from this machine')
  })

  it('turns no catalogue at all into one sentence, never a blank shelf', async () => {
    const out = await projectView(
      view({ ok: false, why: 'this catalogue was not signed by Terminal Deck', items: [], from: null, at: null }),
      '/data',
      probeWith([]),
    )
    expect(out.problem).toBe('this catalogue was not signed by Terminal Deck')
    expect(out.items).toEqual([])
    expect(out.at).toBe('')
  })

  it('still says something when the main half answered ok with no reason', async () => {
    const out = await projectView(view({ ok: false, why: null, items: [] }), '/data', probeWith([]))
    expect(out.problem).not.toBe('')
  })
})

describe('machineProbe', () => {
  it('answers about this machine without throwing', async () => {
    const probe = machineProbe()
    expect(typeof (await probe.onPath('node'))).toBe('boolean')
  })
})
