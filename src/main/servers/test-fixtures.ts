/**
 * Cards and facts the tests in this folder build against.
 *
 * Not a module the app imports — it exists so that four test files describe the
 * *same* server rather than four slightly different ones, which is how a suite
 * ends up green against a shape the feature never produces.
 *
 * Every fixture here is derived from output measured on a real machine
 * (`terminaldeck-server`, Ubuntu 24.04.4, systemd, Docker, Caddy) rather than
 * invented: the compose labels are the ones Docker actually emitted, the unit
 * fragment paths are the ones `systemctl show` actually printed, and the
 * `pg_dumpall` behaviour is what a real `postgres:16-alpine` container actually
 * did. `CLAUDE.md`'s standing instruction is the reason — *"verify against real
 * data… this codebase has repeatedly been wrong in ways only real data
 * exposed."*
 */

import type { Fact, InitSystem, Privilege } from './facts'
import type { RunResult } from './connection'
import { previewOf, type ActionFacts, type ActionId, type ServerRoom, type ServerView } from './actions'
import type { KnownEngine, ServerCard } from './classify'

export function yes<T>(value: T, how = 'measured'): Fact<T> {
  return { known: 'yes', value, measuredAt: 1_700_000_000_000, how }
}

export function no<T>(how = 'measured'): Fact<T> {
  return { known: 'no', measuredAt: 1_700_000_000_000, how }
}

export function cannot<T>(why: string): Fact<T> {
  return { known: 'cannot', measuredAt: 1_700_000_000_000, why }
}

/** The test box: root, systemd, Docker reachable. */
export function facts(overrides: Partial<ActionFacts> = {}): ActionFacts {
  return {
    privilege: yes<Privilege>('yes'),
    init: yes<InitSystem>('systemd'),
    containerRuntime: yes<'docker' | 'podman'>('docker'),
    ...overrides,
  }
}

/**
 * One command's result, with the two fields it is easy to forget.
 *
 * `signal` and `truncated` are real parts of `RunResult` and both change
 * behaviour: a command stopped by a signal has `code: null` and must be treated
 * as a failure, and truncated output means the tail was dropped. A fixture that
 * omitted them would let a test pass against a shape the transport never
 * produces.
 */
export function cmd(overrides: Partial<RunResult> = {}): RunResult {
  return { code: 0, signal: null, stdout: '', stderr: '', truncated: false, ...overrides }
}

/**
 * A service kept in a checked-out repository — the shape `td-scratch.service`
 * had on the real box, `WorkingDirectory=/opt/td-scratch` and all.
 */
export function repoCard(overrides: Partial<ServerCard> = {}): ServerCard {
  return {
    id: 'service:td-scratch.service',
    kind: 'app',
    name: 'td-scratch',
    detail: 'Terminal Deck scratch service',
    running: true,
    managedBy: { kind: 'systemd', unit: 'td-scratch.service' },
    url: null,
    engine: null,
    repoDir: '/opt/td-scratch',
    ...overrides,
  }
}

/** A compose-managed container — the labels are the ones Docker really emitted. */
export function containerCard(overrides: Partial<ServerCard> & { engine?: KnownEngine } = {}): ServerCard {
  return {
    id: 'container:tdscratch-web-1',
    kind: overrides.engine !== undefined && overrides.engine !== null ? 'database' : 'app',
    name: 'web',
    detail: 'Running in a container from alpine:3',
    running: true,
    managedBy: {
      kind: 'container',
      runtime: 'docker',
      name: 'tdscratch-web-1',
      compose: { project: 'tdscratch', service: 'web', workingDir: '/opt/td-scratch-compose' },
    },
    url: null,
    engine: null,
    repoDir: null,
    ...overrides,
  }
}

/** A container the person started by hand — no compose labels, so no way back. */
export function looseContainerCard(): ServerCard {
  return {
    ...containerCard(),
    id: 'container:hand-started',
    name: 'hand-started',
    managedBy: { kind: 'container', runtime: 'docker', name: 'hand-started', compose: null },
  }
}

/** A site the reverse proxy named. */
export function siteCard(): ServerCard {
  return {
    id: 'site:178-105-239-176.sslip.io',
    kind: 'site',
    name: '178-105-239-176.sslip.io',
    detail: 'Served by caddy',
    running: null,
    managedBy: null,
    url: 'https://178-105-239-176.sslip.io',
    engine: null,
    repoDir: null,
  }
}

/* --------------------------------------------------------------- the room -- */

/**
 * A `ServerRoom` with no transport behind it.
 *
 * The permission decisions in `tools.ts` are the piece that must be
 * exercisable, and `deck-control/surface.ts` makes the argument for why they
 * get an interface rather than a real backend: *"the piece that must be
 * exercisable is the piece that decides whether a dangerous call happens."*
 * Every method records what it was asked so a test can assert that a refusal
 * happened **before** the room was reached, rather than after.
 */
export function fakeRoom(
  overrides: Partial<ServerRoom> & { seen?: ServerView | null } = {},
): ServerRoom & { acted: Array<{ serverId: string; cardId: string; actionId: ActionId }> } {
  const acted: Array<{ serverId: string; cardId: string; actionId: ActionId }> = []
  const card = repoCard()
  const view: ServerView =
    overrides.seen === undefined
      ? {
          cards: [card],
          facts: facts(),
          composeAvailable: true,
          offered: { [card.id]: ['logs', 'restart', 'stop', 'update'] },
          absent: { [card.id]: [] },
          how: ['asked this server what it keeps running'],
          cannot: [],
          measuredAt: 1_700_000_000_000,
        }
      : (overrides.seen as ServerView)

  const room: ServerRoom & { acted: typeof acted } = {
    acted,
    list: () => [{ id: 's1', name: 'demo', address: 'example.test', username: 'root' }],
    knows: (serverId) => serverId === 's1',
    look: async () => view,
    cached: () => (overrides.seen === null ? null : view),
    preview: async (serverId, cardId, actionId) =>
      previewOf(actionId, { serverId, card: view.cards.find((row) => row.id === cardId) ?? card, facts: view.facts }),
    act: async (serverId, cardId, actionId) => {
      acted.push({ serverId, cardId, actionId })
      return { done: 'done', detail: {}, wayBack: null }
    },
    logs: async () => ({ lines: [] }),
    ...overrides,
  }
  return room
}
