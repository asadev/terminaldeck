import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { DeviceAccounts, DeviceRow } from './DeviceAccounts'
import type { MachineAccount } from '../../machines/machine-account'
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
    hostVersion: '',
    hostKind: null,
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
   * The connected-and-idle case, which used to be a dead end and is now the
   * ordinary one.
   *
   * `account.read` carries a session id and `protocol.ts` refuses one without —
   * *"account.read without a session id"* — so until `CAPABILITY.logins` existed,
   * a machine with nothing running on it was a machine there was no way to ask,
   * and this pane said so in a sentence. It now asks the **machine**, so an idle
   * one is asked exactly like a busy one.
   */
  it('asks a connected machine whether or not anything is running on it', () => {
    // The read is an effect, which `renderToStaticMarkup` never runs — so this
    // is exactly the first paint in a real window, and it is the same paint
    // either way.
    expect(render({ machine, link: link() })).toContain('Asking DESKTOP-DDGMNCV…')
    expect(render({ machine, link: link({ sessions: [session()] }) })).toContain('Asking DESKTOP-DDGMNCV…')
  })

  it('no longer says a machine’s logins can only be read through a session', () => {
    // The sentence that was true when it was written, and is not any more. It is
    // asserted as an absence because leaving it on screen would send somebody to
    // start a session they no longer need.
    expect(render({ machine, link: link() })).not.toContain('read through a session running on it')
  })
})

/**
 * One login on the far machine, as a row.
 *
 * Rendered directly because the list arrives in an effect and
 * `renderToStaticMarkup` runs none — and the row is where the two things worth
 * pinning are: what it is *called*, and whether it has a control on it.
 */
describe('a login on the far machine', () => {
  const login: MachineAccount = {
    id: 'system',
    // The key `profiles.ts` mints for an agent's own install. Identical on every
    // machine, and it names nobody.
    name: 'Default',
    provider: 'claude',
    color: null,
    system: true,
    signIn: {
      state: 'signed-in',
      account: 'sherzod.davlatov@gmail.com',
      plan: 'max',
      detail: 'Signed in as sherzod.davlatov@gmail.com on the max plan.',
      command: '',
    },
  }

  function row(over: Partial<Parameters<typeof DeviceRow>[0]> = {}): string {
    return renderToStaticMarkup(
      <ul>
        <DeviceRow account={login} running={false} session="" busy={false} onSignIn={() => {}} {...over} />
      </ul>,
    )
  }

  it('is named by the login it is signed in as, never by the profile key', () => {
    const html = row()
    expect(html).toContain('sherzod.davlatov@gmail.com')
    //   > *"It is saying default, so never default. Whatever is actual account
    //   > should be visible here, never default."*
    expect(html).not.toContain('Default')
  })

  it('offers a sign-in that acts on the machine that owns the login', () => {
    expect(row()).toContain('Sign in')
  })

  it('draws no sign-in for a machine that cannot be asked to start one', () => {
    // An older build over there, or this desktop being a guest on it. A button
    // certain to be refused is not one to draw.
    expect(row({ onSignIn: null })).not.toContain('Sign in')
  })
})

describe('what this pane still does not offer', () => {
  /**
   *   > *"So we can click and manage what accounts are there, what we want to
   *   > login, logout, things, access."*
   *
   * Two of the three are here now — the list and the sign-in over
   * `CAPABILITY.logins`, and the access grant on the Remote pane. **Sign out is
   * not**, and this is the assertion that keeps it from being drawn before it
   * exists: nothing in this app signs an agent out on any machine, including
   * this one — `agent-catalog.ts` has `signInArgs` and no counterpart — so a
   * Sign out here could only apologise.
   */
  it('draws no sign-out anywhere, because nothing in this app can sign an agent out', () => {
    const html = render({ machine, link: link({ sessions: [session()] }) })
    expect(html).not.toContain('Sign out')
  })
})
