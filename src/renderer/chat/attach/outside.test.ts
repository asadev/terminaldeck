import { describe, expect, it } from 'vitest'
import {
  browseForAttachment,
  browseStart,
  bringInRefusal,
  bringInside,
  pasteAttachment,
  picksFromDrop,
  readBoundary,
  readBrowse,
  readPaste,
  readPicks,
  readBringIn,
  readableOn,
  resolveOutsideBridge,
  sessionBoundary,
  splitByBoundary,
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
 * gets mistaken for a broken one. That has happened here before.
 */

function bridgeOf(overrides: Partial<AttachOutsideBridge>): AttachOutsideBridge {
  return {
    browseForAttachment: async () => null,
    inspectAttachPaths: async () => null,
    pasteAttachment: async () => null,
    sessionAttachBoundary: async () => null,
    bringAttachmentsIn: async () => null,
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

describe('what a confined session may attach', () => {
  const boundary = {
    confined: true,
    folder: '/Users/apple/Library/Application Support/terminaldeck/copilot',
    projects: ['/Users/apple/Projects/thing'],
  }

  it('lets a confined session attach the files it can actually read', () => {
    /*
     * The regression this replaced a blanket refusal to avoid. While the in-app
     * project list existed, refusing the whole of Browse on a confined session
     * cost nothing — the list was still there and every row of it was inside the
     * boundary. With the list deleted, a blanket refusal means a copilot session
     * cannot attach anything at all, including what is sitting in its own
     * folder. That is a control that cannot act.
     */
    expect(readableOn(boundary, `${boundary.folder}/memory/today.md`)).toBe(true)
    expect(readableOn(boundary, '/Users/apple/Projects/thing/src/index.ts')).toBe(true)
    expect(readableOn(boundary, '/Users/apple/Desktop/shot.png')).toBe(false)
  })

  it('does not accept a sibling folder whose name merely starts the same way', () => {
    // `insideRoot` compares with the separator for exactly this reason;
    // asserted here too because this is the call that decides what gets attached.
    expect(readableOn(boundary, '/Users/apple/Projects/thing-secrets/.env')).toBe(false)
  })

  it('waves everything through when the session is not confined', () => {
    expect(readableOn(UNCONFINED, '/anywhere/at/all')).toBe(true)
  })

  it('splits a batch rather than refusing all of it for one bad pick', () => {
    const { allowed, refused } = splitByBoundary(boundary, [
      { path: `${boundary.folder}/notes.md`, isDirectory: false },
      { path: '/Users/apple/Desktop/shot.png', isDirectory: false },
    ])
    expect(allowed.map((p) => p.path)).toEqual([`${boundary.folder}/notes.md`])
    expect(refused.map((p) => p.path)).toEqual(['/Users/apple/Desktop/shot.png'])
  })

  it('brings the ones it cannot read inside, rather than refusing them', async () => {
    /*
     * The regression this replaces. Dropping a photo from `~/Pictures` on the
     * chat composer of a confined session used to produce a paragraph and no
     * attachment, while the same photo on the terminal two inches away
     * transferred and typed its path. *"any kind of media dropping from your PC
     * to any session should smoothly work."*
     */
    const asked: unknown[] = []
    const bridge = bridgeOf({
      bringAttachmentsIn: async (sessionId, paths) => {
        asked.push([sessionId, paths])
        return { brought: [{ from: '/Users/apple/Desktop/shot.png', path: `${boundary.folder}/Terminal Deck/shot.png` }], refused: 0 }
      },
    })
    const out = await bringInside(bridge, 'sess-1', [{ path: '/Users/apple/Desktop/shot.png', isDirectory: false }])
    expect(asked).toEqual([['sess-1', ['/Users/apple/Desktop/shot.png']]])
    expect(out.picks).toEqual([{ path: `${boundary.folder}/Terminal Deck/shot.png`, isDirectory: false }])
    expect(out.refused).toBe(0)
  })

  it('keeps the drop order and drops what did not come in', async () => {
    // Three photos dragged together should make three chips in the order they
    // were dragged, so the answer is re-ordered against the request rather than
    // taken as it arrives.
    const bridge = bridgeOf({
      bringAttachmentsIn: async () => ({
        brought: [
          { from: '/a/three.png', path: '/g/three.png' },
          { from: '/a/one.png', path: '/g/one.png' },
        ],
        refused: 1,
      }),
    })
    const out = await bringInside(bridge, 'sess-1', [
      { path: '/a/one.png', isDirectory: false },
      { path: '/a/two.png', isDirectory: false },
      { path: '/a/three.png', isDirectory: false },
    ])
    expect(out.picks.map((p) => p.path)).toEqual(['/g/one.png', '/g/three.png'])
    expect(out.refused).toBe(1)
  })

  it('answers a sentence rather than throwing when the channel is missing', async () => {
    // A rejected promise inside a composer callback takes the whole box down
    // through the error boundary.
    const bridge = bridgeOf({
      bringAttachmentsIn: async () => {
        throw new Error('no such channel')
      },
    })
    const out = await bringInside(bridge, 'sess-1', [{ path: '/a/one.png', isDirectory: false }])
    expect(out).toEqual({ picks: [], refused: 1 })
    expect(readBringIn(null)).toEqual({ brought: [], refused: 0 })
    expect(readBringIn({ brought: [{ from: 1, path: '' }, { from: '/a', path: '/b' }], refused: 'x' })).toEqual({
      brought: [{ from: '/a', path: '/b' }],
      refused: 0,
    })
  })

  it('opens the panel somewhere the session can read', () => {
    // A file browser whose first screen is a directory every row of which will
    // be refused is a worse opening frame than one that starts where the session
    // genuinely works.
    expect(browseStart(boundary, '/Users/apple/Projects/other')).toBe(boundary.folder)
    expect(browseStart(boundary, '/Users/apple/Projects/thing')).toBe('/Users/apple/Projects/thing')
    expect(browseStart(UNCONFINED, '/Users/apple/Projects/other')).toBe('/Users/apple/Projects/other')
  })
})

describe('the words on screen', () => {
  it('says nothing at all when everything came in', () => {
    // The paragraph that used to stand here — "<name> was not attached. This
    // session is held inside <folder>, so it cannot read a file from anywhere
    // else." — is gone, because the file now comes in. Silence is the success
    // signal; the chip is already on screen.
    expect(bringInRefusal(0)).toBe('')
    expect(bringInRefusal(-1)).toBe('')
  })

  it('is one clause when something genuinely could not be moved', () => {
    // A folder, something over the size cap, a disk that would not take it.
    // Rare, boring, and worth exactly one clause — never a count of filenames,
    // which wrap a notice line to three lines and stop being a line.
    expect(bringInRefusal(1)).toBe('One file did not come in.')
    expect(bringInRefusal(3)).toBe('3 files did not come in.')
    expect(bringInRefusal(3).split(' ')).toHaveLength(6)
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

/* ------------------------------------------------------------- windows ----- */

/**
 * The same three routes, on the machine none of them worked on.
 *
 * Every path here is a literal `C:\…` string rather than anything derived from
 * the platform this runs on, which is the only way a Mac can check a Windows
 * answer: it forces the *data* the Windows routes produce — `showOpenDialog`,
 * `webUtils` and the clipboard all hand back native spellings, and
 * `normalisePick` rewrites only `\\wsl.localhost\…` — through the functions the
 * macOS routes use. Every assertion below fails against the code as it stood.
 *
 * This file has no separator logic of its own: `readableOn` is `insideRoot` and
 * the two refusal sentences are `basename`, both from `mentions.ts`. That is
 * exactly why it is checked here as well. The confined session is the one a
 * Windows user is most likely to meet — the copilot's own, and any session a
 * phone started — and with `insideRoot` answering no for every Windows path,
 * `splitByBoundary` refused the entire batch outright.
 */
describe('a confined session on Windows', () => {
  const boundary = {
    confined: true,
    folder: 'C:\\Users\\asad\\AppData\\Roaming\\terminaldeck\\copilot',
    projects: ['C:\\Users\\asad\\Projects\\thing'],
  }

  it('lets it attach the files it can actually read', () => {
    expect(readableOn(boundary, `${boundary.folder}\\memory\\today.md`)).toBe(true)
    expect(readableOn(boundary, 'C:\\Users\\asad\\Projects\\thing\\src\\index.ts')).toBe(true)
    expect(readableOn(boundary, 'C:\\Users\\asad\\Desktop\\shot.png')).toBe(false)
  })

  it('still refuses a sibling folder whose name merely starts the same way', () => {
    expect(readableOn(boundary, 'C:\\Users\\asad\\Projects\\thing-secrets\\.env')).toBe(false)
  })

  it('splits a batch rather than refusing all of it', () => {
    // The whole batch was refused before, because `insideRoot` said no to every
    // Windows path — so a copilot session on Windows could attach nothing at
    // all, including the files inside the very folder it is held in.
    const { allowed, refused } = splitByBoundary(boundary, [
      { path: `${boundary.folder}\\notes.md`, isDirectory: false },
      { path: 'C:\\Users\\asad\\Desktop\\shot.png', isDirectory: false },
    ])
    expect(allowed.map((p) => p.path)).toEqual([`${boundary.folder}\\notes.md`])
    expect(refused.map((p) => p.path)).toEqual(['C:\\Users\\asad\\Desktop\\shot.png'])
  })

  it('brings a Windows path inside rather than refusing it', async () => {
    // The Windows half of the same regression. `bringInside` sends paths and
    // matches answers by string, so it has no separator logic to get wrong —
    // which is precisely why it is checked on the platform whose paths every
    // other function here used to mishandle.
    const bridge = bridgeOf({
      bringAttachmentsIn: async () => ({
        brought: [
          { from: 'C:\\Users\\asad\\Desktop\\shot.png', path: `${boundary.folder}\\Terminal Deck\\shot.png` },
        ],
        refused: 0,
      }),
    })
    const out = await bringInside(bridge, 'sess-1', [
      { path: 'C:\\Users\\asad\\Desktop\\shot.png', isDirectory: false },
    ])
    expect(out.picks.map((p) => p.path)).toEqual([`${boundary.folder}\\Terminal Deck\\shot.png`])
    expect(readableOn(boundary, out.picks[0]!.path)).toBe(true)
  })

  it('opens the panel in the project when the session can read it', () => {
    expect(browseStart(boundary, 'C:\\Users\\asad\\Projects\\thing')).toBe(
      'C:\\Users\\asad\\Projects\\thing',
    )
    expect(browseStart(boundary, 'C:\\Users\\asad\\Projects\\other')).toBe(boundary.folder)
  })
})
