import { describe, expect, it, vi } from 'vitest'

/**
 * The parts of the driver a test can hold still.
 *
 * The actionability loop, the input dispatch and the isolated-world reads are
 * all facts about Chromium, and they are exercised against real websites by
 * `scripts/check-browser-drive.mjs`. What is here is the arithmetic that
 * decides whether a password is still legible in a PNG — which is exactly the
 * kind of defect nobody notices by looking, and exactly the kind a sentinel
 * value catches.
 *
 * `electron` is stubbed rather than imported: this module is main-process code
 * and the two functions under test never touch the runtime.
 */
vi.mock('electron', () => ({
  app: { getPath: () => '/tmp/deck-test' },
  nativeImage: { createFromBitmap: () => ({ toPNG: () => Buffer.alloc(0) }) },
}))

const { BrowserDrive, bitmapShape, boundKey, describeStep, paintMasks } = await import(
  './browser-driver'
)

/** BGRA. A colour nothing else in the buffer uses, so finding it means the mask missed. */
const SENTINEL_BLUE = 0xff
const SENTINEL_GREEN = 0x00
const SENTINEL_RED = 0xee

function canvas(width: number, height: number, scale: number): Buffer {
  return Buffer.alloc(width * scale * height * scale * 4, 0x11)
}

function paintSentinel(
  bitmap: Buffer,
  pixelWidth: number,
  rect: { x: number; y: number; width: number; height: number },
  scale: number,
): void {
  for (let y = rect.y * scale; y < (rect.y + rect.height) * scale; y++) {
    for (let x = rect.x * scale; x < (rect.x + rect.width) * scale; x++) {
      const at = (y * pixelWidth + x) * 4
      bitmap[at] = SENTINEL_BLUE
      bitmap[at + 1] = SENTINEL_GREEN
      bitmap[at + 2] = SENTINEL_RED
      bitmap[at + 3] = 0xff
    }
  }
}

describe('a password is painted out before the file exists', () => {
  it('covers every pixel of the field, at a retina scale factor', () => {
    /*
     * The scale factor is where this goes wrong quietly. The rectangles arrive
     * in CSS pixels from the page and the buffer is in device pixels, so a
     * driver that forgot the ratio would paint a grey square over the top-left
     * quarter of the field on a Retina display and leave the rest of the
     * password perfectly readable — in a picture that *looks* redacted.
     */
    const scale = 2
    const size = { width: 200, height: 100 }
    const pixelWidth = size.width * scale
    const bitmap = canvas(size.width, size.height, scale)
    const field = { x: 20, y: 30, width: 120, height: 24 }
    paintSentinel(bitmap, pixelWidth, field, scale)

    /*
     * The viewport is 200 CSS pixels wide and the image is 400 device pixels
     * wide, so a device pixel is half a CSS pixel. Deriving that from the
     * buffer's own length instead — which is what this did first — answers 1,
     * because `getSize()` and the buffer are both device measurements. The
     * mask then landed at half the offset and half the size: a grey bar above
     * the form and a legible password box below it, in a picture that looked
     * redacted. Caught by looking at the picture.
     */
    const viewport = { width: size.width, height: size.height }
    const shape = bitmapShape({ width: pixelWidth, height: 200 }, bitmap.length, viewport)
    expect(shape).toEqual({ pixelWidth: 400, pixelHeight: 200, scale: 2, viewport })
    const painted = paintMasks(bitmap, shape!, [field])
    expect(painted).toBe(1)

    let survivors = 0
    for (let i = 0; i < bitmap.length; i += 4) {
      if (bitmap[i] === SENTINEL_BLUE && bitmap[i + 2] === SENTINEL_RED) survivors++
    }
    expect(survivors).toBe(0)
  })

  it('paints the whole field even when its box lands between device pixels', () => {
    // Sub-pixel geometry is the ordinary case, not the edge case: a field at a
    // fractional offset is what a CSS layout produces. Rounding inward here
    // would leave a one-pixel band of the password along an edge.
    const scale = 2
    const size = { width: 100, height: 50 }
    const bitmap = canvas(size.width, size.height, scale)
    const shape = bitmapShape({ width: size.width * scale, height: size.height * scale }, bitmap.length, size)!
    const painted = paintMasks(bitmap, shape, [{ x: 10.4, y: 5.6, width: 30.3, height: 12.7 }])
    expect(painted).toBe(1)
    // The mask must start no later than floor(10.4*2)=20 and end no earlier
    // than ceil((10.4+30.3)*2)=82.
    const row = 12 * shape.pixelWidth * 4
    expect(bitmap[row + 20 * 4]).toBe(0x80)
    expect(bitmap[row + 81 * 4]).toBe(0x80)
  })

  it('does not paint a rectangle that is entirely off the page', () => {
    const size = { width: 100, height: 50 }
    const bitmap = canvas(size.width, size.height, 1)
    const shape = bitmapShape(size, bitmap.length, size)!
    expect(paintMasks(bitmap, shape, [{ x: 500, y: 500, width: 10, height: 10 }])).toBe(0)
    expect(paintMasks(bitmap, shape, [{ x: 0, y: 0, width: 0, height: 0 }])).toBe(0)
  })

  it('refuses the whole picture when the buffer is not the shape it expected', () => {
    /*
     * Returning the unmasked image is the single outcome this path exists to
     * prevent, so an arithmetic surprise throws rather than degrading. A
     * screenshot that never appears is a bug report; one that appears with the
     * password in it is not noticed at all.
     */
    expect(() =>
      bitmapShape({ width: 100, height: 50 }, 100 * 50 * 4 + 17, { width: 100, height: 50 }),
    ).toThrow(/could not be masked/)
  })

  it('answers null for an image with no pixels rather than pretending', () => {
    expect(bitmapShape({ width: 0, height: 0 }, 0, { width: 100, height: 50 })).toBeNull()
  })

  it('refuses the picture when the page could not say how wide its viewport is', () => {
    // A default of 1 would be right on some machines and would mis-place every
    // mask on a Retina display, silently. Refusing is the only honest answer.
    expect(() => bitmapShape({ width: 100, height: 50 }, 100 * 50 * 4, { width: 0, height: 0 })).toThrow(
      /could not be masked/,
    )
  })

  it('refuses a scale that could not be real', () => {
    // A viewport reported mid-resize, or a number somebody made up. Sixteen
    // device pixels to a CSS pixel is not a display, it is a mistake.
    expect(() => bitmapShape({ width: 1600, height: 800 }, 1600 * 800 * 4, { width: 100, height: 50 })).toThrow(
      /could not be masked/,
    )
  })
})

describe('what the person sees the drive doing', () => {
  it('names the element the way it is labelled on screen', () => {
    // The only feedback a driven click has: CDP input does not move the OS
    // pointer, and nothing HTML can be drawn over a WebContentsView, so there
    // is no cursor to watch.
    expect(describeStep('click', 'Sign in', '#go')).toBe('clicking “Sign in”')
    expect(describeStep('type', 'Email', 'input#email')).toBe('typing into “Email”')
    expect(describeStep('submit', '', 'form#login')).toBe('submitting form#login')
  })

  it('falls back to the selector when the element has no name', () => {
    expect(describeStep('click', '   ', 'button.icon')).toBe('clicking button.icon')
  })
})

/**
 * Disconnect, from the driver's end.
 *
 *   > *"we should be have a button here to disconnect also, or it should only
 *   > this way."*
 *
 * "Only this way" is what these pin. The relation and the drive are two objects
 * in two modules, and the control is meant to be one act: `browser-binding-ipc`
 * ends the binding and calls in here with the shell tab id, which is the only
 * handle it has. So the key that files a window's slot has to be one spelling
 * and it has to be reachable from a shell tab id alone.
 */
describe('letting go of a window the person disconnected', () => {
  /** Enough `DriveHost` to hold a slot. Nothing here opens or steers a page. */
  const host = {
    openTab: async () => null,
    contentsFor: () => null,
    publish: () => undefined,
    now: () => 1_000,
  }

  const target = (browserTabId: string) => ({
    key: boundKey(browserTabId),
    viewId: `view:${browserTabId}`,
    browserTabId,
    name: 'B1',
  })

  it('files a window under one key, spelled in one place', () => {
    // `browser-tools.ts` mints its targets with this, and `releaseWindow` looks
    // them up with it. Two copies is a drive that keeps running under a key
    // nobody matched.
    expect(boundKey('browser:1:1')).toBe('bound:browser:1:1')
  })

  it('forgets what that window had been granted', () => {
    const drive = new BrowserDrive(host)
    const window = target('browser:1:1')
    drive.noteOriginGranted('https://app.example.com', window)
    expect(drive.originGranted('https://app.example.com', window)).toBe(true)

    drive.releaseWindow('browser:1:1')

    // A window that is nobody's carries nobody's permission. Reconnecting it
    // asks again, which is the point of the control being the truth.
    expect(drive.originGranted('https://app.example.com', window)).toBe(false)
    expect(drive.driving()).toEqual([])
  })

  it('leaves every other window alone', () => {
    const drive = new BrowserDrive(host)
    drive.noteOriginGranted('https://a.example.com', target('browser:1:1'))
    drive.noteOriginGranted('https://b.example.com', target('browser:1:2'))

    drive.releaseWindow('browser:1:1')

    expect(drive.originGranted('https://b.example.com', target('browser:1:2'))).toBe(true)
  })

  it('says nothing about a window it was never holding', () => {
    // The ordinary case: disconnecting a window no agent has ever driven.
    const drive = new BrowserDrive(host)
    expect(() => drive.releaseWindow('browser:9:9')).not.toThrow()
  })
})
