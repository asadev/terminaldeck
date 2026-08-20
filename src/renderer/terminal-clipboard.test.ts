/**
 * OSC 52, read as strings.
 *
 * The interesting half of the clipboard bridge is what it does with the payload
 * of a sequence, and every one of those cases is a string — so they are tested
 * directly rather than through a terminal, which this suite has no DOM for.
 * `attachClipboardOsc` itself is four lines of routing on top of these.
 *
 * The case that matters most is the one that must never grow a feature: the
 * **read** form. `\x1b]52;c;?` asks the terminal to send the clipboard back down
 * the pty, which on a remote pane means this machine's clipboard travelling to
 * somebody else's computer because a program over there asked. It has to be
 * unimplementable by accident, and the shape of that is `readOsc52` answering
 * null before anything downstream could ever compose a reply.
 */

import { describe, expect, it } from 'vitest'
import {
  MAX_OSC_CLIPBOARD_BYTES,
  PASTE_TOO_BIG,
  decodeOsc52,
  pasteFilesInto,
  pastedFiles,
  pastedName,
  readOsc52,
} from './terminal-clipboard'
import { MAX_PASTE_BYTES, overPasteCap } from '../shared/paste-cap'

const encode = (text: string): string => Buffer.from(text, 'utf8').toString('base64')

describe('what a set sequence carries', () => {
  it('takes the payload after the targets field, whatever the targets are', () => {
    expect(readOsc52(`c;${encode('hello')}`)).toBe(encode('hello'))
    // An empty targets field means the default selection; several letters are
    // several selections. This platform has one clipboard, so neither changes
    // what happens.
    expect(readOsc52(`;${encode('hello')}`)).toBe(encode('hello'))
    expect(readOsc52(`cps;${encode('hello')}`)).toBe(encode('hello'))
  })

  it('refuses the read form, so no reply can ever be composed', () => {
    expect(readOsc52('c;?')).toBeNull()
    expect(readOsc52(';?')).toBeNull()
    expect(readOsc52('p;?')).toBeNull()
  })

  it('refuses a payload with no field separator at all', () => {
    expect(readOsc52('')).toBeNull()
    expect(readOsc52('c')).toBeNull()
    expect(readOsc52('c;')).toBeNull()
  })
})

describe('decoding', () => {
  it('reassembles UTF-8 rather than handing back one character per byte', () => {
    // `atob` answers with latin-1, so a naive implementation turns an accented
    // character into mojibake — invisible in ASCII tests and obvious in real use.
    const text = 'échec — 😀 café'
    const decoded = decodeOsc52(encode(text))
    expect(decoded).toEqual({ text })
  })

  it('refuses a payload over the cap rather than truncating it', () => {
    // Truncation is the dangerous answer: half a token or half a diff pastes as
    // something that looks right and is not.
    const huge = 'a'.repeat(Math.ceil((MAX_OSC_CLIPBOARD_BYTES * 4) / 3) + 8)
    expect(decodeOsc52(huge)).toEqual({ tooLarge: true })
  })

  it('answers null for something that is not base64 at all', () => {
    expect(decodeOsc52('not base64!!')).toBeNull()
  })
})

describe('the paste bound, and the sentence for it', () => {
  it('measures a paste in bytes, not in characters', () => {
    expect(overPasteCap('a'.repeat(MAX_PASTE_BYTES))).toBe(false)
    expect(overPasteCap('a'.repeat(MAX_PASTE_BYTES + 1))).toBe(true)
    // A quarter of the cap in emoji is exactly the cap in bytes, and one more is
    // over it — while both are far under it counted as UTF-16 units.
    const atCap = '😀'.repeat(MAX_PASTE_BYTES / 4)
    expect(atCap.length).toBeLessThan(MAX_PASTE_BYTES)
    expect(overPasteCap(atCap)).toBe(false)
    expect(overPasteCap(`${atCap}😀`)).toBe(true)
  })

  it('names the limit the way a person would say it', () => {
    expect(PASTE_TOO_BIG).toContain('1.0 MB')
    // One line, and no advice. The standing rule this round is that there is no
    // explanatory prose on a terminal.
    expect(PASTE_TOO_BIG.split('\n')).toHaveLength(1)
  })
})

/**
 * The other direction: a paste that is carrying a file.
 *
 * `pastedFiles` is the whole of what R2 adds on top of the transfer rule, and it
 * is a pure reading of a `DataTransfer` — so it is tested as one, with the two
 * shapes that actually arrive: a file copied in Finder, which has a path behind
 * it, and an image copied in a web page, which has none.
 */
describe('what a paste is carrying', () => {
  const item = (file: File | null, kind: 'file' | 'string' = 'file'): DataTransferItem =>
    ({ kind, getAsFile: () => file }) as unknown as DataTransferItem

  const transfer = (items: DataTransferItem[]): DataTransfer =>
    ({ items }) as unknown as DataTransfer

  const paths = { pathForDroppedFile: (file: File): string => (file.name === 'report.pdf' ? '/Users/apple/report.pdf' : '') }

  it('sees nothing in a plain text paste, so a pasted diff stays a paste', () => {
    expect(pastedFiles(transfer([item(null, 'string')]), paths)).toEqual([])
    expect(pastedFiles(null, paths)).toEqual([])
  })

  it('gives a file copied in Finder the path it already has', () => {
    const file = new File(['x'], 'report.pdf')
    const [carried] = pastedFiles(transfer([item(file)]), paths)
    expect(carried.path).toBe('/Users/apple/report.pdf')
    expect(carried.name).toBe('report.pdf')
  })

  it('gives an image with no file behind it an empty path, so its bytes are read', () => {
    const shot = new File(['x'], '', { type: 'image/png' })
    const [carried] = pastedFiles(transfer([item(shot)]), paths, new Date(2026, 7, 20, 21, 5, 6))
    expect(carried.path).toBe('')
    // A composed name, because the clipboard gave none and three screenshots in
    // a row must not all be called the same thing.
    expect(carried.name).toBe('pasted-20260820-210506.png')
  })

  it('keeps whatever name the clipboard did give', () => {
    const shot = new File(['x'], 'Screenshot.png', { type: 'image/png' })
    expect(pastedName(shot, new Date())).toBe('Screenshot.png')
  })

  it('falls back to .bin rather than lying about the type', () => {
    expect(pastedName({ name: '', type: 'application/x-thing' }, new Date(2026, 0, 2, 3, 4, 5))).toBe(
      'pasted-20260102-030405.bin',
    )
  })

  it('survives a build with no path bridge at all', () => {
    const file = new File(['x'], 'report.pdf')
    expect(pastedFiles(transfer([item(file)]), null)[0].path).toBe('')
  })
})

/**
 * The typing half, which is the same for a session here and a session on a PC —
 * because the only thing that differs is what `pathForSession` decides, and that
 * is `session-transfer.test.ts`'s subject rather than this one's.
 */
describe('putting pasted files at the prompt', () => {
  const blob = () => ({ arrayBuffer: async () => new ArrayBuffer(4) })

  it('types the path the transfer answered with, quoted, one per file', async () => {
    const typed: string[] = []
    const term = { paste: (data: string) => typed.push(data) }
    await pasteFilesInto(
      [{ name: 'report.pdf', path: '/here/report.pdf', file: blob() }],
      { machineId: 'pc-1' },
      () => term,
      () => {},
      { uploadToMachine: async () => ({ ok: true, path: '/far/report.pdf' }) },
    )
    expect(typed).toEqual(["'/far/report.pdf' "])
  })

  it('stops at the first refusal and says it, leaving what landed on the line', async () => {
    const typed: string[] = []
    const said: string[] = []
    const term = { paste: (data: string) => typed.push(data) }
    let call = 0
    await pasteFilesInto(
      [
        { name: 'a.png', path: '/here/a.png', file: blob() },
        { name: 'b.png', path: '/here/b.png', file: blob() },
        { name: 'c.png', path: '/here/c.png', file: blob() },
      ],
      { machineId: 'pc-1' },
      () => term,
      (line) => said.push(line),
      {
        uploadToMachine: async () =>
          (call += 1) === 1 ? { ok: true, path: '/far/a.png' } : { ok: false, message: 'The link went away.' },
      },
    )
    expect(typed).toEqual(["'/far/a.png' "])
    expect(said).toContain('The link went away.')
  })

  it('types nothing into a pane that went away mid-transfer', async () => {
    await expect(
      pasteFilesInto(
        [{ name: 'a.png', path: '/here/a.png', file: blob() }],
        { machineId: 'pc-1' },
        () => null,
        () => {},
        { uploadToMachine: async () => ({ ok: true, path: '/far/a.png' }) },
      ),
    ).resolves.toBeUndefined()
  })
})
