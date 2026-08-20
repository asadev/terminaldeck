import { useLayoutEffect, useRef, useState } from 'react'
import { readMachineTabId } from '../shell/workspace-tabs'
import { readSessions, resolveAgentSessions } from './agent-target'
import { useSessionBinding, useWindowBinding, type BoundWindowView } from './binding-view'
import { useWindowMachine } from './window-machine'

/**
 * The mark that says a browser window belongs to a session — `B1`, `B2`.
 *
 * ## Why it is a chip with a glyph in it and never a dot
 *
 * Both dot vocabularies in the places this is drawn are already spoken for, and
 * a third would be one dot too many rather than one dot more. `StatusDot` is
 * 7px, carries six run states, and its own header says *"Colour alone never
 * carries the meaning"*. The account dot is a round-robin over six tokens whose
 * header says the colour *"means nothing on its own"*. And `WorkspaceTabStrip`
 * refused a browser dot outright, in as many words: *"A browser page has no
 * status and gets no mark, rather than a grey one that means nothing."*
 *
 * That refusal is right and this passes it, because a chip reading `B2` means
 * something without the colour: the number is the fact, and the colour only
 * says which session's numbering it belongs to. A chip with a number in it also
 * cannot be mistaken for a 7px dot at a glance, which is what stops the strip
 * growing a third mark people have to learn.
 *
 * ## Nothing attached is drawn as nothing
 *
 * Not a grey chip, not `B—`. `useSessionBinding` answers null rather than an
 * empty binding for exactly this, and every component below returns `null` on
 * it. A placeholder here would put a mark on every session in the rail to say
 * that nothing has happened, which is the same failure the refused browser dot
 * was.
 *
 * ## Two, then a count
 *
 * A rail row and a 24-character pill both run out of room, and the thing that
 * must never be the first to give is the session's own name — the same rule the
 * account chip already loses to. So two chips, then `+N`, whose tooltip names
 * every window the count stands for so nothing is hidden behind it.
 */

/**
 * The two handles a binding is keyed on, taken off a tab id.
 *
 * A local session's tab id *is* its session id; a session on another machine
 * wears a `machine <id> <session>` tab id instead, and the binding is keyed on
 * the pair rather than the composite — main knows nothing about how this window
 * spells its tab ids. One helper because the strip and the rail both need it
 * and two spellings of an id split is how one of the two surfaces quietly stops
 * finding any binding at all.
 */
export function bindKey(tab: { id: string }): { sessionId: string; machineId: string } {
  const remote = readMachineTabId(tab.id)
  return remote ?? { sessionId: tab.id, machineId: '' }
}

/** How many chips are drawn before the rest become a count. */
const CHIPS_SHOWN = 2

/**
 * How many of those chips there is *room* for, on this row, right now.
 *
 * ## The defect
 *
 * Asad filmed `B1`/`B2` painting over a tab's ✕. That was answered with
 * `overflow: hidden` on the tab's face, and answering it that way produced the
 * next thing he would have filmed: the chips stopped overlapping and started
 * being **sliced**. At ordinary window widths a tab read `Sess… B1 B` with two
 * pixels of a second chip against the ✕, and on a session with eight windows
 * the tab showed `B1` and nothing else — the `+7` that is the only mark saying
 * windows are missing was itself the first thing clipped away. A row that is a
 * fraction of the truth and does not say so is worse than one that overlaps.
 *
 * So a chip is either drawn whole or not drawn, and what it turns into is the
 * count — which grows to cover whatever was dropped, so the number on screen is
 * true at every width.
 *
 * ## Why it measures rather than guessing
 *
 * The room a chip has depends on the tab's width, the length of the session's
 * name and the qualifier beside it, none of which this component knows. It
 * reads `scrollWidth > clientWidth` — the browser's own answer to "is this
 * clipped" — and drops one chip at a time until the answer is no.
 *
 * ## Why the parent's width is the reset key, and why this cannot oscillate
 *
 * Dropping a chip makes this box narrower, which lets the qualifier beside it
 * grow back, which changes how much room this box has — a loop, if the loop
 * were allowed to run both ways. It is not: within one width of the row, the
 * count only ever goes **down**, so it settles in at most two extra frames. The
 * only thing that puts the dropped chips back is the row itself changing size,
 * and the row's width is set by the strip and by the window, neither of which
 * this box can move. That is the whole reason the observer watches the *parent*
 * rather than this element.
 */
function useChipFit(total: number, floor: number): {
  ref: React.RefObject<HTMLSpanElement | null>
  shown: number
} {
  const ref = useRef<HTMLSpanElement | null>(null)
  // The row's width, as a version number. Bumped only when it actually changes,
  // so a resize that does not move this row costs nothing.
  const [gauge, setGauge] = useState(0)
  const [fit, setFit] = useState({ gauge: 0, drop: 0 })
  const drop = fit.gauge === gauge ? fit.drop : 0
  const cap = Math.min(total, CHIPS_SHOWN)
  const shown = Math.max(floor, cap - drop)

  useLayoutEffect(() => {
    const parent = ref.current?.parentElement
    if (!parent || typeof ResizeObserver === 'undefined') return
    let last = -1
    const observer = new ResizeObserver(() => {
      const width = parent.clientWidth
      if (width === last) return
      last = width
      setGauge((n) => n + 1)
    })
    observer.observe(parent)
    return () => observer.disconnect()
  }, [])

  // Deliberately without a dependency list: the question is about the pixels
  // this render produced, and it has to be asked again after every one of them.
  // It only ever writes state when something is clipped, so a settled row is a
  // measurement and nothing else.
  useLayoutEffect(() => {
    const el = ref.current
    if (!el || shown <= floor) return
    if (el.scrollWidth > el.clientWidth + 0.5) setFit({ gauge, drop: drop + 1 })
  })

  return { ref, shown }
}

/** What a window is called, using only what it has told us about itself. */
function windowName(window: BoundWindowView): string {
  // A window that has not reported a title or an address has only just been
  // created. "a browser window" is the honest description of it; inventing a
  // name here would put a page title in a tooltip that no page ever had.
  return window.title || window.url || 'a browser window'
}

/** `B2 — Stripe Dashboard`, plus the session when the caller knows its name. */
function chipTooltip(window: BoundWindowView, sessionName: string | null): string {
  const head = `B${window.n} — ${windowName(window)}`
  return sessionName ? `${head} · attached to ${sessionName}` : head
}

interface ChipProps {
  n: number
  /** 0–3, straight from the binding. Drawn through `--bind-1 … --bind-4`. */
  colour: number
  tooltip: string
}

function Chip({ n, colour, tooltip }: ChipProps) {
  return (
    <span
      className="bind-chip"
      /*
       * The colour as an attribute rather than an inline custom property.
       *
       * Four rules in the stylesheet, no `style` object and no cast through
       * `CSSProperties` to smuggle a `--var` past TypeScript. It also keeps the
       * palette entirely in `tokens.css`, which is where `tokens.test.ts` can
       * see it — a colour written into a component is the copy-drifts failure
       * that whole test file exists for.
       */
      data-bind={(colour % 4) + 1}
      title={tooltip}
      aria-label={tooltip}
    >
      B{n}
    </span>
  )
}

interface SessionChipsProps {
  sessionId: string
  /** Empty for a session on this machine. */
  machineId?: string
  /** What to call the session in the tooltip, or null when the caller cannot say. */
  sessionName?: string | null
}

/** Every window attached to one session: `B1 B2 +3`, or nothing at all. */
export function SessionBindChips({ sessionId, machineId = '', sessionName = null }: SessionChipsProps) {
  const binding = useSessionBinding(sessionId, machineId)
  // A session with one window has nothing to fall back to: `+1` in place of
  // `B1` is the same 20 pixels wide and says less, so the last chip stays even
  // where it has to be tight. Every other case can hand its chips to the count.
  const total = binding?.windows.length ?? 0
  const { ref, shown: room } = useChipFit(total, total > 1 ? 0 : 1)
  if (!binding) return null

  const shown = binding.windows.slice(0, room)
  const rest = binding.windows.slice(room)

  return (
    <span className="bind-chips" ref={ref}>
      {shown.map((window) => (
        <Chip
          key={window.browserTabId}
          n={window.n}
          colour={binding.colour}
          tooltip={chipTooltip(window, sessionName)}
        />
      ))}
      {rest.length > 0 && (
        <span
          className="bind-chip"
          data-bind={(binding.colour % 4) + 1}
          data-more=""
          // Every window the count stands for, by name. A `+3` that cannot be
          // read is a number the person has to open a menu to understand.
          title={rest.map((window) => chipTooltip(window, sessionName)).join('\n')}
          aria-label={`${rest.length} more browser ${
            rest.length === 1 ? 'window' : 'windows'
          } attached: ${rest.map((window) => `B${window.n}`).join(', ')}`}
        >
          +{rest.length}
        </span>
      )}
    </span>
  )
}

interface WindowChipProps {
  /** The shell tab id of a browser window — `browser:<epoch-ms>:<seq>`. */
  browserTabId: string
  /**
   * What the session holding this window is called, looked up by the caller.
   *
   * A function rather than a string because the caller has the tab list and
   * this component has an id, and neither can do the other's half: the binding
   * knows *which* session, the strip and the rail know what that session is
   * called. Returning null is allowed and means the tooltip says the window and
   * not the session — better than printing a raw session id at somebody.
   */
  nameFor?: (sessionId: string, machineId: string) => string | null
}

/** The one chip a browser window wears, or nothing when it is attached to nothing. */
export function WindowBindChip({ browserTabId, nameFor }: WindowChipProps) {
  const found = useWindowBinding(browserTabId)
  if (!found) return null
  const { session, window } = found
  const name = nameFor?.(session.sessionId, session.machineId) ?? null
  const tooltip = session.ended
    ? // The session behind this page has exited, and saying so is the reason
      // the binding is kept rather than dropped on exit: a window that goes
      // quietly anonymous cannot explain the page still on screen.
      `B${window.n} — ${name ?? 'the session this page belongs to'} has exited. This is what it was looking at.`
    : chipTooltip(window, name)
  return (
    <span className="bind-chips">
      <Chip n={window.n} colour={session.colour} tooltip={tooltip} />
    </span>
  )
}

/* --------------------------------------------------- the other direction -- */

/** A chain link, in the same 24×24 grid the rest of this window is drawn on. */
const LINK =
  'M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7'

/**
 * Which session this browser window belongs to — asked from the browser.
 *
 * ## Why this exists
 *
 * > *"from the browser directly, I cannot connect to any session. It should be
 * > either here or somewhere. So I can actually directly choose a session to
 * > connect to the browser instead of from session to a browser. Both sides
 * > should be the option."*
 *
 * The relation could only be made from the session's end — the rail's ⋯ menu and
 * the pane bar's button — which is the wrong end whenever the thing you are
 * looking at is the page. This is the same relation from here.
 *
 * ## One relation, not a second model
 *
 * It holds no state. The menu is built in the main process out of the one
 * binding map, so a window ticked here is ticked in the rail in the same frame.
 * Two spellings of "which windows are attached" is how the pane bar and the rail
 * came to disagree about the same window before this was one map.
 *
 * ## Why the sessions are read on the press
 *
 * Not held in state and not refreshed on a timer. Asad, of the other picker in
 * this window: *"It's not updated right away. Anyways, maybe we need to
 * refresh."* A list read at the moment the menu is asked for cannot be stale,
 * and one IPC round trip is cheaper than a subscription that has to be right.
 *
 * ## Why the label is the slot and not a word
 *
 * `B1` when it is attached, because that is the name the agent was given and the
 * name he says out loud; the glyph alone when it is not.
 *
 * ## And why the hover is one word
 *
 *   > *"when I hover, it should show the title, like shade, inspect, record.
 *   > Instead of this line, show only the name … but not these full lines."*
 *
 * Said of the bar this button sits on, and every other control on it obeys:
 * `Inspect`, `Record`, `Shot`, `Draw`, `Size`, `Devtools`, `More`. This one
 * answered with five words and 191 pixels — four times the widest label beside
 * it, wide enough to cover the tab title above — which made the newest glyph on
 * the bar the one most likely to be hovered and the only one that replied with a
 * sentence. The verb, the slot and the offer to detach are all in the menu it
 * opens, which is a place a sentence can be read rather than glimpsed.
 */
export function ConnectSessionButton({ browserTabId }: { browserTabId: string }) {
  const found = useWindowBinding(browserTabId)
  const slot = found ? `B${found.window.n}` : ''

  return (
    <button
      type="button"
      className="bind-button"
      data-attached={slot !== '' || undefined}
      data-bind={found ? (found.session.colour % 4) + 1 : undefined}
      title="Session"
      /* Not the hover text. `Tooltips.tsx` draws the `title`, and a screen
         reader has neither the glyph nor the `B1` beside it to go on — so the
         name it computes says which of the two states this is. */
      aria-label={slot === '' ? 'Attach to a session' : `Attached to ${slot}`}
      onClick={() => {
        const deck = (window as unknown as { deck?: Record<string, unknown> }).deck
        const api = resolveAgentSessions(deck)
        const show = deck?.showBrowserConnectMenu as
          | ((request: {
              tabId: string
              sessions: { sessionId: string; machineId?: string; name: string; machineName?: string }[]
            }) => Promise<boolean>)
          | undefined
        if (!show) return
        const pop = (sessions: ReturnType<typeof readSessions>): void => {
          void show({
            tabId: browserTabId,
            // A session whose process has exited is left out rather than listed
            // and refused: attaching a window to a dead pty makes a relation
            // nothing can ever act on, and the rail already keeps the row that
            // explains where it went.
            sessions: sessions
              .filter((session) => !session.ended)
              .map((session) => ({
                sessionId: session.id,
                machineId: session.machineId,
                name: session.label,
                machineName: session.machineName,
              })),
          })
        }
        if (!api) {
          pop([])
          return
        }
        api
          .listSessions()
          .then((value) => pop(readSessions(value)))
          // A list that could not be read still opens the menu, which says there
          // are none. A press that does nothing at all is the defect this whole
          // round is about.
          .catch(() => pop([]))
      }}
    >
      {slot !== '' && <span className="bind-button-label">{slot}</span>}
      <svg
        width="13"
        height="13"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        <path d={LINK} />
      </svg>
    </button>
  )
}


/* ------------------------------------------------------- which computer -- */

/**
 * The mark a browser window wears when its page is **not** on this computer.
 *
 * ## What he asked for, and why this is where it ended up
 *
 * > *"if I open any browser here and if I connect it to, let's say, desktop, now
 * > this is in desktop, it should come under this table, under the desktop
 * > sessions. So all the desktop browser, including session, should be at one
 * > place."*
 *
 * He asked for a grouping in the sidebar, and later in the same recording he
 * emptied the sidebar of browser windows: *"Browser windows will not be on the
 * side bar at all. They will be always only on the top bar."* Both instructions
 * are his, both are load-bearing, and there is exactly one arrangement that
 * honours the pair — the top bar has to carry the machine, because after the
 * second instruction it is the only surface a browser window appears on.
 *
 * Without this, it appeared on none. The main process was told which machine
 * every window is on and grouped them under machine headings in its two native
 * menus; the renderer was never told, so the strip drew a page running on his PC
 * identically to one running here and the only way to find out was to open a
 * menu. *"Now I don't know if it is actually there or here."*
 *
 * ## A glyph, and the name on hover — not the name on the tab
 *
 * A strip tab has 22 characters for a title (`STRIP_LABEL_BUDGET`) and is
 * already shedding chips into a count to fit what it has. Spending eight of
 * those characters on `office-pc` would cost the thing that actually tells two
 * tabs apart. So the tab says *not here* in one glyph, and *where* in the hover
 * — which is the same trade the strip already makes for a remote session, whose
 * machine lives only in `tabTooltip`.
 *
 * ## Why a session's pill wears no such mark and this one does
 *
 * `WorkspaceTabStrip` decided deliberately that a remote session's pill looks
 * exactly like a local one, because the complaint it was answering was that
 * remote work looked like a foreign kind of thing. That still holds — and a
 * session has somewhere else to say it: the rail groups sessions under their
 * machine, with a heading. A browser window has nowhere else at all. The
 * asymmetry is not two rules; it is one rule (*the machine is stated exactly
 * once, somewhere you are already looking*) landing in different places for two
 * things that are listed in different places.
 *
 * ## Nothing at all for a window on this computer
 *
 * `useWindowMachine` answers null for it, and null draws nothing — the same
 * bargain as every other mark in this file. A glyph on every tab saying "here"
 * is the placeholder that puts a mark on every row to report that nothing has
 * happened, which is what the refused browser status dot was.
 */
export function WindowMachineMark({ browserTabId }: { browserTabId: string }) {
  const machine = useWindowMachine(browserTabId)
  if (!machine) return null
  const name = machine.name || machine.id
  return (
    <span className="tab-machine-mark" title={name} aria-label={`on ${name}`}>
      {/*
        A display, and the same one the machine picker and the sidebar's machine
        rows draw. One idea, one shape — a second glyph for "a computer that is
        not this one" would be a second thing to learn about the same fact.
      */}
      <svg
        width="12"
        height="12"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        <rect x="3" y="4" width="18" height="12" rx="2" />
        <path d="M9 20h6M12 16v4" />
      </svg>
    </span>
  )
}
