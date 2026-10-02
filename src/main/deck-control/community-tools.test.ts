import { describe, expect, it, vi } from 'vitest'
import type { CommunityItemRow, CommunityViewOut } from '../community-view'
import type { ToolContext } from './catalogue'
import { communityTools, redactValues, type CommunityToolDeps } from './community-tools'
import { toolsStoreTools, type ToolsStoreDeps } from './tools-store-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext
const SESSION = { caller: { kind: 'session', sessionId: 's1', tiers: LOCAL_CALLER.tiers } } as unknown as ToolContext

function item(over: Partial<CommunityItemRow>): CommunityItemRow {
  return {
    id: 'acme/search-mcp',
    publisher: 'Acme',
    handle: 'acme',
    profileUrl: '',
    kind: 'mcp',
    name: 'Search',
    summary: 'Search the web from your agent',
    version: '1.0.0',
    licence: 'MIT',
    tags: ['web'],
    agents: ['claude'],
    tier: 3,
    needs: ['node'],
    missing: [],
    cost: 'free',
    costNote: '',
    delivery: '',
    offsiteUrl: '',
    repo: 'https://github.com/acme/search',
    commit: '',
    artifactUrl: '',
    sha256: '',
    bytes: 0,
    network: ['api.acme.test'],
    updatedAt: '',
    stars: 0,
    openIssues: 0,
    ratingScore: 0,
    ratingCount: 0,
    state: 'available',
    installedVersion: '',
    message: '',
    reason: '',
    lands: ['~/.claude.json'],
    command: '',
    variables: ['ACME_KEY'],
    trigger: '',
    reach: [],
    logo: '',
    ...over,
  } as CommunityItemRow
}

function view(items: CommunityItemRow[]): CommunityViewOut {
  return { from: 'store', at: '', stale: '', because: '', problem: '', items, folder: '/x', agents: [] }
}

function deps(over: Partial<CommunityToolDeps> = {}): CommunityToolDeps {
  return {
    view: async () => view([item({}), item({ id: 'bob/notes', kind: 'skill', name: 'Notes', summary: 'Keep notes', tags: [], tier: 1, variables: [] })]),
    install: async () => ({ ok: true, message: 'Installed.' }),
    remove: async () => ({ ok: true, message: 'Removed.' }),
    ...over,
  }
}

describe('store.community', () => {
  it('says in plain words what each item runs on this Mac', async () => {
    const [tool] = communityTools(deps())
    const out = (await tool.run({}, DESK)).value as { items: { item: string; whatItRuns: string }[] }
    expect(out.items.find((row) => row.item === 'acme/search-mcp')?.whatItRuns).toBe('Runs a program on this machine')
    expect(out.items.find((row) => row.item === 'bob/notes')?.whatItRuns).toBe('Text only — nothing runs')
  })

  it('says plainly, in its description and on the confirmation, that an install runs someone else’s work', async () => {
    const [tool] = communityTools(deps())
    expect(tool.description).toContain('Installing runs someone else’s work on this Mac')
    await tool.run({}, DESK)
    const sentence = tool.summary({ action: 'install', item: 'acme/search-mcp' }, DESK)
    expect(sentence).toContain("runs someone else's work on this Mac")
    expect(sentence).toContain('Runs a program on this machine')
  })

  it('makes install and remove alter', () => {
    const [tool] = communityTools(deps())
    expect(tool.escalate?.({ action: 'install', item: 'x' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'remove', item: 'x' }, DESK)).toBe('alter')
    expect(tool.escalate?.({}, DESK)).toBe('read')
  })

  it('never writes an install’s values — often API keys — into the log', () => {
    const redacted = redactValues({ action: 'install', item: 'x', values: { ACME_KEY: 'sk-live-1234567890' } })
    expect(JSON.stringify(redacted)).not.toContain('sk-live')
    expect(redacted.values).toEqual({ ACME_KEY: '[18 characters]' })
  })

  it('passes the person’s choices to the installer the panel uses', async () => {
    const install = vi.fn<CommunityToolDeps['install']>(async () => ({ ok: true, message: '' }))
    const [tool] = communityTools(deps({ install }))
    await tool.run({ action: 'install', item: 'acme/search-mcp', agents: ['claude'], values: { ACME_KEY: 'k' } }, DESK)
    expect(install).toHaveBeenCalledWith('acme/search-mcp', { agents: ['claude'], values: { ACME_KEY: 'k' } })
  })

  it('narrows the shelf by kind and by words', async () => {
    const [tool] = communityTools(deps())
    const out = (await tool.run({ kind: 'skill' }, DESK)).value as { items: unknown[] }
    expect(out.items).toHaveLength(1)
    const found = (await tool.run({ query: 'web' }, DESK)).value as { items: { item: string }[] }
    expect(found.items.map((row) => row.item)).toEqual(['acme/search-mcp'])
  })

  it('is refused to an ordinary session', () => {
    const [tool] = communityTools(deps())
    expect(() => tool.precheck?.({}, SESSION)).toThrow('reaches only the windows attached to it')
  })
})

function storeDeps(over: Partial<ToolsStoreDeps> = {}): ToolsStoreDeps {
  return {
    list: () => ({
      view: {
        tools: [
          {
            id: 'listings',
            name: 'Listings',
            summary: 'Reads property listings',
            homepage: '',
            licence: 'MIT',
            version: '1',
            grants: [],
            origins: ['example.com'],
            url: '',
            fetched: false,
            sha256: 'a'.repeat(64),
            state: 'available',
            installedVersion: '',
            installedAt: 0,
            message: '',
            reads: [],
          },
        ],
        folder: '/x',
      },
      orphans: [],
    }),
    install: async () => ({ ok: true, message: 'Installed.' }),
    remove: () => ({ ok: true, message: 'Removed.' }),
    ...over,
  }
}

describe('browser.store', () => {
  it('lists every tool with where it runs and the digest it is pinned to', async () => {
    const [tool] = toolsStoreTools(storeDeps())
    const out = (await tool.run({}, DESK)).value as { tools: Record<string, unknown>[] }
    expect(out.tools[0]).toMatchObject({ tool: 'listings', runsOn: ['example.com'], sha256: 'a'.repeat(64) })
  })

  it('makes install and remove alter, and refuses a tool the store does not have', () => {
    const [tool] = toolsStoreTools(storeDeps())
    expect(tool.escalate?.({ action: 'install', tool: 'listings' }, DESK)).toBe('alter')
    expect(() => tool.precheck?.({ action: 'install', tool: 'nope' }, DESK)).toThrow('has no tool nope')
  })

  it('installs through the store the panel uses, and points at the tool that runs it', async () => {
    const install = vi.fn<ToolsStoreDeps['install']>(async () => ({ ok: true, message: '' }))
    const [tool] = toolsStoreTools(storeDeps({ install }))
    const out = (await tool.run({ action: 'install', tool: 'listings' }, DESK)).value as { next: string }
    expect(install).toHaveBeenCalledWith('listings')
    expect(out.next).toContain('browser.extract')
  })
})
