import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { LOCAL_DETAIL_FNS } from '../../shared/crm/detail-contract'

/**
 * The task popup is built, and it is wired: a click on one of your tasks in
 * any view opens it, and every call it makes reaches something in the main
 * process. Read from the sources, the way `src/renderer/wiring.test.ts` reads
 * the rest of the app, because a component that is never mounted renders
 * perfectly in its own tests.
 */

const SRC = join(__dirname, '..', '..')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

describe('the task popup is wired', () => {
  it('is what the Tasks page opens, and the old inline page is gone', () => {
    const page = read('renderer/tasks/TasksPage.tsx')
    expect(page).toContain("import { LocalTaskPopup } from '../crm-task/LocalTaskPopup'")
    expect(page).toMatch(/renderPopup=\{\(task, siblings, open, close\) => \(\s*<LocalTaskPopup/)
    expect(page).not.toContain('TaskDetail')
  })

  it('opens from a row title, a board card and a calendar item, once, outside the rows', () => {
    const work = read('renderer/tasks/MyWork.tsx')
    expect(work).toMatch(/className="mw-title"[^>]*aria-haspopup="dialog" onClick=\{onOpen\}/)
    expect(work).toMatch(/className="mw-card-title" aria-haspopup="dialog" onClick=\{\(\) => onOpen\(task\.id\)\}/)
    expect(work).toMatch(/className="mw-day-task"[^>]*aria-haspopup="dialog" onClick=\{\(\) => onOpen\(task\.id\)\}/)
    expect(work.match(/openTask !== undefined &&\s*renderPopup\(/g)).toHaveLength(1)
    expect(work).not.toMatch(/detail=\{/)
  })

  it('reaches the main process on one guarded channel the preload exposes', () => {
    expect(read('preload/index.ts')).toContain("tasksLocalDetail: (fn: string, args: unknown[]): Promise<unknown> => ipcRenderer.invoke('tasks:local-detail', fn, args)")
    expect(read('renderer/tasks/tasks-model.ts')).toContain("'tasksLocalDetail',")
    const ipc = read('main/tasks/tasks-ipc.ts')
    expect(ipc).toMatch(/ipcMain\.handle\('tasks:local-detail', async \(event, fn: unknown, args: unknown\) => \{\s*guard\(event\)/)
    expect(read('main/deck-control/index.ts')).toMatch(/detail: taskDetail/)
  })

  it('has an answer in the main process for every call the popup makes', () => {
    const main = read('main/tasks/task-detail-local.ts')
    const missing = LOCAL_DETAIL_FNS.filter((fn) => !main.includes(`case '${fn}':`))
    expect(missing).toEqual([])
  })

  it('a reminder clicked opens its task: main brings the window forward and asks, App shows the Tasks page, My Work opens it', () => {
    const main = read('main/index.ts')
    expect(main).toMatch(/showTask: \(taskId\) => \{[\s\S]{0,240}mainWindow\.focus\(\)\s*send\(TASKS_OPEN_CHANNEL, taskId\)/)
    expect(read('main/tasks/tasks-ipc.ts')).toContain("export const TASKS_OPEN_CHANNEL = 'tasks:open'")
    expect(read('preload/index.ts')).toContain("ipcRenderer.on('tasks:open', handler)")
    expect(read('renderer/App.tsx')).toContain("window.deck.onTasksOpen?.((taskId) => showPanel('tasks', `task:${taskId}@${Date.now()}`))")
    expect(read('renderer/shell/PanelView.tsx')).toContain("<TasksPage openTask={focus?.startsWith('task:') ? focus.slice('task:'.length) : null}")
    expect(read('renderer/tasks/TasksPage.tsx')).toMatch(/<MyWork\s+state=\{state\}\s+now=\{now\}\s+openRequest=\{openTask\}/)
    expect(read('renderer/tasks/MyWork.tsx')).toMatch(/useEffect\(\(\) => \{\s*if \(openRequest === null\) return[\s\S]{0,160}setOpen\(/)
    // And the clock wakes with the Mac.
    expect(main).toMatch(/powerMonitor\.on\('resume'[\s\S]*deckControl\?\.tasksWake\(\)/)
  })

  it('offers only what is true for one person: no follow or follower calls, no link to copy, sharing said to stay on this computer', () => {
    const actions = read('renderer/crm-task/local-actions.ts')
    for (const fn of ['setFollowing', 'addFollower', 'removeFollower']) expect(actions).not.toContain(`call('${fn}'`)
    const header = read('renderer/crm-task/page/page-header.tsx')
    expect(header).toContain('link={null}')
    expect(header).toContain('No link to share: this task lives on this computer. It can be shared only with your agents here — never with anyone outside it.')
    expect(read('renderer/crm-task/page/more-menu.tsx')).toMatch(/disabled=\{p\.link === null\}\s*title=\{p\.link === null \? NO_LINK : undefined\}/)
  })

  it('keeps every portal inside the popup root, so the scoped stylesheet reaches what it opens', () => {
    for (const file of ['anchored-popover.tsx', 'photo-lightbox.tsx', 'date-picker-input.tsx', 'ui/dialog.tsx', 'people/person-picker.tsx']) {
      const source = read(`renderer/crm-task/${file}`)
      expect(source, file).not.toMatch(/^\s+document\.body,$/m)
      expect(source, file).toContain('portalRoot(),')
    }
  })
})
