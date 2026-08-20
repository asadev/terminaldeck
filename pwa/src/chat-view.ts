/**
 * The conversation, as a conversation, on a phone.
 *
 * The desktop grew a chat view and Asad said exactly what one is, in one breath,
 * on 2026-08-20:
 *
 *   > *"my message should start from the right, should be on the other side like
 *   > this one, just like Claude… The left side will be the agent… here we don't
 *   > see any name, agent or whatever. So no need to give a name actually on both
 *   > sides. Not even you, for me also not you. Just start it from the right
 *   > side, give the time and all that. Just the text only and time only will be
 *   > good enough. And give the copy button wherever it's possible."*
 *
 * That is the whole specification and it is followed literally: right, left,
 * time, copy, no names. Nothing else is on this screen — no role label, no
 * "thinking", no separator with a date on it, no empty-state paragraph.
 *
 * ## Why the phone could not have one until now
 *
 * The desktop's view reads a file. `chat:load` and `chat:tail` take a folder and
 * hand back bubbles collapsed out of the JSONL the agent is writing; a phone has
 * neither the file nor a filesystem to find it in. `CAPABILITY.chat` and
 * `chat.read`/`chat.rows` are that reading carried over the wire, collapsed by
 * the same `ChatCollapser` on the far side — so a bubble here is the same bubble
 * the Mac would draw, rather than a second parse that can disagree with it.
 *
 * ## Merging, and why `reset` cannot be ignored
 *
 * Rows are merged by id: a match is replaced, anything else is appended. That is
 * what makes a growing answer redraw in place instead of stacking a paragraph at
 * a time. `reset` means the far side's document is not the one this view is
 * holding a prefix of — a rolled-over transcript, an account switch, a
 * compaction — and a client that appended through one would render the
 * conversation twice.
 */

import type { CopilotChatMessage } from '../../src/main/remote/protocol'

/** Bubbles held, oldest first. */
export type ChatRows = readonly CopilotChatMessage[]

/**
 * Fold an answer into what is already held.
 *
 * Pure and exported because it is the only part of this file with a rule in it,
 * and a rule that lives inside a DOM builder is a rule nothing can ask a
 * question of.
 */
export function mergeRows(held: ChatRows, incoming: ChatRows, reset: boolean): CopilotChatMessage[] {
  const rows = reset ? [] : [...held]
  for (const row of incoming) {
    const at = rows.findIndex((existing) => existing.id === row.id)
    if (at < 0) rows.push(row)
    else rows[at] = row
  }
  return rows
}

/**
 * `14:32`, in the reader's own locale and time zone.
 *
 * The time and nothing else — no date, no "yesterday", no relative wording. A
 * bubble carries one short figure because that is what he asked for, and a
 * client that decided when a day boundary deserved a separator would be adding
 * the furniture this whole review is about removing.
 *
 * Zero is *undated*, which `ChatMessage.at` uses for a line the transcript gave
 * no timestamp, and an undated bubble gets no time rather than 01:00 on the 1st
 * of January 1970.
 */
export function bubbleTime(at: number, now = new Date()): string {
  if (!Number.isFinite(at) || at <= 0) return ''
  const when = new Date(at)
  void now
  return when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

const SVG_NS = 'http://www.w3.org/2000/svg'

/**
 * The copy glyph — two offset rectangles, the same mark every clipboard button
 * on every surface of this product uses.
 */
function copyIcon(): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('width', '14')
  svg.setAttribute('height', '14')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '1.8')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('stroke-linejoin', 'round')
  svg.setAttribute('aria-hidden', 'true')
  const back = document.createElementNS(SVG_NS, 'rect')
  back.setAttribute('x', '9')
  back.setAttribute('y', '9')
  back.setAttribute('width', '11')
  back.setAttribute('height', '11')
  back.setAttribute('rx', '2')
  const front = document.createElementNS(SVG_NS, 'path')
  front.setAttribute('d', 'M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1')
  svg.append(back, front)
  return svg
}

export interface ChatViewDeps {
  /** Put text on the clipboard. Seam so the suite is not at the mercy of a permission. */
  copy?: (text: string) => Promise<void>
}

export class ChatView {
  readonly element = document.createElement('div')

  private rows: CopilotChatMessage[] = []
  /** Null until the first answer. False means the folder has no transcript at all. */
  private found: boolean | null = null
  private readonly copy: (text: string) => Promise<void>

  constructor(deps: ChatViewDeps = {}) {
    this.copy =
      deps.copy ??
      ((text) =>
        navigator.clipboard?.writeText(text) ??
        Promise.reject(new Error('this browser has no clipboard')))
    this.element.className = 'chatv'
    this.render()
  }

  /** Everything held, for the suite and for a caller that wants to know if it is empty. */
  get conversation(): ChatRows {
    return this.rows
  }

  /**
   * Has the far machine found a transcript for this session at all.
   *
   * Null until the first answer. False is a *different* empty from a session
   * that has not spoken yet — a folder whose agent has never written one — and
   * the difference is why the toggle that opens this view is not drawn for it.
   * Nothing on this screen says so in words; the control is simply absent, which
   * is the same rule New Session and the port list already follow.
   */
  get hasTranscript(): boolean | null {
    return this.found
  }

  apply(incoming: ChatRows, reset: boolean, found: boolean): void {
    this.rows = mergeRows(this.rows, incoming, reset)
    this.found = found
    this.render()
  }

  clear(): void {
    this.rows = []
    this.found = null
    this.render()
  }

  private render(): void {
    /*
     * Whether the reader was already at the bottom, measured *before* the rows
     * change.
     *
     * A chat view that scrolled to the bottom on every answer would yank the
     * screen out from under somebody reading back through it, which is the same
     * complaint about the same behaviour he filmed on the desktop's session
     * list. Sixteen pixels of slack because a phone's momentum scrolling rarely
     * lands exactly on the last row.
     */
    const atBottom =
      this.element.scrollHeight - this.element.scrollTop - this.element.clientHeight < 16

    // Nothing to say is drawn as nothing. Not "no messages yet", not a folder
    // with no transcript explained in a sentence — the rule he has now stated
    // four times, and a chat view with one paragraph in the middle of it is the
    // clearest example of the thing being removed everywhere else.
    this.element.replaceChildren(...this.rows.map((row) => this.bubble(row)))
    if (atBottom) this.element.scrollTop = this.element.scrollHeight
  }

  private bubble(row: CopilotChatMessage): HTMLElement {
    const line = document.createElement('div')
    line.className = 'chatv__row'
    // The side, and the only thing that says whose message this is. No label
    // above it and no name inside it: *"no need to give a name actually on both
    // sides. Not even you, for me also not you."*
    line.dataset.role = row.role

    const bubble = document.createElement('div')
    bubble.className = 'chatv__bubble'
    bubble.textContent = row.text

    const meta = document.createElement('div')
    meta.className = 'chatv__meta'

    const time = bubbleTime(row.at)
    if (time !== '') {
      const stamp = document.createElement('span')
      stamp.textContent = time
      meta.append(stamp)
    }

    const copy = document.createElement('button')
    copy.className = 'chatv__copy'
    copy.type = 'button'
    // The only words on this screen are the ones a screen reader needs; the
    // screen itself carries a glyph.
    copy.setAttribute('aria-label', 'Copy')
    copy.title = 'Copy'
    copy.append(copyIcon())
    copy.addEventListener('click', () => {
      void this.copy(row.text).then(
        () => {
          // Two seconds of a tick on the button itself. A toast saying "Copied"
          // would be a sentence about something the finger already knows it did.
          copy.dataset.done = 'yes'
          setTimeout(() => delete copy.dataset.done, 2000)
        },
        () => {
          // A clipboard a browser refuses is not worth a sentence either. The
          // button simply does not tick.
        },
      )
    })
    meta.append(copy)

    line.append(bubble, meta)
    return line
  }
}
