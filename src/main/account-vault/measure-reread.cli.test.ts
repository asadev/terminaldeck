import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, it } from 'vitest'
import { withPath } from '../platform/host'
import { quietEnv, scrubbedEnv, startRig, type Rig } from './cli-rig.fixture'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV, writeSecurityShim } from './keychain-shim'
import { startVaultSocket, TicketBook, type VaultSocket } from './server'
import { AccountVault } from './store'

/**
 * A measurement, not a check: *when* does a running Claude Code read its login
 * again? Everything `switch-in-place.ts` does rests on the answer, so the
 * instrument is kept beside it. It writes a timeline to `TD_MEASURE_OUT`:
 *
 *     TD_MEASURE_CLAUDE=$(command -v claude) TD_MEASURE_OUT=/tmp/t.txt \
 *       npx vitest run src/main/account-vault/measure-reread.cli.test.ts
 *     TD_MEASURE_MODE=touch …   # the same, switching with a nudge
 *
 * One long-lived `claude -p --input-format stream-json` process; its keychain
 * lookups are answered by the vault through the shim, and which account a
 * lookup is answered with is flipped between turns. The API is a local server
 * that records each request's token. Same fences as `vault.cli.test.ts`.
 *
 * Measured on Claude Code 2.1.287 (2026-10-03):
 *
 *     cache:  turn1 A · turn2 A · SWITCH to B · turn3 (+0 s) A · turn4 (+5 s) A ·
 *             turn5 (+32 s) B · SWITCH to A, API refuses B once · turn6: B, then A
 *             keychain reads: start ×2, then +32 s, then on the 401
 *     touch:  SWITCH to B + write {} to .credentials.json · turn3 (+0 s) B ·
 *             SWITCH to A + touch · turn4 A · SWITCH to B, no touch · turn5 A
 *
 * So: read at start, cached 30 s (`ASt`), read again on the first request after
 * that, at once on a 401 — and at once on the next request after
 * `<config dir>/.credentials.json` changes time.
 */

const BIN = process.env.TD_MEASURE_CLAUDE ?? ''
const LIVE = BIN !== '' && existsSync(BIN) && process.platform === 'darwin'
const SLOT = 'keychain:Claude Code-credentials'

describe.skipIf(!LIVE)('measure: when a running Claude Code re-reads its login', () => {
  let root = ''
  let rig: Rig
  let socket: VaultSocket
  let vault: AccountVault
  let tickets: TicketBook
  let ticket = ''
  const reads: Array<{ at: number; served: string }> = []
  let shimDir = ''

  beforeAll(async () => {
    root = mkdtempSync('/tmp/tdm-')
    rig = await startRig(root)
    vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
    vault.put('A', 'claude', SLOT, claudeLogin('ACCOUNT-A'), 'sign-in')
    vault.put('B', 'claude', SLOT, claudeLogin('ACCOUNT-B'), 'sign-in')
    tickets = new TicketBook()
    ticket = tickets.seat('A', join(root, 'cfg'))
    tickets.bind(ticket, 'measured')
    const read = vault.read.bind(vault)
    vault.read = (id: string, slot: string) => {
      reads.push({ at: Date.now(), served: id })
      return read(id, slot)
    }
    socket = await startVaultSocket(join(root, 'v.sock'), {
      vault,
      tickets,
      providerOf: () => 'claude',
      configDirOf: () => join(root, 'cfg'),
      adopting: () => false,
      markKept: () => undefined,
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

  it('prints the timeline', async () => {
    const cfg = join(root, 'cfg')
    mkdirSync(cfg, { recursive: true })
    mkdirSync(join(root, 'home'), { recursive: true })
    const child: ChildProcessWithoutNullStreams = spawn(
      BIN,
      ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose'],
      {
        cwd: root,
        env: {
          ...withPath(scrubbedEnv(), `${shimDir}:/usr/bin:/bin`, 'darwin'),
          ...quietEnv(rig),
          HOME: join(root, 'home'),
          CLAUDE_CONFIG_DIR: cfg,
          [VAULT_SOCKET_ENV]: socket.path,
          [VAULT_TICKET_ENV]: ticket,
          // Claude Code's newer credential store ("v5", gate `tengu_hover_rest`)
          // checks for changes differently; `TD_MEASURE_HOVER=1` measures it.
          ...(process.env.TD_MEASURE_HOVER ? { CLAUDE_CODE_HOVER_REST: process.env.TD_MEASURE_HOVER } : {}),
        },
      },
    )
    let out = ''
    child.stdout.on('data', (chunk) => (out += String(chunk)))
    child.stderr.on('data', () => undefined)
    const t0 = Date.now()
    const results = (): number => (out.match(/"type":"result"/g) ?? []).length
    const turn = async (text: string): Promise<void> => {
      const before = results()
      child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } })}\n`)
      const until = Date.now() + 30_000
      while (results() <= before && Date.now() < until) await new Promise((r) => setTimeout(r, 50))
    }
    const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))
    const log: string[] = []
    const mark = (label: string): void => {
      log.push(`${((Date.now() - t0) / 1000).toFixed(1)}s ${label}`)
    }
    const serve = (account: string): void => {
      tickets.retarget('measured', account)
    }
    const last = (): string => rig.seen.at(-1)?.auth ?? ''

    try {
      await turn('one')
      mark(`turn1 -> ${last()}`)
      await turn('two')
      mark(`turn2 -> ${last()}`)

      if (process.env.TD_MEASURE_MODE === 'config') {
        // Only the global config's identity changes — no credentials file.
        const file = join(cfg, '.claude.json')
        const now = existsSync(file) ? (JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>) : {}
        serve('B')
        writeFileSync(file, JSON.stringify({ ...now, oauthAccount: { accountUuid: 'b', emailAddress: 'b@example.com', organizationUuid: 'ob', organizationName: 'B org' } }))
        mark('SWITCH to B, then rewrite .claude.json oauthAccount (no credentials file)')
        await sleep(1500)
        await turn('three')
        mark(`turn3 -> ${last()}`)
        await sleep(3000)
        await turn('four')
        mark(`turn4 -> ${last()}`)
      } else if (process.env.TD_MEASURE_MODE === 'touch') {
        serve('B')
        writeFileSync(join(cfg, '.credentials.json'), '{}\n', { mode: 0o600 })
        mark('SWITCH to B, then write {} to .credentials.json')
        await turn('three')
        mark(`turn3 -> ${last()}`)
        serve('A')
        await sleep(20)
        const now = new Date()
        utimesSync(join(cfg, '.credentials.json'), now, now)
        mark('SWITCH to A, then touch .credentials.json')
        await turn('four')
        mark(`turn4 -> ${last()}`)
        serve('B')
        mark('SWITCH to B, no touch')
        await turn('five')
        mark(`turn5 -> ${last()}`)
      } else {
        serve('B')
        mark('SWITCH to B')
        await turn('three')
        mark(`turn3 -> ${last()}`)
        await sleep(5_000)
        await turn('four')
        mark(`turn4 -> ${last()}`)
        await sleep(27_000)
        await turn('five')
        mark(`turn5 -> ${last()}`)
        serve('A')
        mark('SWITCH to A, and the API refuses B once')
        let refusedOnce = false
        rig.respond = (auth) => {
          if (!refusedOnce && auth.includes('ACCOUNT-B')) {
            refusedOnce = true
            return 401
          }
          return 200
        }
        const before = rig.seen.length
        await turn('six')
        mark(`turn6 -> ${rig.seen.slice(before).map((seen) => seen.auth).join(' , ')}`)
      }
    } finally {
      const exited = new Promise((resolve) => child.once('exit', resolve))
      child.kill()
      await Promise.race([exited, sleep(5_000)])
    }
    const readTimes = reads.map((r) => `${((r.at - t0) / 1000).toFixed(1)}s:${r.served}`).join(' ')
    writeFileSync(
      process.env.TD_MEASURE_OUT ?? join(root, 'timeline.txt'),
      `TIMELINE\n${log.join('\n')}\nKEYCHAIN READS ${readTimes}\nREFRESHES ${rig.refreshes.length}\n`,
    )
  }, 180_000)
})
