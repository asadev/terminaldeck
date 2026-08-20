/**
 * Dropping something on a terminal, decided without a DOM.
 *
 * Each of these is a step the drop handlers take, and each one has a failure
 * that used to be silent: a drag whose kinds were read off `items` instead of
 * `types` (so the pane refused every file), a path typed unquoted (so a photo
 * called `holiday photo.jpg` became two arguments), an `ok` with no path (so the
 * prompt got two quote marks), and a transfer whose line said it had worked.
 */

import { describe, expect, it } from 'vitest'
import {
  draggingFiles,
  droppedPaths,
  droppedText,
  promptWord,
  readUploadOutcome,
  transferLine,
} from './terminal-drop'

describe('whether a drag is carrying files', () => {
  it('reads the kinds rather than the contents', () => {
    /*
     * During `dragover` the browser deliberately hides the contents of a drag —
     * `getAsFile()` answers null until the drop — while still listing what kinds
     * are on offer. A handler that counted files would decide every drag was
     * empty, refuse to preventDefault, and then never receive a `drop` at all.
     */
    expect(draggingFiles({ types: ['Files'] })).toBe(true)
    expect(draggingFiles({ types: ['text/plain', 'Files'] })).toBe(true)
    expect(draggingFiles({ types: ['text/plain'] })).toBe(false)
    expect(draggingFiles({ types: [] })).toBe(false)
    expect(draggingFiles(null)).toBe(false)
  })
})

describe('the paths behind a drop', () => {
  const file = (name: string): File => ({ name }) as unknown as File

  it('keeps the order they were dropped in', () => {
    const bridge = { pathForDroppedFile: (f: File) => `/tmp/${f.name}` }
    expect(droppedPaths([file('a.png'), file('b.png')], bridge)).toEqual(['/tmp/a.png', '/tmp/b.png'])
  })

  it('leaves out anything with nothing on disk behind it', () => {
    // Dragging selected *text* produces a `File`-shaped item with no path. That
    // is a normal thing to do over a terminal, and the text branch answers it.
    const bridge = { pathForDroppedFile: (f: File) => (f.name === 'real.png' ? '/tmp/real.png' : '') }
    expect(droppedPaths([file('selection'), file('real.png')], bridge)).toEqual(['/tmp/real.png'])
  })
})

describe('what gets typed at the prompt', () => {
  it('quotes the path and leaves one space after it', () => {
    // Without the space a second dropped file abuts the first and the shell
    // reads one word.
    expect(promptWord('/Users/asad/My Photos/holiday photo.jpg')).toBe(
      "'/Users/asad/My Photos/holiday photo.jpg' ",
    )
    expect(promptWord("/tmp/it's here.png")).toBe("'/tmp/it'\\''s here.png' ")
  })

  it('quotes a Windows path the way the shell that will read it does', () => {
    // The style follows the *path*, not this machine: a path that arrived from a
    // paired PC is read by a prompt over there.
    expect(promptWord('C:/Users/asad/My Project/a.txt')).toBe('"C:/Users/asad/My Project/a.txt" ')
  })
})

describe('dropped text', () => {
  it('turns every carriage return into a newline', () => {
    // A `\r` arriving at a pty *is* a Return. A two-line snippet dropped on a
    // shell must not run its first line on the way in.
    expect(droppedText('one\r\ntwo')).toBe('one\ntwo')
    expect(droppedText('one\rtwo')).toBe('one\ntwo')
    expect(droppedText('')).toBe('')
  })
})

describe('what the far machine said about a file', () => {
  it('takes a path, and only a path, as success', () => {
    expect(readUploadOutcome({ ok: true, path: '/far/x.jpg' })).toEqual({ ok: true, path: '/far/x.jpg' })
    // An `ok` with no path would have the pane typing two quote marks at the
    // prompt with nothing to explain it.
    expect(readUploadOutcome({ ok: true, path: '' }).ok).toBe(false)
    expect(readUploadOutcome({ ok: true }).ok).toBe(false)
  })

  it('always has a sentence for a failure, including one that arrives empty', () => {
    expect(readUploadOutcome({ ok: false, message: 'That file is empty.' })).toEqual({
      ok: false,
      message: 'That file is empty.',
    })
    expect(readUploadOutcome({ ok: false }).ok).toBe(false)
    expect((readUploadOutcome({ ok: false }) as { message: string }).message).not.toBe('')
    expect((readUploadOutcome(undefined) as { message: string }).message).not.toBe('')
  })
})

describe('the one line a pane draws about a transfer', () => {
  const line = (over: Partial<Parameters<typeof transferLine>[0]>): string =>
    transferLine({ name: 'clip.mov', size: 1000, sent: 0, phase: 'sending', message: '', ...over })

  it('says the name and the number, and nothing else', () => {
    expect(line({ sent: 420 })).toBe('clip.mov — 42%')
    expect(line({ phase: 'finishing', sent: 1000 })).toBe('clip.mov — finishing')
  })

  it('says nothing at all once it has landed', () => {
    // The success signal is the path appearing at the prompt. A line saying it
    // worked would be narrating something already on screen.
    expect(line({ phase: 'landed', sent: 1000 })).toBe('')
  })

  it('says the failure in the words the end that knows why used', () => {
    expect(line({ phase: 'failed', message: 'That file arrived corrupted.' })).toBe(
      'That file arrived corrupted.',
    )
  })

  it('never divides by a size it was not given', () => {
    expect(line({ size: 0, phase: 'opening' })).toBe('clip.mov')
  })
})
