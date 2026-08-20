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
/*
 * The two-write rule, imported rather than restated.
 *
 * `terminalWrites` is the desktop composer's own measurement of what a Claude
 * CLI accepts as a submitted line, and it is the single rule that decides
 * whether a send button does anything at all. A second copy of it here would be
 * a copy that goes stale against the CLI while the desktop's is corrected — and
 * the failure of a stale copy is silent: the words land in the agent's input box
 * and sit there. `mentions.ts` has no imports of its own, so this costs the
 * bundle the two functions and nothing else.
 */
import { SUBMIT_GAP_MS, terminalWrites } from '../../src/renderer/chat/attach/mentions'

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

/**
 * Somewhere to answer, at the bottom of the conversation.
 *
 * The view above this was read-only when it shipped, and that made chat mode a
 * detour: read the answer here, go back to the terminal to type one line. The
 * desktop's own chat view has taken `onSend` since it was built
 * (`src/renderer/components/ChatComposer.tsx`), and this is the same act on a
 * phone.
 *
 * ## One channel, which is the session's own pty
 *
 * The message is written into the terminal exactly as if it had been typed
 * there, because that IS where the agent is listening — chat mode is a different
 * view of one session, not a second channel. So there is no second transport to
 * keep in step, and a reply sent here appears in the terminal view too.
 *
 * **It cannot be one write.** The CLI classifies each stdin chunk before it
 * looks at the keys in it, and a chunk of 64 bytes or more is *pasted text*,
 * where a carriage return is a newline rather than submit — measured through a
 * real pty: 57 bytes in one write submits, 64 does not. `terminalWrites` is that
 * sequence and it is imported rather than restated, so the two composers in this
 * product cannot come apart on the one rule that decides whether a send button
 * works at all.
 *
 * ## The keyboard, and the strip under it
 *
 * The field grows to six rows and no further; past that it scrolls, because a
 * composer that can eat the conversation is a composer that hides what is being
 * answered. The row carries `--dock-safe` for the home indicator, the same
 * variable the key bar uses and which main.ts zeroes while the keyboard is up —
 * the keyboard already covers that strip and paying for it twice lifts the row
 * off the keys by a visible third of a key.
 *
 * Enter sends and Shift+Enter breaks the line, which is what every chat app does
 * and what a hardware keyboard on an iPad expects. On a touch keyboard the
 * button is the way, which is why it is a button and not a hint.
 */

const SVG_NS_ARROW = 'http://www.w3.org/2000/svg'

/** The send glyph — an arrow in a circle, the mark this corner carries. */
function sendIcon(): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS_ARROW, 'svg')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('width', '20')
  svg.setAttribute('height', '20')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '2')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('stroke-linejoin', 'round')
  svg.setAttribute('aria-hidden', 'true')
  const circle = document.createElementNS(SVG_NS_ARROW, 'circle')
  circle.setAttribute('cx', '12')
  circle.setAttribute('cy', '12')
  circle.setAttribute('r', '9')
  const shaft = document.createElementNS(SVG_NS_ARROW, 'path')
  shaft.setAttribute('d', 'M12 16V8M8.5 11.5 12 8l3.5 3.5')
  svg.append(circle, shaft)
  return svg
}

export interface ChatComposerDeps {
  /** Write into the session. One call per element of {@link terminalWrites}. */
  write: (data: string) => void
  /** True while the socket is up and a session is attached. */
  live: () => boolean
  /** Test seam for the gap between the two writes. */
  wait?: (ms: number) => Promise<void>
}

export class ChatComposer {
  readonly element = document.createElement('div')
  private readonly field = document.createElement('textarea')
  private readonly button = document.createElement('button')
  private readonly wait: (ms: number) => Promise<void>

  constructor(private readonly deps: ChatComposerDeps) {
    this.wait = deps.wait ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)))
    this.element.className = 'chatc'

    this.field.className = 'chatc__field'
    this.field.rows = 1
    // No placeholder. A field at the foot of a conversation is a field you type
    // in, and a sentence inside it saying so is the furniture this whole review
    // is about removing. The label a screen reader needs is not on screen.
    this.field.setAttribute('aria-label', 'Message')
    this.field.addEventListener('input', () => this.grow())
    this.field.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter' || event.shiftKey || event.isComposing) return
      event.preventDefault()
      void this.send()
    })

    this.button.className = 'chatc__send'
    this.button.type = 'button'
    this.button.setAttribute('aria-label', 'Send')
    this.button.title = 'Send'
    this.button.append(sendIcon())
    this.button.addEventListener('click', () => void this.send())

    this.element.append(this.field, this.button)
    this.render()
  }

  focus(): void {
    this.field.focus()
  }

  /** Redraw what the socket allows. Called when the connection changes. */
  render(): void {
    const ready = this.deps.live()
    this.field.disabled = !ready
    this.button.disabled = !ready || this.field.value.trim() === ''
  }

  private grow(): void {
    // Measured from the content rather than counted in characters: a wrapped
    // line is as tall as a typed one and a character count cannot see the wrap.
    this.field.style.height = 'auto'
    this.field.style.height = `${Math.min(this.field.scrollHeight, 132)}px`
    this.render()
  }

  private async send(): Promise<void> {
    const typed = this.field.value.trim()
    if (typed === '' || !this.deps.live()) return
    // Cleared first. The two writes below are a round trip apart, and a field
    // that emptied on the second would let a fast second Enter send the same
    // message twice.
    this.field.value = ''
    this.grow()
    const [body, submit] = terminalWrites(typed)
    this.deps.write(body)
    await this.wait(SUBMIT_GAP_MS)
    this.deps.write(submit)
  }
}
