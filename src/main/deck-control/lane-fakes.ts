/**
 * A fake surface and a tool context, for the sessions lane's tests.
 *
 * Shared by `session-more-tools.test.ts`, `project-tools.test.ts`,
 * `files-tools.test.ts` and `ui-tools.test.ts` rather than written four times,
 * because a fake that drifts from `DeckSurface` in one test file and not the
 * others is how a rule ends up pinned against a surface nothing ships. It is a
 * plain module rather than a `*.test.ts` file so vitest does not run it as one;
 * nothing outside the tests imports it.
 */

import type { SessionMeta, SessionStatus } from '../../shared/types'
import { LOCAL_CALLER, type DeckSurface, type TranscriptMessage } from './surface'
import type { ToolContext, ToolSpec } from './catalogue'
import type { TranscriptChoice } from './transcript-match'

export interface FakeState {
  sessions: SessionMeta[]
  statuses: Map<string, { status: SessionStatus; at: number }>
  screens: Map<string, string>
  typed: Array<{ id: string; data: string }>
  projects: Array<{ path: string; lastOpenedAt: number }>
  transcripts: Map<string, TranscriptChoice[]>
  messages: Map<string, TranscriptMessage[]>
  gitRepo: Set<string>
}

export function session(overrides: Partial<SessionMeta> & { id: string }): SessionMeta {
  return { cwd: '/work/api', title: 'api', provider: 'claude', exitCode: null, createdAt: 1_000, ...overrides }
}

export function fakeSurface(): { state: FakeState; surface: DeckSurface } {
  const state: FakeState = {
    sessions: [session({ id: 's1' }), session({ id: 's2', cwd: '/work/web', title: 'web' })],
    statuses: new Map(),
    screens: new Map(),
    typed: [],
    projects: [
      { path: '/work/api', lastOpenedAt: 2 },
      { path: '/work/web', lastOpenedAt: 1 },
    ],
    transcripts: new Map(),
    messages: new Map(),
    gitRepo: new Set(['/work/api']),
  }
  const surface: DeckSurface = {
    listSessions: () => state.sessions,
    sessionStatus: (id) => state.statuses.get(id) ?? null,
    startSession: async (input) => {
      const created = session({ id: `new-${state.sessions.length + 1}`, cwd: input.cwd })
      state.sessions = [...state.sessions, created]
      return created
    },
    writeToSession: (id, data) => {
      state.typed.push({ id, data })
    },
    killSession: (id) => {
      state.sessions = state.sessions.filter((one) => one.id !== id)
    },
    sessionScreen: async (id) => (state.sessions.some((one) => one.id === id) ? (state.screens.get(id) ?? '') : null),
    sessionScrollback: () => '',
    listProjects: () => state.projects,
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
    gitStatus: async (cwd) => ({ repo: state.gitRepo.has(cwd), cwd }),
    alerts: async () => ({ alerts: [] }),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: () => ({}),
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/state/last-good.json', at: 0 }),
    transcriptsIn: async (cwd) => state.transcripts.get(cwd) ?? [],
    transcriptBytes: async (path) => (state.messages.has(path) ? 1_000 : 0),
    readTranscriptFrom: async (path) => state.messages.get(path) ?? [],
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({ repo: false, root: null, branch: null, ahead: 0, behind: 0, files: [], reason: 'none' }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  }
  return { state, surface }
}

/** A clock a test moves, and a sleep that moves it instead of waiting. */
export function fakeClock(start = 10_000): { now: () => number; sleep: (ms: number) => Promise<void>; advance(ms: number): void } {
  let at = start
  return {
    now: () => at,
    sleep: async (ms) => {
      at += ms
    },
    advance: (ms) => {
      at += ms
    },
  }
}

export function contextFor(
  surface: DeckSurface,
  options: { now?: () => number; own?: readonly string[] } = {},
): ToolContext {
  const own = new Set(options.own ?? [])
  return {
    surface,
    callId: 'call-1',
    caller: LOCAL_CALLER,
    attended: true,
    startedByCopilot: (id) => own.has(id),
    noteStarted: (id) => {
      own.add(id)
    },
    now: options.now ?? (() => 10_000),
  }
}

/** One tool out of a factory's list, by id, or a loud failure. */
export function toolNamed(tools: readonly ToolSpec[], id: string): ToolSpec {
  const found = tools.find((tool) => tool.id === id)
  if (found === undefined) throw new Error(`no tool ${id} in this list`)
  return found
}
