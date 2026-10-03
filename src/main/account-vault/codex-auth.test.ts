import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CODEX_AUTH_SLOT, CodexAuthKeeper, codexHomeInUse, readAuthFile, type DirWatch } from './codex-auth'
import { fakeCipher } from './fake-cipher.fixture'
import { AccountVault } from './store'

const ON_WINDOWS = process.platform === 'win32'

/** `auth.json` in the shape Codex writes it. Fake values only. */
const codexLogin = (token: string): string =>
  JSON.stringify({ OPENAI_API_KEY: null, tokens: { access_token: `at-${token}`, refresh_token: `rt-${token}` } })

let root = ''
let vault: AccountVault
/** Watcher events, fired by hand so nothing waits on the filesystem's timing. */
let fire: Map<string, () => void>
let watch: DirWatch

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-vault-codex-'))
  vault = new AccountVault({ dir: join(root, 'vault'), cipher: fakeCipher() })
  fire = new Map()
  watch = (dir, onEvent) => {
    fire.set(dir, onEvent)
    return () => fire.delete(dir)
  }
})
afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

function account(id: string): { id: string; configDir: string } {
  const configDir = join(root, 'profiles', id)
  mkdirSync(configDir, { recursive: true })
  return { id, configDir }
}

/** Fire the watcher and let the debounce run. */
async function settleWatch(dir: string): Promise<void> {
  fire.get(dir)?.()
  await new Promise((resolve) => setTimeout(resolve, 5))
}

describe('a Codex login, kept by the app', () => {
  it('moves an existing login into the vault the first time it is seen', () => {
    const work = account('work')
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('EXISTING'))
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => false })
    expect(keeper.settle(work)).toBe('kept')
    expect(vault.read('work', CODEX_AUTH_SLOT)).toBe(codexLogin('EXISTING'))
    expect(vault.summary('work')?.lastSource).toBe('adopted')
  })

  it.skipIf(ON_WINDOWS)('puts a kept login back where Codex reads it, owner-only', () => {
    const work = account('work')
    vault.put('work', 'codex', CODEX_AUTH_SLOT, codexLogin('KEPT'), 'sign-in')
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => false })
    expect(keeper.settle(work)).toBe('placed')
    const file = join(work.configDir, 'auth.json')
    expect(readFileSync(file, 'utf8')).toBe(codexLogin('KEPT'))
    expect(statSync(file).mode & 0o777).toBe(0o600)
  })

  it('captures the sign-in and every refresh Codex writes back', async () => {
    const work = account('work')
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => false })
    keeper.settle(work)
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('SIGNED-IN'))
    await settleWatch(work.configDir)
    expect(vault.read('work', CODEX_AUTH_SLOT)).toBe(codexLogin('SIGNED-IN'))
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('REFRESHED'))
    await settleWatch(work.configDir)
    expect(vault.read('work', CODEX_AUTH_SLOT)).toBe(codexLogin('REFRESHED'))
    expect(vault.summary('work')?.lastSource).toBe('refresh')
  })

  it('ignores a half-written file rather than keeping it', async () => {
    const work = account('work')
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => false })
    keeper.settle(work)
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('GOOD'))
    await settleWatch(work.configDir)
    writeFileSync(join(work.configDir, 'auth.json'), '{"tokens": {"acc')
    await settleWatch(work.configDir)
    expect(vault.read('work', CODEX_AUTH_SLOT)).toBe(codexLogin('GOOD'))
  })

  it('treats Codex removing its own file as a sign-out', async () => {
    const work = account('work')
    vault.put('work', 'codex', CODEX_AUTH_SLOT, codexLogin('A'), 'sign-in')
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => false })
    keeper.settle(work)
    unlinkSync(join(work.configDir, 'auth.json'))
    await settleWatch(work.configDir)
    expect(vault.has('work')).toBe(false)
  })

  it('at quit keeps the newest copy and leaves no plaintext login on disk', () => {
    const work = account('work')
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => false })
    keeper.settle(work)
    // Codex refreshed a moment before quit, before the watcher's tick.
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('LAST-MINUTE'))
    keeper.release(work)
    expect(existsSync(join(work.configDir, 'auth.json'))).toBe(false)
    expect(vault.read('work', CODEX_AUTH_SLOT)).toBe(codexLogin('LAST-MINUTE'))
    // And the next launch puts it back.
    expect(new CodexAuthKeeper(vault, { watch }).settle(work)).toBe('placed')
  })

  it('each account has its own file, so two Codex logins run side by side', () => {
    const one = account('one')
    const two = account('two')
    vault.put('one', 'codex', CODEX_AUTH_SLOT, codexLogin('ONE'), 'sign-in')
    vault.put('two', 'codex', CODEX_AUTH_SLOT, codexLogin('TWO'), 'sign-in')
    const keeper = new CodexAuthKeeper(vault, { watch })
    keeper.settle(one)
    keeper.settle(two)
    expect(readAuthFile(join(one.configDir, 'auth.json'))).toBe(codexLogin('ONE'))
    expect(readAuthFile(join(two.configDir, 'auth.json'))).toBe(codexLogin('TWO'))
    expect(keeper.following().sort()).toEqual(['one', 'two'])
  })

  it('forgetting an account removes its file and stops following it', () => {
    const work = account('work')
    vault.put('work', 'codex', CODEX_AUTH_SLOT, codexLogin('A'), 'sign-in')
    const keeper = new CodexAuthKeeper(vault, { watch })
    keeper.settle(work)
    keeper.forget(work)
    expect(existsSync(join(work.configDir, 'auth.json'))).toBe(false)
    expect(keeper.following()).toEqual([])
  })

  it('never takes away a file it could not keep', () => {
    const work = account('work')
    const noStore = new AccountVault({ dir: join(root, 'v2'), cipher: fakeCipher({ available: false }) })
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('ONLY-COPY'))
    const keeper = new CodexAuthKeeper(noStore, { watch, inUse: () => false })
    keeper.settle(work)
    keeper.release(work)
    expect(readAuthFile(join(work.configDir, 'auth.json'))).toBe(codexLogin('ONLY-COPY'))
  })

  /*
   * Review finding 5. Before: the file was removed at quit whatever else was
   * using the folder — the headless host on the same Mac, a terminal somebody
   * pointed at it — signing that Codex out mid-task.
   */
  it('leaves the file where it is when something outside the app is running Codex on that folder', () => {
    const work = account('work')
    const keeper = new CodexAuthKeeper(vault, { watch, debounceMs: 0, inUse: () => true })
    writeFileSync(join(work.configDir, 'auth.json'), codexLogin('SHARED'))
    keeper.settle(work)
    keeper.release(work)
    expect(readAuthFile(join(work.configDir, 'auth.json'))).toBe(codexLogin('SHARED'))
    expect(vault.read('work', CODEX_AUTH_SLOT)).toBe(codexLogin('SHARED'))
  })
})

describe('who else is running Codex on a folder', () => {
  const dir = '/Users/x/Library/Application Support/terminaldeck/profiles/work'
  const row = (pid: number, ppid: number, env: string): string => `${pid} ${ppid} codex PATH=/usr/bin ${env}`

  it('counts a process outside this app with exactly that CODEX_HOME', () => {
    expect(codexHomeInUse(row(500, 1, `CODEX_HOME=${dir} TERM=xterm`), dir, 100)).toBe(true)
    expect(codexHomeInUse(row(500, 1, `TERM=xterm CODEX_HOME=${dir}`), dir, 100)).toBe(true)
  })

  it('does not count this app’s own sessions, which are being stopped', () => {
    const listing = [`101 100 node-pty-helper`, row(500, 101, `CODEX_HOME=${dir}`)].join('\n')
    expect(codexHomeInUse(listing, dir, 100)).toBe(false)
  })

  it('does not mistake a sibling folder whose name starts the same way', () => {
    expect(codexHomeInUse(row(500, 1, `CODEX_HOME=${dir}-2 TERM=xterm`), dir, 100)).toBe(false)
    expect(codexHomeInUse(row(500, 1, 'TERM=xterm'), dir, 100)).toBe(false)
  })
})
