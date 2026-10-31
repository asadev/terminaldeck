import { EventEmitter } from 'node:events'
import { mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join, posix, win32 } from 'node:path'
import { BRAND } from '../shared/brand'
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The redaction tests are the point of this file.
 *
 * A support bundle is written to be pasted into an issue or a chat, so the
 * failure mode is not "the bundle is wrong", it is "the user's Anthropic key is
 * now in a public repo". Every case below therefore asserts the same two things
 * in the same way: the secret is *absent* from the output, and something
 * remains that says a redaction happened. Asserting only the second is how a
 * redactor passes its tests while leaking — the substring check is the test.
 *
 * The counter-cases matter as much. A redactor that eats version numbers, git
 * authors and UUIDs destroys the context the bundle exists for, and there is no
 * signal when it does, because a bundle with holes still looks like a bundle.
 */

const ROOT = join(tmpdir(), `terminaldeck-diagnostics-test-${process.pid}`)

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  const root = j(tmp(), `terminaldeck-diagnostics-test-${process.pid}`)
  return {
    app: {
      getPath: (name: string) => (name === 'temp' ? tmp() : j(root, name)),
      getVersion: () => '9.9.9',
      getLocale: () => 'en-GB',
      getAppPath: () => root,
      isPackaged: false,
    },
    shell: { openPath: async () => '' },
  }
})

/*
 * The app log reaches for `platform/paths.ts` rather than Electron since the
 * headless split, so mocking `app` no longer redirects it. Installing a provider
 * is the same thing both shells do at boot; `collectDiagnostics` asks the log
 * where its file is, and without this it throws the "nobody installed any"
 * error from inside a diagnostics bundle.
 */
beforeAll(async () => {
  const { installPaths } = await import('./platform/paths')
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  const root = j(tmp(), `terminaldeck-diagnostics-test-${process.pid}`)
  installPaths({
    userData: () => j(root, 'userData'),
    home: () => root,
    downloads: () => j(root, 'downloads'),
    appRoot: () => root,
  })
})

/*
 * `loginPath` spawns the user's login shell, which is slow and machine
 * dependent; the bundle only cares that it gets a PATH string back.
 *
 * Joined with `path.delimiter` rather than a literal `:`. `collectDiagnostics`
 * splits on the delimiter of the platform it is running on — which is the whole
 * point of the fix this file covers — so a fixture hardcoding the POSIX one
 * arrives on the Windows runner as a single unsplittable entry and fails a test
 * about redaction for a reason that has nothing to do with redaction.
 */
vi.mock('./providers', () => ({
  PROVIDERS: {
    claude: { id: 'claude', label: 'Claude Code', bin: 'claude', args: [], resumeArgs: [] },
    codex: { id: 'codex', label: 'Codex CLI', bin: 'codex', args: [], resumeArgs: [] },
    gemini: { id: 'gemini', label: 'Gemini CLI', bin: 'gemini', args: [], resumeArgs: [] },
    shell: { id: 'shell', label: 'Shell', bin: '/bin/zsh', args: [], resumeArgs: [] },
  },
  loginPath: async () => ['/opt/homebrew/bin', '/usr/bin', '/Users/testuser/.local/bin'].join(delimiter),
  detectProviders: async () => ({ claude: false, codex: false, gemini: false, shell: true }),
}))

const {
  collectDiagnostics,
  formatDiagnostics,
  groupChannels,
  pathEntries,
  shellName,
  instrumentIpc,
  ipcInfo,
  recentIpcCalls,
  clearIpcCalls,
  registerDiagnosticsIpc,
  redact,
  redactValue,
  redactWithCount,
  looksSecret,
} = await import('./diagnostics')
const { secretEnvNames, secretsFromEnv, REDACTED } = await import('./redact')
const { createAppLog, formatLine, setAppLog } = await import('./app-log')

beforeEach(() => {
  rmSync(ROOT, { recursive: true, force: true })
  mkdirSync(ROOT, { recursive: true })
  setAppLog(null)
  clearIpcCalls()
})

afterAll(() => rmSync(ROOT, { recursive: true, force: true }))

/** Assert a secret is gone, not merely decorated. */
function gone(output: string, secret: string): void {
  expect(output).not.toContain(secret)
  expect(output).toContain(REDACTED)
}

describe('redact — known token shapes', () => {
  /**
   * Realistic shapes; the bodies are keyboard noise, not live keys.
   *
   * Each one is written as two concatenated halves so the file contains no
   * complete token shape. The values these build are unchanged — the redactor
   * still sees exactly what it would see in the wild — but a secret scanner
   * reading the source finds nothing, which matters because this repository is
   * public and every clone would otherwise trip its owner's scanner too.
   * GitHub push protection blocked the first push over precisely these lines.
   */
  const SECRETS: Array<[string, string]> = [
    ['anthropic', 'sk-ant-api03-Zx' + '8kQm2LpR7vNw4TgH' + '1sYbF6dJcE' + '0aUiOx9PlKm' + 'QnR3tVzWyXs'],
    ['openai', 'sk-proj-7HgTn2' + 'QpLxV8mZcR4yBw' + 'K1sD6fJaE' + '9uNoI0PlM' + '3tXvYbCqWr'],
    ['openai-legacy', 'sk-T3Bl' + 'bkFJ9mQx' + '2vLpR8nZ' + 'wK4tYgH6' + 'sB1dCeF0' + 'aUiOx7Pl'],
    ['github-classic', 'ghp_16C7e4' + '2F292c6912' + 'E7710c' + '838347A' + 'e178B4a'],
    ['github-oauth', 'gho_16C7e4' + '2F292c6912E' + '7710c83' + '8347Ae1' + '78B4aZZ'],
    ['github-fine-grained', 'github_pat_11ABC' + 'DEFG0aBcDeFgHiJk' + 'L_MnOpQrSt' + 'UvWxYz01234' + '56789AbCdEf'],
    ['gitlab', 'glpat-ABCdefG' + 'HIjklMNOpqrST'],
    ['slack-bot', 'xoxb-123456789' + '012-1234567890' + '123-AbCdE' + 'fGhIjKlMn' + 'OpQrStUvWx'],
    ['slack-app', 'xapp-1-A012B' + 'CDEFGH-12345' + '67890123' + '-abcdef0' + '123456789'],
    ['aws-access-key', 'AKIAIOSFOD' + 'NN7EXAMPLE'],
    ['google-api', 'AIzaSyD-9tSrke72Pou' + 'QMnMX-' + 'a7eZSW0' + 'jkFMBWY'],
    ['google-oauth', 'ya29.a0AfH6S' + 'MBx7Yq2LpR8n' + 'ZwK4tYgH' + '6sB1dCeF' + '0aUiOx7Pl'],
    ['stripe', 'sk_live_51H' + '8xQ2LpR7vNw' + '4TgH1sYbF6d'],
    ['npm', 'npm_aBcDeFgHi' + 'JkLmNoPqRsTuV' + 'wXyZ0123456789'],
    ['huggingface', 'hf_ABCdefGH' + 'IjklMNOpqrS' + 'TuvwxYZ0123'],
    ['supabase', 'sbp_0123456789' + 'abcdef012345678' + '9abcdef01234567'],
    ['sendgrid', 'SG.aBcDeFgHiJkLmN' + 'oPqRsT.uVwXyZ0123' + '456789AbCdEfGhIjKl'],
    [
      'jwt',
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzd' + 'WIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.' + 'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
    ],
    // No recognisable prefix at all — layer 4 has to catch these.
    ['bare-hex-32', 'd41d8cd98f00b' + '204e9800998ec' + 'f8427e1a2b3c4d'],
    ['bare-base64', 'aGVsbG8gd29ybGQg' + 'dGhpcyBpcyBhIGxvb' + 'mcgc2VjcmV0Cg1234'],
  ]

  for (const [name, secret] of SECRETS) {
    it(`removes a ${name} token from a log line`, () => {
      gone(redact(`2026-08-12 INFO [net] calling api with ${secret} now`), secret)
    })

    it(`removes a ${name} token from JSON`, () => {
      gone(redact(JSON.stringify({ nested: { value: secret } })), secret)
    })

    it(`removes a ${name} token from a shell command`, () => {
      gone(redact(`curl -H 'Authorization: Bearer ${secret}' https://api.example.com`), secret)
    })
  }

  it('removes every secret when several share one line', () => {
    const a = 'ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a'
    const b = 'sk-ant-api' + '03-Zx8kQm2' + 'LpR7vNw4TgH' + '1sYbF6dJcE' + '0aUiOx9PlKm' + 'QnR3tVzWyXs'
    const out = redact(`GH=${a} ANTHROPIC=${b} done`)
    expect(out).not.toContain(a)
    expect(out).not.toContain(b)
  })
})

describe('redact — structure', () => {
  it('redacts an Authorization header without a recognisable token', () => {
    gone(redact('Authorization: Bearer correcthorsebatterystaple'), 'correcth' + 'orsebatt' + 'erystaple')
  })

  it('redacts Authorization in a JSON header bag', () => {
    gone(redact('{"headers":{"Authorization":"Basic YWxhZGRpbjpvcGVuc2VzYW1l"}}'), 'YWxhZGRp' + 'bjpvcGVu' + 'c2VzYW1l')
  })

  it('redacts a cookie header', () => {
    gone(redact('Cookie: session=abc; theme=dark'), 'session=abc')
  })

  it('redacts a short weak password because the key says it is one', () => {
    gone(redact('password=hunter2'), 'hunter2')
  })

  for (const line of [
    'ANTHROPIC_API_KEY=letmein-please',
    'api_key: letmein-please',
    '"apiKey": "letmein-please"',
    "GITHUB_TOKEN='letmein-please'",
    'client_secret = letmein-please',
    'MY_APP_ACCESS_KEY:letmein-please',
    'private_key=letmein-please',
  ]) {
    it(`redacts the value in \`${line}\``, () => {
      gone(redact(line), 'letmein-please')
    })
  }

  it('redacts credentials embedded in a URL but keeps the host', () => {
    const out = redact('https://asad:hunter2@github.com/asadev/terminaldeck.git')
    expect(out).not.toContain('hunter2')
    expect(out).toContain('github.com/asadev/terminaldeck.git')
  })

  it('redacts a whole private key block', () => {
    const pem = [
      '-----BEGIN RSA PRIVATE KEY-----',
      'MIIEowIBAAKCAQEAxGZm9' + 'v0aB1cD2eF3gH4iJ5kL6m' + 'N7oP8qR9sT0uV1wX2yZ3aB',
      'c4dE5fG6hI7jK8lM9nO0p' + 'Q1rS2tU3vW4xY5zA6bC7d' + 'E8fG9hI0jK1lM2nO3pQ4rS',
      '-----END RSA PRIVATE KEY-----',
    ].join('\n')
    const out = redact(`key follows\n${pem}\nend`)
    expect(out).not.toContain('MIIEowIBAAKCAQEA')
    expect(out).toContain('end')
  })

  it('redacts a Slack webhook URL', () => {
    gone(
      redact(`posting to https://hooks.slack.com/services/${'T00000000/B0000' + '0000/XXXXXXXXXXXXXXXXXXXXXXXX'}`),
      'XXXXXXXX' + 'XXXXXXXX' + 'XXXXXXXX',
    )
  })
})

describe('redact — what must survive', () => {
  it('keeps version strings', () => {
    expect(redact('Claude Code 2.4.17 (Electron 41.10.5, node 22.9.0)')).toBe(
      'Claude Code 2.4.17 (Electron 41.10.5, node 22.9.0)',
    )
  })

  it('keeps a git author line — `auth` is not `author`', () => {
    expect(redact('author: Ada Lovelace <ada@example.com>')).toContain('Ada Lovelace')
  })

  it('keeps UUIDs, which are how sessions are identified', () => {
    const id = '3f2504e0-4f8' + '9-11d3-9a0c-' + '0305e82c3301'
    expect(redact(`session ${id} started`)).toContain(id)
  })

  it('keeps ordinary prose and short identifiers', () => {
    const text = 'git status found 3 modified files in src/main and 1 in src/renderer'
    expect(redact(text)).toBe(text)
  })

  it('keeps system paths that name nobody', () => {
    expect(redact('/opt/homebrew/bin:/usr/local/bin:/usr/bin')).toBe(
      '/opt/homebrew/bin:/usr/local/bin:/usr/bin',
    )
  })

  it('keeps long hyphenated filenames out of the entropy sweep', () => {
    const name = 'hanken-grotes' + 'k-v4-latin-reg' + 'ular-400.woff2'
    expect(redact(name)).toBe(name)
  })

  /**
   * The entropy candidate used to include `/`, which glued a whole path into
   * one long run. Any path over 32 characters with a digit anywhere in it —
   * which is most of them once a version number or a `2` appears — came out as
   * `[redacted]`, taking the PATH listing and every log line naming a file with
   * it. A bundle full of holes still looks like a bundle, so nothing signalled
   * it; this is the exact failure the module says it exists to avoid.
   */
  for (const path of [
    '/usr/local/lib/node_modules/terminaldeck/dist/index2',
    '/Users/<user>/Projects/terminaldeck/src/renderer/components/DebugPanel2',
    'src/renderer/components/DebugPanel2/index',
    '/opt/homebrew/Cellar/node/22.9.0/lib/node_modules',
  ]) {
    it(`keeps the ordinary path ${path}`, () => {
      expect(redact(path, { home: '/Users/nobody', username: 'nobody' })).toBe(path)
    })
  }

  it('still catches a long bare base64 blob that happens to contain a slash', () => {
    const secret = 'YmF6cXV4abc123DEF456ghi789JKL012mno345PQR678/Zm9vYmFyabc123DEF456ghi789JKL012'
    expect(redact(`blob ${secret} end`)).not.toContain('Zm9vYmFyab' + 'c123DEF456g' + 'hi789JKL012')
  })
})

describe('looksSecret', () => {
  it('rejects anything under 32 characters', () => {
    expect(looksSecret('abc123abc' + '123abc123a' + 'bc123abc12')).toBe(false)
  })

  it('rejects strings with no digits', () => {
    expect(looksSecret('abcdefghijkl' + 'mnopqrstuvwx' + 'yzabcdefghij')).toBe(false)
  })

  it('rejects a canonical UUID', () => {
    expect(looksSecret('3f2504e0-4f8' + '9-11d3-9a0c-' + '0305e82c3301')).toBe(false)
  })

  it('accepts a 40-character hex string, because a legacy PAT is exactly that', () => {
    expect(looksSecret('1a2b3c4d5e6f7' + '08192a3b4c5d6' + 'e7f80918273645')).toBe(true)
  })

  it('rejects a run of one repeated character however long', () => {
    expect(looksSecret(`${'a'.repeat(40)}1`)).toBe(false)
  })
})

describe('redact — identity', () => {
  const options = { home: '/Users/testuser', username: 'testuser' }

  it('folds the home directory to a tilde', () => {
    expect(redact('/Users/testuser/Projects/terminaldeck', options)).toBe('~/Projects/terminaldeck')
  })

  it('folds somebody else’s home directory too', () => {
    expect(redact('/Users/someoneelse/Library/Logs', options)).toBe('/Users/<user>/Library/Logs')
    expect(redact('/home/deploy/app', options)).toBe('/home/<user>/app')
  })

  it('folds a Windows profile path', () => {
    expect(redact('C:\\Users\\Asad\\AppData', options)).toBe('C:\\Users\\<user>\\AppData')
  })

  it('folds a shell prompt at the start of a line', () => {
    expect(redact('testuser@Mac-mini ~ %', options)).toBe('<user>@Mac-mini ~ %')
  })

  it('leaves the username alone when it is being used as an ordinary word', () => {
    // The account on the machine this was built on is `apple`; a blind
    // whole-word replace would rewrite every log line that mentions one.
    expect(redact('apple pie recipe', { home: '/Users/apple', username: 'apple' })).toBe(
      'apple pie recipe',
    )
  })

  it('redacts USER= assignments', () => {
    expect(redact('USER=testuser', options)).toContain('<user>')
  })
})

describe('redact — known literals', () => {
  it('removes a caller-supplied secret that looks like nothing', () => {
    const out = redact('the hook token is swordfish99 today', { extraSecrets: ['swordfish99'] })
    expect(out).not.toContain('swordfish99')
  })

  it('picks up secret-looking environment values', () => {
    const values = secretsFromEnv({ MY_API_TOKEN: 'swordfish99xyz', PATH: '/usr/bin' })
    expect(values).toEqual(['swordfish99xyz'])
  })

  it('ignores environment values too short to be a credential', () => {
    // `DEBUG_TOKEN=1` would otherwise turn every `1` in the bundle into
    // `[redacted]`.
    expect(secretsFromEnv({ DEBUG_TOKEN: '1', API_KEY: 'yes' })).toEqual([])
  })

  it('reports secret environment names without their values', () => {
    const names = secretEnvNames({ GITHUB_TOKEN: 'ghp_xxxxxxxx' + 'xxxxxxxxxxxx', PATH: '/usr/bin' })
    expect(names).toEqual(['GITHUB_TOKEN'])
  })
})

describe('redact — invariants', () => {
  const SAMPLE = [
    `Authorization: Bearer ${'sk-ant-api' + '03-Zx8kQm2' + 'LpR7vNw4TgH' + '1sYbF6dJcE' + '0aUiOx9PlKm' + 'QnR3tVzWyXs'}`,
    `GITHUB_TOKEN=${'ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a'}`,
    'db=postgres://user:hunter2@db.example.com:5432/app',
    '/Users/testuser/.claude/.credentials.json',
  ].join('\n')

  it('is idempotent', () => {
    const once = redact(SAMPLE, { home: '/Users/testuser', username: 'testuser' })
    const twice = redact(once, { home: '/Users/testuser', username: 'testuser' })
    expect(twice).toBe(once)
  })

  it('counts what it removed', () => {
    expect(redactWithCount(SAMPLE).count).toBeGreaterThan(3)
  })

  it('handles empty and whitespace input', () => {
    expect(redact('')).toBe('')
    expect(redact('   ')).toBe('   ')
  })
})

describe('redactValue', () => {
  it('drops values under a secret-looking key whatever their type', () => {
    const out = redactValue({ token: 12345678, apiKey: { nested: true }, theme: 'dark' })
    expect(out.token).toBe(REDACTED)
    expect(out.apiKey).toBe(REDACTED)
    expect(out.theme).toBe('dark')
  })

  it('walks arrays and nested objects', () => {
    const out = redactValue({ items: [{ password: 'hunter2' }, 'ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a'] })
    expect(JSON.stringify(out)).not.toContain('hunter2')
    expect(JSON.stringify(out)).not.toContain('ghp_16C7')
  })

  it('survives a cycle', () => {
    const node: Record<string, unknown> = { name: 'a' }
    node.self = node
    expect(() => redactValue(node)).not.toThrow()
  })

  /**
   * A shared reference is not a cycle. Marking every object ever visited made
   * the second appearance of the same object come back as `[circular]`, which
   * silently deletes half the preferences of anyone whose config reuses one.
   */
  it('keeps a shared reference rather than calling it a cycle', () => {
    const shared = { theme: 'dark' }
    const out = redactValue({ a: shared, b: shared })
    expect(out.a).toEqual({ theme: 'dark' })
    expect(out.b).toEqual({ theme: 'dark' })
  })

  it('keeps a shared array on both branches', () => {
    const shared = [1, 2]
    const out = redactValue({ a: shared, b: shared })
    expect(out.b).toEqual([1, 2])
  })

  it('still marks a genuine cycle', () => {
    const node: Record<string, unknown> = { name: 'a' }
    node.self = node
    expect(JSON.stringify(redactValue(node))).toContain('[circular]')
  })
})

/* ------------------------------------------------------------------ ipc -- */

interface FakeIpc {
  _invokeHandlers: Map<string, unknown>
  handle(channel: string, listener: (...args: unknown[]) => unknown): void
  on(channel: string, listener: (...args: unknown[]) => void): FakeIpc
  eventNames(): string[]
}

function fakeIpc(): FakeIpc {
  const listeners = new Map<string, unknown>()
  const ipc: FakeIpc = {
    _invokeHandlers: new Map(),
    handle(channel, listener) {
      ipc._invokeHandlers.set(channel, listener)
    },
    on(channel, listener) {
      listeners.set(channel, listener)
      return ipc
    },
    eventNames: () => [...listeners.keys()],
  }
  return ipc
}

describe('ipc introspection', () => {
  it('groups channels by module', () => {
    const modules = groupChannels(['git:status', 'git:diff', 'cost:project', 'brand:get'])
    expect(modules.map((m) => m.name)).toEqual(['brand', 'cost', 'git'])
    expect(modules[2].channels).toEqual(['git:diff', 'git:status'])
  })

  it('reads registered channels off ipcMain', () => {
    const ipc = fakeIpc()
    ipc.handle('git:status', () => null)
    ipc.on('session:write', () => {})
    const info = ipcInfo(ipc as unknown as Parameters<typeof ipcInfo>[0])
    expect(info.invokeChannels).toBe(1)
    expect(info.sendChannels).toBe(1)
    expect(info.modules.map((m) => m.name)).toEqual(['git', 'session'])
  })
})

describe('instrumentIpc', () => {
  it('times calls registered before and after instrumentation, and records failures', async () => {
    const ipc = fakeIpc()
    ipc.handle('early:ok', () => 'fine')

    expect(instrumentIpc(ipc as unknown as Parameters<typeof instrumentIpc>[0])).toBe(true)
    // Idempotent — a second call must not double-wrap.
    expect(instrumentIpc(ipc as unknown as Parameters<typeof instrumentIpc>[0])).toBe(true)

    ipc.handle('late:boom', async () => {
      throw new Error(`exploded with ${'ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a'}`)
    })

    clearIpcCalls()
    const early = ipc._invokeHandlers.get('early:ok') as () => unknown
    early()
    const late = ipc._invokeHandlers.get('late:boom') as () => Promise<unknown>
    await expect(late()).rejects.toThrow()

    const calls = recentIpcCalls()
    expect(calls.map((c) => c.channel)).toEqual(['early:ok', 'late:boom'])
    expect(calls[0].ok).toBe(true)
    expect(calls[0].ms).toBeGreaterThanOrEqual(0)
    expect(calls[1].ok).toBe(false)
    // Even an error message goes through redaction on its way to the panel.
    expect(calls[1].error).not.toContain('ghp_16C7')
  })
})

describe('instrumentIpc — what it must not break', () => {
  /**
   * Wrapping `ipcMain.on` replaces the caller's function with a wrapper, so
   * `removeListener(channel, fn)` no longer matches anything and the listener
   * stays attached for the life of the process. Node's own `once()` wrappers
   * solve this by exposing the original as `.listener`, which `removeListener`
   * checks; so does this one now.
   */
  it('leaves a wrapped listener removable by the function the caller passed', async () => {
    // `instrumented` is module state and an earlier test already set it, so a
    // plain call would return early and this would pass without wrapping
    // anything. A fresh instance is the only way to exercise the real path.
    vi.resetModules()
    const fresh = await import('./diagnostics')

    const emitter = new EventEmitter() as unknown as {
      _invokeHandlers: Map<string, unknown>
      handle(channel: string, listener: unknown): void
      on(channel: string, listener: unknown): unknown
      removeListener(channel: string, listener: unknown): unknown
      listenerCount(channel: string): number
    }
    emitter._invokeHandlers = new Map()
    emitter.handle = (channel, listener) => {
      emitter._invokeHandlers.set(channel, listener)
    }

    expect(fresh.instrumentIpc(emitter as unknown as Parameters<typeof instrumentIpc>[0])).toBe(true)

    const listener = (): void => {}
    emitter.on('session:write', listener)
    expect(emitter.listenerCount('session:write')).toBe(1)
    // Proves the wrapper really is in place — otherwise this asserts nothing.
    // `rawListeners`, because `listeners()` unwraps via `.listener`, which is
    // precisely the mechanism under test.
    const raw = (emitter as unknown as { rawListeners(e: string): unknown[] }).rawListeners('session:write')
    expect(raw[0]).not.toBe(listener)
    expect((raw[0] as { listener?: unknown }).listener).toBe(listener)

    emitter.removeListener('session:write', listener)
    expect(emitter.listenerCount('session:write')).toBe(0)
  })
})

describe('debug:subscribe', () => {
  /**
   * Unsubscribing used to drop the entry but leave the `once('destroyed')`
   * handler attached, so each subscribe/unsubscribe cycle added another one to
   * the same WebContents. The Debug panel does exactly that every time debug
   * mode is toggled, and Node starts warning about a leak at eleven.
   */
  it('does not accumulate a destroyed listener per subscribe/unsubscribe cycle', () => {
    const ipc = fakeIpc()
    registerDiagnosticsIpc(ipc as unknown as Parameters<typeof registerDiagnosticsIpc>[0])

    const contents = new EventEmitter() as unknown as {
      isDestroyed(): boolean
      send(channel: string, payload: unknown): void
      listenerCount(event: string): number
    }
    contents.isDestroyed = () => false
    contents.send = () => {}

    const subscribe = ipc._invokeHandlers.get('debug:subscribe') as (event: unknown) => unknown
    const unsubscribe = ipc._invokeHandlers.get('debug:unsubscribe') as (event: unknown) => unknown

    for (let i = 0; i < 20; i += 1) {
      subscribe({ sender: contents })
      unsubscribe({ sender: contents })
    }

    expect(contents.listenerCount('destroyed')).toBe(0)
  })
})

describe('debug:diagnostics — what the renderer is allowed to ask for', () => {
  function handlers() {
    const ipc = fakeIpc()
    registerDiagnosticsIpc(ipc as unknown as Parameters<typeof registerDiagnosticsIpc>[0])
    return ipc._invokeHandlers
  }

  /**
   * The bundle passed `logLines` straight through to `tail`, where `slice(-n)`
   * treats 0 and NaN as "everything". Asking for no log lines returned the whole
   * log, across every rotated generation, in the artefact specifically written
   * to be pasted somewhere public.
   */
  it('clamps a log-line count instead of passing it through', async () => {
    const log = createAppLog({ dir: join(ROOT, 'clamp') })
    setAppLog(log)
    for (let i = 0; i < 400; i += 1) log.info('bulk', `line ${i}`)

    const collect = handlers().get('debug:diagnostics') as (
      event: unknown,
      options: unknown,
    ) => Promise<{ log: { lines: string[] } }>

    for (const logLines of [0, -5, Number.NaN]) {
      const bundle = await collect({}, { includeClis: false, logLines })
      expect(bundle.log.lines.length, `logLines=${logLines}`).toBeLessThanOrEqual(400)
      expect(bundle.log.lines.length, `logLines=${logLines}`).toBeGreaterThan(0)
    }

    expect((await collect({}, { includeClis: false, logLines: 7 })).log.lines).toHaveLength(7)
    // No opinion means the default, not the smallest legal value.
    expect((await collect({}, { includeClis: false })).log.lines).toHaveLength(200)
    expect((await collect({}, { includeClis: false, logLines: null })).log.lines).toHaveLength(200)
    expect((await collect({}, 'nonsense')).log.lines.length).toBeGreaterThan(0)
    // Not a race, and not a guess: this case writes 400 log lines and then
    // builds seven whole bundles, each of which redacts every line it returns.
    // That is a little over four seconds of straight-line work on a developer
    // machine — measured, with a scrubbed environment, so it is the redaction
    // and not somebody's env. Against vitest's 5s default it passed only while
    // nothing else was running, and failed every time the suite was under load.
    // The number below is headroom for a CPU-bound case, not a widened wait for
    // something that might not have happened yet.
  }, 20_000)

  /**
   * The handler used to spread the raw argument into `CollectOptions`, so the
   * caller could set `redaction` — the one thing that makes a bundle safe to
   * paste — or replace `ipcMain`.
   */
  it('ignores redaction options supplied by the caller', async () => {
    const log = createAppLog({ dir: join(ROOT, 'hostile') })
    setAppLog(log)
    log.warn('mcp', `GITHUB_TOKEN=${'ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a'}`)

    const collect = handlers().get('debug:diagnostics') as (
      event: unknown,
      options: unknown,
    ) => Promise<unknown>

    const bundle = await collect(
      {},
      { includeClis: false, redaction: { extraSecrets: [] }, ipcMain: { evil: true } },
    )
    expect(JSON.stringify(bundle)).not.toContain('ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a')
  })
})

/* --------------------------------------------------------------- bundle -- */

describe('collectDiagnostics', () => {
  const REDACTION = { home: '/Users/testuser', username: 'testuser' }

  it('redacts the log tail it carries', async () => {
    const log = createAppLog({ dir: join(ROOT, 'logs') })
    setAppLog(log)
    log.error('net', 'request failed', { authorization: 'Bearer sk-ant-api03-ZzZzKmQnR3tVzWyXsAbCdEfGh' })
    log.info('fs', 'read /Users/testuser/Projects/terminaldeck/src/main/index.ts')

    const bundle = await collectDiagnostics({ includeClis: false, redaction: REDACTION })
    const serialised = JSON.stringify(bundle)

    expect(serialised).not.toContain('sk-ant-api03-ZzZzKm' + 'QnR3tVzWyXsAbCdEfGh')
    expect(serialised).not.toContain('/Users/testuser')
    expect(bundle.log.lines.length).toBe(2)
    expect(bundle.redaction.count).toBeGreaterThan(0)
  })

  it('reports environment secrets by name only, and splits PATH', async () => {
    const bundle = await collectDiagnostics({ includeClis: false, redaction: REDACTION })
    expect(bundle.environment.path).toContain('/opt/homebrew/bin')
    // The mocked login PATH carries a home directory; it must arrive folded.
    expect(bundle.environment.path.join(delimiter)).not.toContain('/Users/testuser')
    for (const name of bundle.environment.secretsPresent) {
      expect(typeof name).toBe('string')
      expect(bundle.environment.secretsPresent.join()).not.toContain('=')
    }
  })

  it('includes version and path information', async () => {
    const bundle = await collectDiagnostics({ includeClis: false })
    expect(bundle.app.version).toBe('9.9.9')
    expect(bundle.app.electron.length).toBeGreaterThan(0)
    expect(bundle.app.node).toBe(process.versions.node)
    expect(bundle.paths.userData.length).toBeGreaterThan(0)
    expect(bundle.system.memoryTotalMb).toBeGreaterThan(0)
  })

  it('formats a bundle that leaks nothing', async () => {
    const log = createAppLog({ dir: join(ROOT, 'logs2') })
    setAppLog(log)
    log.warn('mcp', `token=${'ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a'}`)

    const text = formatDiagnostics(await collectDiagnostics({ includeClis: false, redaction: REDACTION }))
    expect(text).not.toContain('ghp_16' + 'C7e42F2' + '92c6912' + 'E7710c' + '838347A' + 'e178B4a')
    expect(text).toContain(`# ${BRAND.name} diagnostics`)
    expect(text).toContain('## Paths')
    expect(text).toContain('## Log')
  })
})

/* --------------------------------------------------------- environment -- */

/**
 * The environment section is the part of the bundle a user is asked to paste
 * when the app cannot find their CLI, so it is the part that has to survive
 * being read on Windows — and it did not.
 *
 * Both cases are pinned against a Windows-shaped input rather than against the
 * host, because the host here is always a Mac and both bugs are invisible from
 * one.
 */
describe('the PATH the bundle prints', () => {
  // What a real Windows PATH looks like: `;` between entries, `:` inside every
  // single one of them.
  const WINDOWS_PATH = 'C:\\Program Files\\nodejs;C:\\Windows\\system32;C:\\Users\\Asad\\AppData\\Roaming\\npm'

  it('splits a Windows PATH into directories, not fragments', () => {
    expect(pathEntries(WINDOWS_PATH, win32.delimiter)).toEqual([
      'C:\\Program Files\\nodejs',
      'C:\\Windows\\system32',
      'C:\\Users\\Asad\\AppData\\Roaming\\npm',
    ])
  })

  it('never leaves a bare drive letter standing in for a directory', () => {
    // The old `split(':')` produced `['C', '\\Program Files\\nodejs;C', …]`.
    // Stated as a property: every entry has to still look like a path.
    for (const entry of pathEntries(WINDOWS_PATH, win32.delimiter)) {
      expect(entry, entry).not.toBe('C')
      expect(entry, entry).not.toContain(win32.delimiter)
    }
  })

  it('still splits a POSIX PATH the POSIX way', () => {
    expect(pathEntries('/opt/homebrew/bin:/usr/bin', posix.delimiter)).toEqual([
      '/opt/homebrew/bin',
      '/usr/bin',
    ])
  })

  it('drops the empty entry a trailing separator leaves behind', () => {
    expect(pathEntries('/usr/bin:', posix.delimiter)).toEqual(['/usr/bin'])
  })
})

describe('the shell the bundle names', () => {
  it('reports the login shell on a platform that has one', () => {
    expect(shellName({ SHELL: '/bin/zsh' }, 'darwin')).toBe('/bin/zsh')
  })

  it('says something true on Windows instead of nothing at all', () => {
    // `process.env.SHELL` is unset on Windows, so this line used to print
    // `- shell: ` and send the reader looking for a setting that does not exist.
    const line = shellName({ COMSPEC: 'C:\\WINDOWS\\system32\\cmd.exe' }, 'win32')
    expect(line).toContain('C:\\WINDOWS\\system32\\cmd.exe')
    expect(line).toContain('no login shell')
    expect(line).not.toBe('')
  })

  it('names the command processor even when COMSPEC is missing', () => {
    // A Windows install without COMSPEC is not a thing, but an empty line here
    // is the failure being fixed, so there is no case that returns one.
    const line = shellName({}, 'win32')
    expect(line).toContain('cmd.exe')
    expect(line).not.toBe('')
  })

  it('does not invent a shell for a POSIX environment that has none', () => {
    expect(shellName({}, 'darwin')).toBe('')
  })
})

describe('formatLine', () => {
  it('keeps a log entry on one line', () => {
    const line = formatLine({ at: 0, level: 'info', scope: 'git', message: 'a\nb' })
    expect(line).not.toContain('\n')
    expect(line).toContain('[git]')
    expect(line).toContain('INFO')
  })
})
