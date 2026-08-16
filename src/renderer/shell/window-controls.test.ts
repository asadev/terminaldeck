import { describe, expect, it } from 'vitest'
import {
  controlsInset,
  installWindowControls,
  WINDOW_CONTROLS_ATTRIBUTE,
  WINDOW_CONTROLS_INSET,
  type TitlebarArea,
  type WindowControlsHost,
  type WindowControlsOverlay,
} from './window-controls'

/**
 * The measurement the Windows window depends on, exercised with no window.
 *
 * There is no DOM in this test process — that is deliberate, see CLAUDE.md — so
 * everything here is driven through the host `installWindowControls` takes.
 * That is the whole reason it takes one: the alternative is a module that can
 * only be checked by opening the app on a machine nobody here has, which is how
 * the Windows title bar came to be three stacked strips for as long as it was.
 */

/** A root element that remembers what was written to it. */
function fakeRoot() {
  const attributes = new Map<string, string>()
  const properties = new Map<string, string>()
  return {
    attributes,
    properties,
    setAttribute: (name: string, value: string) => void attributes.set(name, value),
    removeAttribute: (name: string) => void attributes.delete(name),
    style: {
      setProperty: (name: string, value: string) => void properties.set(name, value),
      removeProperty: (name: string) => void properties.delete(name),
    },
  }
}

/** A stand-in for `navigator.windowControlsOverlay`, with the event it fires. */
function fakeOverlay(area: TitlebarArea, visible = true) {
  const listeners = new Set<() => void>()
  const overlay: WindowControlsOverlay & {
    listeners: Set<() => void>
    set(next: TitlebarArea, nextVisible?: boolean): void
  } = {
    visible,
    listeners,
    getTitlebarAreaRect: () => area,
    addEventListener: (_type, listener) => void listeners.add(listener),
    removeEventListener: (_type, listener) => void listeners.delete(listener),
    set(next, nextVisible = overlay.visible) {
      area = next
      overlay.visible = nextVisible
      for (const listener of [...listeners]) listener()
    },
  }
  return overlay
}

function hostWith(
  overlay: WindowControlsOverlay | null,
  windowWidth = 1440,
): WindowControlsHost & { root: ReturnType<typeof fakeRoot> } {
  return { root: fakeRoot(), overlay, windowWidth: () => windowWidth }
}

describe('controlsInset', () => {
  it('is whatever the OS kept for itself on the right', () => {
    // Windows 11 at 100%: three 46px buttons, so the title bar area we are left
    // with stops 138px short of the window's own right edge.
    expect(controlsInset({ x: 0, width: 1302 }, 1440)).toBe(138)
  })

  it('is measured rather than assumed, so a maximised or scaled window is right too', () => {
    // The same window maximised on a 4K display at 150%: different buttons,
    // different width, and a constant would have been wrong by 70px.
    expect(controlsInset({ x: 0, width: 2352 }, 2560)).toBe(208)
  })

  it('is nothing at all when there is no overlay to measure', () => {
    expect(controlsInset(null, 1440)).toBe(0)
  })

  it('refuses a measurement that cannot be true', () => {
    /*
     * Zero is the safe answer, and that is the point of each of these: it is
     * the layout every platform without an overlay already gets, so a rect that
     * has not been laid out yet, or one from a mocked API, degrades to today's
     * toolbar rather than to a mode switch stranded in the middle of the bar.
     */
    expect(controlsInset({ x: 0, width: 1440 }, 1440)).toBe(0)
    expect(controlsInset({ x: 0, width: 2000 }, 1440)).toBe(0)
    expect(controlsInset({ x: Number.NaN, width: 1302 }, 1440)).toBe(0)
    expect(controlsInset({ x: 0, width: 1302 }, Number.NaN)).toBe(0)
  })

  it('reads a right-to-left window as having nothing on the right, which it has', () => {
    // Windows moves the caption buttons to the left there. The shell is
    // left-to-right throughout, so the honest answer is "no right-hand reserve"
    // rather than a padding that pretends to have handled a mirrored layout.
    expect(controlsInset({ x: 138, width: 1302 }, 1440)).toBe(0)
  })
})

describe('installWindowControls', () => {
  it('writes nothing at all on a platform with no overlay', () => {
    // macOS. The stylesheet reads the attribute to mean "there are no traffic
    // lights on the left" — setting it here would drop the sidebar's collapse
    // arrow straight onto the close button, on the platform that works today.
    const host = hostWith(null)
    installWindowControls(host)
    expect(host.root.attributes.size).toBe(0)
    expect(host.root.properties.size).toBe(0)
  })

  it('publishes the geometry the moment it is installed', () => {
    const host = hostWith(fakeOverlay({ x: 0, width: 1302 }))
    installWindowControls(host)
    expect(host.root.attributes.get(WINDOW_CONTROLS_ATTRIBUTE)).toBe('overlay')
    expect(host.root.properties.get(WINDOW_CONTROLS_INSET)).toBe('138px')
  })

  it('keeps up when the buttons change size under the window', () => {
    /*
     * Maximising a window changes the caption buttons' width, and so does
     * dragging the window to a display with a different scale factor. Neither
     * of those re-renders React, which is why this listens to Chromium's own
     * event instead of measuring on render.
     */
    const overlay = fakeOverlay({ x: 0, width: 1302 })
    const host = hostWith(overlay)
    installWindowControls(host)
    overlay.set({ x: 0, width: 1240 })
    expect(host.root.properties.get(WINDOW_CONTROLS_INSET)).toBe('200px')
  })

  it('gives the room back when the buttons go away', () => {
    // Full screen on Windows takes them off the bar entirely. Holding the
    // reserve would leave a 138px hole in the corner of a full-screen window.
    const overlay = fakeOverlay({ x: 0, width: 1302 })
    const host = hostWith(overlay)
    installWindowControls(host)
    overlay.set({ x: 0, width: 0 }, false)
    expect(host.root.attributes.has(WINDOW_CONTROLS_ATTRIBUTE)).toBe(false)
    expect(host.root.properties.has(WINDOW_CONTROLS_INSET)).toBe(false)
  })

  it('leaves the document as it found it, and stops listening', () => {
    // The component that installs this is unmounted whenever the shell
    // re-mounts — the error boundary re-renders the whole tree — and a listener
    // left behind would be measuring into a root nobody is reading.
    const overlay = fakeOverlay({ x: 0, width: 1302 })
    const host = hostWith(overlay)
    const stop = installWindowControls(host)
    expect(overlay.listeners.size).toBe(1)
    stop()
    expect(overlay.listeners.size).toBe(0)
    expect(host.root.attributes.size).toBe(0)
    expect(host.root.properties.size).toBe(0)
  })
})
