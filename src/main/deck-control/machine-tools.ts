import type { ProviderId } from '../../shared/types'
import { MACHINES_STATE_CHANNEL, type MachinesView } from '../remote/machines/ipc'
import type { PairResult } from '../remote/machines/pair'
import { CONTROL_IDS, MAX_URL_LENGTH, type RemoteSession } from '../remote/protocol'
import {
  bool,
  hereOnly,
  int,
  KEY_NAMES,
  keysFrom,
  pressKeys,
  typeLine,
  oneOf,
  optBool,
  optStr,
  sendableFile,
  str,
  strList,
  verbOf,
} from './area-shared'
import { BadArgument, sanitizeSendText, type ToolContext, type ToolOutput, type ToolSpec } from './catalogue'
import type { ChannelCall, ChannelTap } from './channel-tap'
import type { MachineWatch } from './machine-watch'
import { Refused, type Tier } from './surface'
import { BRAND } from '../../shared/brand'

/**
 * The other computers this app is paired to, driven from a tool.
 *
 * ## What "a machine" is here
 *
 * Another copy of this app — a desktop, or the headless host on a server — that
 * **this** desktop dials out to over the relay. Not a phone that dials *in*:
 * those are devices, and `remote-tools.ts` has them. The Machines list in the
 * sidebar is exactly this list, and every tool here reaches it through the same
 * channels that list's buttons call (`channel-tap.ts` says why that is the
 * whole design rather than a shortcut).
 *
 * ## Six tools, sorted by what a person would be risking
 *
 *  - **`machines.look`** — read. Which machines, whether each is up, what is
 *    running on it; one machine's host, logins and GitHub; one session's screen,
 *    model, login and usage.
 *  - **`machines.session`** — start, type into, stop, rename and retune one
 *    session over there. `act` for a session the copilot started; `alter` for
 *    anybody else's — the same line `sessions.send` and `sessions.stop` draw on
 *    this machine, for the same reason: *"that session is theirs and they may be
 *    mid-thought in it."*
 *  - **`machines.copilot`** — talk to that machine's own copilot, when it shares
 *    one with this desktop. It answers with that machine's tools under that
 *    machine's consent; nothing here widens what it may do.
 *  - **`machines.ports`** — what that machine is serving, an address for it here,
 *    and opening a page in its browser.
 *  - **`machines.upload`** — send a file there. `alter`: a file leaving this
 *    computer is read by a person first.
 *  - **`machines.manage`** — pair, forget, rename, connect, the window grant,
 *    its host, its logins and its GitHub. All `alter`: each changes what that
 *    machine can do or what this one knows.
 *
 * Six definitions rather than forty, for the reason `servers/tools.ts` gives for
 * its three: every definition is a standing cost on every turn, and a closed
 * `do` list is checked in one place and harder to widen by accident than near-
 * identical specs. Every one of them carries an `index` line, so the standing
 * cost is six sentences.
 *
 * ## What never comes back
 *
 * `machines:pair` answers the window with the new **guest private key** and the
 * **bearer credential** that machine issued. Both belong to the machine store and
 * to nothing else, so `pair` here answers the machine's name and its fingerprint
 * and drops the rest on the floor — the narrowing `MachineLinked` already makes
 * for the server connector, and for the same reason.
 *
 * A pairing code *shown* for another computer to type is returned: it is six
 * digits, single-use, gone in minutes, and the whole point of it is that a person
 * reads it out. The rule this layer holds to is about long-lived secrets.
 */

/* ------------------------------------------------------------ the wire --- */

type Ok = { ok: boolean; message: string }
type Switched = { ok: boolean; message: string; session: string | null }

/** Every channel these tools may reach, and its shape. Nothing outside this list. */
export type MachineChannels = {
  'machines:list': { args: []; result: MachinesView }
  'machines:host:read': { args: [string]; result: unknown }
  'machines:logins:read': { args: [string]; result: unknown }
  'machines:github:read': { args: [string]; result: unknown }
  'machines:controls:read': { args: [string, string]; result: unknown }
  'machines:account:read': { args: [string, string]; result: unknown }
  'machines:usage:read': { args: [string, string, 'plan' | 'context', boolean]; result: unknown }
  'machines:create': { args: [string, string, string]; result: boolean }
  'machines:send': { args: [string, string, string]; result: Ok }
  'machines:close': { args: [string, string]; result: boolean }
  'machines:session:rename': { args: [string, string, string]; result: boolean }
  'machines:attach': { args: [string, string, number, number]; result: boolean }
  'machines:controls:apply': { args: [string, string, string, string]; result: unknown }
  'machines:account:switch': { args: [string, string, string]; result: Switched }
  'machines:copilot:attach': { args: [string]; result: Ok }
  'machines:copilot:start': { args: [string]; result: Ok }
  'machines:copilot:refresh': { args: [string]; result: Ok }
  'machines:copilot:say': { args: [string, string]; result: Ok }
  'machines:ports': { args: [string]; result: boolean }
  'machines:reach': { args: [string, number]; result: unknown }
  'machines:reach:close': { args: [string, number]; result: boolean }
  'machines:open': { args: [string, string]; result: boolean }
  'machines:upload': { args: [string, string, string]; result: unknown }
  'machines:upload:cancel': { args: [string]; result: boolean }
  'machines:code': { args: []; result: { ok: true; code: { token: string; expiresAt: number } } | { ok: false; message: string } }
  'machines:code:cancel': { args: []; result: unknown }
  'machines:pair': { args: [string]; result: PairResult }
  'machines:forget': { args: [string]; result: MachinesView }
  'machines:connect': { args: [string]; result: MachinesView }
  'machines:disconnect': { args: [string]; result: MachinesView }
  'machines:rename': { args: [string, string]; result: MachinesView }
  'machines:drive-windows': { args: [string, boolean]; result: MachinesView }
  'machines:host:restart': { args: [string]; result: unknown }
  'machines:host:stop': { args: [string]; result: unknown }
  'machines:logins:signin': { args: [string, string]; result: Switched }
  'machines:logins:signout': { args: [string, string]; result: Switched }
  'machines:github:connect': { args: [string]; result: unknown }
  'machines:github:cancel': { args: [string]; result: unknown }
  'machines:github:disconnect': { args: [string]; result: unknown }
}

export interface MachineToolsDeps {
  call: ChannelCall<MachineChannels>
  /** The next `machines:state` push that passes `matches`, waited for around `after`. */
  nextState: (matches: (view: MachinesView) => boolean, ceilingMs: number, after: () => unknown) => Promise<MachinesView | null>
  watch: MachineWatch
  /** This app's own data folder, which no file is ever sent out of. */
  userData(): string
}

/** Build the state waiter from a tap — the one place the push's shape is trusted. */
export function stateWaiter(tap: Pick<ChannelTap, 'nextPush'>): MachineToolsDeps['nextState'] {
  return async (matches, ceilingMs, after) =>
    (await tap.nextPush(
      MACHINES_STATE_CHANNEL,
      (payload) => isView(payload) && matches(payload),
      ceilingMs,
      after,
    )) as MachinesView | null
}

function isView(value: unknown): value is MachinesView {
  return typeof value === 'object' && value !== null && Array.isArray((value as MachinesView).machines)
}

/* ------------------------------------------------------------- limits ---- */

/** How long `start` waits for the new session to appear in that machine's list. */
export const START_WAIT_MS = 15_000
/** How long a ports refresh waits for that machine to answer. */
const PORTS_WAIT_MS = 6_000
/** How long `copilot read` waits for the conversation to arrive after subscribing. */
const CHAT_WAIT_MS = 3_000
/** Longest a `say` may wait for the far copilot's answer. */
export const MAX_REPLY_WAIT_S = 120
/** Messages of the far conversation returned by default, newest last. */
const DEFAULT_MESSAGES = 20
const MAX_MESSAGES_BACK = 100
/** A remote screen opened by `watch`. The same starting shape a copilot-started local session gets. */
const WATCH_COLS = 120
const WATCH_ROWS = 30

/** The key under which a session over there is remembered as the copilot's own. */
export function startedKey(machineId: string, sessionId: string): string {
  return `machine:${machineId}:${sessionId}`
}

const AGENTS: readonly ProviderId[] = ['claude', 'codex', 'gemini', 'shell']

/* ---------------------------------------------------------- the views ---- */

/**
 * One machine, as a tool reads it: the stored row joined to its live link.
 *
 * Joined here because the window does the same join and an agent should not
 * have to: `machines` and `links` are two parallel lists keyed by id, and a model
 * handed both will sooner or later read one machine's state off the other's row.
 */
export function machineRows(
  view: MachinesView,
  mine: (machineId: string, sessionId: string) => boolean = () => false,
): Array<Record<string, unknown>> {
  return view.machines.map((machine) => {
    const link = view.links.find((row) => row.id === machine.id)
    return {
      id: machine.id,
      name: machine.name,
      platform: machine.platform,
      state: link?.state ?? 'offline',
      online: link?.state === 'online',
      why: link?.reason ?? null,
      sessions: (link?.sessions ?? []).map((session) => ({
        ...sessionRow(session),
        startedByYou: mine(machine.id, session.id),
      })),
      // Null and [] differ, and the difference is a remedy: null is a machine
      // that never said; [] is one where somebody chose no folders for this one.
      folders: link?.folders ?? null,
      ports: link?.ports ?? [],
      sharesCopilot: (link?.copilot ?? null) !== null,
      hostVersion: link?.hostVersion ?? '',
      lastConnectedAt: machine.lastConnectedAt,
    }
  })
}

function sessionRow(session: RemoteSession): Record<string, unknown> {
  return {
    id: session.id,
    title: session.title,
    folder: session.cwd,
    agent: session.provider,
    status: session.status,
    exitCode: session.exitCode,
  }
}

function sessionsOf(view: MachinesView, machineId: string): RemoteSession[] {
  return view.links.find((row) => row.id === machineId)?.sessions ?? []
}

/* ---------------------------------------------------------- the tools ---- */

export function machineTools(deps: MachineToolsDeps): ToolSpec[] {
  /**
   * The last list this layer read, kept so a synchronous `precheck` and
   * `summary` can name a machine and refuse an id that is not one — before a
   * dialog asks a person about a computer that does not exist.
   */
  let lastView: MachinesView | null = null

  const view = async (): Promise<MachinesView> => {
    lastView = await deps.call('machines:list')
    return lastView
  }

  const nameOf = (machineId: string): string =>
    lastView?.machines.find((machine) => machine.id === machineId)?.name ?? machineId

  /** An id this app has no row for, refused — when there is a list to check it against. */
  const knownIfListed = (machineId: string): void => {
    if (lastView === null) return
    if (!lastView.machines.some((machine) => machine.id === machineId)) {
      throw new Refused(
        'not-permitted',
        `There is no machine with the id ${machineId} in this app. Use machines.look to see the machines it is paired to.`,
      )
    }
  }

  const requireMachine = async (machineId: string): Promise<MachinesView> => {
    const now = await view()
    if (!now.machines.some((machine) => machine.id === machineId)) {
      throw new Refused(
        'not-permitted',
        `There is no machine with the id ${machineId} in this app. Use machines.look to see the machines it is paired to.`,
      )
    }
    return now
  }

  const requireSession = async (machineId: string, sessionId: string): Promise<RemoteSession> => {
    const now = await requireMachine(machineId)
    const found = sessionsOf(now, machineId).find((session) => session.id === sessionId)
    if (found === undefined) {
      throw new Refused(
        'not-permitted',
        `${nameOf(machineId)} has no session ${sessionId} that this computer can see. Use machines.look with that ` +
          'machineId to list its sessions.',
      )
    }
    return found
  }

  /** A link that refused, turned into a refusal the log keeps apart from a crash. */
  const okOr = (answer: { ok: boolean; message: string }): void => {
    if (!answer.ok) throw new Refused('not-permitted', answer.message)
  }

  /* ---------------------------------------------------------- look -------- */

  const look: ToolSpec = {
    id: 'machines.look',
    wire: 'machines_look',
    tier: 'read',
    title: 'Look at the other computers',
    description:
      'The other computers this app is paired to and reaches out to over the internet (other copies of this ' +
      'app, on desktops or servers). With no arguments: every one, whether it is connected, and the sessions ' +
      'running on it. With machineId: that computer in detail — its host, the agent logins it has and its GitHub ' +
      'connection. With machineId and sessionId: one session over there — its screen if this computer is ' +
      'watching it, its model and effort, which login it runs as, and its plan usage and context. Call this ' +
      'first: every other machines tool takes ids from it.',
    index:
      'Other paired computers: which are online, their sessions, and one remote session’s screen and settings. Call first.',
    inputSchema: {
      type: 'object',
      properties: {
        machineId: { type: 'string', description: 'Which computer. Omit to list them all.' },
        sessionId: { type: 'string', description: 'One session on that computer, from its sessions list.' },
      },
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Looking at the other computers')
      if (optStr(args, 'sessionId') !== null) str(args, 'machineId')
    },
    summary: (args) => {
      const machineId = optStr(args, 'machineId')
      const sessionId = optStr(args, 'sessionId')
      if (machineId === null) return 'List the other computers this app is paired to'
      return sessionId === null
        ? `Look at ${nameOf(machineId)}`
        : `Look at session ${sessionId} on ${nameOf(machineId)}`
    },
    run: async (args, context): Promise<ToolOutput> => {
      const machineId = optStr(args, 'machineId')
      const sessionId = optStr(args, 'sessionId')
      const mine = (machine: string, session: string): boolean => context.startedByCopilot(startedKey(machine, session))
      if (machineId === null) {
        const now = await view()
        const machines = machineRows(now, mine)
        return {
          value: {
            thisComputer: now.here,
            machines,
            ...(now.blocked === null ? {} : { cannotPairNow: now.blocked }),
            ...(machines.length === 0
              ? { note: 'This computer is not paired to any other. machines.manage with do "pair" and a code shown on the other computer adds one.' }
              : {}),
          },
          summary: { machines: machines.length, online: machines.filter((row) => row.online === true).length },
        }
      }
      if (sessionId === null) {
        const now = await requireMachine(machineId)
        const row = machineRows(now, mine).find((candidate) => candidate.id === machineId)
        if (row?.online !== true) {
          return {
            value: { ...row, note: `${nameOf(machineId)} is not connected, so it cannot be asked anything right now.` },
            summary: { machineId, online: false },
          }
        }
        /*
         * Asked together, because each is a round trip to a computer in another
         * room and none depends on another. A null is that machine not
         * answering — a link that dropped, or a build too old for the question —
         * and it is reported as exactly that, never as "none".
         */
        const [host, logins, github] = await Promise.all([
          deps.call('machines:host:read', machineId),
          deps.call('machines:logins:read', machineId),
          deps.call('machines:github:read', machineId),
        ])
        return {
          value: {
            ...row,
            host: host ?? 'did not answer',
            logins: logins ?? 'did not answer',
            github: github ?? 'did not answer',
          },
          summary: { machineId, online: true, answered: [host, logins, github].filter((one) => one !== null).length },
        }
      }
      const session = await requireSession(machineId, sessionId)
      /*
       * `plan` and `context`, and never `refresh`: that one boots a whole agent
       * CLI on somebody else's computer — 725 MB, three seconds, measured — and
       * `machines/ipc.ts` keeps it behind a person opening the usage panel.
       */
      const [screen, controls, account, plan, contextWindow] = await Promise.all([
        deps.watch.screen(machineId, sessionId),
        deps.call('machines:controls:read', machineId, sessionId),
        deps.call('machines:account:read', machineId, sessionId),
        deps.call('machines:usage:read', machineId, sessionId, 'plan', false),
        deps.call('machines:usage:read', machineId, sessionId, 'context', false),
      ])
      return {
        value: {
          machineId,
          machine: nameOf(machineId),
          ...sessionRow(session),
          startedByYou: mine(machineId, sessionId),
          screen:
            screen === null
              ? null
              : { text: screen.text, live: screen.live, cols: screen.cols, rows: screen.rows, lastOutputAt: screen.lastOutputAt },
          ...(screen === null
            ? {
                screenNote:
                  'Nothing on this computer is showing that session, so its screen has not been seen here. ' +
                  'machines.session with do "watch" starts receiving it.',
              }
            : screen.live
              ? {}
              : { screenNote: 'This is the last screen seen here; nothing on this computer is receiving it now.' }),
          controls: controls ?? 'did not answer',
          login: account ?? 'did not answer',
          usage: { plan, context: contextWindow },
        },
        summary: { machineId, sessionId, screen: screen !== null, live: screen?.live ?? false },
      }
    },
  }

  /* ---------------------------------------------------------- session ----- */

  const SESSION_VERBS = ['start', 'send', 'keys', 'stop', 'rename', 'set', 'switch-login', 'watch'] as const
  type SessionVerb = (typeof SESSION_VERBS)[number]

  const session: ToolSpec = {
    id: 'machines.session',
    wire: 'machines_session',
    tier: 'act',
    title: 'Drive a session on another computer',
    description:
      'Work with one agent session on another computer this app is paired to. do: "start" a new session ' +
      '(folder and agent optional; that computer decides which folders it allows) and get its sessionId back; ' +
      '"send" a line of text (submit presses return, default true); "keys" presses named keys such as enter, ' +
      'escape, up, down, ctrl-c; "stop" ends it; "rename" sets its title; "set" changes its model, effort, fast ' +
      'mode or permission mode; "switch-login" restarts it as a different agent login (it gets a new sessionId); ' +
      '"watch" starts receiving its screen here so machines.look can show it (it also sizes that session to ' +
      `${WATCH_COLS}×${WATCH_ROWS} on that computer, as opening it from a phone does). Anything done to a ` +
      'session you did not start, a permission-mode change and a login switch ask the person first.',
    index:
      'Start, type into, stop, rename, retune or watch a session on another paired computer.',
    inputSchema: {
      type: 'object',
      properties: {
        machineId: { type: 'string' },
        do: { type: 'string', enum: [...SESSION_VERBS] },
        sessionId: { type: 'string', description: 'Required for everything except start.' },
        folder: { type: 'string', description: 'start: the folder on that computer.' },
        agent: { type: 'string', enum: [...AGENTS], description: 'start: which agent. Default: that computer’s own.' },
        text: { type: 'string', description: 'send: printable text, one line.' },
        submit: { type: 'boolean', description: 'send: press return afterwards. Default true.' },
        keys: {
          type: 'array',
          items: { type: 'string' },
          description: `keys: pressed in order — ${KEY_NAMES.join(', ')}, or one printable character such as "y" or "2".`,
        },
        title: { type: 'string', description: 'rename: the new title. Empty puts back that computer’s own name.' },
        control: { type: 'string', enum: [...CONTROL_IDS], description: 'set: which control.' },
        value: { type: 'string', description: 'set: the value, as the session’s own picker names it.' },
        loginId: { type: 'string', description: 'switch-login: a login id from machines.look on that machine.' },
      },
      required: ['machineId', 'do'],
      additionalProperties: false,
    },
    /**
     * The tier follows whose session it is, as on this machine.
     *
     * `start` and `watch` are `act` — a new session appears in that computer's
     * list, and watching changes nothing a person chose. Anything else done to a
     * session the copilot did not start is `alter`. Two are `alter` even on the
     * copilot's own session: the **permission** control is the boundary the
     * session runs inside, and a **login switch** ends the agent process and
     * starts it again as somebody's other account.
     */
    escalate: (args, context): Tier => {
      const verb = verbOf(args) as SessionVerb
      // A title is a label anybody can type again; it is the one change to
      // somebody else's session that stays `act`.
      if (verb === 'start' || verb === 'watch' || verb === 'rename') return 'act'
      if (verb === 'switch-login') return 'alter'
      if (verb === 'set' && args.control === 'permission') return 'alter'
      const machineId = typeof args.machineId === 'string' ? args.machineId : ''
      const sessionId = typeof args.sessionId === 'string' ? args.sessionId : ''
      return context.startedByCopilot(startedKey(machineId, sessionId)) ? 'act' : 'alter'
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Driving a session on another computer')
      const machineId = str(args, 'machineId')
      knownIfListed(machineId)
      const verb = oneOf(args, 'do', SESSION_VERBS)
      if (verb !== 'start') str(args, 'sessionId')
      if (verb === 'send') sanitizeSendText(str(args, 'text'))
      if (verb === 'keys') keysFrom(strList(args, 'keys'))
      if (verb === 'set') {
        oneOf(args, 'control', CONTROL_IDS)
        str(args, 'value')
      }
      if (verb === 'switch-login') str(args, 'loginId')
      if (verb === 'rename' && typeof args.title !== 'string') throw new BadArgument('title is required for rename')
    },
    summary: (args) => {
      const machine = nameOf(typeof args.machineId === 'string' ? args.machineId : '?')
      const target = `session ${typeof args.sessionId === 'string' ? args.sessionId : '?'} on ${machine}`
      switch (verbOf(args)) {
        case 'start': {
          const agent = typeof args.agent === 'string' ? `${args.agent} ` : ''
          const folder = typeof args.folder === 'string' && args.folder !== '' ? ` in ${args.folder}` : ''
          return `Start a ${agent}session on ${machine}${folder}`
        }
        case 'send':
          return `Type into ${target}: “${typeof args.text === 'string' ? args.text : ''}”${args.submit === false ? '' : ' and press return'}`
        case 'keys':
          return `Press ${Array.isArray(args.keys) ? args.keys.join(', ') : '?'} in ${target}`
        case 'stop':
          return `Stop ${target}. Whatever it was doing ends and cannot be resumed from here.`
        case 'rename':
          return `Rename ${target} to “${typeof args.title === 'string' ? args.title : ''}”`
        case 'set':
          return `Set ${String(args.control)} to ${String(args.value)} in ${target}`
        case 'switch-login':
          return `Restart ${target} as the login ${String(args.loginId)}. The agent process there is ended and started again.`
        case 'watch':
          return `Start receiving the screen of ${target} (it is sized ${WATCH_COLS}×${WATCH_ROWS} there)`
        default:
          return `Work with ${target}`
      }
    },
    run: async (args, context: ToolContext): Promise<ToolOutput> => {
      const machineId = str(args, 'machineId')
      const verb = oneOf(args, 'do', SESSION_VERBS)

      if (verb === 'start') {
        const before = new Set(sessionsOf(await requireMachine(machineId), machineId).map((row) => row.id))
        const folder = optStr(args, 'folder') ?? ''
        const agent = optStr(args, 'agent') ?? ''
        if (agent !== '' && !(AGENTS as readonly string[]).includes(agent)) {
          throw new BadArgument(`agent must be one of: ${AGENTS.join(', ')}`)
        }
        let sent = false
        /*
         * The new session's id is not in the answer — `machines:create` answers
         * only that the request left — so it is read off the push that lists it.
         * Subscribed before the request goes, so a fast machine cannot answer
         * between the two.
         */
        const next = await deps.nextState(
          (state) => sessionsOf(state, machineId).some((row) => !before.has(row.id)),
          START_WAIT_MS,
          async () => {
            sent = await deps.call('machines:create', machineId, folder, agent)
          },
        )
        if (!sent) {
          throw new Refused(
            'not-permitted',
            `${nameOf(machineId)} could not be asked to start a session: it is not connected, or its build cannot start one from here.`,
          )
        }
        const started = next === null ? undefined : sessionsOf(next, machineId).find((row) => !before.has(row.id))
        if (started === undefined) {
          return {
            value: {
              machineId,
              sessionId: null,
              note:
                `The request reached ${nameOf(machineId)} but no new session appeared within ${START_WAIT_MS / 1000} seconds. ` +
                'That computer may have refused the folder; machines.look on it shows its sessions and the folders it allows.',
            },
            summary: { machineId, started: false },
          }
        }
        context.noteStarted(startedKey(machineId, started.id))
        return {
          value: { machineId, ...sessionRow(started), startedByYou: true },
          summary: { machineId, sessionId: started.id, started: true },
        }
      }

      const sessionId = str(args, 'sessionId')
      const target = await requireSession(machineId, sessionId)

      if (verb === 'send' || verb === 'keys') {
        if (target.exitCode !== null) {
          throw new BadArgument(`session ${sessionId} has already exited; there is nothing to type into`)
        }
        /*
         * Each write is its own `machines:send`, with the gap `session-typing.ts`
         * measured between them — the line, then its Enter; one key, then the
         * next. A line and its return in one frame land as one chunk in the
         * agent on that computer, which reads it as a paste and never sends it.
         */
        const write = async (data: string): Promise<void> => {
          okOr(await deps.call('machines:send', machineId, sessionId, data))
        }
        if (verb === 'send') await typeLine(write, sanitizeSendText(str(args, 'text')), optBool(args, 'submit', true))
        else await pressKeys(write, keysFrom(strList(args, 'keys')))
        return {
          value: { machineId, sessionId, sent: true },
          summary: {
            machineId,
            sessionId,
            ...(verb === 'send' ? { text: str(args, 'text'), submitted: optBool(args, 'submit', true) } : { keys: strList(args, 'keys') }),
          },
        }
      }

      if (verb === 'stop') {
        if (!(await deps.call('machines:close', machineId, sessionId))) {
          throw new Refused('not-permitted', `${nameOf(machineId)} could not be asked to stop that session: it is not connected, or its build cannot.`)
        }
        return { value: { machineId, sessionId, stopRequested: true }, summary: { machineId, sessionId } }
      }

      if (verb === 'rename') {
        const title = typeof args.title === 'string' ? args.title : ''
        if (!(await deps.call('machines:session:rename', machineId, sessionId, title))) {
          throw new Refused('not-permitted', `${nameOf(machineId)} could not be asked to rename it: not connected, or too old a build.`)
        }
        return { value: { machineId, sessionId, renameRequested: true }, summary: { machineId, sessionId, title } }
      }

      if (verb === 'set') {
        const control = oneOf(args, 'control', CONTROL_IDS)
        const answer = await deps.call('machines:controls:apply', machineId, sessionId, control, str(args, 'value'))
        const ok = (answer as { ok?: unknown } | null)?.ok === true
        if (!ok) throw new Refused('not-permitted', (answer as { message?: string } | null)?.message ?? 'That did not change.')
        return { value: answer, summary: { machineId, sessionId, control, value: str(args, 'value') } }
      }

      if (verb === 'switch-login') {
        const answer = await deps.call('machines:account:switch', machineId, sessionId, str(args, 'loginId'))
        okOr(answer)
        // The copilot's own session comes back as its own; somebody else's stays theirs.
        if (answer.session !== null && context.startedByCopilot(startedKey(machineId, sessionId))) {
          context.noteStarted(startedKey(machineId, answer.session))
        }
        return {
          value: { machineId, sessionId: answer.session, previousSessionId: sessionId, message: answer.message },
          summary: { machineId, sessionId, now: answer.session },
        }
      }

      // watch
      if (deps.watch.attached(machineId, sessionId)) {
        return { value: { machineId, sessionId, watching: true, note: 'Already being received here.' }, summary: { machineId, sessionId, already: true } }
      }
      if (!(await deps.call('machines:attach', machineId, sessionId, WATCH_COLS, WATCH_ROWS))) {
        throw new Refused('not-permitted', `${nameOf(machineId)} is not connected, so its sessions cannot be watched right now.`)
      }
      return {
        value: { machineId, sessionId, watching: true, note: 'machines.look with this sessionId now shows its screen.' },
        summary: { machineId, sessionId, watching: true },
      }
    },
  }

  /* ---------------------------------------------------------- copilot ----- */

  const COPILOT_VERBS = ['read', 'say', 'start'] as const

  const copilot: ToolSpec = {
    id: 'machines.copilot',
    wire: 'machines_copilot',
    tier: 'act',
    title: `Talk to ${BRAND.assistant} on another computer`,
    description:
      `${BRAND.assistant} on another paired computer, when that computer shares it with this one (machines.look says ` +
      'sharesCopilot). do: "read" returns its conversation and state; "say" sends it one line — set waitSeconds ' +
      'to wait for its answer, which is returned with the conversation; "start" starts this computer’s run on ' +
      'it. It acts with that computer’s own tools and asks that computer’s person before anything it may not do ' +
      'alone; nothing here widens that.',
    index: `Read, start or talk to ${BRAND.assistant} on another paired computer, and wait for its answer.`,
    inputSchema: {
      type: 'object',
      properties: {
        machineId: { type: 'string' },
        do: { type: 'string', enum: [...COPILOT_VERBS] },
        text: { type: 'string', description: 'say: printable text, one line.' },
        waitSeconds: { type: 'integer', description: `say: wait up to this long for the answer, 0–${MAX_REPLY_WAIT_S}. Default 0.` },
        messages: { type: 'integer', description: `How many messages to return, newest last. Default ${DEFAULT_MESSAGES}.` },
      },
      required: ['machineId', 'do'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, `Talking to ${BRAND.assistant} on another computer`)
      knownIfListed(str(args, 'machineId'))
      if (oneOf(args, 'do', COPILOT_VERBS) === 'say') sanitizeSendText(str(args, 'text'))
      if (args.waitSeconds !== undefined) int(args, 'waitSeconds', 0, MAX_REPLY_WAIT_S)
      if (args.messages !== undefined) int(args, 'messages', 1, MAX_MESSAGES_BACK)
    },
    summary: (args) => {
      const machine = nameOf(typeof args.machineId === 'string' ? args.machineId : '?')
      if (verbOf(args) === 'say') return `Say to ${BRAND.assistant} on ${machine}: “${typeof args.text === 'string' ? args.text : ''}”`
      if (verbOf(args) === 'start') return `Start ${BRAND.assistant} on ${machine}`
      return `Read the conversation with ${BRAND.assistant} on ${machine}`
    },
    run: async (args): Promise<ToolOutput> => {
      const machineId = str(args, 'machineId')
      const verb = oneOf(args, 'do', COPILOT_VERBS)
      const limit = args.messages === undefined ? DEFAULT_MESSAGES : int(args, 'messages', 1, MAX_MESSAGES_BACK)
      await requireMachine(machineId)
      const shaped = (): Record<string, unknown> => {
        const held = deps.watch.conversation(machineId)
        return { machineId, state: held.state, run: held.run, messages: held.messages.slice(-limit) }
      }

      if (verb === 'start') {
        okOr(await deps.call('machines:copilot:start', machineId))
        return { value: shaped(), summary: { machineId, started: true } }
      }

      /*
       * Subscribe before anything else, every time. The far end answers an
       * attach with its state and the whole conversation, so this is both "make
       * sure the frames are coming" and "make sure what is held is current" —
       * and re-attaching is what the window does too, so it disturbs nothing.
       */
      const heldBefore = deps.watch.conversation(machineId).changedAt !== null
      const arrived = deps.watch.nextChange(machineId, CHAT_WAIT_MS)
      okOr(await deps.call('machines:copilot:attach', machineId))
      await deps.call('machines:copilot:refresh', machineId)
      // A first read waits for the frames the attach is owed; a later one has
      // them already and must not spend three seconds proving it.
      if (!heldBefore) await arrived

      if (verb === 'read') {
        return { value: shaped(), summary: { machineId, messages: deps.watch.conversation(machineId).messages.length } }
      }

      const text = sanitizeSendText(str(args, 'text'))
      const before = deps.watch.conversation(machineId).messages
      const since = before.length === 0 ? null : before[before.length - 1].id
      okOr(await deps.call('machines:copilot:say', machineId, text))
      const waitSeconds = args.waitSeconds === undefined ? 0 : int(args, 'waitSeconds', 0, MAX_REPLY_WAIT_S)
      const answered = waitSeconds === 0 ? null : await deps.watch.replied(machineId, since, waitSeconds * 1000)
      return {
        value: {
          ...shaped(),
          said: text,
          ...(answered === null ? {} : { answered, ...(answered ? {} : { note: `No finished answer within ${waitSeconds} seconds; read again later.` }) }),
        },
        summary: { machineId, text, waited: waitSeconds, answered },
      }
    },
  }

  /* ---------------------------------------------------------- ports ------- */

  const PORT_VERBS = ['list', 'refresh', 'open-here', 'close-here', 'open-there'] as const

  const ports: ToolSpec = {
    id: 'machines.ports',
    wire: 'machines_ports',
    tier: 'act',
    title: 'Reach what another computer is serving',
    description:
      'The local web servers and ports on another paired computer. do: "list" what it is serving; "refresh" asks ' +
      'it again (after something was started there); "open-here" gives one of its ports an http address on this ' +
      'computer and returns that URL — open it in the browser like any page; "close-here" hands the address back; ' +
      '"open-there" opens a URL in the browser on that computer.',
    index: 'List another paired computer’s ports, give one an address here, or open a page in its browser.',
    inputSchema: {
      type: 'object',
      properties: {
        machineId: { type: 'string' },
        do: { type: 'string', enum: [...PORT_VERBS] },
        port: { type: 'integer', description: 'open-here and close-here.' },
        url: { type: 'string', description: 'open-there.' },
      },
      required: ['machineId', 'do'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Reaching another computer’s ports')
      knownIfListed(str(args, 'machineId'))
      const verb = oneOf(args, 'do', PORT_VERBS)
      if (verb === 'open-here' || verb === 'close-here') int(args, 'port', 1, 65535)
      if (verb === 'open-there') {
        const url = str(args, 'url')
        if (url.length > MAX_URL_LENGTH) throw new BadArgument(`url must be ${MAX_URL_LENGTH} characters or fewer`)
      }
    },
    summary: (args) => {
      const machine = nameOf(typeof args.machineId === 'string' ? args.machineId : '?')
      switch (verbOf(args)) {
        case 'open-here':
          return `Give port ${String(args.port)} on ${machine} an address on this computer`
        case 'close-here':
          return `Stop serving port ${String(args.port)} of ${machine} here`
        case 'open-there':
          return `Open ${String(args.url)} in the browser on ${machine}`
        case 'refresh':
          return `Ask ${machine} what it is serving`
        default:
          return `List what ${machine} is serving`
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const machineId = str(args, 'machineId')
      const verb = oneOf(args, 'do', PORT_VERBS)
      const now = await requireMachine(machineId)
      const portsOf = (state: MachinesView): unknown[] => state.links.find((row) => row.id === machineId)?.ports ?? []

      if (verb === 'list' || verb === 'refresh') {
        let state = now
        if (verb === 'refresh') {
          let asked = false
          const pushed = await deps.nextState(
            (next) => next.links.some((row) => row.id === machineId),
            PORTS_WAIT_MS,
            async () => {
              asked = await deps.call('machines:ports', machineId)
            },
          )
          if (!asked) throw new Refused('not-permitted', `${nameOf(machineId)} is not connected, so it cannot be asked.`)
          state = pushed ?? (await view())
        }
        const found = portsOf(state)
        return { value: { machineId, ports: found }, summary: { machineId, ports: found.length } }
      }

      if (verb === 'open-here') {
        const port = int(args, 'port', 1, 65535)
        const answer = (await deps.call('machines:reach', machineId, port)) as { ok?: boolean; message?: string } | null
        if (answer?.ok !== true) throw new Refused('not-permitted', answer?.message ?? 'That port could not be reached.')
        return { value: answer, summary: { machineId, port } }
      }

      if (verb === 'close-here') {
        const port = int(args, 'port', 1, 65535)
        return { value: { machineId, port, closed: await deps.call('machines:reach:close', machineId, port) }, summary: { machineId, port } }
      }

      const url = str(args, 'url')
      if (!(await deps.call('machines:open', machineId, url))) {
        throw new Refused('not-permitted', `${nameOf(machineId)} could not be asked to open it: not connected, or its build cannot.`)
      }
      return { value: { machineId, url, opened: true }, summary: { machineId, url } }
    },
  }

  /* ---------------------------------------------------------- upload ------ */

  const upload: ToolSpec = {
    id: 'machines.upload',
    wire: 'machines_upload',
    tier: 'act',
    title: 'Send a file to another computer',
    description:
      'Copy one file from this computer to another paired computer, into its downloads folder or a folder you ' +
      'name there (that computer decides whether the folder is allowed). Answers where it landed. Sending always ' +
      'asks the person first. do "cancel" stops a transfer in flight. Files under ~/.ssh and other credential ' +
      'folders are never sent.',
    index: 'Copy a file from this computer to another paired computer, or cancel a transfer.',
    inputSchema: {
      type: 'object',
      properties: {
        machineId: { type: 'string' },
        do: { type: 'string', enum: ['send', 'cancel'] },
        path: { type: 'string', description: 'send: absolute path of a file on this computer.' },
        folder: { type: 'string', description: 'send: folder on that computer. Default: its downloads folder.' },
      },
      required: ['machineId', 'do'],
      additionalProperties: false,
    },
    escalate: (args): Tier => (verbOf(args) === 'cancel' ? 'act' : 'alter'),
    precheck: (args, context) => {
      hereOnly(context.caller, 'Sending files to another computer')
      knownIfListed(str(args, 'machineId'))
      if (oneOf(args, 'do', ['send', 'cancel'] as const) === 'send') sendableFile(str(args, 'path'), [deps.userData()])
    },
    summary: (args) => {
      const machine = nameOf(typeof args.machineId === 'string' ? args.machineId : '?')
      if (verbOf(args) === 'cancel') return `Cancel the file transfer to ${machine}`
      const folder = typeof args.folder === 'string' && args.folder !== '' ? args.folder : 'its downloads folder'
      return `Send ${String(args.path)} from this computer to ${machine}, into ${folder}`
    },
    run: async (args): Promise<ToolOutput> => {
      const machineId = str(args, 'machineId')
      await requireMachine(machineId)
      if (oneOf(args, 'do', ['send', 'cancel'] as const) === 'cancel') {
        return { value: { machineId, cancelled: await deps.call('machines:upload:cancel', machineId) }, summary: { machineId } }
      }
      const path = sendableFile(str(args, 'path'), [deps.userData()])
      const answer = (await deps.call('machines:upload', machineId, path, optStr(args, 'folder') ?? '')) as {
        ok?: boolean
        message?: string
      } | null
      if (answer?.ok !== true) throw new Refused('not-permitted', answer?.message ?? 'That file did not send.')
      return { value: answer, summary: { machineId, path } }
    },
  }

  /* ---------------------------------------------------------- manage ------ */

  const MANAGE_VERBS = [
    'pair',
    'show-code',
    'cancel-code',
    'connect',
    'disconnect',
    'rename',
    'forget',
    'allow-windows',
    'restart-host',
    'stop-host',
    'sign-in',
    'sign-out',
    'github-connect',
    'github-cancel',
    'github-disconnect',
  ] as const
  type ManageVerb = (typeof MANAGE_VERBS)[number]

  const NEEDS_MACHINE: readonly ManageVerb[] = MANAGE_VERBS.filter(
    (verb) => verb !== 'pair' && verb !== 'show-code' && verb !== 'cancel-code',
  )

  const manage: ToolSpec = {
    id: 'machines.manage',
    wire: 'machines_manage',
    tier: 'alter',
    title: 'Pair, forget or change another computer',
    description:
      'Change which computers this app is paired to and how. Every call asks the person first. do: "pair" with ' +
      'the code shown on the other computer; "show-code" puts a pairing code on this computer for another one to ' +
      'type (returned, single-use, minutes long) and "cancel-code" withdraws it; "connect" / "disconnect" its ' +
      'link; "rename"; "forget" it; "allow-windows" (allowed true/false) lets its sessions drive browser windows ' +
      'here; "restart-host" / "stop-host" its host program; "sign-in" / "sign-out" one of its agent logins ' +
      '(loginId from machines.look); "github-connect" (returns the code to type at github.com), "github-cancel", ' +
      '"github-disconnect" its GitHub connection.',
    index:
      'Pair, forget, rename or connect another computer; its host, agent logins and GitHub.',
    inputSchema: {
      type: 'object',
      properties: {
        do: { type: 'string', enum: [...MANAGE_VERBS] },
        machineId: { type: 'string', description: 'Every verb except pair, show-code and cancel-code.' },
        code: { type: 'string', description: 'pair: the code the other computer shows.' },
        name: { type: 'string', description: 'rename: the new name.' },
        allowed: { type: 'boolean', description: 'allow-windows.' },
        loginId: { type: 'string', description: 'sign-in and sign-out.' },
      },
      required: ['do'],
      additionalProperties: false,
    },
    /*
     * Asked every time, even for an AI app whose key is set not to ask, for the
     * reason `remote.manage` gives: pairing is who reaches whom, and "show-code"
     * hands back a code another computer types to be let in. See
     * `ToolSpec.ownerMustAnswer`.
     */
    ownerMustAnswer: () => true,
    precheck: (args, context) => {
      hereOnly(context.caller, 'Changing which computers this app is paired to')
      const verb = oneOf(args, 'do', MANAGE_VERBS)
      if (NEEDS_MACHINE.includes(verb)) knownIfListed(str(args, 'machineId'))
      if (verb === 'pair') str(args, 'code')
      if (verb === 'rename') str(args, 'name')
      if (verb === 'allow-windows') bool(args, 'allowed')
      if (verb === 'sign-in' || verb === 'sign-out') str(args, 'loginId')
    },
    /*
     * Each sentence says what changes for whom, because the dialog is the only
     * thing between a model's choice and a person's computer. "Forget machine
     * m-4f…" asks nobody anything; "Forget Office PC — this computer stops
     * reaching it" asks the real question.
     */
    summary: (args) => {
      const machine = nameOf(typeof args.machineId === 'string' ? args.machineId : '?')
      switch (verbOf(args) as ManageVerb) {
        case 'pair':
          return 'Pair this computer to the one showing that code, so this app can reach it and its sessions'
        case 'show-code':
          return 'Show a pairing code on this computer, so another computer can be paired to it'
        case 'cancel-code':
          return 'Withdraw the pairing code on screen'
        case 'connect':
          return `Connect to ${machine}`
        case 'disconnect':
          return `Disconnect from ${machine} until it is connected again`
        case 'rename':
          return `Rename ${machine} to “${String(args.name)}” in this app`
        case 'forget':
          return `Forget ${machine}: this computer stops reaching it and would need a new code to pair again`
        case 'allow-windows':
          return args.allowed === true
            ? `Let sessions on ${machine} drive browser windows in this app`
            : `Stop sessions on ${machine} driving browser windows in this app`
        case 'restart-host':
          return `Restart the host program on ${machine}. Its connections drop and come back`
        case 'stop-host':
          return `Stop the host program on ${machine}. It cannot be started again from here — only on that computer`
        case 'sign-in':
          return `Sign in the agent login ${String(args.loginId)} on ${machine}`
        case 'sign-out':
          return `Sign out the agent login ${String(args.loginId)} on ${machine}`
        case 'github-connect':
          return `Connect ${machine} to GitHub`
        case 'github-cancel':
          return `Cancel the GitHub sign-in waiting on ${machine}`
        case 'github-disconnect':
          return `Disconnect ${machine} from GitHub`
        default:
          return `Change ${machine}`
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const verb = oneOf(args, 'do', MANAGE_VERBS)

      if (verb === 'show-code') {
        const answer = await deps.call('machines:code')
        if (!answer.ok) throw new Refused('not-permitted', answer.message)
        return {
          value: {
            code: answer.code.token,
            expiresAt: answer.code.expiresAt,
            note: 'Type this on the other computer, in its Machines list. It works once.',
          },
          // Not in the log: it is a door for the next few minutes, and the log outlives them.
          summary: { shown: true, expiresAt: answer.code.expiresAt },
        }
      }
      if (verb === 'cancel-code') {
        await deps.call('machines:code:cancel')
        return { value: { cancelled: true }, summary: { cancelled: true } }
      }
      if (verb === 'pair') {
        const result = await deps.call('machines:pair', str(args, 'code'))
        if (!result.ok) throw new Refused('not-permitted', result.message)
        // The credential and the guest keys stay where the handler put them.
        const now = await view()
        const row = machineRows(now).find((candidate) => candidate.id === result.offer.hostId)
        return {
          value: { paired: true, machineId: result.offer.hostId, name: row?.name ?? result.offer.name, machine: row ?? null },
          summary: { paired: true, machineId: result.offer.hostId },
        }
      }

      const machineId = str(args, 'machineId')
      await requireMachine(machineId)
      const asView = (state: MachinesView): Record<string, unknown> => ({
        machine: machineRows(state).find((row) => row.id === machineId) ?? null,
      })

      switch (verb) {
        case 'connect':
          return { value: asView(await deps.call('machines:connect', machineId)), summary: { machineId } }
        case 'disconnect':
          return { value: asView(await deps.call('machines:disconnect', machineId)), summary: { machineId } }
        case 'rename': {
          const name = str(args, 'name')
          return { value: asView(await deps.call('machines:rename', machineId, name)), summary: { machineId, name } }
        }
        case 'forget': {
          const after = await deps.call('machines:forget', machineId)
          lastView = after
          return { value: { forgotten: !after.machines.some((row) => row.id === machineId) }, summary: { machineId } }
        }
        case 'allow-windows': {
          const allowed = bool(args, 'allowed')
          return { value: asView(await deps.call('machines:drive-windows', machineId, allowed)), summary: { machineId, allowed } }
        }
        case 'restart-host':
        case 'stop-host': {
          const answer = await deps.call(verb === 'restart-host' ? 'machines:host:restart' : 'machines:host:stop', machineId)
          return {
            value: {
              machineId,
              answer:
                answer ??
                // `machines/ipc.ts`: a null here is often the connection dropping *as
                // the host acts*, before its reply flushed — not a failure.
                'No reply. The host may already be acting on it, which drops the connection; machines.look shows the link coming back.',
            },
            summary: { machineId, answered: answer !== null },
          }
        }
        case 'sign-in':
        case 'sign-out': {
          const loginId = str(args, 'loginId')
          const answer = await deps.call(verb === 'sign-in' ? 'machines:logins:signin' : 'machines:logins:signout', machineId, loginId)
          okOr(answer)
          return { value: answer, summary: { machineId, loginId } }
        }
        default: {
          const channel =
            verb === 'github-connect'
              ? 'machines:github:connect'
              : verb === 'github-cancel'
                ? 'machines:github:cancel'
                : 'machines:github:disconnect'
          const answer = await deps.call(channel, machineId)
          return {
            value: { machineId, github: answer ?? 'did not answer' },
            // The device code a github-connect answers with is for the person, not the log.
            summary: { machineId, verb },
          }
        }
      }
    },
  }

  return [look, session, copilot, ports, upload, manage]
}

/** Every id this file contributes, for the checklist and the budget test. */
export const MACHINE_TOOL_IDS = [
  'machines.look',
  'machines.session',
  'machines.copilot',
  'machines.ports',
  'machines.upload',
  'machines.manage',
] as const
