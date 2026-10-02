import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import type { ToolContext, ToolSpec } from './catalogue'
import type { ChannelCall } from './channel-tap'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { MAX_SHELL_CHARS, serverRoomTools, type ServerChannels } from './server-room-tools'
import { ALL_TIERS, Refused, type Caller, type DeckSurface } from './surface'

const LOCAL: Caller = { kind: 'local', tiers: ALL_TIERS }
const PHONE: Caller = { kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS }
const PRIVATE_KEY = '-----BEGIN OPENSSH PRIVATE KEY-----\nTHE-ACTUAL-KEY-MATERIAL\n-----END OPENSSH PRIVATE KEY-----\n'

let userData = ''
let calls: unknown[][] = []
let answers: Partial<Record<keyof ServerChannels, (...args: unknown[]) => unknown>> = {}
let shells: Array<{ shellId: string; serverId: string; openedAt: number | null }> = []
let tools: ToolSpec[] = []

const tool = (id: string): ToolSpec => {
  const found = tools.find((spec) => spec.id === id)
  if (!found) throw new Error(`no tool ${id}`)
  return found
}

const context = (caller: Caller = LOCAL): ToolContext =>
  ({
    surface: {} as DeckSurface,
    callId: 'row',
    caller,
    attended: true,
    startedByCopilot: () => false,
    noteStarted: () => undefined,
    now: () => 0,
  }) as ToolContext

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'server-room-'))
  calls = []
  shells = [{ shellId: 's1 abc', serverId: 's1', openedAt: 1 }]
  answers = {
    'servers:list': () => [{ id: 's1', name: 'web-1', address: '10.0.0.5' }],
    'servers:keys': () => [{ path: '/home/me/.ssh/id_ed25519', name: 'id_ed25519', what: 'A key made by OpenSSH', locked: false }],
    'servers:key-read': () => ({ ok: true, key: PRIVATE_KEY }),
    'servers:add': () => ({ ok: true, id: 's2', savedSignIn: true, note: '' }),
    'servers:shell:write': () => ({ written: true }),
    'servers:shell:open': () => ({ ok: true, shellId: 's1 fresh' }),
    'servers:shell:close': () => ({ closed: true }),
  }
  const call = (async (channel: keyof ServerChannels, ...args: unknown[]) => {
    calls.push([channel, ...args])
    const answer = answers[channel]
    if (answer === undefined) throw new Error(`the test did not expect ${channel}`)
    return answer(...args)
  }) as ChannelCall<ServerChannels>
  tools = serverRoomTools({
    call,
    openShells: () => shells,
    shellScreen: async (shellId) => (shellId === 's1 abc' ? 'me@web-1:~$ ' : null),
    userData: () => userData,
  })
})

afterEach(() => rmSync(userData, { recursive: true, force: true }))

describe('the terminal', () => {
  it('is alter, declares no way to lower it, and never reads a grant', () => {
    /*
     * §6.2: *"A grant covers the `act` tier only. It never covers zone three: not
     * the terminal."* No escalation hook means nothing can move it, and the
     * source not mentioning grants at all means a later edit cannot quietly
     * start consulting one.
     */
    const shell = tool('servers.shell')
    expect(shell.tier).toBe('alter')
    expect(shell.escalate).toBeUndefined()
    const source = readFileSync(join(__dirname, 'server-room-tools.ts'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    expect(source).not.toMatch(/ServerGrants|grants\.granted|\.granted\(/)
  })

  it('says plainly what it is, in the words a model reads first', () => {
    const shell = tool('servers.shell')
    expect(shell.description).toMatch(/full power/)
    expect(shell.description).toMatch(/cannot be undone/)
    expect(shell.description).toMatch(/asks the person first/)
  })

  it('shows the whole line in the dialog, because anything too long to show is refused first', () => {
    const shell = tool('servers.shell')
    const line = 'sudo systemctl restart nginx && journalctl -u nginx -n 50'
    expect(shell.summary({ do: 'type', shellId: 's1 abc', text: line }, context())).toContain(line)
    expect(() => shell.precheck?.({ do: 'type', shellId: 's1 abc', text: 'x'.repeat(MAX_SHELL_CHARS + 1) }, context())).toThrow(
      /person can read all of it/,
    )
  })

  it('takes one line per call — a newline would be a second command nobody approved', () => {
    expect(() => tool('servers.shell').precheck?.({ do: 'type', shellId: 's1 abc', text: 'ls\nrm -rf /' }, context())).toThrow(/printable/)
  })

  it('refuses a paired device, and a terminal that is not open', () => {
    expect(() => tool('servers.shell').precheck?.({ do: 'type', shellId: 's1 abc', text: 'ls' }, context(PHONE))).toThrow(Refused)
    expect(() => tool('servers.shell').precheck?.({ do: 'type', shellId: 'nope', text: 'ls' }, context())).toThrow(/No terminal nope/)
  })

  it('types the line and presses return', async () => {
    await tool('servers.shell').run({ do: 'type', shellId: 's1 abc', text: 'uptime' }, context())
    expect(calls.filter((call) => call[0] === 'servers:shell:write')).toEqual([
      ['servers:shell:write', 's1 abc', 'uptime'],
      ['servers:shell:write', 's1 abc', '\r'],
    ])
  })

  it('is the only tool in this file that takes free text a server would run', () => {
    // The same structural check `no-run-tool.test.ts` applies to the named tools.
    const banned = /^(command|cmd|argv|args|script|shell|exec|run|sudo|code|eval|sql|query|text)$/i
    for (const spec of tools.filter((one) => one.id !== 'servers.shell')) {
      const properties = (spec.inputSchema as { properties?: Record<string, unknown> }).properties ?? {}
      for (const name of Object.keys(properties)) expect(banned.test(name), `${spec.id} takes ${name}`).toBe(false)
    }
  })
})

describe('reading a server', () => {
  it('lists key files by name and never their contents', async () => {
    const out = await tool('servers.details').run({ about: 'keys' }, context())
    expect(JSON.stringify(out)).not.toContain('KEY-MATERIAL')
    expect((out.value as { keys: unknown[] }).keys).toEqual([
      { path: '/home/me/.ssh/id_ed25519', name: 'id_ed25519', what: 'A key made by OpenSSH', needsPassphrase: false },
    ])
  })

  it('reads a terminal’s screen off the shadow terminal the shell already has', async () => {
    answers['servers:controls:read'] = () => null
    answers['servers:shell:account'] = () => ({ known: 'yes', agents: 0, logins: [] })
    const out = await tool('servers.details').run({ about: 'shell', shellId: 's1 abc' }, context())
    expect((out.value as { screen: string }).screen).toBe('me@web-1:~$ ')
  })
})

describe('adding a server', () => {
  it('reads the key in place and never hands it back', async () => {
    const out = await tool('servers.manage').run(
      { do: 'add', address: '10.0.0.6', username: 'deploy', keyPath: '/home/me/.ssh/id_ed25519' },
      context(),
    )
    expect(JSON.stringify(out)).not.toContain('KEY-MATERIAL')
    const added = calls.find((row) => row[0] === 'servers:add')?.[1] as { method: string; key: string }
    expect(added.method).toBe('key')
    expect(added.key).toBe(PRIVATE_KEY)
    // Offered first, so the read guard has the path — the same order the form uses.
    expect(calls.findIndex((row) => row[0] === 'servers:keys')).toBeLessThan(calls.findIndex((row) => row[0] === 'servers:key-read'))
  })

  it('needs exactly one way to sign in', () => {
    const manage = tool('servers.manage')
    expect(() => manage.precheck?.({ do: 'add', address: 'a', username: 'u' }, context())).toThrow(/exactly one/)
    expect(() => manage.precheck?.({ do: 'add', address: 'a', username: 'u', keyPath: 'k', password: 'p' }, context())).toThrow(/exactly one/)
  })

  it('keeps the password and the passphrase out of the action log', async () => {
    const logDir = mkdtempSync(join(tmpdir(), 'server-room-log-'))
    try {
      const broker: ConsentBroker = new ConsentBroker({
        ask: (request) => {
          broker.respond(request.id, true, WINDOW_SURFACE)
          return true
        },
        timeoutMs: 50,
      })
      const deck = new DeckControl({ surface: {} as DeckSurface, log: new ActionLog({ dir: logDir }), consent: broker, extraTools: tools })
      await deck.call(
        'servers.manage',
        { do: 'add', address: '10.0.0.6', username: 'deploy', keyPath: '/home/me/.ssh/id_ed25519', passphrase: 'open-sesame-77' },
        { caller: LOCAL },
      )
      await deck.call('servers.manage', { do: 'add', address: '10.0.0.7', username: 'root', password: 'hunter2-hunter2' }, { caller: LOCAL })
      const written = readFileSync(join(logDir, 'actions.jsonl'), 'utf8')
      expect(written).not.toContain('open-sesame-77')
      expect(written).not.toContain('hunter2-hunter2')
      expect(written).not.toContain('KEY-MATERIAL')
    } finally {
      rmSync(logDir, { recursive: true, force: true })
    }
  })
})

describe('flows that run in a terminal', () => {
  it('closes a terminal it opened once the flow is finished', async () => {
    answers['servers:setup:install'] = () => ({ ok: true, state: { step: 'done' } })
    await tool('servers.manage').run({ do: 'install-agent', serverId: 's1', agent: 'claude' }, context())
    expect(calls).toContainEqual(['servers:shell:open', 's1', 120, 30, ''])
    expect(calls).toContainEqual(['servers:shell:close', 's1 fresh'])
  })

  it('leaves it open while the flow is still going, because closing it would cancel the flow', async () => {
    answers['servers:setup:install'] = () => ({ ok: true, state: { step: 'signing-in' } })
    const out = await tool('servers.manage').run({ do: 'install-agent', serverId: 's1', agent: 'claude' }, context())
    expect(calls.some((row) => row[0] === 'servers:shell:close')).toBe(false)
    expect((out.value as { shellId: string }).shellId).toBe('s1 fresh')
  })

  it('runs in the person’s own terminal when one is named, and never closes theirs', async () => {
    answers['servers:host:install'] = () => ({ ok: true, state: { step: 'done' } })
    await tool('servers.manage').run({ do: 'install-host', serverId: 's1', shellId: 's1 abc' }, context())
    expect(calls).toContainEqual(['servers:host:install', 's1', 's1 abc'])
    expect(calls.some((row) => row[0] === 'servers:shell:open' || row[0] === 'servers:shell:close')).toBe(false)
  })
})

describe('uploading', () => {
  it('never sends a credential folder onto a server', () => {
    expect(() =>
      tool('servers.manage').precheck?.({ do: 'upload', serverId: 's1', path: join(homedir(), '.aws', 'credentials') }, context()),
    ).toThrow(/credentials are kept/)
  })
})
