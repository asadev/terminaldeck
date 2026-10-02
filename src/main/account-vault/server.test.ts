import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ProviderId } from '../../shared/types'
import { withPath } from '../platform/host'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { NOT_FOUND_TEXT } from './keychain-requests'
import { securityShimScript, VAULT_SOCKET_ENV, VAULT_TICKET_ENV } from './keychain-shim'
import {
  acceptCapture,
  answerShim,
  startVaultSocket,
  TicketBook,
  wireText,
  type VaultServerDeps,
  type VaultSocket,
} from './server'
import { AccountVault } from './store'

const ON_WINDOWS = process.platform === 'win32'
const SLOT = 'keychain:Claude Code-credentials'
const hex = (text: string): string => Buffer.from(text, 'utf8').toString('hex')

/** Each account's own config directory — the hash on its keychain items comes from it. */
const CONFIG_DIRS: Record<string, string> = { one: '/cfg/one', two: '/cfg/two' }
/** `sha256(dir)[:8]`, the suffix the CLI names an account's keychain items with. */
const suffixOf = (configDir: string): string => createHash('sha256').update(configDir).digest('hex').slice(0, 8)
/** The login item's service name for one account, as the CLI spells it. */
const serviceOf = (account: string): string => `Claude Code-credentials-${suffixOf(CONFIG_DIRS[account] ?? '')}`

/** The body the shim sends: ticket, argc, argv, then stdin. */
function body(ticket: string, argv: string[], stdin = ''): Buffer {
  return Buffer.from([ticket, String(argv.length), ...argv, stdin].join('\0'), 'utf8')
}
/** The account a ticket names, for spelling its own service — `one` for a forged one. */
const accountOf = (ticket: string): string => tickets.accountFor(ticket) ?? 'one'
const find = (ticket: string, account = accountOf(ticket)): Buffer =>
  body(ticket, ['find-generic-password', '-a', 'me', '-w', '-s', serviceOf(account)])
const add = (ticket: string, value: string, account = accountOf(ticket)): Buffer =>
  body(ticket, ['-i'], `add-generic-password -U -a "me" -s "${serviceOf(account)}" -X "${hex(value)}"\n`)
const remove = (ticket: string, account = accountOf(ticket)): Buffer =>
  body(ticket, ['delete-generic-password', '-a', 'me', '-s', serviceOf(account)])

let dir = ''
let vault: AccountVault
let tickets: TicketBook
let accounts: Map<string, ProviderId>
let adopting: Set<string>
/** Slots settled, as `<account>|<slot>`. */
let settled: Set<string>
let kept: string[]
let deps: VaultServerDeps

beforeEach(() => {
  // Short on purpose: a unix socket path has to fit in 104 bytes.
  dir = mkdtempSync('/tmp/tdv-')
  vault = new AccountVault({ dir, cipher: fakeCipher() })
  tickets = new TicketBook()
  accounts = new Map<string, ProviderId>([
    ['one', 'claude'],
    ['two', 'claude'],
  ])
  adopting = new Set()
  settled = new Set()
  kept = []
  deps = {
    vault,
    tickets,
    providerOf: (id) => accounts.get(id) ?? null,
    configDirOf: (id) => CONFIG_DIRS[id] ?? null,
    adopting: (id, slot) => adopting.has(id) && !settled.has(`${id}|${slot}`),
    markKept: (id, slot) => {
      kept.push(id)
      settled.add(`${id}|${slot}`)
    },
  }
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('answering a session from the vault', () => {
  it('each session is answered with its own account and no other', () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    vault.put('two', 'claude', SLOT, claudeLogin('TWO'), 'sign-in')
    const a = answerShim(find(tickets.ticketFor('one')), deps)
    const b = answerShim(find(tickets.ticketFor('two')), deps)
    expect(a).toEqual({ kind: 'exit', answer: { code: 0, stdout: claudeLogin('ONE'), stderr: '' } })
    expect(b).toEqual({ kind: 'exit', answer: { code: 0, stdout: claudeLogin('TWO'), stderr: '' } })
  })

  it('a switch is a new ticket, and it changes nothing for any other session', () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    vault.put('two', 'claude', SLOT, claudeLogin('TWO'), 'sign-in')
    const sessionB = tickets.ticketFor('two')
    // Session A was on `one` and is restarted on `two` — it is simply handed
    // `two`'s ticket. Session B, already on `two`, keeps working, and `one`'s
    // login is untouched for anybody still on it.
    const sessionA = tickets.ticketFor('two')
    expect(answerShim(find(sessionA), deps)).toEqual(answerShim(find(sessionB), deps))
    expect(answerShim(find(tickets.ticketFor('one')), deps)).toMatchObject({
      answer: { stdout: claudeLogin('ONE') },
    })
  })

  it('a sign-out in one account signs out that account only', () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    vault.put('two', 'claude', SLOT, claudeLogin('TWO'), 'sign-in')
    expect(answerShim(remove(tickets.ticketFor('one')), deps)).toMatchObject({ answer: { code: 0 } })
    expect(vault.has('one')).toBe(false)
    expect(answerShim(find(tickets.ticketFor('two')), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
  })

  it('captures the sign-in and every refresh the agent writes back', () => {
    const ticket = tickets.ticketFor('one')
    const heard: string[] = []
    deps.onCapture = (event) => heard.push(event.kind)

    expect(answerShim(find(ticket), deps)).toEqual({
      kind: 'exit',
      answer: { code: 44, stdout: '', stderr: NOT_FOUND_TEXT },
    })
    expect(answerShim(add(ticket, claudeLogin('FIRST')), deps)).toMatchObject({ answer: { code: 0 } })
    expect(answerShim(add(ticket, claudeLogin('REFRESHED')), deps)).toMatchObject({ answer: { code: 0 } })
    expect(vault.read('one', SLOT)).toBe(claudeLogin('REFRESHED'))
    expect(heard).toEqual(['sign-in', 'refresh'])
    expect(kept).toContain('one')
    expect(vault.summary('one')?.lastSource).toBe('refresh')
  })

  it('never answers a login lookup without a ticket this run minted — and never with a token', () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    const forged = 'a'.repeat(48)
    expect(answerShim(find(forged), deps)).toEqual({ kind: 'exit', answer: { code: 44, stdout: '', stderr: NOT_FOUND_TEXT } })
    expect(answerShim(find(''), deps)).toMatchObject({ answer: { code: 44 } })
    // A write with a bad ticket keeps nothing.
    answerShim(add(forged, claudeLogin('EVIL')), deps)
    expect(JSON.stringify(vault.summaries())).not.toContain('EVIL')
    expect(vault.read('one', SLOT)).toBe(claudeLogin('ONE'))
  })

  it('stops answering for an account the moment it is deleted', () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    const ticket = tickets.ticketFor('one')
    tickets.revoke('one')
    expect(answerShim(find(ticket), deps)).toMatchObject({ answer: { code: 44 } })
    // And a fresh ticket for a re-made account of the same name is a different one.
    expect(tickets.ticketFor('one')).not.toBe(ticket)
  })

  it('passes everything that is not a login straight to the real command', () => {
    const ticket = tickets.ticketFor('one')
    expect(answerShim(body(ticket, ['find-identity', '-v']), deps)).toEqual({ kind: 'pass' })
    expect(
      answerShim(body(ticket, ['find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-device-keys']), deps),
    ).toEqual({ kind: 'pass' })
  })

  it('moves an account that predates the vault by keeping what the agent itself reads, once', () => {
    adopting.add('one')
    const ticket = tickets.ticketFor('one')
    expect(answerShim(find(ticket), deps)).toEqual({ kind: 'capture' })

    // The shim ran the real command and reports what it printed.
    const report = Buffer.from(
      [ticket, '0', '6', 'find-generic-password', '-a', 'me', '-w', '-s', serviceOf('one'), `${claudeLogin('OLD-KEYCHAIN')}\n`].join('\0'),
    )
    expect(acceptCapture(report, deps)).toBe(true)
    expect(vault.read('one', SLOT)).toBe(claudeLogin('OLD-KEYCHAIN'))
    expect(vault.summary('one')?.lastSource).toBe('adopted')
    // Moved for good: the next lookup is the vault's, not the keychain's.
    expect(answerShim(find(ticket), deps)).toMatchObject({ answer: { stdout: claudeLogin('OLD-KEYCHAIN') } })
  })

  it('keeps nothing from a capture that failed, and settles a slot the keychain never had', () => {
    adopting.add('one')
    const ticket = tickets.ticketFor('one')
    const report = (code: string, out: string): Buffer =>
      Buffer.from([ticket, code, '6', 'find-generic-password', '-a', 'me', '-w', '-s', serviceOf('one'), out].join('\0'))
    // Locked keychain: nothing kept, nothing settled — the next lookup tries again.
    expect(acceptCapture(report('36', ''), deps)).toBe(false)
    expect(settled.has(`one|${SLOT}`)).toBe(false)
    // "Not found" in the real keychain: nothing to move, and the slot is settled.
    expect(acceptCapture(report('44', ''), deps)).toBe(true)
    expect(settled.has(`one|${SLOT}`)).toBe(true)
    expect(vault.has('one')).toBe(false)
    // Settled for good: a late report of a value is not kept.
    expect(acceptCapture(report('0', 'x'), deps)).toBe(false)
    expect(vault.has('one')).toBe(false)
  })

  /*
   * Review finding 3. Before: a sign-out of a slot still in the keychain was
   * answered "not found" from the empty vault — the real item survived, the
   * slot was not settled, and the next lookup captured the login straight back.
   * After a 401 that loops: the CLI deletes the bad token, gets it back, fails.
   */
  it('a sign-out of a login still in the keychain really deletes it, and it stays deleted', () => {
    adopting.add('one')
    const ticket = tickets.ticketFor('one')
    expect(answerShim(remove(ticket), deps)).toEqual({ kind: 'pass' })
    expect(settled.has(`one|${SLOT}`)).toBe(true)
    // The next lookup is the vault's — empty — and never a capture.
    expect(answerShim(find(ticket), deps)).toMatchObject({ kind: 'exit', answer: { code: 44 } })
  })

  it('moves each slot on its own, so settling the login does not strand the API-key slot', () => {
    adopting.add('one')
    const ticket = tickets.ticketFor('one')
    const apiKey = body(ticket, ['find-generic-password', '-a', 'me', '-w', '-s', `Claude Code-${suffixOf(CONFIG_DIRS.one ?? '')}`])
    expect(answerShim(find(ticket), deps)).toEqual({ kind: 'capture' })
    settled.add(`one|${SLOT}`)
    expect(answerShim(apiKey, deps)).toEqual({ kind: 'capture' })
  })

  /*
   * Review finding 11. Before: an interactive-mode lookup was answered
   * `capture`, which `acceptCapture` can never accept (it is not handed
   * stdin), so it passed to the keychain for ever without being kept.
   */
  it('passes an interactive-mode lookup through rather than promising a capture it cannot keep', () => {
    adopting.add('one')
    const ticket = tickets.ticketFor('one')
    const interactive = body(ticket, ['-i'], `find-generic-password -a "me" -w -s "${serviceOf('one')}"\n`)
    expect(answerShim(interactive, deps)).toEqual({ kind: 'pass' })
  })

  /*
   * Review finding 6. Before: the directory hash was dropped, so a nested
   * agent with another `CLAUDE_CONFIG_DIR` — inheriting this session's ticket —
   * was answered from this account's slot and could overwrite or delete it.
   */
  it('answers only lookups carrying this account’s own directory hash', () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    const ticket = tickets.ticketFor('one')
    const elsewhere = `Claude Code-credentials-${suffixOf('/somewhere/else')}`
    const nestedFind = body(ticket, ['find-generic-password', '-a', 'me', '-w', '-s', elsewhere])
    const nestedWrite = body(ticket, ['-i'], `add-generic-password -U -a "me" -s "${elsewhere}" -X "${hex('EVIL')}"\n`)
    const nestedDelete = body(ticket, ['delete-generic-password', '-a', 'me', '-s', elsewhere])
    const machineOwn = body(ticket, ['find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-credentials'])
    for (const request of [nestedFind, nestedWrite, nestedDelete, machineOwn]) {
      expect(answerShim(request, deps)).toEqual({ kind: 'pass' })
    }
    expect(vault.read('one', SLOT)).toBe(claudeLogin('ONE'))
    // And this account's own spelling is answered as before.
    expect(answerShim(find(ticket), deps)).toMatchObject({ answer: { stdout: claudeLogin('ONE') } })
  })

  it('speaks three lines a shell can read', () => {
    expect(wireText({ kind: 'pass' })).toBe('pass\n')
    expect(wireText({ kind: 'exit', answer: { code: 44, stdout: '', stderr: 'a\nb' } })).toBe('exit 44\na b\n')
  })
})

describe.skipIf(ON_WINDOWS)('the shim, run by a real shell against a real socket', () => {
  let socket: VaultSocket | null = null
  let fakeSecurity = ''
  let fakeLog = ''

  beforeEach(async () => {
    socket = await startVaultSocket(join(dir, 'v.sock'), deps)
    /*
     * The "real" security for this test is a script that records how it was
     * called and answers from a file. The login keychain is never reached:
     * every pass-through lands here, which is exactly the property the test is
     * about.
     */
    fakeLog = join(dir, 'real-security.log')
    fakeSecurity = join(dir, 'fake-security')
    writeFileSync(
      fakeSecurity,
      `#!/bin/sh\nprintf '%s\\n' "REAL: $*" >> '${fakeLog}'\n` +
        `if [ "$1" = "-i" ]; then cat >> '${fakeLog}'; exit 0; fi\n` +
        `case "$*" in *credentials*) printf '%s\\n' '${claudeLogin('FROM-OLD-KEYCHAIN')}'; exit 0 ;; esac\n` +
        `exit 44\n`,
    )
    chmodSync(fakeSecurity, 0o755)
    writeFileSync(join(dir, 'security'), securityShimScript(socket.path, fakeSecurity))
    chmodSync(join(dir, 'security'), 0o755)
  })
  afterEach(async () => {
    await socket?.close()
    socket = null
  })

  const shim = (args: string[], env: Record<string, string>, input?: string) =>
    new Promise<{ code: number; stdout: string; stderr: string }>((resolve) => {
      const child = execFile(
        join(dir, 'security'),
        args,
        { env: withPath(env, '/usr/bin:/bin', 'darwin') },
        (error, stdout, stderr) => {
          const code = error && typeof (error as { code?: unknown }).code === 'number' ? (error as { code: number }).code : 0
          resolve({ code, stdout, stderr })
        },
      )
      if (input !== undefined) child.stdin?.end(input)
      else child.stdin?.end()
    })

  const vaultEnv = (account: string): Record<string, string> => ({
    [VAULT_SOCKET_ENV]: socket?.path ?? '',
    [VAULT_TICKET_ENV]: tickets.ticketFor(account),
  })

  it('answers a lookup from the vault, exactly as `security -w` prints it', async () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    const out = await shim(['find-generic-password', '-a', 'me', '-w', '-s', serviceOf('one')], vaultEnv('one'))
    expect(out).toEqual({ code: 0, stdout: `${claudeLogin('ONE')}\n`, stderr: '' })
  })

  it('says "not found" with exit 44 for an account with no login', async () => {
    const out = await shim(['find-generic-password', '-a', 'me', '-w', '-s', serviceOf('two')], vaultEnv('two'))
    expect(out.code).toBe(44)
    expect(out.stderr).toContain('could not be found in the keychain')
  })

  it('keeps a `security -i` write without the token ever appearing in an argument', async () => {
    const login = claudeLogin('WRITTEN')
    const out = await shim(['-i'], vaultEnv('one'), `add-generic-password -U -a "me" -s "${serviceOf('one')}" -X "${hex(login)}"\n`)
    expect(out.code).toBe(0)
    expect(vault.read('one', SLOT)).toBe(login)
    // The real command was never involved.
    expect(() => readFileSync(fakeLog, 'utf8')).toThrow()
  })

  it('hands anything that is not a login to the real command, argv and stdin untouched', async () => {
    const out = await shim(['find-identity', '-v', '-p', 'codesigning'], vaultEnv('one'))
    expect(out.code).toBe(44)
    const stdin = 'add-generic-password -U -a "me" -s "Claude Code-device-keys" -X "00"\n'
    await shim(['-i'], vaultEnv('one'), stdin)
    const log = readFileSync(fakeLog, 'utf8')
    expect(log).toContain('REAL: find-identity -v -p codesigning')
    expect(log).toContain('REAL: -i')
    expect(log).toContain('Claude Code-device-keys')
  })

  it('without a ticket, or with another run\'s vault, it is the real command and nothing else', async () => {
    vault.put('one', 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    const noTicket = await shim(['find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-credentials'], {})
    expect(noTicket.stdout).toContain('FROM-OLD-KEYCHAIN')
    const otherRun = await shim(['find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-credentials'], {
      [VAULT_SOCKET_ENV]: '/somewhere/else.sock',
      [VAULT_TICKET_ENV]: tickets.ticketFor('one'),
    })
    expect(otherRun.stdout).toContain('FROM-OLD-KEYCHAIN')
  })

  it('moves an old account across on its first lookup, through the real command, and keeps it', async () => {
    adopting.add('one')
    const out = await shim(['find-generic-password', '-a', 'me', '-w', '-s', serviceOf('one')], vaultEnv('one'))
    expect(out.code).toBe(0)
    expect(out.stdout).toBe(`${claudeLogin('FROM-OLD-KEYCHAIN')}\n`)
    expect(vault.read('one', SLOT)).toBe(claudeLogin('FROM-OLD-KEYCHAIN'))
    expect(kept).toContain('one')
  })

  /*
   * Review finding 2. Before: `-i` anywhere in argv made the shim read stdin to
   * the end, so `security cms -D -i file` — whose `-i` is an input file — sat
   * waiting on a stdin that never closes (a terminal, a loop's pipe).
   */
  it('does not read stdin for a command whose -i is an ordinary flag', async () => {
    const env = vaultEnv('one')
    const exited = await new Promise<boolean>((resolve) => {
      const child = spawn(join(dir, 'security'), ['cms', '-D', '-i', 'profile.mobileprovision'], {
        env: withPath(env, '/usr/bin:/bin', 'darwin'),
        stdio: ['pipe', 'ignore', 'ignore'],
      })
      // stdin is left open on purpose: a terminal never sends end-of-file.
      const timer = setTimeout(() => {
        child.kill('SIGKILL')
        resolve(false)
      }, 4000)
      child.on('exit', () => {
        clearTimeout(timer)
        resolve(true)
      })
    })
    expect(exited).toBe(true)
    expect(readFileSync(fakeLog, 'utf8')).toContain('REAL: cms -D -i profile.mobileprovision')
  })

  /*
   * Review finding 10. Before: with the app not answering, only `-credentials`
   * lookups failed closed — an API-key lookup went to the real keychain — and a
   * write was answered 44 "not found".
   */
  it('fails closed for the API-key slot too, and refuses a write rather than calling it not found', async () => {
    const env = vaultEnv('one')
    await socket?.close()
    socket = null
    const suffix = suffixOf(CONFIG_DIRS.one ?? '')
    const apiKey = await shim(['find-generic-password', '-a', 'me', '-w', '-s', `Claude Code-${suffix}`], env)
    expect(apiKey.code).toBe(44)
    const write = await shim(['-i'], env, `add-generic-password -U -a "me" -s "${serviceOf('one')}" -X "${hex('x')}"\n`)
    expect(write.code).toBe(1)
    expect(write.stderr).toContain('nothing was changed')
    expect(() => readFileSync(fakeLog, 'utf8')).toThrow()
  })

  it('fails closed for a login when the app is not answering — never the keychain item a hash names', async () => {
    const env = vaultEnv('one')
    await socket?.close()
    socket = null
    const out = await shim(['find-generic-password', '-a', 'me', '-w', '-s', serviceOf('one')], env)
    expect(out.code).toBe(44)
    expect(() => readFileSync(fakeLog, 'utf8')).toThrow()
  })
})
