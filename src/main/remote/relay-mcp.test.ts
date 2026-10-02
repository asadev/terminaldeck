/**
 * An AI app on the internet reaching this Mac's tools, end to end.
 *
 * Every piece is the real one: the relay from `relay/src/rendezvous` on a
 * loopback port, the desktop's own `relay-client`, the switchboard, the access
 * key door, a real `DeckControl` with its consent broker and action log, and
 * the official MCP SDK client — the one claude.ai's and ChatGPT's connectors
 * are built on — dialling the relay's HTTP route with a key, in both the
 * header form and the secret-link form.
 *
 * The relay's own half (body cap, rate limit, 404s, never logging a path) is
 * pinned in `relay/src/rendezvous.test.ts`. What is pinned here is the
 * desktop's: that a relayed request is answered by the same handler, gated by
 * the same key check and the same dispatcher, and that everything that means
 * "no" looks, from outside, exactly like a Mac that is not there.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRelayServer, type RelayServer } from '../../../relay/src/rendezvous'
import * as relayMirror from '../../../relay/src/mcp-route'
import * as wire from '../../shared/relay-wire'
import { keyRig, type KeyRig, type KeyRigOptions } from '../deck-control/key-door.fixture'
import { loadHostIdentity } from './host-identity'
import { createRelayClient, type RelayLink } from './relay-client'
import { RelayMcpSwitchboard, type RelayMcpAnswerer } from './relay-mcp'

let dir = ''
let relay: RelayServer | null = null
let link: RelayLink | null = null
let rig: KeyRig | null = null
const clients: Client[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-relay-mcp-'))
})

afterEach(async () => {
  for (const client of clients.splice(0)) await client.close().catch(() => undefined)
  link?.stop()
  link = null
  rig?.door.stop()
  rig = null
  await relay?.close()
  relay = null
  rmSync(dir, { recursive: true, force: true })
})

async function waitFor(predicate: () => boolean, label: string, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

interface Rigged {
  port: number
  hostId: string
  board: RelayMcpSwitchboard
}

/** A relay, this Mac's link to it, and an answerer behind the switchboard. */
async function boot(answerer: RelayMcpAnswerer | 'keys', options: KeyRigOptions = {}): Promise<Rigged> {
  relay = createRelayServer({ heartbeatMs: 60_000 })
  await new Promise<void>((resolve) => relay?.server.listen(0, '127.0.0.1', resolve))
  const port = (relay.server.address() as AddressInfo).port
  const board = new RelayMcpSwitchboard()
  if (answerer === 'keys') {
    rig = keyRig(dir, options)
    board.install(rig.door)
  } else {
    board.install(answerer)
  }
  const identity = loadHostIdentity(join(dir, 'identity'))
  link = createRelayClient({
    url: `ws://127.0.0.1:${port}`,
    identity,
    isKnownDevice: () => false,
    baseBackoffMs: 20,
    maxBackoffMs: 100,
    watchdogMs: 0,
    mcp: board,
  })
  link.start(() => false)
  await waitFor(() => link?.state().connected === true, 'the link')
  return { port, hostId: identity.hostId, board }
}

function raw(
  port: number,
  path: string,
  init: { headers?: Record<string, string>; body?: string } = {},
): Promise<{ status: number; body: string }> {
  const body = init.body ?? '{"jsonrpc":"2.0","id":1,"method":"ping"}'
  return new Promise((resolve, reject) => {
    const request = httpRequest(
      {
        host: '127.0.0.1',
        port,
        path,
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json, text/event-stream',
          'content-length': Buffer.byteLength(body),
          ...init.headers,
        },
      },
      (response) => {
        let text = ''
        response.setEncoding('utf8')
        response.on('data', (chunk: string) => (text += chunk))
        response.on('end', () => resolve({ status: response.statusCode ?? 0, body: text }))
      },
    )
    request.on('error', reject)
    request.end(body)
  })
}

async function connect(port: number, hostId: string, key: string, form: 'link' | 'header' = 'link'): Promise<Client> {
  const client = new Client({ name: 'claude-ai', version: '0.1.0' }, { capabilities: {} })
  const url =
    form === 'link'
      ? new URL(`http://127.0.0.1:${port}/mcp/${hostId}/${key}`)
      : new URL(`http://127.0.0.1:${port}/mcp/${hostId}`)
  await client.connect(
    new StreamableHTTPClientTransport(
      url,
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

describe('the relay wire contract, MCP half', () => {
  it('agrees with the relay’s own copy, field for field', () => {
    // Two implementations of one wire, safe only because this fails the moment
    // they disagree — the same bargain the host-id cross-check makes.
    expect(relayMirror.MCP_ENVELOPE).toEqual(wire.MCP_ENVELOPE)
    expect(relayMirror.RELAY_MCP_PREFIX).toBe(wire.RELAY_MCP_PREFIX)
    expect(relayMirror.MCP_MAX_REQUEST_BYTES).toBe(wire.MCP_MAX_REQUEST_BYTES)
    expect(relayMirror.MCP_MAX_RESPONSE_BYTES).toBe(wire.MCP_MAX_RESPONSE_BYTES)
    expect(relayMirror.MCP_RELAY_WAIT_MS).toBe(wire.MCP_RELAY_WAIT_MS)
    expect(relayMirror.MCP_RATE_PER_MINUTE).toBe(wire.MCP_RATE_PER_MINUTE)
    expect(relayMirror.MCP_MAX_IN_FLIGHT).toBe(wire.MCP_MAX_IN_FLIGHT)
    expect(relayMirror.MCP_REPLY_FIRST).toBe(wire.MCP_REPLY_FIRST)
    expect(relayMirror.MCP_REPLY_LAST).toBe(wire.MCP_REPLY_LAST)
    expect(relayMirror.MCP_NOT_FOUND_STATUS).toBe(wire.MCP_NOT_FOUND_STATUS)
    expect(relayMirror.MCP_NOT_FOUND_BODY).toBe(wire.MCP_NOT_FOUND_BODY)
    // And the codecs read each other's bytes.
    const head = { pathKey: 'k', authorization: null, protocolVersion: '2025-06-18', userAgent: null }
    const decoded = wire.decodeMcpRequest(relayMirror.encodeMcpRequest(head, Buffer.from('{}')))
    expect(decoded).toEqual({ head: { v: 1, ...head }, body: Buffer.from('{}') })
    const reply = wire.encodeMcpReply(wire.MCP_REPLY_FIRST | wire.MCP_REPLY_LAST, { status: 200, contentType: 'application/json' }, Buffer.from('x'))
    expect(relayMirror.decodeMcpReply(reply)).toEqual({
      first: true,
      last: true,
      head: { status: 200, contentType: 'application/json' },
      chunk: Buffer.from('x'),
    })
  })

  it('waits at least as long as any confirmation the desktop can raise', async () => {
    const { DEFAULT_CONSENT_TIMEOUT_MS, OUTSIDE_APP_CONSENT_TIMEOUT_MS } = await import('../deck-control/consent')
    expect(wire.MCP_RELAY_WAIT_MS).toBeGreaterThan(DEFAULT_CONSENT_TIMEOUT_MS)
    expect(wire.MCP_RELAY_WAIT_MS).toBeGreaterThan(OUTSIDE_APP_CONSENT_TIMEOUT_MS)
  })
})

describe('an AI app on the internet, through the relay', () => {
  it('connects with the secret link, lists tools_run, and calls a tool', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key, id } = rig.key('look', { name: 'Claude on the web' })
    const client = await connect(port, hostId, key)
    const names = (await client.listTools()).tools.map((tool) => tool.name)
    expect(names).toContain('tools_run')
    expect(names).toContain('tools_describe')
    const result = await client.callTool({ name: 'sessions_list', arguments: {} })
    expect(result.isError).not.toBe(true)
    expect(text(result)).toContain('session-1')
    const row = rig.log.tail(5).find((entry) => entry.tool === 'sessions.list')
    expect(row?.caller).toMatchObject({ kind: 'key', keyId: id, keyName: 'Claude on the web' })
    expect(rig.keys.get(id)).toMatchObject({ lastVia: 'internet', lastApp: 'claude-ai 0.1.0' })
  })

  it('takes the key in an Authorization header as well', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key } = rig.key('look')
    const client = await connect(port, hostId, key, 'header')
    expect((await client.callTool({ name: 'projects_list', arguments: {} })).isError).not.toBe(true)
  })

  it('reaches a held-back tool through tools_describe and tools_run, as a listed-tools-only client must', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key } = rig.key('look')
    const client = await connect(port, hostId, key)
    const described = await client.callTool({ name: 'tools_describe', arguments: { tools: ['sessions_get'] } })
    expect(text(described)).toContain('sessions_get')
    const ran = await client.callTool({ name: 'tools_run', arguments: { name: 'sessions_get', arguments: { sessionId: 'session-1' } } })
    expect(ran.isError).not.toBe(true)
  })

  it('looks exactly like an offline Mac for a wrong key, a revoked key, or internet reach off', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    const { key, id } = rig.key('full')
    // Off: the relay was told this Mac does not serve, and answers itself.
    const off = await raw(port, `/mcp/${hostId}/${key}`)
    expect(off).toEqual({ status: wire.MCP_NOT_FOUND_STATUS, body: wire.MCP_NOT_FOUND_BODY })

    rig.keys.setInternet(true)
    await waitFor(() => true, 'reach')
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect((await raw(port, `/mcp/${hostId}/${key}`)).status).toBe(200)
    // Wrong and revoked are answered by the desktop, with the relay's own bytes.
    const wrong = await raw(port, `/mcp/${hostId}/ak_this-is-not-a-key-at-all-xxxxxxxxxxxxxxxx`)
    expect(wrong).toEqual(off)
    rig.keys.revoke(id)
    expect(await raw(port, `/mcp/${hostId}/${key}`)).toEqual(off)
  })

  it('puts a big change to the owner and runs it when they allow it on their phone', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key } = rig.key('full', { name: 'ChatGPT' })
    const client = await connect(port, hostId, key)
    const call = client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    await waitFor(() => (rig?.asked.length ?? 0) === 1, 'the question')
    const question = rig.asked[0]
    expect(rig.consent.respond(question.id, true, 'device:his-phone')).toBe(true)
    const result = await call
    expect(result.isError).not.toBe(true)
    expect(rig.app.settings['appearance.density']).toBe('compact')
  })

  it('refuses cleanly when nobody answers, before the relay or the app gives up', async () => {
    const { port, hostId } = await boot('keys', { consentTimeoutMs: 100 })
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key } = rig.key('full')
    const client = await connect(port, hostId, key)
    const result = await client.callTool({
      name: 'tools_run',
      arguments: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    expect(result.isError).toBe(true)
    expect(text(result)).toMatch(/nobody answered/)
    expect(rig.app.settings['appearance.density']).toBe('comfortable')
  })

  it('withdraws the question when the app hangs up', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key } = rig.key('full')
    const body = JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'settings_write', arguments: { scope: 'settings', patch: { 'appearance.density': 'compact' } } },
    })
    const request = httpRequest({
      host: '127.0.0.1',
      port,
      path: `/mcp/${hostId}/${key}`,
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        'content-length': Buffer.byteLength(body),
      },
    })
    request.on('error', () => undefined)
    request.end(body)
    await waitFor(() => (rig?.consent.list().length ?? 0) === 1, 'the question')
    request.destroy()
    await waitFor(() => (rig?.consent.list().length ?? 1) === 0, 'the question to be withdrawn')
    await waitFor(() => rig?.log.tail(5).some((row) => row.tool === 'settings.write') === true, 'the row')
    const row = rig.log.tail(5).find((entry) => entry.tool === 'settings.write')
    expect(row?.confirmed.reason).toBe('caller-gone')
    expect(rig.app.settings['appearance.density']).toBe('comfortable')
  })

  it('closes the internet road the moment it is switched off', async () => {
    const { port, hostId } = await boot('keys')
    if (!rig) throw new Error('no rig')
    rig.keys.setInternet(true)
    const { key } = rig.key('look')
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect((await raw(port, `/mcp/${hostId}/${key}`)).status).toBe(200)
    rig.keys.setInternet(false)
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect((await raw(port, `/mcp/${hostId}/${key}`)).status).toBe(404)
  })

  it('carries an answer bigger than one relay frame', async () => {
    const big = Buffer.alloc(200 * 1024, 0x61)
    const answerer: RelayMcpAnswerer = {
      serving: () => true,
      answer: async () => ({ status: 200, contentType: 'application/json', body: Buffer.concat([Buffer.from('"'), big, Buffer.from('"')]) }),
      onChange: () => () => undefined,
    }
    const { port, hostId } = await boot(answerer)
    await new Promise((resolve) => setTimeout(resolve, 30))
    const answered = await raw(port, `/mcp/${hostId}/ak_whatever-the-answerer-decides-xxxxxxxx`)
    expect(answered.status).toBe(200)
    expect(answered.body.length).toBe(big.length + 2)
  })
})
