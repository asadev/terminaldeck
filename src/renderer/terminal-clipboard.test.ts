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
import { MAX_OSC_CLIPBOARD_BYTES, PASTE_TOO_BIG, decodeOsc52, readOsc52 } from './terminal-clipboard'
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
