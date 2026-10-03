import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { createServer as createTlsServer } from 'node:https'
import { connect, type AddressInfo, type Socket } from 'node:net'
import { join } from 'node:path'

/**
 * The instrument the account tests run the real Claude Code CLI against — a
 * local Anthropic that records which token every request carried, and a local
 * stand-in for the OAuth host, so nothing ever leaves the machine.
 *
 *  - **The API** is a plain HTTP server (`ANTHROPIC_BASE_URL`). Each request's
 *    `Authorization` is recorded with the time it arrived; the reply is the
 *    smallest valid streamed answer. A test can make it answer 401 instead.
 *  - **The OAuth host** cannot be moved in a public build, so the CLI is given
 *    `HTTPS_PROXY` pointing at a proxy that answers `CONNECT
 *    platform.claude.com:443` with a local TLS server, its certificate signed by
 *    a throwaway CA handed over in `NODE_EXTRA_CA_CERTS`, and refuses every
 *    other host (recorded in `refused`).
 *
 * Only ever used with made-up logins; see `fake-cipher.fixture.ts`.
 */

export interface Seen {
  auth: string
  at: number
  /** Every other header the request carried, names lower-cased. */
  headers: Record<string, string>
}

export interface Rig {
  sinkUrl: string
  proxyUrl: string
  caFile: string
  /** Every API request's Authorization, in order, with when it arrived. */
  seen: Seen[]
  /** Every OAuth token-endpoint request body. */
  refreshes: string[]
  /** Every host something tried to reach that was not a stand-in. */
  refused: string[]
  /** Decide the status code for one API request by its Authorization. Default 200. */
  respond: (auth: string) => number
  /** The token pair the OAuth stand-in hands back on a refresh. */
  refreshTo: string
  close(): Promise<void>
}

/** The minimal valid streamed reply — enough for a turn to finish normally. */
function sse(text: string): string {
  const events: Array<[string, unknown]> = [
    ['message_start', { type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-test', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } }],
    ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
    ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } }],
    ['content_block_stop', { type: 'content_block_stop', index: 0 }],
    ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } }],
    ['message_stop', { type: 'message_stop' }],
  ]
  return events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('')
}

export async function startRig(root: string): Promise<Rig> {
  const rig = {
    seen: [] as Seen[],
    refreshes: [] as string[],
    refused: [] as string[],
    respond: (_auth: string) => 200,
    refreshTo: 'REFRESHED',
  }
  const tunnels = new Set<Socket>()

  const handler = (req: IncomingMessage, res: ServerResponse): void => {
    let body = ''
    req.on('data', (chunk) => (body += String(chunk)))
    req.on('end', () => {
      const auth = String(req.headers.authorization ?? '')
      if (req.url?.startsWith('/v1/messages')) {
        const headers: Record<string, string> = {}
        for (const [name, value] of Object.entries(req.headers)) {
          if (name !== 'authorization') headers[name] = String(value)
        }
        rig.seen.push({ auth, at: Date.now(), headers })
        const status = rig.respond(auth)
        if (status !== 200) {
          res.writeHead(status, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ type: 'error', error: { type: 'authentication_error', message: 'OAuth token has expired.' } }))
          return
        }
        res.writeHead(200, { 'content-type': 'text/event-stream' })
        res.end(sse('SINK-REPLY'))
        return
      }
      if (req.url?.startsWith('/v1/oauth/token')) {
        rig.refreshes.push(body)
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(
          JSON.stringify({
            access_token: `sk-ant-oat01-${rig.refreshTo}`,
            refresh_token: `sk-ant-ort01-${rig.refreshTo}`,
            expires_in: 28_800,
            token_type: 'Bearer',
            scope: 'user:inference user:profile',
          }),
        )
        return
      }
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end('{}')
    })
  }

  const sink: Server = createServer(handler)
  await new Promise<void>((resolve) => sink.listen(0, '127.0.0.1', resolve))
  const sinkUrl = `http://127.0.0.1:${(sink.address() as AddressInfo).port}`

  const tls = join(root, 'tls')
  mkdirSync(tls, { recursive: true })
  const cnf = join(tls, 'ca.cnf')
  writeFileSync(cnf, '[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n')
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(tls, 'ca.key'), '-out', join(tls, 'ca.crt'), '-days', '1', '-subj', '/CN=td-vault-test-ca', '-config', cnf, '-extensions', 'ca'], { stdio: 'ignore' })
  execFileSync('openssl', ['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(tls, 'srv.key'), '-out', join(tls, 'srv.csr'), '-subj', '/CN=platform.claude.com', '-config', cnf], { stdio: 'ignore' })
  writeFileSync(join(tls, 'srv.ext'), 'subjectAltName=DNS:platform.claude.com\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
  execFileSync('openssl', ['x509', '-req', '-in', join(tls, 'srv.csr'), '-CA', join(tls, 'ca.crt'), '-CAkey', join(tls, 'ca.key'), '-CAcreateserial', '-out', join(tls, 'srv.crt'), '-days', '1', '-extfile', join(tls, 'srv.ext')], { stdio: 'ignore' })
  const oauth: Server = createTlsServer({ key: readFileSync(join(tls, 'srv.key')), cert: readFileSync(join(tls, 'srv.crt')) }, handler)
  await new Promise<void>((resolve) => oauth.listen(0, '127.0.0.1', resolve))
  const oauthPort = (oauth.address() as AddressInfo).port

  const proxy: Server = createServer((_req, res) => {
    rig.refused.push('plain http')
    res.writeHead(403)
    res.end()
  })
  proxy.on('connect', (req: IncomingMessage, client: Socket, head: Buffer) => {
    tunnels.add(client)
    client.on('close', () => tunnels.delete(client))
    if (req.url !== 'platform.claude.com:443') {
      rig.refused.push(String(req.url))
      client.end('HTTP/1.1 403 Forbidden\r\n\r\n')
      return
    }
    const upstream = connect(oauthPort, '127.0.0.1', () => {
      tunnels.add(upstream)
      upstream.on('close', () => tunnels.delete(upstream))
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n')
      upstream.write(head)
      upstream.pipe(client)
      client.pipe(upstream)
    })
    upstream.on('error', () => client.destroy())
    client.on('error', () => upstream.destroy())
  })
  await new Promise<void>((resolve) => proxy.listen(0, '127.0.0.1', resolve))
  const proxyUrl = `http://127.0.0.1:${(proxy.address() as AddressInfo).port}`

  const value: Rig = Object.assign(rig, {
    sinkUrl,
    proxyUrl,
    caFile: join(tls, 'ca.crt'),
    close: async () => {
      for (const tunnel of tunnels) tunnel.destroy()
      for (const server of [sink, oauth, proxy]) {
        server.closeAllConnections()
        await new Promise<void>((resolve) => server.close(() => resolve()))
      }
    },
  })
  return value
}

/** This process's environment without the parent session's identity — what a real session is spawned with. */
export function scrubbedEnv(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue
    if (/^(CLAUDE|ANTHROPIC|TERMINALDECK)/.test(key)) continue
    out[key] = value
  }
  return out
}

/** Environment flags that keep a test run of the CLI quiet and local. */
export function quietEnv(rig: Rig): Record<string, string> {
  return {
    ANTHROPIC_BASE_URL: rig.sinkUrl,
    HTTPS_PROXY: rig.proxyUrl,
    HTTP_PROXY: rig.proxyUrl,
    NO_PROXY: '127.0.0.1,localhost',
    NODE_EXTRA_CA_CERTS: rig.caFile,
    DISABLE_TELEMETRY: '1',
    DISABLE_ERROR_REPORTING: '1',
    DISABLE_AUTOUPDATER: '1',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
  }
}
