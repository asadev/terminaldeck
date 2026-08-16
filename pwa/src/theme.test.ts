import { describe, expect, it } from 'vitest'
import type { MediaQueryLike } from './physical-keyboard'
import { memoryStorage } from './remember'
import {
  SYSTEM_DARK_QUERY,
  THEME_ATTRIBUTE,
  THEME_CHOICES,
  THEME_KEY,
  THEME_LABEL,
  readChoice,
  resolveAppearance,
  stampAppearance,
  watchSystemAppearance,
  writeChoice,
  type Appearance,
  type ThemeChoice,
} from './theme'

/** A `MediaQueryList` a test can drive, matching the structural type. */
function fakeQuery(matches: boolean): MediaQueryLike & { fire(matches: boolean): void; listeners: number } {
  const listeners = new Set<(event: { matches: boolean }) => void>()
  return {
    matches,
    addEventListener: (_type, listener) => void listeners.add(listener),
    removeEventListener: (_type, listener) => void listeners.delete(listener),
    fire(next: boolean): void {
      this.matches = next
      for (const listener of listeners) listener({ matches: next })
    },
    get listeners(): number {
      return listeners.size
    },
  }
}

describe('the three states', () => {
  it('has exactly three, and system is the first of them', () => {
    // The regression this stops is the two-state one: a light/dark switch with
    // no way to say "whatever this computer says", which is the default and the
    // one people notice missing.
    expect([...THEME_CHOICES]).toEqual(['system', 'light', 'dark'])
  })

  it('follows the system only for the system choice', () => {
    expect(resolveAppearance('system', true)).toBe('dark')
    expect(resolveAppearance('system', false)).toBe('light')
  })

  it('lets an explicit choice beat the system in both directions', () => {
    // Both directions, because the easy half is "dark on a light machine" and
    // the half that gets forgotten is a person choosing light on a machine that
    // is set to dark.
    expect(resolveAppearance('light', true)).toBe('light')
    expect(resolveAppearance('dark', false)).toBe('dark')
  })

  it('names every choice on screen', () => {
    for (const choice of THEME_CHOICES) {
      expect(THEME_LABEL[choice], `${choice} has no label`).toMatch(/\S/)
    }
  })
})

describe('the choice survives the page', () => {
  it('starts at system when nothing has been stored', () => {
    expect(readChoice(memoryStorage())).toBe('system')
  })

  it('reads back what was written', () => {
    const store = memoryStorage()
    for (const choice of ['light', 'dark'] as const) {
      writeChoice(store, choice)
      expect(readChoice(store)).toBe(choice)
    }
  })

  it('takes the key away again when the answer goes back to system', () => {
    // Not merely equivalent to writing the word: an appearance is a decision
    // that can be withdrawn, and a withdrawn decision must not stay behind in a
    // borrowed browser's storage.
    const store = memoryStorage()
    writeChoice(store, 'dark')
    writeChoice(store, 'system')
    expect(store.getItem(THEME_KEY)).toBeNull()
    expect(readChoice(store)).toBe('system')
  })

  it('ignores a value that is not one of the three', () => {
    // localStorage is shared with everything else on the origin. Trusting it
    // means stamping `data-theme="cyan"` on the document and painting whichever
    // palette the cascade happens to fall through to.
    const store = memoryStorage()
    store.setItem(THEME_KEY, 'cyan')
    expect(readChoice(store)).toBe('system')
  })

  it('keeps working when the store throws on every call', () => {
    // Private-mode Safari. The choice applies to this page and is not
    // remembered, which is what every other stored thing in this client does.
    const angry = {
      getItem: (): string | null => {
        throw new Error('nope')
      },
      setItem: (): void => {
        throw new Error('nope')
      },
      removeItem: (): void => {
        throw new Error('nope')
      },
    }
    expect(readChoice(angry)).toBe('system')
    expect(() => writeChoice(angry, 'light')).not.toThrow()
  })
})

describe('what gets stamped on the document', () => {
  it('always writes an explicit appearance, never the choice', () => {
    // `system` is not a palette. If it ever reached the attribute, the
    // stylesheet would fall through to its base and an explicit dark on a light
    // machine would have nothing to beat the media query with.
    const written: string[] = []
    const root = { setAttribute: (name: string, value: string) => void written.push(`${name}=${value}`) }
    for (const appearance of ['light', 'dark'] as Appearance[]) {
      stampAppearance(root, appearance)
    }
    expect(written).toEqual([`${THEME_ATTRIBUTE}=light`, `${THEME_ATTRIBUTE}=dark`])
  })
})

describe('watching the system', () => {
  it('asks the one query that answers this question', () => {
    // Pinned as a string: the way this gets broken is somebody replacing the
    // query with a user-agent guess, and a behavioural test would not notice.
    const asked: string[] = []
    watchSystemAppearance((query) => {
      asked.push(query)
      return fakeQuery(false)
    }, () => undefined)
    expect(asked).toEqual([SYSTEM_DARK_QUERY])
  })

  it('reports the current answer without calling back', () => {
    let calls = 0
    const watch = watchSystemAppearance(() => fakeQuery(true), () => (calls += 1))
    expect(watch.dark).toBe(true)
    expect(calls).toBe(0)
  })

  it('follows a machine that changes its mind while the page is open', () => {
    const query = fakeQuery(false)
    const seen: boolean[] = []
    const watch = watchSystemAppearance(() => query, (dark) => void seen.push(dark))
    query.fire(true)
    query.fire(true)
    query.fire(false)
    // Twice, not three times: a media query can fire without its answer having
    // changed, and the caller's response is to re-theme the emulator.
    expect(seen).toEqual([true, false])
    expect(watch.dark).toBe(false)
    watch.stop()
    expect(query.listeners).toBe(0)
  })

  it('falls back to dark where the question cannot be asked', () => {
    // Not a coin toss: dark is the base of the stylesheet and the palette this
    // client shipped with, so a browser that cannot answer lands on the one that
    // is right where this client is most used.
    expect(watchSystemAppearance(undefined, () => undefined).dark).toBe(true)
    expect(
      watchSystemAppearance(() => {
        throw new Error('refused')
      }, () => undefined).dark,
    ).toBe(true)
  })
})

describe('the choice type stays a closed set', () => {
  it('resolves every one of them to a real appearance', () => {
    for (const choice of THEME_CHOICES as readonly ThemeChoice[]) {
      expect(['light', 'dark']).toContain(resolveAppearance(choice, true))
      expect(['light', 'dark']).toContain(resolveAppearance(choice, false))
    }
  })
})
