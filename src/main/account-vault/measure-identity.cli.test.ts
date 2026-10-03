import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { spawn as ptySpawn, type IPty } from 'node-pty'
import { afterAll, beforeAll, describe, it } from 'vitest'
import { withPath } from '../platform/host'
import { quietEnv, scrubbedEnv, startRig, type Rig } from './cli-rig.fixture'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { VAULT_HOME_ENV, VAULT_SOCKET_ENV, VAULT_TICKET_ENV, writeSecurityShim } from './keychain-shim'
import { startVaultSocket, TicketBook, type VaultSocket } from './server'
import { AccountVault } from './store'

/**
 * A measurement: where does an interactive Claude Code show its account
 * (`/status`: Email, Organization), and does a running one notice when that
 * changes? Writes what it saw to `TD_MEASURE_OUT`.
 *
 *     TD_MEASURE_CLAUDE=$(command -v claude) TD_MEASURE_OUT=/tmp/id.txt \
 *       npx vitest run src/main/account-vault/measure-identity.cli.test.ts
 *
 * Interactive, in a real pty, on the machine's-own-install shape: no
 * `CLAUDE_CONFIG_DIR`, so the global config is `$HOME/.claude.json` — with
 * `HOME` a scratch folder, so nothing of the person's is read or written.
 * `TD_MEASURE_SYMLINK=1` makes that file a symlink, to see how it is written.
 *
 * Measured on Claude Code 2.1.287 (2026-10-03):
 *  - `/status` Email and Organization are `oauthAccount` in the global config
 *    file (`$HOME/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json`); Login
 *    method comes from the login itself.
 *  - A running session reads that file again when it changes: rewrite
 *    `oauthAccount` on disk and the next `/status` shows the new address.
 *  - It writes the file through a symlink (the link survives), but takes its
 *    write lock beside the path it was given (`${path}.lock`, `di()`), so two
 *    paths to one file are two locks on it.
 *
 * Which is why a session switched in place keeps the name Claude Code shows:
 * the only file it reads it from is shared with every other session on the
 * account it started on (and, for the Mac's own login, with the person's own
 * terminal), and a second path to it would write past Claude Code's own lock.
 */

const BIN = process.env.TD_MEASURE_CLAUDE ?? ''
const LIVE = BIN !== '' && existsSync(BIN) && process.platform === 'darwin'
const SLOT = 'keychain:Claude Code-credentials'

function account(email: string, org: string, uuid: string): Record<string, unknown> {
  return {
    accountUuid: uuid,
    emailAddress: email,
    organizationUuid: `org-${uuid}`,
    organizationName: org,
    displayName: email.split('@')[0],
    billingType: 'stripe_subscription',
    accountCreatedAt: '2025-01-01T00:00:00Z',
    subscriptionCreatedAt: '2025-01-01T00:00:00Z',
    ccOnboardingFlags: {},
    hasExtraUsageEnabled: false,
    profileFetchedAt: Date.now(),
  }
}

const strip = (text: string): string =>
  text
    // A cursor-forward is how the TUI draws a run of spaces.
    // eslint-disable-next-line no-control-regex
    .replace(/\u001b\[(\d*)C/g, (_m, n: string) => ' '.repeat(Number(n || '1')))
    // eslint-disable-next-line no-control-regex
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '').replace(/\u001b\][^\u0007]*\u0007/g, '').replace(/\r/g, '')

describe.skipIf(!LIVE)('measure: where an interactive Claude Code shows its account', () => {
  let root = ''
  let rig: Rig
  let socket: VaultSocket
  let shimDir = ''
  let ticket = ''

  beforeAll(async () => {
    root = mkdtempSync('/tmp/tdid-')
    rig = await startRig(root)
    const vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
    vault.put('B', 'claude', SLOT, claudeLogin('ACCOUNT-B'), 'sign-in')
    const tickets = new TicketBook()
    ticket = tickets.seat('system', null)
    tickets.bind(ticket, 's')
    socket = await startVaultSocket(join(root, 'v.sock'), {
      vault,
      tickets,
      providerOf: () => 'claude',
      configDirOf: () => null,
      adopting: () => false,
      markKept: () => undefined,
      sourceOf: (id) => (id === 'system' ? { kind: 'keychain', dir: null } : { kind: 'vault' }),
    })
    // The "real" keychain: the machine's own login is A.
    const fake = join(root, 'fake-security')
    const blob = Buffer.from(claudeLogin('ACCOUNT-A'), 'utf8').toString('base64')
    writeFileSync(
      fake,
      `#!/bin/sh\n[ "$1" = "-i" ] && { cat >/dev/null; exit 0; }\ncase "$*" in *find-generic-password*" -w "*"Claude Code-credentials") printf '%s' '${blob}' | base64 -D; echo; exit 0;; esac\nexit 44\n`,
    )
    chmodSync(fake, 0o755)
    shimDir = writeSecurityShim(root, socket.path, fake) ?? ''
  }, 30_000)

  afterAll(async () => {
    await socket?.close()
    await rig?.close()
    rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
  })

  it('prints what /status shows, before and after the config file changes', async () => {
    const home = join(root, 'home')
    const cwd = join(root, 'proj')
    mkdirSync(join(home, '.claude'), { recursive: true })
    mkdirSync(cwd, { recursive: true })
    const { realpathSync } = await import('node:fs')
    const trusted = realpathSync(cwd)
    const configFile = join(home, '.claude.json')
    const base = {
      hasCompletedOnboarding: true,
      lastOnboardingVersion: '2.1.287',
      theme: 'dark',
      numStartups: 5,
      bypassPermissionsModeAccepted: true,
      projects: { [trusted]: { hasTrustDialogAccepted: true, allowedTools: [] } },
    }
    const symlinked = process.env.TD_MEASURE_SYMLINK === '1'
    const real = symlinked ? join(home, 'real-config.json') : configFile
    writeFileSync(real, JSON.stringify({ ...base, oauthAccount: account('a@example.com', "A's Organization", 'aaaaaaaa-1') }, null, 2))
    if (symlinked) {
      const { symlinkSync } = await import('node:fs')
      symlinkSync(real, configFile)
    }
    const log: string[] = []
    let screen = ''
    const pty: IPty = ptySpawn(BIN, [], {
      name: 'xterm-256color',
      cols: 140,
      rows: 50,
      cwd,
      env: {
        ...withPath(scrubbedEnv(), `${shimDir}:/usr/bin:/bin`, 'darwin'),
        ...quietEnv(rig),
        HOME: home,
        TERM: 'xterm-256color',
        [VAULT_SOCKET_ENV]: socket.path,
        [VAULT_TICKET_ENV]: ticket,
        [VAULT_HOME_ENV]: 'agent',
      },
    })
    pty.onData((data) => {
      screen += data
    })
    const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))
    const tail = (): string => strip(screen).slice(-3000)
    try {
      await sleep(6000)
      log.push(`--- after start ---\n${tail()}`)
      screen = ''
      pty.write('/status')
      await sleep(400)
      pty.write('\r')
      await sleep(2500)
      log.push(`--- /status #1 ---\n${tail()}`)
      pty.write('\u001b')
      await sleep(800)

      // The config file changes on disk, as a switch made in place would make it.
      const now = JSON.parse(readFileSync(real, 'utf8')) as Record<string, unknown>
      log.push(`config keys now: ${Object.keys(now).join(',')}`)
      writeFileSync(real, JSON.stringify({ ...now, oauthAccount: account('b@example.com', "B's Organization", 'bbbbbbbb-2') }, null, 2))
      await sleep(2500)
      screen = ''
      pty.write('/status')
      await sleep(400)
      pty.write('\r')
      await sleep(2500)
      log.push(`--- /status #2 (after the file changed) ---\n${tail()}`)
      pty.write('\u001b')
      await sleep(500)
      log.push(`config file still a symlink: ${lstatSync(configFile).isSymbolicLink()}`)
      log.push(`real file oauthAccount email: ${(JSON.parse(readFileSync(real, 'utf8')) as { oauthAccount?: { emailAddress?: string } }).oauthAccount?.emailAddress}`)
      log.push(`credentials file in ~/.claude: ${existsSync(join(home, '.claude', '.credentials.json'))}`)
    } finally {
      pty.kill()
      await sleep(500)
    }
    writeFileSync(process.env.TD_MEASURE_OUT ?? join(root, 'identity.txt'), `${log.join('\n')}\n`)
  }, 120_000)
})
