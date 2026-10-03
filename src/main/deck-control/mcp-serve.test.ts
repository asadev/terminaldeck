import { Server } from '@modelcontextprotocol/server'
import { describe, expect, it } from 'vitest'
import { serveMcp, withStandardHeaders, type McpEra } from './mcp-serve'

/**
 * The two protocol eras on one address, and the headers the relay drops.
 *
 * A tiny server stands in for `createMcpServer` so what is under test is the
 * routing: which era a request is served in, that the old era still answers
 * plain JSON, and that a 2026 request with its standard headers rebuilt from
 * the body is accepted where the same request without them is refused — which
 * is exactly the request the relay delivers.
 */

const ENVELOPE = {
  'io.modelcontextprotocol/protocolVersion': '2026-07-28',
  'io.modelcontextprotocol/clientCapabilities': {},
  'io.modelcontextprotocol/clientInfo': { name: 'test', version: '1' },
}

function factory(eras: McpEra[]) {
  return (era: McpEra): Server => {
    eras.push(era)
    const server = new Server({ name: 'probe', version: '1' }, { capabilities: { tools: {} } })
    server.setRequestHandler('tools/list', async () => ({ tools: [{ name: 'echo', inputSchema: { type: 'object' as const } }] }))
    server.setRequestHandler('tools/call', async (request) => ({
      content: [{ type: 'text' as const, text: `called ${request.params.name}` }],
    }))
    return server
  }
}

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request('http://relay.invalid/mcp', {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...headers },
    body: JSON.stringify(body),
  })
}

function json(answer: { body: Uint8Array }): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(answer.body)) as Record<string, unknown>
}

describe('withStandardHeaders', () => {
  it('puts Mcp-Method, and Mcp-Name for a named call, back from the body', () => {
    const headers = withStandardHeaders(new Headers(), { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'sessions_list' } })
    expect(headers.get('mcp-method')).toBe('tools/call')
    expect(headers.get('mcp-name')).toBe('sessions_list')
  })

  it('replaces what was there, encodes a name that is not plain ASCII, and leaves notifications and batches alone', () => {
    const replaced = withStandardHeaders(new Headers({ 'mcp-method': 'tools/list' }), {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'résumé tool' },
    })
    expect(replaced.get('mcp-method')).toBe('tools/call')
    expect(replaced.get('mcp-name')).toBe(`=?base64?${Buffer.from('résumé tool').toString('base64')}?=`)
    expect(withStandardHeaders(new Headers(), { jsonrpc: '2.0', method: 'notifications/initialized' }).has('mcp-method')).toBe(false)
    expect(withStandardHeaders(new Headers(), [{ jsonrpc: '2.0', id: 1, method: 'ping' }]).has('mcp-method')).toBe(false)
  })
})

describe('serveMcp', () => {
  it('serves a 2025-era request in the old era, as plain JSON', async () => {
    const eras: McpEra[] = []
    const body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'echo', arguments: {} } }
    const answer = await serveMcp({ request: post(body), parsed: body, server: factory(eras) })
    expect(eras).toEqual(['legacy'])
    expect(answer.status).toBe(200)
    expect(answer.headers.get('content-type')).toMatch(/^application\/json/)
    expect(json(answer)).toMatchObject({ result: { content: [{ type: 'text', text: 'called echo' }] } })
  })

  it('serves a 2026-era request in the new era once its standard headers are back', async () => {
    const body = { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'echo', arguments: {}, _meta: ENVELOPE } }
    const bare = { 'mcp-protocol-version': '2026-07-28' }

    // As the relay delivers it, with nothing put back: refused, header missing.
    const refused = await serveMcp({ request: post(body, bare), parsed: body, server: factory([]) })
    expect(refused.status).toBe(400)
    expect(json(refused)).toMatchObject({ error: { code: -32020 } })

    // The same request, its headers rebuilt from the body: answered, in the new era.
    const eras: McpEra[] = []
    const request = new Request('http://relay.invalid/mcp', {
      method: 'POST',
      headers: withStandardHeaders(
        new Headers({ 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...bare }),
        body,
      ),
      body: JSON.stringify(body),
    })
    const answer = await serveMcp({ request, parsed: body, server: factory(eras) })
    expect(eras).toEqual(['modern'])
    expect(answer.status).toBe(200)
    expect(json(answer)).toMatchObject({ result: { content: [{ text: 'called echo' }], resultType: 'complete' } })
  })

  it('refuses subscriptions/listen at once', async () => {
    const eras: McpEra[] = []
    const body = { jsonrpc: '2.0', id: 3, method: 'subscriptions/listen', params: { _meta: ENVELOPE } }
    const answer = await serveMcp({ request: post(body, { 'mcp-protocol-version': '2026-07-28' }), parsed: body, server: factory(eras) })
    expect(json(answer)).toMatchObject({ id: 3, error: { code: -32601 } })
    expect(eras).toEqual([])
  })
})
