import { describe, expect, it } from 'vitest'
import { KEYMAP, chordMatches, parseChord } from '../keymap'
import { TERMINAL_COMMANDS, terminalChord } from './TerminalView'

/**
 * The three chords the shortcuts sheet prints under "In a session".
 *
 * All three were in `KEYMAP` with no implementation anywhere — `run()` in
 * App.tsx does not know them, so they fell through to xterm, which does nothing
 * with any of them. These tests tie the handler to the table: if a binding's
 * chord changes, the matcher below stops agreeing with it.
 */
describe('terminalChord', () => {
  const key = (k: string, mods: Partial<Record<'metaKey' | 'ctrlKey' | 'shiftKey' | 'altKey', boolean>> = {}) => ({
    key: k,
    ...mods,
  })

  it('matches what the keymap declares, on both platforms', () => {
    for (const id of TERMINAL_COMMANDS) {
      const binding = KEYMAP.find((b) => b.id === id)
      expect(binding, `${id} is not in the keymap`).toBeDefined()
      const chord = parseChord(binding!.keys[0])
      expect(chord, `${id} has an unparseable chord`).not.toBeNull()

      for (const isMac of [true, false]) {
        const event = {
          key: chord!.key,
          metaKey: isMac && chord!.mod,
          ctrlKey: !isMac && chord!.mod,
          shiftKey: chord!.shift,
          altKey: chord!.alt,
        }
        expect(chordMatches(chord!, event, isMac), `${id} on ${isMac ? 'mac' : 'pc'}`).toBe(true)
        expect(terminalChord(event), `${id} on ${isMac ? 'mac' : 'pc'}`).toBe(id)
      }
    }
  })

  it('leaves everything else to the session', () => {
    // A terminal is a full keyboard application. Claiming a key it wanted is
    // the one failure mode worse than not implementing the shortcut at all.
    expect(terminalChord(key('f'))).toBeNull()
    expect(terminalChord(key('c', { ctrlKey: true }))).toBeNull()
    expect(terminalChord(key('k', { metaKey: true }))).toBeNull()
    expect(terminalChord(key('t', { metaKey: true }))).toBeNull()
    expect(terminalChord(key('f', { metaKey: true, altKey: true }))).toBeNull()
  })

  it('is case-insensitive, because Shift changes the character', () => {
    expect(terminalChord(key('K', { metaKey: true, shiftKey: true }))).toBe('terminal.clear')
    expect(terminalChord(key('C', { metaKey: true, shiftKey: true }))).toBe('terminal.copy')
  })
})
