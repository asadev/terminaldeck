/**
 * A whole `deck-control` with access keys in front of it, and nothing else.
 *
 * Shared by the key store, door, `tools.run` and relay tests, because every one
 * of them asks the same question from a different side — *does a call on a key
 * go through the same gate the copilot's does* — and a rig per file would be
 * four slightly different fakes of the same app, one of which would eventually
 * disagree with the real surface in exactly the way that hides a bug.
 *
 * The surface is inert in the way `server.test.ts`'s is: one session, one
 * project, settings that really change, everything else the empty answer. What
 * is real is everything that decides whether a call happens — the dispatcher,
 * the consent broker, the action log on a temp directory, the key store on a
 * temp directory, and the door.
 */

import { join } from 'node:path'
import type { SessionMeta } from '../../shared/types'
import { AccessKeys, type AccessLevel } from './access-keys'
import { ActionLog } from './action-log'
import { ConsentBroker, type ConsentRequest } from './consent'
import { DeckControl, type Budgets } from './control'
import { AccessKeyDoor } from './key-door'
import type { DeckSurface } from './surface'

export const FIXTURE_SESSION: SessionMeta = {
  id: 'session-1',
  cwd: '/work/api',
  title: 'api',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_000,
}

export interface FakeApp {
  surface: DeckSurface
  settings: Record<string, string | number | boolean>
  started: string[]
  typed: Array<{ id: string; data: string }>
}

export function fakeApp(): FakeApp {
  const app: FakeApp = {
    surface: {} as DeckSurface,
    settings: { 'appearance.density': 'comfortable' },
    started: [],
    typed: [],
  }
  app.surface = {
    listSessions: () => [FIXTURE_SESSION],
    sessionStatus: () => ({ status: 'working', at: 2_000 }),
    startSession: async (input) => {
      app.started.push(input.cwd)
      return { ...FIXTURE_SESSION, id: `started-${app.started.length}`, cwd: input.cwd }
    },
    writeToSession: (id, data) => {
      app.typed.push({ id, data })
    },
    killSession: () => undefined,
    sessionScreen: async () => '',
    sessionScrollback: () => '',
    listProjects: () => [
      { path: '/work/api', lastOpenedAt: 1 },
      { path: '/work/site', lastOpenedAt: 2 },
    ],
    gitStatus: async (cwd) => ({ repo: true, cwd }),
    alerts: async () => ({ alerts: [] }),
    readSettings: () => ({ settings: { ...app.settings }, preferences: {} }),
    writeSettings: (patch) => {
      for (const [key, value] of Object.entries(patch)) {
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          app.settings[key] = value
        }
      }
      return { ...app.settings }
    },
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/tmp/settings.last-good.json', at: 0 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: 'not a repository',
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
  }
  return app
}

export interface KeyRig {
  app: FakeApp
  log: ActionLog
  consent: ConsentBroker
  control: DeckControl
  keys: AccessKeys
  door: AccessKeyDoor
  /** Every question the broker put to "a window". */
  asked: ConsentRequest[]
  /** Make a key and hand back its secret and id. */
  key(level: AccessLevel, options?: { name?: string; askFirst?: boolean; folders?: string[] }): { key: string; id: string }
}

export interface KeyRigOptions {
  /** Is there a window to ask? Default yes. */
  approver?: boolean
  consentTimeoutMs?: number
  budgets?: Partial<Budgets>
}

export function keyRig(dir: string, options: KeyRigOptions = {}): KeyRig {
  const app = fakeApp()
  const log = new ActionLog({ dir: join(dir, 'log') })
  const asked: ConsentRequest[] = []
  const consent = new ConsentBroker({
    ask: (request) => {
      asked.push(request)
      return options.approver !== false
    },
    ...(options.consentTimeoutMs === undefined ? {} : { timeoutMs: options.consentTimeoutMs }),
  })
  const control = new DeckControl({
    surface: app.surface,
    log,
    consent,
    ...(options.budgets === undefined ? {} : { budgets: options.budgets }),
  })
  const keys = new AccessKeys({ dir: join(dir, 'remote') })
  const door = new AccessKeyDoor({ keys, control: () => control, consent: () => consent })
  return {
    app,
    log,
    consent,
    control,
    keys,
    door,
    asked,
    key: (level, extra = {}) => {
      const made = keys.create({
        name: extra.name ?? `App ${keys.list().length + 1}`,
        level,
        ...(extra.askFirst === undefined ? {} : { askFirst: extra.askFirst }),
        ...(extra.folders === undefined ? {} : { folders: extra.folders }),
      })
      return { key: made.key, id: made.view.id }
    },
  }
}
