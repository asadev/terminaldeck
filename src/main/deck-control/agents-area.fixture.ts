/**
 * A tool context for the agents-area tests: a fake surface with two open
 * folders, two sessions (one the copilot started), settings with a protected
 * key in them, and a record of every write.
 *
 * Imported by tests only. It is the smallest {@link DeckSurface} these tools
 * reach — sessions, projects, settings, a session start — and anything else on
 * it throws, so a tool that starts reaching for more fails loudly here rather
 * than passing against a stub that answers everything.
 */

import type { CreateSessionInput, SessionMeta } from '../../shared/types'
import type { ToolContext, ToolSpec } from './catalogue'
import { LOCAL_CALLER, type Caller, type DeckSurface } from './surface'

export interface FakeRecord {
  started: Array<{ input: CreateSessionInput; device: string | undefined }>
  settings: Record<string, string | number | boolean>
  trace: string[]
  noted: string[]
}

export function fakeContext(options: { caller?: Caller; mine?: string[] } = {}): {
  context: ToolContext
  record: FakeRecord
} {
  const record: FakeRecord = {
    started: [],
    settings: { 'appearance.density': 'compact', 'remote.enabled': true, 'advanced.debugMode': false, 'editor.font': 'Menlo' },
    trace: [],
    noted: [],
  }
  const sessions: SessionMeta[] = [
    { id: 'mine-1', cwd: '/work/api', title: 'api', provider: 'claude', exitCode: null, createdAt: 1 },
    { id: 'theirs-1', cwd: '/work/web', title: 'web', provider: 'claude', exitCode: null, createdAt: 2 },
  ]
  const mine = new Set(options.mine ?? ['mine-1'])
  const surface = new Proxy(
    {
      listSessions: () => sessions,
      sessionStatus: () => null,
      listProjects: () => [
        { path: '/work/api', lastOpenedAt: 2 },
        { path: '/work/web', lastOpenedAt: 1 },
      ],
      deviceFolders: (device: string) => (device === 'phone-1' ? ['/work/web'] : []),
      readSettings: () => ({ settings: { ...record.settings }, preferences: { theme: 'dark' } }),
      snapshotSettings: () => {
        record.trace.push('snapshot')
        return { path: '/state/settings.last-good.json', at: 1 }
      },
      writeSettings: (patch: Record<string, unknown>) => {
        record.trace.push(`write:${Object.keys(patch).sort().join(',')}`)
        for (const [key, value] of Object.entries(patch)) {
          if (value === null) delete record.settings[key]
        }
        return { ...record.settings }
      },
      applyToWindow: () => true,
      // No task has a workspace of its own here.
      taskWorkspaceFolders: () => [],
      startSession: async (input: CreateSessionInput, device?: string) => {
        record.started.push({ input, device })
        const meta: SessionMeta = {
          id: `started-${record.started.length}`,
          cwd: input.cwd,
          title: 'sign in',
          provider: input.provider ?? 'claude',
          exitCode: null,
          createdAt: 3,
        }
        sessions.push(meta)
        return meta
      },
    } as Partial<DeckSurface>,
    {
      get(target, key) {
        if (key in target) return target[key as keyof typeof target]
        throw new Error(`the agents-area fixture has no ${String(key)} — add it if a tool now needs it`)
      },
    },
  ) as DeckSurface
  const context: ToolContext = {
    surface,
    callId: 'call-1',
    caller: options.caller ?? LOCAL_CALLER,
    attended: true,
    startedByCopilot: (id) => mine.has(id),
    noteStarted: (id) => {
      record.noted.push(id)
      mine.add(id)
    },
    now: () => 10_000,
  }
  return { context, record }
}

/** One tool out of a factory's list, by id, or a failure naming the id. */
export function tool(tools: readonly ToolSpec[], id: string): ToolSpec {
  const found = tools.find((spec) => spec.id === id)
  if (found === undefined) throw new Error(`no tool ${id}`)
  return found
}

/** The tier a call would be judged at — what `control.ts` computes. */
export function tierOf(spec: ToolSpec, args: Record<string, unknown>, context: ToolContext): string {
  const rank = { read: 0, act: 1, alter: 2 } as const
  const raised = spec.escalate?.(args, context) ?? spec.tier
  return rank[raised] > rank[spec.tier] ? raised : spec.tier
}
