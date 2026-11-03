import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { withPath } from '../platform/host'
import { quietEnv, scrubbedEnv, startRig, type Rig } from './cli-rig.fixture'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { keychainUser, type ShimAnswer } from './keychain-requests'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV, writeSecurityShim } from './keychain-shim'
import { seatLaunch } from './runtime'
import { runSteps, startVaultSocket, TicketBook, type VaultSocket } from './server'
import { AccountVault } from './store'
import { switchInPlace, type InPlaceDeps } from './switch-in-place'
import { runSecurity } from './wire'

/**
 * The owner's case, with the real CLI: a session on the Mac's own login (no
 * `CLAUDE_CONFIG_DIR` — its login is the keychain item `Claude Code-credentials`
 * and its folder `~/.claude`), switched in place to an account made before the
 * app kept logins, whose login is still in the keychain item named after its
 * own folder.
 *
 *     TD_LIVE_CLAUDE=$(command -v claude) npx vitest run src/main/account-vault/switch-system-session.cli.test.ts
 *
 * `HOME` is a scratch folder, so "~/.claude" here is a scratch folder; the
 * "real" keychain is a script answering from files in the scratch folder.
 * What is asserted is what he needs to be true: the very next request goes out
 * as the other account, and nothing is written into `~/.claude`.
 */

const BIN = process.env.TD_LIVE_CLAUDE ?? ''
const LIVE = BIN !== '' && existsSync(BIN) && process.platform === 'darwin'
const SLOT = 'keychain:Claude Code-credentials'
const sha256 = (text: string): string => createHash('sha256').update(text).digest('hex')

describe.skipIf(!LIVE)('the real CLI on the Mac’s own login, switched in place to an account not yet kept', () => {
  let root = ''
  let home = ''
  let cfgB = ''
  let storeBase = ''
  let rig: Rig
  let vault: AccountVault
  let tickets: TicketBook
  let socket: VaultSocket
  let shimDir = ''
  let fake = ''
  const adopting = new Set(['examplemail'])
  const ran: string[] = []

  beforeAll(async () => {
    root = mkdtempSync('/tmp/tdsys-')
    home = join(root, 'home')
    cfgB = join(root, 'profiles', 'examplemail')
    storeBase = join(root, 'userData', 'account-vault', 'store')
    mkdirSync(join(home, '.claude'), { recursive: true })
    mkdirSync(cfgB, { recursive: true })
    rig = await startRig(root)

    // The "real" keychain: one file per service, holding the item's password.
    const keychain = join(root, 'keychain')
    mkdirSync(keychain)
    writeFileSync(join(keychain, 'Claude Code-credentials'), claudeLogin('MAC-OWN-LOGIN'))
    writeFileSync(join(keychain, `Claude Code-credentials-${sha256(cfgB).slice(0, 8)}`), claudeLogin('EXAMPLEMAIL'))
    fake = join(root, 'fake-security')
    writeFileSync(
      fake,
      [
        '#!/bin/sh',
        `K='${keychain}'`,
        `printf '%s\\n' "$*" >> '${join(root, 'security.log')}'`,
        'if [ "$1" = "-i" ]; then',
        '  line=$(cat)',
        '  svc=$(printf "%s" "$line" | sed -n "s/.*-s \\"\\([^\\"]*\\)\\".*/\\1/p")',
        '  hex=$(printf "%s" "$line" | sed -n "s/.*-X \\"\\([0-9a-fA-F]*\\)\\".*/\\1/p")',
        '  [ -n "$svc" ] && [ -n "$hex" ] && printf "%s" "$hex" | xxd -r -p > "$K/$svc" && exit 0',
        '  exit 1',
        'fi',
        'svc=""; want=0; prev=""',
        'for a in "$@"; do [ "$prev" = "-s" ] && svc="$a"; [ "$a" = "-w" ] && want=1; prev="$a"; done',
        'case "$1" in',
        '  find-generic-password) [ -f "$K/$svc" ] || exit 44; [ "$want" = 1 ] && cat "$K/$svc" && echo; exit 0 ;;',
        '  delete-generic-password) [ -f "$K/$svc" ] || exit 44; rm -f "$K/$svc"; exit 0 ;;',
        'esac',
        'exit 44',
        '',
      ].join('\n'),
    )
    chmodSync(fake, 0o755)

    vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
    tickets = new TicketBook()
    const keychainRun = async (argv: readonly string[], stdin: string | null): Promise<ShimAnswer> => {
      ran.push(argv.join(' '))
      return runSecurity(fake, argv, stdin)
    }
    socket = await startVaultSocket(join(root, 'v.sock'), {
      vault,
      tickets,
      providerOf: () => 'claude',
      configDirOf: (id) => (id === 'examplemail' ? cfgB : id === 'system' ? join(home, '.claude') : null),
      adopting: (id) => adopting.has(id) && !vault.has(id),
      markKept: (id) => adopting.delete(id),
      sourceOf: (id) => (id === 'system' ? { kind: 'keychain', dir: null } : { kind: 'vault' }),
      runReal: keychainRun,
    })
    shimDir = writeSecurityShim(join(root, 'userData'), socket.path, fake) ?? ''
    void runSteps
  }, 30_000)

  afterAll(async () => {
    await socket?.close()
    await rig?.close()
    rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
  })

  it('carries the other account’s token on its very next request, and writes nothing into ~/.claude', async () => {
    // What host-core gives a session started on the Mac's own login.
    const launch = seatLaunch(
      { id: 'system', provider: 'claude', system: true, configDir: join(home, '.claude') },
      { kind: 'keychain', dir: null },
      storeBase,
    )
    mkdirSync(launch.storeDir ?? root, { recursive: true })
    const ticket = tickets.seat('system', launch.launchDir, 'system', launch.storeDir)
    tickets.bind(ticket, 'session-1')
    const cwd = join(root, 'ClaudeCRM')
    mkdirSync(cwd)
    const child: ChildProcessWithoutNullStreams = spawn(
      BIN,
      ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose'],
      {
        cwd,
        env: {
          ...withPath(scrubbedEnv(), `${shimDir}:/usr/bin:/bin`, 'darwin'),
          ...quietEnv(rig),
          HOME: home,
          ...launch.env,
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
      source: (id) => (id === 'system' ? { kind: 'keychain', dir: null } : { kind: 'vault' }),
      adopting: (id) => adopting.has(id) && !vault.has(id),
      held: (id) => vault.has(id),
      keep: (id, slot, value) => {
        if (value !== null) vault.put(id, 'claude', slot, value, 'adopted')
        adopting.delete(id)
        return true
      },
      keychain: (argv, stdin) => runSecurity(fake, argv, stdin),
      user: keychainUser(),
      retarget: (id, account) => tickets.retarget(id, account),
      launchDir: (seat) => seat.storeDir ?? null,
      sha256,
    }
    let before: string[] = []
    try {
      await turn('one')
      expect(rig.seen.at(-1)?.auth).toBe('Bearer sk-ant-oat01-MAC-OWN-LOGIN')
      before = readdirSync(join(home, '.claude')).sort()

      const moved = await switchInPlace('session-1', { id: 'examplemail', name: 'examplemail@gmail.com', configDir: cfgB }, deps)
      expect(moved.ok).toBe(true)
      const sent = rig.seen.length
      await turn('two')
      // The very next request: the other account, moved in from its own item.
      expect(rig.seen.slice(sent).map((seen) => seen.auth)).toEqual(['Bearer sk-ant-oat01-EXAMPLEMAIL'])
      expect(vault.read('examplemail', SLOT)).toBe(claudeLogin('EXAMPLEMAIL'))
      // And ~/.claude is exactly as it was: no credentials file, nothing else.
      expect(readdirSync(join(home, '.claude')).sort()).toEqual(before)
      expect(existsSync(join(home, '.claude', '.credentials.json'))).toBe(false)
      // The machine's own login is untouched in its keychain item.
      expect(child.exitCode).toBeNull()
    } finally {
      const exited = new Promise((resolve) => child.once('exit', resolve))
      child.kill()
      await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5_000))])
    }
  }, 120_000)
})
