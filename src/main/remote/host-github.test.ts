import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  createRemoteEndpoint,
  type RemoteEndpointOptions,
  type RemoteWire,
  type SessionAccess,
  type SessionHandle,
} from './server'
import { createGitHubHostAccess, githubHostWire, type GitHubHostAccess } from './host-github'
import {
  CAPABILITY,
  PROTOCOL_VERSION,
  serialize,
  type ClientMessage,
  type GitHubHostWire,
  type ServerMessage,
} from './protocol'
import { GitHubAuthenticator, type GitHubAuthState } from '../github-auth'

/**
 * The machine's own GitHub login, over the wire — the 2026-08-27 flip, from the
 * side a phone sees.
 *
 * Two halves: the mapping from the authenticator's folder-shaped `GitHubAuthState`
 * down to the small `GitHubHostWire` a phone reads, and the routing of the four
 * verbs plus the change push through the same transport seam `credential-wiring`
 * uses. Between them they hold the promise the whole change rests on: a phone
 * *drives* the login and the host *owns* it, and a device-flow sign-in a phone
 * starts is heard about again — as `github.changed` — when the host's poll
 * finishes it.
 */

/* ------------------------------------------------------------- the mapping -- */

/** A connected, nothing-pending state, with the folder-shaped fields left null. */
function baseState(over: Partial<GitHubAuthState> = {}): GitHubAuthState {
  return {
    connected: true,
    source: 'device-flow',
    host: 'github.com',
    identity: { login: 'asadev', name: 'Asad Iqbal', htmlUrl: 'https://github.com/asadev', avatarUrl: 'https://a/1' },
    scopes: [],
    scopesReported: false,
    ghInstalled: true,
    credentialKind: 'github-app',
    appConfigured: true,
    installUrl: 'https://github.com/apps/terminaldeck/installations/new',
    disconnect: 'Signs this machine out of GitHub locally.',
    pending: null,
    failure: null,
    expiredCredentialRemoved: false,
    repo: null,
    branch: null,
    access: null,
    ...over,
  }
}

describe('mapping the authenticator state to the wire', () => {
  it('carries the account and drops everything folder-shaped', () => {
    const wire = githubHostWire(baseState(), null)
    expect(wire).toEqual({
      connected: true,
      login: 'asadev',
      name: 'Asad Iqbal',
      avatarUrl: 'https://a/1',
      source: 'device-flow',
      appConfigured: true,
      installUrl: 'https://github.com/apps/terminaldeck/installations/new',
      pending: null,
      failure: null,
      disconnect: 'Signs this machine out of GitHub locally.',
    })
    // The wire has no place for a repository, a branch or a repo list — a phone
    // asks about the account, not about a folder it does not have.
    expect(Object.keys(wire)).not.toContain('repo')
    expect(Object.keys(wire)).not.toContain('access')
  })

  it('carries the code while a sign-in is in flight', () => {
    const wire = githubHostWire(
      baseState({
        connected: false,
        identity: null,
        source: null,
        disconnect: null,
        pending: {
          userCode: 'WDJB-MJHT',
          verificationUri: 'https://github.com/login/device',
          expiresAt: 1_900_000_000_000,
          installUrl: 'https://github.com/apps/terminaldeck/installations/new',
        },
      }),
      null,
    )
    expect(wire.connected).toBe(false)
    expect(wire.pending).toEqual({
      userCode: 'WDJB-MJHT',
      verificationUri: 'https://github.com/login/device',
      expiresAt: 1_900_000_000_000,
    })
    // `installUrl` is a property of the account, not of one attempt, so it does
    // not ride inside `pending` on the wire even though the authenticator's prompt
    // carries a copy.
    expect(wire.pending && 'installUrl' in wire.pending).toBe(false)
  })

  it('folds the last flow failure in when the read itself found nothing', () => {
    // A person who pressed Connect and refused the consent screen should read
    // why, not a bare "not signed in" — the same fact the desktop's `withFlowReason`
    // shows. The read produced no failure of its own, so the flow's fills the gap.
    const wire = githubHostWire(
      baseState({ connected: false, identity: null, source: null, disconnect: null }),
      'You cancelled the GitHub sign-in.',
    )
    expect(wire.failure).toBe('You cancelled the GitHub sign-in.')
  })

  it('keeps no failure while connected', () => {
    const wire = githubHostWire(baseState(), 'a stale reason from a previous attempt')
    expect(wire.failure).toBeNull()
  })
})

/* --------------------------------------------------------------- the wire -- */

function fakeSessions(): SessionAccess {
  return {
    list: () => [],
    attach: (): SessionHandle | null => null,
    write: () => {},
    resize: () => {},
    detach: () => {},
  }
}

/** A host GitHub access that records its calls and can fire a change by hand. */
function fakeHostGitHub(initial: GitHubHostWire): {
  api: GitHubHostAccess
  calls: string[]
  emit(next: GitHubHostWire): void
} {
  let current = initial
  const listeners = new Set<() => void>()
  const calls: string[] = []
  const api: GitHubHostAccess = {
    read: async () => {
      calls.push('read')
      return current
    },
    connect: async () => {
      calls.push('connect')
      current = { ...current, pending: { userCode: 'WDJB-MJHT', verificationUri: 'https://github.com/login/device', expiresAt: 1 } }
      return current
    },
    cancel: async () => {
      calls.push('cancel')
      current = { ...current, pending: null }
      return current
    },
    disconnect: async () => {
      calls.push('disconnect')
      current = { ...current, connected: false, login: null }
      return current
    },
    onChanged: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    emitChanged: () => {
      for (const listener of listeners) listener()
    },
  }
  return {
    api,
    calls,
    emit(next) {
      current = next
      for (const listener of listeners) listener()
    },
  }
}

const DISCONNECTED: GitHubHostWire = {
  connected: false,
  login: null,
  name: null,
  avatarUrl: null,
  source: null,
  appConfigured: true,
  installUrl: null,
  pending: null,
  failure: null,
  disconnect: null,
}

interface Peer {
  received: ServerMessage[]
  send(message: ClientMessage): void
}

function connect(endpoint: ReturnType<typeof createRemoteEndpoint>, capabilities?: string[]): Peer {
  const received: ServerMessage[] = []
  let deliver: ((text: string) => void) | null = null
  endpoint.attachTransport('100.64.0.2', (handlers) => {
    deliver = handlers.message
    const wire: RemoteWire = {
      send: (text: string) => received.push(JSON.parse(text)),
      close: () => handlers.closed(),
    }
    return wire
  })
  const peer: Peer = { received, send: (message) => deliver?.(serialize(message)) }
  peer.send({
    t: 'hello',
    protocol: PROTOCOL_VERSION,
    token: 'device-1.secret',
    device: { name: 'iPhone', platform: 'iOS' },
    ...(capabilities ? { capabilities } : {}),
  })
  return peer
}

const auth: RemoteEndpointOptions['auth'] = {
  authenticate: async () => ({ ok: true, deviceId: 'device-1', deviceName: 'iPhone', credential: null }),
}

function serve(hostGitHub?: GitHubHostAccess, ownDevice?: (id: string) => boolean): ReturnType<typeof createRemoteEndpoint> {
  return createRemoteEndpoint({
    sessions: fakeSessions(),
    auth,
    webRoot: join(__dirname, 'nowhere'),
    pingIntervalMs: 0,
    ...(hostGitHub ? { hostGitHub } : {}),
    ...(ownDevice ? { ownDevice } : {}),
  })
}

async function wait<T>(get: () => T | undefined): Promise<T> {
  for (let i = 0; i < 100; i += 1) {
    const found = get()
    if (found !== undefined) return found
    await new Promise((done) => setTimeout(done, 5))
  }
  throw new Error('timed out')
}

const welcome = (peer: Peer) => wait(() => peer.received.find((m) => m.t === 'welcome'))
const stateFor = (peer: Peer, rid: string) =>
  wait(() => peer.received.find((m): m is Extract<ServerMessage, { t: 'github.state' }> => m.t === 'github.state' && m.rid === rid))

describe('over the wire', () => {
  it('advertises github only when the host has an authenticator behind it', async () => {
    expect((await welcome(connect(serve()))).capabilities).not.toContain(CAPABILITY.github)
    expect((await welcome(connect(serve(fakeHostGitHub(DISCONNECTED).api)))).capabilities).toContain(CAPABILITY.github)
  })

  it('withholds github from a guest, the same as settings', async () => {
    const host = fakeHostGitHub(DISCONNECTED)
    // A guest granted a folder must not be able to point the machine's git at
    // their own account.
    const welcomed = await welcome(connect(serve(host.api, () => false)))
    expect(welcomed.capabilities).not.toContain(CAPABILITY.github)
  })

  it('answers github.read with the machine’s current login', async () => {
    const host = fakeHostGitHub({ ...DISCONNECTED, connected: true, login: 'asadev' })
    const peer = connect(serve(host.api), [CAPABILITY.github])
    await welcome(peer)
    peer.send({ t: 'github.read', rid: 'r1' })
    expect((await stateFor(peer, 'r1')).github).toMatchObject({ connected: true, login: 'asadev' })
  })

  it('starts a sign-in on github.connect and hands back the code', async () => {
    const host = fakeHostGitHub(DISCONNECTED)
    const peer = connect(serve(host.api), [CAPABILITY.github])
    await welcome(peer)
    peer.send({ t: 'github.connect', rid: 'c1' })
    const state = await stateFor(peer, 'c1')
    expect(host.calls).toContain('connect')
    expect(state.github.pending?.userCode).toBe('WDJB-MJHT')
  })

  it('pushes github.changed when the host’s login changes under it', async () => {
    // A device-flow sign-in a phone started finishes minutes later in the host's
    // background poll. This is how the phone learns it took, without polling.
    const host = fakeHostGitHub(DISCONNECTED)
    const peer = connect(serve(host.api), [CAPABILITY.github])
    await welcome(peer)

    host.emit({ ...DISCONNECTED, connected: true, login: 'asadev', source: 'device-flow' })
    const changed = await wait(() =>
      peer.received.find((m): m is Extract<ServerMessage, { t: 'github.changed' }> => m.t === 'github.changed'),
    )
    expect(changed.github).toMatchObject({ connected: true, login: 'asadev' })
  })

  it('does not push github.changed to a client that never asked for the capability', async () => {
    const host = fakeHostGitHub(DISCONNECTED)
    const peer = connect(serve(host.api), [])
    await welcome(peer)
    host.emit({ ...DISCONNECTED, connected: true, login: 'asadev' })
    await new Promise((done) => setTimeout(done, 30))
    expect(peer.received.some((m) => m.t === 'github.changed')).toBe(false)
  })

  it('tells a phone the host does not manage its GitHub from here when there is no authenticator', async () => {
    const peer = connect(serve(), [CAPABILITY.github])
    await welcome(peer)
    peer.send({ t: 'github.read', rid: 'r1' })
    const error = await wait(() => peer.received.find((m) => m.t === 'error'))
    expect(error).toMatchObject({ code: 'unavailable' })
  })
})

/* ---------------------------------------------------- the git credential -- */

describe('the login the proxy answers git from', () => {
  it('hands a token in the environment straight to git', () => {
    const auth = new GitHubAuthenticator({
      storageDir: mkdtempSync(join(tmpdir(), 'td-gh-')),
      resolveRepo: async () => ({ ok: false, kind: 'not-a-repo', message: 'no folder', action: null, detail: '' }),
      env: { GH_TOKEN: 'ghp_env' },
    })
    // No stored login to name, so git gets the safe universal username — the
    // password is what GitHub validates.
    expect(auth.gitCredential()).toEqual({ username: 'x-access-token', password: 'ghp_env' })
  })

  it('has nothing to hand when the machine has connected no account', () => {
    const auth = new GitHubAuthenticator({
      storageDir: mkdtempSync(join(tmpdir(), 'td-gh-')),
      resolveRepo: async () => ({ ok: false, kind: 'not-a-repo', message: 'no folder', action: null, detail: '' }),
      env: {},
    })
    // Which is what makes the proxy refuse with "connect one on the host".
    expect(auth.gitCredential()).toBeNull()
  })
})

/* ----------------------------------------------- the change hook is wired -- */

describe('the change hook', () => {
  it('rings every listener when the authenticator fires, and can be unsubscribed', async () => {
    const auth = new GitHubAuthenticator({
      storageDir: mkdtempSync(join(tmpdir(), 'td-gh-')),
      resolveRepo: async () => ({ ok: false, kind: 'not-a-repo', message: 'no folder', action: null, detail: '' }),
      env: {},
    })
    const access = createGitHubHostAccess(auth)
    let rung = 0
    const off = access.onChanged(() => {
      rung += 1
    })
    access.emitChanged()
    access.emitChanged()
    off()
    access.emitChanged()
    expect(rung).toBe(2)
  })
})
