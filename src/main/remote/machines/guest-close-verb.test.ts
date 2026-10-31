import { describe, expect, it } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { serialize, type ServerMessage } from '../protocol'
import type { DialRequest, GuestChannel } from './dial'
import { createMachineLink, type MachineLinkState } from './guest'
import type { MachineSecrets } from './store'

/**
 * This desktop **ending** a session on another one, from the guest side of the
 * wire.
 *
 * `guest-close.test.ts`, one directory up, pins the host half: who is allowed to
 * send `close`, and the part that matters most — that a guest granted one folder
 * cannot end a session running in another, with the session layer never even
 * asked. This file is the other end of the same verb, and it exists because the
 * two failures it pins are both silent.
 *
 * ## 1. An unadvertised verb must be refused *here*
 *
 * A host that never advertised `close` answers the frame by **closing the
 * channel**. So a ✕ sent optimistically would not fail — it would disconnect the
 * machine, take every remote session on it off the screen, and reconnect a
 * second later looking like a network glitch. Measured on a real Windows PC once
 * already, for a different verb: *"`online` → `error` with the session list
 * blanked → `connecting` → `online`, 1.9 seconds, for a mistake whose entire
 * correct outcome is one line of red text."* That is why `create`, `ports` and
 * `web.open` all check before sending, and why this does too.
 *
 * ## 2. The `closed` frame is the only news this connection gets
 *
 * `server.ts` answers the device that sent `close` with `closed`, and sends
 * every *other* connected device a fresh `sessions` list — deliberately, because
 * `closed` names one device's action and `sessions` is v1. Which means the
 * connection that asked is the one that never receives the refreshed list. If
 * this end does not act on `closed`, the row stays on screen until something
 * unrelated causes a push, and on a quiet machine that is until the next
 * reconnect. The ✕ would look broken for as long as it took anybody to notice.
 */

function secrets(): MachineSecrets {
  return {
    hostId: hostIdFor(Buffer.alloc(32, 2)),
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
  }
}

interface Rig {
  link: ReturnType<typeof createMachineLink>
  states: MachineLinkState[]
  sent: string[]
  say(message: ServerMessage): void
  open(): boolean
}

/*
 * The capability list is not a parameter here, deliberately: it travels in the
 * `welcome`, which is where the link actually learns it, so passing it to the
 * builder as well would be a second source for one fact and a test that could
 * agree with itself while the code disagreed with the wire.
 */
function build(): Rig {
  const sent: string[] = []
  const states: MachineLinkState[] = []
  let live = true
  let deliver: (text: string) => void = () => {}

  const link = createMachineLink({
    id: 'machine-1',
    secrets: secrets(),
    onState: (state) => states.push(state),
    onOutput: () => {},
    onWelcome: () => {},
    baseBackoffMs: 5,
    maxBackoffMs: 10,
    dial: (request: DialRequest): Promise<GuestChannel> => {
      deliver = request.handlers.message
      const channel: GuestChannel = {
        send: (text) => {
          if (live) sent.push(text)
        },
        close: () => {
          live = false
        },
        get open(): boolean {
          return live
        },
      }
      return Promise.resolve(channel)
    },
  })

  return {
    link,
    states,
    sent,
    say: (message) => deliver(serialize(message)),
    open: () => live,
  }
}

function welcome(capabilities: string[]): ServerMessage {
  return {
    t: 'welcome',
    protocol: 1,
    deviceId: 'device-1',
    deviceName: 'This Mac',
    token: null,
    sessions: [
      { id: 's1', title: 'agent', cwd: '/tmp/p', provider: 'claude', status: 'running', exitCode: null },
      { id: 's2', title: 'other', cwd: '/tmp/p', provider: 'claude', status: 'running', exitCode: null },
    ],
    capabilities,
    hostPlatform: 'win32',
    folders: ['/tmp/p'],
  }
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

async function online(capabilities: string[]): Promise<Rig> {
  const rig = build()
  rig.link.connect()
  await settle()
  rig.say(welcome(capabilities))
  return rig
}

describe('close, from the guest side', () => {
  it('sends the frame when the machine advertised it', async () => {
    const rig = await online(['create', 'close'])
    expect(rig.link.close('s1')).toBe(true)
    expect(JSON.parse(rig.sent[rig.sent.length - 1])).toEqual({ t: 'close', id: 's1' })
    rig.link.disconnect()
  })

  it('refuses without sending anything when it did not', async () => {
    // The whole point. Sending it would have taken the channel down and every
    // remote session on that machine off the screen with it.
    const rig = await online(['create'])
    const before = rig.sent.length
    expect(rig.link.close('s1')).toBe(false)
    expect(rig.sent).toHaveLength(before)
    expect(rig.open()).toBe(true)
    rig.link.disconnect()
  })

  it('takes the row out of the list when the far machine confirms', async () => {
    const rig = await online(['create', 'close'])
    rig.link.close('s1')
    rig.say({ t: 'closed', id: 's1' })

    const latest = rig.states[rig.states.length - 1]
    expect(latest.sessions.map((session) => session.id)).toEqual(['s2'])
    rig.link.disconnect()
  })

  it('clears a refusal with it, so the sentence describes the right request', async () => {
    // A refused request prints its sentence under the group. Leaving it there
    // beside a session that has just ended describes the wrong thing — the same
    // rule `created` follows in the other direction.
    const rig = await online(['create', 'close'])
    rig.say({ t: 'error', code: 'unauthorized', message: 'That folder is not shared.' })
    expect(rig.states[rig.states.length - 1].reason).toBe('That folder is not shared.')

    rig.say({ t: 'closed', id: 's1' })
    expect(rig.states[rig.states.length - 1].reason).toBeNull()
    rig.link.disconnect()
  })

  it('is refused while the link is not online at all', async () => {
    // No welcome, so no capability list. Nothing to send it down either, and a
    // `true` here would be a window told its request left when it did not.
    const rig = build()
    expect(rig.link.close('s1')).toBe(false)
  })
})
