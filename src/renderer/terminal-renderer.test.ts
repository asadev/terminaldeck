import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  FORCE_DOM_SETTING,
  MOST_ACCELERATED,
  RendererPool,
  SOFTWARE_RENDERERS,
  forcedToDom,
  gpuCanvasOf,
  isSoftwareRenderer,
  readAcceleration,
  releaseSeatContext,
  rendererSeat,
  seatsToAccelerate,
  type Acceleration,
  type ProbeCanvas,
  type ProbeContext,
  type RendererAddon,
  type SeatCanvas,
} from './terminal-renderer'

/**
 * Which terminals get a GPU context, and — the half that matters — what happens
 * to the ones that lose it.
 *
 * Every one of these is a rule from the review, and the rule is quoted on the
 * describe block so a failure says which promise broke rather than which
 * function returned the wrong number. The bar was:
 *
 *   > *"I need reliability for everyone."*
 *
 * so: faster where it genuinely works, unchanged where it does not, and never a
 * broken terminal.
 *
 * There is no DOM here — this project's test setup has none, deliberately — so
 * the terminal, the addon and the GPU are all fakes. That is not a weaker test
 * than a browser one would be: what is being asserted is the *policy*, and the
 * rendering itself was measured with playwright instead, which is written up in
 * the module's own header with the numbers.
 */

beforeEach(() => {
  losses = 0
})

/* --------------------------------------------------------------- fakes -- */

/**
 * An addon that records what was done to it, and can be told to misbehave.
 *
 * `order` is the point of the `releaseContext` half: the two calls have to
 * happen in one order and only one, and the reason is measured rather than
 * stylistic — disposal takes the addon's own `webglcontextlost` listener off the
 * canvas, so losing the context first would hand a live addon a real context
 * loss and freeze the terminal for three seconds on every ordinary tab switch.
 */
function fakeAddon(
  options: { releases?: boolean | (() => boolean) } = {},
): RendererAddon & {
  disposed: number
  released: number
  order: string[]
  lossHandlers: (() => void)[]
  lossDisposed: number
} {
  const state = {
    disposed: 0,
    released: 0,
    order: [] as string[],
    lossHandlers: [] as (() => void)[],
    lossDisposed: 0,
  }
  const releases = options.releases ?? true
  return {
    ...state,
    onContextLoss(handler: () => void) {
      this.lossHandlers.push(handler)
      return {
        dispose: () => {
          this.lossDisposed += 1
        },
      }
    },
    dispose() {
      this.disposed += 1
      this.order.push('dispose')
    },
    releaseContext() {
      this.released += 1
      this.order.push('release')
      return typeof releases === 'function' ? releases() : releases
    },
  }
}

const yes: Acceleration = { ok: true, how: 'a fake GPU' }
const no: Acceleration = { ok: false, why: 'a fake software rasteriser' }

/** A pool whose seats hand back fakes, so the whole policy runs with no DOM. */
function pool(
  options: { cap?: number; measure?: () => Acceleration; releases?: boolean | (() => boolean) } = {},
) {
  const notes: string[] = []
  const made: ReturnType<typeof fakeAddon>[] = []
  const p = new RendererPool({
    cap: options.cap,
    measure: options.measure ?? (() => yes),
    note: (message) => notes.push(message),
  })
  const join = () => {
    const handle = p.join(() => {
      const addon = fakeAddon({ releases: options.releases })
      made.push(addon)
      return addon
    })
    return handle
  }
  return { pool: p, join, made, notes }
}

/* ------------------------------------------------- rule 1: the software -- */

describe('rule 1: it refuses a software renderer, which is slower than doing nothing', () => {
  /**
   * The measurement this rule exists for, repeated here because a number in a
   * comment is the only thing that keeps a rule from being "tidied away":
   * Chrome on this Mac, one 197x47 terminal, scrolling. DOM renderer 8.3 ms a
   * frame with nothing late. The same terminal with WebGL on SwiftShader:
   * **107.1 ms a frame, 398 of 399 frames late.** Twelve times worse than not
   * using the GPU at all.
   */
  it('takes Chromium’s own answer first: no context without the caveat flag', () => {
    const asked: unknown[] = []
    const canvas: ProbeCanvas = {
      getContext(kind, attributes) {
        asked.push({ kind, attributes })
        return null
      },
    }
    const answer = readAcceleration(canvas)
    expect(answer.ok).toBe(false)
    // The flag is the whole of the first signal: without it Chromium hands back
    // a SwiftShader context and xterm paints a terminal on the CPU.
    expect(asked).toEqual([
      {
        kind: 'webgl2',
        attributes: { failIfMajorPerformanceCaveat: true, antialias: false, depth: false },
      },
    ])
  })

  it('refuses a driver that names itself, even when the flag let it through', () => {
    // The blind spot in signal one: a real driver that is merely terrible is
    // not a "caveat" to Chromium, and a remoted or basic display adapter is
    // exactly that. This is the string SwiftShader actually produced on this
    // Mac, quoted rather than invented.
    const answer = readAcceleration(
      gpu('ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (LLVM 10.0.0) (0x0000C0DE)), SwiftShader driver)'),
    )
    expect(answer.ok).toBe(false)
    expect(answer.ok === false && answer.why).toContain('SwiftShader')
  })

  it('keeps a real GPU', () => {
    // Likewise measured, on the machine this was written on.
    const answer = readAcceleration(
      gpu('ANGLE (Apple, ANGLE Metal Renderer: Apple M1 Pro, Unspecified Version)'),
    )
    expect(answer.ok).toBe(true)
    expect(answer.ok === true && answer.how).toContain('Apple M1 Pro')
  })

  it('gives the probe’s own context straight back', () => {
    // A context nobody releases counts against the cap rule 2 is about for as
    // long as the window is open. This is the difference between the probe
    // costing nothing and the probe costing a terminal.
    //
    // This asserted only that the extension was *asked for* until 2026-08-19,
    // and that is why it was the weakest test in the file: the fake's
    // `loseContext` was a no-op nobody recorded, so deleting the actual call
    // from `release()` left it green. It counts the call now, and the fake
    // counts it — which is the same pin section 2b needs for a seat.
    const asked: string[] = []
    const canvas = gpu('Apple M1 Pro', (name) => asked.push(name))
    readAcceleration(canvas)
    expect(asked).toContain('WEBGL_lose_context')
    expect(losses).toBe(1)
  })

  it('treats a GPU it has never heard of as hardware', () => {
    // The list is a veto on names known to be CPU rasterisers, not an
    // allow-list. A new GPU must not become a slow terminal because nobody has
    // added its name yet.
    expect(readAcceleration(gpu('ANGLE (Some Vendor, Whatever 9000, Vulkan)')).ok).toBe(true)
  })

  it('survives a window with no canvas at all, and says why', () => {
    const answer = readAcceleration(null)
    expect(answer.ok).toBe(false)
    expect(answer.ok === false && answer.why).toMatch(/canvas/)
  })

  it('names the rasterisers that matter on the machines this ships to', () => {
    // Windows over RDP is the common one, and it reports the Microsoft Basic
    // Render Driver — which is not SwiftShader and would sail past a check that
    // only knew Chromium's own fallback.
    for (const needle of ['swiftshader', 'llvmpipe', 'microsoft basic render', 'warp']) {
      expect(SOFTWARE_RENDERERS).toContain(needle)
    }
    expect(isSoftwareRenderer('ANGLE (Microsoft, Microsoft Basic Render Driver Direct3D11)')).toBe(true)
    expect(isSoftwareRenderer('Mesa/X.org, llvmpipe (LLVM 15.0.7, 256 bits)')).toBe(true)
    expect(isSoftwareRenderer('NVIDIA GeForce RTX 4090/PCIe/SSE2')).toBe(false)
  })

  it('never hands out a context when the answer is no, and says so once', () => {
    const { join, made, notes } = pool({ measure: () => no })
    const seat = join()
    seat.setVisible(true)
    expect(made).toHaveLength(0)
    expect(seat.accelerated()).toBe(false)
    // The line is the diagnostics: somebody reporting a slow terminal has to be
    // able to find out that the app decided their GPU was software.
    expect(notes.join(' ')).toContain('software')
  })

  it('asks the GPU once, not once per terminal', () => {
    // Twelve sessions in a window is ordinary. Twelve probes, each creating and
    // destroying a context, is not.
    const measure = vi.fn(() => yes)
    const { join } = pool({ measure })
    for (let i = 0; i < 5; i += 1) join().setVisible(true)
    expect(measure).toHaveBeenCalledTimes(1)
  })

  it('does not touch the GPU at all until a terminal is actually on screen', () => {
    const measure = vi.fn(() => yes)
    const { join } = pool({ measure })
    join()
    join()
    expect(measure).not.toHaveBeenCalled()
  })
})

/* ------------------------------------------------------ rule 2: the cap -- */

describe('rule 2: it bounds the contexts, because Chromium evicts the oldest', () => {
  /**
   * Measured rather than assumed: building terminals in one page until Chromium
   * complained printed
   *
   *     WARNING: Too many active WebGL contexts. Oldest context will be lost.
   *
   * five times with twenty-one contexts alive — the seventeenth onwards. The
   * ceiling is sixteen per page, and crossing it does not refuse the new
   * context, it takes the *oldest* one away: the terminal somebody has had open
   * longest is the one that dies.
   */
  it('leaves room: the cap is a fraction of the sixteen Chromium allows', () => {
    expect(MOST_ACCELERATED).toBeLessThanOrEqual(8)
    expect(MOST_ACCELERATED).toBeGreaterThan(1)
  })

  it('gives contexts to the terminals on screen and to no others', () => {
    const { join } = pool({ cap: 4 })
    const shown = [join(), join()]
    const hidden = [join(), join()]
    for (const seat of shown) seat.setVisible(true)
    expect(shown.every((seat) => seat.accelerated())).toBe(true)
    expect(hidden.some((seat) => seat.accelerated())).toBe(false)
  })

  it('never exceeds the cap, however many terminals are on screen', () => {
    // The swarm grid draws a cell for every session in a project with no upper
    // bound at all, and every one of them is genuinely visible.
    const { join } = pool({ cap: 4 })
    const seats = Array.from({ length: 12 }, () => join())
    for (const seat of seats) seat.setVisible(true)
    expect(seats.filter((seat) => seat.accelerated())).toHaveLength(4)
  })

  it('swaps on focus: the terminal being used takes the context', () => {
    const { join } = pool({ cap: 1 })
    const first = join()
    const second = join()
    first.setVisible(true)
    second.setVisible(true)
    expect(first.accelerated()).toBe(false)
    expect(second.accelerated()).toBe(true)

    first.touch()
    expect(first.accelerated()).toBe(true)
    expect(second.accelerated()).toBe(false)
  })

  it('takes the context back when a terminal leaves the screen', () => {
    const { join } = pool({ cap: 4 })
    const seat = join()
    seat.setVisible(true)
    expect(seat.accelerated()).toBe(true)
    seat.setVisible(false)
    expect(seat.accelerated()).toBe(false)
  })

  it('hands a freed context to a terminal that was waiting for one', () => {
    const { join } = pool({ cap: 1 })
    const first = join()
    first.setVisible(true)
    const second = join()
    second.setVisible(true)
    // The one that arrived most recently holds the only context.
    expect(second.accelerated()).toBe(true)
    first.touch()
    expect(first.accelerated()).toBe(true)

    // Closing the tab that held it must not leave the window drawing everything
    // on the DOM renderer with a context spare.
    first.leave()
    expect(second.accelerated()).toBe(true)
  })

  it('settles on a stable set rather than churning contexts', () => {
    // Ties broken by creation order, so a window full of terminals nobody has
    // focused does not swap renderers every time anything re-renders.
    const seats = [
      { id: 3, visible: true, touched: 0 },
      { id: 1, visible: true, touched: 0 },
      { id: 2, visible: true, touched: 0 },
    ]
    expect(seatsToAccelerate(seats, 2)).toEqual([1, 2])
    expect(seatsToAccelerate(seats, 2)).toEqual(seatsToAccelerate(seats, 2))
  })

  it('gives a terminal arriving on screen a place in the order', () => {
    // Otherwise a session opened into a full window draws on the DOM renderer
    // until somebody thinks to click it.
    const { join } = pool({ cap: 1 })
    const old = join()
    old.setVisible(true)
    const fresh = join()
    fresh.setVisible(true)
    expect(fresh.accelerated()).toBe(true)
    expect(old.accelerated()).toBe(false)
  })
})

/* ------------------------------------ rule 2, second half: the give-back -- */

describe('rule 2, second half: a seat that gives up its renderer gives up its context', () => {
  /**
   * The defect this block exists for, and it was live in a shipped design for
   * one review cycle. `MOST_ACCELERATED = 4` was documented as meaning "this app
   * can never be the reason a context is evicted". It could not mean that: the
   * cap bounds seats holding an addon, Chromium counts live contexts, and
   * `@xterm/addon-webgl@0.19.0` disposes by removing its canvas from the DOM
   * (`WebglRenderer.ts:144-150`) without ever calling `WEBGL_lose_context`.
   *
   * Measured in Chrome 151 on this Mac, driving the real module through
   * playwright, three runs of each: forty terminals opened and closed left
   * **16, 11 and 7 contexts alive with nothing on screen at all**, against a cap
   * of four; six panes with focus moving between them held 12, 16 and 12 and
   * printed 39, 36 and 39 "Too many active WebGL contexts" warnings in 80 swaps
   * — which is Chromium taking a renderer away from a terminal somebody is
   * using, and one baseline run carried four such losses. After the release
   * below, three runs of each: **0, 0, 0** held with nothing on screen, **4, 4,
   * 4** with six panes up, and no warnings at all.
   *
   * What was missing was not the mechanism — `release()` had been in this file
   * from the first commit, for the probe — but a test that a *seat's* context is
   * released. The one that should have caught it asserted only that the
   * extension was asked for. So these assert the call, the order, and what
   * happens when it fails.
   */
  it('releases the context when it takes a renderer away, and only after disposing it', () => {
    const { join, made } = pool({ cap: 4 })
    const seat = join()
    seat.setVisible(true)
    seat.setVisible(false)
    expect(made[0]?.released).toBe(1)
    // The order is measured, not tidiness: disposal takes the addon's own
    // `webglcontextlost` listener off the canvas, so losing the context
    // afterwards fires an event nobody hears. The other way round hands a live
    // addon a genuine context loss, which freezes the terminal for three seconds
    // and then trips rule 3 — from an ordinary tab switch.
    expect(made[0]?.order).toEqual(['dispose', 'release'])
  })

  it('releases on every path that takes a context back, not just the tidy one', () => {
    // Four ways a seat loses its renderer, and a context left behind by any of
    // them counts exactly the same at Chromium's table.
    const swap = pool({ cap: 1 })
    const first = swap.join()
    first.setVisible(true)
    const second = swap.join()
    second.setVisible(true) // pushed out by a newer terminal
    expect(swap.made[0]?.released).toBe(1)

    const closing = pool({ cap: 4 })
    const going = closing.join()
    going.setVisible(true)
    going.leave() // the tab was closed
    expect(closing.made[0]?.released).toBe(1)

    const forced = pool({ cap: 4 })
    const held = forced.join()
    held.setVisible(true)
    forced.pool.forceDom(true) // the escape hatch
    expect(forced.made[0]?.released).toBe(1)

    const lost = pool({ cap: 4 })
    const dying = lost.join()
    dying.setVisible(true)
    lost.made[0]?.lossHandlers.forEach((fire) => fire()) // rule 3
    expect(lost.made[0]?.released).toBe(1)
  })

  it('stops the whole window when a context will not come back', () => {
    // Carrying on is what makes the cap a lie: the next swap leaks another, and
    // the end of that is Chromium evicting the terminal somebody has had open
    // longest. The window finishes on the DOM renderer instead, and says so.
    const { join, notes } = pool({ cap: 1, releases: false })
    const first = join()
    first.setVisible(true)
    const second = join()
    second.setVisible(true)

    expect(first.accelerated()).toBe(false)
    expect(second.accelerated()).toBe(false)
    expect(notes.join(' ')).toContain('could not be given back')

    // And it does not start again on the next terminal, exactly as a context
    // loss does not.
    const third = join()
    third.setVisible(true)
    expect(third.accelerated()).toBe(false)
  })

  it('treats a release that throws as a release that did not happen', () => {
    const { join, notes } = pool({
      cap: 4,
      releases: () => {
        throw new Error('the canvas is gone')
      },
    })
    const seat = join()
    seat.setVisible(true)
    seat.setVisible(false)
    expect(notes.join(' ')).toContain('the canvas is gone')
    expect(notes.join(' ')).toContain('could not be given back')
    seat.setVisible(true)
    expect(seat.accelerated()).toBe(false)
  })

  it('holds no more contexts than the cap, over a hundred focus swaps', () => {
    // The shape the browser measurement found the leak in: more terminals on
    // screen than the cap, focus moving between them. What that measured was
    // Chromium's own count; what this measures is that this module's books
    // balance — every addon it ever made is either alive in a seat or released.
    const { join, made } = pool({ cap: 4 })
    const seats = Array.from({ length: 6 }, () => join())
    for (const seat of seats) seat.setVisible(true)
    for (let step = 0; step < 100; step += 1) seats[step % seats.length]?.touch()

    const live = made.filter((addon) => addon.disposed === 0)
    expect(live).toHaveLength(4)
    expect(seats.filter((seat) => seat.accelerated())).toHaveLength(4)
    for (const addon of made) {
      if (addon.disposed > 0) expect(addon.released).toBe(1)
    }
  })

  /* ------------------------------------------------- and the mechanism -- */

  it('picks the renderer’s canvas out of the three that loading it adds', () => {
    // Measured in Chrome, and quoted here because the whole mechanism rests on
    // it: the link layer carries a class, the atlas page hangs off `.terminal`
    // rather than the screen, and the renderer's own has neither.
    const existing = canvas('', 'terminal') // was already there
    const link = canvas('xterm-link-layer', 'xterm-screen')
    const renderer = canvas('', 'xterm-screen')
    const atlas = canvas('', 'terminal')
    expect(gpuCanvasOf(new Set([existing]), [existing, link, renderer, atlas])).toBe(renderer)
  })

  it('answers “I do not know” rather than guessing, when it is not exactly one', () => {
    // The caller turns a `null` into "stop accelerating this window", which is
    // the right answer to not knowing which context is ours — releasing one that
    // might be somebody else's is worse than the leak.
    const link = canvas('xterm-link-layer', 'xterm-screen')
    expect(gpuCanvasOf(new Set<SeatCanvas>(), [link])).toBe(null)
    const two = [canvas('', 'xterm-screen'), canvas('', 'xterm-screen')]
    expect(gpuCanvasOf(new Set<SeatCanvas>(), two)).toBe(null)
    // And a canvas that was there before this load is not this load's.
    const old = canvas('', 'xterm-screen')
    expect(gpuCanvasOf(new Set([old]), [old])).toBe(null)
  })

  it('loses the context on the canvas it was given, and says whether it went', () => {
    const live = canvas('', 'xterm-screen', glContext('Apple M1 Pro'))
    expect(releaseSeatContext(live)).toBe(true)
    expect(losses).toBe(1)
  })

  it('wires the seat the pool is handed to the canvas the addon just made', () => {
    // The seam the defect was actually in. Everything either side of it had a
    // test: the policy did, and so did `gpuCanvasOf` and `releaseSeatContext`.
    // What `attachRenderer` did with them did not, and it was handing the pool
    // an addon whose disposal released nothing at all.
    const screen = [canvas('', 'terminal')] // the measure canvas, already there
    const addon = fakeAddon()
    const seat = rendererSeat(
      () => screen,
      () => {
        // What loading the real addon does, in the order it does it.
        screen.push(canvas('xterm-link-layer', 'xterm-screen'))
        screen.push(canvas('', 'xterm-screen', glContext('Apple M1 Pro')))
        screen.push(canvas('', 'terminal')) // the atlas page
        return addon
      },
    )

    seat.dispose()
    expect(seat.releaseContext()).toBe(true)
    expect(losses).toBe(1)
    // And the addon underneath is still the one the pool talks to.
    expect(addon.disposed).toBe(1)
    const stop = seat.onContextLoss(() => {})
    expect(addon.lossHandlers).toHaveLength(1)
    stop.dispose()
    expect(addon.lossDisposed).toBe(1)
  })

  it('says it could not release when loading the addon named no canvas', () => {
    // A future version of the addon that stops appending its canvas to
    // `.xterm-screen` lands here, and the answer has to be "stop" rather than a
    // silent leak — which is what the pool does with a `false`.
    const seat = rendererSeat(
      () => [],
      () => fakeAddon(),
    )
    seat.dispose()
    expect(seat.releaseContext()).toBe(false)
    expect(losses).toBe(0)
  })

  it('reports a failure rather than a success when there is nothing to release', () => {
    // Each of these is a context still alive somewhere this code cannot reach,
    // which is precisely what the pool must not treat as success.
    expect(releaseSeatContext(null)).toBe(false)
    expect(releaseSeatContext(canvas('', 'xterm-screen', null))).toBe(false)
    const noExtension: ProbeContext = { getExtension: () => null, getParameter: () => null }
    expect(releaseSeatContext(canvas('', 'xterm-screen', noExtension))).toBe(false)
    const throws: ProbeContext = {
      getExtension: () => {
        throw new Error('context is gone')
      },
      getParameter: () => null,
    }
    expect(releaseSeatContext(canvas('', 'xterm-screen', throws))).toBe(false)
    expect(losses).toBe(0)
  })
})

/* ----------------------------------------------------- rule 3: the loss -- */

describe('rule 3: a lost context falls back live, with the session unbroken', () => {
  /**
   * Verified in a browser as well as here, because the half this file cannot
   * see is the half that matters: with the context destroyed under a terminal
   * holding 400 lines, disposing the addon rebuilt all 47 DOM rows, left the
   * same 46 lines of text on screen, and bytes written afterwards painted
   * normally. Nothing was said to the pty at any point.
   *
   * Note what the browser also showed: `@xterm/addon-webgl@0.19.0` waits `3e3`
   * ms for a `webglcontextrestored` before it reports the loss at all, so the
   * terminal is frozen for three seconds before any of this runs. That is the
   * library's decision; what is ours is that it recovers rather than staying
   * dead.
   */
  it('disposes the addon that lost its context, which is what restores the DOM renderer', () => {
    const { join, made } = pool({ cap: 4 })
    const seat = join()
    seat.setVisible(true)
    const addon = made[0]
    expect(addon.disposed).toBe(0)

    addon.lossHandlers.forEach((fire) => fire())

    expect(addon.disposed).toBe(1)
    expect(seat.accelerated()).toBe(false)
  })

  it('stops the whole window, because the next context would die the same way', () => {
    const { join, made, notes } = pool({ cap: 4 })
    const first = join()
    const second = join()
    first.setVisible(true)
    second.setVisible(true)
    made[0].lossHandlers.forEach((fire) => fire())

    expect(second.accelerated()).toBe(false)
    // And a terminal opened afterwards does not start the cycle again.
    const third = join()
    third.setVisible(true)
    expect(third.accelerated()).toBe(false)
    expect(made).toHaveLength(2)
    expect(notes.join(' ')).toContain('lost')
  })

  it('gives up the window when the renderer cannot be built at all', () => {
    // `WebglAddon.activate` throws `WebGL2 not supported` when the context
    // cannot be created, and that is a fact about the window, not about this
    // terminal — so it must not be discovered once per terminal, forever.
    const notes: string[] = []
    const p = new RendererPool({
      measure: () => yes,
      note: (message) => notes.push(message),
    })
    let attempts = 0
    const make = () => {
      attempts += 1
      throw new Error('WebGL2 not supported null')
    }
    const first = p.join(make)
    const second = p.join(make)
    first.setVisible(true)
    second.setVisible(true)
    expect(attempts).toBe(1)
    expect(first.accelerated()).toBe(false)
    expect(second.accelerated()).toBe(false)
    expect(notes.join(' ')).toContain('WebGL2 not supported')
  })

  it('keeps the terminal when disposing a renderer throws', () => {
    // The failure mode to avoid is an exception on the way out of a swap
    // leaving a seat that believes it still holds a context it does not.
    const notes: string[] = []
    const p = new RendererPool({
      measure: () => yes,
      note: (message) => notes.push(message),
    })
    let released = 0
    const seat = p.join(() => ({
      onContextLoss: () => ({ dispose: () => {} }),
      dispose: () => {
        throw new Error('already gone')
      },
      releaseContext: () => {
        released += 1
        return true
      },
    }))
    seat.setVisible(true)
    expect(() => seat.setVisible(false)).not.toThrow()
    expect(seat.accelerated()).toBe(false)
    expect(notes.some((note) => note.includes('already gone'))).toBe(true)
    // And the context still goes back. A half-torn-down addon is the case where
    // a context is most likely to be left holding a seat at Chromium's table,
    // so it is the last case that should skip the release.
    expect(released).toBe(1)
  })

  it('lets go of the loss subscription when it takes a context back', () => {
    // A handler left registered on an addon that has been disposed is how one
    // stale event takes the renderer away from every terminal in the window.
    const { join, made } = pool({ cap: 4 })
    const seat = join()
    seat.setVisible(true)
    seat.setVisible(false)
    expect(made[0].lossDisposed).toBe(1)
  })
})

/* --------------------------------------------------- rule 4: the switch -- */

describe('rule 4: the escape hatch, for a driver nothing else catches', () => {
  it('is an Advanced setting, so the row that draws it needs no change here', () => {
    // The stored key *is* the setting id, so declaring a row with this id in
    // `settings-schema.ts` wires the toggle to this code with nothing else to
    // do. That row is owed; the key already works by hand.
    expect(FORCE_DOM_SETTING).toBe('advanced.forceDomRenderer')
  })

  it('reads both shapes the settings channel hands back', () => {
    expect(forcedToDom({ version: 1, values: { [FORCE_DOM_SETTING]: true } })).toBe(true)
    // The bare map, from a build that predates the envelope.
    expect(forcedToDom({ [FORCE_DOM_SETTING]: true })).toBe(true)
    expect(forcedToDom({ version: 1, values: {} })).toBe(false)
  })

  it('behaves normally when the settings file cannot be read', () => {
    // An unreadable settings file must not decide how the app renders.
    for (const raw of [null, undefined, 'true', 42, { values: null }]) {
      expect(forcedToDom(raw)).toBe(false)
    }
    // And only a real boolean counts: a string "true" out of a hand-edited file
    // is a mistake, not an instruction.
    expect(forcedToDom({ values: { [FORCE_DOM_SETTING]: 'true' } })).toBe(false)
  })

  it('takes every context back when it is turned on, live', () => {
    // It has to work on a window that is already running: the person turning it
    // on is looking at a terminal that is rendering wrongly right now.
    const { pool: p, join, made, notes } = pool({ cap: 4 })
    const seat = join()
    seat.setVisible(true)
    expect(seat.accelerated()).toBe(true)

    p.forceDom(true)
    expect(seat.accelerated()).toBe(false)
    expect(made[0].disposed).toBe(1)
    expect(notes.join(' ')).toContain('forced to the DOM renderer')
  })

  it('gives them back when it is turned off, unlike a context loss', () => {
    // The two are deliberately different: a loss is a symptom and does not
    // reverse, a setting is a decision and does.
    const { pool: p, join } = pool({ cap: 4 })
    const seat = join()
    seat.setVisible(true)
    p.forceDom(true)
    p.forceDom(false)
    expect(seat.accelerated()).toBe(true)
  })
})

/* --------------------------------------------------------------- helper -- */

/**
 * How many contexts the fakes below have actually been told to lose.
 *
 * A module-level counter rather than a closure because two tests need it and
 * both are about the same thing: `loseContext()` having been *called*, not
 * merely reachable. Reset by the `beforeEach` above.
 */
let losses = 0

/** A canvas whose context reports one renderer name. */
function gpu(name: string, onExtension?: (name: string) => void): ProbeCanvas {
  return { getContext: () => glContext(name, onExtension) }
}

/** The context behind {@link gpu}, and the one a seat's canvas hands back. */
function glContext(name: string, onExtension?: (name: string) => void): ProbeContext {
  return {
    getExtension(extension: string) {
      onExtension?.(extension)
      if (extension === 'WEBGL_debug_renderer_info') return { UNMASKED_RENDERER_WEBGL: 37446 }
      if (extension === 'WEBGL_lose_context') {
        return {
          loseContext: () => {
            losses += 1
          },
        }
      }
      return null
    },
    getParameter(id: number) {
      return id === 37446 ? name : null
    },
  }
}

/**
 * The three canvases loading the renderer adds to a terminal, as measured in
 * Chrome — the link layer with its class, the renderer's own with none, and a
 * hidden texture-atlas page that hangs off `.terminal` rather than the screen.
 */
function canvas(className: string, parentClass: string | null, gl?: ProbeContext | null): SeatCanvas {
  return {
    className,
    parentElement:
      parentClass === null ? null : { classList: { contains: (token) => token === parentClass } },
    getContext: () => gl ?? null,
  }
}
