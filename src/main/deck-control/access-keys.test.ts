import { mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { recordsFenceAgrees, recordsFencePaths } from '../confine/records'
import { ACCESS_KEYS_FILE, AccessKeys, KEY_PREFIX, KeyRefused, MAX_KEYS, tiersFor } from './access-keys'

/**
 * The key store, on a real temp directory.
 *
 * The properties that matter are about what is on disk, so they are checked on
 * disk: the secret is not there, only its hash is; the file is the owner's
 * alone; and a file that cannot be read lets nothing in.
 */

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-access-keys-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function store(now?: () => number): AccessKeys {
  return new AccessKeys({ dir: join(dir, 'remote'), ...(now ? { now } : {}) })
}

const file = (): string => join(dir, 'remote', ACCESS_KEYS_FILE)

describe('making a key', () => {
  it('hands the secret back once and keeps only its hash', () => {
    const keys = store()
    const made = keys.create({ name: 'ChatGPT', level: 'work' })
    expect(made.key.startsWith(KEY_PREFIX)).toBe(true)
    expect(made.key.length).toBeGreaterThan(40)
    const onDisk = readFileSync(file(), 'utf8')
    expect(onDisk).not.toContain(made.key)
    expect(onDisk).not.toContain(made.key.slice(KEY_PREFIX.length))
    expect(onDisk).toMatch(/"hash": "[0-9a-f]{64}"/)
    // And no view of the key ever carries the secret or the hash.
    expect(JSON.stringify(keys.list())).not.toContain(made.key)
    expect(JSON.stringify(keys.list())).not.toContain('hash')
  })

  it('writes the file for this account alone', () => {
    if (process.platform === 'win32') return
    const keys = store()
    keys.create({ name: 'Cursor', level: 'look' })
    expect(statSync(file()).mode & 0o777).toBe(0o600)
    expect(statSync(join(dir, 'remote')).mode & 0o777).toBe(0o700)
  })

  it('makes a different secret every time', () => {
    const keys = store()
    const a = keys.create({ name: 'A', level: 'look' })
    const b = keys.create({ name: 'B', level: 'look' })
    expect(a.key).not.toBe(b.key)
  })

  it('asks first unless it was told, in so many words, not to', () => {
    const keys = store()
    expect(keys.create({ name: 'A', level: 'full' }).view.askFirst).toBe(true)
    expect(keys.create({ name: 'B', level: 'full', askFirst: 'no' }).view.askFirst).toBe(true)
    expect(keys.create({ name: 'C', level: 'full', askFirst: false }).view.askFirst).toBe(false)
  })

  it('refuses a key with no name, a name too long, and a level that is not one', () => {
    const keys = store()
    expect(() => keys.create({ name: '   ', level: 'look' })).toThrow(KeyRefused)
    expect(() => keys.create({ name: 'x'.repeat(61), level: 'look' })).toThrow(KeyRefused)
    expect(() => keys.create({ name: 'A', level: 'admin' })).toThrow(KeyRefused)
  })

  it('strips a newline out of a name, so it cannot forge a second log line', () => {
    const keys = store()
    const made = keys.create({ name: 'Chat\nGPT', level: 'look' })
    expect(made.view.name).toBe('Chat GPT')
  })

  it('stops at the cap', () => {
    const keys = store()
    for (let i = 0; i < MAX_KEYS; i += 1) keys.create({ name: `K${i}`, level: 'look' })
    expect(() => keys.create({ name: 'one too many', level: 'look' })).toThrow(KeyRefused)
  })
})

describe('matching a key', () => {
  it('finds the key it was made as, and nothing else', () => {
    const keys = store()
    const made = keys.create({ name: 'ChatGPT', level: 'work' })
    expect(keys.match(made.key)?.id).toBe(made.view.id)
    expect(keys.match(`${made.key}x`)).toBeNull()
    expect(keys.match(made.key.slice(0, -1))).toBeNull()
    expect(keys.match('')).toBeNull()
    expect(keys.match(null)).toBeNull()
    expect(keys.match(made.key.slice(KEY_PREFIX.length))).toBeNull()
  })

  it('still finds it after a restart, from the hash alone', () => {
    const made = store().create({ name: 'ChatGPT', level: 'work' })
    expect(store().match(made.key)?.name).toBe('ChatGPT')
  })
})

describe('changing and taking back a key', () => {
  it('the task tools are off for every key until the owner turns them on, and a file from before them reads as off', () => {
    const keys = store()
    const made = keys.create({ name: 'Claude Desktop', level: 'full' })
    expect(keys.get(made.view.id)?.tasks).toBe(false)
    keys.setTasks(made.view.id, 'yes')
    expect(keys.get(made.view.id)?.tasks).toBe(false)
    keys.setTasks(made.view.id, true)
    expect(keys.get(made.view.id)?.tasks).toBe(true)
    expect(store().get(made.view.id)?.tasks).toBe(true)
    keys.setTasks(made.view.id, false)
    expect(store().get(made.view.id)?.tasks).toBe(false)
    // A key saved before the switch existed carries no `tasks` at all: it stays off.
    keys.flush()
    const file = join(dir, 'remote', ACCESS_KEYS_FILE)
    const raw = JSON.parse(readFileSync(file, 'utf8')) as { keys: Array<Record<string, unknown>> }
    for (const key of raw.keys) delete key.tasks
    writeFileSync(file, JSON.stringify(raw))
    expect(store().get(made.view.id)?.tasks).toBe(false)
  })

  it('a revoke means the very next match finds nothing', () => {
    const keys = store()
    const made = keys.create({ name: 'ChatGPT', level: 'full' })
    expect(keys.revoke(made.view.id)).toBe(true)
    expect(keys.match(made.key)).toBeNull()
    expect(keys.get(made.view.id)).toBeNull()
    // And it is gone from disk, not just from memory.
    expect(store().match(made.key)).toBeNull()
    expect(keys.revoke(made.view.id)).toBe(false)
  })

  it('a level change is what the next read sees, on disk too', () => {
    const keys = store()
    const made = keys.create({ name: 'Cursor', level: 'look' })
    keys.setLevel(made.view.id, 'full')
    expect(keys.get(made.view.id)?.level).toBe('full')
    expect(store().get(made.view.id)?.level).toBe('full')
    expect(() => keys.setLevel(made.view.id, 'root')).toThrow(KeyRefused)
  })

  it('renames, switches ask-first, and limits folders', () => {
    const keys = store()
    const { view } = keys.create({ name: 'A', level: 'full' })
    expect(keys.rename(view.id, 'Claude on the web').name).toBe('Claude on the web')
    expect(keys.setAskFirst(view.id, false).askFirst).toBe(false)
    expect(keys.setAskFirst(view.id, undefined).askFirst).toBe(true)
    expect(keys.setFolders(view.id, ['/work/site', 'relative/ignored']).folders).toEqual(['/work/site'])
    expect(keys.setFolders(view.id, null).folders).toBeNull()
    expect(keys.setFolders(view.id, []).folders).toBeNull()
  })

  it('refuses to change a key that does not exist', () => {
    expect(() => store().rename('nope', 'x')).toThrow(KeyRefused)
  })

  it('tells a listener about a change a person made', () => {
    const keys = store()
    let told = 0
    keys.onChange(() => (told += 1))
    const { view } = keys.create({ name: 'A', level: 'look' })
    keys.setLevel(view.id, 'work')
    keys.revoke(view.id)
    keys.setInternet(true)
    expect(told).toBe(4)
  })
})

describe('the levels', () => {
  it('maps each level to exactly the tiers it names', () => {
    expect(tiersFor('look')).toEqual({ read: true, act: false, alter: false })
    expect(tiersFor('work')).toEqual({ read: true, act: true, alter: false })
    expect(tiersFor('full')).toEqual({ read: true, act: true, alter: true })
  })
})

describe('internet reach and the port', () => {
  it('starts off, and only a literal true turns it on', () => {
    const keys = store()
    expect(keys.internet()).toBe(false)
    expect(keys.setInternet('yes')).toBe(false)
    expect(keys.setInternet(true)).toBe(true)
    expect(store().internet()).toBe(true)
    keys.setInternet(false)
    expect(store().internet()).toBe(false)
  })

  it('remembers the port across a restart', () => {
    const keys = store()
    expect(keys.port()).toBeNull()
    keys.setPort(47821)
    expect(store().port()).toBe(47821)
    keys.setPort(-1)
    expect(store().port()).toBe(47821)
  })
})

describe('last used', () => {
  it('records when, how, and which app — and writes a new app at once', () => {
    let now = 1_000
    const keys = store(() => now)
    const { view } = keys.create({ name: 'A', level: 'look' })
    now = 5_000
    keys.noteUsed(view.id, 'internet', 'claude-ai 0.1.0')
    expect(keys.get(view.id)).toMatchObject({ lastUsedAt: 5_000, lastVia: 'internet', lastApp: 'claude-ai 0.1.0' })
    expect(store().get(view.id)?.lastApp).toBe('claude-ai 0.1.0')
  })

  it('does not write the file on every call', () => {
    let now = 1_000
    const keys = store(() => now)
    const { view } = keys.create({ name: 'A', level: 'look' })
    keys.noteUsed(view.id, 'this-mac', 'cursor')
    const before = readFileSync(file(), 'utf8')
    now += 1_000
    keys.noteUsed(view.id, 'this-mac', null)
    expect(readFileSync(file(), 'utf8')).toBe(before)
    keys.flush()
    expect(readFileSync(file(), 'utf8')).not.toBe(before)
  })

  it('cleans what an app says about itself before keeping it', () => {
    const keys = store()
    const { view } = keys.create({ name: 'A', level: 'look' })
    keys.noteUsed(view.id, 'internet', `evil\nrow ${'x'.repeat(200)}`)
    const label = keys.get(view.id)?.lastApp ?? ''
    expect(label).not.toContain('\n')
    expect(label.length).toBeLessThanOrEqual(80)
  })
})

describe('a file that cannot be read', () => {
  it('lets nothing in, keeps the door shut, and sets the bad copy aside', () => {
    const keys = store()
    const made = keys.create({ name: 'A', level: 'full' })
    keys.setInternet(true)
    writeFileSync(file(), '{ this is not json')
    const reopened = store()
    expect(reopened.match(made.key)).toBeNull()
    expect(reopened.internet()).toBe(false)
    expect(reopened.loadProblem()).toMatch(/could not be read/)
    expect(readdirSync(join(dir, 'remote')).some((name) => name.includes('.unreadable-'))).toBe(true)
  })

  it('drops a record it cannot trust rather than guessing at it', () => {
    const keys = store()
    const made = keys.create({ name: 'A', level: 'full' })
    const raw = JSON.parse(readFileSync(file(), 'utf8')) as { keys: Array<Record<string, unknown>> }
    raw.keys[0].level = 'superuser'
    writeFileSync(file(), JSON.stringify(raw))
    expect(store().match(made.key)).toBeNull()
  })
})

describe('the records fence', () => {
  it('fences the file this store actually writes', () => {
    // The fence spells the path itself, so the copilot's confinement does not
    // depend on this module. This is the pin that the two spellings agree.
    // Resolved, because `/var` is `/private/var` on macOS and the fence names
    // what the kernel sees — the reason `recordsFencePaths` resolves at all.
    const userData = realpathSync(dir)
    const keys = new AccessKeys({ dir: join(userData, 'remote') })
    keys.create({ name: 'A', level: 'look' })
    expect(
      recordsFenceAgrees(recordsFencePaths(userData), {
        routines: join(userData, 'routines'),
        routineState: join(userData, 'routine-state.json'),
        log: join(userData, 'copilot-log'),
        accessKeys: join(userData, 'remote', ACCESS_KEYS_FILE),
      }),
    ).toBe(true)
  })
})

describe('how a key’s app hears about its sessions', () => {
  it('starts waiting, needs an address for a webhook, and mints the signing secret once', () => {
    const keys = store()
    const { view } = keys.create({ name: 'A', level: 'work' })
    expect(view.notify).toEqual({ mode: 'wait', url: null, hasSecret: false })
    expect(() => keys.setNotify(view.id, { mode: 'webhook' })).toThrow(KeyRefused)
    expect(() => keys.setNotify(view.id, { mode: 'webhook', url: 'http://hooks.example.com/x' })).toThrow(/https/)
    const first = keys.setNotify(view.id, { mode: 'webhook', url: 'https://hooks.example.com/x' })
    expect(first.secret).toMatch(/^whsec_/)
    expect(first.view.notify).toEqual({ mode: 'webhook', url: 'https://hooks.example.com/x', hasSecret: true })
    // Switching away and back keeps the address and the secret, and shows no new one.
    keys.setNotify(view.id, { mode: 'off' })
    const again = keys.setNotify(view.id, { mode: 'webhook' })
    expect(again.secret).toBeNull()
    expect(keys.notifySettings(view.id)).toEqual({ mode: 'webhook', url: 'https://hooks.example.com/x', secret: first.secret })
  })

  it('never puts the secret in a view or a list, and a new one replaces the old', () => {
    const keys = store()
    const { view } = keys.create({ name: 'A', level: 'work' })
    const { secret } = keys.setNotify(view.id, { mode: 'webhook', url: 'https://hooks.example.com/x' })
    expect(JSON.stringify(keys.list())).not.toContain(String(secret))
    const rotated = keys.rotateWebhookSecret(view.id)
    expect(rotated.secret).not.toBe(secret)
    expect(keys.notifySettings(view.id)?.secret).toBe(rotated.secret)
    // And it survives a restart, in the 0600 file beside the hashes.
    expect(store().notifySettings(view.id)?.secret).toBe(rotated.secret)
  })

  it('allows plain http only to this Mac', () => {
    const keys = store()
    const { view } = keys.create({ name: 'A', level: 'work' })
    expect(() => keys.setNotify(view.id, { mode: 'webhook', url: 'http://127.0.0.1:9000/hook' })).not.toThrow()
    expect(() => keys.setNotify(view.id, { mode: 'webhook', url: 'https://u:p@hooks.example.com/x' })).toThrow(/password/)
  })
})
