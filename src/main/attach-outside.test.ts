import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  clipboardFilePaths,
  pastedImageName,
  pathFromFileUrl,
  prunePasted,
  registerAttachOutsideIpc,
  type OutsidePick,
  type PasteResult,
} from './attach-outside'

/**
 * Attaching something that is not in the open project.
 *
 * The clipboard cases are the ones worth having, and they are here because they
 * were **measured** rather than reasoned about. Run against Electron 41 on
 * macOS 27 with the pasteboard set two ways:
 *
 *  - A PNG **file** copied in Finder: `availableFormats()` says
 *    `["text/uri-list"]`, `read('public.file-url')` returns the URL,
 *    `read('NSFilenamesPboardType')` returns an XML plist of every path — and
 *    `readImage()` is **not empty**, because macOS renders a preview of the file
 *    into the pasteboard.
 *  - A screenshot copied as a **bitmap**: only `readImage()` has anything.
 *
 * The first row is the trap. Anything that checks for an image before it checks
 * for a file would take a file the user already has on disk, write a second copy
 * of it into this app's storage, and attach the copy — a path they have never
 * seen, for a file that was sitting right there. `paste attaches the file itself`
 * below is that measurement, expressed as a test that fails if the order is ever
 * swapped back.
 *
 * `read('text/uri-list')` returning `''` for the same pasteboard that answers
 * `public.file-url` with a real URL was measured too, and is why nothing here
 * consults the format list.
 */

/** The plist a Finder copy of two files puts on the pasteboard. */
function plistOf(paths: readonly string[]): string {
  const rows = paths.map((path) => `\t<string>${path}</string>`).join('\n')
  return `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<array>\n${rows}\n</array>\n</plist>\n`
}

describe('reading file paths off the clipboard', () => {
  it('prefers the plist, which is the only source that can carry more than one', () => {
    const board = (format: string): string =>
      format === 'NSFilenamesPboardType'
        ? plistOf(['/Users/apple/Desktop/one.png', '/Users/apple/Desktop/two.png'])
        : 'file:///Users/apple/Desktop/one.png'
    expect(clipboardFilePaths(board)).toEqual([
      '/Users/apple/Desktop/one.png',
      '/Users/apple/Desktop/two.png',
    ])
  })

  it('falls back to the single file URL when the plist is not the XML form', () => {
    // Degraded, never wrong: one file instead of three. A binary plist matches
    // no `<string>`, and the alternative — a real plist parser fed a blob — is a
    // throw on a paste.
    const board = (format: string): string =>
      format === 'NSFilenamesPboardType' ? 'bplist00\u0000\u0000' : 'file:///tmp/only.txt'
    expect(clipboardFilePaths(board)).toEqual(['/tmp/only.txt'])
  })

  it('reads a Windows clipboard, which holds neither macOS name', () => {
    /*
     * The defect this closes: copying a file in Explorer and pressing paste
     * reported "There is no file or image on the clipboard" over a clipboard
     * that had a file on it, because both formats asked for were macOS
     * pasteboard types and a Windows clipboard has neither.
     *
     * Forced by the DATA rather than by the platform — the reader is injected,
     * so this measures what the function does with what Windows hands it, on
     * whatever machine the suite happens to be running on.
     */
    const board = (format: string): string =>
      format === 'FileNameW' ? 'C:\\Users\\Asad\\notes.txt\u0000' : ''
    expect(clipboardFilePaths(board)).toEqual(['C:\\Users\\Asad\\notes.txt'])
  })

  it('prefers the format that can carry several files, where there is one', () => {
    // `FileNameW` holds exactly one path, so it is asked for last. A board
    // answering both would otherwise turn a three-file copy into a one-file
    // paste.
    const board = (format: string): string =>
      format === 'NSFilenamesPboardType'
        ? plistOf(['/tmp/a.txt', '/tmp/b.txt'])
        : format === 'FileNameW'
          ? 'C:\\only.txt'
          : ''
    expect(clipboardFilePaths(board)).toEqual(['/tmp/a.txt', '/tmp/b.txt'])
  })

  it('answers nothing for a clipboard holding text', () => {
    expect(clipboardFilePaths(() => '')).toEqual([])
    expect(clipboardFilePaths((f) => (f === 'public.file-url' ? 'just some words' : ''))).toEqual([])
  })

  it('decodes the escapes a filename can legitimately contain', () => {
    expect(clipboardFilePaths(() => plistOf(['/tmp/a &amp; b.txt']))).toEqual(['/tmp/a & b.txt'])
    expect(pathFromFileUrl('file:///tmp/a%20file%20with%20spaces.png')).toBe(
      '/tmp/a file with spaces.png',
    )
  })

  it('treats anything that is not a local file URL as no file at all', () => {
    // A malformed URL on somebody else's pasteboard must mean "nothing here",
    // not an exception on ⌘V.
    expect(pathFromFileUrl('https://example.com/x.png')).toBeNull()
    expect(pathFromFileUrl('file://server/share/x.png')).toBeNull()
    expect(pathFromFileUrl('')).toBeNull()
    expect(pathFromFileUrl('file:///%E0%A4%A')).toBeNull()
  })

  it('does not hand back the /C:/ shape a Windows file URL decodes to', () => {
    /*
     * `file:///C:/Users/asad/a.png` leaves `/C:/Users/asad/a.png` after the
     * scheme — a leading slash in front of a drive letter. That is not a near
     * miss, it is the exact `new URL(…).pathname` → `/D:/…` shape the Windows
     * CI has already caught once in this repository, written by hand here. A
     * `/C:/…` string is accepted by no Windows API: `existsSync` says no, the
     * composer's absolute-path gate says no, and the agent asked to read the
     * file says no, each in its own words.
     *
     * It cannot fire today, because `clipboardFilePaths` only asks for the two
     * macOS pasteboard types — so this is pinned as a trap that has been
     * removed rather than as a bug that was seen. The person who adds the
     * `FileNameW`/`CF_HDROP` branch Windows paste needs should not have to know
     * this function was waiting for them.
     */
    expect(pathFromFileUrl('file:///C:/Users/asad/a%20file.png')).toBe('C:\\Users\\asad\\a file.png')
    // Lower-case drive letters are as legitimate as upper-case ones; Windows
    // hands out both from different APIs.
    expect(pathFromFileUrl('file:///d:/tmp/x.txt')).toBe('d:\\tmp\\x.txt')
    // A drive root keeps its separator. `C:` alone means "the current directory
    // on drive C" to Windows, not the root of it — the one answer here that
    // would be silently wrong rather than visibly wrong.
    expect(pathFromFileUrl('file:///C:/')).toBe('C:\\')
    // And the POSIX answers are untouched, separator for separator: this is a
    // port of the rule, not a rewrite of the function.
    expect(pathFromFileUrl('file:///tmp/x.png')).toBe('/tmp/x.png')
    expect(pathFromFileUrl('file:///tmp/dir/')).toBe('/tmp/dir')
  })
})

describe('naming and clearing up pasted bitmaps', () => {
  it('makes a name that is legible and cannot collide with the next paste', () => {
    const first = pastedImageName(new Date('2026-08-17T04:05:06.789Z'), 'a1b2c3')
    expect(first).toBe('pasted-2026-08-17_04-05-06-a1b2c3.png')
    // Two pastes inside one second are one key repeat apart. Without the tail
    // the second would overwrite an image already attached to an unsent message.
    const second = pastedImageName(new Date('2026-08-17T04:05:06.999Z'), 'd4e5f6')
    expect(second).not.toBe(first)
  })

  it('deletes what is old and keeps what is not', () => {
    const dir = mkdtempSync(join(tmpdir(), 'td-paste-'))
    try {
      const old = join(dir, 'pasted-old.png')
      const fresh = join(dir, 'pasted-fresh.png')
      writeFileSync(old, 'x')
      writeFileSync(fresh, 'x')
      const now = Date.now()
      const ancient = new Date(now - 30 * 24 * 60 * 60 * 1000)
      utimesSync(old, ancient, ancient)
      prunePasted(dir, now)
      expect(existsSync(old)).toBe(false)
      expect(existsSync(fresh)).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('does nothing, loudly or otherwise, for a directory that is not there', () => {
    // A first-ever paste runs this before the directory exists. A throw here
    // would turn "paste your screenshot" into an error on the one path that has
    // to work on a fresh install.
    expect(() => prunePasted(join(tmpdir(), 'td-paste-absent-' + Date.now()), Date.now())).not.toThrow()
  })
})

/* ---------------------------------------------------------------- the ipc -- */

type Handler = (...args: unknown[]) => unknown

interface FakeImage {
  isEmpty(): boolean
  toPNG(): Buffer
}

function register(options: {
  clipboard: { read(format: string): string; readImage(): FakeImage }
  pasteDir: string
  boundaryOf?: (id: string) => { folder: string; readableProjects: readonly string[] } | null
}): Map<string, Handler> {
  const handlers = new Map<string, Handler>()
  registerAttachOutsideIpc(
    {
      handle: (channel: string, fn: Handler) => {
        handlers.set(channel, fn)
      },
    } as unknown as Electron.IpcMain,
    {
      // Null on purpose for the browse channel: opening a real NSOpenPanel from
      // a test would block the run on a person, and the one thing worth pinning
      // about that path without a window is that it refuses rather than throws.
      window: () => null,
      pasteDir: options.pasteDir,
      home: () => '/Users/apple',
      boundaryOf: options.boundaryOf ?? (() => null),
      clipboard: options.clipboard,
      now: () => Date.parse('2026-08-17T04:05:06.000Z'),
    },
  )
  return handlers
}

const EMPTY_IMAGE: FakeImage = { isEmpty: () => true, toPNG: () => Buffer.alloc(0) }
const REAL_IMAGE: FakeImage = { isEmpty: () => false, toPNG: () => Buffer.from('not-really-a-png') }

let pasteDir = ''

beforeEach(() => {
  pasteDir = join(mkdtempSync(join(tmpdir(), 'td-attach-')), 'pasted')
})

afterEach(() => {
  rmSync(pasteDir, { recursive: true, force: true })
})

describe('the paste channel', () => {
  it('attaches the file itself when a file was copied, never a second copy of it', async () => {
    /*
     * The measured trap, pinned. `readImage()` is deliberately non-empty here
     * because that is what macOS actually does for a copied image *file* — the
     * pasteboard carries a rendered preview alongside the URL. If the image
     * branch is ever moved above the file branch, this test fails with a path
     * inside `pasteDir` instead of the desktop file the user copied.
     */
    const handlers = register({
      pasteDir,
      clipboard: {
        read: (format) =>
          format === 'NSFilenamesPboardType' ? plistOf(['/Users/apple/Desktop/shot.png']) : '',
        readImage: () => REAL_IMAGE,
      },
    })
    const result = (await handlers.get('attach:paste')?.()) as PasteResult
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.source).toBe('files')
    expect(result.picks.map((pick: OutsidePick) => pick.path)).toEqual([
      '/Users/apple/Desktop/shot.png',
    ])
    expect(existsSync(pasteDir), 'a copy was written for a file that already exists').toBe(false)
  })

  it('writes a bitmap out, because there is no file for the agent to be pointed at', async () => {
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => REAL_IMAGE },
    })
    const result = (await handlers.get('attach:paste')?.()) as PasteResult
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.source).toBe('image')
    expect(result.picks).toHaveLength(1)
    expect(result.picks[0].isDirectory).toBe(false)
    const written = readdirSync(pasteDir)
    expect(written).toHaveLength(1)
    expect(written[0]).toMatch(/^pasted-2026-08-17_04-05-06-[0-9a-f]{6}\.png$/)
    expect(result.picks[0].path).toBe(join(pasteDir, written[0]))
  })

  it('says so, rather than doing nothing, when the clipboard holds neither', async () => {
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
    })
    const result = (await handlers.get('attach:paste')?.()) as PasteResult
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toBe('nothing')
    expect(result.detail).not.toBe('')
  })

  it('survives a clipboard format this platform does not have', async () => {
    // Windows has no `NSFilenamesPboardType`, and Electron has thrown on an
    // unknown format rather than returning '' in the past. A paste must not
    // become an unhandled rejection because of it.
    const handlers = register({
      pasteDir,
      clipboard: {
        read: (format) => {
          if (format === 'NSFilenamesPboardType') throw new Error('unknown format')
          return 'file:///tmp/from-the-url.txt'
        },
        readImage: () => EMPTY_IMAGE,
      },
    })
    const result = (await handlers.get('attach:paste')?.()) as PasteResult
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.picks[0].path).toBe('/tmp/from-the-url.txt')
  })
})

describe('the inspect channel', () => {
  it('stats what was dropped, because a dropped folder looks like an empty file', () => {
    const dir = mkdtempSync(join(tmpdir(), 'td-drop-'))
    try {
      const child = join(dir, 'inner')
      mkdirSync(child)
      const file = join(dir, 'note.txt')
      writeFileSync(file, '')
      const handlers = register({
        pasteDir,
        clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
      })
      const picks = handlers.get('attach:inspect')?.(null, [child, file]) as Promise<OutsidePick[]>
      return picks.then((answer) => {
        expect(answer).toEqual([
          { path: child, isDirectory: true },
          { path: file, isDirectory: false },
        ])
      })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('drops anything that is not a string rather than trusting the renderer', async () => {
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
    })
    await expect(handlers.get('attach:inspect')?.(null, [1, '', null])).resolves.toEqual([])
    await expect(handlers.get('attach:inspect')?.(null, 'not an array')).resolves.toEqual([])
  })
})

describe('the boundary channel', () => {
  it('answers unconfined for a session nothing is holding', async () => {
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
    })
    await expect(handlers.get('attach:boundary')?.(null, 'a-session')).resolves.toEqual({
      confined: false,
      folder: '',
      projects: [],
    })
  })

  it('names the folder for a session that is held inside one', async () => {
    // The folder is in the answer because the sentence on screen has to be about
    // *this tab* — "this session can only read /Users/apple/granted" tells
    // somebody what to do next, and "this session is confined" does not.
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
      boundaryOf: (id) =>
        id === 'phone-session' ? { folder: '/Users/apple/granted', readableProjects: [] } : null,
    })
    await expect(handlers.get('attach:boundary')?.(null, 'phone-session')).resolves.toEqual({
      confined: true,
      folder: '/Users/apple/granted',
      projects: [],
    })
  })

  it("carries the copilot's project grant, so the sentence is not wrong about it", async () => {
    // A copilot session is confined to its own folder *and* granted read access
    // to every project the person has added. Saying it "cannot read a file from
    // anywhere else" without that clause is a wrong explanation, which is a
    // different failure from no explanation.
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
      boundaryOf: () => ({
        folder: '/Users/apple/copilot',
        readableProjects: ['/Users/apple/Projects/thing'],
      }),
    })
    await expect(handlers.get('attach:boundary')?.(null, 'copilot')).resolves.toEqual({
      confined: true,
      folder: '/Users/apple/copilot',
      projects: ['/Users/apple/Projects/thing'],
    })
  })

  it('answers unconfined for a missing id instead of throwing at the composer', async () => {
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
    })
    await expect(handlers.get('attach:boundary')?.(null, undefined)).resolves.toEqual({
      confined: false,
      folder: '',
      projects: [],
    })
  })
})

describe('the browse channel', () => {
  it('refuses rather than throwing when there is no window to open over', async () => {
    const handlers = register({
      pasteDir,
      clipboard: { read: () => '', readImage: () => EMPTY_IMAGE },
    })
    await expect(handlers.get('attach:browse')?.(null, { mode: 'file' })).resolves.toEqual({
      ok: false,
      reason: 'no-window',
    })
  })
})
