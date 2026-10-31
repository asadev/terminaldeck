import { describe, expect, it } from 'vitest'
import { readSessionWindowEvent, readSessionWindows, tearOffPoint } from './session-windows'

describe('the list of session windows, as the main process sends it', () => {
  it('reads a window and the displays, and which window is asking', () => {
    const view = readSessionWindows({
      windows: [
        {
          sessionId: 's1',
          windowId: 901,
          label: 'Fix the parser',
          status: 'working',
          displayId: 7,
          displayLabel: 'DELL U2723QE',
          bounds: { x: 1, y: 2, width: 3, height: 4 },
          fullScreen: false,
          minimized: false,
          focused: true,
        },
      ],
      displays: [{ id: 7, label: 'DELL U2723QE', primary: false }],
      self: 901,
    })
    expect(view.self).toBe(901)
    expect(view.windows[0]).toMatchObject({ sessionId: 's1', windowId: 901, label: 'Fix the parser', focused: true })
    expect(view.displays).toEqual([{ id: 7, label: 'DELL U2723QE', primary: false }])
  })

  it('drops a row it cannot read rather than drawing it as something else', () => {
    const view = readSessionWindows({ windows: [{ sessionId: '', windowId: 1 }, { sessionId: 's2' }, 'nonsense'], displays: null })
    expect(view.windows).toEqual([])
    expect(view.self).toBeNull()
  })

  it('reads the three moves and nothing else', () => {
    expect(readSessionWindowEvent({ kind: 'docked', sessionId: 's1', select: true })).toEqual({
      kind: 'docked',
      sessionId: 's1',
      select: true,
    })
    expect(readSessionWindowEvent({ kind: 'replaced', previousId: 'a', sessionId: 'b' })).toEqual({
      kind: 'replaced',
      previousId: 'a',
      sessionId: 'b',
    })
    expect(readSessionWindowEvent(null)).toBeNull()
    expect(readSessionWindowEvent({ kind: 'exploded', sessionId: 's1' })).toBeNull()
  })
})

describe('a tab let go outside the window', () => {
  const viewport = { width: 1280, height: 800 }

  it('is a window of its own, opened where it was let go', () => {
    expect(tearOffPoint({ clientX: 1500, clientY: 200, screenX: 3100, screenY: 260 }, viewport)).toEqual({ x: 3100, y: 260 })
    expect(tearOffPoint({ clientX: -40, clientY: 300, screenX: 20, screenY: 360 }, viewport)).toEqual({ x: 20, y: 360 })
    expect(tearOffPoint({ clientX: 400, clientY: 900, screenX: 460, screenY: 960 }, viewport)).toEqual({ x: 460, y: 960 })
  })

  it('is the ordinary fold back into the rail when it lands inside the window', () => {
    expect(tearOffPoint({ clientX: 600, clientY: 400, screenX: 660, screenY: 460 }, viewport)).toBeNull()
  })

  it('is nothing at all when the drag did not say where it ended', () => {
    expect(tearOffPoint({ clientX: 0, clientY: 0, screenX: 0, screenY: 0 }, viewport)).toBeNull()
  })
})
