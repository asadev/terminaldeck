import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { TaskDetailBody } from './task-detail-panel'
import { crmTaskOf, LocalTaskPopup } from './LocalTaskPopup'
import {
  showsWorkspace,
  windowWorkspaceBridge,
  workspaceActions,
  WorkspaceCell,
  workspaceViewOf,
  type WorkspaceBridge,
  type WorkspaceViewModel,
} from './workspace-cell'
import type { DetailActions } from './detail-actions'
import type { TaskFieldActions } from './task-fields-section'
import { localPeople } from '../../shared/crm/detail-contract'
import type { TaskRow } from '../tasks/tasks-model'

const FOLDER = '/Users/me/Library/Application Support/Terminal Deck/workspaces/0f3c/local-a-1a2b3c4d'
const BRANCH = 'td/fix-the-login-page-1a2b3c4d'

function view(state: 'active' | 'kept' | 'removed', reason: string | null = null): WorkspaceViewModel {
  return { workspace: { folder: FOLDER, branch: BRANCH, repo: '/work/app', state, reason }, refusal: null }
}

const draw = (model: WorkspaceViewModel, extra: { busy?: boolean; note?: { ok: boolean; text: string } | null } = {}): string =>
  renderToStaticMarkup(<WorkspaceCell view={model} onOpen={() => undefined} onRemove={() => undefined} {...extra} />)

describe('the workspace row', () => {
  it('shows the branch, the state and the folder, with both actions', () => {
    const html = draw(view('active'))
    expect(html).toContain(`>${BRANCH}</span>`)
    expect(html).toContain('>Active</span>')
    expect(html).toContain(`title="${FOLDER}"`)
    expect(html).toContain('>Open folder</button>')
    expect(html).toContain('>Remove when clean</button>')
    expect(html).not.toContain('data-testid="workspace-note"')
  })

  it('says why a kept one was kept, as an alert', () => {
    const reason = 'It has 2 uncommitted changes (a.txt, new.txt), so it was kept. Commit or discard them, then remove it.'
    const html = draw(view('kept', reason))
    expect(html).toContain('>Kept</span>')
    expect(html).toContain(`role="alert"`)
    expect(html).toContain(reason)
    expect(html).toContain('>Remove when clean</button>')
  })

  it('shows a removed one with its kept branch and no actions', () => {
    const html = draw(view('removed', `Removed. Its branch ${BRANCH} stays in /work/app, with every commit made on it.`))
    expect(html).toContain('>Removed</span>')
    expect(html).toContain('role="status"')
    expect(html).toContain(`Its branch ${BRANCH} stays in /work/app`)
    expect(html).not.toContain('<button')
  })

  it('shows why a task has none', () => {
    const html = draw({ workspace: null, refusal: '/work/notes is not a git repository, so the task runs in the project folder itself.' })
    expect(html).toContain('None. /work/notes is not a git repository, so the task runs in the project folder itself.')
    expect(html).not.toContain('<button')
  })

  it('holds the remove button while a removal is under way', () => {
    const html = draw(view('active'), { busy: true })
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Removing…<\/button>/)
  })

  it('shows what the last action said in place of the stored reason', () => {
    const html = draw(view('kept', 'older reason'), { note: { ok: false, text: 'The folder could not be opened.' } })
    expect(html).toContain('The folder could not be opened.')
    expect(html).not.toContain('older reason')
  })
})

describe('the row in the task detail', () => {
  const fake = <T,>(): T => new Proxy({}, { get: () => async () => ({ ok: true }) }) as T
  const row: TaskRow = {
    id: 'local:a', keyId: 'local', externalTaskId: 'a', title: 'Fix the login page', agent: 'Builder', project: '/work/app',
    crmStatus: 'In Progress', process: 'idle', keepOpenUntil: null, verified: null, updatedAt: 1, local: true, assignee: 'builder', instructions: '',
    handedFrom: null, notes: [], priority: null, startDate: null, dueDate: null, startTime: null, dueTime: null, labels: [], board: null,
    taskType: 'task', estimateMinutes: null, archivedAt: null, deletedAt: null, completedAt: null, position: null, recurrence: null, createdAt: 1,
  }
  const team = localPeople([{ id: 'builder', name: 'Builder' }])
  const body = (workspaceField?: React.ReactNode): string =>
    renderToStaticMarkup(
      <TaskDetailBody
        task={crmTaskOf(row, team)}
        team={team}
        currentUserId="me"
        onClose={() => undefined}
        onPatched={() => undefined}
        onDelete={() => undefined}
        actions={fake<DetailActions>()}
        fieldActions={fake<TaskFieldActions>()}
        boards={[]}
        workspaceField={workspaceField}
        full={false}
        onToggleFull={() => undefined}
      />,
    )

  it('is a "Workspace" property beside the project folder when there is one to show', () => {
    const html = body(<WorkspaceCell view={view('active')} onOpen={() => undefined} onRemove={() => undefined} />)
    expect(html).toMatch(/<\/svg>Workspace<\/dt>/)
    expect(html).toContain('data-testid="task-workspace"')
    expect(html).toContain('data-testid="workspace-cell"')
  })

  it('is not drawn when there is nothing to show', () => {
    expect(body()).not.toContain('data-testid="task-workspace"')
  })

  it('leaves the popup drawing as before until the main process answers', () => {
    const bridge: WorkspaceBridge = { taskWorkspace: async () => view('active'), taskWorkspaceOpen: async () => ({ ok: true }), taskWorkspaceRemove: async () => ({}) }
    const html = renderToStaticMarkup(
      <LocalTaskPopup task={row} tasks={[row]} siblings={['local:a']} agents={[]} onNavigate={() => undefined} onClose={() => undefined} onDelete={() => undefined} bridge={null} workspaceBridge={bridge} />,
    )
    expect(html).toContain('crm-task-host')
  })
})

describe('what crosses the bridge', () => {
  it('is checked before it is drawn', () => {
    expect(workspaceViewOf(null)).toEqual({ workspace: null, refusal: null })
    expect(workspaceViewOf({ workspace: { folder: FOLDER, branch: BRANCH, repo: '/work/app', state: 'lost' }, refusal: 'why' })).toEqual({ workspace: null, refusal: 'why' })
    expect(workspaceViewOf({ workspace: { folder: FOLDER, branch: BRANCH, repo: '/work/app', state: 'kept', reason: 'r', extra: 1 }, refusal: null })).toEqual(view('kept', 'r'))
  })

  it('decides whether the row is drawn at all', () => {
    expect(showsWorkspace(null)).toBe(false)
    expect(showsWorkspace({ workspace: null, refusal: null })).toBe(false)
    expect(showsWorkspace({ workspace: null, refusal: 'not a repository' })).toBe(true)
    expect(showsWorkspace(view('removed'))).toBe(true)
  })

  it('is nothing in a build without the calls', () => {
    expect(windowWorkspaceBridge()).toBeNull()
  })
})

describe('the row’s calls', () => {
  function recording(answers: Partial<Record<keyof WorkspaceBridge, unknown>>): { bridge: WorkspaceBridge; calls: string[] } {
    const calls: string[] = []
    const answer = (name: keyof WorkspaceBridge) => async (taskId: string): Promise<unknown> => {
      calls.push(`${name}(${taskId})`)
      const value = answers[name]
      if (value instanceof Error) throw value
      return value
    }
    return {
      calls,
      bridge: { taskWorkspace: answer('taskWorkspace'), taskWorkspaceOpen: answer('taskWorkspaceOpen'), taskWorkspaceRemove: answer('taskWorkspaceRemove') },
    }
  }

  it('send the task id and nothing else', async () => {
    const { bridge, calls } = recording({ taskWorkspace: view('active'), taskWorkspaceOpen: { ok: true }, taskWorkspaceRemove: { ok: true, message: 'Removed.', view: view('removed', 'Removed.') } })
    const actions = workspaceActions(bridge, 'local:a')
    expect(await actions.load()).toEqual(view('active'))
    expect(await actions.open()).toBeNull()
    expect(await actions.remove()).toEqual({ view: view('removed', 'Removed.'), note: { ok: true, text: 'Removed.' } })
    expect(calls).toEqual(['taskWorkspace(local:a)', 'taskWorkspaceOpen(local:a)', 'taskWorkspaceRemove(local:a)'])
  })

  it('carry a refusal back as words', async () => {
    const kept = 'It has 1 uncommitted change (a.txt), so it was kept. Commit or discard them, then remove it.'
    const { bridge } = recording({ taskWorkspaceOpen: { ok: false, error: 'No such folder' }, taskWorkspaceRemove: { ok: false, message: kept, view: view('kept', kept) } })
    const actions = workspaceActions(bridge, 'local:a')
    expect(await actions.open()).toEqual({ ok: false, text: 'No such folder' })
    expect(await actions.remove()).toEqual({ view: view('kept', kept), note: { ok: false, text: kept } })
  })

  it('never reject, and say so when the build has no calls', async () => {
    const { bridge } = recording({ taskWorkspace: new Error('gone'), taskWorkspaceOpen: new Error('denied'), taskWorkspaceRemove: new Error('denied') })
    const actions = workspaceActions(bridge, 'local:a')
    expect(await actions.load()).toEqual({ workspace: null, refusal: null })
    expect(await actions.open()).toEqual({ ok: false, text: 'denied' })
    expect((await actions.remove()).note).toEqual({ ok: false, text: 'denied' })
    expect((await workspaceActions(null, 'local:a').remove()).note.ok).toBe(false)
  })
})
