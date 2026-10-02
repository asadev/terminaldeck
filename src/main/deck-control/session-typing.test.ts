import { describe, expect, it } from 'vitest'
import { ESCAPE_GAP_MS, KEY_GAP_MS, KeyError, MAX_KEYS, pressKeys, resolveKey, resolveKeys, typeLine } from './session-typing'

/** Every write and every pause, in order, so the *sequence* is what is asserted. */
function recorder(): { trace: string[]; write(data: string): void; sleep(ms: number): Promise<void> } {
  const trace: string[] = []
  return {
    trace,
    write: (data) => {
      trace.push(`write ${JSON.stringify(data)}`)
    },
    sleep: async (ms) => {
      trace.push(`wait ${ms}`)
    },
  }
}

describe('typing a line', () => {
  it('sends the text and its Enter as two writes with a gap — never one write ending in a return', async () => {
    /*
     * The defect this file is named for. A 145-character message written as one
     * chunk with `\r` on the end is a paste to the agent CLIs: the return is a
     * newline and nothing is sent. Measured in `renderer/chat/attach/mentions.ts`
     * and found again in `sessions.send`.
     */
    const r = recorder()
    const long = 'please read the failing test in src/app.test.ts and fix the cause rather than the assertion, then run it'
    await typeLine(r.write, long, true, r.sleep)
    expect(r.trace).toEqual([`write ${JSON.stringify(long)}`, `wait ${KEY_GAP_MS}`, 'write "\\r"'])
  })

  it('adds the trailing space a line with an @ needs, so the completion popup does not eat the Enter', async () => {
    const r = recorder()
    await typeLine(r.write, 'look at @src/app.ts', true, r.sleep)
    expect(r.trace[0]).toBe('write "look at @src/app.ts "')
  })

  it('types the text alone, with no added space and no Enter, when not submitting', async () => {
    const r = recorder()
    await typeLine(r.write, 'look at @src/app.ts', false, r.sleep)
    expect(r.trace).toEqual(['write "look at @src/app.ts"'])
  })
})

describe('naming a key', () => {
  it('knows the keys a permission menu wants', () => {
    expect(resolveKey('enter').bytes).toBe('\r')
    expect(resolveKey('escape').bytes).toBe('\x1b')
    expect(resolveKey('down').bytes).toBe('\x1b[B')
    expect(resolveKey('ctrl-c').bytes).toBe('\x03')
    expect(resolveKey('shift-tab').bytes).toBe('\x1b[Z')
  })

  it('reads the spellings a model reaches for', () => {
    expect(resolveKey('Ctrl+C').name).toBe('ctrl-c')
    expect(resolveKey('ctrl_c').name).toBe('ctrl-c')
    expect(resolveKey('Return').name).toBe('enter')
    expect(resolveKey('esc').name).toBe('escape')
    expect(resolveKey('arrow-up').name).toBe('up')
  })

  it('takes one printable character as itself — a menu choice', () => {
    expect(resolveKey('2')).toMatchObject({ bytes: '2', name: 'char:2' })
    expect(resolveKey('y').bytes).toBe('y')
    expect(resolveKey('é').bytes).toBe('é')
  })

  it('refuses a raw control character, so no escape sequence can be smuggled in by value', () => {
    expect(() => resolveKey('\x1b')).toThrow(KeyError)
    expect(() => resolveKey('\x03')).toThrow(KeyError)
  })

  it('refuses a name it does not have, and lists the ones it does', () => {
    expect(() => resolveKey('hyper')).toThrow(/enter, escape/)
    // Ctrl-Z is deliberately absent: it suspends the agent where nothing here can see it.
    expect(() => resolveKey('ctrl-z')).toThrow(KeyError)
  })

  it('caps how many keys one call may press', () => {
    expect(() => resolveKeys(Array.from({ length: MAX_KEYS + 1 }, () => 'down'))).toThrow(KeyError)
    expect(() => resolveKeys([])).toThrow(KeyError)
  })
})

describe('pressing keys', () => {
  it('writes each key on its own, with a longer pause after a lone Escape', async () => {
    /*
     * Escape followed at once by "1" is read as Alt-1, not as two keys. The
     * pause is what makes the second key its own keypress.
     */
    const r = recorder()
    await pressKeys(r.write, resolveKeys(['escape', '1', 'enter']), r.sleep)
    expect(r.trace).toEqual([
      'write "\\u001b"',
      `wait ${ESCAPE_GAP_MS}`,
      'write "1"',
      `wait ${KEY_GAP_MS}`,
      'write "\\r"',
    ])
  })
})
