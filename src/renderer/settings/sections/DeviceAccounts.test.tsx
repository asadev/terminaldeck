import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { DeviceAccounts } from './DeviceAccounts'
import type { MachineWithLink } from '../../machines/useMachines'
import type { Machine, MachineLinkState, RemoteSession } from '../../machines/types'

/**
 * A linked device's logins, on the Coding AI pane.
 *
 *   > *"And maybe we can also see the other linked device. Whatever new comes
 *   > here, so we can manage next to them, each of them."*
 *
 * Every case here is a state of the far machine rather than an interaction, and
 * `renderToStaticMarkup` runs no effects — so what this file pins is the three
 * answers the pane gives *before* anything has been read, which are the three a
 * screenshot on a healthy machine never shows.
 */

const machine: Machine = {
  id: 'm1',
  name: 'DESKTOP-DDGMNCV',
  hostId: 'h1',
  fingerprint: 'ff',
  platform: 'win32',
  pairedAt: 1,
  lastConnectedAt: 2,
}

function session(over: Partial<RemoteSession> = {}): RemoteSession {
  return { id: 's1', title: 'Session 1', cwd: '/c/work', provider: 'claude', status: 'running', exitCode: null, ...over }
}

function link(over: Partial<MachineLinkState> = {}): MachineLinkState {
  return {
    id: 'm1',
    state: 'online',
    reason: null,
    sessions: [],
    folders: null,
    capabilities: [],
    copilot: null,
    ports: [],
    hostPlatform: 'win32',
    retryAt: null,
    ...over,
  }
}

function render(device: MachineWithLink): string {
  return renderToStaticMarkup(<DeviceAccounts device={device} />)
}

describe('a device that cannot be asked', () => {
  it('says the logins are over there rather than drawing an empty list', () => {
    // An empty box under a machine's name reads as "this machine has no
    // accounts", which is a claim about somebody's PC made without asking it.
    const html = render({ machine, link: link({ state: 'offline' }) })
    expect(html).toContain('DESKTOP-DDGMNCV is not connected')
    expect(html).not.toContain('settings-profiles')
  })

  /**
   * The wiring this pane is waiting on, said out loud.
   *
   * `account.read` carries a session id and `protocol.ts` refuses one without —
   * *"account.read without a session id"* — so a machine with nothing running on
   * it is a machine there is no way to ask. That is a gap in the protocol rather
   * than in this screen, and the sentence names the thing to do about it.
   */
  it('names what is missing when the machine is connected and idle', () => {
    const html = render({ machine, link: link() })
    expect(html).toContain('read through a session running on it')
    expect(html).not.toContain('settings-profiles')
  })

  it('says it is asking, once there is a session to ask through', () => {
    // The read is an effect, which `renderToStaticMarkup` never runs — so this
    // is exactly the first paint in a real window.
    const html = render({ machine, link: link({ sessions: [session()] }) })
    expect(html).toContain('Asking DESKTOP-DDGMNCV…')
  })
})

describe('what this pane does not offer', () => {
  /**
   *   > *"So we can click and manage what accounts are there, what we want to
   *   > login, logout, things, access."*
   *
   * The protocol carries two account verbs, `account.read` and `account.switch`,
   * and both are about one session. There is no sign-in, no sign-out and no
   * access grant to call — so this draws none of the three rather than a button
   * that can only apologise.
   */
  it('draws no sign-in or sign-out control for a far machine', () => {
    const html = render({ machine, link: link({ sessions: [session()] }) })
    expect(html).not.toContain('Sign in')
    expect(html).not.toContain('Sign out')
    expect(html).not.toContain('settings-btn')
  })
})
