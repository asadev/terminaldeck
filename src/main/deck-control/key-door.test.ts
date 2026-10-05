import { mkdtempSync, rmSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { OUTSIDE_APP_CONSENT_TIMEOUT_MS, keySurface } from './consent'
import { standingApproval } from './control'
import { keyRig, type KeyRig, type KeyRigOptions } from './key-door.fixture'
import { keyCaller } from './key-door'
import { MCP_PATH, openStandaloneDeckControlServer, type StandaloneDeckControlServer } from './server'

/**
 * The door for AI apps outside this one, from both sides.
 *
 * The first block asks the door directly: is a key resolved per request, does
 * a revoke or a level change land on the very next call, does switching the
 * internet off close the internet road and only that road. The rest goes over
 * a real loopback socket with the SDK's own MCP client holding a key — the way
 * Claude Code, Cursor or Codex on this Mac would — and checks that every call
 * it makes passes through the same gate the copilot's do.
 */

let dir = ''
let rig: KeyRig
let server: StandaloneDeckControlServer | null = null
const clients: Client[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-key-door-'))
})

afterEach(async () => {
  for (const client of clients.splice(0)) await client.close().catch(() => undefined)
  await server?.stop()
  server = null
  rig?.door.stop()
  rmSync(dir, { recursive: true, force: true })
})

async function boot(options: KeyRigOptions = {}): Promise<void> {
  rig = keyRig(dir, options)
  server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
}

function url(): URL {
  if (!server) throw new Error('not booted')
  return new URL(server.endpoint.url)
}

async function connect(key: string, form: 'header' | 'path' = 'header'): Promise<Client> {
  const client = new Client({ name: 'outside-app', version: '9.9.9' }, { capabilities: {} })
  const target = form === 'path' ? new URL(`${url().toString()}/${key}`) : url()
  await client.connect(
    new StreamableHTTPClientTransport(
      target,
      form === 'header' ? { requestInit: { headers: { Authorization: `Bearer ${key}` } } } : {},
    ),
  )
  clients.push(client)
  return client
}

function text(result: unknown): string {
  const content = (result as { content?: Array<{ text?: string }> }).content ?? []
  return content.map((part) => part.text ?? '').join('')
}

function post(path: string, headers: Record<string, string>): Promise<number> {
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' })
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      {
        host: '127.0.0.1',
        port: url().port,
        path,
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json, text/event-stream',
          'content-length': Buffer.byteLength(body),
          ...headers,
        },
      },
      (response) => {
        response.resume()
        response.on('end', () => resolve(response.statusCode ?? 0))
      },
    )
    request.on('error', reject)
    request.end(body)
  })
}

/* ------------------------------------------------------------ the door -- */

describe('resolving a key', () => {
  beforeEach(() => {
    rig = keyRig(dir)
  })

  it('refuses a CRM\'s own key at the AI-app tools, while the task route still knows it', () => {
    const made = rig.keys.create({ name: 'Sales CRM (CRM)', level: 'look', askFirst: true, crmOnly: true })
    expect(rig.door.grant(made.key, 'this-mac', { userAgent: null })).toBeNull()
    rig.keys.setInternet(true)
    expect(rig.door.grant(made.key, 'internet', { userAgent: null })).toBeNull()
    // `/tasks` asks `keys.match`, which still answers for it.
    expect(rig.keys.match(made.key)).toMatchObject({ id: made.view.id, crmOnly: true })
    // An ordinary key is untouched.
    const { key } = rig.key('work')
    const grant = rig.door.grant(key, 'this-mac', { userAgent: null })
    expect(grant).not.toBeNull()
    grant?.done()
  })

  it('answers nothing for a key it does not know, or one that was revoked', () => {
    const { key, id } = rig.key('work')
    expect(rig.door.grant('ak_nope', 'this-mac', { userAgent: null })).toBeNull()
    expect(rig.door.grant(null, 'this-mac', { userAgent: null })).toBeNull()
    const grant = rig.door.grant(key, 'this-mac', { userAgent: null })
    expect(grant).not.toBeNull()
    grant?.done()
    rig.keys.revoke(id)
    expect(rig.door.grant(key, 'this-mac', { userAgent: null })).toBeNull()
  })

  it('keeps the internet road shut until it is switched on, and leaves this Mac’s open', () => {
    const { key } = rig.key('look')
    expect(rig.door.grant(key, 'internet', { userAgent: null })).toBeNull()
    expect(rig.door.grant(key, 'this-mac', { userAgent: null })).not.toBeNull()
    rig.keys.setInternet(true)
    expect(rig.door.grant(key, 'internet', { userAgent: null })).not.toBeNull()
  })

  it('lands a level change on the very next tool call, inside a request already open', () => {
    const { key, id } = rig.key('look')
    const grant = rig.door.grant(key, 'this-mac', { userAgent: null })
    expect(grant?.caller().tiers).toEqual({ read: true, act: false, alter: false })
    rig.keys.setLevel(id, 'full')
    expect(grant?.caller().tiers).toEqual({ read: true, act: true, alter: true })
    rig.keys.revoke(id)
    expect(grant?.caller().tiers).toEqual({ read: false, act: false, alter: false })
  })

  it('aborts a request in flight when its key is revoked', () => {
    const { key, id } = rig.key('full')
    const grant = rig.door.grant(key, 'this-mac', { userAgent: null })
    expect(grant?.signal?.aborted).toBe(false)
    expect(rig.door.inFlightCount(id)).toBe(1)
    rig.keys.revoke(id)
    expect(grant?.signal?.aborted).toBe(true)
  })

  it('aborts only the internet road’s requests when internet reach goes off', () => {
    const { key } = rig.key('full')
    rig.keys.setInternet(true)
    const local = rig.door.grant(key, 'this-mac', { userAgent: null })
    const remote = rig.door.grant(key, 'internet', { userAgent: null })
    rig.keys.setInternet(false)
    expect(remote?.signal?.aborted).toBe(true)
    expect(local?.signal?.aborted).toBe(false)
  })

  it('withdraws a revoked key’s question that is still waiting on the owner', async () => {
    const { key, id } = rig.key('full')
    const grant = rig.door.grant(key, 'this-mac', { userAgent: null })
    if (!grant) throw new Error('no grant')
    const pending = rig.control.call(
      'settings.write',
      { scope: 'settings', patch: { 'appearance.density': 'compact' } },
      { caller: grant.caller(), ...(grant.signal ? { signal: grant.signal } : {}) },
    )
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(rig.consent.list().map((question) => question.origin)).toEqual([keySurface(id)])
    rig.keys.revoke(id)
    const result = await pending
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('caller-gone')
    expect(rig.app.settings['appearance.density']).toBe('comfortable')
  })

  it('names the app from what its client says, or from its user agent until it does', () => {
    const { key, id } = rig.key('look')
    rig.door.grant(key, 'this-mac', { userAgent: 'claude-code/2.1.233 (external, cli)' })?.done()
    expect(rig.keys.get(id)?.lastApp).toBe('claude-code/2.1.233')
    const grant = rig.door.grant(key, 'internet', { userAgent: null })
    expect(grant).toBeNull()
    rig.keys.setInternet(true)
    rig.door.grant(key, 'internet', { userAgent: 'python-httpx/0.27' })?.noteClient('claude-ai 0.1.0')
    expect(rig.keys.get(id)).toMatchObject({ lastApp: 'claude-ai 0.1.0', lastVia: 'internet' })
  })

  it('builds the caller from the key as it stands', () => {
    const { id } = rig.key('work', { name: 'Cursor', folders: ['/work/site'], askFirst: false })
    expect(keyCaller(rig.keys, id, 'old name')).toMatchObject({
      kind: 'key',
      keyId: id,
      keyName: 'Cursor',
      askFirst: false,
      folders: ['/work/site'],
      tasks: false,
    })
    // The "Your tasks" switch reaches the caller the task tools check.
    rig.keys.setTasks(id, true)
    expect(keyCaller(rig.keys, id, 'old name').tasks).toBe(true)
  })
})

/* ---------------------------------------------------- over the loopback -- */

describe('an AI app on this Mac, holding a key', () => {
  it('connects, lists the tools including tools_run, and is named in the keys list', async () => {
    await boot()
    const { key, id } = rig.key('look', { name: 'Cursor' })
    const client = await connect(key)
    const listed = await client.listTools()
    const names = listed.tools.map((tool) => tool.name)
    expect(names).toContain('tools_run')
    expect(names).toContain('tools_describe')
    expect(names).toContain('sessions_list')
    // `initialize` said who it was.
    expect(rig.keys.get(id)?.lastApp).toBe('outside-app 9.9.9')
    expect(rig.keys.get(id)?.lastVia).toBe('this-mac')
    // And the server told it, in its instructions, how to reach the rest.
    expect(client.getInstructions()).toMatch(/tools_run/)
    expect(client.getInstructions()).toMatch(/may only look/)
  })

  it('runs a call through the dispatcher and writes it down under the key’s name', async () => {
    await boot()
    const { key, id } = rig.key('look', { name: 'Cursor' })
    const client = await connect(key)
    const result = await client.callTool({ name: 'sessions_list', arguments: {} })
    expect(result.isError).not.toBe(true)
    const row = rig.log.tail(5).find((entry) => entry.tool === 'sessions.list')
    expect(row?.caller).toMatchObject({ kind: 'key', keyId: id, keyName: 'Cursor' })
    expect(row?.detail.startsWith('From “Cursor”:')).toBe(true)
  })

  it('takes the key in the path for apps that cannot set a header', async () => {
    await boot()
    const { key } = rig.key('look')
    const client = await connect(key, 'path')
    const result = await client.callTool({ name: 'projects_list', arguments: {} })
    expect(result.isError).not.toBe(true)
  })

  it('refuses a wrong key, a revoked key, and a per-run token in the path', async () => {
    await boot()
    const { key, id } = rig.key('look')
    expect(await post(MCP_PATH, { authorization: `Bearer ${key}` })).toBe(200)
    expect(await post(MCP_PATH, { authorization: 'Bearer ak_wrong' })).toBe(403)
    expect(await post(`${MCP_PATH}/${server?.endpoint.token ?? ''}`, {})).toBe(403)
    rig.keys.revoke(id)
    expect(await post(MCP_PATH, { authorization: `Bearer ${key}` })).toBe(403)
    // The guards the copilot's endpoint always had still hold for keys.
    const fresh = rig.key('look').key
    expect(await post(MCP_PATH, { authorization: `Bearer ${fresh}`, origin: 'https://evil.example' })).toBe(403)
    expect(await post(MCP_PATH, { authorization: `Bearer ${fresh}`, host: 'evil.example' })).toBe(403)
  })

  it('refuses what a Look only key does not reach, in words the owner can find', async () => {
    await boot()
    const { key } = rig.key('look')
    const client = await connect(key)
    const result = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    expect(result.isError).toBe(true)
    expect(text(result)).toMatch(/set to Look only/)
    expect(rig.asked).toEqual([])
    expect(rig.app.settings['appearance.density']).toBe('comfortable')
  })

  it('puts a big change to the owner first, with who is asking, on a shorter clock', async () => {
    await boot()
    const { key, id } = rig.key('full', { name: 'ChatGPT' })
    const client = await connect(key)
    const call = client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    await waitFor(() => rig.asked.length === 1)
    const question = rig.asked[0]
    expect(question.origin).toBe(keySurface(id))
    expect(question.label).toMatch(/“ChatGPT”/)
    // The app travels beside the tool's own sentence: the desktop names it in
    // the headline, a phone in front of the sentence (`copilot-consent.ts`).
    expect(question.askedBy).toBe('ChatGPT')
    expect(question.summary.startsWith('From')).toBe(false)
    const { toConsentQuestion } = await import('../remote/copilot-consent')
    expect(toConsentQuestion(question).summary.startsWith('From “ChatGPT”:')).toBe(true)
    expect(question.expiresAt - question.requestedAt).toBeLessThanOrEqual(OUTSIDE_APP_CONSENT_TIMEOUT_MS)
    // His phone may answer a key's question; it is not any device's own.
    expect(rig.consent.mayAnswer(question.id, 'device:phone-1')).toBe(true)
    expect(rig.consent.respond(question.id, true, 'device:phone-1')).toBe(true)
    const result = await call
    expect(result.isError).not.toBe(true)
    expect(rig.app.settings['appearance.density']).toBe('compact')
  })

  it('answers an unattended Mac’s silence with a clean refusal, inside the client’s patience', async () => {
    await boot({ consentTimeoutMs: 80 })
    const { key } = rig.key('full')
    const client = await connect(key)
    const result = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    expect(result.isError).toBe(true)
    expect(text(result)).toMatch(/nobody answered/)
    expect(text(result)).toMatch(/Nothing was changed/)
    expect(rig.app.settings['appearance.density']).toBe('comfortable')
  })

  it('says plainly when there is nowhere to ask at all', async () => {
    await boot({ approver: false })
    const { key } = rig.key('full')
    const client = await connect(key)
    const result = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    expect(text(result)).toMatch(/nowhere to ask them/)
  })

  it('runs a big change without asking only when the key says so, and writes that down', async () => {
    await boot()
    const { key, id } = rig.key('full', { name: 'My server', askFirst: false })
    const client = await connect(key)
    const result = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    expect(result.isError).not.toBe(true)
    expect(rig.asked).toEqual([])
    const row = rig.log.tail(5).find((entry) => entry.tool === 'settings.write')
    expect(row?.confirmed).toMatchObject({ required: true, granted: true, by: standingApproval(id) })
    expect(row?.detail).toMatch(/without asking/)
    expect(row?.detail).not.toMatch(/allowed by the person/)
  })

  it('still refuses the settings nobody may write, whatever the key says', async () => {
    await boot()
    const { key } = rig.key('full', { askFirst: false })
    const client = await connect(key)
    const result = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'remote.enabled': false } } },
    })
    expect(result.isError).toBe(true)
    expect(rig.app.settings['remote.enabled']).toBeUndefined()
  })

  it('starts sessions only in the folders a key was limited to', async () => {
    await boot()
    const { key } = rig.key('work', { folders: ['/work/site'] })
    const client = await connect(key)
    const refused = await client.callTool({
      name: 'sessions_start',
      arguments: { cwd: '/work/api', brief: undefined },
    })
    expect(refused.isError).toBe(true)
    expect(text(refused)).toMatch(/may only start sessions in: \/work\/site/)
    expect(rig.app.started).toEqual([])
    const started = await client.callTool({ name: 'sessions_start', arguments: { cwd: '/work/site' } })
    expect(started.isError).not.toBe(true)
    expect(rig.app.started).toEqual(['/work/site'])
  })

  it('spends its own budget, not the copilot’s', async () => {
    await boot({ budgets: { all: { limit: 3, windowMs: 60_000 } } })
    const { key } = rig.key('look')
    const client = await connect(key)
    for (let i = 0; i < 3; i += 1) await client.callTool({ name: 'sessions_list', arguments: {} })
    const fourth = await client.callTool({ name: 'sessions_list', arguments: {} })
    expect(text(fourth)).toMatch(/too many tool calls/)
    // The copilot at the desk is untouched by an outside app's loop.
    const copilot = await rig.control.call('sessions.list', {})
    expect(copilot.ok).toBe(true)
  })
})

describe('the loopback port', () => {
  it('serves on the port it was asked for, and moves honestly when that one is taken', async () => {
    rig = keyRig(dir)
    const first = await openStandaloneDeckControlServer({ control: rig.control, preferredPort: 0 })
    const wanted = first.endpoint.port
    await first.stop()
    const again = await openStandaloneDeckControlServer({ control: rig.control, preferredPort: wanted })
    try {
      expect(again.endpoint.port).toBe(wanted)
      const second = await openStandaloneDeckControlServer({ control: rig.control, preferredPort: wanted })
      try {
        expect(second.endpoint.port).not.toBe(wanted)
        expect(second.endpoint.port).toBeGreaterThan(0)
      } finally {
        await second.stop()
      }
    } finally {
      await again.stop()
    }
  })
})

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('timed out')
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}
