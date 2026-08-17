import { describe, expect, it } from 'vitest'
import {
  browseForAttachment,
  browseLabel,
  confinedRefusal,
  pasteAttachment,
  picksFromDrop,
  readBoundary,
  readBrowse,
  readPaste,
  readPicks,
  resolveOutsideBridge,
  sessionBoundary,
  UNCONFINED,
  type AttachOutsideBridge,
} from './outside'

/**
 * The three routes out of the project, read defensively.
 *
 * Everything here crosses the preload as `unknown`, so every one of these tests
 * is about the same question: what does this do when the other side answers with
 * something it did not promise. The answer has to be a sentence, never a throw —
 * a rejected promise inside a composer callback takes the whole box down through
 * the error boundary, and a broken-looking composer is how an unwired feature
 * gets mistaken for a broken one. That has happened here before; `AttachPicker`
 * carries the same guard for the same reason.
 */

function bridgeOf(overrides: Partial<AttachOutsideBridge>): AttachOutsideBridge {
  return {
    browseForAttachment: async () => null,
    inspectAttachPaths: async () => null,
    pasteAttachment: async () => null,
    sessionAttachBoundary: async () => null,
    pathForDroppedFile: () => '',
    ...overrides,
  }
}

describe('reading picks', () => {
  it('keeps well-formed rows and drops the rest', () => {
    expect(
      readPicks([
        { path: '/tmp/a.txt', isDirectory: false },
        { path: '/tmp/dir', isDirectory: true },
        { path: '', isDirectory: false },
        { isDirectory: true },
        null,
        'nope',
      ]),
    ).toEqual([
      { path: '/tmp/a.txt', isDirectory: false },
      { path: '/tmp/dir', isDirectory: true },
    ])
  })

  it('answers an empty list for anything that is not one', () => {
    expect(readPicks(null)).toEqual([])
    expect(readPicks({ picks: [] })).toEqual([])
  })
})

describe('reading a browse', () => {
  it('tells a cancel apart from a failure', () => {
    // Escape in the panel is the most common way this call ends and is not an
    // error. Collapsing the two would make a build with no channel look exactly
    // like a person changing their mind, which is how something unwired ships
    // looking finished.
    expect(readBrowse({ ok: false, reason: 'cancelled' })).toEqual({ kind: 'cancelled' })
    expect(readBrowse({ ok: true, picks: [] })).toEqual({ kind: 'cancelled' })
    expect(readBrowse({ ok: false, reason: 'no-window' }).kind).toBe('failed')
    expect(readBrowse(null).kind).toBe('failed')
  })

  it('carries the picks through when there are any', () => {
    expect(readBrowse({ ok: true, picks: [{ path: '/tmp/x', isDirectory: false }] })).toEqual({
      kind: 'picked',
      picks: [{ path: '/tmp/x', isDirectory: false }],
    })
  })

  it('says something a person can read for every failure', () => {
    for (const response of [null, { ok: false, reason: 'no-window' }, { ok: 'yes' }]) {
      const outcome = readBrowse(response)
      if (outcome.kind !== 'failed') continue
      expect(outcome.message).not.toBe('')
      expect(outcome.message.endsWith('.')).toBe(true)
    }
  })
})

describe('reading a paste', () => {
  it('separates "nothing to attach" from "that went wrong"', () => {
    // Pasting text is the overwhelmingly common case and must not produce an
    // error message. A failed *write* must.
    expect(readPaste({ ok: false, reason: 'nothing' })).toEqual({ kind: 'nothing' })
    expect(readPaste({ ok: true, picks: [] })).toEqual({ kind: 'nothing' })
    const failed = readPaste({ ok: false, reason: 'write-failed', detail: 'ENOSPC' })
    expect(failed.kind).toBe('failed')
    if (failed.kind === 'failed') expect(failed.message).toContain('ENOSPC')
  })

  it('reports which of the two sources answered', () => {
    expect(readPaste({ ok: true, picks: [{ path: '/tmp/a', isDirectory: false }], source: 'files' })).toEqual({
      kind: 'picked',
      picks: [{ path: '/tmp/a', isDirectory: false }],
      source: 'files',
    })
    const image = readPaste({ ok: true, picks: [{ path: '/tmp/b.png' }], source: 'image' })
    expect(image.kind === 'picked' && image.source).toBe('image')
  })
})

describe('reading a boundary', () => {
  it('is unconfined unless the main process says otherwise, in so many words', () => {
    expect(readBoundary(null)).toEqual(UNCONFINED)
    expect(readBoundary({})).toEqual(UNCONFINED)
    expect(readBoundary({ confined: 'yes' })).toEqual(UNCONFINED)
  })

  it('keeps the folder, which is the half the sentence needs', () => {
    expect(readBoundary({ confined: true, folder: '/Users/apple/granted' })).toEqual({
      confined: true,
      folder: '/Users/apple/granted',
      projects: [],
    })
    expect(
      readBoundary({ confined: true, folder: '/c', projects: ['/p', 7, null] }),
    ).toEqual({ confined: true, folder: '/c', projects: ['/p'] })
  })
})

describe('the words on screen', () => {
  it('names the machine the way its owner would', () => {
    // His words: "browse my file manager of the PC or Windows or MacBook".
    expect(browseLabel('mac')).toBe('Browse this Mac…')
    expect(browseLabel('windows')).toBe('Browse this PC…')
    expect(browseLabel('other')).toBe('Browse this computer…')
  })

  it('names the folder in the refusal, so the sentence is about this tab', () => {
    // The last segment, not the whole path: the copilot's folder is five
    // directories deep inside Application Support, and the full string wrapped
    // to four lines inside a 336px popover.
    expect(confinedRefusal('/Users/apple/granted')).toContain('inside granted')
    expect(confinedRefusal('/Users/apple/granted')).not.toContain('/Users/apple')
    // And degrades to something that is still a sentence when it does not know.
    expect(confinedRefusal('')).toContain('its own folder')
  })

  it('does not tell a copilot session it cannot read the projects it can read', () => {
    // A wrong explanation is a different failure from no explanation, and not
    // an obviously smaller one. The copilot is confined to its own folder *and*
    // granted read access to every project the person has added.
    const plain = confinedRefusal('/Users/apple/copilot')
    const copilot = confinedRefusal('/Users/apple/copilot', ['/Users/apple/Projects/thing'])
    expect(plain).not.toContain('projects you have open')
    expect(copilot).toContain('projects you have open')
  })
})

describe('resolving the bridge', () => {
  it('refuses a partial bridge rather than failing on the third call', () => {
    // A half-wired build has to look unwired from the first click, not from
    // whichever route happens to use the missing method.
    const partial = { browseForAttachment: () => Promise.resolve(null) }
    expect(resolveOutsideBridge(partial as unknown as AttachOutsideBridge)).not.toBeNull()
    const injected = undefined
    const globalWindow = globalThis as unknown as { window?: unknown }
    const had = 'window' in globalWindow
    globalWindow.window = { deck: partial }
    try {
      expect(resolveOutsideBridge(injected)).toBeNull()
    } finally {
      if (had) delete globalWindow.window
    }
  })
})

describe('the calls themselves', () => {
  it('sends the image extension list only for the image mode', async () => {
    const seen: Array<Record<string, unknown>> = []
    const bridge = bridgeOf({
      browseForAttachment: async (request) => {
        seen.push(request as unknown as Record<string, unknown>)
        return { ok: false, reason: 'cancelled' }
      },
    })
    await browseForAttachment(bridge, 'image', '/tmp/project')
    await browseForAttachment(bridge, 'file', '/tmp/project')
    expect(Array.isArray(seen[0].extensions)).toBe(true)
    expect(seen[0].extensions).toContain('png')
    expect('extensions' in seen[1]).toBe(false)
    // The project, not wherever the panel was left. `project-picker.ts` has the
    // measurement: with no `defaultPath`, AppKit restored a bookmark pointing at
    // an empty folder and the panel listed nothing, four openings in a row.
    expect(seen[0].startIn).toBe('/tmp/project')
  })

  it('does not send an empty startIn, which would mean "wherever you were"', async () => {
    const seen: Array<Record<string, unknown>> = []
    const bridge = bridgeOf({
      browseForAttachment: async (request) => {
        seen.push(request as unknown as Record<string, unknown>)
        return { ok: false, reason: 'cancelled' }
      },
    })
    await browseForAttachment(bridge, 'file', '')
    expect('startIn' in seen[0]).toBe(false)
  })

  it('turns a rejected call into a sentence rather than an unhandled rejection', async () => {
    const bridge = bridgeOf({
      browseForAttachment: async () => {
        throw new Error('no such channel')
      },
      pasteAttachment: async () => {
        throw new Error('no such channel')
      },
      sessionAttachBoundary: async () => {
        throw new Error('no such channel')
      },
    })
    expect((await browseForAttachment(bridge, 'file', '/tmp')).kind).toBe('failed')
    expect((await pasteAttachment(bridge)).kind).toBe('failed')
    /*
     * Unconfined, and this is the one that looks wrong until you name what it
     * decides. The OS holds the boundary either way — nothing here can widen
     * what a session may read. All this answers is whether the app *warns
     * first*, and failing the other way would withdraw Browse from every
     * ordinary session because one IPC call hiccuped.
     */
    expect(await sessionBoundary(bridge, 's1')).toEqual(UNCONFINED)
  })

  it('drops files with no path behind them, which is what dragged text is', async () => {
    const asFile = (name: string): File => ({ name }) as unknown as File
    const bridge = bridgeOf({
      pathForDroppedFile: (file) => (file.name === 'real.png' ? '/tmp/real.png' : ''),
      inspectAttachPaths: async (paths) => paths.map((path) => ({ path, isDirectory: false })),
    })
    expect(await picksFromDrop(bridge, [asFile('real.png'), asFile('dragged text')])).toEqual([
      { path: '/tmp/real.png', isDirectory: false },
    ])
    expect(await picksFromDrop(bridge, [asFile('dragged text')])).toEqual([])
  })
})
