import { describe, expect, it } from 'vitest'
import type { Annotation } from '../../shared/annotate'
import { elementFromCapture, normalise } from '../browser/BrowserAnnotate'
import type { BrowserCapture } from '../browser/bridge'
import { composeDeviceShot } from '../devices/DeviceShotPopup'
import { elementOf, subLine } from '../devices/DevicesPage'
import { groupDevices, kindWords, resolveDevicesBridge, stateLine, type DeviceEntry } from '../devices/devices-bridge'
import { markerGeometry, paintMarkers, type PictureContext } from './marked-picture'

describe('the marked picture', () => {
  it('sizes the marker to the picture, not to the screen it was drawn on', () => {
    const phone = markerGeometry({ x: 0.04, y: 0.444, width: 0.92, height: 0.062 }, 1206, 2622)
    const small = markerGeometry({ x: 0.04, y: 0.444, width: 0.92, height: 0.062 }, 402, 874)
    expect(phone.stroke).toBeGreaterThan(small.stroke)
    expect(phone.badge.r).toBeGreaterThan(small.badge.r)
    expect(phone.box.x).toBeCloseTo(48.24)
  })

  it('keeps the number on the picture for an element flush with the edge', () => {
    const top = markerGeometry({ x: 0, y: 0, width: 1, height: 0.05 }, 1206, 2622)
    expect(top.badge.cx - top.badge.r).toBeGreaterThan(0)
    expect(top.badge.cy - top.badge.r).toBeGreaterThan(0)
  })

  it('draws an outline and a numbered disc per note, halo first', () => {
    const calls: string[] = []
    const ctx = {
      strokeStyle: '',
      fillStyle: '',
      lineWidth: 0,
      font: '',
      textAlign: 'left',
      textBaseline: 'alphabetic',
      beginPath: () => calls.push('begin'),
      rect: () => calls.push('rect'),
      arc: () => calls.push('arc'),
      stroke: () => calls.push(`stroke:${String(ctx.strokeStyle)}`),
      fill: () => calls.push(`fill:${String(ctx.fillStyle)}`),
      fillText: (text: string) => calls.push(`text:${text}`),
    } as unknown as PictureContext & { strokeStyle: string; fillStyle: string }
    const notes: Annotation[] = [
      { id: 'a', n: 1, rect: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 }, element: null, note: 'x' },
      { id: 'b', n: 2, rect: { x: 0.5, y: 0.5, width: 0.2, height: 0.1 }, element: null, note: 'y' },
    ]
    paintMarkers(ctx, notes, 1000, 2000, { accent: 'blue', onAccent: 'white' })
    expect(calls.filter((c) => c.startsWith('text:'))).toEqual(['text:1', 'text:2'])
    const strokes = calls.filter((c) => c.startsWith('stroke:'))
    expect(strokes[0]).toMatch(/rgba/)
    expect(strokes[1]).toBe('stroke:blue')
  })
})

describe('a page element, placed on the frozen page', () => {
  const capture: BrowserCapture = {
    selector: '#order',
    tag: 'button',
    label: 'Order now',
    labelSource: 'text',
    url: 'http://localhost:3000/',
    attributes: { id: 'order' },
    context: '',
    pageImage: '',
    rect: { x: 80, y: 230, width: 180, height: 52 },
  }

  it('converts CSS pixels to the view’s own, through the zoom', () => {
    // A page this app zoomed out to 0.8 to fit: CSS pixels are bigger than the
    // view's, so the box shrinks on the photograph.
    const at1 = normalise(capture.rect, { x: 0, y: 0, width: 1000, height: 500 }, 1)
    const at08 = normalise(capture.rect, { x: 0, y: 0, width: 1000, height: 500 }, 0.8)
    expect(at1).toEqual({ x: 0.08, y: 0.46, width: 0.18, height: 0.104 })
    expect(at08?.x).toBeCloseTo(0.064)
    expect(at08?.width).toBeCloseTo(0.144)
  })

  it('never reaches past the picture’s edge', () => {
    const wide = normalise({ x: 900, y: 0, width: 400, height: 50 }, { x: 0, y: 0, width: 1000, height: 500 }, 1)
    expect((wide?.x ?? 0) + (wide?.width ?? 0)).toBeLessThanOrEqual(1)
  })

  it('names it by tag, text, id and selector', () => {
    expect(elementFromCapture(capture)).toEqual({ role: '<button>', name: 'Order now', identifier: 'order', selector: '#order' })
  })
})

describe('the device page’s words', () => {
  const base: DeviceEntry = {
    id: 'ios:1',
    platform: 'ios',
    kind: 'simulator',
    state: 'ready',
    available: true,
    name: 'iPhone 17 Pro',
    runtime: 'iOS 27.0',
    canBoot: false,
    canShutDown: true,
    buttons: [],
    keys: [],
    text: 'unicode',
    canRotate: true,
    note: '',
  }

  it('does not say iOS twice, nor say Running under the Running heading', () => {
    expect(subLine(base)).toBe('Simulator · iOS 27.0')
    expect(subLine({ ...base, platform: 'android', kind: 'emulator', runtime: '', available: false, canBoot: true, state: 'shutdown' })).toBe(
      'Android emulator',
    )
  })

  it('says what an unauthorised phone is waiting for', () => {
    const phone = { ...base, platform: 'android' as const, kind: 'physical' as const, state: 'unauthorized' as const, available: false, canBoot: false, runtime: '', note: 'Unlock the phone.' }
    expect(subLine(phone)).toBe('Android phone · Unlock the phone.')
    expect(stateLine({ ...phone, note: '' })).toBe('Waiting for permission on the phone')
    expect(kindWords(phone)).toBe('Android phone')
  })

  it('groups running, then off, then the rest', () => {
    const groups = groupDevices([
      { ...base, id: 'a', available: false, canBoot: true },
      { ...base, id: 'b' },
      { ...base, id: 'c', available: false, canBoot: false },
    ])
    expect(groups.map((g) => [g.title, g.rows.map((r) => r.id)])).toEqual([
      ['Running', ['b']],
      ['Off', ['a']],
      ['Not available', ['c']],
    ])
  })

  it('has no bridge when the preload lacks a method, rather than a half one', () => {
    expect(resolveDevicesBridge({ deviceList: () => null })).toBeNull()
    expect(resolveDevicesBridge(null)).toBeNull()
  })

  it('records a tree node as an element, without repeating a name as an id', () => {
    expect(elementOf({ ref: 'x', role: 'AXButton', label: 'General', identifier: 'com.apple.settings.general' })).toEqual({
      role: 'button',
      name: 'General',
      identifier: 'com.apple.settings.general',
    })
    expect(elementOf({ ref: 'y', role: 'AXButton', identifier: 'save' })).toEqual({ role: 'button', identifier: 'save' })
  })

  it('sends a screenshot as one line naming the device, not a browser', () => {
    const line = composeDeviceShot({ path: '/p/x.png', width: 1206, height: 2622 }, 'iOS Simulator', 'iPhone\n17', 'Look', '/far/x.png')
    expect(line).toBe('Look [iOS Simulator screenshot of "iPhone 17": /far/x.png (1206 x 2622)]')
  })
})
