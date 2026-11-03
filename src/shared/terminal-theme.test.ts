import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  ANSI_SLOTS,
  BUILTIN_SCHEMES,
  COLOUR_SLOTS,
  CUSTOM_SCHEME_PREFIX,
  FOLLOW_APP_SCHEME_ID,
  SLOT_LABELS,
  alphaPart,
  appScheme,
  cleanName,
  contrastRatio,
  copyName,
  copyOf,
  customSchemeKey,
  customSchemesFrom,
  exportScheme,
  isBuiltinId,
  isLightScheme,
  isTerminalScheme,
  newCustomId,
  normaliseColour,
  opaquePart,
  parseScheme,
  schemeById,
  storedScheme,
  withColour,
  xtermTheme,
  type TerminalScheme,
} from './terminal-theme'

const ROOT = resolve(__dirname, '..', '..')
const read = (rel: string): string => readFileSync(join(ROOT, rel), 'utf8')

/**
 * The colours, held to the two things a palette can actually be wrong about.
 *
 * A scheme is data, so most of what could go wrong with one is not a code path
 * — it is a value being *the wrong value*, which no amount of exercising the
 * function that reads it will notice. Two classes of that are checkable and
 * both have already happened in this repository:
 *
 *  1. **A copy has drifted.** Two of the schemes below are the app's own theme
 *     restated in TypeScript, because a stylesheet cannot be imported into a
 *     colour object. `tokens.test.ts` exists because every such copy in this
 *     codebase had gone stale; this file holds the two new ones against the
 *     sheet the same way.
 *  2. **A scheme is not what its name says.** "Solarized Dark" that is not
 *     Solarized Dark is worse than no Solarized at all, and nobody reviewing a
 *     diff of twenty hex codes can see it. What is checkable is the shape:
 *     every slot present, every value a real colour, and the light ones light.
 */
describe('every scheme that ships', () => {
  it('states all twenty-one colours, and every one of them is a colour', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      for (const slot of COLOUR_SLOTS) {
        expect(normaliseColour(scheme[slot]), `${scheme.id}.${slot}`).not.toBeNull()
      }
    }
  })

  it('is normalised already, so nothing is stored one way and compared another', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      for (const slot of COLOUR_SLOTS) {
        expect(scheme[slot], `${scheme.id}.${slot}`).toBe(normaliseColour(scheme[slot]))
      }
    }
  })

  it('has a unique id and a unique name', () => {
    const ids = BUILTIN_SCHEMES.map((scheme) => scheme.id)
    const names = BUILTIN_SCHEMES.map((scheme) => scheme.name)
    expect(new Set(ids).size).toBe(ids.length)
    expect(new Set(names).size).toBe(names.length)
  })

  it('never claims the id that means "no scheme"', () => {
    // `follow-app` resolving to a scheme would make the default un-choosable:
    // the pane would draw a card for it and the terminal would pin it.
    expect(schemeById(FOLLOW_APP_SCHEME_ID)).toBeNull()
    expect(isBuiltinId(FOLLOW_APP_SCHEME_ID)).toBe(false)
  })

  /**
   * The light/dark question, answered by measurement rather than by a flag.
   *
   * This is the assertion that makes {@link isLightScheme} worth having: it is
   * derived, so a scheme somebody edits to a white ground becomes light without
   * anybody remembering to say so — and a shipped scheme whose name says Light
   * has to actually be one.
   */
  it('classifies each one as the side its own name claims', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      const saysLight = /light/i.test(scheme.name)
      expect(isLightScheme(scheme), `${scheme.name}`).toBe(saysLight)
    }
  })

  /**
   * Text has to be readable on the ground it is printed on.
   *
   * 4.5:1 is the AA body-text bar, and every scheme here clears it except
   * Solarized, which is the interesting case rather than an exception being
   * waved through: its own author picked base0 on base03 for a *flat* contrast
   * on purpose, and it measures about 4.2:1. Shipping it retuned would be
   * shipping something that is not Solarized. So the floor is 4, the two
   * Solarized schemes are the only ones near it, and the editor prints the real
   * number beside anything somebody makes themselves.
   */
  it('puts readable ink on every ground', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      const ratio = contrastRatio(scheme.foreground, scheme.background)
      expect(ratio, `${scheme.name} is ${ratio.toFixed(2)}:1`).toBeGreaterThan(4)
    }
  })

  it('gives the cursor something to sit on that is not itself', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      expect(opaquePart(scheme.cursor), scheme.name).not.toBe(opaquePart(scheme.cursorAccent))
    }
  })

  it('names every slot on screen', () => {
    for (const slot of COLOUR_SLOTS) {
      expect(SLOT_LABELS[slot]?.trim() ?? '', slot).not.toBe('')
    }
    expect(new Set(Object.values(SLOT_LABELS)).size).toBe(COLOUR_SLOTS.length)
  })
})

/**
 * The app's own two, against the stylesheet they were copied from.
 *
 * This is the mechanism `tokens.test.ts` exists for, applied to the two copies
 * this feature added. A CSS custom property cannot be imported into a colour
 * object, so these twenty-one values are hand-written twice — and every
 * hand-written copy of a colour in this repository had gone stale by the time
 * anybody checked. Reading the sheet as text is the only thing that keeps them
 * honest, and it fails on the day somebody retunes the palette and forgets this
 * file rather than on the day a user notices their terminal is the wrong grey.
 */
describe('the two schemes that restate the app’s own theme', () => {
  const sheet = read('src/renderer/styles/tokens.css')

  /** The value of `name` inside the `[data-theme='…']` block. */
  const token = (theme: 'dark' | 'light', name: string): string => {
    const block = new RegExp(`\\[data-theme='${theme}'\\]\\s*\\{([\\s\\S]*?)\\n\\}`).exec(sheet)
    expect(block, `${theme} block missing from tokens.css`).not.toBeNull()
    const found = new RegExp(`${name}:\\s*([^;]+);`).exec(block![1])
    expect(found, `${name} missing from the ${theme} theme`).not.toBeNull()
    return found![1].trim().toLowerCase()
  }

  const PAIRS: ReadonlyArray<readonly ['dark' | 'light', string]> = [
    ['dark', 'deck-dark'],
    ['light', 'deck-light'],
  ]

  it.each(PAIRS)('%s: the ground and the ink are the sheet’s', (theme, id) => {
    const scheme = schemeById(id)!
    expect(scheme.background).toBe(token(theme, '--terminal-bg'))
    expect(scheme.foreground).toBe(token(theme, '--terminal-fg'))
    expect(scheme.cursor).toBe(token(theme, '--accent'))
    // The block cursor prints the ground through the character under it.
    expect(scheme.cursorAccent).toBe(scheme.background)
  })

  it.each(PAIRS)('%s: all sixteen are the sheet’s', (theme, id) => {
    const scheme = schemeById(id)!
    for (const slot of ANSI_SLOTS) {
      const name = `--ansi-${slot.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`
      expect(scheme[slot], `${id}.${slot}`).toBe(token(theme, name))
    }
  })

  it('is what `appScheme` hands back for each appearance', () => {
    expect(appScheme('dark').id).toBe('deck-dark')
    expect(appScheme('light').id).toBe('deck-light')
  })
})

/**
 * The keys handed to the emulator are the keys the emulator has.
 *
 * `TerminalView` casts this object to xterm's `ITheme`, and a cast is a claim
 * the compiler stops checking. The claim is checkable against the emulator's
 * own typings, read as text — which is also the only version of this check that
 * fails when xterm *renames* a slot in a major version rather than when
 * somebody here invents one.
 */
describe('the object handed to xterm', () => {
  it('uses only names xterm declares on ITheme', () => {
    const typings = read('node_modules/@xterm/xterm/typings/xterm.d.ts')
    const block = /interface ITheme \{([\s\S]*?)\n {2}\}/.exec(typings)
    expect(block, 'xterm no longer declares ITheme the way this test reads it').not.toBeNull()
    const declared = new Set([...block![1].matchAll(/^\s*(\w+)\??:/gm)].map((m) => m[1]))
    for (const slot of COLOUR_SLOTS) {
      expect(declared.has(slot), `xterm has no ITheme.${slot}`).toBe(true)
    }
  })

  it('carries the colours and neither of the two labels', () => {
    const theme = xtermTheme(BUILTIN_SCHEMES[0]) as Record<string, string>
    expect(Object.keys(theme).sort()).toEqual([...COLOUR_SLOTS].sort())
    expect(theme.id).toBeUndefined()
    expect(theme.name).toBeUndefined()
  })
})

describe('a colour, normalised', () => {
  it('expands the short forms the way CSS does', () => {
    expect(normaliseColour('#abc')).toBe('#aabbcc')
    expect(normaliseColour('#abcd')).toBe('#aabbccdd')
  })

  it('lower-cases and trims, so two spellings of one colour compare equal', () => {
    expect(normaliseColour('  #FF00AA ')).toBe('#ff00aa')
  })

  it('keeps eight digits, because the selection needs the alpha', () => {
    expect(normaliseColour('#3b8fee29')).toBe('#3b8fee29')
    expect(alphaPart('#3b8fee29')).toBe('29')
    expect(alphaPart('#3b8fee')).toBe('')
    expect(opaquePart('#3b8fee29')).toBe('#3b8fee')
  })

  /**
   * Everything else is refused, and that is the security half of this function.
   *
   * A scheme arrives as text somebody pasted and ends up in a `style`
   * attribute on the preview and in xterm's theme object. A named colour would
   * merely be surprising; the rest of what fits in a CSS colour position is
   * not, which is why this is an allow-list of hex and nothing else.
   */
  it.each([
    'red',
    'rgb(1,2,3)',
    'url(x)',
    'javascript:alert(1)',
    '#12345',
    '#gggggg',
    '',
    '#',
  ])('refuses %s', (value) => {
    expect(normaliseColour(value)).toBeNull()
  })

  it('refuses anything that is not a string at all', () => {
    for (const value of [null, undefined, 42, {}, ['#ffffff']]) {
      expect(normaliseColour(value)).toBeNull()
    }
  })

  it('leaves a scheme alone when the value is half typed', () => {
    const scheme = BUILTIN_SCHEMES[0]
    expect(withColour(scheme, 'red', '#ff')).toBe(scheme)
    expect(withColour(scheme, 'red', '#ff0000').red).toBe('#ff0000')
  })
})

describe('reading a scheme somebody pasted', () => {
  const CANONICAL = exportScheme(schemeById('nord')!)

  it('takes this app’s own export back', () => {
    const result = parseScheme(CANONICAL)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    const nord = schemeById('nord')!
    for (const slot of COLOUR_SLOTS) expect(result.scheme[slot], slot).toBe(nord[slot])
    expect(result.scheme.name).toBe('Nord')
  })

  /**
   * And the other spelling, which is the one people will actually paste.
   *
   * `cursorColor`, `purple`, `brightPurple`. Accepting them is six lines and is
   * the difference between "paste a scheme you found" working and not.
   */
  it('takes the alias spellings', () => {
    const result = parseScheme(
      JSON.stringify({
        name: 'Elsewhere',
        background: '#101010',
        foreground: '#e0e0e0',
        cursorColor: '#ffcc00',
        selectionBackground: '#333333',
        black: '#000000',
        red: '#ff0000',
        green: '#00ff00',
        yellow: '#ffff00',
        blue: '#0000ff',
        purple: '#ff00ff',
        cyan: '#00ffff',
        white: '#cccccc',
        brightBlack: '#666666',
        brightRed: '#ff6666',
        brightGreen: '#66ff66',
        brightYellow: '#ffff66',
        brightBlue: '#6666ff',
        brightPurple: '#ff66ff',
        brightCyan: '#66ffff',
        brightWhite: '#ffffff',
      }),
    )
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.scheme.cursor).toBe('#ffcc00')
    expect(result.scheme.magenta).toBe('#ff00ff')
    expect(result.scheme.brightMagenta).toBe('#ff66ff')
  })

  it('takes the first scheme out of a file of them', () => {
    const wrapped = JSON.stringify({ schemes: [JSON.parse(CANONICAL)] })
    const result = parseScheme(wrapped)
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.scheme.name).toBe('Nord')
  })

  /**
   * The two slots almost nobody publishes are filled in rather than refused.
   *
   * Refusing over `cursorAccent` would reject most of the schemes in the world
   * for a field their authors never had.
   */
  it('fills in the cursor’s ground and a selection when they are absent', () => {
    const raw = JSON.parse(CANONICAL) as Record<string, unknown>
    delete raw.cursorAccent
    delete raw.selectionBackground
    const result = parseScheme(JSON.stringify(raw))
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.scheme.cursorAccent).toBe(result.scheme.background)
    expect(normaliseColour(result.scheme.selectionBackground)).not.toBeNull()
  })

  it('never takes an id from the file, so a paste cannot take over a scheme', () => {
    const result = parseScheme(JSON.stringify({ ...JSON.parse(CANONICAL), id: 'nord' }), ['custom-1'])
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.scheme.id).toBe('custom-2')
  })

  it('names what is missing rather than saying no', () => {
    const result = parseScheme('{ "name": "Half", "background": "#101010", "foreground": "#eeeeee" }')
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.problem).toContain('cursor')
    expect(result.problem).toContain('black')
  })

  it('says so when it is not JSON at all', () => {
    const result = parseScheme('{ nope')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.problem).toContain('JSON')
  })

  it('refuses a colour that is not one, rather than passing it to the emulator', () => {
    const raw = { ...(JSON.parse(CANONICAL) as Record<string, unknown>), red: 'javascript:x' }
    const result = parseScheme(JSON.stringify(raw))
    expect(result.ok).toBe(false)
  })

  it('exports something the other spelling can read too', () => {
    const out = JSON.parse(exportScheme(schemeById('dracula')!)) as Record<string, string>
    expect(out.cursorColor).toBe(out.cursor)
    expect(out.purple).toBe(out.magenta)
    expect(out.brightPurple).toBe(out.brightMagenta)
  })
})

describe('the schemes somebody makes', () => {
  const nord = schemeById('nord')!

  it('copies under a name that says whose it is, and does not stack the suffix', () => {
    expect(copyName('Nord')).toBe('Nord (yours)')
    expect(copyName('Nord (yours)')).toBe('Nord (yours)')
  })

  it('takes an id nothing else is using', () => {
    expect(newCustomId([])).toBe('custom-1')
    expect(newCustomId(['custom-1', 'custom-2'])).toBe('custom-3')
    // A gap is filled rather than skipped past: deleting the second of three
    // and making a fourth must not leave two schemes on one key.
    expect(newCustomId(['custom-1', 'custom-3'])).toBe('custom-2')
  })

  it('is a copy of the colours, not a reference to them', () => {
    const copy = copyOf(nord, [])
    expect(copy.id).not.toBe(nord.id)
    expect(copy.name).toBe('Nord (yours)')
    for (const slot of COLOUR_SLOTS) expect(copy[slot]).toBe(nord[slot])
  })

  it('reads back off the settings map under its own key', () => {
    const mine = { ...copyOf(nord, []), name: 'Mine' }
    const values = { [customSchemeKey(mine.id)]: storedScheme(mine), 'appearance.density': 'compact' }
    const back = customSchemesFrom(values)
    expect(back).toHaveLength(1)
    expect(back[0].id).toBe(mine.id)
    expect(back[0].name).toBe('Mine')
    expect(back[0].brightCyan).toBe(nord.brightCyan)
  })

  /**
   * The id comes from the key, never from the value.
   *
   * Two schemes with one id is a picker that cannot show both and a choice that
   * points at whichever one `find` reached first. The key is unique by
   * construction, so taking the id from it makes that state unreachable.
   */
  it('takes its id from the key it was stored under', () => {
    const mine = copyOf(nord, [])
    const values = { [customSchemeKey('elsewhere')]: storedScheme({ ...mine, id: 'lying' }) }
    expect(customSchemesFrom(values)[0].id).toBe('elsewhere')
  })

  it('skips a key that has been damaged rather than losing the rest', () => {
    const mine = copyOf(nord, [])
    const values = {
      [`${CUSTOM_SCHEME_PREFIX}broken`]: '{ not json',
      [`${CUSTOM_SCHEME_PREFIX}empty`]: '',
      [`${CUSTOM_SCHEME_PREFIX}partial`]: JSON.stringify({ name: 'Half', background: '#000000' }),
      [customSchemeKey(mine.id)]: storedScheme(mine),
    }
    expect(customSchemesFrom(values).map((scheme) => scheme.id)).toEqual([mine.id])
  })

  it('sorts by name, so the list does not reorder itself on every read', () => {
    const values = {
      [customSchemeKey('a')]: storedScheme({ ...nord, name: 'Zephyr' }),
      [customSchemeKey('b')]: storedScheme({ ...nord, name: 'Amber' }),
    }
    expect(customSchemesFrom(values).map((scheme) => scheme.name)).toEqual(['Amber', 'Zephyr'])
  })

  /**
   * A stored scheme fits in a settings value with room to spare.
   *
   * `settings-store.ts` cuts a string at 4096 characters **silently**, so a
   * value that outgrew it would come back as a scheme with a torn colour in it
   * rather than as an error. This is the check that keeps one-key-per-scheme
   * honest.
   */
  it('stores well under the settings file’s silent cut', () => {
    for (const scheme of BUILTIN_SCHEMES) {
      expect(storedScheme(scheme).length, scheme.name).toBeLessThan(2048)
    }
  })

  it('wins a lookup against a built-in of the same id', () => {
    const mine: TerminalScheme = { ...nord, id: 'nord', name: 'Not really Nord' }
    expect(schemeById('nord', [mine])!.name).toBe('Not really Nord')
  })

  it('is only a scheme when every colour is there', () => {
    expect(isTerminalScheme(nord)).toBe(true)
    expect(isTerminalScheme({ ...nord, brightCyan: 'teal' })).toBe(false)
    expect(isTerminalScheme({ ...nord, name: '' })).toBe(false)
    expect(isTerminalScheme(null)).toBe(false)
    expect(isTerminalScheme([nord])).toBe(false)
  })

  it('holds a name to one line of ordinary text', () => {
    expect(cleanName('  Two   words  ')).toBe('Two words')
    expect(cleanName('x'.repeat(200))).toHaveLength(48)
    expect(cleanName(42)).toBe('')
  })
})
