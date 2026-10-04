import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { LocalTaskPopup, ProjectCell, crmTaskOf, linkedTaskId } from './LocalTaskPopup'
import { TaskDetailBody } from './task-detail-panel'
import { SubtasksTable } from './page/subtasks-table'
import { DependenciesSection } from './dependencies-section'
import { ChecklistsBlock } from './page/checklists-block'
import { DetailAttachmentsSection } from './detail-attachments'
import { ActivityPane } from './page/activity-pane'
import type { DetailActions } from './detail-actions'
import type { TaskFieldActions } from './task-fields-section'
import { localPeople } from '../../shared/crm/detail-contract'
import type { TaskPeople } from '../../shared/crm/collab-types'
import type { TaskRow } from '../tasks/tasks-model'

/**
 * The reference CRM's task popup, drawn for a local task with fake calls.
 *
 * The dialog itself appears only once mounted (it portals into the page), so a
 * static render draws its body directly, and each section that waits for the
 * main process's answer is drawn with rows of its own.
 */

/** Every call answers "ok", with nothing in it — enough for a first paint. */
const fake = <T,>(): T => new Proxy({}, { get: () => async () => ({ ok: true }) }) as T
const actions = fake<DetailActions>()
const fieldActions = fake<TaskFieldActions>()

const row: TaskRow = {
  id: 'local:a', keyId: 'local', externalTaskId: 'a', title: 'Ship the release\nThen tell everyone it is out.', agent: 'Builder', project: '/work/app',
  crmStatus: 'In Progress', process: 'idle', keepOpenUntil: null, verified: null, updatedAt: 1, local: true, assignee: 'builder', instructions: 'Check the notes first.',
  handedFrom: null, notes: [], priority: 'High', startDate: '2026-10-05', dueDate: '2026-10-09', startTime: null, dueTime: '17:00', labels: ['web'], board: 'Launch',
  taskType: 'task', estimateMinutes: 90, archivedAt: null, deletedAt: null, completedAt: null, position: null, recurrence: null, createdAt: Date.UTC(2026, 9, 1),
}
const agents = [{ id: 'builder', name: 'Builder' }]
const team = localPeople(agents)
const people: TaskPeople = { primary: team[2], others: [team[0]] }

describe('a local task as the CRM task', () => {
  it('maps the fields the popup reads', () => {
    const task = crmTaskOf(row, team)
    expect(task).toMatchObject({
      id: 'local:a', group: 'In Progress', board: 'Launch', priority: 'High', startDate: '2026-10-05', dueDate: '2026-10-09', dueTime: '17:00',
      description: 'Check the notes first.', assigneeUserId: 'builder', assigneeName: 'Builder', createdBy: 'me', links: [], labels: ['web'],
    })
    expect(crmTaskOf({ ...row, assignee: 'none', board: null, dueDate: null }, team)).toMatchObject({ assigneeUserId: null, assigneeName: 'Unassigned', board: '', dueDate: '' })
  })

  it('reads a task link in either spelling, and nothing else', () => {
    expect(linkedTaskId('task:local%3Ab')).toBe('local:b')
    expect(linkedTaskId('/tasks?task=local%3Ab')).toBe('local:b')
    expect(linkedTaskId('https://example.com/?task=x')).toBeNull()
  })
})

describe('the popup', () => {
  const body = (): string =>
    renderToStaticMarkup(
      <TaskDetailBody
        task={crmTaskOf(row, team)}
        team={team}
        currentUserId="me"
        onClose={() => undefined}
        onPatched={() => undefined}
        onDelete={() => undefined}
        siblings={['local:z', 'local:a', 'local:b']}
        onNavigate={() => undefined}
        taskOptions={[{ id: 'local:b', title: 'Other' }]}
        onGone={() => undefined}
        actions={actions}
        fieldActions={fieldActions}
        boards={['Launch', 'Ops']}
        projectField={<ProjectCell task={row} bridge={null} />}
        full={false}
        onToggleFull={() => undefined}
      />,
    )

  it('draws the CRM header: previous and next, the board, ⋯ and close', () => {
    const html = body()
    expect(html).toContain('aria-label="Previous task"')
    expect(html).toContain('aria-label="Next task"')
    expect(html).toContain('>Launch</span>')
    expect(html).toContain('aria-label="Move task"')
    expect(html).toContain('aria-label="Close"')
    expect(html).toContain('aria-label="More"')
  })

  it('draws the property grid with every CRM row, Related to unavailable, and the local Project folder', () => {
    const html = body()
    for (const label of ['Status', 'Assignees', 'Project folder', 'Dates', 'Priority', 'Track time', 'Tags', 'Related to']) {
      expect(html, label).toMatch(new RegExp(`</svg>${label}</dt>`))
    }
    expect(html).toContain('data-testid="cell-unavailable"')
    expect(html).toContain('title="Related records live in a CRM — local tasks cannot link to them."')
    expect(html).toContain('data-testid="project-cell"')
    expect(html).toContain('>/work/app</button>')
  })

  it('draws the heading and body text, the details, the custom fields and the sections that load', () => {
    const html = body()
    expect(html).toContain('data-testid="task-title-block"')
    expect(html).toContain('Ship the release')
    expect(html).toContain('data-testid="task-body"')
    expect(html).toContain('Then tell everyone it is out.')
    expect(html).toContain('Check the notes first.')
    expect(html).toContain('data-testid="task-fields-mount"')
    expect(html).toContain('data-testid="bundle-skeleton"')
    expect(html).toContain('data-testid="task-page-columns"')
  })

  it('draws the activity and comments pane beside it', () => {
    expect(body()).toContain('aria-label="Collapse activity"')
  })

  it('mounts through the CRM dialog, inside the host that keeps links in the app', () => {
    const html = renderToStaticMarkup(
      <LocalTaskPopup task={row} tasks={[row]} siblings={['local:a']} agents={agents} onNavigate={() => undefined} onClose={() => undefined} onDelete={() => undefined} bridge={null} />,
    )
    // The dialog portals in only once mounted; on the server the host is all there is.
    expect(html).toBe('<div class="crm-task-host"></div>')
  })
})

describe('the popup’s sections, with rows', () => {
  it('subtasks', () => {
    const html = renderToStaticMarkup(
      <SubtasksTable
        rows={[{ id: 's1', title: 'Write notes', done: false, sortOrder: 0, assigneeUserId: null }, { id: 's2', title: 'Tag it', done: true, sortOrder: 1, assigneeUserId: 'me' }]}
        people={people}
        team={team}
        meta={{ s1: { priority: 'High', dueDate: '2026-10-08' } }}
        currentUserId="me"
        onChange={() => undefined}
        onMeta={() => undefined}
      />,
    )
    expect(html).toContain('Write notes')
    expect(html).toContain('Tag it')
    expect(html).toMatch(/Subtasks/)
  })

  it('dependencies', () => {
    const html = renderToStaticMarkup(
      <DependenciesSection rows={[{ kind: 'blocked_by', otherTaskId: 'local:b', otherTitle: 'Get sign-off', otherDone: false }]} onChange={() => undefined} />,
    )
    expect(html).toContain('Get sign-off')
  })

  it('checklists', () => {
    const html = renderToStaticMarkup(
      <ChecklistsBlock
        lists={[{ id: 'l1', title: 'Before launch', sortOrder: 0, items: [{ id: 'i1', title: 'Backups', done: true, sortOrder: 0, assigneeUserId: null }] }]}
        people={people}
        team={team}
        onChange={() => undefined}
      />,
    )
    expect(html).toContain('Before launch')
    expect(html).toContain('Backups')
  })

  it('attachments: a picture from its preview, every file by its local address', () => {
    const html = renderToStaticMarkup(
      <DetailAttachmentsSection
        taskId="local:a"
        rows={[
          { id: 'f1', kind: 'upload', fileName: 'plan.pdf', mimeType: 'application/pdf', sizeBytes: 2048, documentId: null, storagePath: 'x', uploadedBy: 'me', createdAt: '2026-10-01T00:00:00Z' },
          { id: 'f2', kind: 'upload', fileName: 'shot.png', mimeType: 'image/png', sizeBytes: 10, documentId: null, storagePath: 'y', uploadedBy: 'me', createdAt: '2026-10-01T00:00:00Z', previewUrl: 'data:image/png;base64,AAAA' },
        ]}
        onChange={() => undefined}
      />,
    )
    expect(html).toContain('href="task-file:local%3Aa/f1"')
    expect(html).toContain('src="data:image/png;base64,AAAA"')
    expect(html).toContain('2 KB')
  })

  it('the activity and comments pane', () => {
    const html = renderToStaticMarkup(
      <ActivityPane
        taskId="local:a"
        viewerId="me"
        team={team}
        people={people}
        activity={[{ id: 'r1', taskId: 'local:a', kind: 'created', payload: {}, actor: team[0], actorUserId: 'me', createdAt: '2026-10-01T09:00:00Z' }]}
        activityError={null}
        comments={[{ id: 'c1', taskId: 'local:a', authorUserId: 'builder', authorName: 'Builder', authorInitials: 'BU', authorColor: 'bg-blue-500', body: 'Should I ship to staging first?', createdAt: '2026-10-01T10:00:00Z' }]}
        commentsError={null}
        attachments={[]}
        onPost={async () => true}
        commands={[]}
        fileOf={() => null}
      />,
    )
    expect(html).toContain('Activity')
    expect(html).toContain('Should I ship to staging first?')
  })
})
