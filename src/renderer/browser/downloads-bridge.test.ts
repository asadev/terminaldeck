import { describe, expect, it } from 'vitest'
import {
  destinationLine,
  downloadLine,
  downloadProgress,
  downloadsAvailable,
  downloadsBadge,
  readAction,
  readDownloadsView,
  resolveDownloadsApi,
  SERVER_DEFAULT_FOLDER,
  type DownloadRow,
} from './downloads-bridge'

/**
 * The rules the downloads panel is drawn from.
 *
 * They are here rather than in the component for the reason every rule in this
 * folder is pulled out: this project's test run has no DOM, so anything inside a
 * render tree is a rule nothing can hold. The one that matters most is
 * {@link downloadsBadge} — an indicator that fails to appear is a download that
 * vanished silently, which is the entire complaint this feature answers.
 */

function row(over: Partial<DownloadRow> = {}): DownloadRow {
  return {
    id: 'dl-1',
    name: 'report.pdf',
    url: 'https://example.test/report.pdf',
    bytes: 100,
    received: 100,
    state: 'done',
    path: '/Users/apple/Downloads/Terminal Deck/report.pdf',
    onMachine: '',
    onMachineName: '',
    message: '',
    startedAt: 1,
    ...over,
  }
}

describe('what the preload gives us', () => {
  it('takes the methods that are there and is not refused by the ones that are not', () => {
    // The whole reason this is its own bridge: `bridge.ts` resolves to null when
    // one of its methods is missing, which would take the entire browser panel
    // away on any build whose preload predates downloads.
    const api = resolveDownloadsApi({ browserDownloads: () => Promise.resolve(null) })
    expect(typeof api.browserDownloads).toBe('function')
    expect(api.browserDownloadOpen).toBeUndefined()
  })

  it('needs the list and the push before it will offer the panel at all', () => {
    expect(downloadsAvailable({})).toBe(false)
    expect(downloadsAvailable({ browserDownloads: async () => null })).toBe(false)
    expect(
      downloadsAvailable({ browserDownloads: async () => null, onBrowserDownloads: () => () => {} }),
    ).toBe(true)
  })
})

describe('a view off the wire', () => {
  it('drops a row with no id, because every control on a row sends that id back', () => {
    const view = readDownloadsView({ items: [{ name: 'x' }, { id: 'a', name: 'y' }] })
    expect(view.items.map((one) => one.id)).toEqual(['a'])
  })

  it('answers something drawable for anything at all', () => {
    expect(readDownloadsView(null).items).toEqual([])
    expect(readDownloadsView({ items: 'no' }).destination.machineId).toBe('')
    // A state this build has never heard of reads as a failure, never as done:
    // the wrong way to be wrong about a file is to say it arrived.
    expect(readDownloadsView({ items: [{ id: 'a', state: 'teleporting' }] }).items[0].state).toBe(
      'failed',
    )
  })

  it('reads a refusal out of anything that is not an ok', () => {
    expect(readAction(null).ok).toBe(false)
    expect(readAction({ ok: true, message: '' })).toEqual({ ok: true, message: '' })
  })
})

describe('the indicator on the bar', () => {
  it('says nothing at all when nothing has happened', () => {
    // Chrome's own rule. A control that is empty nine days in ten is a control
    // people stop seeing, and the standing door is the row in the menu.
    expect(downloadsBadge([])).toBeNull()
  })

  it('counts what is moving, downloads and deliveries alike', () => {
    expect(downloadsBadge([row({ state: 'downloading' })])?.tone).toBe('busy')
    expect(
      downloadsBadge([row({ id: 'a', state: 'downloading' }), row({ id: 'b', state: 'delivering' })]),
    ).toEqual({ label: '2', tone: 'busy' })
  })

  it('marks the newest failure, because that is the one somebody has to see', () => {
    expect(downloadsBadge([row({ state: 'failed' })])).toEqual({ label: '!', tone: 'bad' })
  })

  it('keeps a quiet count once everything has finished', () => {
    expect(downloadsBadge([row(), row({ id: 'b' })])).toEqual({ label: '2', tone: 'done' })
  })
})

describe('one row', () => {
  it('has no bar when the server never said how big the file is', () => {
    // A bar sitting at 0% while a file is arriving reports a stall that is not
    // happening. The bytes so far are the true statement available.
    expect(downloadProgress(row({ state: 'downloading', bytes: 0, received: 500 }))).toBeNull()
    expect(downloadProgress(row({ state: 'downloading', bytes: 200, received: 100 }))).toBe(0.5)
    expect(downloadProgress(row())).toBeNull()
  })

  it('names the machine a finished file is on, by its name', () => {
    expect(downloadLine(row(), 'Mac-mini')).toBe(
      'Mac-mini · /Users/apple/Downloads/Terminal Deck/report.pdf',
    )
    expect(
      downloadLine(
        row({ onMachine: 'mach-1', onMachineName: 'Office PC', path: '/srv/report.pdf' }),
        'Mac-mini',
      ),
    ).toBe('Office PC · /srv/report.pdf')
  })

  it('says why on the states nobody wants, and never says nothing', () => {
    expect(downloadLine(row({ state: 'failed', message: 'The disk is full.' }), 'here')).toBe(
      'The disk is full.',
    )
    // Even with no sentence from anywhere, the line is never blank — a row that
    // says nothing about what happened is the defect.
    expect(downloadLine(row({ state: 'failed', message: '' }), 'here')).not.toBe('')
    expect(downloadLine(row({ state: 'cancelled', message: '' }), 'here')).not.toBe('')
    expect(
      downloadLine(row({ state: 'delivering', onMachineName: 'Office PC' }), 'here'),
    ).toContain('Office PC')
  })

  it('draws bytes while it is coming down', () => {
    expect(downloadLine(row({ state: 'downloading', bytes: 2048, received: 1024 }), 'here')).toBe(
      '1.0 KB of 2.0 KB',
    )
  })
})

describe('the destination line', () => {
  it('names this computer rather than saying "this machine"', () => {
    // *"So I'm confused now what is the truth… I don't know what to trust."* The
    // phrase was on one bar three times meaning three computers.
    expect(destinationLine({ machineId: '', machineName: '', folder: '' }, 'Mac-mini', '/d/TD')).toBe(
      'Mac-mini · /d/TD',
    )
  })

  it('falls back to the phrase only where there is no name, never to a guess', () => {
    expect(destinationLine({ machineId: '', machineName: '', folder: '' }, '', '/d/TD')).toBe(
      'This machine · /d/TD',
    )
  })

  it('says the folder somebody chose, on whichever machine they chose it on', () => {
    expect(
      destinationLine(
        { machineId: 'mach-1', machineName: 'Office PC', folder: '/srv/incoming' },
        'Mac-mini',
        '/d/TD',
      ),
    ).toBe('Office PC · /srv/incoming')
    expect(
      destinationLine({ machineId: 'mach-1', machineName: 'Office PC', folder: '' }, 'Mac-mini', '/d/TD'),
    ).toBe('Office PC · its downloads folder')
  })

  it('says what an unfoldered destination actually does, which differs by kind', () => {
    // A paired desktop puts it in `<downloads>/Terminal Deck`; a server has no
    // such folder and resolves `.` to wherever the sign-in lands. Saying either
    // about the other is describing one machine with another one's behaviour.
    expect(
      destinationLine(
        { machineId: 'srv-1', machineName: 'Office PC', folder: '' },
        'Mac-mini',
        '/d/TD',
        SERVER_DEFAULT_FOLDER,
      ),
    ).toBe('Office PC · wherever the sign-in lands')
  })
})
