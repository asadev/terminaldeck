import { describe, expect, it } from 'vitest'
import {
  bindingsInScope,
  chordMatches,
  chordToString,
  formatBinding,
  formatChord,
  groupedKeymap,
  KEYMAP,
  keyToken,
  parseChord,
  resolveCommand,
  scopeForTarget,
  searchKeymap,
  stealsFromTerminal,
  unhandledCommands,
  type KeyBinding,
  type KeyLike,
} from './keymap'

const MAC = { isMac: true }
const PC = { isMac: false }

/** A KeyboardEvent-shaped literal. Modifiers default to off. */
function press(key: string, mods: Partial<KeyLike> = {}): KeyLike {
  return { key, ...mods }
}

function chord(text: string) {
  const parsed = parseChord(text)
  if (!parsed) throw new Error(`unparseable chord: ${text}`)
  return parsed
}

describe('parseChord', () => {
  it('reads modifiers in any order', () => {
    expect(parseChord('mod+shift+t')).toEqual({
      mod: true,
      ctrl: false,
      alt: false,
      shift: true,
      key: 't',
    })
    expect(parseChord('shift+mod+t')).toEqual(parseChord('mod+shift+t'))
    expect(parseChord('MOD+Shift+T')).toEqual(parseChord('mod+shift+t'))
  })

  it('accepts the usual aliases', () => {
    expect(parseChord('cmd+k')).toEqual(parseChord('mod+k'))
    expect(parseChord('option+k')).toEqual(parseChord('alt+k'))
    expect(parseChord('control+k')).toEqual(parseChord('ctrl+k'))
  })

  it('rejects malformed chords rather than binding nothing', () => {
    expect(parseChord('mod')).toBeNull()
    expect(parseChord('')).toBeNull()
    expect(parseChord('mod+mod+t')).toBeNull()
    expect(parseChord('mod+t+u')).toBeNull()
    expect(parseChord('+')).toEqual({ mod: false, ctrl: false, alt: false, shift: false, key: '+' })
  })

  it('round-trips through chordToString', () => {
    for (const text of ['mod+t', 'mod+shift+i', 'ctrl+shift+tab', 'mod+\\', 'escape', 'mod+,']) {
      expect(chordToString(chord(text))).toBe(text)
    }
  })
})

describe('keyToken', () => {
  it('lowercases the uppercase letter macOS sends for Shift+key', () => {
    // Verified behaviour: on macOS Shift+T arrives with key === 'T'.
    expect(keyToken(press('T', { shiftKey: true }))).toBe('t')
    expect(keyToken(press('t'))).toBe('t')
  })

  it('recovers the key when Option rewrites the character', () => {
    // ⌥T produces '†' on macOS — nothing about the character says "T", so the
    // physical code is the only thing left to read.
    expect(keyToken(press('†', { altKey: true, code: 'KeyT' }))).toBe('t')
    expect(keyToken(press('˜', { altKey: true, code: 'KeyN' }))).toBe('n')
    // A plain Option+digit still produces a usable character on many layouts.
    expect(keyToken(press('1', { altKey: true, code: 'Digit1' }))).toBe('1')
  })

  it('does not reach for the code on an ordinary letter', () => {
    // On a Dvorak or AZERTY layout the code is the wrong key entirely.
    expect(keyToken(press('a', { code: 'KeyQ' }))).toBe('a')
    expect(keyToken(press('A', { shiftKey: true, code: 'KeyQ' }))).toBe('a')
  })

  it('maps shifted punctuation back to the printed key', () => {
    expect(keyToken(press('?', { shiftKey: true, code: 'Slash' }))).toBe('/')
    // Without a code it falls back to the US layout map.
    expect(keyToken(press('?', { shiftKey: true }))).toBe('/')
    expect(keyToken(press('!', { shiftKey: true }))).toBe('1')
  })

  it('names the non-character keys', () => {
    expect(keyToken(press('Escape'))).toBe('escape')
    expect(keyToken(press('ArrowUp'))).toBe('up')
    expect(keyToken(press(' '))).toBe('space')
    expect(keyToken(press('F5'))).toBe('f5')
    expect(keyToken(press(''))).toBe('')
  })
})

describe('chordMatches', () => {
  it('requires the modifiers exactly, never a superset', () => {
    expect(chordMatches(chord('mod+t'), press('t', { metaKey: true }), true)).toBe(true)
    // ⌘⇧T must not fire ⌘T on its way past.
    expect(chordMatches(chord('mod+t'), press('T', { metaKey: true, shiftKey: true }), true)).toBe(false)
    expect(chordMatches(chord('mod+shift+t'), press('T', { metaKey: true, shiftKey: true }), true)).toBe(
      true,
    )
  })

  it('maps mod to Command on macOS and Control elsewhere', () => {
    expect(chordMatches(chord('mod+t'), press('t', { metaKey: true }), true)).toBe(true)
    expect(chordMatches(chord('mod+t'), press('t', { ctrlKey: true }), true)).toBe(false)
    expect(chordMatches(chord('mod+t'), press('t', { ctrlKey: true }), false)).toBe(true)
    expect(chordMatches(chord('mod+t'), press('t', { metaKey: true }), false)).toBe(false)
  })

  it('collapses mod and ctrl into one key off macOS', () => {
    // There is no Command outside macOS, so both requirements are Control.
    expect(chordMatches(chord('mod+ctrl+t'), press('t', { ctrlKey: true }), false)).toBe(true)
    expect(chordMatches(chord('mod+ctrl+t'), press('t', { metaKey: true, ctrlKey: true }), true)).toBe(
      true,
    )
  })
})

describe('scope resolution', () => {
  it('resolves the app shortcuts anywhere', () => {
    expect(resolveCommand(press('t', { metaKey: true }), MAC)).toBe('session.new')
    // ⌘⇧T is the accelerator the application menu prints beside "New Session…",
    // and an Electron menu accelerator is what actually fires — so it is the
    // dialog, not a resume. This assertion used to say the opposite, which is
    // the drift the sheet was printing.
    expect(resolveCommand(press('T', { metaKey: true, shiftKey: true }), MAC)).toBe(
      'session.newDialog',
    )
    expect(resolveCommand(press('R', { metaKey: true, shiftKey: true }), MAC)).toBe('session.resume')
    expect(resolveCommand(press('I', { metaKey: true, shiftKey: true }), MAC)).toBe('view.inspector')
    expect(resolveCommand(press(',', { metaKey: true }), MAC)).toBe('app.preferences')
    expect(resolveCommand(press('/', { metaKey: true }), MAC)).toBe('app.shortcuts')
  })

  it('lets single keys through to the terminal', () => {
    for (const key of ['a', 'Z', '1', 'Enter', 'ArrowUp', 'Tab', 'Escape', ' ']) {
      expect(resolveCommand(press(key), { ...MAC, scope: 'terminal' })).toBeNull()
    }
  })

  it('leaves Control chords to the terminal on macOS', () => {
    // ⌃C interrupts the agent. An app that claimed it would be broken.
    expect(resolveCommand(press('c', { ctrlKey: true }), { ...MAC, scope: 'terminal' })).toBeNull()
    expect(resolveCommand(press('d', { ctrlKey: true }), { ...MAC, scope: 'terminal' })).toBeNull()
  })

  it('claims Command chords over a focused terminal on macOS', () => {
    expect(resolveCommand(press('t', { metaKey: true }), { ...MAC, scope: 'terminal' })).toBe(
      'session.new',
    )
    expect(resolveCommand(press('f', { metaKey: true }), { ...MAC, scope: 'terminal' })).toBe(
      'terminal.find',
    )
  })

  it('needs Shift as well off macOS, where Ctrl belongs to the terminal', () => {
    const terminal = { ...PC, scope: 'terminal' as const }
    expect(resolveCommand(press('p', { ctrlKey: true }), terminal)).toBeNull()
    expect(resolveCommand(press('P', { ctrlKey: true, shiftKey: true }), terminal)).toBe(
      'palette.commands',
    )
    // The same chord is live everywhere else.
    expect(resolveCommand(press('p', { ctrlKey: true }), PC)).toBe('palette.quickOpen')
  })

  it('only lets a multi-chord binding through on the chord that outranks the terminal', () => {
    const terminal = { ...PC, scope: 'terminal' as const }
    // palette.commands is ctrl+k and ctrl+shift+p; only the shifted one is free.
    expect(resolveCommand(press('k', { ctrlKey: true }), terminal)).toBeNull()
    expect(resolveCommand(press('P', { ctrlKey: true, shiftKey: true }), terminal)).toBe(
      'palette.commands',
    )
  })

  it('gives a dialog the whole keyboard', () => {
    const modal = { ...MAC, scope: 'modal' as const }
    expect(resolveCommand(press('Escape'), modal)).toBe('modal.close')
    expect(resolveCommand(press('ArrowDown'), modal)).toBe('modal.next')
    // Closing the session behind an open dialog would be a data-loss bug.
    expect(resolveCommand(press('w', { metaKey: true }), modal)).toBeNull()
    expect(resolveCommand(press('t', { metaKey: true }), modal)).toBeNull()
  })

  it('never resolves a passthrough binding', () => {
    const terminal = { ...MAC, scope: 'terminal' as const }
    expect(resolveCommand(press('c', { ctrlKey: true }), terminal)).toBeNull()
    expect(resolveCommand(press('Escape'), terminal)).toBeNull()
    // …but the sheet still lists them.
    expect(KEYMAP.some((b) => b.id === 'terminal.interrupt' && b.passthrough)).toBe(true)
  })

  it('keeps terminal bindings out of the global scope', () => {
    expect(bindingsInScope('global', true).some((b) => b.scope === 'terminal')).toBe(false)
    expect(bindingsInScope('terminal', true).some((b) => b.id === 'terminal.find')).toBe(true)
  })

  it('treats a modified Tab as the app tab-switcher, not terminal input', () => {
    expect(stealsFromTerminal(chord('ctrl+tab'), true)).toBe(true)
    expect(stealsFromTerminal(chord('ctrl+tab'), false)).toBe(true)
    expect(resolveCommand(press('Tab', { ctrlKey: true }), { ...MAC, scope: 'terminal' })).toBe(
      'session.next',
    )
  })

  it('always frees the function keys', () => {
    expect(stealsFromTerminal(chord('f5'), true)).toBe(true)
    expect(stealsFromTerminal(chord('f12'), false)).toBe(true)
  })

  it('resolves against a supplied keymap', () => {
    const custom: KeyBinding[] = [
      { id: 'x', keys: ['alt+j'], label: 'X', scope: 'global', group: 'G' },
    ]
    expect(resolveCommand(press('j', { altKey: true }), { ...MAC, bindings: custom })).toBe('x')
    expect(resolveCommand(press('t', { metaKey: true }), { ...MAC, bindings: custom })).toBeNull()
  })
})

describe('scopeForTarget', () => {
  const terminalNode = { closest: (sel: string) => (sel.includes('.xterm') ? {} : null) }
  const plainNode = { closest: () => null }

  it('reads the terminal off the focused node', () => {
    expect(scopeForTarget(terminalNode)).toBe('terminal')
    expect(scopeForTarget(plainNode)).toBe('global')
    expect(scopeForTarget(null)).toBe('global')
    expect(scopeForTarget(undefined)).toBe('global')
  })

  it('lets an open dialog outrank the terminal underneath it', () => {
    // xterm keeps a focusable textarea behind the scrim.
    expect(scopeForTarget(terminalNode, { modalOpen: true })).toBe('modal')
  })
})

describe('formatting', () => {
  it('renders macOS chords as glyphs with no separators', () => {
    expect(formatChord('mod+shift+t', true)).toBe('⌘⇧T')
    expect(formatChord('mod+t', true)).toBe('⌘T')
    expect(formatChord('mod+,', true)).toBe('⌘,')
    expect(formatChord('mod+\\', true)).toBe('⌘\\')
    expect(formatChord('ctrl+shift+tab', true)).toBe('⌃⇧⇥')
    expect(formatChord('escape', true)).toBe('Esc')
    expect(formatChord('mod+enter', true)).toBe('⌘↩')
  })

  it('spells chords out elsewhere', () => {
    expect(formatChord('mod+shift+t', false)).toBe('Ctrl+Shift+T')
    expect(formatChord('mod+1', false)).toBe('Ctrl+1')
    expect(formatChord('escape', false)).toBe('Esc')
    // mod and ctrl are the same key off macOS — never "Ctrl+Ctrl+T".
    expect(formatChord('mod+ctrl+t', false)).toBe('Ctrl+T')
    expect(formatChord('mod+ctrl+t', true)).toBe('⌘⌃T')
  })

  it('returns nothing for an unparseable chord instead of throwing', () => {
    expect(formatChord('mod', true)).toBe('')
  })

  it('collapses a range from its own chords, on both platforms', () => {
    const jump = KEYMAP.find((b) => b.id === 'session.jump') as KeyBinding
    expect(jump).toBeDefined()
    // A hand-written display string said "⌘1–9" on Windows too.
    expect(formatBinding(jump, true)).toEqual(['⌘1–9'])
    expect(formatBinding(jump, false)).toEqual(['Ctrl+1–9'])
  })

  it('never prints the same chord twice for one binding', () => {
    // Off macOS `mod` and `ctrl` are the same physical key, so these two
    // chords render identically — the sheet said "Ctrl+X or Ctrl+X" and handed
    // React two children with the same key.
    const doubled: KeyBinding = {
      id: 'x',
      keys: ['mod+x', 'ctrl+x'],
      label: 'X',
      scope: 'global',
      group: 'G',
    }
    expect(formatBinding(doubled, false)).toEqual(['Ctrl+X'])
    // On macOS they really are two different chords and both are shown.
    expect(formatBinding(doubled, true)).toEqual(['⌘X', '⌃X'])
    for (const binding of KEYMAP) {
      for (const isMac of [true, false]) {
        const shown = formatBinding(binding, isMac)
        expect(new Set(shown).size, `${binding.id} on ${isMac ? 'mac' : 'pc'}`).toBe(shown.length)
      }
    }
  })

  it('does not collapse a binding that only has one chord', () => {
    const single: KeyBinding = {
      id: 'x',
      keys: ['mod+1'],
      label: 'X',
      scope: 'global',
      group: 'G',
      collapse: 'range',
    }
    expect(formatBinding(single, true)).toEqual(['⌘1'])
  })
})

describe('the keymap itself', () => {
  it('parses every chord it declares', () => {
    for (const binding of KEYMAP) {
      expect(binding.keys.length).toBeGreaterThan(0)
      for (const key of binding.keys) {
        expect(parseChord(key), `${binding.id} → ${key}`).not.toBeNull()
      }
    }
  })

  it('has unique command ids', () => {
    const ids = KEYMAP.map((b) => b.id)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('never claims one chord twice in a scope', () => {
    for (const scope of ['global', 'terminal', 'modal'] as const) {
      const claimed = new Map<string, string>()
      for (const binding of KEYMAP.filter((b) => b.scope === scope && !b.passthrough)) {
        for (const key of binding.keys) {
          const canonical = chordToString(chord(key))
          expect(claimed.get(canonical), `${scope}: ${canonical}`).toBeUndefined()
          claimed.set(canonical, binding.id)
        }
      }
    }
  })

  it('never claims one keystroke twice once the modifiers are resolved', () => {
    // The canonical-string check above compares chords as written, and off
    // macOS `mod` and `ctrl` are the same physical key — so `mod+x` and
    // `ctrl+x` are two spellings of one keystroke there, and only the first
    // would ever fire. This compares what the matcher actually requires.
    const physical = (text: string, isMac: boolean) => {
      const c = chord(text)
      const meta = isMac && c.mod
      const ctrl = isMac ? c.ctrl : c.mod || c.ctrl
      return `${meta ? 'M' : ''}${ctrl ? 'C' : ''}${c.alt ? 'A' : ''}${c.shift ? 'S' : ''}-${c.key}`
    }
    for (const isMac of [true, false]) {
      for (const scope of ['global', 'terminal', 'modal'] as const) {
        const claimed = new Map<string, string>()
        for (const binding of KEYMAP.filter((b) => b.scope === scope && !b.passthrough)) {
          for (const key of binding.keys) {
            const id = physical(key, isMac)
            expect(claimed.get(id), `${scope}/${isMac ? 'mac' : 'pc'}: ${id}`).toBeUndefined()
            claimed.set(id, binding.id)
          }
        }
      }
    }
  })

  it('never lets a global binding collide with a terminal one it can reach', () => {
    for (const isMac of [true, false]) {
      const claimed = new Map<string, string>()
      for (const binding of bindingsInScope('terminal', isMac)) {
        for (const key of binding.keys) {
          const parsed = chord(key)
          if (binding.scope === 'global' && !stealsFromTerminal(parsed, isMac)) continue
          const canonical = chordToString(parsed)
          expect(claimed.get(canonical), `${canonical} on ${isMac ? 'mac' : 'pc'}`).toBeUndefined()
          claimed.set(canonical, binding.id)
        }
      }
    }
  })

  it('keeps the shortcuts the app already answers to', () => {
    const chords = new Map(KEYMAP.map((b) => [b.id, b.keys[0]]))
    expect(chords.get('session.new')).toBe('mod+t')
    expect(chords.get('session.close')).toBe('mod+w')
    expect(chords.get('project.open')).toBe('mod+o')
    expect(chords.get('app.preferences')).toBe('mod+,')
    expect(chords.get('view.inspector')).toBe('mod+shift+i')
    expect(chords.get('palette.commands')).toBe('mod+k')
    expect(chords.get('palette.quickOpen')).toBe('mod+p')
  })
})

describe('sheet helpers', () => {
  it('groups by scope in reading order and keeps table order inside', () => {
    const groups = groupedKeymap()
    expect(groups.map((g) => g.scope)).toEqual(['global', 'terminal', 'modal'])
    const sessions = groups[0].bindings.filter((b) => b.group === 'Sessions').map((b) => b.id)
    expect(sessions.slice(0, 3)).toEqual(['session.new', 'session.resume', 'session.close'])
  })

  it('drops empty scopes', () => {
    const groups = groupedKeymap([
      { id: 'x', keys: ['mod+j'], label: 'X', scope: 'global', group: 'G' },
    ])
    expect(groups.map((g) => g.scope)).toEqual(['global'])
  })

  it('searches labels, groups and rendered keys', () => {
    expect(searchKeymap('session', KEYMAP, true).map((b) => b.id)).toContain('session.new')
    expect(searchKeymap('⌘⇧I', KEYMAP, true).map((b) => b.id)).toEqual(['view.inspector'])
    expect(searchKeymap('mod+w', KEYMAP, true).map((b) => b.id)).toEqual(['session.close'])
    // Every term has to land, so two words narrow rather than widen.
    expect(searchKeymap('clear terminal', KEYMAP, true).map((b) => b.id)).toEqual(['terminal.clear'])
    expect(searchKeymap('   ', KEYMAP, true).length).toBe(KEYMAP.length)
    expect(searchKeymap('zzzz', KEYMAP, true)).toEqual([])
  })

  it('reports commands with no handler so the sheet cannot lie', () => {
    const all = KEYMAP.filter((b) => !b.passthrough).map((b) => b.id)
    expect(unhandledCommands(all)).toEqual([])
    expect(unhandledCommands([])).toContain('session.new')
    // A documented passthrough needs no handler.
    expect(unhandledCommands([])).not.toContain('terminal.interrupt')
  })
})
