import { describe, expect, it } from 'vitest'
import {
  KEY_BAR,
  KEY_BAR_IDLE,
  controlByteForChar,
  controlByteForCode,
  pressCharacter,
  pressKeyBarKey,
  type KeyBarState,
} from './keybar'

/** Tap a sequence and collect what went to the session. */
function tap(...ids: Parameters<typeof pressKeyBarKey>[1][]): { data: string[]; state: KeyBarState } {
  let state = KEY_BAR_IDLE
  const data: string[] = []
  for (const id of ids) {
    const result = pressKeyBarKey(state, id)
    state = result.state
    if (result.data !== '') data.push(result.data)
  }
  return { data, state }
}

describe('the key bar carries what the soft keyboard does not', () => {
  it('offers every key the brief requires', () => {
    const ids = KEY_BAR.map((key) => key.id)
    expect(ids).toEqual([
      'esc',
      'tab',
      'ctrl',
      'up',
      'down',
      'left',
      'right',
      'pipe',
      'slash',
      'dash',
      'tilde',
    ])
  })

  it('sends the escape and tab bytes a terminal expects', () => {
    expect(tap('esc').data).toEqual(['\x1b'])
    expect(tap('tab').data).toEqual(['\t'])
  })

  it('sends cursor keys, not letters', () => {
    expect(tap('up', 'down', 'right', 'left').data).toEqual(['\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D'])
  })

  it('sends the four punctuation keys literally', () => {
    expect(tap('pipe', 'slash', 'dash', 'tilde').data).toEqual(['|', '/', '-', '~'])
  })
})

describe('sticky Ctrl', () => {
  it('produces nothing on its own — it only arms', () => {
    const result = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl')
    expect(result.data).toBe('')
    expect(result.state.ctrl).toBe(true)
  })

  it('folds into the next key: Ctrl then C is an interrupt', () => {
    let state = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl').state
    const press = pressCharacter(state, 'c')
    expect(press.data).toBe('\x03')
    state = press.state
    expect(state.ctrl).toBe(false)
  })

  it('is spent by one key — the key after it is plain again', () => {
    let state = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl').state
    state = pressCharacter(state, 'c').state
    expect(pressCharacter(state, 'w').data).toBe('w')
  })

  it('toggles off when tapped twice, so a mistap costs nothing', () => {
    const armed = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl').state
    const disarmed = pressKeyBarKey(armed, 'ctrl').state
    expect(disarmed.ctrl).toBe(false)
    expect(pressCharacter(disarmed, 'c').data).toBe('c')
  })

  it('turns arrows into the CSI modifier form a shell reads as Ctrl+arrow', () => {
    const armed = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl').state
    expect(pressKeyBarKey(armed, 'left').data).toBe('\x1b[1;5D')
  })

  it('is spent even by a key it cannot combine with', () => {
    // Otherwise it survives to the key after that one, which is how a sticky
    // modifier turns an innocent letter into a chord nobody asked for.
    const armed = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl').state
    const press = pressKeyBarKey(armed, 'pipe')
    expect(press.data).toBe('|')
    expect(press.state.ctrl).toBe(false)
  })

  it('leaves Esc and Tab alone, because Ctrl+[ and Ctrl+I already are those', () => {
    const armed = pressKeyBarKey(KEY_BAR_IDLE, 'ctrl').state
    expect(pressKeyBarKey(armed, 'esc').data).toBe('\x1b')
    expect(pressKeyBarKey(armed, 'tab').data).toBe('\t')
  })

  it('sends a whole paste untouched when Ctrl is not armed', () => {
    expect(pressCharacter(KEY_BAR_IDLE, 'npm test').data).toBe('npm test')
  })
})

describe('control bytes follow the ASCII rule rather than a table of guesses', () => {
  it('masks the letters', () => {
    expect(controlByteForChar('a')).toBe('\x01')
    expect(controlByteForChar('c')).toBe('\x03')
    expect(controlByteForChar('d')).toBe('\x04')
    expect(controlByteForChar('z')).toBe('\x1a')
    expect(controlByteForChar('C')).toBe('\x03')
  })

  it('handles the three ASCII oddities', () => {
    expect(controlByteForChar(' ')).toBe('\x00')
    expect(controlByteForChar('?')).toBe('\x7f')
    expect(controlByteForChar('[')).toBe('\x1b')
  })

  it('refuses to invent a byte for characters terminals disagree about', () => {
    expect(controlByteForChar('/')).toBeNull()
    expect(controlByteForChar('|')).toBeNull()
    expect(controlByteForChar('~')).toBeNull()
    expect(controlByteForChar('')).toBeNull()
    expect(controlByteForChar('ab')).toBeNull()
  })
})

describe('the iOS hardware-keyboard workaround', () => {
  /**
   * The bug: through xterm.js 6.0.0, Safari on iOS reports Ctrl+C with
   * `keyCode: 13`, xterm matches that as Enter and sends a carriage return, so
   * the keystroke meant to stop a runaway process submits a blank line to it.
   * `code` is unaffected, so the byte is decided from `code` alone — these
   * assertions are the reason nothing in this path may read `key` or `keyCode`.
   */
  it('decodes Ctrl+C from the physical key, whatever keyCode claims', () => {
    expect(controlByteForCode('KeyC')).toBe('\x03')
  })

  it('covers the chords that matter on a phone', () => {
    expect(controlByteForCode('KeyD')).toBe('\x04')
    expect(controlByteForCode('KeyZ')).toBe('\x1a')
    expect(controlByteForCode('KeyL')).toBe('\x0c')
    expect(controlByteForCode('KeyR')).toBe('\x12')
    // Ctrl+[ is Escape, which matters on the many layouts that have no Esc key.
    expect(controlByteForCode('BracketLeft')).toBe('\x1b')
    expect(controlByteForCode('Space')).toBe('\x00')
  })

  it('declines anything it does not recognise, so xterm still handles it', () => {
    expect(controlByteForCode('Enter')).toBeNull()
    expect(controlByteForCode('ArrowUp')).toBeNull()
    expect(controlByteForCode('')).toBeNull()
    expect(controlByteForCode('Digit1')).toBeNull()
  })
})
