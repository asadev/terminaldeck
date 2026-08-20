import { describe, expect, it } from 'vitest'
import {
  portSourceFor,
  readServerPorts,
  readServers,
  resolveServersApi,
  serverChoices,
  type ServerPortsState,
} from './server-machines'
import { lostMachine, machineChoices, THIS_MACHINE } from './machines-bridge'

/**
 * A server is a machine in this picker, and the tests say so by asserting
 * against the *shared* helpers rather than against anything of its own.
 *
 * That is the point of the file. `lostMachine`, `machineChoices` and
 * `MachineChoice` are the paired-device path's own code, and a server row that
 * needed any of them changed would be the browser growing a second kind of
 * machine — which is precisely what *"shape of the application should not be
 * changing for local and remote devices"* forbids.
 */

const SERVERS = [
  { id: 's1', name: 'the box' },
  { id: 's2', name: 'the other one' },
]

describe('reading the bridge', () => {
  it('is absent, not broken, when the preload predates this', () => {
    expect(resolveServersApi({ listServers: () => undefined })).toBeNull()
    expect(resolveServersApi(undefined)).toBeNull()
    const whole = { listServers() {}, serverPorts() {}, reachOnServer() {} }
    expect(resolveServersApi(whole)).toBe(whole)
  })

  it('takes the two fields a browser needs and leaves the rest where they are', () => {
    const rows = readServers([
      { id: 's1', name: 'the box', address: '178.105.248.86', username: 'root', fingerprint: 'SHA256:…' },
      { id: 's2', name: '' },
      { name: 'no id at all' },
      'nonsense',
    ])
    // An address and a sign-in name have no business in a browser panel: a
    // field that crossed because nobody stopped it is how one ends up in a
    // screenshot.
    expect(rows).toEqual([
      { id: 's1', name: 'the box' },
      { id: 's2', name: 'That server' },
    ])
  })

  it('turns an unreadable answer into a sentence rather than a silence', () => {
    expect(readServerPorts(null)).toEqual({
      state: 'refused',
      message: 'That server was asked what it is serving and gave no answer.',
    })
    expect(readServerPorts({ ok: false })).toMatchObject({ state: 'refused' })
  })

  it('reads the list, named things first, exactly as this machine’s own scan is read', () => {
    const answer = readServerPorts({
      ok: true,
      cannot: null,
      ports: [
        { port: 6001, process: '', guessed: true, ours: false },
        { port: 8000, process: 'docker-proxy', guessed: false, ours: false },
      ],
    })
    expect(answer).toEqual({
      state: 'ready',
      cannot: null,
      ports: [
        { port: 8000, process: 'docker-proxy', guessed: false, ours: false },
        { port: 6001, process: '', guessed: true, ours: false },
      ],
    })
  })
})

describe('a server in the picker', () => {
  it('is a row of exactly the shape a paired computer is', () => {
    const [device] = machineChoices({
      machines: [{ id: 'm1', name: 'office-pc', platform: 'win32' }],
      links: [],
    } as never)
    const [server] = serverChoices(SERVERS, {})
    expect(Object.keys(server).sort()).toEqual(Object.keys(device).sort())
    expect(server.kind).toBe('server')
    expect(device.kind).toBe('device')
  })

  it('is selectable before it has been asked, because nobody has asked it', () => {
    const [server] = serverChoices(SERVERS, {})
    /*
     * Not knowing whether a server will allow this is not the same as knowing
     * that it will not. A row greyed out on a maybe hides a working feature
     * behind a dropdown — and a server is not dialled until somebody chooses
     * it, which is §5.4's rule rather than a shortcut.
     */
    expect(server.unreachable).toBeNull()
    expect(server.ports).toEqual([])
  })

  it('keeps the server’s own sentence out of the row, and stops being selectable', () => {
    const refused: Record<string, ServerPortsState> = {
      s1: { state: 'refused', message: 'This server is set up to refuse this.' },
    }
    const [server] = serverChoices(SERVERS, refused)
    // A word on the row; the server's sentence only as the row's `title`. A
    // server writes its own refusal and this menu cannot know how long it will
    // be, which is the whole reason the label is fixed here rather than passed
    // through.
    expect(server.unreachable).toBe('Refused')
    expect(server.detail).toBe('This server is set up to refuse this.')
    // And the same helper the paired path uses gives the picker back, naming
    // the server and its state, rather than leaving somebody pointed at a
    // machine that refuses every address they type.
    expect(lostMachine(serverChoices(SERVERS, refused), 's1')).toBe('the box — Refused')
    expect(lostMachine(serverChoices(SERVERS, refused), THIS_MACHINE)).toBeNull()
  })

  it('lists what it said it is serving', () => {
    const [server] = serverChoices(SERVERS, {
      s1: { state: 'ready', cannot: null, ports: [{ port: 8000, process: 'nginx', guessed: false, ours: false }] },
    })
    expect(server.ports).toHaveLength(1)
  })
})

describe('what the start page is given', () => {
  it('waits rather than claiming nothing is running, while the answer is coming', () => {
    // `null` is the page's own "still asking" state, which draws *"Asking … what
    // it is serving"*. An empty list here would be a claim about somebody's
    // server that this app has not been given grounds for.
    expect(portSourceFor(undefined)).toEqual({ ports: null, cannot: null })
    expect(portSourceFor({ state: 'asking' })).toEqual({ ports: null, cannot: null })
  })

  it('says why the list is empty when the server has no way to tell', () => {
    const why = 'this server has no tool installed for listing what is listening'
    expect(portSourceFor({ state: 'ready', ports: [], cannot: why })).toEqual({
      ports: [],
      cannot: why,
    })
  })

  it('shows the refusal in place of a list rather than an empty one', () => {
    expect(portSourceFor({ state: 'refused', message: 'It will not allow this.' })).toEqual({
      ports: [],
      cannot: 'It will not allow this.',
    })
  })
})
