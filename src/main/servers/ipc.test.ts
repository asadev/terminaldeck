/**
 * The registration, driven the way the window drives it.
 *
 * Against a plain object rather than Electron's `ipcMain`, which is the whole
 * reason `ipc-seam.ts` exists: *"narrowing it means the registration can be
 * exercised with an ordinary object instead of `as unknown as IpcMain`, and a
 * cast in a test throws away the very check the test is for."*
 *
 * Three things here are worth more than ordinary coverage, and each has a
 * recorded failure behind it:
 *
 *  - **the channel names**, because `src/preload/contract.test.ts` records three
 *    shipping bugs at this seam and none of them was a type error;
 *  - **the connection lifecycle**, because §5.4's *"events, not polling"* is
 *    paid by closing things, and the closing half is the half that is easy to
 *    forget;
 *  - **what crosses back**, because a credential that reached a screen would be
 *    *"a screenshot away from publishing it"* — `renderer/machines/types.ts`'s
 *    own words about paired devices, which hold identically here.
 */

import { randomUUID } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { InvokeRegistrar } from '../ipc-seam'
import {
  registerServersIpc,
  SERVERS_SHELL_CLOSED_CHANNEL,
  SERVERS_SHELL_OUTPUT_CHANNEL,
  type ServersIpcDeps,
} from './ipc'
import { ServerProblem, type ServerShell } from './connection'
import { factNo, factYes, type ServerFacts } from './facts'
import { cmd } from './test-fixtures'

const AT = 1_700_000_000_000

function registrar(): { ipcMain: InvokeRegistrar; call: (channel: string, ...args: unknown[]) => Promise<unknown> } {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  return {
    ipcMain: { handle: (channel, listener) => void handlers.set(channel, listener) },
    call: async (channel, ...args) => {
      const handler = handlers.get(channel)
      if (handler === undefined) throw new Error(`no handler for ${channel}`)
      return handler({}, ...args)
    },
  }
}

/** A server with one thing on it, so a card exists to press a button on. */
function serverFacts(): ServerFacts {
  const nothing = factNo<never>(AT, 'asked')
  return {
    serverId: 's1',
    measuredAt: AT,
    os: factYes('Ubuntu 24.04.4 LTS', AT, 'read'),
    kernel: nothing,
    arch: nothing,
    hostname: nothing,
    user: factYes('root', AT, 'asked'),
    privilege: factYes('yes', AT, 'asked'),
    init: factYes('systemd', AT, 'asked'),
    containerRuntime: factNo(AT, 'asked'),
    packageManager: nothing,
    webServer: nothing,
    cpus: nothing,
    disk: nothing,
    memory: nothing,
    load1: nothing,
    uptimeSeconds: nothing,
    services: factYes(
      [{ name: 'mine.service', state: 'running', description: 'Mine', addedHere: true }],
      AT,
      'asked what it is set up to keep running',
    ),
    containers: factNo(AT, 'asked'),
    listeners: factYes([], AT, 'asked'),
    siteNames: factNo(AT, 'asked'),
    agents: factYes([], AT, 'looked for a coding assistant'),
    agentInstall: nothing,
  }
}

const dirs: string[] = []

function harness(overrides: Partial<ServersIpcDeps> = {}): {
  ipc: ReturnType<typeof registerServersIpc>
  call: (channel: string, ...args: unknown[]) => Promise<unknown>
  ran: string[][]
  broadcast: Array<{ channel: string; payload: unknown }>
  storageDir: string
  released: string[]
} {
  const storageDir = mkdtempSync(join(tmpdir(), 'td-servers-'))
  dirs.push(storageDir)
  const ran: string[][] = []
  const broadcast: Array<{ channel: string; payload: unknown }> = []
  const released: string[] = []
  const { ipcMain, call } = registrar()
  const ipc = registerServersIpc(ipcMain, {
    storageDir,
    servers: () => [{ id: 's1', name: 'demo', address: 'example.test', username: 'root' }],
    facts: async () => serverFacts(),
    run: async (_serverId, argv) => {
      ran.push([...argv])
      return cmd({ stdout: argv.includes('journalctl') ? 'line one\nline two\n' : '' })
    },
    runScript: async () => cmd({ stdout: '##compose-available\nno\n' }),
    release: (serverId) => void released.push(serverId),
    broadcast: (channel, payload) => void broadcast.push({ channel, payload }),
    ...overrides,
  })
  return { ipc, call, ran, broadcast, storageDir, released }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('the channels the window calls', () => {
  it('answers the list without connecting to anything', async () => {
    const { call, ran } = harness()
    expect(await call('servers:list')).toEqual([
      { id: 's1', name: 'demo', address: 'example.test', username: 'root' },
    ])
    // §5.4: the list of servers costs nothing when closed. It does not dial
    // anything to draw itself.
    expect(ran).toEqual([])
  })

  it('hands the identity and the kind of sign-in through to the list, unchanged', async () => {
    /*
     * The shape, pinned at this end, because it was wrong here once and cost
     * nothing at compile time.
     *
     * `hostKey` is **nested** — `{ algorithm, fingerprint }` — exactly as
     * `store.ts` writes it and exactly as the window's own narrower reads it
     * (`renderer/machines/servers/types.test.ts` asserts the same literal).
     * Flattening it to a bare `fingerprint` on the way past typechecked
     * perfectly and made the identity screen say "It has not told us one yet"
     * about a server whose fingerprint was sitting in `servers.json` — on the
     * one screen whose stated job is *"you can compare what is below against
     * the server itself"*.
     *
     * `credential` is the kind and never the credential; §3.7.
     */
    const row = {
      id: 's1',
      name: 'demo',
      address: 'example.test',
      username: 'root',
      credential: 'key' as const,
      hostKey: { algorithm: 'ssh-ed25519', fingerprint: 'SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0' },
    }
    const { call } = harness({ servers: () => [row] })
    expect(await call('servers:list')).toEqual([row])
  })

  it('builds the whole view in one look, and remembers it', async () => {
    const { call } = harness()
    const answer = (await call('servers:look', 's1')) as { ok: true; view: { cards: unknown[]; offered: unknown } }
    expect(answer.ok).toBe(true)
    expect(answer.view.cards).toHaveLength(1)
    expect(answer.view.offered).toEqual({ 'service:mine.service': ['logs', 'restart', 'stop'] })
  })

  it('hands a refusal back as a sentence rather than as a rejected promise', async () => {
    /*
     * A rejected `ipcMain.handle` reaches the renderer as `Error: Error
     * invoking remote method '…'`, which mangles the one thing this feature
     * must deliver intact — the sentence `actions.ts` wrote. §4.3 has three
     * surfaces rendering one string.
     */
    const { call } = harness({
      facts: async () => {
        throw new Error('That address did not answer in time.')
      },
    })
    expect(await call('servers:look', 's1')).toEqual({
      ok: false,
      sentence: 'That address did not answer in time.',
      detail: '',
    })
  })

  it('previews an action without running it', async () => {
    const { call, ran } = harness()
    await call('servers:look', 's1')
    const before = ran.length
    const answer = (await call('servers:preview', 's1', 'service:mine.service', 'restart')) as {
      ok: true
      preview: { sentence: string; klass: string }
    }
    expect(answer.preview.sentence).toMatch(/offline for about five seconds/)
    expect(answer.preview.klass).toBe('reversible')
    expect(ran.length).toBe(before)
  })

  it('refuses an action id it has never heard of, before anything is looked up', async () => {
    const { call, ran } = harness()
    expect(await call('servers:act', 's1', 'service:mine.service', 'rm -rf /')).toEqual({
      ok: false,
      sentence: 'That isn’t something this app can do.',
      detail: '',
    })
    expect(ran).toEqual([])
  })

  it('runs a real action and forgets what it knew, because the server just changed', async () => {
    const { call, ran } = harness()
    await call('servers:look', 's1')
    const answer = (await call('servers:act', 's1', 'service:mine.service', 'restart')) as {
      ok: true
      outcome: { done: string }
    }
    expect(answer.outcome.done).toBe('Restarted mine.')
    expect(ran).toContainEqual(['systemctl', 'restart', 'mine.service'])
    /*
     * The cache is dropped rather than re-measured. §5.4 is explicit that a
     * refresh is a press and not a tick — but a page that kept showing
     * "running" after a Stop would be showing something it *knows* is wrong,
     * which is a different thing from being honestly stale.
     */
    expect(await call('servers:look', 's1')).toMatchObject({ ok: true })
  })

  it('reads a bounded window of log, clamped whatever the caller asks for', async () => {
    const { call, ran } = harness()
    const answer = (await call('servers:logs', 's1', 'service:mine.service', 999_999)) as {
      ok: true
      lines: string[]
    }
    expect(answer.lines).toEqual(['line one', 'line two'])
    const journalctl = ran.find((argv) => argv[0] === 'journalctl')
    expect(journalctl).toContain('2000')
  })
})

describe('when it lets go', () => {
  it('closes the connection and every terminal when the page closes', async () => {
    const closed = vi.fn()
    const shell: ServerShell = {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: closed,
    }
    const { call, released } = harness({ openShell: async () => shell })
    await call('servers:look', 's1')
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { ok: true; shellId: string }
    expect(opened.ok).toBe(true)

    await call('servers:close', 's1')

    expect(closed).toHaveBeenCalledTimes(1)
    expect(released).toEqual(['s1'])
    // The shell id is dead afterwards, rather than writing into a channel that
    // is gone.
    expect(await call('servers:shell:write', opened.shellId, 'ls\n')).toEqual({ written: false })
  })

  it('says which server a shell is on, so a browser window can be bound to it', async () => {
    /*
     * A shell on a server is a *session* to the session↔browser map, which keys
     * its bindings `<machineId>\0<sessionId>` with the server standing in for
     * the machine. Nothing outside this file can answer which server a shell is
     * on — the id happens to begin with the server's, and a reader that split on
     * the space would be one server name with a space in it away from binding a
     * window to a machine that does not exist.
     */
    const shell: ServerShell = {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: () => undefined,
    }
    const { ipc, call } = harness({ openShell: async () => shell })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }

    expect(ipc.serverOfShell(opened.shellId)).toBe('s1')
    expect(ipc.serverOfShell('nothing this app opened')).toBeNull()

    /*
     * And the two id spaces cannot collide, which is what makes `index.ts`'s
     * `machineOfSession` safe to ask all three registries in a row with one id.
     * A session id is a bare `randomUUID()`; a shell id is the server's id, a
     * space, and a UUID. A UUID contains no space, so a session id can never
     * name a shell and a shell id can never name a pty — the answer is decided
     * by whichever registry actually holds it, never by the order they are
     * asked in.
     */
    expect(opened.shellId).toContain(' ')
    expect(ipc.serverOfShell(randomUUID())).toBeNull()

    // And it stops answering the moment the shell is gone, rather than pointing
    // a binding at a channel that has been closed.
    await call('servers:shell:close', opened.shellId)
    expect(ipc.serverOfShell(opened.shellId)).toBeNull()
  })

  it('says so plainly on a build with no terminal, rather than drawing one that does nothing', async () => {
    const { call } = harness({ openShell: undefined })
    expect(await call('servers:shell:open', 's1', 100, 40)).toMatchObject({
      ok: false,
      sentence: 'This copy of the app can’t open a terminal on a server.',
    })
  })

  it('passes columns first and rows second, the same order everywhere', async () => {
    /*
     * `ssh2` reverses them between `shell({cols, rows})` and `setWindow(rows,
     * cols, …)`, in the same library on the same channel. Getting it wrong
     * produces a terminal that is perfect until the window is resized and then
     * wraps every line at the wrong column — which reads as a rendering bug.
     * A square test window would pass either way, so this one is not square.
     */
    const sizes: Array<{ cols: number; rows: number }> = []
    const shell: ServerShell = {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: (size) => void sizes.push(size),
      close: () => undefined,
    }
    const openShell = vi.fn(async () => shell)
    const { call } = harness({ openShell })
    const opened = (await call('servers:shell:open', 's1', 132, 43)) as { shellId: string }
    // Three arguments: the third is the folder the terminal should start in,
    // and `undefined` is what a press that chose none sends — which is every
    // press this channel had until the folder picker existed.
    expect(openShell).toHaveBeenCalledWith('s1', { cols: 132, rows: 43 }, undefined)
    await call('servers:shell:resize', opened.shellId, 100, 25)
    expect(sizes).toEqual([{ cols: 100, rows: 25 }])
  })

  it('pushes the far end’s output on its own channel, tagged with the shell it came from', async () => {
    /*
     * Typed explicitly rather than inferred. TypeScript narrows a `let` that is
     * only ever assigned inside a callback to `null`, and the call below then
     * fails to compile for a reason that has nothing to do with the test.
     */
    const listeners: Array<(chunk: string) => void> = []
    const shell: ServerShell = {
      onData: (listener) => {
        listeners.push(listener)
        return () => undefined
      },
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: () => undefined,
    }
    const { call, broadcast } = harness({ openShell: async () => shell })
    const opened = (await call('servers:shell:open', 's1', 80, 24)) as { shellId: string }
    listeners[0]?.('hello\r\n')
    expect(broadcast).toContainEqual({
      channel: SERVERS_SHELL_OUTPUT_CHANNEL,
      payload: { shellId: opened.shellId, data: 'hello\r\n' },
    })
    expect(SERVERS_SHELL_CLOSED_CHANNEL).toBe('servers:shell:closed')
  })
})

describe('adding, and forgetting', () => {
  // `kind` is remembered so a test can assert the list learns which sort of
  // sign-in a server has — never what it is.
  const kinds = vi.fn(() => true)
  const store = {
    add: () => ({ id: 'new-1' }),
    setCredentialKind: kinds,
    rename: () => true,
    forget: vi.fn(() => true),
    // The default folder is part of the slice `ipc.ts` asks for, and none of
    // the tests in this block is about it: a store with no row for the id
    // answers null, which is also what a server nobody has chosen a default
    // for answers.
    get: () => null,
    setStartIn: () => false,
  }

  /*
   * The session-only hold, remade for every test so that one `it` cannot read
   * another's calls. It exists on the credential slice because two of the three
   * branches in `servers:add` write nothing down and the connection still has
   * to be handed the sign-in — see the interface's own comment.
   */
  let hold = vi.fn()
  beforeEach(() => {
    hold = vi.fn()
  })

  it('saves a sign-in into the secure store and never answers it back', async () => {
    const save = vi.fn(() => ({ ok: true, message: '' }))
    const { call } = harness({
      store,
      credentials: { available: () => true, save, holdForSession: hold, forget: () => ({ ok: true, message: '' }) },
      acquire: async () => undefined,
    })
    const answer = await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'hunter2',
      remember: true,
    })
    expect(save).toHaveBeenCalledWith('new-1', { kind: 'password', password: 'hunter2' })
    expect(answer).toEqual({ ok: true, id: 'new-1', savedSignIn: true, note: '' })
    expect(JSON.stringify(answer)).not.toContain('hunter2')
    /*
     * And the list is told *which sort* of sign-in this server has. Without
     * this the stored row keeps its default of `none` for ever, and the sign-in
     * section reads "this build did not say" about a password the person typed
     * one screen earlier — which reads as the app having lost it.
     */
    expect(kinds).toHaveBeenCalledWith('new-1', 'password')
  })

  it('honours "don’t save" by simply not writing anything', async () => {
    // §3.7: somebody trying this out on a borrowed machine should not have to
    // trust us to be careful.
    const save = vi.fn(() => ({ ok: true, message: '' }))
    const { call } = harness({
      store,
      credentials: { available: () => true, save, holdForSession: hold, forget: () => ({ ok: true, message: '' }) },
      acquire: async () => undefined,
    })
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'hunter2',
      remember: false,
    })) as { savedSignIn: boolean; note: string }
    expect(save).not.toHaveBeenCalled()
    expect(answer.savedSignIn).toBe(false)
    expect(answer.note).toMatch(/only until you close the app/)
    /*
     * "Don't save" means don't write it down. It does not mean throw it away:
     * the connection this handler is about to open needs the sign-in, and
     * without this the person who ticked the box gets a server that is added
     * and then refuses them, with a sentence blaming a password they typed
     * correctly.
     */
    expect(hold).toHaveBeenCalledWith('new-1', { kind: 'password', password: 'hunter2' })
  })

  it('adds the server anyway on a machine with no secure store, and says what happened', async () => {
    const { call } = harness({
      store,
      credentials: {
        available: () => false,
        save: () => ({ ok: false, message: '' }),
        holdForSession: hold,
        forget: () => ({ ok: true, message: '' }),
      },
      acquire: async () => undefined,
    })
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'hunter2',
    })) as { ok: boolean; savedSignIn: boolean; note: string }
    expect(answer.ok).toBe(true)
    expect(answer.savedSignIn).toBe(false)
    expect(answer.note).toMatch(/no secure store/i)
    // Same reason as "don't save" above, arriving from the other direction: the
    // OS refused to keep it, so this launch keeps it in memory and says so.
    expect(hold).toHaveBeenCalledWith('new-1', { kind: 'password', password: 'hunter2' })
  })

  it('asks for a passphrase rather than refusing a locked key', async () => {
    /*
     * The difference between a flow that works and one where somebody with a
     * perfectly good key concludes the app does not support keys. The key is
     * parsed before anything is stored or dialled, so this costs no round trip.
     */
    const { call } = harness({ store })
    const locked = [
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAAAA',
      '-----END OPENSSH PRIVATE KEY-----',
    ].join('\n')
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'key',
      key: locked,
    })) as { ok: boolean; kind: string }
    expect(answer.ok).toBe(false)
    expect(['needs-passphrase', 'key-unreadable']).toContain(answer.kind)
  })

  it('rolls the server back out of the list when it could not be reached', async () => {
    /*
     * A row that has never connected is a row whose first failure arrives
     * later, on a different screen, with none of the three things the person
     * just typed in front of them.
     */
    const forget = vi.fn(() => true)
    const forgetCredential = vi.fn(() => ({ ok: true, message: '' }))
    const { call } = harness({
      store: {
        add: () => ({ id: 'new-1' }),
        setCredentialKind: () => true,
        rename: () => true,
        forget,
        // This test is about forgetting a server that never connected, so the
        // default folder is only here because the slice `ipc.ts` asks for
        // includes it. A store with no row for the id answers null, which is
        // what a server with no default answers too.
        get: () => null,
        setStartIn: () => false,
      },
      credentials: {
        available: () => true,
        save: () => ({ ok: true, message: '' }),
        holdForSession: () => undefined,
        forget: forgetCredential,
      },
      acquire: async () => {
        throw new ServerProblem('sign-in-refused', 'That sign-in was refused.')
      },
    })
    const answer = (await call('servers:add', {
      address: 'example.test',
      username: 'root',
      method: 'password',
      password: 'nope',
    })) as { ok: boolean; kind: string; sentence: string }
    expect(answer).toEqual({ ok: false, kind: 'sign-in-refused', sentence: 'That sign-in was refused.' })
    expect(forget).toHaveBeenCalledWith('new-1')
    expect(forgetCredential).toHaveBeenCalledWith('new-1')
  })

  it('carries a changed identity through whole, fingerprints and all', async () => {
    /*
     * §3.6: the connection stops and nothing is offered but the fingerprint and
     * a way to cancel. The window can only draw that if it can tell this
     * failure from the eight that merely need another go — so the kind and both
     * fingerprints cross, rather than being flattened into one sentence.
     */
    const { call } = harness({
      facts: async () => {
        throw new ServerProblem('identity-changed', 'This server answered with a different identity.', {
          expected: 'SHA256:aaa',
          offered: 'SHA256:bbb',
        })
      },
    })
    expect(await call('servers:look', 's1')).toEqual({
      ok: false,
      sentence: 'This server answered with a different identity.',
      detail: '',
      kind: 'identity-changed',
      identity: { expected: 'SHA256:aaa', offered: 'SHA256:bbb' },
    })
  })

  it('forgets only what this app holds, and never dials the server to do it', async () => {
    const forgetCredential = vi.fn(() => ({ ok: true, message: '' }))
    const { call, ran, released } = harness({
      store,
      credentials: {
        available: () => true,
        save: () => ({ ok: true, message: '' }),
        holdForSession: () => undefined,
        forget: forgetCredential,
      },
    })
    await call('servers:look', 's1')
    const before = ran.length
    expect(await call('servers:forget', 's1')).toEqual({ forgotten: true })
    expect(forgetCredential).toHaveBeenCalledWith('s1')
    expect(released).toContain('s1')
    // Not one command was sent. "Forget" is about our record; §5.3 says the
    // sentence has to be exact because it will read as "delete" otherwise.
    expect(ran.length).toBe(before)
  })
})

describe('the grant, from the window', () => {
  it('grants, reports and revokes, per server', async () => {
    const { call } = harness()
    const granted = (await call('servers:grant', 's1', 60_000)) as { ok: true; grant: { serverId: string } }
    expect(granted.grant.serverId).toBe('s1')
    expect(await call('servers:grant-state', 's1')).toMatchObject({ serverId: 's1' })
    expect(await call('servers:revoke', 's1')).toEqual({ revoked: true })
    expect(await call('servers:grant-state', 's1')).toBeNull()
  })

  it('refuses a server this app does not know', async () => {
    const { call } = harness()
    expect(await call('servers:grant', 'made-up', 60_000)).toMatchObject({ ok: false })
  })

  it('drops every grant when the app stops', async () => {
    const { call, ipc } = harness()
    await call('servers:grant', 's1', 60_000)
    ipc.stop()
    expect(ipc.grants.state('s1')).toBeNull()
  })
})

describe('the way back survives the thing it is a way back from', () => {
  it('writes it to this computer, not to the server', async () => {
    const { call, storageDir, ran } = harness({
      run: async (_serverId, argv) => {
        ran.push?.([...argv])
        if (argv.includes('rev-parse')) return cmd({ stdout: `${'d'.repeat(40)}\n` })
        return cmd()
      },
      facts: async () => {
        const base = serverFacts()
        return {
          ...base,
          services: factYes(
            [{ name: 'mine.service', state: 'running', description: 'Mine', addedHere: true }],
            AT,
            'asked',
          ),
        }
      },
      runScript: async () => cmd({ stdout: '##compose-available\nno\n##repos\nmine.service\t/opt/mine\n' }),
    })
    await call('servers:look', 's1')
    const answer = (await call('servers:act', 's1', 'service:mine.service', 'update')) as { ok: boolean }
    expect(answer.ok).toBe(true)

    const written = JSON.parse(readFileSync(join(storageDir, 'server-waybacks.json'), 'utf8')) as {
      rows: Record<string, { kind: string; commit: string }>
    }
    const row = Object.values(written.rows)[0]
    expect(row.kind).toBe('repo-commit')
    expect(row.commit).toBe('d'.repeat(40))
  })
})

/**
 * Putting a file on a server, from the window.
 *
 * The one consumer is `renderer/session-transfer.ts`, which reads this answer
 * with the *same* function it reads `machines:upload` with — so the shape here
 * is not a local choice, it is what keeps a file going to a server and a file
 * going to a paired PC from becoming two behaviours.
 */
describe('servers:upload', () => {
  const HERE = join(tmpdir(), 'td-upload-fixture.png')

  it('answers the path the server gave it', async () => {
    writeFileSync(HERE, 'x')
    const { call } = harness({ putFile: async () => '/home/imza/Terminal Deck/shot.png' })
    expect(await call('servers:upload', 's1', HERE)).toEqual({
      ok: true,
      path: '/home/imza/Terminal Deck/shot.png',
    })
  })

  it('sends the file’s own name as the suggestion, never a path', async () => {
    writeFileSync(HERE, 'x')
    const putFile = vi.fn(async () => '/home/imza/Terminal Deck/x.png')
    const { call } = harness({ putFile })
    await call('servers:upload', 's1', HERE)
    expect(putFile).toHaveBeenCalledWith('s1', HERE, 'td-upload-fixture.png')
  })

  it('says so on a build that cannot put a file on a server at all', async () => {
    writeFileSync(HERE, 'x')
    const { call } = harness()
    expect(await call('servers:upload', 's1', HERE)).toMatchObject({ ok: false })
  })

  it('says so about a file that is not there, without dialling anything', async () => {
    const putFile = vi.fn(async () => '/x')
    const { call } = harness({ putFile })
    expect(await call('servers:upload', 's1', join(tmpdir(), 'td-not-a-file.png'))).toMatchObject({
      ok: false,
    })
    expect(putFile).not.toHaveBeenCalled()
  })

  it('answers the server’s own sentence when it refuses', async () => {
    writeFileSync(HERE, 'x')
    const { call } = harness({
      putFile: async () => {
        throw new ServerProblem('not-allowed', 'This sign-in is not allowed to write there.')
      },
    })
    expect(await call('servers:upload', 's1', HERE)).toEqual({
      ok: false,
      message: 'This sign-in is not allowed to write there.',
    })
  })

  it('refuses anything that is not a server and a file', async () => {
    const { call } = harness({ putFile: async () => '/x' })
    expect(await call('servers:upload', 7, HERE)).toMatchObject({ ok: false })
    expect(await call('servers:upload', 's1', '')).toMatchObject({ ok: false })
  })
})

describe('the conversation a shell on a server is writing', () => {
  const OPENED = 1_760_000_000_000

  /** A shell that stays open, so the ids the chat channels take exist. */
  function idleShell(): ServerShell {
    return {
      onData: () => () => undefined,
      onClose: () => () => undefined,
      write: () => undefined,
      resize: () => undefined,
      close: () => undefined,
    }
  }

  /**
   * One transcript on the far end, with a body and a first-line timestamp, and
   * the two deps that read it.
   *
   * The script and the byte range are faked at the boundary `connection.ts`
   * owns; everything above them — which file belongs to which shell, how a line
   * becomes a bubble — is the real code. `servers/chat.test.ts` exercises those
   * rules directly; what this file is for is the *wiring*.
   */
  function transcriptDeps(path: string, body: string, startedAt: number): Partial<ServersIpcDeps> {
    return {
      openShell: async () => idleShell(),
      now: () => OPENED,
      runScript: async () =>
        cmd({
          stdout: `now\t${Math.trunc(OPENED / 1000)}\nfile\t${new Date(startedAt).toISOString()}\t${path}\n`,
        }),
      readFileRange: async (_serverId, asked, from, length) => {
        const whole = Buffer.from(asked === path ? body : '', 'utf8')
        return { bytes: whole.subarray(from, from + length), size: whole.length }
      },
    }
  }

  it('reads the transcript that belongs to this shell and collapses it', async () => {
    const line = (type: 'user' | 'assistant', text: string, id: string): string =>
      type === 'user'
        ? `${JSON.stringify({ type, uuid: id, timestamp: '2026-10-09T00:00:05Z', message: { content: text } })}\n`
        : `${JSON.stringify({
            type,
            uuid: id,
            timestamp: '2026-10-09T00:00:06Z',
            message: { id, content: [{ type: 'text', text }] },
          })}\n`

    const { call } = harness(
      transcriptDeps(
        '/root/.claude/projects/p/live.jsonl',
        line('user', 'deploy it', 'u1') + line('assistant', 'On it.', 'a1'),
        OPENED + 1_000,
      ),
    )
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    const update = (await call('servers:chat:load', opened.shellId)) as {
      found: boolean
      transcriptPath: string
      messages: Array<{ role: string; text: string }>
    }
    expect(update.found).toBe(true)
    expect(update.transcriptPath).toBe('/root/.claude/projects/p/live.jsonl')
    expect(update.messages).toEqual([
      { id: 'you:u1', role: 'you', text: 'deploy it', at: Date.parse('2026-10-09T00:00:05Z') },
      { id: 'agent:a1', role: 'agent', text: 'On it.', at: Date.parse('2026-10-09T00:00:06Z') },
    ])
  })

  it('answers nothing at all rather than half a feature when the build cannot read a file', async () => {
    /*
     * `readFileRange` is optional on the deps and a build without it must not
     * quietly draw an empty conversation — the window asks `serverChatWired`
     * first and keeps the refusal it always had. Null is what that question is
     * answered with here, and it is deliberately not an empty update: an empty
     * update is a claim that there is nothing to say.
     */
    const { call } = harness({ openShell: async () => idleShell() })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:chat:load', opened.shellId)).toBeNull()
    expect(await call('servers:chat:tail', opened.shellId)).toBeNull()
  })

  it('is keyed on the shell, so a second terminal on one server is a second reading', async () => {
    const { call } = harness(
      transcriptDeps('/root/.claude/projects/p/one.jsonl', '', OPENED + 1_000),
    )
    const first = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    const second = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(first.shellId).not.toBe(second.shellId)

    // Closing one reading leaves the other's alone. The main process holds them
    // under the shell's id, which is why `closeChat` on the window's side
    // ignores the transcript path it is handed.
    await call('servers:chat:load', first.shellId)
    expect(await call('servers:chat:close', first.shellId)).toEqual({ closed: true })
    expect(await call('servers:chat:close', first.shellId)).toEqual({ closed: false })
  })

  it('refuses anything that is not a shell', async () => {
    const { call } = harness(transcriptDeps('/x.jsonl', '', OPENED))
    expect(await call('servers:chat:load', 7)).toBeNull()
    expect(await call('servers:chat:close', 7)).toEqual({ closed: false })
  })
})

describe('which login that server account signs in as', () => {
  it('answers out of the probe rather than asking the server again', async () => {
    /*
     * Read from the measurement the server page already took — the same thing
     * `setupRoom` does with the install room — so drawing a bar does not cost an
     * SSH probe. A server nobody has looked at is measured once, here, and every
     * later ask is free.
     *
     * It is deliberately **not** an account this app can switch. Nothing on the
     * SSH side records which login a shell's agent is on; what this reports is a
     * fact about the home the shell landed in, and the bar says so in those
     * words rather than drawing a menu with nothing to act on.
     */
    const facts = serverFacts()
    const withAgent: ServerFacts = {
      ...facts,
      agents: factYes(
        [{ id: 'claude', path: '/usr/bin/claude', version: '2.0.0', signedIn: 'yes', account: 'me@example.test' }],
        AT,
        'looked for a coding assistant',
      ),
    }
    let probes = 0
    const { call } = harness({
      facts: async () => {
        probes += 1
        return withAgent
      },
      openShell: async () => ({
        onData: () => () => undefined,
        onClose: () => () => undefined,
        write: () => undefined,
        resize: () => undefined,
        close: () => undefined,
      }),
    })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toEqual({
      agentId: 'claude',
      account: 'me@example.test',
      signedIn: 'yes',
    })
    await call('servers:shell:account', opened.shellId)
    expect(probes).toBe(1)
  })

  it('says nothing at all when no agent there has a login to report', async () => {
    // Absent rather than empty — the same silent degrade the connectors chip
    // beside it makes. A chip drawn with nothing in it is worse than no chip.
    const { call } = harness({
      openShell: async () => ({
        onData: () => () => undefined,
        onClose: () => () => undefined,
        write: () => undefined,
        resize: () => undefined,
        close: () => undefined,
      }),
    })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toBeNull()
  })

  it('says nothing when the server will not answer, rather than failing the bar', async () => {
    const { call } = harness({
      facts: async () => {
        throw new ServerProblem('no-answer', 'That address did not answer.')
      },
      openShell: async () => ({
        onData: () => () => undefined,
        onClose: () => () => undefined,
        write: () => undefined,
        resize: () => undefined,
        close: () => undefined,
      }),
    })
    const opened = (await call('servers:shell:open', 's1', 100, 40)) as { shellId: string }
    expect(await call('servers:shell:account', opened.shellId)).toBeNull()
  })
})
