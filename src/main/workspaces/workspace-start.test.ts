import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { buildCatalogue, knownFolders, type ToolContext, type ToolSpec } from '../deck-control/catalogue'
import { LOCAL_CALLER, type DeckSurface } from '../deck-control/surface'
import type { SessionMeta } from '../../shared/types'

/**
 * A task's workspace as `sessions.start` — the road every task session takes —
 * sees it: a folder of its own, startable although it is kept under the app's
 * storage, and counted apart from the project and from every other workspace by
 * the one-session-per-folder rule.
 */

const START = buildCatalogue().find((tool) => tool.id === 'sessions.start') as ToolSpec

const STATE = '/data/terminaldeck'
const PROJECT = '/work/app'
const ONE = join(STATE, 'workspaces', 'k1', 'local-a-11111111')
const TWO = join(STATE, 'workspaces', 'k1', 'local-b-22222222')

function context(options: { sessions?: SessionMeta[]; owned?: string[]; workspaces?: string[] } = {}): ToolContext {
  const sessions = options.sessions ?? []
  const owned = new Set(options.owned ?? [])
  const surface = {
    listSessions: () => sessions,
    sessionStatus: () => null,
    startSession: async () => {
      throw new Error('not in these tests')
    },
    writeToSession: () => undefined,
    killSession: () => undefined,
    sessionScreen: async () => null,
    sessionScrollback: () => '',
    listProjects: () => [{ path: PROJECT, lastOpenedAt: 1 }],
    appStateRoot: () => STATE,
    ...(options.workspaces === undefined ? {} : { taskWorkspaceFolders: () => options.workspaces ?? [] }),
    copilotRoot: () => join(STATE, 'copilot'),
    gitStatus: async () => ({}),
    alerts: async () => ({}),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: (patch: Record<string, unknown>) => patch as Record<string, string | number | boolean>,
    writePreferences: (patch: Record<string, unknown>) => patch,
    snapshotSettings: () => ({ path: '/tmp/x.json', at: 1 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({ repo: false, root: null, branch: null, ahead: 0, behind: 0, files: [], reason: 'no repo' }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  } satisfies DeckSurface
  return {
    surface,
    callId: 'row-1',
    attended: true,
    caller: LOCAL_CALLER,
    startedByCopilot: (id) => owned.has(id),
    noteStarted: (id) => owned.add(id),
    now: () => Date.parse('2026-10-05T09:00:00'),
  }
}

function live(id: string, cwd: string): SessionMeta {
  return { id, cwd, title: cwd, provider: 'claude', exitCode: null, createdAt: 1_000 }
}

describe('a task workspace, to sessions.start', () => {
  it('is a folder a session may start in, though it is kept in the app’s storage', () => {
    const ctx = context({ workspaces: [ONE] })
    expect(knownFolders(ctx.surface).has(ONE)).toBe(true)
    expect(() => START.precheck?.({ cwd: ONE }, ctx)).not.toThrow()
  })

  it('is only the folders recorded as workspaces, never anything else in storage', () => {
    const ctx = context({ workspaces: [ONE], sessions: [live('theirs', join(STATE, 'workspaces'))] })
    // Known only because a session is there; still the app's storage, so still refused.
    expect(() => START.precheck?.({ cwd: join(STATE, 'workspaces') }, ctx)).toThrow(/own storage/)
    expect(() => START.precheck?.({ cwd: TWO }, ctx)).toThrow(/not a folder this app has open/)
  })

  it('is nothing at all on a surface with no workspaces behind it', () => {
    expect(knownFolders(context().surface).has(ONE)).toBe(false)
  })

  it('counts apart from the project and from another workspace of the same repository', () => {
    const ctx = context({ workspaces: [ONE, TWO], sessions: [live('c1', PROJECT), live('c2', ONE)], owned: ['c1', 'c2'] })
    expect(() => START.precheck?.({ cwd: TWO }, ctx)).not.toThrow()
    // The rule still holds inside one workspace.
    expect(() => START.precheck?.({ cwd: ONE }, ctx)).toThrow(/one working tree/)
    expect(() => START.precheck?.({ cwd: PROJECT }, ctx)).toThrow(/one working tree/)
  })
})
