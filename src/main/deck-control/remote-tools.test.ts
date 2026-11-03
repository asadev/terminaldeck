import { beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext, ToolSpec } from './catalogue'
import type { ChannelCall } from './channel-tap'
import { remoteTools, type RemoteChannels } from './remote-tools'
import { ALL_TIERS, Refused, type Caller, type DeckSurface } from './surface'

const LOCAL: Caller = { kind: 'local', tiers: ALL_TIERS }
const PHONE: Caller = { kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS }

let calls: unknown[][] = []
let answers: Partial<Record<keyof RemoteChannels, (...args: unknown[]) => unknown>> = {}
let tools: ToolSpec[] = []

const tool = (id: string): ToolSpec => tools.find((spec) => spec.id === id) as ToolSpec
const context = (caller: Caller = LOCAL): ToolContext =>
  ({ surface: {} as DeckSurface, callId: 'row', caller, attended: true, startedByCopilot: () => false, noteStarted: () => undefined, now: () => 0 }) as ToolContext

const DEVICES = [
  { id: 'd-phone', name: 'iPhone', addedAt: 1, lastSeenAt: 2, approved: true, revoked: false, status: 'approved', fingerprint: 'F1' },
  { id: 'd-guest', name: 'Saba’s laptop', addedAt: 1, lastSeenAt: null, approved: false, revoked: false, status: 'pending', fingerprint: 'F2' },
]

beforeEach(() => {
  calls = []
  answers = {
    'remote:status': () => ({
      running: true,
      url: null,
      address: null,
      port: 0,
      reason: null,
      directReason: 'Tailscale is not signed in',
      relay: { url: 'wss://relay', hostId: 'h', publicKey: 'pk', fingerprint: 'HOST-F', connected: true, channels: 1, reason: null, retryAt: null },
      connections: [{ id: 'c1', deviceId: 'd-phone', deviceName: 'iPhone', platform: 'ios', address: 'relay', connectedAt: 5, sessionIds: ['s1'], sessions: [], tunnels: [] }],
    }),
    'remote:devices': () => DEVICES,
    'remote:kinds': () => [{ deviceId: 'd-phone', kind: 'mine', decidedAt: 1 }],
    'remote:folders': () => [],
    'remote:accounts': () => [],
    'remote:sessions': () => [],
    'remote:windows': () => ['d-phone'],
    'remote:sessions:running': () => [{ id: 's1', title: 'build', cwd: '/work', provider: 'claude', status: 'working', exitCode: null }],
    'power:lid-awake:get': () => ({ supported: true, on: false }),
    'confine:state': () => ({ platform: 'darwin', confining: true }),
    'tailnet:status': () => ({ running: false }),
    'remote:pair': () => ({ token: '135790', expiresAt: 99, findable: true }),
    'remote:device:approve': (id) => DEVICES.map((device) => (device.id === id ? { ...device, approved: true, status: 'approved' } : device)),
  }
  const call = (async (channel: keyof RemoteChannels, ...args: unknown[]) => {
    calls.push([channel, ...args])
    const answer = answers[channel]
    if (answer === undefined) throw new Error(`the test did not expect ${channel}`)
    return answer(...args)
  }) as ChannelCall<RemoteChannels>
  tools = remoteTools({ call })
})

describe('remote.status', () => {
  it('joins each device to what it may reach and whether it is connected', async () => {
    const out = (await tool('remote.status').run({}, context())).value as {
      remoteAccess: { on: boolean }
      devices: Array<Record<string, unknown>>
      keepAwake: unknown
      confinement: unknown
    }
    expect(out.remoteAccess.on).toBe(true)
    expect(out.devices[0]).toEqual(expect.objectContaining({ id: 'd-phone', kind: 'mine', connected: true, drivesWindows: true }))
    expect(out.devices[1]).toEqual(expect.objectContaining({ id: 'd-guest', status: 'pending', connected: false }))
    expect(out.confinement).toEqual({ platform: 'darwin', confining: true })
  })

  it('never brings Tailscale up unless asked, and labels it optional when it does', async () => {
    const plain = (await tool('remote.status').run({}, context())).value as Record<string, unknown>
    expect(plain.tailscale).toBeUndefined()
    expect(JSON.stringify(plain)).not.toContain('Tailscale is not signed in')
    expect(calls.some((row) => row[0] === 'tailnet:status')).toBe(false)
    const asked = (await tool('remote.status').run({ tailscale: true }, context())).value as { tailscale: { optional: boolean } }
    expect(asked.tailscale.optional).toBe(true)
  })

  it('answers only the person at this computer', () => {
    expect(() => tool('remote.status').precheck?.({}, context(PHONE))).toThrow(Refused)
  })
})

describe('remote.manage', () => {
  it('asks the real question for a guest — which folders, which logins', async () => {
    await tool('remote.status').run({}, context())
    const sentence = tool('remote.manage').summary(
      { do: 'approve', deviceId: 'd-guest', kind: 'guest', folders: ['/work/site'], loginShare: 'selected', logins: ['acct-1'] },
      context(),
    )
    expect(sentence).toContain('“Saba’s laptop”')
    expect(sentence).toContain('/work/site')
    expect(sentence).toContain('acct-1')
  })

  it('approves through the panel’s own handler, folders and logins included', async () => {
    await tool('remote.manage').run(
      { do: 'approve', deviceId: 'd-guest', kind: 'guest', folders: ['/work/site'], loginShare: 'all' },
      context(),
    )
    expect(calls).toContainEqual(['remote:device:approve', 'd-guest', 'guest', ['/work/site'], 'all', []])
  })

  it('needs folders before a guest can be approved', () => {
    expect(() => tool('remote.manage').precheck?.({ do: 'approve', deviceId: 'd-guest', kind: 'guest' }, context())).toThrow(/folders/)
  })

  it('returns a pairing code to the call that asked, and keeps it out of the record', async () => {
    const out = await tool('remote.manage').run({ do: 'show-code' }, context())
    expect((out.value as { code: string }).code).toBe('135790')
    expect(JSON.stringify(out.summary)).not.toContain('135790')
  })

  it('is alter, and refuses a paired device before a dialog', () => {
    expect(tool('remote.manage').tier).toBe('alter')
    expect(() => tool('remote.manage').precheck?.({ do: 'stop' }, context(PHONE))).toThrow(Refused)
  })

  it('says what stopping costs', () => {
    expect(tool('remote.manage').summary({ do: 'stop' }, context())).toMatch(/cut off/)
  })
})
