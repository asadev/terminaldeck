import type { Device } from '../remote/device-auth'
import type { DeviceKindRecord } from '../remote/device-kind'
import type { DeviceFolderGrant } from '../remote/folder-grants'
import type { DeviceAccountGrant } from '../remote/account-grants'
import type { DeviceSessionGrant } from '../remote/session-grants'
import type { RemoteSession } from '../remote/protocol'
import type { RemoteStatus, ShownPairingCode } from '../remote/server'
import { bool, hereOnly, oneOf, optBool, str, strList, verbOf } from './area-shared'
import { BadArgument, type ToolOutput, type ToolSpec } from './catalogue'
import type { ChannelCall } from './channel-tap'
import { Refused } from './surface'

/**
 * Who may reach **this** computer from somewhere else, and on what terms.
 *
 * ## The other direction from `machine-tools.ts`
 *
 * That file is the computers this one dials *out* to. This one is the phones,
 * tablets and other computers that dial *in* — paired with a code shown here,
 * approved as the owner's own or as a guest, and held to the folders, sessions,
 * logins and browser windows somebody chose for them. It is the Remote panel in
 * Settings, as two tools:
 *
 *  - **`remote.status`** — read. Whether remote access is on and connected,
 *    every device and everything each may reach, who is connected now, which of
 *    this computer's sessions they are offered, and the two things that decide
 *    whether this computer is *there* to be reached: whether it stays awake, and
 *    whether sessions started from a device are held to their folder.
 *  - **`remote.manage`** — alter, every verb. Turning access on and off, showing
 *    a pairing code, approving and revoking a device, and widening or narrowing
 *    what one may reach. Each of those is a grant or the withdrawal of one, which
 *    is the line `alter` exists to hold.
 *
 * ## Why the switch is here when `settings.write` refuses it
 *
 * `catalogue.ts` refuses the `remote.` settings outright, and its reason is the
 * dialog: *"a dialog reading 'change one setting' looks identical whether the
 * setting is the theme or the thing that decides whether dialogs appear at
 * all."* That argument is about a generic tool with a generic sentence. These
 * verbs each have their own sentence — *"Turn remote access off: every phone and
 * computer connected to this one is cut off"* — so the person is asked the real
 * question, by name, and the protected key list is not routed around: it is not
 * a setting being written, it is the Remote panel's own button being pressed,
 * through the same handler.
 *
 * What stays refused is the copilot's **own** permissions. Nothing here touches
 * what the copilot may do — `remote:copilot` grants are not in this file, and
 * the server grant is skipped in the checklist for that reason.
 *
 * ## Tailscale
 *
 * Never needed. The relay is how devices reach this computer. `tailnet:status`
 * is reported only when asked for, labelled as the optional direct route it is,
 * and its absence is never a problem worth a sentence.
 */

export type RemoteChannels = {
  'remote:status': { args: []; result: RemoteStatus }
  'remote:devices': { args: []; result: Device[] }
  'remote:kinds': { args: []; result: DeviceKindRecord[] }
  'remote:folders': { args: []; result: DeviceFolderGrant[] }
  'remote:accounts': { args: []; result: DeviceAccountGrant[] }
  'remote:sessions': { args: []; result: DeviceSessionGrant[] }
  'remote:sessions:running': { args: []; result: RemoteSession[] }
  'remote:windows': { args: []; result: string[] }
  'power:lid-awake:get': { args: []; result: unknown }
  'confine:state': { args: []; result: unknown }
  'tailnet:status': { args: [boolean]; result: unknown }
  'remote:start': { args: []; result: RemoteStatus }
  'remote:stop': { args: []; result: RemoteStatus }
  'remote:pair': { args: []; result: ShownPairingCode }
  'remote:pair:cancel': { args: []; result: unknown }
  'remote:device:approve': { args: [string, string, string[], string, string[]]; result: Device[] }
  'remote:device:revoke': { args: [string]; result: Device[] }
  'remote:folders:set': { args: [string, string[]]; result: DeviceFolderGrant[] }
  'remote:accounts:set': { args: [string, string, string[]]; result: DeviceAccountGrant[] }
  'remote:sessions:set': { args: [string, string, string[]]; result: DeviceSessionGrant[] }
  'remote:windows:set': { args: [string, boolean]; result: string[] }
  'remote:connection:disconnect': { args: [string]; result: unknown[] }
  'remote:tunnel:stop': { args: [string, string]; result: unknown[] }
  'power:lid-awake:set': { args: [boolean]; result: unknown }
}

export interface RemoteToolsDeps {
  call: ChannelCall<RemoteChannels>
}

const MANAGE_VERBS = [
  'start',
  'stop',
  'show-code',
  'cancel-code',
  'approve',
  'revoke',
  'set-folders',
  'set-accounts',
  'set-sessions',
  'set-windows',
  'disconnect',
  'stop-tunnel',
  'keep-awake',
] as const
type ManageVerb = (typeof MANAGE_VERBS)[number]

const NEEDS_DEVICE: readonly ManageVerb[] = ['approve', 'revoke', 'set-folders', 'set-accounts', 'set-sessions', 'set-windows']
const SHARES = ['all', 'selected'] as const
const KINDS = ['mine', 'guest'] as const

/** One device and everything it may reach, joined — the panel's row, as a tool reads it. */
export function deviceRows(input: {
  devices: readonly Device[]
  kinds: readonly DeviceKindRecord[]
  folders: readonly DeviceFolderGrant[]
  accounts: readonly DeviceAccountGrant[]
  sessions: readonly DeviceSessionGrant[]
  windows: readonly string[]
  connectedIds: ReadonlySet<string>
}): Array<Record<string, unknown>> {
  return input.devices.map((device) => {
    const kind = input.kinds.find((row) => row.deviceId === device.id)?.kind ?? null
    const accounts = input.accounts.find((row) => row.deviceId === device.id)
    const sessions = input.sessions.find((row) => row.deviceId === device.id)
    return {
      id: device.id,
      name: device.name,
      status: device.status,
      kind,
      connected: input.connectedIds.has(device.id),
      lastSeenAt: device.lastSeenAt,
      fingerprint: device.fingerprint,
      // What a guest is held to. An owner's own device ("mine") is not held to
      // folders at all, and saying `[]` for it would read as "no folders".
      ...(kind === 'guest'
        ? {
            folders: input.folders.find((row) => row.deviceId === device.id)?.folders ?? [],
            logins: accounts === undefined ? null : { share: accounts.mode, ids: accounts.accounts },
          }
        : {}),
      sessions: sessions === undefined ? null : { share: sessions.mode, ids: sessions.sessions },
      drivesWindows: input.windows.includes(device.id),
    }
  })
}

export function remoteTools(deps: RemoteToolsDeps): ToolSpec[] {
  let lastDevices: Device[] | null = null

  const nameOf = (deviceId: string): string => {
    const name = lastDevices?.find((device) => device.id === deviceId)?.name
    return name === undefined ? `the device ${deviceId}` : `“${name}”`
  }

  const knownIfListed = (deviceId: string): void => {
    if (lastDevices === null || lastDevices.some((device) => device.id === deviceId)) return
    throw new Refused('not-permitted', `There is no device ${deviceId} paired with this computer. remote.status lists them.`)
  }

  const requireDevice = async (deviceId: string): Promise<void> => {
    lastDevices = await deps.call('remote:devices')
    knownIfListed(deviceId)
  }

  /* ---------------------------------------------------------- status ------ */

  const status: ToolSpec = {
    id: 'remote.status',
    wire: 'remote_status',
    tier: 'read',
    title: 'Who can reach this computer',
    description:
      'Remote access to this computer: whether it is on and connected to the relay, every phone and computer ' +
      'paired with it (as the owner’s own, or a guest), what each may reach — folders, sessions, agent logins, ' +
      'browser windows — who is connected right now and what they have open, the sessions here that devices are ' +
      'offered, whether this computer is kept awake, and whether sessions started from a device are held to their ' +
      'folder. Set tailscale true to include the optional Tailscale direct route, which this app never needs.',
    index: 'Who can reach this computer: remote access, paired phones and computers, who is connected.',
    inputSchema: {
      type: 'object',
      properties: { tailscale: { type: 'boolean', description: 'Also report the optional Tailscale route. Default false.' } },
      additionalProperties: false,
    },
    precheck: (_args, context) => hereOnly(context.caller, 'Reading who can reach this computer'),
    summary: () => 'Read who can reach this computer',
    run: async (args): Promise<ToolOutput> => {
      const [remote, devices, kinds, folders, accounts, sessions, windows, offered, awake, confinement] = await Promise.all([
        deps.call('remote:status'),
        deps.call('remote:devices'),
        deps.call('remote:kinds'),
        deps.call('remote:folders'),
        deps.call('remote:accounts'),
        deps.call('remote:sessions'),
        deps.call('remote:windows'),
        deps.call('remote:sessions:running'),
        deps.call('power:lid-awake:get'),
        deps.call('confine:state'),
      ])
      lastDevices = devices
      const rows = deviceRows({
        devices,
        kinds,
        folders,
        accounts,
        sessions,
        windows,
        connectedIds: new Set(remote.connections.map((connection) => connection.deviceId)),
      })
      const tailscale = optBool(args, 'tailscale', false) ? await deps.call('tailnet:status', false) : undefined
      return {
        value: {
          remoteAccess: {
            on: remote.running,
            why: remote.reason,
            relay: remote.relay === null ? null : { connected: remote.relay.connected, why: remote.relay.reason, fingerprint: remote.relay.fingerprint },
          },
          devices: rows,
          connections: remote.connections.map((connection) => ({
            id: connection.id,
            deviceId: connection.deviceId,
            device: connection.deviceName,
            platform: connection.platform,
            connectedAt: connection.connectedAt,
            sessions: connection.sessionIds,
            tunnels: connection.tunnels,
          })),
          offeredSessions: offered,
          keepAwake: awake,
          confinement,
          ...(tailscale === undefined ? {} : { tailscale: { optional: true, status: tailscale } }),
        },
        summary: { on: remote.running, devices: rows.length, connected: remote.connections.length },
      }
    },
  }

  /* ---------------------------------------------------------- manage ------ */

  const manage: ToolSpec = {
    id: 'remote.manage',
    wire: 'remote_manage',
    tier: 'alter',
    title: 'Change who can reach this computer',
    description:
      'Grant, narrow or take away remote access to this computer. Every call asks the person first. do: "start" / ' +
      '"stop" remote access as a whole (stop cuts off every connected device); "show-code" puts a six-digit pairing ' +
      'code on this computer for a phone or computer to type (returned; single-use, minutes long) and ' +
      '"cancel-code" withdraws it; "approve" a waiting device (kind "mine" for the owner’s own, or "guest" with ' +
      'folders and loginShare/logins); "revoke" a device; "set-folders" (a guest’s folders), "set-accounts" ' +
      '(loginShare all or selected, logins), "set-sessions" (sessionShare all or selected, sessions), ' +
      '"set-windows" (allowed) change what one device may reach; "disconnect" one connection now; "stop-tunnel" ' +
      'one port a connection opened; "keep-awake" (on) keeps this computer from sleeping with the lid closed — ' +
      'turning it on shows macOS’s own administrator password prompt on this computer’s screen.',
    index:
      'Turn remote access on or off, pair, approve or revoke a device, or change what it may reach.',
    inputSchema: {
      type: 'object',
      properties: {
        do: { type: 'string', enum: [...MANAGE_VERBS] },
        deviceId: { type: 'string', description: 'approve, revoke and the set- verbs. From remote.status.' },
        kind: { type: 'string', enum: [...KINDS], description: 'approve.' },
        folders: { type: 'array', items: { type: 'string' }, description: 'approve (guest) and set-folders: absolute folders on this computer.' },
        loginShare: { type: 'string', enum: [...SHARES], description: 'approve (guest) and set-accounts.' },
        logins: { type: 'array', items: { type: 'string' }, description: 'Login ids, when loginShare is selected.' },
        sessionShare: { type: 'string', enum: [...SHARES], description: 'set-sessions.' },
        sessions: { type: 'array', items: { type: 'string' }, description: 'Session ids, when sessionShare is selected.' },
        allowed: { type: 'boolean', description: 'set-windows.' },
        connectionId: { type: 'string', description: 'disconnect and stop-tunnel.' },
        tunnelId: { type: 'string', description: 'stop-tunnel.' },
        on: { type: 'boolean', description: 'keep-awake.' },
      },
      required: ['do'],
      additionalProperties: false,
    },
    /*
     * Asked every time, for every caller — including an AI app whose key is set
     * not to ask. This tool changes *who can reach this computer*: it mints
     * pairing codes and approves devices as the owner's own. An outside app
     * that could do that without a question could hand itself, or anybody, a
     * paired device with full copilot access — a way in that outlives its key
     * being revoked. `COPILOT-REMOTE.md` §5 rule 9: the approval at this
     * keyboard is the only door, and from a key it is his answer, on his Mac or
     * his phone. See `ToolSpec.ownerMustAnswer`.
     */
    ownerMustAnswer: () => true,
    precheck: (args, context) => {
      hereOnly(context.caller, 'Changing who can reach this computer')
      const verb = oneOf(args, 'do', MANAGE_VERBS)
      if (NEEDS_DEVICE.includes(verb)) knownIfListed(str(args, 'deviceId'))
      if (verb === 'approve') {
        if (oneOf(args, 'kind', KINDS) === 'guest') {
          strList(args, 'folders')
          oneOf(args, 'loginShare', SHARES)
        }
      }
      if (verb === 'set-folders') strList(args, 'folders')
      if (verb === 'set-accounts') oneOf(args, 'loginShare', SHARES)
      if (verb === 'set-sessions') oneOf(args, 'sessionShare', SHARES)
      if (verb === 'set-windows') bool(args, 'allowed')
      if (verb === 'disconnect' || verb === 'stop-tunnel') str(args, 'connectionId')
      if (verb === 'stop-tunnel') str(args, 'tunnelId')
      if (verb === 'keep-awake') bool(args, 'on')
    },
    summary: (args) => {
      const device = nameOf(typeof args.deviceId === 'string' ? args.deviceId : '?')
      const list = (key: string): string => (Array.isArray(args[key]) && args[key].length > 0 ? (args[key] as string[]).join(', ') : 'none')
      switch (verbOf(args) as ManageVerb) {
        case 'start':
          return 'Turn remote access on, so paired phones and computers can reach this one'
        case 'stop':
          return 'Turn remote access off: every phone and computer connected to this one is cut off'
        case 'show-code':
          return 'Show a pairing code on this computer, so a new phone or computer can be paired with it'
        case 'cancel-code':
          return 'Withdraw the pairing code on screen'
        case 'approve':
          return args.kind === 'mine'
            ? `Approve ${device} as the owner’s own device: it can reach everything this computer offers`
            : `Approve ${device} as a guest: it may start sessions only in ${list('folders')}, using ${args.loginShare === 'all' ? 'every login' : `the logins ${list('logins')}`}`
        case 'revoke':
          return `Revoke ${device}: it is disconnected and can no longer reach this computer`
        case 'set-folders':
          return `Let ${device} start sessions in: ${list('folders')}`
        case 'set-accounts':
          return args.loginShare === 'all' ? `Let ${device} use every agent login` : `Let ${device} use only the logins: ${list('logins')}`
        case 'set-sessions':
          return args.sessionShare === 'all' ? `Let ${device} see every session` : `Let ${device} see only the sessions: ${list('sessions')}`
        case 'set-windows':
          return args.allowed === true ? `Let ${device} drive browser windows here` : `Stop ${device} driving browser windows here`
        case 'disconnect':
          return `Disconnect the connection ${String(args.connectionId)} now (the device may reconnect)`
        case 'stop-tunnel':
          return `Stop the port ${String(args.tunnelId)} that connection ${String(args.connectionId)} opened`
        case 'keep-awake':
          return args.on === true
            ? 'Keep this computer awake with the lid closed (macOS will ask for the administrator password here)'
            : 'Let this computer sleep with the lid closed again'
        default:
          return 'Change remote access'
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const verb = oneOf(args, 'do', MANAGE_VERBS)
      if (NEEDS_DEVICE.includes(verb)) await requireDevice(str(args, 'deviceId'))
      const deviceId = typeof args.deviceId === 'string' ? args.deviceId : ''
      const list = (key: string): string[] => (args[key] === undefined ? [] : strList(args, key))

      switch (verb) {
        case 'start':
        case 'stop': {
          const after = await deps.call(verb === 'start' ? 'remote:start' : 'remote:stop')
          return { value: { on: after.running, why: after.reason }, summary: { on: after.running } }
        }
        case 'show-code': {
          const shown = await deps.call('remote:pair')
          return {
            value: {
              code: shown.token,
              expiresAt: shown.expiresAt,
              findable: shown.findable,
              note: shown.findable
                ? 'Type this into the app on the new phone or computer. It works once.'
                : 'The code could not be published to the relay, so only a device on this computer’s own network can use it.',
            },
            // A door for the next few minutes; the log outlives them.
            summary: { shown: true, findable: shown.findable },
          }
        }
        case 'cancel-code':
          await deps.call('remote:pair:cancel')
          return { value: { cancelled: true }, summary: { cancelled: true } }
        case 'approve': {
          const kind = oneOf(args, 'kind', KINDS)
          const after = await deps.call(
            'remote:device:approve',
            deviceId,
            kind,
            kind === 'guest' ? strList(args, 'folders') : [],
            kind === 'guest' ? oneOf(args, 'loginShare', SHARES) : 'all',
            kind === 'guest' ? list('logins') : [],
          )
          lastDevices = after
          const device = after.find((row) => row.id === deviceId)
          if (device?.status !== 'approved') {
            throw new Refused('not-permitted', `${nameOf(deviceId)} was not approved. It may already have been decided, or revoked.`)
          }
          return { value: { device }, summary: { deviceId, kind } }
        }
        case 'revoke': {
          const after = await deps.call('remote:device:revoke', deviceId)
          lastDevices = after
          return { value: { device: after.find((row) => row.id === deviceId) ?? null }, summary: { deviceId } }
        }
        case 'set-folders': {
          const after = await deps.call('remote:folders:set', deviceId, strList(args, 'folders'))
          return { value: { folders: after.find((row) => row.deviceId === deviceId)?.folders ?? [] }, summary: { deviceId } }
        }
        case 'set-accounts': {
          const after = await deps.call('remote:accounts:set', deviceId, oneOf(args, 'loginShare', SHARES), list('logins'))
          return { value: { logins: after.find((row) => row.deviceId === deviceId) ?? null }, summary: { deviceId } }
        }
        case 'set-sessions': {
          const after = await deps.call('remote:sessions:set', deviceId, oneOf(args, 'sessionShare', SHARES), list('sessions'))
          return { value: { sessions: after.find((row) => row.deviceId === deviceId) ?? null }, summary: { deviceId } }
        }
        case 'set-windows': {
          const allowed = bool(args, 'allowed')
          const after = await deps.call('remote:windows:set', deviceId, allowed)
          return { value: { drivesWindows: after.includes(deviceId) }, summary: { deviceId, allowed } }
        }
        case 'disconnect': {
          const after = await deps.call('remote:connection:disconnect', str(args, 'connectionId'))
          return { value: { connectionsLeft: after.length }, summary: { connectionId: str(args, 'connectionId') } }
        }
        case 'stop-tunnel': {
          await deps.call('remote:tunnel:stop', str(args, 'connectionId'), str(args, 'tunnelId'))
          return { value: { stopped: true }, summary: { connectionId: str(args, 'connectionId'), tunnelId: str(args, 'tunnelId') } }
        }
        case 'keep-awake': {
          const on = bool(args, 'on')
          return { value: await deps.call('power:lid-awake:set', on), summary: { on } }
        }
        default:
          throw new BadArgument(`do must be one of: ${MANAGE_VERBS.join(', ')}`)
      }
    },
  }

  return [status, manage]
}

export const REMOTE_TOOL_IDS = ['remote.status', 'remote.manage'] as const
