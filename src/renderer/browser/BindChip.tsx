import { readMachineTabId } from '../shell/workspace-tabs'
import { readSessions, resolveAgentSessions } from './agent-target'
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
 */
export function bindKey(tab: { id: string }): { sessionId: string; machineId: string } {
  const remote = readMachineTabId(tab.id)
  return remote ?? { sessionId: tab.id, machineId: '' }
}

/** How many chips are drawn before the rest become a count. */
const CHIPS_SHOWN = 2

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
  if (!binding) return null

  const shown = binding.windows.slice(0, CHIPS_SHOWN)
  const rest = binding.windows.slice(CHIPS_SHOWN)

  return (
    <span className="bind-chips">
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
 * name he says out loud; the glyph alone when it is not. The tooltip carries the
 * verb — there is no room on this bar for a sentence, and none is wanted.
 */
export function ConnectSessionButton({ browserTabId }: { browserTabId: string }) {
  const found = useWindowBinding(browserTabId)
  const slot = found ? `B${found.window.n}` : ''
  const tooltip = slot
    ? `${slot} — attached to a session. Choose another, or detach.`
    : 'Attach this window to a session'

  return (
    <button
      type="button"
      className="bind-button"
      data-attached={slot !== '' || undefined}
      data-bind={found ? (found.session.colour % 4) + 1 : undefined}
      title={tooltip}
      aria-label={tooltip}
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
