import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ProviderId } from '../../shared/types'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { EXIT_NOT_FOUND, NOT_FOUND_TEXT, type ShimAnswer } from './keychain-requests'
import { answerShim, runSteps, TicketBook, type LoginSource, type VaultServerDeps } from './server'
import { AccountVault } from './store'

/**
 * A session's seat at the vault: the login it is handed can change while the
 * process — and so the keychain *names* it asks for — stays exactly as it was.
 * This is the mechanism under "switch in place" (`switch-in-place.ts`); the
 * real CLI running against it is `switch-in-place.cli.test.ts`.
 */

const SLOT = 'keychain:Claude Code-credentials'
const hex = (text: string): string => Buffer.from(text, 'utf8').toString('hex')
const suffixOf = (dir: string): string => createHash('sha256').update(dir).digest('hex').slice(0, 8)
/** The service a process started with this config directory asks for. `null`: the machine's own install. */
const serviceIn = (dir: string | null): string =>
  dir === null ? 'Claude Code-credentials' : `Claude Code-credentials-${suffixOf(dir)}`

const DIRS: Record<string, string> = { a: '/cfg/a', b: '/cfg/b', c: '/cfg/c', mine: '/Users/me/.claude-work' }

function body(ticket: string, argv: string[], stdin = ''): Buffer {
  return Buffer.from([ticket, String(argv.length), ...argv, stdin].join('\0'), 'utf8')
}
const find = (ticket: string, dir: string | null): Buffer =>
  body(ticket, ['find-generic-password', '-a', 'me', '-w', '-s', serviceIn(dir)])
const add = (ticket: string, dir: string | null, value: string): Buffer =>
  body(ticket, ['-i'], `add-generic-password -U -a "me" -s "${serviceIn(dir)}" -X "${hex(value)}"\n`)

let root = ''
let vault: AccountVault
let tickets: TicketBook
let sources: Map<string, LoginSource | null>
let adopting: Set<string>
let ran: Array<{ argv: readonly string[]; stdin: string | null }>
let keychainAnswer: (argv: readonly string[]) => ShimAnswer
let deps: VaultServerDeps

beforeEach(() => {
  root = mkdtempSync('/tmp/tds-')
  vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
  tickets = new TicketBook()
  sources = new Map<string, LoginSource | null>([
    ['a', { kind: 'vault' }],
    ['b', { kind: 'vault' }],
    ['c', { kind: 'vault' }],
    ['system', { kind: 'keychain', dir: null }],
    ['mine', { kind: 'keychain', dir: DIRS.mine ?? null }],
  ])
  adopting = new Set()
  ran = []
  keychainAnswer = () => ({ code: 0, stdout: 'FROM-KEYCHAIN\n', stderr: '' })
  const providers = new Map<string, ProviderId>([
    ['a', 'claude'],
    ['b', 'claude'],
    ['c', 'claude'],
    ['system', 'claude'],
    ['mine', 'claude'],
  ])
  deps = {
    vault,
    tickets,
    providerOf: (id) => providers.get(id) ?? null,
    configDirOf: (id) => DIRS[id] ?? null,
    adopting: (id) => adopting.has(id),
    markKept: (id) => adopting.delete(id),
    sourceOf: (id) => sources.get(id) ?? null,
    runReal: async (argv, stdin) => {
      ran.push({ argv, stdin })
      return keychainAnswer(argv)
    },
  }
  vault.put('a', 'claude', SLOT, claudeLogin('A'), 'sign-in')
  vault.put('b', 'claude', SLOT, claudeLogin('B'), 'sign-in')
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

/** A seat for a session started as `a` in its own folder. */
function seated(sessionId = 's1', launch = 'a', launchDir: string | null = DIRS[launch] ?? null): string {
  const ticket = tickets.seat(launch, launchDir)
  tickets.bind(ticket, sessionId)
  return ticket
}

describe('a seat: one process, its login changeable in place', () => {
  it('is answered as the account it was started as, then — same ticket, same names — as the one it was switched to', () => {
    const ticket = seated()
    expect(answerShim(find(ticket, DIRS.a ?? null), deps)).toMatchObject({ answer: { code: 0, stdout: claudeLogin('A') } })
    expect(tickets.retarget('s1', 'b')).toBe(true)
    // The process still asks under its own folder's name; it is handed b's login.
    expect(answerShim(find(ticket, DIRS.a ?? null), deps)).toMatchObject({ answer: { code: 0, stdout: claudeLogin('B') } })
  })

  it('switching one session changes nothing for another session on the same account', () => {
    const one = seated('s1')
    const two = seated('s2')
    tickets.retarget('s1', 'b')
    expect(answerShim(find(one, DIRS.a ?? null), deps)).toMatchObject({ answer: { stdout: claudeLogin('B') } })
    expect(answerShim(find(two, DIRS.a ?? null), deps)).toMatchObject({ answer: { stdout: claudeLogin('A') } })
  })

  it('a nested agent with its own folder, holding the inherited ticket, still goes to the real command', () => {
    const ticket = seated()
    tickets.retarget('s1', 'b')
    expect(answerShim(find(ticket, '/somewhere/else'), deps)).toEqual({ kind: 'pass' })
  })

  it('a refresh written after the switch but before the agent has read again lands in the account it refreshed', () => {
    const ticket = seated()
    answerShim(find(ticket, DIRS.a ?? null), deps) // the agent holds a's login
    tickets.retarget('s1', 'b')
    // a's refresh, already under way when the switch happened, comes back:
    answerShim(add(ticket, DIRS.a ?? null, claudeLogin('A-REFRESHED')), deps)
    expect(vault.read('a', SLOT)).toBe(claudeLogin('A-REFRESHED'))
    expect(vault.read('b', SLOT)).toBe(claudeLogin('B'))
  })

  it('once the agent has read the new login, its refresh lands in the new account — never the old one', () => {
    const ticket = seated()
    answerShim(find(ticket, DIRS.a ?? null), deps)
    tickets.retarget('s1', 'b')
    answerShim(find(ticket, DIRS.a ?? null), deps) // the compare-and-swap read: b's login
    answerShim(add(ticket, DIRS.a ?? null, claudeLogin('B-REFRESHED')), deps)
    expect(vault.read('b', SLOT)).toBe(claudeLogin('B-REFRESHED'))
    expect(vault.read('a', SLOT)).toBe(claudeLogin('A'))
  })

  it('says when a switched seat is first handed the new login', () => {
    const heard: Array<{ sessionId: string | null; accountId: string }> = []
    deps.onServed = (event) => heard.push(event)
    const ticket = seated()
    answerShim(find(ticket, DIRS.a ?? null), deps)
    tickets.retarget('s1', 'b')
    answerShim(find(ticket, DIRS.a ?? null), deps)
    answerShim(find(ticket, DIRS.a ?? null), deps)
    expect(heard).toEqual([{ sessionId: 's1', accountId: 'b' }])
  })

  it('a seat serving an account that is then deleted answers "not found", never another login', () => {
    const ticket = seated()
    tickets.retarget('s1', 'b')
    tickets.revoke('b')
    expect(answerShim(find(ticket, DIRS.a ?? null), deps)).toEqual({
      kind: 'exit',
      answer: { code: EXIT_NOT_FOUND, stdout: '', stderr: NOT_FOUND_TEXT },
    })
  })

  it('is forgotten when its session ends', () => {
    const ticket = seated()
    tickets.release('s1')
    expect(tickets.sessionSeat('s1')).toBeNull()
    expect(answerShim(find(ticket, DIRS.a ?? null), deps)).toMatchObject({ answer: { code: EXIT_NOT_FOUND } })
  })
})

describe('a seat started on a login the agent keeps itself', () => {
  it('passes every lookup to the real command until it is switched — exactly as before the app kept anything', () => {
    const ticket = seated('s1', 'system', null)
    expect(answerShim(find(ticket, null), deps)).toEqual({ kind: 'pass' })
    expect(answerShim(add(ticket, null, claudeLogin('MINE')), deps)).toEqual({ kind: 'pass' })
    expect(vault.has('system')).toBe(false)
  })

  it('switched to an account the app keeps, its unsuffixed lookups are answered from the vault', () => {
    const ticket = seated('s1', 'system', null)
    tickets.retarget('s1', 'b')
    expect(answerShim(find(ticket, null), deps)).toMatchObject({ answer: { code: 0, stdout: claudeLogin('B') } })
  })

  it('switched back, its own login is the real keychain item again — read there, not copied in', () => {
    const ticket = seated('s1', 'system', null)
    tickets.retarget('s1', 'b')
    answerShim(find(ticket, null), deps)
    tickets.retarget('s1', 'system')
    answerShim(find(ticket, null), deps) // reads its own item: pass
    expect(answerShim(find(ticket, null), deps)).toEqual({ kind: 'pass' })
    expect(vault.has('system')).toBe(false)
  })
})

describe('a seat switched onto a login the agent keeps', () => {
  it('reads that login from the agent’s own keychain item, under its own name — never from the vault', async () => {
    const ticket = seated()
    tickets.retarget('s1', 'system')
    const answer = answerShim(find(ticket, DIRS.a ?? null), deps)
    expect(answer.kind).toBe('steps')
    if (answer.kind !== 'steps') return
    const ranAnswer = await runSteps(answer, deps, 'me')
    expect(ran).toEqual([{ argv: ['find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-credentials'], stdin: null }])
    expect(ranAnswer).toEqual({ code: 0, stdout: 'FROM-KEYCHAIN', stderr: '' })
  })

  it('a folder the person chose is read under that folder’s hash', async () => {
    const ticket = seated()
    tickets.retarget('s1', 'mine')
    const answer = answerShim(find(ticket, DIRS.a ?? null), deps)
    if (answer.kind !== 'steps') throw new Error(`expected steps, got ${answer.kind}`)
    await runSteps(answer, deps, 'me')
    expect(ran[0]?.argv.at(-1)).toBe(serviceIn(DIRS.mine ?? null))
  })

  it('a refresh written back goes to that keychain item over stdin — the token is never on a command line', async () => {
    const ticket = seated()
    tickets.retarget('s1', 'system')
    const read = answerShim(find(ticket, DIRS.a ?? null), deps)
    if (read.kind !== 'steps') throw new Error('expected steps')
    await runSteps(read, deps, 'me')
    const write = answerShim(add(ticket, DIRS.a ?? null, claudeLogin('SYS-REFRESHED')), deps)
    if (write.kind !== 'steps') throw new Error('expected steps')
    await runSteps(write, deps, 'me')
    const last = ran.at(-1)
    expect(last?.argv).toEqual(['-i'])
    expect(last?.stdin).toBe(
      `add-generic-password -U -a "me" -s "Claude Code-credentials" -X "${hex(claudeLogin('SYS-REFRESHED'))}"\n`,
    )
    expect(ran.every((call) => !call.argv.join(' ').includes('SYS-REFRESHED'))).toBe(true)
    expect(vault.read('a', SLOT)).toBe(claudeLogin('A'))
  })

  it('an account made before the vault is moved in from its own item on first use, then answered from the vault', async () => {
    adopting.add('c')
    const ticket = seated()
    tickets.retarget('s1', 'c')
    keychainAnswer = () => ({ code: 0, stdout: `${claudeLogin('C')}\n`, stderr: '' })
    const answer = answerShim(find(ticket, DIRS.a ?? null), deps)
    if (answer.kind !== 'steps') throw new Error('expected steps')
    expect(await runSteps(answer, deps, 'me')).toMatchObject({ code: 0, stdout: claudeLogin('C') })
    expect(ran[0]?.argv.at(-1)).toBe(serviceIn(DIRS.c ?? null))
    expect(vault.read('c', SLOT)).toBe(claudeLogin('C'))
    // Settled: the next lookup never touches the keychain.
    expect(answerShim(find(ticket, DIRS.a ?? null), deps)).toMatchObject({ kind: 'exit', answer: { stdout: claudeLogin('C') } })
  })

  it('an account whose login is out of reach is "not found" — the keychain item the folder names is never read instead', () => {
    sources.set('b', null)
    const ticket = seated()
    tickets.retarget('s1', 'b')
    expect(answerShim(find(ticket, DIRS.a ?? null), deps)).toMatchObject({ kind: 'exit', answer: { code: EXIT_NOT_FOUND } })
  })
})
