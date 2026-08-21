import { useLayoutEffect, useRef, useState } from 'react'
import { readMachineTabId } from '../shell/workspace-tabs'
import { attachableSessions, readSessions, resolveAgentSessions } from './agent-target'
import { useSessionBinding, useWindowBinding, type BoundWindowView } from './binding-view'

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
 *
 * A shell on a **server** is the third case and it cannot be read out of the id
 * at all. `serverTabId` joins the server with `shellKey`, which is this window's
 * handle minted before the shell exists; the id main knows it by is the far
 * end's, and it arrives on `servers:shell:open`. So it rides on the tab — see
 * `WorkspaceTab.server` — and a shell whose id has not come back yet falls
 * through to the local shape, finds no binding, and draws no chip, which is the
 * truth for a shell that cannot have one yet.
 */
export function bindKey(tab: {
  id: string
  server?: { id: string; sessionId?: string }
}): { sessionId: string; machineId: string } {
  const remote = readMachineTabId(tab.id)
  if (remote) return remote
  if (tab.server?.sessionId) return { sessionId: tab.server.sessionId, machineId: tab.server.id }
  return { sessionId: tab.id, machineId: '' }
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
 * The same link with a stroke through it — the corner-to-corner "off" slash.
 *
 * Drawn over {@link LINK} rather than as a separate broken-chain shape, because
 * the two buttons sit side by side and the pair has to read as one subject: the
 * link, and the link cancelled. A different chain drawn a different way at 13px
 * is two glyphs somebody has to compare.
 */
const UNLINK_SLASH = 'M4 20L20 4'

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
 * ## Why Disconnect is a second button and not another menu row
 *
 *   > *"When we connect any browser, and we should be have a button here to
 *   > disconnect also, or it should only this way."*
 *
 * There was a way out and it was a gesture: re-click the ticked row in the
 * checklist this button pops. On the window he filmed, nothing was ticked at
 * all — the page was being driven and attached to no session — so the only exit
 * was invisible *and* unreachable. A verb that exists only as the second press
 * of a checkbox is a verb nobody finds.
 *
 * So the pair: `B1` opens the relation's menu, and the button beside it ends it,
 * in one press, from the place he was already looking. It appears only while
 * something is attached, which is the standing rule on this bar — a control that
 * cannot do anything is not drawn — and it goes out on `browser:unbind`, which
 * lands on the same `disconnect` in `browser-binding-ipc.ts` that the menu's own
 * `Disconnect` row runs, so the two doors do the same amount of work. Ending the relation ends the drive with it,
 * which is what makes this control the whole answer to "is this browser
 * connected".
 *
 * It wears a one-word hover like every other glyph on this bar and spells the
 * window out for a screen reader, which is the same bargain `Inspect`, `Record`
 * and `Shot` make three buttons along.
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

  const connect = (
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
            // Only the rows this menu can honour. A session whose process has
            // exited and a shell on a server would both take the tick and be
            // attached to nothing — see `attachableSessions`, which holds the
            // rule and both reasons.
            sessions: attachableSessions(sessions).map((session) => ({
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

  if (slot === '') return connect

  return (
    <span className="bind-control">
      {connect}
      <button
        type="button"
        className="bind-button"
        data-detach=""
        title="Disconnect"
        /* The window, for a reader who has neither the glyph nor the `B1`
           beside it — the same argument the button above makes about its own
           name. */
        aria-label={`Disconnect ${slot}`}
        onClick={() => {
          const deck = (window as unknown as { deck?: Record<string, unknown> }).deck
          const unbind = deck?.browserUnbind as ((tabId: string) => void) | undefined
          // Nothing at all on a preload without the channel, rather than a
          // button that looks like it worked. The relation is main's, and a
          // renderer that cannot reach main cannot end one.
          unbind?.(browserTabId)
        }}
      >
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
          <path d={UNLINK_SLASH} />
        </svg>
      </button>
    </span>
  )
}


/* ----------------------------------------------- which computer, moved -- */

/*
 * `WindowMachineMark` was here and is deleted — 2026-08-20.
 *
 * It was a 12px display glyph on a browser tab whose `title` held the name of
 * the machine serving the page, and it was this app's answer to:
 *
 * > *"if I open any browser here and if I connect it to, let's say, desktop, now
 * > this is in desktop, it should come under this table, under the desktop
 * > sessions. So all the desktop browser, including session, should be at one
 * > place."*
 *
 * It was not that answer. A tooltip is not a place, and a mark on one tab says
 * nothing about the session two tabs along that runs on the same machine — so
 * the audit found the fact still reachable only by hovering, and nothing at all
 * showing a machine's sessions and its windows together.
 *
 * The strip grouped its tabs by machine for a few hours and then stopped, by
 * name: *"We don't need any kind of separation like this for the device on the
 * top with the name… This was actually for the side panel only, but not for the
 * top bar."* So the rail keeps the grouping and the strip puts the machine on
 * each tab's own hover — `whereRuns` in `WorkspaceTabStrip.tsx`, beside the
 * `tabTooltip` that already answered it for a session. The store it read from —
 * `window-machine.ts` — is unchanged, and is what that hover reads.
 */
