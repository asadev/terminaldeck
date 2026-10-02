import { describe, expect, it, vi } from 'vitest'
import type { DownloadRow, DownloadsView } from '../browser-downloads-store'
import type { ToolContext } from './catalogue'
import { downloadTools, opensAsData, type DownloadToolDeps } from './browser-download-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext
const SESSION = { caller: { kind: 'session', sessionId: 's1', tiers: LOCAL_CALLER.tiers } } as unknown as ToolContext

function row(over: Partial<DownloadRow>): DownloadRow {
  return {
    id: 'd1',
    name: 'report.pdf',
    url: 'https://example.com/report.pdf',
    bytes: 10,
    received: 10,
    state: 'done',
    path: '/Users/me/Downloads/report.pdf',
    onMachine: '',
    onMachineName: '',
    message: '',
    startedAt: 1,
    ...over,
  } as DownloadRow
}

function deps(items: DownloadRow[], over: Partial<DownloadToolDeps> = {}): DownloadToolDeps {
  const view = (): DownloadsView => ({
    destination: { machineId: '', machineName: '', folder: '' },
    defaultFolder: '/Users/me/Downloads/App',
    items,
  })
  return {
    view,
    cancel: () => view(),
    clear: () => ({ ...view(), items: items.filter((one) => one.state === 'downloading') }),
    open: async () => ({ ok: true, message: '' }),
    reveal: () => ({ ok: true, message: '' }),
    setDestination: () => view(),
    chooseFolder: async () => '/Users/me/Elsewhere',
    executableBit: () => false,
    ...over,
  }
}

describe('what opens without asking', () => {
  it('opens plain documents, pictures and archives', () => {
    for (const name of ['a.pdf', 'b.PNG', 'c.zip', 'd.csv', 'e.docx']) {
      expect(opensAsData({ name, path: `/x/${name}` }, () => false), name).toBe(true)
    }
  })

  it('asks for anything that runs, carries macros, mounts an app, or cannot be placed', () => {
    for (const name of ['setup.pkg', 'App.dmg', 'run.command', 'tool.sh', 'sheet.xlsm', 'thing', 'odd.weird', 'Tool.app']) {
      expect(opensAsData({ name, path: `/x/${name}` }, () => false), name).toBe(false)
    }
  })

  it('asks for a file marked executable whatever its name says', () => {
    expect(opensAsData({ name: 'notes.txt', path: '/x/notes.txt' }, () => true)).toBe(false)
  })
})

describe('browser.downloads', () => {
  it('opens a document at act and an installer at alter, decided from the file', () => {
    const [tool] = downloadTools(
      deps([row({ id: 'pdf' }), row({ id: 'pkg', name: 'setup.pkg', path: '/Users/me/Downloads/setup.pkg' })]),
    )
    expect(tool.escalate?.({ action: 'open', download: 'pdf' }, DESK)).toBe('act')
    expect(tool.escalate?.({ action: 'open', download: 'pkg' }, DESK)).toBe('alter')
    // A row that cannot be found is the dangerous reading, not the routine one.
    expect(tool.escalate?.({ action: 'open', download: 'gone' }, DESK)).toBe('alter')
  })

  it('makes clearing the list and moving the destination alter', () => {
    const [tool] = downloadTools(deps([]))
    expect(tool.escalate?.({ action: 'clear' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'destination', folder: '/x' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'cancel', download: 'd1' }, DESK)).toBe('act')
  })

  it('says a clear took rows and left every file where it was', async () => {
    const [tool] = downloadTools(deps([row({}), row({ id: 'd2' })]))
    const out = (await tool.run({ action: 'clear' }, DESK)).value as { cleared: number; note: string }
    expect(out.cleared).toBe(2)
    expect(out.note).toContain('Every file is where it was')
  })

  it('refuses to open a file that is on another machine, before anybody is asked', () => {
    const [tool] = downloadTools(deps([row({ onMachine: 'pc', onMachineName: 'Office PC' })]))
    expect(() => tool.precheck?.({ action: 'open', download: 'd1' }, DESK)).toThrow('on Office PC')
  })

  it('refuses a folder that is not a full path', () => {
    const [tool] = downloadTools(deps([]))
    expect(() => tool.precheck?.({ action: 'destination', folder: 'Downloads' }, DESK)).toThrow('not a full path')
  })

  it('opens the folder chooser for the person when no folder is named, and keeps what they pick', async () => {
    const setDestination = vi.fn<DownloadToolDeps['setDestination']>(() => deps([]).view())
    const [tool] = downloadTools(deps([], { setDestination }))
    await tool.run({ action: 'destination' }, DESK)
    expect(setDestination).toHaveBeenCalledWith({ machineId: '', machineName: '', folder: '/Users/me/Elsewhere' })
  })

  it('refuses the chooser when nobody is there to use it', () => {
    const [tool] = downloadTools(deps([]))
    expect(() =>
      tool.precheck?.({ action: 'destination' }, { ...DESK, attended: false } as ToolContext),
    ).toThrow('needs a person at this Mac')
  })

  it('is refused to an ordinary session', () => {
    const [tool] = downloadTools(deps([]))
    expect(() => tool.precheck?.({}, SESSION)).toThrow('reaches only the windows attached to it')
  })

  it('passes a refusal from the panel’s own function through in its words', async () => {
    const [tool] = downloadTools(deps([row({})], { open: async () => ({ ok: false, message: 'That file is not there any more.' }) }))
    await expect(tool.run({ action: 'open', download: 'd1' }, DESK)).rejects.toThrow('not there any more')
  })
})
