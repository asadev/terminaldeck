import { describe, expect, it } from 'vitest'
import {
  DEVICE_PRESETS,
  fitInto,
  MAX_DIMENSION,
  MIN_DIMENSION,
  parseDimension,
  presetById,
  sizeFor,
  stepZoom,
  ZOOM_STEPS,
} from './devices'

const container = { x: 100, y: 50, width: 1000, height: 700 }

describe('fitInto', () => {
  it('fills the space when no device is chosen', () => {
    const fit = fitInto(container, null)
    expect(fit.rect).toEqual(container)
    expect(fit.clamped).toBe(false)
  })

  it('centres a device horizontally and pins it to the top', () => {
    // Vertically centring hides the header, which is the part being checked.
    const fit = fitInto(container, { width: 390, height: 600 })
    expect(fit.rect).toEqual({ x: 405, y: 50, width: 390, height: 600 })
    expect(fit.clamped).toBe(false)
  })

  it('clamps a device bigger than the panel and admits it', () => {
    // A native view cannot overflow with a scrollbar — it would paint over the
    // rest of the app — and a bar claiming 1440 while showing 1000 is a lie the
    // layout under test gets built on.
    const fit = fitInto(container, { width: 1440, height: 900 })
    expect(fit.applied).toEqual({ width: 1000, height: 700 })
    expect(fit.rect.x).toBe(100)
    expect(fit.clamped).toBe(true)
  })

  it('clamps on one axis only when that is all that overflows', () => {
    const fit = fitInto(container, { width: 390, height: 844 })
    expect(fit.applied).toEqual({ width: 390, height: 700 })
    expect(fit.clamped).toBe(true)
  })
})

describe('sizeFor', () => {
  it('rotates by swapping the numbers, and copies rather than aliases', () => {
    const portrait = { width: 390, height: 844 }
    expect(sizeFor(portrait, 'landscape')).toEqual({ width: 844, height: 390 })
    expect(sizeFor(portrait, 'portrait')).toEqual(portrait)
    expect(sizeFor(portrait, 'portrait')).not.toBe(portrait)
  })
})

describe('presets', () => {
  it('are unique and portrait-shaped', () => {
    const ids = DEVICE_PRESETS.map((preset) => preset.id)
    expect(new Set(ids).size).toBe(ids.length)
    for (const preset of DEVICE_PRESETS) {
      if (preset.group === 'desktop') continue
      expect(preset.height).toBeGreaterThan(preset.width)
    }
  })

  it('looks up by id and says so when there is none', () => {
    expect(presetById('phone')?.width).toBe(390)
    expect(presetById('fit')).toBeNull()
  })
})

describe('parseDimension', () => {
  it('takes a plain number inside a usable range', () => {
    expect(parseDimension('390')).toBe(390)
    expect(parseDimension('  1280 ')).toBe(1280)
    expect(parseDimension(String(MIN_DIMENSION))).toBe(MIN_DIMENSION)
    expect(parseDimension(String(MAX_DIMENSION))).toBe(MAX_DIMENSION)
  })

  it('refuses everything else rather than half-applying it', () => {
    expect(parseDimension('')).toBeNull()
    expect(parseDimension('39')).toBeNull()
    expect(parseDimension('99999')).toBeNull()
    expect(parseDimension('390px')).toBeNull()
    expect(parseDimension('-390')).toBeNull()
    expect(parseDimension('39.5')).toBeNull()
  })
})

describe('stepZoom', () => {
  it('walks the steps', () => {
    expect(stepZoom(1, 1)).toBe(1.1)
    expect(stepZoom(1, -1)).toBe(0.9)
  })

  it('stops at both ends instead of wrapping', () => {
    expect(stepZoom(ZOOM_STEPS[0], -1)).toBe(ZOOM_STEPS[0])
    expect(stepZoom(ZOOM_STEPS[ZOOM_STEPS.length - 1], 1)).toBe(ZOOM_STEPS[ZOOM_STEPS.length - 1])
  })

  it('starts from the nearest step when zoom came back from a previous session', () => {
    // Chromium persists zoom per origin in the partition, so the first press of
    // the button often starts from a value that is not one of these steps.
    expect(stepZoom(1.03, 1)).toBe(1.1)
    expect(stepZoom(1.03, -1)).toBe(0.9)
  })
})
