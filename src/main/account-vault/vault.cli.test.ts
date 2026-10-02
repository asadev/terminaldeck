import { execFile, execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { createServer as createTlsServer } from 'node:https'
import { connect, type AddressInfo, type Socket } from 'node:net'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { withPath } from '../platform/host'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV, writeSecurityShim } from './keychain-shim'
import { startVaultSocket, TicketBook, type VaultSocket } from './server'
import { AccountVault } from './store'

/**
 * The real Claude Code CLI, reading its login out of the vault — measured, not
 * argued. Off unless `TD_LIVE_CLAUDE` names the binary, because it needs the
 * CLI installed and CI has none:
 *
 *     TD_LIVE_CLAUDE=$(command -v claude) npx vitest run src/main/account-vault/vault.cli.test.ts
 *
 * Nothing real is touched, and each of these is what makes that true rather
 * than hoped:
 *
 *  - **No real login.** Every credential is a made-up string from
 *    `fake-cipher.fixture.ts`; nothing here could sign in anywhere.
 *  - **No login keychain.** The shim's fallback "real" `security` is a script in
 *    the scratch folder that answers "not found" to everything and logs what it
 *    was asked. `/usr/bin/security` is never on the path the shim falls back to.
 *  - **No network.** The API is a local server (`ANTHROPIC_BASE_URL`). The
 *    OAuth token endpoint cannot be moved in a public build — `s()` in the
 *    shipped binary is `return "prod"` — so the CLI is given `HTTPS_PROXY`
 *    pointing at a local proxy that answers `CONNECT platform.claude.com:443`
 *    with a local TLS server (its certificate signed by a throwaway CA handed
 *    over in `NODE_EXTRA_CA_CERTS`) and refuses every other host. Nothing can
 *    leave this machine; anything that tries is refused and recorded.
 *  - **No real config.** `HOME` and `CLAUDE_CONFIG_DIR` are scratch folders,
 *    and the parent session's `CLAUDE_*` identity is scrubbed, exactly as
 *    `session-env.ts` scrubs it for a real session.
 */

const BIN = process.env.TD_LIVE_CLAUDE ?? ''
const LIVE = BIN !== '' && existsSync(BIN) && process.platform === 'darwin'

/** The minimal valid streamed reply — enough for `-p` to finish normally. */
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

describe.skipIf(!LIVE)('the real CLI, signed in from the vault', () => {
  let root = ''
  let sink: Server
  let sinkUrl = ''
  let oauth: Server
  let proxy: Server
  let proxyUrl = ''
  let caFile = ''
  /** Every host something tried to reach that was not the OAuth stand-in. */
  const refused: string[] = []
  /** CONNECT tunnels, which a server's own close does not track. */
  const tunnels = new Set<Socket>()
  const seen: string[] = []
  const refreshes: string[] = []
  let vault: AccountVault
  let tickets: TicketBook
  let socket: VaultSocket
  let shimDir = ''
  let fakeLog = ''

  beforeAll(async () => {
    root = mkdtempSync('/tmp/tdcli-')
    const handler = (req: IncomingMessage, res: ServerResponse): void => {
      let body = ''
      req.on('data', (chunk) => (body += String(chunk)))
      req.on('end', () => {
        const auth = String(req.headers.authorization ?? '')
        if (req.url?.startsWith('/v1/messages')) {
          seen.push(auth)
          res.writeHead(200, { 'content-type': 'text/event-stream' })
          res.end(sse('SINK-REPLY'))
          return
        }
        if (req.url?.startsWith('/v1/oauth/token')) {
          refreshes.push(body)
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(
            JSON.stringify({
              access_token: 'sk-ant-oat01-REFRESHED',
              refresh_token: 'sk-ant-ort01-REFRESHED',
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
    sink = createServer(handler)
    await new Promise<void>((resolve) => sink.listen(0, '127.0.0.1', resolve))
    sinkUrl = `http://127.0.0.1:${(sink.address() as AddressInfo).port}`

    /*
     * The throwaway CA and the stand-in for the OAuth host. One day of validity,
     * in the scratch folder, deleted with it; trusted only by the child process
     * this test starts, through NODE_EXTRA_CA_CERTS — never by the machine.
     */
    const tls = join(root, 'tls')
    mkdirSync(tls)
    const cnf = join(tls, 'ca.cnf')
    writeFileSync(
      cnf,
      '[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n',
    )
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(tls, 'ca.key'), '-out', join(tls, 'ca.crt'), '-days', '1', '-subj', '/CN=td-vault-test-ca', '-config', cnf, '-extensions', 'ca'], { stdio: 'ignore' })
    execFileSync('openssl', ['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(tls, 'srv.key'), '-out', join(tls, 'srv.csr'), '-subj', '/CN=platform.claude.com', '-config', cnf], { stdio: 'ignore' })
    writeFileSync(join(tls, 'srv.ext'), 'subjectAltName=DNS:platform.claude.com\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
    execFileSync('openssl', ['x509', '-req', '-in', join(tls, 'srv.csr'), '-CA', join(tls, 'ca.crt'), '-CAkey', join(tls, 'ca.key'), '-CAcreateserial', '-out', join(tls, 'srv.crt'), '-days', '1', '-extfile', join(tls, 'srv.ext')], { stdio: 'ignore' })
    caFile = join(tls, 'ca.crt')
    oauth = createTlsServer({ key: readFileSync(join(tls, 'srv.key')), cert: readFileSync(join(tls, 'srv.crt')) }, handler)
    await new Promise<void>((resolve) => oauth.listen(0, '127.0.0.1', resolve))
    const oauthPort = (oauth.address() as AddressInfo).port
    proxy = createServer((_req, res) => {
      refused.push('plain http')
      res.writeHead(403)
      res.end()
    })
    proxy.on('connect', (req: IncomingMessage, client: Socket, head: Buffer) => {
      tunnels.add(client)
      client.on('close', () => tunnels.delete(client))
      if (req.url !== 'platform.claude.com:443') {
        refused.push(String(req.url))
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
    proxyUrl = `http://127.0.0.1:${(proxy.address() as AddressInfo).port}`

    vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
    tickets = new TicketBook()
    socket = await startVaultSocket(join(root, 'v.sock'), {
      vault,
      tickets,
      providerOf: () => 'claude',
      adopting: () => false,
      markKept: () => undefined,
    })
    fakeLog = join(root, 'real-security.log')
    const fake = join(root, 'fake-security')
    writeFileSync(fake, `#!/bin/sh\nprintf '%s\\n' "$*" >> '${fakeLog}'\n[ "$1" = "-i" ] && cat >/dev/null\nexit 44\n`)
    chmodSync(fake, 0o755)
    shimDir = writeSecurityShim(join(root, 'vault'), socket.path, fake) ?? ''
  }, 30_000)

  afterAll(async () => {
    await socket?.close()
    // Keep-alive connections from the CLI hold a server open after it exits;
    // they are dropped rather than waited out.
    for (const tunnel of tunnels) tunnel.destroy()
    for (const server of [sink, oauth, proxy]) {
      server?.closeAllConnections()
      await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()))
    }
    rmSync(root, { recursive: true, force: true })
  })

  function scrubbed(): Record<string, string> {
    const out: Record<string, string> = {}
    for (const [key, value] of Object.entries(process.env)) {
      if (value === undefined) continue
      if (/^(CLAUDE|ANTHROPIC|TERMINALDECK)/.test(key)) continue
      out[key] = value
    }
    return out
  }

  function runAs(account: string, extra: Record<string, string> = {}): Promise<{ stdout: string; stderr: string }> {
    const configDir = join(root, 'cfg', account)
    const home = join(root, 'home')
    mkdirSync(configDir, { recursive: true })
    mkdirSync(home, { recursive: true })
    return new Promise((resolve) => {
      execFile(
        BIN,
        ['-p', 'say hi', '--output-format', 'text'],
        {
          cwd: root,
          timeout: 60_000,
          env: {
            ...withPath(scrubbed(), `${shimDir}:/usr/bin:/bin`, 'darwin'),
            HOME: home,
            CLAUDE_CONFIG_DIR: configDir,
            ANTHROPIC_BASE_URL: sinkUrl,
            HTTPS_PROXY: proxyUrl,
            HTTP_PROXY: proxyUrl,
            NO_PROXY: '127.0.0.1,localhost',
            NODE_EXTRA_CA_CERTS: caFile,
            DISABLE_TELEMETRY: '1',
            DISABLE_ERROR_REPORTING: '1',
            DISABLE_AUTOUPDATER: '1',
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
            [VAULT_SOCKET_ENV]: socket.path,
            [VAULT_TICKET_ENV]: tickets.ticketFor(account),
            ...extra,
          },
        },
        (_error, stdout, stderr) => resolve({ stdout: String(stdout), stderr: String(stderr) }),
      )
    })
  }

  it('each account sends its own token, read through the shim from the vault', async () => {
    vault.put('one', 'claude', 'keychain:Claude Code-credentials', claudeLogin('VAULT-ONE'), 'sign-in')
    vault.put('two', 'claude', 'keychain:Claude Code-credentials', claudeLogin('VAULT-TWO'), 'sign-in')
    seen.length = 0
    const one = await runAs('one')
    const two = await runAs('two')
    expect(seen, `one said: ${one.stdout} ${one.stderr}\ntwo said: ${two.stdout} ${two.stderr}`).toContain(
      'Bearer sk-ant-oat01-VAULT-ONE',
    )
    expect(seen).toContain('Bearer sk-ant-oat01-VAULT-TWO')
    // Neither run ever asked the "real" keychain for a login.
    const asked = existsSync(fakeLog) ? readFileSync(fakeLog, 'utf8') : ''
    expect(asked).not.toContain('-credentials')
  }, 120_000)

  it('an account with nothing kept is signed out, and is not handed anybody else\'s login', async () => {
    seen.length = 0
    const out = await runAs('nobody')
    expect(seen.filter((auth) => auth.includes('VAULT-'))).toEqual([])
    expect(`${out.stdout}${out.stderr}`.toLowerCase()).toMatch(/log ?in|not logged|auth/)
  }, 120_000)

  it('a token refresh the CLI writes back lands in the vault', async () => {
    const slot = 'keychain:Claude Code-credentials'
    vault.put('three', 'claude', slot, claudeLogin('EXPIRED', 'max', Date.now() - 60_000), 'sign-in')
    seen.length = 0
    refreshes.length = 0
    const out = await runAs('three')
    const kept = vault.read('three', slot) ?? ''
    expect(refreshes.length, `cli said: ${out.stdout} ${out.stderr}`).toBeGreaterThan(0)
    expect(kept).toContain('sk-ant-oat01-REFRESHED')
    expect(vault.summary('three')?.lastSource).toBe('refresh')
    expect(seen).toContain('Bearer sk-ant-oat01-REFRESHED')
  }, 120_000)

  it('everything else the CLI reached for was refused at the local proxy, and nothing went out', () => {
    // The CLI does try: `api.anthropic.com:443` for its account profile, a few
    // times a run. Each attempt is a CONNECT this proxy refused — recorded
    // here so the fence is visible rather than assumed.
    expect(refused.every((host) => /^[a-z0-9.-]+:\d+$/.test(host))).toBe(true)
    expect(refused).not.toContain('platform.claude.com:443')
  })
})
