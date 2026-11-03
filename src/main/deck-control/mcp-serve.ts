/**
 * One MCP exchange, answered in whichever protocol era the caller speaks.
 *
 * ## Two eras on one address
 *
 * Every client this server had until October 2026 speaks the 2025-era protocol:
 * an `initialize` handshake, then requests. ChatGPT's MCP Events — the one
 * server push an AI app actually acts on — need the 2026-07-28 revision, which
 * has no handshake: every request carries its protocol version and the
 * client's identity in `_meta`, and a server must answer `server/discover`.
 *
 * Both are served here, at the same URL, by the same `createMcpServer` factory,
 * so the two eras can never offer different tools:
 *
 *  - **2025-era** requests go through the SDK's web-standard Streamable HTTP
 *    transport, stateless and answering plain JSON, exactly as this server
 *    always has. claude.ai, Claude Code, Cursor, Codex, Gemini CLI, the channel
 *    bridge and every test see the same bytes they saw on SDK 1.x.
 *  - **2026-era** requests go through the SDK's `createMcpHandler`, which owns
 *    the new rules — `server/discover`, the envelope, the standard headers.
 *
 * Which is which is the SDK's own decision (`isLegacyRequest`), not a guess here,
 * so the routing can never disagree with the handler it routes to.
 *
 * ## `subscriptions/listen` is not offered
 *
 * It is a response stream that stays open for as long as the client wants list
 * changes. This server's tool list does not change under a client, and the
 * relay answers a request only once it is complete, so an open-ended stream
 * would hang there. It is refused at once, as a method this server does not
 * have, rather than left to hang.
 *
 * ## The standard headers the relay cannot carry
 *
 * The 2026 revision requires `Mcp-Method` (and `Mcp-Name` for `tools/call`) on
 * every request, mirroring the body, so that proxies can route without reading
 * it. The relay forwards a fixed set of headers and not these; it does not
 * route on them either. So a request that came through the relay has them put
 * back from its own body by {@link withStandardHeaders} — the same values an
 * honest client sent, and no way for a dishonest one to make the header and the
 * body disagree, because there is only the body.
 */

import {
  createMcpHandler,
  isLegacyRequest,
  WebStandardStreamableHTTPServerTransport,
  type Server,
} from '@modelcontextprotocol/server'

export type McpEra = 'legacy' | 'modern'

export interface McpAnswer {
  status: number
  headers: Headers
  body: Uint8Array
}

export interface ServeMcpOptions {
  /** The request, with its body still readable or already parsed into `parsed`. */
  request: Request
  parsed: unknown
  /** A fresh server for this one exchange. Called once, or not at all. */
  server(era: McpEra): Server
  /** Fires when the caller hangs up or loses the right to be answered. */
  signal?: AbortSignal
}

/** Methods whose body names something the `Mcp-Name` header mirrors. */
const NAME_FIELD: Record<string, string> = {
  'tools/call': 'name',
  'prompts/get': 'name',
  'resources/read': 'uri',
  'tasks/get': 'taskId',
  'tasks/update': 'taskId',
  'tasks/cancel': 'taskId',
}

/** A header value, or the spec's base64 sentinel when the text is not plain visible ASCII. */
function headerValue(text: string): string {
  return /^[\x21-\x7e](?:[\x20-\x7e]*[\x21-\x7e])?$/.test(text)
    ? text
    : `=?base64?${Buffer.from(text, 'utf8').toString('base64')}?=`
}

/**
 * `Mcp-Method` and `Mcp-Name`, rebuilt from a single JSON-RPC request's body.
 *
 * Only for a request — a notification is exempt from the presence rule, and a
 * batch is a 2025-era shape. Headers already present are replaced, because the
 * body is the only source this road has.
 */
export function withStandardHeaders(headers: Headers, parsed: unknown): Headers {
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return headers
  const message = parsed as Record<string, unknown>
  if (typeof message.method !== 'string' || message.id === undefined) return headers
  headers.set('mcp-method', headerValue(message.method))
  const field = NAME_FIELD[message.method]
  const params = message.params as Record<string, unknown> | undefined
  const name = field === undefined ? undefined : params?.[field]
  if (typeof name === 'string') headers.set('mcp-name', headerValue(name))
  return headers
}

function isListen(parsed: unknown): parsed is { id: unknown } {
  return (
    typeof parsed === 'object' &&
    parsed !== null &&
    (parsed as Record<string, unknown>).method === 'subscriptions/listen'
  )
}

function notOffered(id: unknown): McpAnswer {
  const body = JSON.stringify({
    jsonrpc: '2.0',
    id: id ?? null,
    error: { code: -32601, message: 'subscriptions/listen is not offered: this server’s lists do not change.' },
  })
  return {
    status: 200,
    headers: new Headers({ 'content-type': 'application/json' }),
    body: new TextEncoder().encode(body),
  }
}

async function buffered(response: Response): Promise<McpAnswer> {
  return { status: response.status, headers: response.headers, body: new Uint8Array(await response.arrayBuffer()) }
}

/**
 * Answer one MCP request, whichever era, and hand back the whole answer.
 *
 * Buffered rather than streamed: both roads into this server want the whole
 * answer — the relay frames it as one message, and the loopback road writes one
 * JSON body — and buffering is what lets the per-exchange server be closed the
 * moment the answer exists.
 */
export async function serveMcp(options: ServeMcpOptions): Promise<McpAnswer> {
  const { request, parsed, signal } = options
  if (await isLegacyRequest(request, parsed)) {
    const mcp = options.server('legacy')
    const transport = new WebStandardStreamableHTTPServerTransport({
      // Stateless: no session id, nothing to resume, nothing to expire.
      sessionIdGenerator: undefined,
      // Plain JSON rather than an SSE stream with a single event in it.
      enableJsonResponse: true,
    })
    /*
     * The caller hanging up has to reach the tool call: closing the transport
     * aborts every in-flight handler's signal, which `control.ts` turns into a
     * `caller-gone` refusal, so a confirmation nobody is waiting for is
     * withdrawn rather than approved.
     */
    const close = (): void => {
      void transport.close().catch(() => undefined)
    }
    if (signal?.aborted) close()
    signal?.addEventListener('abort', close, { once: true })
    try {
      await mcp.connect(transport)
      return await buffered(await transport.handleRequest(request, { parsedBody: parsed }))
    } finally {
      signal?.removeEventListener('abort', close)
      await mcp.close().catch(() => undefined)
    }
  }

  if (isListen(parsed)) return notOffered(parsed.id)
  /*
   * A handler per exchange, like the server it makes: nothing is shared between
   * two requests, which is the whole of this server's statelessness. Strict
   * about the era (`legacy: 'reject'`) because 2025 traffic never reaches here.
   */
  const handler = createMcpHandler(() => options.server('modern'), { legacy: 'reject' })
  try {
    return await buffered(await handler.fetch(request, { parsedBody: parsed }))
  } finally {
    await handler.close().catch(() => undefined)
  }
}
