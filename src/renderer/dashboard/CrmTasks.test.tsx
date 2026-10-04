import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { toTasksState } from '../tasks/tasks-model'
import { CrmTasks, watchTasks } from './CrmTasks'

/**
 * Overview → CRM tasks, rendered. Read-only: the CRM is the task master, so
 * the only control is closing a session that is being kept open.
 */

const NOW = 1_800_000_000_000
const EMPTY = { agents: [], connections: [], keys: [], tasks: [], outbox: { pending: 0, undelivered: 0 } }
const closeOnly = { tasksCloseSession: () => Promise.resolve({ ok: true, state: EMPTY }) }

function render(raw: unknown): string {
  return renderToStaticMarkup(<CrmTasks bridge={closeOnly} state={toTasksState(raw)} now={NOW} />)
}

describe('CRM tasks on the Overview', () => {
  it('draws nothing with no tasks and no connections', () => {
    expect(render(EMPTY)).toBe('')
  })

  it('draws nothing without a preload, so the Overview renders as before', () => {
    expect(renderToStaticMarkup(<CrmTasks bridge={{}} />)).toBe('')
  })

  it('says it is waiting for work once a CRM is connected', () => {
    const html = render({ ...EMPTY, connections: [{ keyId: 'k1' }] })
    expect(html).toContain('CRM tasks')
    expect(html).toContain('No tasks from your CRM yet')
  })

  it('shows a row’s title, agent, CRM status as stored, and process state', () => {
    const html = render({
      ...EMPTY,
      tasks: [
        { id: 'k1:42', title: 'Fix the login page', agent: 'Builder', crmStatus: 'Working on it', process: 'running', keepOpenUntil: null },
      ],
    })
    expect(html).toContain('Fix the login page')
    expect(html).toContain('Builder')
    expect(html).toContain('Working on it')
    expect(html).toContain('Running')
    expect(html).toContain('1 running')
    expect(html).not.toContain('Close session')
  })

  it('says how long a finished session stays open, and offers to close it', () => {
    const html = render({
      ...EMPTY,
      tasks: [
        { id: 'k1:43', title: 'Review copy', agent: 'Reviewer', crmStatus: 'Done', process: 'exited', keepOpenUntil: NOW + 12 * 60_000 },
      ],
    })
    expect(html).toContain('Done')
    expect(html).toContain('Finished')
    expect(html).toContain('kept open for 12 min')
    expect(html).toContain('Close session')
  })

  it('reads again on every change the main process announces, and stops when unsubscribed', async () => {
    const task = (crmStatus: string) => ({
      id: 'k1:T-1', keyId: 'k1', externalTaskId: 'T-1', title: 'Fix the login bug', agent: 'Builder', project: '/work/app',
      crmStatus, process: 'running', keepOpenUntil: null, verified: null, updatedAt: NOW,
    })
    let current = { ...EMPTY, tasks: [task('Working on it')] }
    const hook: { announce: (() => void) | null } = { announce: null }
    let reads = 0
    const bridge = {
      tasksState: () => {
        reads += 1
        return Promise.resolve(current)
      },
      onTasksChanged: (callback: () => void) => {
        hook.announce = callback
        return () => {
          hook.announce = null
        }
      },
    }
    const seen: Array<string | undefined> = []
    const settle = () => new Promise((resolve) => setImmediate(resolve))
    const stop = watchTasks(bridge, (state) => seen.push(state?.tasks[0]?.crmStatus))
    await settle()
    expect(seen).toEqual(['Working on it'])

    // The CRM records a status; main announces the change; the list reads it.
    current = { ...EMPTY, tasks: [task('In Progress')] }
    hook.announce?.()
    await settle()
    expect(seen).toEqual(['Working on it', 'In Progress'])
    expect(renderToStaticMarkup(<CrmTasks bridge={closeOnly} state={toTasksState(current)} now={NOW} />)).toContain('In Progress')

    stop()
    expect(hook.announce).toBeNull()
    expect(reads).toBe(2)
  })
})
