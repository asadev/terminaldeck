import { describe, expect, it } from 'vitest'
import { NOTCH_SCRIPT, notchOf, parseScreens, readScreens } from './hoot-notch'

/** What AppKit printed on his Mac mini on 2026-10-04: three displays, none with a notch. */
const MINI = JSON.stringify([
  { x: 0, width: 1920, height: 1080, left: 0, right: 0, top: 0 },
  { x: 1920, width: 1200, height: 1920, left: 0, right: 0, top: 0 },
  { x: -1920, width: 1920, height: 1080, left: 0, right: 0, top: 0 },
])

/** A 14-inch MacBook Pro's built-in screen: two strips of menu bar either side of a 200-point notch. */
const MACBOOK = JSON.stringify([{ x: 0, width: 1512, height: 982, left: 656, right: 656, top: 32 }])

describe('the notch', () => {
  it('is none on a screen without one — his Mac mini', () => {
    const screens = parseScreens(MINI)
    expect(screens).toHaveLength(3)
    expect(notchOf({ x: 0, y: 0, width: 1920, height: 1080 }, screens)).toBeNull()
  })

  it('is the gap between the two strips of menu bar on a MacBook', () => {
    expect(notchOf({ x: 0, y: 0, width: 1512, height: 982 }, parseScreens(MACBOOK))).toEqual({
      left: 656,
      width: 200,
      height: 32,
    })
  })

  it('matches the display by its size and x, not its y, which AppKit counts from the other end', () => {
    const screens = parseScreens(JSON.stringify([{ x: -1512, width: 1512, height: 982, left: 656, right: 656, top: 32 }]))
    expect(notchOf({ x: -1512, y: 98, width: 1512, height: 982 }, screens)?.width).toBe(200)
    expect(notchOf({ x: 0, y: 0, width: 1512, height: 982 }, screens)).toBeNull()
  })

  it('is not believed when the numbers cannot be a camera housing', () => {
    const odd = (left: number, right: number) =>
      parseScreens(JSON.stringify([{ x: 0, width: 1512, height: 982, left, right, top: 32 }]))
    const display = { x: 0, y: 0, width: 1512, height: 982 }
    expect(notchOf(display, odd(756, 755))).toBeNull()
    expect(notchOf(display, odd(100, 100))).toBeNull()
    expect(notchOf(display, odd(656, 0))).toBeNull()
  })

  it('reads nothing at all from output that is not what the script prints', () => {
    expect(parseScreens('')).toEqual([])
    expect(parseScreens('execution error: -1743')).toEqual([])
    expect(parseScreens('{"x":1}')).toEqual([])
    expect(parseScreens('[null, 3, {"x":"left"}]')).toEqual([{ x: 0, width: 0, height: 0, left: 0, right: 0, top: 0 }])
  })

  it('asks AppKit through osascript, and answers no screens when that fails — never throws', async () => {
    const calls: Array<{ file: string; args: string[] }> = []
    const ok = await readScreens(async (file, args) => {
      calls.push({ file, args })
      return MACBOOK
    })
    expect(ok[0].left).toBe(656)
    expect(calls[0].file).toBe('/usr/bin/osascript')
    expect(calls[0].args.slice(0, 3)).toEqual(['-l', 'JavaScript', '-e'])
    expect(calls[0].args[3]).toBe(NOTCH_SCRIPT)
    expect(await readScreens(async () => Promise.reject(new Error('timed out')))).toEqual([])
  })

  it('asks for the two strips AppKit names, and nothing else of the screen', () => {
    expect(NOTCH_SCRIPT).toContain('auxiliaryTopLeftArea')
    expect(NOTCH_SCRIPT).toContain('auxiliaryTopRightArea')
  })
})
