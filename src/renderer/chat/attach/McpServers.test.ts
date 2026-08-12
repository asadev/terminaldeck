import { describe, expect, it } from 'vitest'
import { readServers, rowDetail, toolPrefix } from './McpServers'

/**
 * The status rows cross the preload as `unknown` — the renderer cannot import
 * `src/main/mcp-client.ts` — so this is the only place the two shapes are held
 * against each other.
 */

const FULL = {
  id: 'user:github',
  name: 'github',
  scope: 'user',
  transport: 'stdio',
  enabled: true,
  disabledReason: null,
  unsupported: null,
  state: 'idle',
}

describe('reading the server list', () => {
  it('keeps the fields the panel shows', () => {
    expect(readServers([FULL])).toEqual([
      {
        id: 'user:github',
        name: 'github',
        scope: 'user',
        transport: 'stdio',
        enabled: true,
        disabledReason: null,
      },
    ])
  })

  it('carries the reason the CLI would skip a server', () => {
    const rows = readServers([{ ...FULL, enabled: false, disabledReason: 'not approved for this project' }])
    expect(rows?.[0]).toMatchObject({ enabled: false, disabledReason: 'not approved for this project' })
  })

  it('drops a row with no identity rather than rendering a blank one', () => {
    expect(readServers([{ scope: 'user' }, FULL])).toHaveLength(1)
  })

  it('keeps a partial row but does not invent what it omits', () => {
    // A row that reaches this far still describes a real server, so it renders;
    // "user · stdio" underneath it would be two facts nobody read.
    expect(readServers([{ id: 'x', name: 'x' }])?.[0]).toMatchObject({
      scope: null,
      transport: null,
      enabled: true,
    })
  })

  it('tells "not an array" apart from "no servers"', () => {
    // null is what the harness's proxy hands back for an unwired method, and
    // it has to read as a broken bridge, not as an empty configuration.
    expect(readServers(null)).toBeNull()
    expect(readServers(undefined)).toBeNull()
    expect(readServers([])).toEqual([])
  })
})

describe('the line under a server name', () => {
  const row = readServers([FULL])![0]

  it('describes the server from what was read', () => {
    expect(rowDetail(row)).toBe('user · stdio')
  })

  it('gives the reason it is off precedence over the description', () => {
    expect(rowDetail({ ...row, enabled: false, disabledReason: 'not approved' })).toBe('not approved')
  })

  it('says nothing at all rather than guessing', () => {
    expect(rowDetail({ ...row, scope: null, transport: null })).toBe('')
    expect(rowDetail({ ...row, transport: null })).toBe('user')
  })
})

describe('the tool namespace', () => {
  it('is the prefix every tool on a server shares', () => {
    expect(toolPrefix('github')).toBe('mcp__github__')
  })
})
