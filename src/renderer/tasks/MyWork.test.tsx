import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { DEFAULT_VIEW, MyWork, TrashList, type MyWorkActions } from './MyWork'
import { toTasksState, type TaskRow } from './tasks-model'

/** The three views of your own tasks, rendered from fixed data. */

const NOW = new Date(2026, 9, 7, 10, 0).getTime() // Wednesday 7 Oct, 10:00
const ok = async () => ({ ok: true, message: null, state: null, secret: null })
const actions: MyWorkActions = { create: ok, update: ok, remove: ok, restore: ok }

function row(over: Partial<TaskRow>): Record<string, unknown> {
  return {
    id: `local:${String(over.title)}`, keyId: 'local', externalTaskId: 'x', agent: 'Me', project: '', crmStatus: 'To-Do', process: 'idle',
    keepOpenUntil: null, verified: null, updatedAt: NOW, local: true, assignee: 'me', instructions: '', handedFrom: null, notes: [],
    priority: null, startDate: null, dueDate: null, startTime: null, dueTime: null, labels: [], board: null, taskType: 'task',
    estimateMinutes: null, archivedAt: null, completedAt: null, position: null, recurrence: null, createdAt: NOW,
    ...over,
  }
}

const state = toTasksState({
  agents: [{ id: 'builder', name: 'Builder' }],
  connections: [],
  keys: [],
  outbox: { pending: 0, undelivered: 0 },
  localStatuses: ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck'],
  tasks: [
    row({ title: 'Plan', priority: 'High', dueDate: '2026-10-06', labels: ['a', 'b', 'c', 'd'], board: 'Launch' }),
    row({ title: 'Build', crmStatus: 'Working on it', assignee: 'builder', dueDate: '2026-10-07', dueTime: '17:00' }),
    row({ title: 'Ship', crmStatus: 'Stuck', taskType: 'milestone' }),
    row({ title: 'Old', crmStatus: 'Done' }),
  ],
})!

const render = (tab: 'table' | 'board' | 'calendar', groupBy = DEFAULT_VIEW.groupBy) =>
  renderToStaticMarkup(
    <MyWork state={state} now={NOW} busy={false} actions={actions} run={async () => true} renderPopup={() => <div />} initialView={{ ...DEFAULT_VIEW, tab, groupBy }} />,
  )

describe('My Work, in three views', () => {
  it('the table: tiles, the stages with Done folded, and each row’s cells', () => {
    const html = render('table')
    expect(html).toMatch(/<span class="mw-tile-value">3<\/span><span class="mw-tile-label">Open/)
    expect(html).toMatch(/<span class="mw-tile-value">1<\/span><span class="mw-tile-label">Overdue/)
    expect(html).toMatch(/<span class="mw-tile-value">1<\/span><span class="mw-tile-label">Done/)
    for (const stage of ['To-Do', 'Working on it', 'Stuck']) expect(html).toContain(`aria-label="${stage}"`)
    expect(html).toContain('aria-expanded="false"><span aria-hidden="true">▸</span> Done')
    expect(html).not.toContain('>Old</button>')
    expect(html).toContain('<span>Yesterday</span>')
    expect(html).toContain('<span>Today, 17:00</span>')
    expect(html).toContain('data-overdue="true"')
    expect(html).toContain('<span class="mw-tag">+1</span>')
    expect(html).toContain('data-shape="diamond"')
    expect(html).toContain('<option value="High" selected="">⚑ High</option>')
  })

  it('the board: one column per stage, a card per task, in the CRM order', () => {
    const html = render('board')
    const stages = [...html.matchAll(/class="mw-stage"[^>]*aria-label="([^"]+)"/g)].map((match) => match[1])
    expect(stages).toEqual(['To-Do, 1', 'Working on it, 1', 'In Progress, 0', 'Stuck, 1', 'Done, 1'])
    expect(html).toContain('draggable="true"')
    expect(html).toContain('>◆ Ship</button>')
    expect(html).toContain('<span class="mw-card-board">Launch</span>')
    expect(html.match(/>\+ Add task</g)).toHaveLength(5)
  })

  it('the calendar: the week by due date, with a way to add on any day', () => {
    const html = render('calendar')
    expect(html.match(/class="mw-day"/g)).toHaveLength(7)
    expect(html).toContain('data-today="true" aria-label="Wed 7/10"')
    expect(html).toContain('>Build</button>')
    expect(html.match(/>\+ Add</g)).toHaveLength(7)
    // A task's name opens it; its ring marks it done.
    expect(html).toContain('aria-haspopup="dialog">Build</button>')
    expect(html).toContain('aria-label="Mark Build done"')
  })

  it('groups by board, project or any other option on request', () => {
    expect(render('table', 'board')).toContain('aria-label="Launch"')
    expect(render('table', 'due')).toContain('aria-label="Overdue"')
  })

  it('opens the popup for the clicked task in every view, with the view’s own order for ▲ ▼', () => {
    for (const tab of ['table', 'board', 'calendar'] as const) {
      const html = render(tab)
      expect(html, tab).toMatch(/aria-haspopup="dialog"[^>]*>(◆ )?(Plan|Build|Ship)<\/button>/)
    }
    const calls: Array<{ title: string; siblings: string[] }> = []
    const html = renderToStaticMarkup(
      <MyWork
        state={state}
        now={NOW}
        busy={false}
        actions={actions}
        run={async () => true}
        initialView={{ ...DEFAULT_VIEW, tab: 'board' }}
        initialOpen="local:Build"
        renderPopup={(task, siblings) => {
          calls.push({ title: task.title, siblings })
          return <div className="popup-stand-in">{task.title}</div>
        }}
      />,
    )
    expect(html).toContain('<div class="popup-stand-in">Build</div>')
    // The board's order: To-Do, Working on it, In Progress, Stuck, Done.
    expect(calls[0]).toEqual({ title: 'Build', siblings: ['local:Plan', 'local:Build', 'local:Ship', 'local:Old'] })
    // Nothing is opened inline under a row any more.
    expect(render('table')).not.toContain('popup-stand-in')
  })
})

describe('the Trash', () => {
  it('is a choice beside Archived, counting what is in it', () => {
    const withTrash = toTasksState({ ...JSON.parse(JSON.stringify(state)), trash: [row({ title: 'Gone', deletedAt: NOW - 3 * 3_600_000 })] })!
    const html = renderToStaticMarkup(
      <MyWork state={withTrash} now={NOW} busy={false} actions={actions} run={async () => true} renderPopup={() => <div />} initialView={{ ...DEFAULT_VIEW, tab: 'table' }} />,
    )
    expect(html).toMatch(/<input type="checkbox"\/>Trash \(1\)<\/label>/)
  })

  it('lists each deleted task with when it went and a Restore, and says what it is for when empty', () => {
    const gone = toTasksState({ ...JSON.parse(JSON.stringify(state)), trash: [row({ title: 'Gone', deletedAt: NOW - 3 * 3_600_000 })] })!.trash
    const html = renderToStaticMarkup(<TrashList tasks={gone} now={NOW} busy={false} onRestore={() => undefined} />)
    expect(html).toContain('<ul class="mw-trash" aria-label="Trash">')
    expect(html).toContain('<span class="mw-trash-title">Gone</span><span class="mw-trash-when">Deleted 3 hours ago</span>')
    expect(html).toContain('>Restore</button>')
    expect(renderToStaticMarkup(<TrashList tasks={[]} now={NOW} busy={false} onRestore={() => undefined} />)).toContain(
      'The Trash is empty. A task you delete, merge or make a subtask waits here until you restore it.',
    )
  })
})
