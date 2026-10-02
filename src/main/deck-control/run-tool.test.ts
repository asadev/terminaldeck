import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { advertiseTool } from './catalogue'
import { advertisedCatalogue } from './describe-tool'
import { keyCaller } from './key-door'
import { keyRig, type KeyRig } from './key-door.fixture'
import { RUN_ID, RUN_WIRE } from './run-tool'
import { openStandaloneDeckControlServer, type StandaloneDeckControlServer } from './server'
import { SESSION_TOOLS } from './session-tools'
import { LOCAL_CALLER } from './surface'

/**
 * `tools.run`: one listed tool that calls any other, for clients that can only
 * call what they were listed.
 *
 * The property that matters most is the one `describe-tool.ts` already holds:
 * a tool the caller may not use answers exactly like a tool that does not
 * exist. After that, that it is not a lower door — the call it makes is judged
 * by the tier, precheck, budget and confirmation of the tool it names — and
 * that it changes nothing about the copilot's own listing.
 */

let dir = ''
let rig: KeyRig
let server: StandaloneDeckControlServer | null = null

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-run-tool-'))
  rig = keyRig(dir)
})

afterEach(async () => {
  await server?.stop()
  server = null
  rig.door.stop()
  rmSync(dir, { recursive: true, force: true })
})

describe('running a tool by name', () => {
  it('runs the named tool through the dispatcher, and the row is that tool’s', async () => {
    const result = await rig.control.call(RUN_ID, { name: 'sessions_list', arguments: {} })
    expect(result.ok).toBe(true)
    expect(result.row.tool).toBe('sessions.list')
    // No row for the wrapper: the call that ran is the one written down.
    expect(rig.log.tail(10).map((row) => row.tool)).toEqual(['sessions.list'])
  })

  it('accepts either spelling, and arguments sent as a JSON string', async () => {
    expect((await rig.control.call(RUN_WIRE, { name: 'projects.list' })).row.tool).toBe('projects.list')
    expect((await rig.control.call(RUN_ID, { name: 'sessions_list', arguments: '{}' })).ok).toBe(true)
  })

  it('answers a tool outside the grant exactly as it answers one that does not exist', async () => {
    const granted = SESSION_TOOLS
    const hidden = await rig.control.call(RUN_ID, { name: 'sessions_start', arguments: { cwd: '/work/api' } }, { granted })
    const missing = await rig.control.call(RUN_ID, { name: 'sessions_teleport', arguments: { cwd: '/work/api' } }, { granted })
    expect(hidden.ok).toBe(false)
    expect(hidden.error).toBe('no tool called sessions_start')
    expect(missing.error).toBe('no tool called sessions_teleport')
    // Same shape in the log too: the wrapper's row, the name, nothing else.
    const strip = (row: typeof hidden.row): unknown => ({ ...row, id: '', at: '', ms: 0, args: {}, detail: '', error: '' })
    expect(strip(hidden.row)).toEqual(strip(missing.row))
    expect(hidden.row.tool).toBe(RUN_ID)
    expect(hidden.row.args).toEqual({ name: 'sessions_start' })
    expect(rig.app.started).toEqual([])
  })

  it('keeps the arguments of a refused call out of the log', async () => {
    const result = await rig.control.call(
      RUN_ID,
      { name: 'nothing_here', arguments: { password: 'hunter2', value: 'typed-into-a-page' } },
      {},
    )
    expect(result.ok).toBe(false)
    expect(JSON.stringify(result.row)).not.toContain('typed-into-a-page')
  })

  it('is held to the tier of the tool it runs, after escalation', async () => {
    const { id } = rig.key('look')
    const caller = keyCaller(rig.keys, id, 'x')
    const result = await rig.control.call(
      RUN_ID,
      { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
      { caller },
    )
    expect(result.refusal).toBe('not-granted')
    expect(result.row.tool).toBe('settings.write')
    expect(rig.app.settings['appearance.density']).toBe('comfortable')
  })

  it('cannot run itself', async () => {
    const result = await rig.control.call(RUN_ID, { name: RUN_WIRE, arguments: { name: 'sessions_list' } })
    expect(result.ok).toBe(false)
    expect(result.error).toMatch(/runs other tools/)
  })

  it('needs a name', async () => {
    const result = await rig.control.call(RUN_ID, {})
    expect(result.ok).toBe(false)
    expect(result.error).toMatch(/name is required/)
  })
})

describe('who is shown it', () => {
  it('leaves the copilot’s listing exactly as it was', () => {
    const copilot = advertisedCatalogue(rig.control.tools())
    expect(copilot.map((spec) => spec.id)).not.toContain(RUN_ID)
    expect(advertisedCatalogue(rig.control.tools(), { run: true }).map((spec) => spec.id)).toContain(RUN_ID)
  })

  it('is listed to a key caller, with hints that tell the truth about that key', async () => {
    server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
    const look = rig.key('look').key
    const full = rig.key('full').key
    const listed = async (key: string): Promise<Record<string, unknown> | undefined> => {
      const client = new Client({ name: 't', version: '0' }, { capabilities: {} })
      await client.connect(
        new StreamableHTTPClientTransport(new URL(server?.endpoint.url ?? ''), {
          requestInit: { headers: { Authorization: `Bearer ${key}` } },
        }),
      )
      try {
        const tools = (await client.listTools()).tools
        return tools.find((tool) => tool.name === RUN_WIRE)?.annotations as Record<string, unknown> | undefined
      } finally {
        await client.close()
      }
    }
    expect(await listed(look)).toMatchObject({ readOnlyHint: true, destructiveHint: false })
    expect(await listed(full)).toMatchObject({ readOnlyHint: false, destructiveHint: true })
  })

  it('is not listed to the copilot over the wire either', async () => {
    server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
    const client = new Client({ name: 't', version: '0' }, { capabilities: {} })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(server.endpoint.url), {
        requestInit: { headers: { Authorization: `Bearer ${server.endpoint.token}` } },
      }),
    )
    try {
      const names = (await client.listTools()).tools.map((tool) => tool.name)
      expect(names).not.toContain(RUN_WIRE)
    } finally {
      await client.close()
    }
  })

  it('reads as the same tool when advertised', () => {
    const spec = rig.control.tools().find((entry) => entry.id === RUN_ID)
    expect(spec).toBeDefined()
    if (!spec) return
    expect(advertiseTool(spec)).toMatchObject({ name: RUN_WIRE })
    expect(LOCAL_CALLER.kind).toBe('local')
  })
})
