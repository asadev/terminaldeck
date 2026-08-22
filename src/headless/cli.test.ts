import { describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import type { Device } from '../main/remote/device-auth'
import type { DeviceKindRecord } from '../main/remote/device-kind'
import type { DeviceFolderGrant } from '../main/remote/folder-grants'
import {
  duration,
  NO_COPILOT_HERE,
  parseArgs,
  pickDevice,
  renderApproved,
  renderDevices,
  renderFolders,
  renderKindQuestion,
  renderNewDevice,
  renderNotApproved,
  renderPairCode,
  renderStatus,
  usage,
  wrap,
} from './cli'
import type { HostStatus } from './host'

const device = (patch: Partial<Device> = {}): Device => ({
  id: '11111111-1111-4111-8111-111111111111',
  name: 'Asad’s iPhone',
  addedAt: 0,
  lastSeenAt: null,
  approved: true,
  revoked: false,
  status: 'approved',
  fingerprint: 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ',
  ...patch,
})

describe('parseArgs', () => {
  it('takes the commands and nothing else', () => {
    // `deviceKind: null` is "nobody has said", which is what makes `main.ts` ask.
    expect(parseArgs(['pair'])).toEqual({ kind: 'pair', deviceKind: null })
    expect(parseArgs(['status'])).toEqual({ kind: 'status' })
    expect(parseArgs(['devices'])).toEqual({ kind: 'devices' })
    expect(parseArgs(['folders'])).toEqual({ kind: 'folders' })
    expect(parseArgs(['stop'])).toEqual({ kind: 'stop' })
  })

  it('reads revoke, by a bare name, by --device, or nothing at all', () => {
    expect(parseArgs(['revoke', 'iPhone'])).toEqual({ kind: 'revoke', device: 'iPhone' })
    expect(parseArgs(['revoke', '--device', 'iPhone'])).toEqual({ kind: 'revoke', device: 'iPhone' })
    // Bare `revoke` is allowed here; `pickDevice` decides whether a single
    // device makes the omission unambiguous.
    expect(parseArgs(['revoke'])).toEqual({ kind: 'revoke', device: null })
  })

  it('refuses revoke naming a device two ways, or two devices', () => {
    expect(parseArgs(['revoke', 'iPhone', '--device', 'iPad']).kind).toBe('error')
    expect(parseArgs(['revoke', 'iPhone', 'iPad']).kind).toBe('error')
    expect(parseArgs(['revoke', '--device']).kind).toBe('error')
  })

  it('takes no arguments to devices', () => {
    expect(parseArgs(['devices', 'extra']).kind).toBe('error')
  })

  it('prints usage for no arguments and for --help', () => {
    expect(parseArgs([])).toEqual({ kind: 'help' })
    expect(parseArgs(['--help'])).toEqual({ kind: 'help' })
  })

  it('names the commands when it does not understand one', () => {
    // A CLI that prints its whole usage because it did not understand you
    // teaches you nothing about which part it did not understand.
    const parsed = parseArgs(['restart'])
    expect(parsed.kind).toBe('error')
    if (parsed.kind !== 'error') return
    expect(parsed.message).toContain('restart')
    expect(parsed.message).toContain('pair, status, devices, revoke, browser, folders and stop')
  })

  it('refuses arguments a command does not take', () => {
    expect(parseArgs(['status', '--json']).kind).toBe('error')
  })

  it('reads folders add and remove, with and without a device', () => {
    expect(parseArgs(['folders', 'add', '/home/asad/app'])).toEqual({
      kind: 'folders-add',
      folder: '/home/asad/app',
      device: null,
    })
    expect(parseArgs(['folders', 'remove', '/home/asad/app', '--device', 'iPhone'])).toEqual({
      kind: 'folders-remove',
      folder: '/home/asad/app',
      device: 'iPhone',
    })
    expect(parseArgs(['folders', 'add', '--device', 'iPhone', '/home/asad/app'])).toEqual({
      kind: 'folders-add',
      folder: '/home/asad/app',
      device: 'iPhone',
    })
  })

  it('refuses two folders rather than joining them', () => {
    // A path with a space that arrived as two arguments is a quoting mistake,
    // and guessing at it is how a grant lands on a folder nobody meant.
    const parsed = parseArgs(['folders', 'add', '/home/asad/my', 'app'])
    expect(parsed.kind).toBe('error')
    if (parsed.kind !== 'error') return
    expect(parsed.message).toContain('Quote a path')
  })

  it('refuses --device with nothing after it', () => {
    expect(parseArgs(['folders', 'add', '/a', '--device']).kind).toBe('error')
  })
})

describe('pickDevice', () => {
  const iphone = device({ id: 'aaaa1111', name: 'Asad’s iPhone' })
  const ipad = device({ id: 'bbbb2222', name: 'Asad’s iPad' })

  it('needs no name when there is only one device', () => {
    expect(pickDevice([iphone], null)).toEqual({ ok: true, device: iphone })
  })

  it('asks which one when there are several, and lists them', () => {
    const picked = pickDevice([iphone, ipad], null)
    expect(picked.ok).toBe(false)
    if (picked.ok) return
    expect(picked.message).toContain('--device "Asad’s iPhone"')
    expect(picked.message).toContain('--device "Asad’s iPad"')
  })

  it('matches on an id prefix and on part of a name', () => {
    expect(pickDevice([iphone, ipad], 'aaaa')).toEqual({ ok: true, device: iphone })
    expect(pickDevice([iphone, ipad], 'ipad')).toEqual({ ok: true, device: ipad })
  })

  it('refuses an ambiguous match rather than taking the first', () => {
    // Two phones whose names share a word is the ordinary case in a household,
    // and granting a folder to the wrong one is not a mistake to make quietly.
    const twins = [device({ id: 'a', name: 'iPhone 12' }), device({ id: 'b', name: 'iPhone 15' })]
    const picked = pickDevice(twins, 'iphone')
    expect(picked.ok).toBe(false)
    if (picked.ok) return
    expect(picked.message).toContain('matches 2 devices')
  })

  it('lets an exact name win over a partial one', () => {
    // A device really called "iPhone" beside one called "iPhone 2" is not
    // ambiguous: the person typed the whole of one of them.
    const twins = [device({ id: 'a', name: 'iPhone' }), device({ id: 'b', name: 'iPhone 2' })]
    expect(pickDevice(twins, 'iPhone')).toEqual({ ok: true, device: twins[0] })
  })

  it('ignores revoked devices entirely', () => {
    const gone = device({ id: 'ccc', name: 'Old phone', revoked: true, status: 'revoked' })
    expect(pickDevice([iphone, gone], null)).toEqual({ ok: true, device: iphone })
    const none = pickDevice([gone], null)
    expect(none.ok).toBe(false)
  })
})

describe('renderFolders', () => {
  it('tells "nothing chosen" apart from "chosen, and empty"', () => {
    /*
     * The two behave differently the moment a project is closed: one follows
     * whatever the host has open, the other is a refusal. Printing them the same
     * way would make the fallback look like a decision somebody made.
     */
    const devices = [device({ id: 'a', name: 'Phone A' }), device({ id: 'b', name: 'Phone B' })]
    const grants: DeviceFolderGrant[] = [{ deviceId: 'b', folders: [] }]
    const text = renderFolders(devices, grants)
    expect(text).toContain('nothing chosen')
    expect(text).toContain('may not start a session anywhere')
  })

  it('lists the folders in the order they were chosen', () => {
    const grants: DeviceFolderGrant[] = [{ deviceId: 'a', folders: ['/one', '/two'] }]
    const text = renderFolders([device({ id: 'a' })], grants)
    expect(text.indexOf('/one')).toBeLessThan(text.indexOf('/two'))
  })
})

describe('renderDevices', () => {
  const kind = (deviceId: string, k: 'mine' | 'guest'): DeviceKindRecord => ({
    deviceId,
    kind: k,
    decidedAt: 0,
  })

  it('says nothing is signed in when the list is empty', () => {
    expect(renderDevices([], [], 0)).toContain('No devices are signed in')
  })

  it('shows each device with its kind, status, last seen, fingerprint and id', () => {
    const dev = device({ id: 'aaaa1111', name: 'Asad’s iPhone', lastSeenAt: 0, fingerprint: 'AAAA-BBBB' })
    const text = renderDevices([dev], [kind('aaaa1111', 'mine')], 60_000)
    expect(text).toContain('Asad’s iPhone')
    expect(text).toContain('mine')
    expect(text).toContain('approved')
    expect(text).toContain('last seen 1m ago')
    expect(text).toContain('AAAA-BBBB')
    expect(text).toContain('aaaa1111')
  })

  it('reads a device with no kind record as undecided, enforced as guest', () => {
    const dev = device({ id: 'bbbb2222', name: 'Old phone' })
    const text = renderDevices([dev], [], 0)
    expect(text).toContain('undecided, enforced as guest')
  })

  it('never lists a revoked device', () => {
    const gone = device({ id: 'ccc', name: 'Gone', revoked: true, status: 'revoked' })
    const here = device({ id: 'ddd', name: 'Here' })
    const text = renderDevices([gone, here], [], 0)
    expect(text).toContain('Here')
    expect(text).not.toContain('Gone')
  })
})

describe('renderPairCode', () => {
  const relay = status().remote.relay

  it('prints the code in the grouped form the app shows', () => {
    // The same short code and the same grouping as the desktop, because it is
    // the same mechanism — a second format would be a second thing to type
    // wrong.
    const text = renderPairCode('4K7M-92QX', 60_000, 0, relay)
    expect(text).toContain('4K7M-92QX')
    // And not re-grouped: the minted token already carries the hyphen, and
    // formatting it a second time produced `4K7M--92Q-X`.
    expect(text).not.toContain('4K7M--')
    expect(text).toContain('60 seconds')
  })

  it('tells a phone the same thing it tells a desktop: type the code', () => {
    /*
     * It used to say the opposite — that a phone needed the relay, the host id
     * and the public key as well, because the desktop handed those over inside a
     * QR code this build cannot draw. The QR is gone from the product and every
     * client looks a code up at the rendezvous now, so a sentence sending
     * somebody to find a desktop with a camera would be describing a route that
     * no longer exists.
     */
    const text = renderPairCode('482913', 60_000, 0, relay)
    expect(text).not.toContain('QR')
    expect(text).toContain('type the code')
    expect(text).toContain('host id      host-abc')
    expect(text).toContain('fingerprint  AAAA-BBBB')
  })

  it('says a code cannot be looked up at all when the relay is down', () => {
    const text = renderPairCode('482913', 60_000, 0, null)
    expect(text).toContain('not on the relay')
    expect(text).not.toContain('host id')
  })
})

describe('renderNewDevice', () => {
  it('shows the fingerprint, because it is the only checkable part', () => {
    expect(renderNewDevice(device())).toContain('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ')
  })

  it('says plainly when a device has no key rather than printing nothing', () => {
    const text = renderNewDevice(device({ fingerprint: null }))
    // The consequence, not the name of the transport that is left. "Can only be
    // reached over a tailnet" told somebody with no mesh VPN that their device
    // was unreachable, in the vocabulary of a product they do not run.
    expect(text).toContain('cannot use the relay')
    expect(text).not.toContain('tailnet')
  })
})

/**
 * The kind, which `pair` may be told and otherwise has to ask.
 *
 * The bug being pinned is that `terminaldeck pair` sent no kind at all, the
 * handler's `asDeviceKind(undefined)` answered null, and the whole approval fell
 * into the branch that decides nothing — while the command printed "Approved."
 * So there are two properties here and they are separate: that a kind can be
 * *given*, and that nothing here will invent one.
 */
describe('the device kind on `pair`', () => {
  it('takes it as an option, and only the two words', () => {
    expect(parseArgs(['pair', '--kind', 'mine'])).toEqual({ kind: 'pair', deviceKind: 'mine' })
    expect(parseArgs(['pair', '--kind', 'guest'])).toEqual({ kind: 'pair', deviceKind: 'guest' })
  })

  it('refuses a third word rather than falling back to one of the two', () => {
    // Both defaults are wrong in a way nobody would notice: `guest` strands the
    // owner's own phone, `mine` hands a stranger the copilot and every port.
    const parsed = parseArgs(['pair', '--kind', 'owner'])
    expect(parsed.kind).toBe('error')
    if (parsed.kind !== 'error') return
    expect(parsed.message).toContain('no default')
  })

  it('refuses --kind with nothing after it', () => {
    expect(parseArgs(['pair', '--kind']).kind).toBe('error')
  })

  it('still refuses an argument that is not --kind', () => {
    expect(parseArgs(['pair', '--yes']).kind).toBe('error')
  })

  it('says what both words mean, because there is no screen to show it', () => {
    const text = renderKindQuestion()
    expect(text).toContain('It’s you at another keyboard')
    expect(text).toContain('The copilot is never shared')
    // The part a screen conveys by having no control for it.
    expect(text).toContain('Nothing changes it afterwards')
  })
})

describe('what `pair` prints once the host has answered', () => {
  it('tells a guest it has no folders yet, rather than the opposite', () => {
    /*
     * The old line was printed for every approval and said the device "starts
     * with the folders this host has open". Approving a guest writes an *empty*
     * list on purpose, so that sentence sent somebody to their phone to watch a
     * session refuse to start.
     */
    const text = renderApproved(device(), 'guest', NO_COPILOT_HERE)
    expect(text).toContain('cannot start a session anywhere')
    expect(text).toContain(`${BRAND.id} folders add`)
    expect(text).not.toContain('sees whatever projects')
  })

  it('tells one of your own what it does get, and what this host has not got', () => {
    const text = renderApproved(device(), 'mine', NO_COPILOT_HERE)
    expect(text).toContain('sees whatever projects this host has open')
    expect(text).toContain('has no copilot')
  })

  it('names the recorded kind when a second approval was refused', () => {
    // The realistic refusal: a kind is written once, so re-approving a device as
    // the other one is not a change that gets made.
    const text = renderNotApproved(device(), 'mine', 'guest')
    expect(text).toContain('NOT approved')
    expect(text).toContain('already has it recorded as "guest"')
    expect(text).toContain('revoke')
  })
})

/* ------------------------------------------------------------------ status -- */

const status = (patch: Partial<HostStatus> = {}): HostStatus => ({
  version: '0.1.8',
  pid: 4242,
  startedAt: 0,
  stateDir: '/home/asad/.local/share/terminaldeck',
  platform: 'linux',
  facts: { platform: 'linux', wsl: true, distro: 'Ubuntu', battery: false, systemd: false, user: 'asad' },
  reachability: {
    kind: 'wsl',
    headline: 'At risk: systemd is not running in this distribution.',
    detail: ['WSL is not a computer that stays on.'],
    steps: ['wsl.exe --shutdown'],
    atRisk: true,
  },
  idle: {
    mode: 'idle',
    attached: 0,
    holding: ['relay connection'],
    stopped: ['session status detection'],
  },
  remote: {
    running: true,
    url: null,
    address: null,
    port: 8443,
    reason: null,
    directReason: 'This machine is not signed in to Tailscale.',
    relay: {
      url: 'wss://relay.terminaldeck.dev',
      hostId: 'host-abc',
      publicKey: 'k',
      fingerprint: 'AAAA-BBBB',
      connected: true,
      channels: 0,
      reason: null,
      retryAt: null,
    },
    connections: [],
  },
  devices: [device()],
  // Empty on purpose, so the default fixture is a device nobody has decided
  // about — which is the state every device paired before device kinds existed
  // is in, and the one the status line has to distinguish from a chosen guest.
  kinds: [],
  folders: [],
  sessions: [],
  neverRunning: ['usage polling (a window feature)'],
  // Null is what every host anybody owns answers. A test whose default was the
  // demo sentence would have every unrelated assertion running against the one
  // machine in the world this build treats differently.
  publicHost: null,
  ...patch,
})

describe('renderStatus', () => {
  it('says which mode it is in, and what it is holding', () => {
    // "An idle mode nobody can observe is indistinguishable from a bug."
    const text = renderStatus(status(), 3_600_000)
    expect(text).toContain('idle')
    expect(text).toContain('holding   relay connection')
    expect(text).toContain('stopped   session status detection')
  })

  it('lists what was never running here, so a reader who counts is not misled', () => {
    expect(renderStatus(status(), 0)).toContain('n/a       usage polling')
  })

  it('says what each device is, since a server has nowhere else to show it', () => {
    const text = renderStatus(
      status({ kinds: [{ deviceId: device().id, kind: 'mine', decidedAt: 0 }] }),
      0,
    )
    expect(text).toContain('Asad’s iPhone  —  mine,')
  })

  it('distinguishes a chosen guest from a device nobody has decided about', () => {
    // `kindOf` enforces both as `guest`. Only one of them has a remedy, and the
    // word "guest" on its own would hide which.
    const text = renderStatus(status(), 0)
    expect(text).toContain('undecided, enforced as guest')
  })

  it('prints the WSL warning where somebody will read it', () => {
    const text = renderStatus(status(), 0)
    expect(text).toContain('Staying reachable — wsl')
    expect(text).toContain('systemd is not running')
    expect(text).toContain('wsl.exe --shutdown')
  })

  it('says nothing about Tailscale while the relay is carrying the session', () => {
    /*
     * The relay is the default route: no install, no account, works from a
     * hotel wifi. Tailscale is an optional faster one. Printing "Direct: none —
     * Tailscale refused the request" under a connected relay reports the
     * absence of an optimisation nobody asked for in the wording of a fault,
     * and sends a person whose host is working to a Tailscale admin console.
     */
    const text = renderStatus(status(), 0)
    expect(text).toContain('connected      wss://relay.terminaldeck.dev')
    expect(text).not.toContain('Tailscale')
    expect(text).not.toContain('Direct')
  })

  it('prints the direct address when the tailnet is actually serving one', () => {
    const base = status()
    const text = renderStatus(
      status({
        remote: {
          ...base.remote,
          url: 'https://asads-macbook-pro.taild11505.ts.net:8443/',
          address: '100.86.107.119',
          directReason: null,
        },
      }),
      0,
    )
    expect(text).toContain('Direct')
    expect(text).toContain('https://asads-macbook-pro.taild11505.ts.net:8443/')
  })

  it('still says nothing about it when the relay is down as well', () => {
    /*
     * This was the last place the complaint survived, on the argument that with
     * nothing carrying the session the missing direct route was half the
     * diagnosis. It is not half of anything. This host has one problem — the
     * relay is not connected — and the Relay block says it in the relay's own
     * words. Adding that a mesh VPN the reader has never installed is also not
     * installed hands them a second errand, and it is the one they will run,
     * because it is the one that sounds like a cause.
     */
    const base = status()
    const text = renderStatus(
      status({
        remote: {
          ...base.remote,
          relay: { ...base.remote.relay!, connected: false, reason: 'No network.', retryAt: null },
        },
      }),
      0,
    )
    expect(text).not.toContain('Tailscale')
    expect(text).not.toContain('Direct')
    expect(text).toContain('not connected  No network.')
  })

  it('never mentions the direct route in a build with no relay at all', () => {
    // `relay: null` is a build assembled without one. What is true is that
    // nothing is dialling out; naming the transport somebody would need instead
    // is the same mistake in a quieter place.
    const base = status()
    const text = renderStatus(status({ remote: { ...base.remote, relay: null } }), 0)
    expect(text).toContain('off — this host is not dialling out')
    expect(text).not.toContain('tailnet')
    expect(text).not.toContain('Tailscale')
  })

  it('says why nothing is serving when nothing is', () => {
    const text = renderStatus(
      status({ remote: { ...status().remote, running: false, reason: 'The relay refused the host key.' } }),
      0,
    )
    expect(text).toContain('not serving')
    expect(text).toContain('The relay refused the host key.')
  })

  it('reports a relay that is down with its reason and its next attempt', () => {
    const base = status()
    const text = renderStatus(
      status({
        remote: {
          ...base.remote,
          relay: { ...base.remote.relay!, connected: false, reason: 'No network.', retryAt: 30_000 },
        },
      }),
      0,
    )
    expect(text).toContain('not connected  No network.')
    expect(text).toContain('retrying in    30s')
  })
})

describe('formatting', () => {
  it('gives a duration one unit and rounds down', () => {
    expect(duration(0)).toBe('0s')
    expect(duration(59_999)).toBe('59s')
    expect(duration(90_000)).toBe('1m')
    expect(duration(3 * 3_600_000 + 41 * 60_000)).toBe('3h')
    expect(duration(3 * 86_400_000)).toBe('3d')
    // A negative gap is a clock disagreement between two processes, not a
    // reason to print "-4s".
    expect(duration(-5000)).toBe('0s')
  })

  it('wraps prose without losing a word', () => {
    const text = 'one two three four five six seven eight'
    const lines = wrap(text, 12)
    expect(lines.join(' ')).toBe(text)
    expect(lines.every((line) => line.length <= 12)).toBe(true)
  })
})

describe('usage', () => {
  it('offers the four commands and the host binary, and nothing more', () => {
    const text = usage()
    for (const command of ['pair', 'status', 'folders', 'stop']) {
      expect(text).toContain(`${BRAND.id} ${command}`)
    }
    expect(text).toContain(`${BRAND.id}-host`)
  })
})
