import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync, appendFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { recordsFenceAgrees, recordsFencePaths } from '../confine/records'
import { ActionLog } from '../deck-control/action-log'
import { ConsentBroker } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import { advertisedCatalogue } from '../deck-control/describe-tool'
import { LOCAL_CALLER, ALL_TIERS, type DeckSurface } from '../deck-control/surface'
import { STORE_MANIFEST_FILE } from '../../shared/store-manifest'
import { PLUGIN_DATA_DIR, PLUGIN_GRANTS_FILE, PLUGINS_DIR } from '../../shared/plugins'
import { looksSecret } from './env'
import { PluginHost, type PluginConsent, type PluginConsentRequest, type PluginHostOptions } from './host'
import { ERROR_CODES } from './process'
import { pluginTools } from './tools'

/**
 * The plugin host, end to end, against a fake plugin: a small Node script
 * written into a temporary folder, speaking the real protocol over the real
 * pipes, under the real host. The question is a fake consent function — the
 * native dialog is the one piece not exercised here, and nothing here reaches
 * the person's real `<userData>`.
 */

/** The fake plugin. One file; `MODE` is baked into its text, so it is part of the code that gets hashed. */
function fakeMain(mode: 'normal' | 'silent' = 'normal'): string {
  return `
const MODE = ${JSON.stringify(mode)}
const fs = require('fs')
let buffer = ''
let next = 1000
const waiting = new Map()
const send = (message) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\\n')
const ask = (method, params) => new Promise((resolve) => {
  const id = next++
  waiting.set(id, resolve)
  send({ id, method, params })
})
async function handle(message) {
  if (message.method === undefined) {
    const resolve = waiting.get(message.id)
    waiting.delete(message.id)
    if (resolve) resolve(message.error ? { error: message.error } : { result: message.result })
    return
  }
  if (message.method === 'shutdown') process.exit(0)
  if (message.method === 'initialize') {
    if (MODE === 'silent') return
    send({ id: message.id, result: { protocol: 1 } })
    return
  }
  if (message.method !== 'tools/call') return
  const { name, arguments: args } = message.params
  if (name === 'echo') return send({ id: message.id, result: { echoed: args.text } })
  if (name === 'env') return send({ id: message.id, result: { env: process.env, cwd: process.cwd() } })
  if (name === 'ask') return send({ id: message.id, result: await ask(args.method, args.params) })
  if (name === 'hang') return
  if (name === 'big') {
    process.stdout.write('{"jsonrpc":"2.0","id":' + message.id + ',"result":"' + 'x'.repeat(args.bytes) + '"}\\n')
    return
  }
  if (name === 'read') {
    try {
      return send({ id: message.id, result: { text: fs.readFileSync(args.path, 'utf8') } })
    } catch (error) {
      return send({ id: message.id, result: { error: error.code } })
    }
  }
}
process.stdin.on('data', (chunk) => {
  buffer += chunk.toString('utf8')
  let newline
  while ((newline = buffer.indexOf('\\n')) !== -1) {
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    if (line.trim() !== '') void handle(JSON.parse(line))
  }
})
process.stdin.on('end', () => process.exit(0))
`
}

const OBJ = { type: 'object', properties: {} }

function fakeManifest(id = 'fake'): Record<string, unknown> {
  const tool = (name: string, properties: Record<string, unknown> = {}): Record<string, unknown> => ({
    name,
    title: `Fake ${name}`,
    description: `The fake plugin's ${name}.`,
    tier: 'read',
    inputSchema: { type: 'object', properties },
  })
  return {
    terminaldeck: 1,
    id,
    name: 'Fake',
    summary: 'A plugin that exists for the tests.',
    version: '1.0.0',
    plugin: {
      main: 'main.js',
      runtime: 'node',
      // goals.read is deliberately not here: asking for it is the undeclared case.
      capabilities: ['tasks.read', 'knowledge.read', 'notify', 'tools.contribute'],
      tools: [
        tool('echo', { text: { type: 'string' } }),
        tool('env'),
        tool('ask', { method: { type: 'string' }, params: OBJ }),
        tool('hang'),
        tool('big', { bytes: { type: 'integer' } }),
        tool('read', { path: { type: 'string' } }),
      ],
    },
  }
}

let root = ''
let userData = ''
let project = ''
let hosts: PluginHost[] = []
let asked: PluginConsentRequest[] = []
let answer: 'yes' | 'no' = 'yes'

const consent: PluginConsent = async (request) => {
  asked.push(request)
  return answer === 'yes' ? { granted: true, at: Date.now() } : { granted: false, reason: 'declined', at: Date.now() }
}

/** The platform the plain-host tests run as: no sandbox, so they behave the same on every CI runner. */
const PLAIN = process.platform === 'win32' ? 'win32' : 'linux'

function placePlugin(id = 'fake', mode: 'normal' | 'silent' = 'normal'): string {
  const folder = join(userData, PLUGINS_DIR, id)
  mkdirSync(folder, { recursive: true })
  writeFileSync(join(folder, STORE_MANIFEST_FILE), JSON.stringify(fakeManifest(id)))
  writeFileSync(join(folder, 'main.js'), fakeMain(mode))
  return folder
}

function host(over: Partial<PluginHostOptions> = {}): PluginHost {
  const made = new PluginHost({
    userData,
    consent,
    platform: PLAIN,
    runtime: process.execPath,
    handshakeTimeoutMs: 8_000,
    services: {
      projects: () => [project],
      tasks: () => [{ id: 't1', title: 'Write the tests', project, status: 'open', updatedAt: 1 }],
      notify: () => true,
    },
    ...over,
  })
  hosts.push(made)
  return made
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function until(check: () => boolean, ms = 5_000): Promise<void> {
  const end = Date.now() + ms
  while (!check()) {
    if (Date.now() > end) throw new Error('timed out waiting')
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
}

const ALL = ['tasks.read', 'notify', 'tools.contribute'] as const

beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'td-plugins-')))
  userData = join(root, 'userData')
  project = join(root, 'project')
  mkdirSync(userData, { recursive: true })
  mkdirSync(project, { recursive: true })
  asked = []
  answer = 'yes'
  hosts = []
})

afterEach(async () => {
  await Promise.all(hosts.map((one) => one.stopAll()))
  rmSync(root, { recursive: true, force: true })
})

describe('a plugin folder', () => {
  it('does nothing until it is allowed: listed, not started, nobody asked', async () => {
    placePlugin()
    const plugins = host()
    await plugins.startAll()
    const view = plugins.state().plugins[0]
    expect(view.state).toBe('needs-ok')
    expect(view.declared).toEqual(['tasks.read', 'knowledge.read', 'notify', 'tools.contribute'])
    expect(view.granted).toEqual([])
    expect(plugins.pidOf('fake')).toBeNull()
    expect(asked).toHaveLength(0)
    expect(pluginTools(plugins)).toEqual([])
  })

  it('is allowed only through the question, and a no allows nothing', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    answer = 'no'
    const refused = await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    expect(refused.ok).toBe(false)
    expect(refused.message).toContain('You said no')
    expect(refused.state.plugins[0].state).toBe('needs-ok')
    expect(existsSync(join(userData, PLUGIN_GRANTS_FILE))).toBe(false)

    answer = 'yes'
    const granted = await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    expect(granted.ok).toBe(true)
    expect(asked).toHaveLength(2)
    expect(asked[1].capabilities).toEqual([...ALL])
    expect(asked[1].hash).toMatch(/^[0-9a-f]{64}$/)
    expect(asked[1].detail).toContain('Give Hoot new tools')
    const view = granted.state.plugins[0]
    expect(view.state).toBe('running')
    expect(view.granted).toEqual([...ALL])
  })

  it('handshakes: started, it answers initialize with the protocol', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const pid = plugins.pidOf('fake')
    expect(pid).not.toBeNull()
    expect(alive(pid as number)).toBe(true)
    expect(await plugins.callTool('fake', 'echo', { text: 'hello' })).toEqual({ echoed: 'hello' })
  })

  it('is stopped when it never finishes the handshake', async () => {
    placePlugin('fake', 'silent')
    const plugins = host({ handshakeTimeoutMs: 500 })
    plugins.scan()
    const result = await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const view = result.state.plugins[0]
    expect(view.state).toBe('stopped')
    expect(view.note).toContain('did not answer initialize')
    expect(plugins.pidOf('fake')).toBeNull()
  })
})

describe('what a plugin may ask for', () => {
  async function running(capabilities: string[], projects: string[] = []): Promise<PluginHost> {
    placePlugin()
    const plugins = host()
    plugins.scan()
    const result = await plugins.allow('fake', { capabilities: capabilities as never, projects })
    expect(result.ok, result.message).toBe(true)
    return plugins
  }
  const ask = (plugins: PluginHost, method: string, params: Record<string, unknown> = {}): Promise<unknown> =>
    plugins.callTool('fake', 'ask', { method, params })

  it('refuses a capability its manifest never declared, whatever it was allowed', async () => {
    const plugins = await running([...ALL])
    expect(await ask(plugins, 'goals.list')).toEqual({
      error: { code: ERROR_CODES.notDeclared, message: expect.stringContaining('does not ask for') },
    })
  })

  it('refuses a declared capability the person did not allow', async () => {
    const plugins = await running(['tools.contribute'])
    expect(await ask(plugins, 'tasks.list')).toEqual({
      error: { code: ERROR_CODES.notGranted, message: expect.stringContaining('has not allowed') },
    })
    expect(await ask(plugins, 'notify', { title: 'hi' })).toMatchObject({ error: { code: ERROR_CODES.notGranted } })
  })

  it('answers a granted one', async () => {
    const plugins = await running([...ALL])
    expect(await ask(plugins, 'tasks.list')).toEqual({
      result: { tasks: [{ id: 't1', title: 'Write the tests', project, status: 'open', updatedAt: 1 }] },
    })
  })

  it('refuses a method that does not exist', async () => {
    const plugins = await running([...ALL])
    expect(await ask(plugins, 'shell.run', { command: 'id' })).toMatchObject({ error: { code: ERROR_CODES.unknownMethod } })
  })

  it('holds project-scoped reading to the projects chosen, and says so when this build has none', async () => {
    const other = join(root, 'other')
    mkdirSync(other)
    const plugins = await running(['knowledge.read', 'tools.contribute'], [project])
    expect(await ask(plugins, 'knowledge.search', { project: other, query: 'x' })).toMatchObject({
      error: { code: ERROR_CODES.notGranted },
    })
    expect(await ask(plugins, 'knowledge.search', { project, query: 'x' })).toMatchObject({
      error: { code: ERROR_CODES.unavailable },
    })
  })

  it('asks again to widen, and not to narrow', async () => {
    const plugins = await running(['tools.contribute'])
    expect(asked).toHaveLength(1)
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    expect(asked).toHaveLength(2)
    await plugins.allow('fake', { capabilities: ['tools.contribute'], projects: [] })
    expect(asked).toHaveLength(2)
    // Taken away, it is refused on the very next request — no restart.
    expect(await ask(plugins, 'tasks.list')).toMatchObject({ error: { code: ERROR_CODES.notGranted } })
  })
})

describe('the grant is for the code', () => {
  it('is lost when the plugin’s files change, and the changed code is stopped', async () => {
    const folder = placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const pid = plugins.pidOf('fake') as number
    expect(pid).not.toBeNull()

    appendFileSync(join(folder, 'main.js'), '\n// one more line\n')
    const view = plugins.state().plugins[0]
    expect(view.state).toBe('changed')
    expect(view.allowed).toBe(false)
    expect(view.granted).toEqual([])
    await until(() => !alive(pid))
    expect(pluginTools(plugins)).toEqual([])
    await expect(plugins.callTool('fake', 'echo', { text: 'x' })).rejects.toThrow('not allowed')
    expect((await plugins.setEnabled('fake', true)).message).toContain('Allow it first')

    // A new host — a relaunch — does not start it either.
    const relaunched = host()
    await relaunched.startAll()
    expect(relaunched.pidOf('fake')).toBeNull()

    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    expect(asked).toHaveLength(2)
    expect(asked[1].hash).not.toBe(asked[0].hash)
  })

  it('ignores the .DS_Store a Finder window leaves behind', async () => {
    const folder = placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    writeFileSync(join(folder, '.DS_Store'), 'finder')
    expect(plugins.state().plugins[0].state).toBe('running')
  })
})

describe('the bounds', () => {
  it('stops a plugin that does not answer in time', async () => {
    placePlugin()
    const plugins = host({ requestTimeoutMs: 600 })
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const pid = plugins.pidOf('fake') as number
    await expect(plugins.callTool('fake', 'hang', {})).rejects.toThrow('did not answer tools/call')
    await until(() => !alive(pid))
    const view = plugins.state().plugins[0]
    expect(view.state).toBe('stopped')
    expect(view.note).toContain('did not answer tools/call')
    // The next call starts it again, from nothing.
    expect(await plugins.callTool('fake', 'echo', { text: 'back' })).toEqual({ echoed: 'back' })
    expect(plugins.pidOf('fake')).not.toBe(pid)
  })

  it('refuses a message larger than the limit, and stops the plugin that sent it', async () => {
    placePlugin()
    const plugins = host({ maxMessageBytes: 4096 })
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const pid = plugins.pidOf('fake') as number
    await expect(plugins.callTool('fake', 'big', { bytes: 20_000 })).rejects.toThrow('larger than 4096 bytes')
    await until(() => !alive(pid))
    expect(plugins.state().plugins[0].note).toContain('larger than 4096 bytes')
  })

  it('starts it with an environment that carries none of this app’s secrets', async () => {
    const secrets: Record<string, string> = {
      ANTHROPIC_API_KEY: 'sk-ant-test-secret',
      OPENAI_API_KEY: 'sk-openai-test-secret',
      GITHUB_TOKEN: 'ghp_testsecret',
      GH_TOKEN: 'gho_testsecret',
      TERMINALDECK_RELAY_TOKEN: 'td-test-secret',
      CLAUDE_CONFIG_DIR: '/Users/someone/.claude-profile',
      AWS_SECRET_ACCESS_KEY: 'aws-test-secret',
      NODE_OPTIONS: '--require /tmp/evil.js',
    }
    const before = { ...process.env }
    Object.assign(process.env, secrets)
    try {
      const folder = placePlugin()
      const plugins = host({ parentEnv: process.env })
      plugins.scan()
      await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
      const reported = (await plugins.callTool('fake', 'env', {})) as { env: Record<string, string>; cwd: string }
      const names = Object.keys(reported.env)
      expect(names.filter((name) => looksSecret(name))).toEqual([])
      for (const name of Object.keys(secrets)) expect(names).not.toContain(name)
      for (const value of Object.values(secrets)) expect(Object.values(reported.env)).not.toContain(value)
      // Nothing beyond the short list it is composed from.
      const allowed = ['HOME', 'TMPDIR', 'PATH', 'ELECTRON_RUN_AS_NODE', 'LANG', 'LC_ALL', 'LC_CTYPE', 'SystemRoot', 'USERPROFILE', 'TEMP', 'TMP']
      // macOS adds a few of its own to every process it starts.
      const fromTheSystem = (name: string): boolean => name.startsWith('__CF') || name === 'COMMAND_MODE'
      expect(names.filter((name) => !allowed.includes(name) && !fromTheSystem(name))).toEqual([])
      expect(realpathSync(reported.cwd)).toBe(realpathSync(folder))
      expect(reported.env.HOME).toBe(realpathSync(join(userData, PLUGIN_DATA_DIR, 'fake')))
    } finally {
      for (const name of Object.keys(secrets)) {
        if (before[name] === undefined) delete process.env[name]
        else process.env[name] = before[name]
      }
    }
  })
})

describe('on and off', () => {
  it('never starts a plugin that is turned off — not now, not after a relaunch, not for a tool call', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const pid = plugins.pidOf('fake') as number
    const off = await plugins.setEnabled('fake', false)
    expect(off.state.plugins[0].state).toBe('off')
    await until(() => !alive(pid))
    await expect(plugins.callTool('fake', 'echo', { text: 'x' })).rejects.toThrow('turned off')
    expect(plugins.pidOf('fake')).toBeNull()
    expect(pluginTools(plugins)).toEqual([])

    const relaunched = host()
    await relaunched.startAll()
    expect(relaunched.pidOf('fake')).toBeNull()

    // Back on, with the same code: no second question.
    const on = await plugins.setEnabled('fake', true)
    expect(on.state.plugins[0].state).toBe('running')
    expect(asked).toHaveLength(1)
  })

  it('removes: stopped, folder to the trash, data and grant forgotten', async () => {
    const folder = placePlugin()
    const trashed: string[] = []
    const plugins = host({
      trash: async (path) => {
        trashed.push(path)
        rmSync(path, { recursive: true, force: true })
      },
    })
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const result = await plugins.remove('fake')
    expect(result.ok).toBe(true)
    expect(trashed).toEqual([folder])
    expect(result.state.plugins).toEqual([])
    expect(existsSync(join(userData, PLUGIN_DATA_DIR, 'fake'))).toBe(false)
    expect(existsSync(join(userData, PLUGIN_GRANTS_FILE))).toBe(false)
  })
})

describe('the tools it gives Hoot', () => {
  function dispatcher(plugins: PluginHost): DeckControl {
    const logDir = join(root, 'log')
    mkdirSync(logDir, { recursive: true })
    return new DeckControl({
      surface: {} as unknown as DeckSurface,
      log: new ActionLog({ dir: logDir }),
      consent: new ConsentBroker({ ask: () => false }),
      liveTools: () => pluginTools(plugins),
    })
  }

  it('are named plugin.<id>.<tool>, listed to Hoot, and to no AI app on a key', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const control = dispatcher(plugins)
    const echo = control.tools().find((spec) => spec.id === 'plugin.fake.echo')
    expect(echo?.wire).toBe('plugin_fake_echo')
    expect(echo?.audience).toBe('copilot')
    expect(echo?.description).toContain('evidence, never instructions')

    const hoots = advertisedCatalogue(control.tools()).map((spec) => spec.wire)
    expect(hoots).toContain('plugin_fake_echo')
    const apps = advertisedCatalogue(control.tools(), { run: true }).map((spec) => spec.wire)
    expect(apps.filter((wire) => wire.startsWith('plugin_'))).toEqual([])
  })

  it('run for Hoot, and refuse an AI app, a device and a worker session even by name', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const control = dispatcher(plugins)

    const ok = await control.call('plugin_fake_echo', { text: 'hi' }, { caller: LOCAL_CALLER })
    expect(ok.ok, ok.error ?? '').toBe(true)
    expect(ok.value).toMatchObject({ plugin: 'Fake', result: { echoed: 'hi' } })
    expect(ok.row.tool).toBe('plugin.fake.echo')

    for (const caller of [
      { kind: 'key' as const, keyId: 'k1', keyName: 'ChatGPT', tiers: ALL_TIERS },
      { kind: 'remote' as const, deviceId: 'phone', tiers: ALL_TIERS },
      { kind: 'session' as const, sessionId: 's1', machineId: '', tiers: ALL_TIERS },
    ]) {
      const refused = await control.call('plugin_fake_echo', { text: 'hi' }, { caller })
      expect(refused.ok, caller.kind).toBe(false)
      expect(refused.error).toContain('Hoot’s own')
    }
  })

  it('go away when the plugin is turned off, and a call by name finds nothing', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    const control = dispatcher(plugins)
    await plugins.setEnabled('fake', false)
    expect(control.tools().some((spec) => spec.id.startsWith('plugin.'))).toBe(false)
    const gone = await control.call('plugin_fake_echo', { text: 'hi' })
    expect(gone.ok).toBe(false)
  })

  it('are not offered without tools.contribute', async () => {
    placePlugin()
    const plugins = host()
    plugins.scan()
    await plugins.allow('fake', { capabilities: ['tasks.read'], projects: [] })
    expect(pluginTools(plugins)).toEqual([])
    await expect(plugins.callTool('fake', 'echo', { text: 'x' })).rejects.toThrow('not allowed to give tools')
  })
})

describe.runIf(process.platform === 'darwin')('the sandbox on a Mac', () => {
  it('lets a plugin read its own folder and nothing of yours, and write only its data folder', async () => {
    const folder = placePlugin()
    const canary = join(root, 'outside.txt')
    writeFileSync(canary, 'the person’s own file')
    // Readable from outside, so a refusal inside is the sandbox and not a missing file.
    expect(readFileSync(canary, 'utf8')).toContain('own file')
    const plugins = host({ platform: 'darwin' })
    plugins.scan()
    const result = await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    expect(result.state.plugins[0].state, result.state.plugins[0].note).toBe('running')
    expect(asked[0].confined).toBe(true)
    expect(await plugins.callTool('fake', 'read', { path: canary })).toEqual({ error: 'EPERM' })
    const own = (await plugins.callTool('fake', 'read', { path: join(folder, 'main.js') })) as { text?: string }
    expect(own.text).toContain('MODE')
  })
})

describe('the grants file', () => {
  it('is the file the records fence keeps Hoot from writing', () => {
    expect(
      recordsFenceAgrees(recordsFencePaths(userData), {
        routines: join(userData, 'routines'),
        routineState: join(userData, 'routine-state.json'),
        log: join(userData, 'copilot-log'),
        pluginGrants: join(userData, PLUGIN_GRANTS_FILE),
      }),
    ).toBe(true)
  })
})

describe('it never reaches for anything it was not given', () => {
  it('spawns with no shell, from the plugin folder', async () => {
    placePlugin()
    const seen: { command: string; args: readonly string[]; shell: unknown; cwd: unknown }[] = []
    const { spawn } = await import('node:child_process')
    const plugins = host({
      spawner: vi.fn((command, args, options) => {
        seen.push({ command, args, shell: options.shell, cwd: options.cwd })
        return spawn(command, [...args], options)
      }),
    })
    plugins.scan()
    await plugins.allow('fake', { capabilities: [...ALL], projects: [] })
    expect(seen).toHaveLength(1)
    expect(seen[0].shell).toBe(false)
    expect(seen[0].command).toBe(process.execPath)
    expect(seen[0].args).toEqual([join(realpathSync(join(userData, PLUGINS_DIR, 'fake')), 'main.js')])
  })
})
