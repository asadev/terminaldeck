import { describe, expect, it } from 'vitest'
import { PROTOCOL_VERSION, type RemoteSession, type ServerMessage } from './protocol-client'
import { folderOffer, foldersAfter, noFoldersSentence, pickerRows } from './folders'

/**
 * The one-folder bug, asked from the client side.
 *
 * What the phone showed used to be assembled here, out of the working
 * directories of whatever sessions it could see. These tests pin the three
 * answers apart — a granted list, an empty one, and a desktop that never said —
 * because collapsing any two of them is what made a picker nobody could
 * explain.
 */

function session(id: string, cwd: string): RemoteSession {
  return { id, title: id, cwd, provider: 'claude', status: 'idle', exitCode: null }
}

function welcome(folders?: string[]): ServerMessage {
  const message: Extract<ServerMessage, { t: 'welcome' }> = {
    t: 'welcome',
    protocol: PROTOCOL_VERSION,
    deviceId: 'dev-1',
    deviceName: 'iPhone',
    token: null,
    sessions: [],
    capabilities: ['create'],
  }
  // Assigned rather than passed as undefined, so the "this desktop is older
  // than the field" case is genuinely a message with no key in it.
  if (folders !== undefined) message.folders = folders
  return message
}

const running = [session('a', '/Users/asad/Projects/api'), session('b', '/Users/asad/Projects/site')]

describe('what the picker offers', () => {
  it('offers the folders the desktop granted, in the order it sent them', () => {
    const offer = folderOffer(['/Users/asad/Projects/site', '/Users/asad/Projects/api'], running)
    expect(offer).toEqual({ kind: 'granted', folders: ['/Users/asad/Projects/site', '/Users/asad/Projects/api'] })
    expect(pickerRows(offer, 'Mac')).toEqual([
      { label: '/Users/asad/Projects/site', folder: '/Users/asad/Projects/site', path: true },
      { label: '/Users/asad/Projects/api', folder: '/Users/asad/Projects/api', path: true },
    ])
  })

  it('ignores what is running once the desktop has said', () => {
    // The exact defect: the picker used to be the session list wearing a
    // different hat, so it changed when something was started at the desk and
    // disagreed with what the desktop would accept.
    const offer = folderOffer(['/Users/asad/Projects/tools'], running)
    expect(pickerRows(offer, 'Mac').map((row) => row.folder)).toEqual(['/Users/asad/Projects/tools'])
  })

  it('draws no "wherever you would" row against a desktop that granted a list', () => {
    // It would not be a second choice. A create naming nothing starts in the
    // first granted folder, so the row would be the same destination twice with
    // one of the two hiding which folder it is.
    const rows = pickerRows(folderOffer(['/one', '/two'], []), 'Mac')
    expect(rows.every((row) => row.folder !== null)).toBe(true)
  })

  it('treats an empty grant as its own state rather than as no answer', () => {
    expect(folderOffer([], running)).toEqual({ kind: 'none' })
    expect(pickerRows({ kind: 'none' }, 'Mac')).toEqual([])
  })

  it('says which machine has shared nothing, and where that is changed', () => {
    const said = noFoldersSentence('PC')
    expect(said).toContain('The PC has not shared a folder')
    // The remedy is on a machine the reader is not holding, so the screen that
    // grants folders is named rather than implied.
    expect(said).toContain('Remote access')
    expect(said).not.toContain('Mac')
  })

  it('falls back to the folders sessions are running in when the desktop never said', () => {
    const offer = folderOffer(null, running)
    expect(offer).toEqual({ kind: 'unsaid', folders: ['/Users/asad/Projects/api', '/Users/asad/Projects/site'] })
    expect(pickerRows(offer, 'Mac')).toEqual([
      { label: 'Wherever the Mac would', folder: null, path: false },
      { label: '/Users/asad/Projects/api', folder: '/Users/asad/Projects/api', path: true },
      { label: '/Users/asad/Projects/site', folder: '/Users/asad/Projects/site', path: true },
    ])
  })

  it('still offers the desktop’s own default when an old desktop has nothing running', () => {
    // A phone paired to a desktop released before the field, with an empty
    // session list, must not end up with a picker of nothing: the desktop will
    // happily start one wherever it would have.
    expect(pickerRows(folderOffer(null, []), 'desktop')).toEqual([
      { label: 'Wherever the desktop would', folder: null, path: false },
    ])
  })

  it('does not list one folder twice because two sessions are in it', () => {
    const twice = [session('a', '/Users/asad/Projects/api'), session('b', '/Users/asad/Projects/api')]
    expect(folderOffer(null, twice)).toEqual({ kind: 'unsaid', folders: ['/Users/asad/Projects/api'] })
  })
})

describe('keeping the picker in step with the desktop', () => {
  it('takes the list out of the welcome', () => {
    expect(foldersAfter(null, welcome(['/one']))).toEqual(['/one'])
  })

  it('replaces it when the desktop pushes a new one, with no reconnect', () => {
    // The point of the pushed frame. Someone removes a folder at the desk while
    // the phone sits there connected; if this only landed in the next welcome,
    // the picker would keep offering a tap whose one outcome is a refusal until
    // the app was quit and reopened.
    const first = foldersAfter(null, welcome(['/one', '/two']))
    const after = foldersAfter(first, { t: 'folders', folders: ['/two'] })
    expect(after).toEqual(['/two'])
    expect(pickerRows(folderOffer(after, running), 'Mac').map((row) => row.folder)).toEqual(['/two'])
  })

  it('lets a pushed empty list mean none, rather than falling back to what is running', () => {
    // The dangerous half of the same frame. Removing the *last* folder is a
    // person's answer, and a client that read it as "the desktop said nothing"
    // would answer by offering the session list again — every row of which the
    // desktop would now refuse.
    const after = foldersAfter(['/one'], { t: 'folders', folders: [] })
    expect(after).toEqual([])
    expect(folderOffer(after, running)).toEqual({ kind: 'none' })
  })

  it('keeps the list it has when a welcome arrives from a desktop that predates the field', () => {
    // Not the same as the pushed frame above: the field is *absent*, which is a
    // desktop that has no opinion rather than one that removed everything.
    expect(foldersAfter(['/one'], welcome())).toBeNull()
  })

  it('leaves the list alone for every other frame', () => {
    const held = ['/one']
    expect(foldersAfter(held, { t: 'sessions', sessions: running })).toBe(held)
    expect(foldersAfter(held, { t: 'output', id: 'a', data: 'x' })).toBe(held)
    expect(foldersAfter(held, { t: 'pong' })).toBe(held)
  })
})
