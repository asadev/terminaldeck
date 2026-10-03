import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { withPath } from '../platform/host'
import { quietEnv, scrubbedEnv, startRig, type Rig } from './cli-rig.fixture'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV, writeSecurityShim } from './keychain-shim'
import { startVaultSocket, TicketBook, type VaultSocket } from './server'
import { AccountVault } from './store'
import { NUDGE_FILE, noteCreatedNudge, settleNudge, switchInPlace, type InPlaceDeps } from './switch-in-place'

/**
 * The proof: one real Claude Code process, switched to another account in
 * place, carries the other account's token on its very next request — same
 * process, same conversation, nothing restarted — and a refresh it makes while
 * on the new account is saved to the new account and never the old one.
 *
 *     TD_LIVE_CLAUDE=$(command -v claude) npx vitest run src/main/account-vault/switch-in-place.cli.test.ts
 *
 * Off unless `TD_LIVE_CLAUDE` names the binary (CI has none). Nothing real is
 * touched — the same fences as `vault.cli.test.ts`: made-up logins, a scratch
 * `HOME` and `CLAUDE_CONFIG_DIR`, a "real" `security` behind the shim that is a
 * script answering "not found", the API a local server, and the OAuth host a
 * local stand-in reached through a proxy that refuses every other host.
 */

const BIN = process.env.TD_LIVE_CLAUDE ?? ''
const LIVE = BIN !== '' && existsSync(BIN) && process.platform === 'darwin'
const SLOT = 'keychain:Claude Code-credentials'
const sha256 = (text: string): string => createHash('sha256').update(text).digest('hex')

describe.skipIf(!LIVE)('the real CLI, switched to another account in place', () => {
  let root = ''
  let rig: Rig
  let vault: AccountVault
  let tickets: TicketBook
  let socket: VaultSocket
  let shimDir = ''
  let ticket = ''
  let cfgA = ''
  let cfgB = ''

  beforeAll(async () => {
    root = mkdtempSync('/tmp/tdip-cli-')
    rig = await startRig(root)
    rig.refreshTo = 'REFRESHED-B'
    cfgA = join(root, 'cfg-a')
    cfgB = join(root, 'cfg-b')
    mkdirSync(cfgA, { recursive: true })
    mkdirSync(cfgB, { recursive: true })
    mkdirSync(join(root, 'home'), { recursive: true })

    vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
    vault.put('A', 'claude', SLOT, claudeLogin('ACCOUNT-A'), 'sign-in')
    // B's access token has already expired: the first request made as B makes
    // the CLI refresh it, which is how "a refresh while on B" is produced.
    vault.put('B', 'claude', SLOT, claudeLogin('ACCOUNT-B', 'max', Date.now() - 60_000), 'sign-in')

    tickets = new TicketBook()
    ticket = tickets.seat('A', cfgA)
    tickets.bind(ticket, 'session-1')
    socket = await startVaultSocket(join(root, 'v.sock'), {
      vault,
      tickets,
      providerOf: () => 'claude',
      configDirOf: (id) => (id === 'A' ? cfgA : id === 'B' ? cfgB : null),
      adopting: () => false,
      markKept: () => undefined,
      sourceOf: () => ({ kind: 'vault' }),
      onServed: (event) => {
        if (event.sessionId !== null && tickets.sessionSeat(event.sessionId)?.serving === event.accountId) {
          settleNudge(event.sessionId)
        }
      },
    })
    const fake = join(root, 'fake-security')
    writeFileSync(fake, '#!/bin/sh\n[ "$1" = "-i" ] && cat >/dev/null\nexit 44\n')
    chmodSync(fake, 0o755)
    shimDir = writeSecurityShim(root, socket.path, fake) ?? ''
  }, 30_000)

  afterAll(async () => {
    await socket?.close()
    await rig?.close()
    rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
  })

  it('switches in place, takes on the next request, and keeps a refresh on the account it belongs to', async () => {
    const child: ChildProcessWithoutNullStreams = spawn(
      BIN,
      ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose'],
      {
        cwd: root,
        env: {
          ...withPath(scrubbedEnv(), `${shimDir}:/usr/bin:/bin`, 'darwin'),
          ...quietEnv(rig),
          HOME: join(root, 'home'),
          CLAUDE_CONFIG_DIR: cfgA,
          [VAULT_SOCKET_ENV]: socket.path,
          [VAULT_TICKET_ENV]: ticket,
        },
      },
    )
    let out = ''
    child.stdout.on('data', (chunk) => (out += String(chunk)))
    child.stderr.on('data', () => undefined)
    const results = (): number => (out.match(/"type":"result"/g) ?? []).length
    const turn = async (text: string): Promise<void> => {
      const before = results()
      child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } })}\n`)
      const until = Date.now() + 30_000
      while (results() <= before && Date.now() < until) await new Promise((r) => setTimeout(r, 50))
    }
    const deps: InPlaceDeps = {
      seat: (id) => tickets.sessionSeat(id),
      source: () => ({ kind: 'vault' }),
      adopting: () => false,
      held: (id) => vault.has(id),
      keep: () => true,
      user: 'me',
      retarget: (id, account) => tickets.retarget(id, account),
      launchDir: () => cfgA,
      sha256,
    }

    try {
      await turn('one')
      expect(rig.seen.at(-1)?.auth).toBe('Bearer sk-ant-oat01-ACCOUNT-A')
      const pid = child.pid

      // ---- switch to B, in place, and ask straight away -------------------
      const switchedAt = Date.now()
      const moved = await switchInPlace('session-1', { id: 'B', name: 'B', configDir: cfgB }, deps)
      expect(moved).toMatchObject({ ok: true, nudged: 'created' })
      if (moved.ok && moved.nudged === 'created' && moved.nudgeFile !== null) noteCreatedNudge('session-1', moved.nudgeFile)
      const before = rig.seen.length
      await turn('two')
      const tookMs = Date.now() - switchedAt
      const asB = rig.seen.slice(before)

      // B's expired token was refreshed with B's refresh token…
      expect(rig.refreshes).toHaveLength(1)
      expect(rig.refreshes[0]).toContain('sk-ant-ort01-ACCOUNT-B')
      // …the request went out as B, freshly refreshed, well inside the 30 s
      // the CLI would otherwise have kept A's login cached for…
      expect(asB.map((seen) => seen.auth)).toEqual(['Bearer sk-ant-oat01-REFRESHED-B'])
      expect(tookMs).toBeLessThan(10_000)
      // …and the refreshed login is B's — A's is exactly as it was.
      expect(vault.read('B', SLOT)).toContain('sk-ant-oat01-REFRESHED-B')
      expect(vault.read('A', SLOT)).toBe(claudeLogin('ACCOUNT-A'))
      // The file that made it look has been taken back.
      expect(existsSync(join(cfgA, NUDGE_FILE))).toBe(false)

      // ---- and back to A, in place --------------------------------------
      const back = await switchInPlace('session-1', { id: 'A', name: 'A', configDir: cfgA }, deps)
      expect(back.ok).toBe(true)
      await turn('three')
      expect(rig.seen.at(-1)?.auth).toBe('Bearer sk-ant-oat01-ACCOUNT-A')

      // One process the whole way through, and one conversation.
      expect(child.pid).toBe(pid)
      expect(child.exitCode).toBeNull()
      const conversations = new Set([...out.matchAll(/"session_id":"([^"]+)"/g)].map((match) => match[1]))
      expect(conversations.size).toBe(1)
      expect(results()).toBe(3)
      if (process.env.TD_MEASURE_OUT) {
        writeFileSync(
          process.env.TD_MEASURE_OUT,
          [
            `pid before ${pid}, after ${child.pid}, exited ${String(child.exitCode)}`,
            `conversation ids seen: ${[...conversations].join(', ')}`,
            `switch to B -> answered turn as B: ${tookMs} ms`,
            `requests after the switch: ${asB.map((seen) => seen.auth).join(' , ')}`,
            `refresh bodies: ${rig.refreshes.length} (spent B's refresh token: ${rig.refreshes[0]?.includes('sk-ant-ort01-ACCOUNT-B') === true})`,
            `vault B now refreshed: ${vault.read('B', SLOT)?.includes('REFRESHED-B') === true}, vault A unchanged: ${vault.read('A', SLOT) === claudeLogin('ACCOUNT-A')}`,
            `back to A -> next request: ${rig.seen.at(-1)?.auth ?? ''}`,
            '',
          ].join('\n'),
        )
      }
      // Whatever else the CLI reached for (its profile lookup goes to
      // api.anthropic.com directly) was refused by the proxy: nothing left.
      expect(rig.refused.every((host) => host !== 'platform.claude.com:443')).toBe(true)
    } finally {
      // Gone before the scratch folder is removed: it writes into it to the end.
      const exited = new Promise((resolve) => child.once('exit', resolve))
      child.kill()
      await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5_000))])
    }
  }, 120_000)
})
