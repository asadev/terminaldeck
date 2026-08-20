import { WebglAddon } from '@xterm/addon-webgl'
import type { Terminal } from '@xterm/xterm'

/**
 * Which terminals draw on the GPU — and, which is most of this file, which ones
 * deliberately do not.
 *
 * ## The defect
 *
 * `@xterm/addon-webgl` has been in `package.json` and in `node_modules` for the
 * whole life of this app and **nothing imported it**. All three terminals —
 * `TerminalView`, `RemoteTerminal`, `ServerTerminal` — therefore ran xterm's DOM
 * renderer, which paints every cell as a styled `<span>`, with `scrollback:
 * 10_000` behind it. A dependency that is installed, paid for on every `npm ci`,
 * listed in `THIRD-PARTY-LICENSES.md` and wired to nothing is this repository's
 * signature bug, and it is the reported one: scrolling a busy session tears.
 *
 * ## The bar, which is not "turn on the GPU"
 *
 * Asad, on the first proposal, which was to load the addon and be done:
 *
 *   > *"I need reliability for everyone."*
 *
 * So the standard this file has to meet is **faster where it genuinely works,
 * unchanged where it does not, and never a broken terminal** — because a
 * terminal that stutters is a nuisance and a terminal that goes black is the
 * end of the session someone was working in. Four rules come out of that, and
 * each one is a section below:
 *
 *  1. refuse software rendering, which is *slower* than the DOM renderer;
 *  2. bound the number of live contexts, because Chromium caps them per page —
 *     which is two halves, a cap on how many are handed out and a release when
 *     one is handed back, and shipping only the first is the defect section 2b
 *     is the account of;
 *  3. survive losing a context, live, with the session intact;
 *  4. leave an escape hatch for a machine whose driver is broken in a way none
 *     of the above catches.
 *
 * ## What was measured, and on what
 *
 * Google Chrome 151.0.7922.169 on macOS 27, M1 Pro, retina (`deviceScaleFactor:
 * 2`), one 197x47 terminal filling a 1600x1000 window, 10 000 lines of
 * scrollback, driven by playwright. A frame on this display is 8.33 ms (120 Hz),
 * so "8.3 mean" below means *nothing was missed*.
 *
 * | case                                     | DOM              | WebGL            |
 * | ---------------------------------------- | ---------------- | ---------------- |
 * | write 638 890 bytes                       | 33.4 ms          | 30.5 ms          |
 * | scroll, 1 terminal, 800 lines/frame in    | 8.3 mean, 0 late | 8.3 mean, 0 late |
 * | scroll, **4 terminals**, 100 lines/frame  | 13.0 mean, **67 of 240 frames late** | 8.5 mean, **3 late** |
 * | scroll, 1 terminal, **software GL**       | 8.3 mean, 0 late | **107.1 mean, 398 of 399 frames late** |
 *
 * Two things follow from that table and they are the whole design.
 *
 * **One terminal on a good GPU does not need this.** At any load this Mac could
 * be made to produce, a single terminal held 120 Hz on both renderers. The win
 * appears when several terminals paint at once — the swarm grid, a split, a
 * remote pane beside a local session — where the DOM renderer missed 67 frames
 * in four seconds and WebGL missed 3. That is the tearing, and it is why the
 * fix is worth making for everyone rather than for the machine it was noticed
 * on.
 *
 * **On a software rasteriser WebGL is 12.9x worse than doing nothing.** 107 ms
 * a frame is nine frames a second, in a terminal, forever. That is not a
 * regression to trade against a benefit; it is an unusable window, and it is
 * what rule 1 exists to prevent.
 *
 * ## Why one module and not three copies
 *
 * The three terminals already share `terminalTheme()` for exactly this reason —
 * two hand-copied colour tables is how the app came to have a purple-blue
 * terminal months after that palette was retired. A GPU policy copied three
 * times would be worse: the copies would not merely drift in appearance, they
 * would each hold their own context and the *count* is the thing that has to be
 * global. There is exactly one pool in a window, and every terminal in it —
 * local, device, server — is a seat in the same pool.
 */

/* ----------------------------------------------------------- 1. the probe -- */

/**
 * Rule 1. **Refuse software rendering.**
 *
 * On a VM, over RDP, on a machine whose driver is on Chromium's blocklist, and
 * inside a lot of remote-desktop software, `getContext('webgl2')` still hands
 * back a context — it is just backed by SwiftShader, a CPU rasteriser, rather
 * than by a GPU. xterm's own addon asks for its context with
 * `{antialias: false, depth: false, preserveDrawingBuffer}` and **no**
 * `failIfMajorPerformanceCaveat`, so it takes that context happily and paints
 * the terminal on the CPU through a graphics API, which is the slowest thing
 * anybody could do with these pixels. Measured at 107 ms a frame against the
 * DOM renderer's 8.3.
 *
 * ## How it is detected, and why in two ways
 *
 * **`failIfMajorPerformanceCaveat: true`.** This is Chromium's own answer to
 * the question, and it is the one signal that does not depend on parsing a
 * string. Asked this way, a window that would be given a software context is
 * given `null` instead. Verified both directions on this Mac: Chrome as it
 * normally runs returns a context; the same Chrome launched with `--disable-gpu
 * --enable-unsafe-swiftshader --use-gl=swiftshader` returns `null`.
 *
 * **The unmasked renderer string**, as a second opinion, because the first has
 * a known blind spot: `failIfMajorPerformanceCaveat` is advisory, and there are
 * platforms and driver combinations where Chromium honours it inconsistently —
 * notably a real driver that is merely terrible (a basic display adapter, a
 * remoted GPU) is not a "caveat" to Chromium and is a disaster for us. The two
 * strings this Mac produced, quoted so the next reader knows what shape they
 * are:
 *
 *   hardware:  ANGLE (Apple, ANGLE Metal Renderer: Apple M1 Pro, Unspecified Version)
 *   software:  ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (LLVM 10.0.0) (0x0000C0DE)), SwiftShader driver)
 *
 * `WEBGL_debug_renderer_info` was available in both runs. When it is *not*
 * available the string check simply does not run — it is a second opinion, and
 * an absent second opinion is not a veto. `gl.RENDERER` is deliberately not used
 * as a substitute: it reads `"WebKit WebGL"` on both of the runs above, which
 * is a masked constant and says nothing about the hardware.
 *
 * ## Why this is a probe and not the addon's own context
 *
 * The honest measurement would be to ask xterm's renderer what it got. It does
 * not expose that, and reaching into `addon._renderer._gl` to find out would tie
 * this file to the private shape of a dependency. The probe asks the same
 * question of the same GPU stack in the same window one moment earlier, and it
 * releases its context immediately (`WEBGL_lose_context`) so that the answer
 * costs nothing from the budget rule 2 is about.
 */

/** The context the probe asks for. Not the one xterm asks for — see above. */
const PROBE_ATTRIBUTES = {
  failIfMajorPerformanceCaveat: true,
  antialias: false,
  depth: false,
} as const

/**
 * Substrings that name a CPU rasteriser pretending to be a GPU.
 *
 * Lower-cased comparison, and matched as substrings because every one of these
 * arrives wrapped in ANGLE's own parenthesised description (see the two quoted
 * strings above) rather than as a bare name.
 *
 * `llvmpipe` and `softpipe` are Mesa's; `swiftshader` is Chromium's own;
 * `microsoft basic render` is what Windows reports with no display driver
 * installed and is *extremely* common over RDP; `warp` is Direct3D's software
 * device; `apple software renderer` is the macOS equivalent. `generic renderer`
 * is what a few virtualised GPUs answer.
 *
 * A name this list does not know is treated as hardware, because the first
 * signal has already said the context is not caveated and inventing a veto from
 * an unrecognised string would turn every new GPU into a slow terminal.
 */
export const SOFTWARE_RENDERERS = [
  'swiftshader',
  'llvmpipe',
  'softpipe',
  'software rasterizer',
  'software adapter',
  'microsoft basic render',
  'apple software renderer',
  'generic renderer',
  'warp',
] as const

export function isSoftwareRenderer(name: string): boolean {
  const lower = name.toLowerCase()
  return SOFTWARE_RENDERERS.some((needle) => lower.includes(needle))
}

/**
 * The answer, with the reason attached in both directions.
 *
 * `why` is written to be readable by a person, because it is what a support
 * bundle will carry when somebody says the terminal is slow — "the app decided
 * your GPU is software" is a fact that has to be *legible*, not inferred from
 * the absence of a canvas.
 */
export type Acceleration =
  | { readonly ok: true; readonly how: string }
  | { readonly ok: false; readonly why: string }

/**
 * The slice of a WebGL context this file touches — two reads and one release.
 *
 * Structural rather than `WebGL2RenderingContext` so a test can fake it, and
 * shared by both halves of the file: the probe reads the renderer name off one,
 * and section 2b hands a terminal's back through the same {@link release}.
 */
export interface ProbeContext {
  getExtension(name: string): unknown
  getParameter(id: number): unknown
}

/** The slice of a canvas the probe uses. */
export interface ProbeCanvas {
  getContext(kind: 'webgl2', attributes: typeof PROBE_ATTRIBUTES): ProbeContext | null
}

/** `UNMASKED_RENDERER_WEBGL`, as `WEBGL_debug_renderer_info` declares it. */
interface DebugRendererInfo {
  UNMASKED_RENDERER_WEBGL: number
}

function isDebugRendererInfo(value: unknown): value is DebugRendererInfo {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as DebugRendererInfo).UNMASKED_RENDERER_WEBGL === 'number'
  )
}

/**
 * Ask one canvas whether this window has a GPU worth handing a terminal to.
 *
 * Split from {@link acceleration} — which memoises it against the real
 * `document` — so the decision can be tested without a DOM, which this project
 * has none of in its test setup, deliberately.
 */
export function readAcceleration(canvas: ProbeCanvas | null): Acceleration {
  if (canvas === null) {
    return { ok: false, why: 'this window cannot make a canvas to test the GPU with' }
  }

  let gl: ProbeContext | null = null
  try {
    gl = canvas.getContext('webgl2', PROBE_ATTRIBUTES)
  } catch {
    // getContext is specified not to throw, and a browser extension or a
    // hardened runtime that overrides it has not read the specification. A
    // throw here means the same thing a null does.
    return { ok: false, why: 'asking this window for a WebGL2 context threw' }
  }
  if (gl === null) {
    return {
      ok: false,
      why: 'this window would only be given a software-rendered WebGL context, which is slower than not using one',
    }
  }

  let name = ''
  try {
    const info = gl.getExtension('WEBGL_debug_renderer_info')
    if (isDebugRendererInfo(info)) {
      const unmasked = gl.getParameter(info.UNMASKED_RENDERER_WEBGL)
      if (typeof unmasked === 'string') name = unmasked
    }
  } catch {
    // The second opinion is optional; an absent one is not a veto.
  }

  release(gl)

  if (name !== '' && isSoftwareRenderer(name)) {
    return { ok: false, why: `the WebGL driver is a software rasteriser: ${name}` }
  }
  return {
    ok: true,
    how:
      name === ''
        ? 'Chromium gave this window a WebGL2 context that is not software-rendered'
        : `Chromium gave this window a hardware WebGL2 context: ${name}`,
  }
}

/**
 * Give a context straight back.
 *
 * A WebGL2 context counts against the per-page cap the moment it exists, and a
 * context nobody has released is not collected on any schedule this code can
 * name. Dropping the canvas is not enough; `WEBGL_lose_context` is the only way
 * to say "done" and have it mean something now. This is the difference between
 * the probe costing nothing and the probe costing a terminal.
 *
 * Written for the probe, and for a long time called only by it — which was the
 * defect section 2b below exists to correct, because the sentence above is just
 * as true of the context a *terminal* is holding. Both callers are the same two
 * lines and they are here rather than copied.
 *
 * Returns whether a context was actually let go, because the caller in section
 * 2b has to know: a release that quietly did nothing is a leak, and a leak is
 * what makes the cap's promise false.
 */
function release(gl: ProbeContext): boolean {
  try {
    const lose = gl.getExtension('WEBGL_lose_context')
    if (typeof (lose as { loseContext?: unknown } | null)?.loseContext === 'function') {
      ;(lose as { loseContext(): void }).loseContext()
      return true
    }
  } catch {
    // Nothing to do about it here. What is done about it is the caller's: the
    // probe shrugs (at worst one context is held until the window closes, which
    // the cap has room for), and a seat that cannot give its context back stops
    // the window taking any more. See {@link RendererPool.unload}.
  }
  return false
}

let measured: Acceleration | null = null

/**
 * The answer for this window, measured once.
 *
 * Once, because the probe costs a context creation and a driver does not change
 * under a running window — and because the same answer has to be given to every
 * terminal, including the twelfth one opened an hour from now.
 */
export function acceleration(): Acceleration {
  if (measured === null) {
    const doc = (globalThis as { document?: { createElement(tag: 'canvas'): unknown } }).document
    const canvas = (doc?.createElement('canvas') ?? null) as ProbeCanvas | null
    measured = readAcceleration(canvas)
  }
  return measured
}

/** Tests and the escape hatch below both need the memo to be forgettable. */
export function forgetAcceleration(): void {
  measured = null
}

/* ------------------------------------------------------------ 2. the cap -- */

/**
 * Rule 2. **Bound the contexts.**
 *
 * `driving/ScanField.tsx` already argued this from the other side, when it
 * chose a 2D canvas for the dots rather than WebGL:
 *
 *   > *"This window already runs one WebGL context per terminal — xterm's
 *   > renderer — and browser tabs are separate composited views on top.
 *   > Chromium caps live WebGL contexts per process and evicts the oldest when
 *   > the cap is hit, which on this app means a terminal loses its renderer to
 *   > make room for a decoration."*
 *
 * That was written from the documentation. It is now measured: building
 * terminals in one page until Chromium complained, the console printed
 *
 *   WARNING: Too many active WebGL contexts. Oldest context will be lost.
 *
 * five times while twenty-one contexts were alive — the seventeenth onwards.
 * **The ceiling is sixteen per page**, and the penalty for crossing it is not a
 * refusal, it is the *oldest* context being taken away: the terminal somebody
 * has had open longest is the one that goes.
 *
 * This app can be a long way past sixteen terminals. Every session's terminal
 * stays mounted when its tab is hidden — that is what makes scrollback survive a
 * tab switch — and `SwarmGrid` puts a cell on screen for every session in a
 * project with no upper bound at all. Handing a context to each would guarantee
 * the eviction above, in the worst possible order.
 *
 * ## So: on screen, most recently used, and at most four
 *
 * A seat gets a context when it is **actually on screen** and it is one of the
 * {@link MOST_ACCELERATED} most recently focused of the seats that are. Anything
 * hidden, scrolled out of view, or further down the focus order draws on the
 * DOM, and the two swap the moment focus moves — which is measured as safe in
 * both directions: disposing the addon restores the DOM rows and the buffer
 * intact, and a fresh addon loads on the same terminal afterwards.
 *
 * Visibility is *measured*, not taken from the `visible` prop, and that is not
 * fussiness. `App.tsx` passes `visible` as a literal `true` in both the split
 * layout and the swarm grid, because in those layouts every terminal it renders
 * genuinely is on screen — so the prop cannot tell four visible terminals apart
 * from one, which is the exact case this rule exists for. `RemoteTerminal` has
 * no such prop at all. An `IntersectionObserver` on the element answers the
 * question the same way for all three, needs nothing from any caller, and is
 * how the app keeps its shape identical whichever machine the session is on.
 */

/**
 * How many terminals may hold a context at once.
 *
 * Four, from the table at the top of this file: four accelerated terminals
 * streaming at once cost 8.5 ms a frame with 3 late frames in 240, where the
 * same four on the DOM renderer cost 13.0 ms with 67 late. So four is both
 * affordable and the size at which the benefit is real — a fifth and sixth
 * simultaneously-scrolling terminal is not a thing anybody is reading.
 *
 * It is also a quarter of the sixteen Chromium allows, which leaves room for
 * everything else in the page that might want one.
 *
 * ## What this number cannot do on its own, which is the correction
 *
 * The first version of this comment finished the paragraph above with *"and,
 * more importantly, means this app can never be the reason a context is
 * evicted"*. That was reasoned from the cap and never measured, and it was
 * **false**. The cap bounds *seats holding a renderer*. Chromium counts *live
 * contexts*. Those were two different numbers, because disposing the addon does
 * not give its context back — see section 2b, which is the other half of this
 * rule and the half that was missing.
 *
 * Measured in Chrome 151 on this Mac, driving this module itself rather than a
 * sketch of it: six panes on screen with focus moving between them, and then
 * forty terminals opened and closed, which is an ordinary afternoon. Three runs
 * of each, and the count is Chromium's rather than this module's own bookkeeping
 * — after the scenario, take WebGL2 contexts one at a time until it says the
 * table is full, and subtract.
 *
 * | after                                    | contexts this app held  | "too many" warnings |
 * | ---------------------------------------- | ----------------------- | ------------------- |
 * | 80 focus swaps across 6 panes, *before*  | 12, 16, 12              | 39, 36, 39          |
 * | 40 terminals opened and closed, *before* | **16, 11, 7 — with nothing on screen** | 9, 0, 2 |
 * | 80 focus swaps across 6 panes, *after*   | **4, 4, 4**             | 0, 0, 0             |
 * | 40 terminals opened and closed, *after*  | **0, 0, 0**             | 0, 0, 0             |
 *
 * Sixteen of Chromium's sixteen, held by a window whose cap is four and which,
 * in the second row, has nothing on screen at all. The spread in the "before"
 * rows is not noise in the measurement — it is Chromium having already evicted
 * some of them, which is the failure itself: in one baseline run the
 * console carried four `webglcontextlost` events on terminals that were on
 * screen at the time. Rule 3 turns one of those into the whole window on the DOM
 * renderer until restart, so a design meant for a driver fault was reachable by
 * clicking between panes for a minute.
 *
 * A cap that merely *usually* avoids that would be worth very little — but a cap
 * is not what avoids it. Giving the context back is.
 */
export const MOST_ACCELERATED = 4

/** What the policy needs to know about a seat. Nothing about terminals. */
export interface SeatState {
  readonly id: number
  readonly visible: boolean
  /** A counter, not a clock: bigger means focused more recently. */
  readonly touched: number
}

/**
 * Which seats should be drawing on the GPU right now.
 *
 * Pure, and exported, because it is the whole of the policy and a decision
 * worth a paragraph is worth a test — the same argument `ShellFrames` makes for
 * itself two directories over.
 *
 * Ties are broken by id, i.e. by the order the terminals were created, so that
 * a window full of never-focused terminals settles on a stable set instead of
 * churning contexts every time anything re-renders.
 */
export function seatsToAccelerate(seats: readonly SeatState[], cap: number): number[] {
  if (cap <= 0) return []
  return seats
    .filter((seat) => seat.visible)
    .sort((a, b) => (b.touched - a.touched !== 0 ? b.touched - a.touched : a.id - b.id))
    .slice(0, cap)
    .map((seat) => seat.id)
}

/* ------------------------------------------- 2b. giving the context back -- */

/**
 * Rule 2, second half. **A seat that gives up its renderer gives up its
 * context**, and a window that cannot give one back stops taking them.
 *
 * ## The defect this section is
 *
 * The cap above was shipped believing it bounded live contexts. It does not.
 * `@xterm/addon-webgl@0.19.0` tears down like this, and this is the whole of it
 * (`WebglRenderer.ts:144-150`):
 *
 *     this._register(toDisposable(() => {
 *       for (const l of this._renderLayers) { l.dispose() }
 *       this._canvas.parentElement?.removeChild(this._canvas)
 *       removeTerminalFromCache(this._terminal)
 *     }))
 *
 * Render layers disposed, canvas out of the DOM, cache entry dropped — and
 * **no `WEBGL_lose_context`**. Nothing tells the GPU process the context is
 * finished, so it keeps its seat at Chromium's table of sixteen. That is
 * precisely what {@link release} says, 390 lines above, about the probe's own
 * context: *"a context nobody has released is not collected on any schedule this
 * code can name. Dropping the canvas is not enough."* The rule was written down
 * and then applied to the one context that is created once, and not to the ones
 * that churn — and churn is exactly what the design above causes, because a
 * context moves every time focus does.
 *
 * The numbers are in {@link MOST_ACCELERATED}. The short version: forty
 * terminals opened and closed left **seven to sixteen** contexts alive with
 * nothing on screen at all, against a cap of four; with this section, none.
 *
 * ## Finding the canvas, which the addon does not hand over
 *
 * `WebglAddon` declares eight members: `activate`, `dispose`, `onContextLoss`,
 * `textureAtlas`, `clearTextureAtlas` and three texture-atlas events. Not one of
 * them is the render canvas or its context — `textureAtlas` is the *glyph* atlas,
 * a hidden 2D canvas, and it is the third row of the table below rather than the
 * second. The canvas is reachable through the DOM instead — the renderer
 * appends it to xterm's `.xterm-screen` (`WebglRenderer.ts:138`) — and
 * `getContext('webgl2')` on a canvas that already has a WebGL2 context returns
 * *that* context rather than making a second one. Verified in Chrome rather
 * than read off the specification: on 40 of 40 loads the object handed back was
 * `===` the addon's own `_renderer._gl`.
 *
 * Which canvas, also measured rather than assumed. Loading the addon on a
 * terminal adds three, and they are told apart by where they are and what they
 * are called:
 *
 * | canvas                         | parent          | class              |
 * | ------------------------------ | --------------- | ------------------ |
 * | the link render layer, 2D      | `.xterm-screen` | `xterm-link-layer` |
 * | **the renderer's own, WebGL2** | `.xterm-screen` | *(none)*           |
 * | a texture-atlas page, hidden   | `.terminal`     | *(none)*           |
 *
 * so "new, unclassed, and a child of `.xterm-screen`" names exactly one of the
 * three — on 40 of 40 loads, checked both ways round.
 *
 * `addon._renderer._gl` would be one line and is deliberately not used. The
 * probe section above already refused to read the addon's private shape and
 * gave its reason; a file that keeps one standard for the paragraph it argued
 * and another for the paragraph it needed would not be worth reading.
 *
 * ## And when it is ever not exactly one
 *
 * Then {@link gpuCanvasOf} answers `null`, {@link releaseSeatContext} answers
 * `false`, and the pool stops accelerating the whole window. That is not
 * caution, it is what makes the claim in {@link MOST_ACCELERATED} a fact rather
 * than a hope: either every context this app takes is given back, or it takes at
 * most one more and stops. The alternative — carrying on and writing a warning
 * — is exactly the shape this defect already had once, which is a promise in a
 * comment and a leak in the code.
 */

/** Where xterm's renderer puts its canvas. `WebglRenderer.ts:138`. */
const SCREEN_CLASS = 'xterm-screen'

/**
 * The slice of a canvas this section uses. Structural, so a test can fake it,
 * and satisfied by `HTMLCanvasElement` — which is what lets
 * {@link attachRenderer} hand {@link rendererSeat} a real `querySelectorAll`
 * with no cast.
 */
export interface SeatCanvas {
  readonly className: string
  readonly parentElement: { readonly classList: { contains(token: string): boolean } } | null
  getContext(kind: 'webgl2'): ProbeContext | null
}

/**
 * The one canvas that loading the renderer added to `.xterm-screen`.
 *
 * `before` is the set of canvases the terminal had a moment earlier, so this is
 * a difference rather than a guess: the atlas page hangs off `.terminal` and the
 * link layer carries a class, which leaves one. `null` — deliberately, rather
 * than a best guess — if it is not exactly one, because the caller's answer to
 * "I do not know which context is mine" has to be to stop, not to release
 * something that might belong to somebody else.
 */
export function gpuCanvasOf<T extends SeatCanvas>(
  before: ReadonlySet<T>,
  after: readonly T[],
): T | null {
  const fresh = after.filter(
    (canvas) =>
      !before.has(canvas) &&
      canvas.className === '' &&
      canvas.parentElement?.classList.contains(SCREEN_CLASS) === true,
  )
  return fresh.length === 1 ? (fresh[0] ?? null) : null
}

/**
 * Give one seat's context back. Answers whether it went.
 *
 * Call it **after** the addon has been disposed, and that order is measured, not
 * tidiness: disposal takes the addon's own `webglcontextlost` listener off the
 * canvas, so losing the context afterwards fires an event nobody is listening
 * for. Losing it first would hand the addon a genuine context loss — which it
 * answers by freezing the terminal for three seconds and then reporting it —
 * and rule 3 would turn an ordinary tab switch into the whole window on the DOM
 * renderer until restart.
 *
 * A `false` here means the context is still alive and this code no longer knows
 * where it is. See the last paragraph of this section for what the caller does
 * with that.
 */
export function releaseSeatContext(canvas: SeatCanvas | null): boolean {
  if (canvas === null) return false
  let gl: ProbeContext | null = null
  try {
    gl = canvas.getContext('webgl2')
  } catch {
    // `getContext` is specified not to throw; a canvas that does is one this
    // code cannot reason about, and the caller treats that as a leak.
    return false
  }
  return gl === null ? false : release(gl)
}

/** An addon as the dependency ships it: no way to give its context back. */
export type LoadedAddon = Omit<RendererAddon, 'releaseContext'>

/**
 * One seat's renderer: the addon, plus the two lines that make it releasable.
 *
 * Split out of {@link attachRenderer} and exported for one reason, which is the
 * history of this section. The pieces either side of this one — the policy in
 * {@link RendererPool}, and {@link gpuCanvasOf} and {@link releaseSeatContext}
 * below it — are easy to test without a DOM and are tested. **The wiring between
 * them is not, unless it is given a name**, and the wiring is exactly where the
 * original defect lived: `attachRenderer` handed the pool an addon whose
 * disposal released nothing at all, and every test in this file stayed green,
 * because every one of them fakes the addon. Both halves of that were run rather
 * than assumed: with this seam still four lines inside a closure, replacing the
 * release with `() => true` left all 37 tests passing; with the two that now sit
 * on this function, the same edit fails two of 39.
 *
 * `canvases` is a callback and not an array because it is read twice, either
 * side of `load()`, and the difference is the answer — see {@link gpuCanvasOf}.
 * Both arguments are functions so that a test can drive this without a DOM,
 * which is what this project's test setup has.
 */
export function rendererSeat(
  canvases: () => Iterable<SeatCanvas>,
  load: () => LoadedAddon,
): RendererAddon {
  const before = new Set<SeatCanvas>(canvases())
  const addon = load()
  const canvas = gpuCanvasOf(before, [...canvases()])
  return {
    onContextLoss: (handler) => addon.onContextLoss(handler),
    dispose: () => addon.dispose(),
    releaseContext: () => releaseSeatContext(canvas),
  }
}

/* --------------------------------------------------- 3 and 4: the pool -- */

/**
 * The addon, as this file uses it. Three members of `WebglAddon`.
 *
 * Structural rather than the imported class for the reason `DriveTerminal`
 * gives in `driving/terminal-registry.ts`: it documents the blast radius, and
 * it lets the pool be tested in a runner with no DOM and no canvas.
 */
export interface RendererAddon {
  /**
   * Fires when the renderer has lost its canvas context **and has given up
   * waiting for it back**. Not immediately: `@xterm/addon-webgl@0.19.0` starts a
   * `3e3` ms timer on `webglcontextlost` and only fires this if no
   * `webglcontextrestored` arrives before it expires. Measured at 3 s on this
   * Mac, and it means the terminal is frozen for those three seconds before
   * anything here can react. That is the library's decision, not ours; what is
   * ours is what happens next, which is rule 3.
   */
  onContextLoss(handler: () => void): { dispose(): void }
  dispose(): void
  /**
   * Give the GPU context back, and say whether it went.
   *
   * Called immediately after {@link dispose}, and it is a separate member
   * because the addon has no such method: disposal removes the canvas and
   * leaves the context alive, which is the whole of section 2b. The mechanism
   * lives beside `new WebglAddon()` in {@link attachRenderer}, where the canvas
   * is; what lives here is the *policy*, which is that a pool refusing to hold
   * more than {@link MOST_ACCELERATED} contexts has to be able to prove it let
   * the others go.
   *
   * **Required, not optional.** An optional member is one a future seat can
   * forget, and forgetting exactly this is the defect this section exists to
   * correct.
   */
  releaseContext(): boolean
}

/** A seat's private state. `SeatState` is the part the policy sees. */
interface Seat {
  id: number
  /** Build a renderer for this terminal and put it on screen, or refuse. */
  accelerate: () => RendererAddon | null
  visible: boolean
  touched: number
  addon: RendererAddon | null
  loss: { dispose(): void } | null
}

/** What a terminal holds on to. Everything else about the pool is private. */
export interface SeatHandle {
  /** The element came on or off screen. */
  setVisible(visible: boolean): void
  /** Somebody put the keyboard in this terminal. */
  touch(): void
  /** The terminal is going away. */
  leave(): void
  /** Whether this seat is drawing on the GPU right now. For tests and diagnostics. */
  accelerated(): boolean
}

export interface PoolOptions {
  cap?: number
  /** Whether this window may hand out contexts at all. Called at most once. */
  measure?: () => Acceleration
  /**
   * Where every decision is written down.
   *
   * One line per state change, to the console by default, and that is the whole
   * of this module's diagnostics on purpose. There is no `whichRenderer()`
   * getter, because there is nowhere in the app that would call one: the
   * Advanced pane's diagnostics are built from `settings-extra.ts`, which is
   * another file. An exported accessor with no caller is the shape of bug this
   * codebase keeps finding in itself — the WebGL addon this module exists to
   * load was installed and imported by nothing for the app's whole life. When
   * that pane wants the renderer, it can have a getter *and* a reader in the
   * same change.
   *
   * Overridden in tests, which assert on the sentences rather than on a value
   * only a test would read.
   */
  note?: (message: string) => void
}

/**
 * Every terminal in one window, and the contexts they share between them.
 *
 * ## Rule 3: survive context loss
 *
 * A context can be taken away by something entirely outside this app — a driver
 * reset, a GPU process crash, the machine waking from sleep, an external display
 * being unplugged. When that happens the terminal is showing a dead canvas, and
 * the only acceptable outcome is that it goes back to painting.
 *
 * So the handler disposes the addon, which is measured to be a complete
 * recovery: with the context destroyed under a terminal holding 400 lines of
 * output, `dispose()` left `.xterm-rows` rebuilt with all 47 rows, the same 46
 * lines of text on screen, and bytes written afterwards painting normally. The
 * session is not touched at any point — nothing here talks to a pty, a device or
 * a server, and that is on purpose.
 *
 * **And then it stops, for the whole window.** A lost context has two plausible
 * causes and neither is improved by asking again: either the GPU is in trouble,
 * in which case the next context will die the same way, or something evicted us,
 * in which case taking another context is how the eviction continues. A terminal
 * that stutters is a nuisance; a terminal that dies every few minutes and comes
 * back is unusable, and the person watching it cannot tell which of the two
 * things they are looking at. It comes back on the next launch, which is a
 * price worth paying for a rule that cannot oscillate.
 *
 * ## Rule 4: the escape hatch
 *
 * {@link forceDom} turns every context in the window off and keeps it off, and
 * it is reversible — unlike a context loss, because it is a person's decision
 * rather than a symptom. What sets it is at the bottom of this file.
 */
export class RendererPool {
  private readonly seats = new Map<number, Seat>()
  private readonly cap: number
  private readonly measure: () => Acceleration
  private readonly note: (message: string) => void

  private next = 1
  /**
   * Focus order, as a counter rather than a clock: two terminals focused inside
   * the same millisecond must still have an order, and the only thing read off
   * this number is which of two is the more recent.
   */
  private clock = 0
  private allowed: Acceleration | null = null
  /** Set once by a context loss. Never cleared: see the note above. */
  private surrendered: string | null = null
  /**
   * A context this pool could not give back, noticed mid-pass.
   *
   * Recorded rather than acted on where it happens, because it happens inside
   * `unload`, which `settle` is in the middle of looping over — surrendering
   * from there would re-enter `settle` while the map it is iterating is being
   * changed underneath it. `settle` reads this once its pass is finished.
   */
  private stranded: string | null = null
  /** Set by the setting. Cleared when the setting is turned back off. */
  private forced = false

  constructor(options: PoolOptions = {}) {
    this.cap = options.cap ?? MOST_ACCELERATED
    this.measure = options.measure ?? acceleration
    this.note = options.note ?? ((message) => console.info(`terminal renderer: ${message}`))
  }

  join(accelerate: () => RendererAddon | null): SeatHandle {
    const id = this.next
    this.next += 1
    const seat: Seat = { id, accelerate, visible: false, touched: 0, addon: null, loss: null }
    this.seats.set(id, seat)
    return {
      setVisible: (visible) => {
        if (seat.visible === visible) return
        seat.visible = visible
        // A terminal coming on screen is the commonest way one earns a context,
        // and it has not been focused yet — so arriving counts as being used,
        // or a freshly opened session in a full window would draw on the DOM
        // until somebody clicked it.
        if (visible) seat.touched = this.tick()
        this.settle()
      },
      touch: () => {
        seat.touched = this.tick()
        this.settle()
      },
      leave: () => {
        this.unload(seat)
        this.seats.delete(id)
        this.settle()
      },
      accelerated: () => seat.addon !== null,
    }
  }

  /** Rule 4, and also what a settings change calls when it is turned back off. */
  forceDom(forced: boolean): void {
    if (this.forced === forced) return
    this.forced = forced
    this.note(forced ? 'forced to the DOM renderer by a setting' : 'the DOM-renderer setting was turned off')
    this.settle()
  }

  /** Rule 3. Public because the loss handler is registered per seat. */
  surrender(why: string): void {
    if (this.surrendered !== null) return
    this.surrendered = why
    this.note(`${why} — every terminal in this window is back on the DOM renderer until it is restarted`)
    this.settle()
  }

  private tick(): number {
    this.clock += 1
    return this.clock
  }

  private mayAccelerate(): boolean {
    if (this.forced || this.surrendered !== null) return false
    if (this.allowed === null) {
      this.allowed = this.measure()
      this.note(this.allowed.ok ? this.allowed.how : `staying on the DOM renderer — ${this.allowed.why}`)
    }
    return this.allowed.ok
  }

  /**
   * Bring the window into line with the policy.
   *
   * Called after every change rather than diffed incrementally, because the set
   * of seats is a handful of entries and a policy applied from scratch cannot
   * drift out of step with itself — which an incremental one, on a list that
   * changes from four different events, absolutely can.
   */
  private settle(): void {
    const wanted = new Set<number>()
    // The probe is only paid for if some terminal would otherwise get a
    // context: a window that never shows a terminal never touches the GPU.
    if (this.seats.size > 0 && [...this.seats.values()].some((seat) => seat.visible)) {
      if (this.mayAccelerate()) {
        for (const id of seatsToAccelerate([...this.seats.values()], this.cap)) wanted.add(id)
      }
    }

    for (const seat of this.seats.values()) {
      /*
       * `wanted` is a plan, and the window's state is re-read for every seat in
       * the pass, because `load` can end the window in the middle of one: a seat
       * whose `accelerate()` throws calls `surrender`, and without this the
       * seats after it would still be handed contexts the window has just
       * decided it must not hold. Reachable only when `accelerate` fails for one
       * seat and succeeds for another — which `WebGL2 not supported` would not
       * do, since that is a fact about the window — but a seat holding a context
       * while `surrendered` is set is exactly the accounting error section 2b is
       * about, and this is one condition rather than a paragraph of hope.
       */
      if (wanted.has(seat.id) && this.surrendered === null && !this.forced) this.load(seat)
      else this.unload(seat)
    }

    /*
     * A context that would not come back, from anywhere in the pass above.
     * Cleared before surrendering, so the `settle` that `surrender` runs cannot
     * come back here and do it again.
     */
    if (this.stranded !== null) {
      const why = this.stranded
      this.stranded = null
      this.surrender(why)
    }
  }

  private load(seat: Seat): void {
    if (seat.addon !== null) return
    let addon: RendererAddon | null = null
    try {
      addon = seat.accelerate()
    } catch (error) {
      /*
       * `WebglAddon.activate` throws `WebGL2 not supported` when the context
       * cannot be created, and that is a fact about the window rather than
       * about this terminal — so the whole window gives up rather than trying
       * again on the next one and throwing again, once per terminal, forever.
       *
       * It is `surrender` and not a plain refusal because the two are the same
       * situation: we asked for a context, we did not get one, and asking again
       * is not a plan.
       */
      this.surrender(`this window could not create a WebGL renderer (${describe(error)})`)
      return
    }
    if (addon === null) {
      this.surrender('this build has no WebGL renderer to load')
      return
    }
    seat.addon = addon
    try {
      seat.loss = addon.onContextLoss(() => {
        // Rule 3, in two moves: this terminal goes back to the DOM renderer
        // immediately — `settle` disposes the addon, which is what restores it —
        // and the window stops asking for contexts.
        this.surrender('the graphics context was lost')
      })
    } catch {
      // An addon that cannot report a loss is an addon we cannot make safe.
      this.unload(seat)
      this.surrender('this window has a WebGL renderer that cannot report a lost context')
    }
  }

  /**
   * Take the context back, live — both halves of taking it back.
   *
   * **`dispose()`** is not a teardown here, it is the *fallback*. The addon's own
   * disposal path puts xterm's DOM renderer back and resizes it, so the terminal
   * keeps its buffer, its scroll position and its cursor, and the next byte
   * written paints. Measured: rows rebuilt, text identical, writes after the
   * swap visible on screen.
   *
   * **`releaseContext()`** is the half that was missing, and section 2b is the
   * argument for it: disposal leaves the context alive, so for a long time this
   * method gave the *renderer* back and kept the *context*, which made the cap
   * above a promise about the wrong number. It runs even when disposal threw,
   * because a half-torn-down addon is exactly the case where a context is most
   * likely to be left holding a seat.
   *
   * A context that will not come back is not survivable by carrying on: the next
   * swap leaks another, and the end of that is Chromium evicting somebody's
   * terminal. So it is recorded, and `settle` turns it into a surrender — the
   * same answer this file gives every other "the GPU story has gone wrong",
   * which is that the window finishes on the DOM renderer and says so.
   */
  private unload(seat: Seat): void {
    if (seat.loss !== null) {
      try {
        seat.loss.dispose()
      } catch {
        // A disposable that throws must not strand the addon below it.
      }
      seat.loss = null
    }
    if (seat.addon === null) return
    const addon = seat.addon
    seat.addon = null
    try {
      addon.dispose()
    } catch (error) {
      // xterm guards its own restore against a terminal that is already
      // disposed, so this is a genuine surprise rather than an ordinary
      // teardown race — but the terminal is what matters and it is fine either
      // way, so it is written down rather than thrown.
      this.note(`disposing a renderer threw (${describe(error)})`)
    }

    let given = false
    try {
      given = addon.releaseContext()
    } catch (error) {
      this.note(`giving a renderer's context back threw (${describe(error)})`)
    }
    if (!given && this.stranded === null) {
      this.stranded = "a terminal's WebGL context could not be given back"
    }
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/* -------------------------------------------------- the setting, and the -- */
/* -------------------------------------------------- wiring the three call -- */

/**
 * Rule 4. **An escape hatch**, for a machine whose driver is broken in a way
 * the probe does not catch.
 *
 * The probe answers Chromium's question, and Chromium does not know everything:
 * a driver that reports itself as hardware, passes `failIfMajorPerformanceCaveat`
 * and then renders a terminal wrong — glyphs missing, colours inverted, a black
 * rectangle — is a real thing on old Windows GPUs. The person in front of it
 * cannot wait for a build, so there has to be a switch.
 *
 * ## Where the switch is, and what is still owed
 *
 * It is a key in `settings.json`, read straight off the settings channel here:
 *
 *     "advanced.forceDomRenderer": true
 *
 * The id is `advanced.`-prefixed on purpose. Settings ids are `section.name`
 * and the stored key *is* the id, so the day a row is declared for it in
 * `settings/settings-schema.ts` — one entry, in the Advanced section, beside
 * `advanced.debugMode` — the toggle writes this exact key. `settings-schema.ts`
 * is not this lane's file to edit and that row is reported as owed; **the key
 * works today either way**, because `mergeSettings` keeps keys it does not know
 * and `applyPatch` merges rather than replaces, so a hand-written entry survives
 * every write the settings window makes. Advanced → Debug mode is the pane that
 * says where that file is.
 *
 * ## What the first version of that paragraph got wrong
 *
 * It ended *"and this code needs no change to obey it"*. That was reasoned from
 * the id and not checked, and it is false — in the one direction that matters,
 * which is a person toggling the row. Two things carry a settings change to
 * running code in this window, and this module can only see one of them:
 *
 *  - **`settings:changed`**, the IPC push, which is what {@link watchTheSetting}
 *    subscribes to. `live-push.ts` says in as many words that it carries
 *    "changes the window did not make", because "a push back down the same wire
 *    would be a second update for one change". A toggle in this window's own
 *    Settings dialog is exactly a change the window *did* make, so nothing
 *    arrives.
 *  - **`<SettingsWindow onChange>`**, the callback that dialog fires after every
 *    accepted write. `App.tsx` renders that dialog inside this window and feeds
 *    the callback to `useAppSettings`. Nothing here can see it.
 *
 * So what is true today: the key is obeyed at launch, and obeyed *live* when it
 * is written from outside this window — the copilot, or a paired phone, which is
 * what `live-push.ts` was built for. Toggled in the Settings dialog it would
 * take effect on the next launch, and for somebody staring at a terminal that is
 * rendering wrongly right now, "restart the app" is not the escape hatch this
 * rule promised. Closing it is two lines, one at each end — here:
 *
 *     export function forceDomRenderer(on: boolean): void { pool.forceDom(on) }
 *
 * and in `App.tsx`, beside the `apply` that dialog's `onChange` already calls:
 *
 *     forceDomRenderer(values[FORCE_DOM_SETTING] === true)
 *
 * and it is reported as owed together with the row. Neither line is written yet,
 * deliberately, and that includes the one that lives in this file: an export
 * with no caller is the shape of bug this module exists to fix — the addon it
 * loads sat in `package.json` imported by nothing for the app's whole life — so
 * the setter and the line that calls it belong in one change, by the same
 * argument {@link PoolOptions.note} makes about a `whichRenderer()` nobody reads.
 *
 * ## Why this module reads it rather than being handed it
 *
 * `ServerSessionPane` already made this call and wrote down why: *"Read here
 * rather than threaded down from the window. The hook is one read at launch plus
 * whatever the settings window pushes, so asking for it costs nothing — and the
 * alternative is the bug this repository has already shipped twice: a font size
 * in Settings that reaches a preview and no terminal."* The same holds here and
 * harder, because the alternative would be threading a prop through `App.tsx`,
 * the split, the swarm grid, the machines panel and the servers panel — five
 * files, four of them other people's, to carry one boolean to a module all three
 * terminals already call.
 *
 * The quote's second half — *"plus whatever the settings window pushes"* — is
 * the part that turned out not to be true of this window's own dialog, which is
 * the correction above. It does not overturn the choice: a threaded prop would
 * close that gap, at the price of five files and a boolean carried through four
 * layouts that have no other reason to know about the GPU. One read here plus
 * one line in `App.tsx` is the same result for two lines of change, and the
 * second of them is owed rather than pretended.
 */
export const FORCE_DOM_SETTING = 'advanced.forceDomRenderer'

/**
 * Is the escape hatch on, in whatever the settings channel just handed us?
 *
 * Both stored shapes, exactly as `toStoredSettings` handles them: the
 * `{version, values}` envelope and the bare map from a build that predates it.
 * Anything else — a rejected promise, a bridge that is not there, a value that
 * is not a boolean — is `false`, because the default has to be "behave normally"
 * and an unreadable settings file must not decide how the app renders.
 */
export function forcedToDom(raw: unknown): boolean {
  if (typeof raw !== 'object' || raw === null) return false
  const record = raw as Record<string, unknown>
  const values = (typeof record.values === 'object' && record.values !== null
    ? record.values
    : record) as Record<string, unknown>
  return values[FORCE_DOM_SETTING] === true
}

/** The window's one pool. Every terminal in it is a seat. */
const pool = new RendererPool()

/** The slice of the preload bridge this module reads. Every method optional. */
interface SettingsChannel {
  getSettings?(): Promise<unknown>
  onSettingsChanged?(handler: (settings: unknown) => void): () => void
}

let watching = false

/**
 * Start listening for the escape hatch, once, on the first terminal.
 *
 * Not at import time: a module that reaches for `window.deck` while it is being
 * imported is a module that cannot be imported by a test, and `.harness/stub.ts`
 * mounts this app against a bridge that grows methods one at a time. Both
 * methods are called with `?.` for that reason — the harness note in
 * `useAppSettings` says the same thing about the same bridge.
 *
 * The read is asynchronous and the terminals are not, so a window whose owner
 * has forced the DOM renderer may accelerate one or two terminals for the few
 * milliseconds before the answer lands. That is not a hole: `forceDom(true)`
 * takes the contexts back live, by the same disposal path everything else here
 * uses, and the person sees the renderer they asked for.
 */
function watchTheSetting(): void {
  if (watching) return
  watching = true
  const deck = (globalThis as { window?: { deck?: SettingsChannel } }).window?.deck
  if (!deck) return
  void deck
    .getSettings?.()
    .then((stored) => pool.forceDom(forcedToDom(stored)))
    .catch(() => {
      // The schema default is what the app already assumes.
    })
  deck.onSettingsChanged?.((stored) => pool.forceDom(forcedToDom(stored)))
}

/**
 * Put a terminal in the pool. The one call the three terminals make.
 *
 * Call it **after `term.open(host)`** — xterm has to have built its DOM before a
 * renderer can replace it — and call the returned function when the terminal is
 * disposed.
 *
 * `host` is the element the pane owns, not xterm's own `.xterm`: it is the box
 * whose size and visibility the layout controls, and it is already what every
 * one of the three watches with a `ResizeObserver` for fitting.
 */
export function attachRenderer(term: Terminal, host: HTMLElement): () => void {
  watchTheSetting()

  /*
   * The seat, and the two things only this function can know: how to build a
   * renderer for *this* terminal, and where the context it takes ends up.
   *
   * Both are handed to {@link rendererSeat}, which is where the canvas is caught
   * — it reads them either side of the load, because the only moment the
   * renderer's canvas can be told from the link layer's and the atlas page's is
   * by what loading the addon *added*, and section 2b has the table. Caught now
   * rather than looked up at disposal time, because by then the addon has
   * already taken it out of the DOM.
   *
   * `loadAddon` is what throws `WebGL2 not supported` on a window with no
   * WebGL2, and it throws before the canvas is ever read — so that failure still
   * arrives at `RendererPool.load` exactly as it did, and is still a fact about
   * the window rather than about this terminal.
   */
  const seat = pool.join(() =>
    rendererSeat(
      () => host.querySelectorAll('canvas'),
      () => {
        const addon = new WebglAddon()
        term.loadAddon(addon)
        return addon
      },
    ),
  )

  const focused = (): void => seat.touch()
  host.addEventListener('focusin', focused)

  /*
   * On screen, measured.
   *
   * `IntersectionObserver` answers for every way this app hides a terminal —
   * `.terminal-host[data-visible='false']`, `.server-pane[data-visible='false']`
   * and a panel that is simply not rendered are all `display: none`, which is
   * not intersecting — and it fires once when it starts observing, so the
   * initial state needs no separate read.
   *
   * Guarded because the constructor is missing in some non-browser runtimes
   * this file is imported into. A window that cannot measure visibility treats
   * every terminal as visible, which leaves the cap doing the bounding on its
   * own: still correct, just less selective about which four.
   */
  let stopWatching: (() => void) | null = null
  if (typeof IntersectionObserver === 'function') {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) seat.setVisible(entry.isIntersecting)
    })
    observer.observe(host)
    stopWatching = () => observer.disconnect()
  } else {
    seat.setVisible(true)
  }

  return () => {
    host.removeEventListener('focusin', focused)
    stopWatching?.()
    seat.leave()
  }
}
