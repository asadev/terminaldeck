/**
 * A browser window one machine holds for a session running on **another** one,
 * in the words the machine with the session has to print.
 *
 * ## Why this is its own file
 *
 * Two modules own half of this fact each and neither may import the other.
 * `remote/protocol.ts` owns the wire: it decides what a `window.holds` frame is
 * allowed to contain and refuses everything else. `main/browser-binding.ts` owns
 * the map and the sentences an agent reads, and its own header is explicit that
 * it is *"a map and some arithmetic, so it is testable without a window"* — a
 * file that pulled the whole remote protocol in to borrow four field names would
 * stop being that.
 *
 * So the vocabulary lives here, in `shared/`, and both read it. One definition of
 * the row, one cap on the text, one sanitiser — which matters more here than in
 * most places, because the same row is validated on the way in and composed into
 * an agent's context on the way out, and a cap enforced in only one of those two
 * is not a cap.
 *
 * ## What a row is, and what it deliberately is not
 *
 * It is what `windowLine` in `browser-binding.ts` needs and nothing else: the
 * number a person says out loud, the title, the URL, and where the page is
 * served. No window id, no tab id and no view id — the asking end may never name
 * a window on the other machine, only one of its own sessions, and a row that
 * carried an id would be the first half of the enumeration `WindowCallFrame`
 * refuses to make possible.
 */

/**
 * How many windows one session may have on the far machine, as far as this
 * travels.
 *
 * A person attaches one or two windows to a session; four is already unusual.
 * Sixteen is well past the real number and it is here for the reason every other
 * cap in the window family is: the list lands in a `Map` on the receiving
 * machine and is then *printed into an agent's context*, so an unbounded list
 * from a peer is somebody else spending this session's context budget. Trimmed
 * rather than refused, like `MAX_WINDOW_HOLDS` — a peer with a seventeenth
 * window should lose the seventeenth, not the link that carries the other
 * sixteen.
 */
export const MAX_HELD_WINDOWS = 16

/**
 * How long a title, a URL or a machine name may be by the time it is printed.
 *
 * The same argument one line up, sharper. These three strings are the only text
 * in this whole channel that a *peer* composes and this machine prints into a
 * turn — every other word in a hook answer is written in this repository. A page
 * whose title is forty kilobytes of whitespace is a real page, and a link that
 * carried it would put forty kilobytes into an agent's context on the strength
 * of a `document.title`.
 *
 * Cut rather than dropped: a truncated title still names the page well enough to
 * act on, and dropping the row would lose the *number*, which is the one part an
 * agent cannot work out for itself.
 */
export const MAX_HELD_LABEL_CHARS = 512

/**
 * The largest slot number that can be a real window.
 *
 * `SessionBinding.next` counts up by one per attach and never goes backwards
 * while the session holds a window, so a four-digit ceiling is thousands of
 * attaches past anything a person does. It is here so that a row cannot arrive
 * carrying `1e21` and be printed as `B1e+21`, which names no window and is the
 * kind of line that makes an agent doubt the rest of the list.
 */
const MAX_HELD_SLOT = 9_999

/** One window on the far machine. */
export interface HeldWindow {
  /**
   * The slot number — the `2` in `B2` — exactly as the machine holding the
   * window allocated it. Never renumbered in flight: `B2` has to mean the same
   * thing in the sentence an agent reads and in the `window.call` it sends back,
   * and the far machine resolves that name in its own binding map.
   */
  n: number
  /** Last known page title, or `''` when the window has not reported one. */
  title: string
  /** Last known URL, or `''` when the window has not reported one. */
  url: string
  /**
   * Where the page in that window is really served from, **said in the reading
   * machine's frame of reference**: `''` means "this computer" to whoever
   * receives the row.
   *
   * Translated by the sender rather than carried raw, and that is the whole
   * reason this field is a name and not an id. `BoundWindow.hostMachineId` is
   * empty for "the machine this map is on", so shipping it unchanged would tell
   * the receiver that a page served by the *sender* is served locally — the
   * exact inversion of Asad's rule for this feature (*"we always need a truth …
   * so just be sure we always be able to see the truth"*). The sender knows both
   * ends of the link and is the only one that can do the translation, so it
   * does it.
   */
  host: string
}

/** Every window one machine holds for one session on the machine being told. */
export interface HeldSession {
  /** The session id, as the machine that owns the session knows it. */
  session: string
  windows: HeldWindow[]
}

/**
 * Control characters and the separators that would let a peer add a line.
 *
 * C0, DEL and C1, plus the two Unicode line separators, which are line breaks to
 * plenty of readers and are not C0.
 */
const NOT_PRINTABLE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g

/**
 * One peer-supplied label, made safe to print in a hook answer.
 *
 * Three things happen and each is load-bearing:
 *
 *  - **Control characters and line breaks go.** These strings are inserted into
 *    a newline-separated list that an agent reads as instructions-adjacent
 *    context. A title containing `\n` could otherwise add a line of its own to
 *    that list — a page on somebody's screen writing into another machine's
 *    prompt. `windowLine` builds one line; this is what makes that true.
 *  - **It is cut to {@link MAX_HELD_LABEL_CHARS}.** See that constant.
 *  - **It is trimmed**, because a title that is only whitespace is `''`, and
 *    `''` is what every reader of these rows already handles by printing
 *    nothing rather than a placeholder that reads like a fact.
 */
export function heldLabel(value: unknown): string {
  if (typeof value !== 'string') return ''
  const flat = value.replace(NOT_PRINTABLE, ' ').trim()
  return flat.length > MAX_HELD_LABEL_CHARS ? flat.slice(0, MAX_HELD_LABEL_CHARS) : flat
}

/**
 * The rows of one session's windows, out of whatever a peer sent.
 *
 * Bad entries are dropped and a long list is trimmed rather than made a reason
 * to refuse the frame — `readWindowHolds` states that rule for the session list
 * and this is the same rule one level down. The frame is a peer describing its
 * own screen; a row that cannot be read describes nothing, and closing a working
 * link over it would cost somebody every terminal on it.
 *
 * `n` is the one field with no fallback. A window with no number cannot be named
 * — `B?` is not something an agent can send back — so a row without a usable one
 * is dropped rather than printed as a nameless line.
 */
export function readHeldWindows(value: unknown): HeldWindow[] {
  if (!Array.isArray(value)) return []
  const windows: HeldWindow[] = []
  for (const entry of value) {
    if (windows.length >= MAX_HELD_WINDOWS) break
    if (typeof entry !== 'object' || entry === null) continue
    const row = entry as Record<string, unknown>
    const n = row.n
    if (typeof n !== 'number' || !Number.isInteger(n) || n < 1 || n > MAX_HELD_SLOT) continue
    windows.push({
      n,
      title: heldLabel(row.title),
      url: heldLabel(row.url),
      host: heldLabel(row.host),
    })
  }
  return windows
}

/**
 * Are these two lists of windows the same thing?
 *
 * Asked on every arriving `window.holds`, and the answer decides whether the
 * session is marked for a mid-turn announcement. It has to be asked, because the
 * frame is deliberately idempotent: a link that dropped and came back re-sends
 * the whole set, and a reconnection that put a paragraph into every running
 * agent's next tool call would make a flaky network cost context. Only a real
 * change announces.
 */
export function sameHeldWindows(a: readonly HeldWindow[], b: readonly HeldWindow[]): boolean {
  if (a.length !== b.length) return false
  return a.every((window, index) => {
    const other = b[index]
    return (
      window.n === other.n &&
      window.title === other.title &&
      window.url === other.url &&
      window.host === other.host
    )
  })
}
