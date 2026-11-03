import { describe, expect, it } from 'vitest'
import {
  editMcpServer,
  mergeEnvironment,
  resolveEditRequest,
  type McpExisting,
} from './mcp-edit'
import type { McpAddResult } from './mcp-add'

/**
 * Changing a server you added.
 *
 * Two things are being pinned here, and the second one is the reason this file
 * is longer than the feature looks.
 *
 *  1. **A blank value keeps the saved one.** That promise is about somebody's
 *     API key, and the renderer is never sent one — so if the merge is wrong,
 *     the failure is a person's credential quietly replaced by an empty string
 *     in a config file they cannot see the inside of.
 *  2. **A failed edit leaves the server there.** An edit is a remove and an add,
 *     because the CLI that owns the file has no replace, and the failure that
 *     matters is the add failing after the remove succeeded.
 */

const EXISTING: McpExisting = {
  name: 'mine',
  scope: 'user',
  transport: 'stdio',
  command: 'npx -y @me/thing',
  url: '',
  env: { API_KEY: 'secret-value', REGION: 'eu' },
}

function next(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: 'mine',
    scope: 'user',
    transport: 'stdio',
    command: 'npx -y @me/thing --verbose',
    url: '',
    extras: ['API_KEY=', 'REGION='],
    projectPath: null,
    ...over,
  }
}

function request(over: Record<string, unknown> = {}): Record<string, unknown> {
  return { name: 'mine', scope: 'user', next: next(), ...over }
}

/** A recorder for the two writes, so their order and payloads can be read back. */
function spy(results: { remove?: McpAddResult; add?: McpAddResult[] } = {}) {
  const calls: { verb: 'remove' | 'add'; payload: Record<string, unknown> }[] = []
  let addAt = 0
  return {
    calls,
    deps: {
      read: () => ({ ...EXISTING }),
      remove: async (payload: unknown) => {
        calls.push({ verb: 'remove', payload: payload as Record<string, unknown> })
        return results.remove ?? { ok: true, message: 'Removed mine.' }
      },
      add: async (payload: unknown) => {
        calls.push({ verb: 'add', payload: payload as Record<string, unknown> })
        const answer = results.add?.[addAt] ?? { ok: true, message: 'Added mine.' }
        addAt += 1
        return answer
      },
    },
  }
}

describe('keeping a value this app is not allowed to see', () => {
  it('carries a saved value through a line whose value is blank', () => {
    expect(mergeEnvironment(['API_KEY=', 'REGION='], EXISTING.env)).toEqual([
      'API_KEY=secret-value',
      'REGION=eu',
    ])
  })

  it('replaces one that was typed', () => {
    expect(mergeEnvironment(['API_KEY=new'], EXISTING.env)).toEqual(['API_KEY=new'])
  })

  it('splits at the first = only, because values contain them', () => {
    expect(mergeEnvironment(['DSN=postgres://u:p@h/db?x=1'], {})).toEqual([
      'DSN=postgres://u:p@h/db?x=1',
    ])
  })

  it('drops a variable when its line is deleted', () => {
    // Deleting the line is the only gesture that reads as deleting the variable,
    // so it is the one that does it.
    expect(mergeEnvironment(['API_KEY='], EXISTING.env)).toEqual(['API_KEY=secret-value'])
    expect(mergeEnvironment([], EXISTING.env)).toEqual([])
  })

  it('refuses a blank value with nothing saved behind it, rather than writing an empty one', () => {
    // Both silent outcomes — dropping the line, or writing `KEY=` — end with a
    // person looking at a server that saved successfully and does not work.
    expect(() => mergeEnvironment(['NEW_KEY='], EXISTING.env)).toThrow(/no saved value/)
  })
})

describe('what an edit is allowed to be', () => {
  it('holds the new server to every rule an add is held to', () => {
    // A second, laxer front door to the same file is the thing this refuses to
    // be. `resolveRequest` does the work; this just must not skip it.
    expect(() => resolveEditRequest(request({ next: next({ name: '--scope' }) }))).toThrow(
      /letters, numbers/,
    )
    expect(() => resolveEditRequest(request({ next: next({ command: '' }) }))).toThrow(/command/)
    expect(() => resolveEditRequest(request({ name: '' }))).toThrow(/Name the server/)
    expect(() => resolveEditRequest(request({ scope: 'nowhere' }))).toThrow(/which scope/)
  })

  it('refuses to edit a project-scoped server with no project open', () => {
    /*
     * The remove would be aimed at this app's own working directory — `/` for a
     * packaged Mac app — and would report success having removed nothing, so the
     * add would leave two servers where there was one.
     */
    expect(() =>
      resolveEditRequest(request({ scope: 'local', next: next({ scope: 'user' }) })),
    ).toThrow(/Open the project/)
  })
})

describe('the two writes', () => {
  it('removes the old one and adds the new one, in that order, with the merged environment', async () => {
    const watcher = spy()
    const result = await editMcpServer(request(), watcher.deps)
    expect(result.ok, result.message).toBe(true)
    expect(watcher.calls.map((call) => call.verb)).toEqual(['remove', 'add'])
    expect(watcher.calls[1]?.payload.extras).toEqual(['API_KEY=secret-value', 'REGION=eu'])
    expect(watcher.calls[1]?.payload.command).toBe('npx -y @me/thing --verbose')
  })

  it('addresses the removal by the name the server has now, not the one it is getting', async () => {
    const watcher = spy()
    await editMcpServer(request({ next: next({ name: 'renamed' }) }), watcher.deps)
    expect(watcher.calls[0]?.payload.name).toBe('mine')
    expect(watcher.calls[1]?.payload.name).toBe('renamed')
  })

  it('says what it was called before, when the name changed', async () => {
    const watcher = spy()
    const result = await editMcpServer(request({ next: next({ name: 'renamed' }) }), watcher.deps)
    expect(result.message).toContain('was called mine and is now renamed')
  })

  it('writes nothing at all when the merge cannot be done', async () => {
    /*
     * Validated **before** a single write. An edit whose environment cannot be
     * resolved must fail with the old server still in the file — not after the
     * remove, with nothing in it.
     */
    const watcher = spy()
    const result = await editMcpServer(
      request({ next: next({ extras: ['MISSING='] }) }),
      watcher.deps,
    )
    expect(result.ok).toBe(false)
    expect(watcher.calls).toHaveLength(0)
  })

  it('writes nothing when the remove fails', async () => {
    const watcher = spy({ remove: { ok: false, message: 'claude is not on this machine.' } })
    const result = await editMcpServer(request(), watcher.deps)
    expect(result.ok).toBe(false)
    expect(result.message).toContain('was not changed')
    expect(watcher.calls.map((call) => call.verb)).toEqual(['remove'])
  })

  it('puts the original back when the add fails, and says so', async () => {
    /*
     * The failure this whole shape exists for: the server is gone and the
     * replacement did not land. A rollback nobody is told about is
     * indistinguishable from the data loss it prevented — and the restore has to
     * carry the *values*, which is only possible because the merge lives in this
     * process rather than in a renderer.
     */
    const watcher = spy({
      add: [{ ok: false, message: 'A server called mine already exists.' }, { ok: true, message: 'Added mine.' }],
    })
    const result = await editMcpServer(request(), watcher.deps)
    expect(result.ok).toBe(false)
    expect(result.message).toContain('has been put back exactly as it was')
    expect(watcher.calls.map((call) => call.verb)).toEqual(['remove', 'add', 'add'])
    expect(watcher.calls[2]?.payload.extras).toEqual(['API_KEY=secret-value', 'REGION=eu'])
    expect(watcher.calls[2]?.payload.command).toBe('npx -y @me/thing')
  })

  it('says outright when the rollback also failed', async () => {
    // The one moment the person has to be told their server is not there.
    const watcher = spy({
      add: [
        { ok: false, message: 'It would not write.' },
        { ok: false, message: 'It would not write.' },
      ],
    })
    const result = await editMcpServer(request(), watcher.deps)
    expect(result.message).toContain('is not in your configuration right now')
  })

  it('refuses politely when the server has gone since the page was drawn', async () => {
    const result = await editMcpServer(request(), { read: () => null })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('not in your configuration any more')
  })
})
