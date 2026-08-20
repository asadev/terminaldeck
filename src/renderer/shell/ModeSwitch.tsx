import type { ReactNode } from 'react'
import './ModeSwitch.css'

/**
 * The two controls in the top-right of the window: what the window is doing.
 *
 * It replaces four separate things that had accumulated up there — a
 * Terminal/Chat segmented control, a swarm button, a session-details button and
 * a command-palette button — which is a toolbar that had become a shelf. Three
 * of those four are not modes at all: they open a dialog, or a page. Only the
 * first was ever answering the question the top-right of a window is for.
 *
 * ## Why it is two icons and no longer a row of three words
 *
 * It was a segmented control reading `Terminal | Chat | Split`, and Asad, on a
 * screen recording:
 *
 *   > *"instead of terminal chat being with the pill we can give one icon switch
 *   > if we click on it it will show terminal icon if we click on it then it
 *   > will show chat icon and the same time it will switch the window type also
 *   > split can have its own one button to make it split and separate one button
 *   > so total two buttons may be two icons may be only"*
 *
 * He is describing the arrangement the state model already had and the control
 * was hiding. Terminal and Chat are two answers to *one* question — how this
 * session is drawn — and they are held per session in `sessionView`. Split is a
 * different question with its own state (`panes`), asked of the window rather
 * than of a session. Three equal segments said the three were one choice of
 * three, which is why the control had to be as wide as three words to be read
 * at all.
 *
 * So: one button that flips between the two views, and one button that turns the
 * split on and off. The row went from about 180 pixels to about 50, which the
 * session controls beside it get to keep — `control-room.ts` measures whatever
 * else is on the bar and hands the remainder to the chip cluster, so the saving
 * lands without a number being written down anywhere.
 *
 * ## Which icon the toggle shows — he chose, on 2026-08-20
 *
 * A button whose icon changes is the most-misread shape in interface design,
 * because there are two honest conventions and they are exact opposites: show
 * the state you are in (a muted speaker means "muted"), or show the state one
 * press away (a play triangle means "press to play"). Get it wrong and every
 * press is a coin flip.
 *
 * **This one shows the destination — the mode a press produces.** It shipped
 * the other way, arguing that the top-right of a window answers *"what am I
 * looking at"* and that the pane is right there to check the icon against. That
 * argument is not wrong; it is simply not the one he wants, and he settled it
 * looking at the running app:
 *
 *   > *"chat icon should be when I am on the terminal mode. And when I am on
 *   > the chat mode, then it should show the terminal icon, so I can switch to
 *   > that one. Instead of what I am on right now, that one shows."*
 *
 * Which is the stronger reading anyway, once the words are gone: the pane below
 * already says what you are looking at, in the loudest way an interface can —
 * by being it. A 15-pixel glyph repeating that fact is spending the only signal
 * this control has on the one question the user never has to ask. What they do
 * ask is *where does this take me*, and now the icon answers it.
 *
 * The convention still cannot carry the meaning on its own, so it does not have
 * to: the accessible name and the tooltip are one string that names **both**
 * halves — `Terminal — press to show this session as Chat`. That sentence is
 * correct under either reading, and it is deliberately unchanged by the flip,
 * so a person who guessed the other convention is corrected by hovering rather
 * than by pressing.
 *
 * ## Why Split is a toggle and not a third icon in the same row
 *
 * Because the renderer cannot draw a third mode. `renderPane` in `App.tsx`
 * mounts a `TerminalView` for every pane that holds a session — there is no
 * chat inside a split, and there is no state in this app in which "split" and
 * "chat" are both true. Split is therefore on or off, it carries `aria-pressed`
 * to say which, and its icon never changes: one frame divided down the middle,
 * whichever mode is underneath.
 *
 * Turning it off returns to the session's own view rather than to a fixed
 * `terminal`, which is why {@link ModeSwitchProps.view} exists. A split that
 * only ever collapsed into a terminal would silently rewrite the preference of
 * anybody who splits while reading a chat.
 */

/** How a single session is shown. Held per session, because it is a preference
    about that conversation rather than about the window. */
export type SessionViewMode = 'terminal' | 'chat'

/**
 * What fills the window.
 *
 * `split` is not a third way of showing one session — it is several sessions at
 * once — which is why it is in this union rather than in `SessionViewMode`. The
 * two are joined here, at the control, because to the person using the app they
 * are one question with three answers.
 */
export type WorkspaceMode = SessionViewMode | 'split'

export interface ModeSwitchProps {
  mode: WorkspaceMode
  /**
   * How the *focused session* is drawn, whether or not the window is split.
   *
   * `mode` collapses to `'split'` the moment there are panes, so on its own it
   * cannot say what leaving the split should show, and it cannot label the view
   * toggle while a split is up. This is the same value `mode` falls back to when
   * `splitting` is false, read straight out of `sessionView` — not a second
   * piece of state, and not this component remembering what it last saw, which
   * would be a guess dressed up as a fact.
   *
   * Optional so that the tests and boards that mount this component with two
   * props keep working; absent, an unsplit control reads it off `mode` and a
   * split one assumes `terminal`, which is the default every session starts at.
   */
  view?: SessionViewMode
  onChange(mode: WorkspaceMode): void
  label?: string
  /**
   * Draw Split as an offer rather than as a mode, because the feature is not
   * installed.
   *
   * This is the one place split view would have been, so it is the one place
   * worth offering it — a store that quietly removes a control teaches people
   * the app cannot do the thing, which is the failure a feature store actually
   * causes. The button is not dead: pressing it still asks for split, and the
   * window above installs the feature and splits, so the confirmation of where
   * to find it is the thing appearing under the pointer.
   */
  splitOffer?: boolean
  /**
   * Modes that cannot act here, each with the sentence saying why.
   *
   * ## Why a refusal rather than an absence, which is this product's usual rule
   *
   * The rule is *"a control that appears and does nothing is worse than one that
   * is absent"*, and a mode listed here does not do nothing — it refuses, out
   * loud, with a reason. That is the same shape `blockedFor` gives the model and
   * effort chips one bar over, and the distinction is that a *dead* control is
   * silent about being dead.
   *
   * It exists because the whole switch used to vanish over a session on a paired
   * machine or a terminal on a server, and vanishing was the wrong answer for the
   * mode that works: Terminal is exactly what those sessions are already
   * showing, so the control was withdrawn while one of its three answers was
   * live. Asad's complaint about the bar over remote sessions was that things
   * were missing without explanation, and an empty stretch of toolbar cannot tell
   * "not built" from "not possible".
   *
   * Keyed by mode rather than by a boolean per button so the *reason* is
   * unavoidable: there is no way to disable one of these without writing the
   * sentence a person reads when they press it.
   *
   * Two icons rather than three segments does not weaken any of that, because
   * the entries are matched to the mode a press would *produce*: the toggle
   * wears `unavailable.chat` while it is showing Terminal, since Chat is where
   * pressing it goes. A disabled icon with no explanation would be worse than
   * the disabled word it replaces — there is no label left to read.
   */
  unavailable?: Partial<Record<WorkspaceMode, string>>
}

/**
 * The terminal mark, borrowed from `workspace-tabs.ts` rather than redrawn.
 *
 * Every session row in the rail and every tab in the strip already wears this
 * prompt-and-underscore, so the toolbar saying "this session is a terminal" with
 * the same shape costs a reader nothing to learn. It is copied rather than
 * imported because `KIND_ICON` is keyed by *tab kind* and this is a *view mode*;
 * the two agree today and there is no reason they must, and an import would make
 * a rename of one silently redraw the other.
 */
const TERMINAL_GLYPH = <path d="M4 17l6-6-6-6M12 19h8" />

/**
 * Chat: a speech bubble with its tail on the left, drawn as one closed path.
 *
 * No lines of text inside it. Three candidates were rendered at the size this is
 * actually drawn — an empty bubble, a bubble with a separate tail, and a bubble
 * with two rules in it for "text" — and at 15 pixels the rules turn to grey mush
 * and the separate tail detaches into a stray tick. The empty outline is the one
 * that still reads as a bubble.
 */
const CHAT_GLYPH = (
  <path d="M20.5 13.8a2.7 2.7 0 0 1-2.7 2.7H9.4L4.7 20v-3.5a2.7 2.7 0 0 1-1.2-2.2V7.2a2.7 2.7 0 0 1 2.7-2.7h11.6a2.7 2.7 0 0 1 2.7 2.7z" />
)

/**
 * Split: one frame, its right half filled.
 *
 * ## The divider was not enough — 2026-08-20
 *
 * *"give a better icon for the… the Split."*
 *
 * It was answered once by keeping the mark and squaring it: a 17 × 13 frame
 * with a hairline down the middle became 17 × 17 with the same hairline. That
 * is not what he asked. Rendered side by side at the 15 pixels this is actually
 * drawn, the before and after are the same three hairlines in a box — a person
 * cannot name the difference, which is the only test a *better icon* has to
 * pass.
 *
 * So the mark changed rather than its proportions. The frame stays — two
 * separate boxes read as two apps, and the panes really do share this window's
 * chrome — but one compartment is now solid. Six candidates were rendered at
 * the real 15px against the row this button sits in (the chevron and `>_`):
 * the divided frame at both heights, two panes with a gutter, and the filled
 * half on either side. The divided frame and the two panes both dissolve —
 * three 1px hairlines and a 3px gutter respectively — while the filled half
 * carries mass and survives all the way down.
 *
 * Mass in a toolbar of outlines was the exact objection that got this rejected
 * the first time, on the grounds it would read as a state (a battery, a
 * contrast dial). It does not, because those are circles and wide horizontal
 * cells; this is a near-square divided vertically, which is the mark VS Code,
 * Xcode and SF Symbols all use for precisely this action, and it is the shape
 * of the thing it does.
 *
 * The right half is the filled one because that is the pane a press produces:
 * what is in front of you stays where it is and a second pane joins it on the
 * right. There is no divider stroke — the boundary is the fill's own edge,
 * which is one less hairline to lose at small sizes.
 */
const SPLIT_GLYPH = (
  <>
    <rect x="3.5" y="3.5" width="17" height="17" rx="3.5" />
    {/* Filled to the frame's own path rather than inset inside it. An inset
        pane needs its own corner radius, and two concentric radii 1 unit apart
        turn into a smudged double edge at 15px; run to the frame and the two
        merge into one solid corner. `stroke="none"` because the shared <svg>
        sets a stroke on everything, and a stroked fill would grow the half by
        0.8 units on three sides and eat the frame. */}
    <path
      d="M12 3.5h5A3.5 3.5 0 0 1 20.5 7v10a3.5 3.5 0 0 1-3.5 3.5h-5z"
      fill="currentColor"
      stroke="none"
    />
  </>
)

const VIEW_GLYPH: Record<SessionViewMode, ReactNode> = {
  terminal: TERMINAL_GLYPH,
  chat: CHAT_GLYPH,
}

/** What each view is called in the sentence on the control. */
const VIEW_NAME: Record<SessionViewMode, string> = { terminal: 'Terminal', chat: 'Chat' }

/**
 * One glyph, on the toolbar's own grid.
 *
 * 15 pixels on a 24-unit box at 1.6 stroke, which sits between the session
 * controls' 1.8 and the rail's 1.5 — the two icon families this control is drawn
 * between. Nothing here is imported from an icon package for the reason
 * `SessionControls.tsx` gives about its own dismiss cross: one vocabulary in one
 * toolbar, and a package would be a second.
 */
function Glyph({ children }: { children: ReactNode }) {
  return (
    <svg
      className="ms-glyph"
      width="15"
      height="15"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  )
}

export function ModeSwitch({
  mode,
  view,
  onChange,
  label = 'What this window is showing',
  splitOffer = false,
  unavailable,
}: ModeSwitchProps) {
  const split = mode === 'split'
  /* What the session is drawn as, which is `mode` itself unless a split has
     collapsed it. See `view` for why the fallback is a default rather than a
     memory of what this component last rendered. */
  const shown: SessionViewMode = view ?? (split ? 'terminal' : mode)
  const other: SessionViewMode = shown === 'terminal' ? 'chat' : 'terminal'

  /* The toggle is refused by its *destination*, because that is the only mode a
     press can produce. Over a remote session it is Chat that cannot be drawn, so
     the button showing Terminal is the one carrying Chat's sentence. */
  const viewBlocked = unavailable?.[other] ?? null

  /*
   * A refusal only ever applies to *entering* a split.
   *
   * `unavailable.split` says this window's panes cannot hold what is in front of
   * you — a session on another machine is a window, not a pane — and none of
   * that is an argument against leaving a split you are already in. Blocking the
   * pressed state as well would be the one outcome a refusal must never produce:
   * a person shut inside a layout with the way out greyed.
   */
  const splitBlocked = split ? null : unavailable?.split ?? null
  /*
   * A refusal outranks the offer. A button that is both not installed and not
   * possible here is not an install anybody should be invited to make: pressing
   * it would put the feature in the store and still not do the thing under the
   * pointer.
   */
  const offered = splitBlocked === null && !split && splitOffer

  /*
   * One string per button, used as both the accessible name and the tooltip.
   *
   * It names the state *and* what pressing does, in that order, which is the
   * thing that makes an icon-only toggle safe: whichever convention a reader
   * assumes, the sentence corrects them before they press. There is no visible
   * label left to carry any of this.
   */
  const viewName = viewBlocked
    ? `${VIEW_NAME[shown]} — cannot show this session as ${VIEW_NAME[other]}. ${viewBlocked}`
    : split
      ? `${VIEW_NAME[shown]} — press to leave the split and show this session as ${VIEW_NAME[other]}`
      : `${VIEW_NAME[shown]} — press to show this session as ${VIEW_NAME[other]}`
  /* A refusal names the *act*, not the mode, because the sentences these are
     given already start with the mode's own name — `Split arranges this
     window's own panes…` — and `Split — Split arranges…` is a stutter a screen
     reader has to read out loud. */
  const splitName = splitBlocked
    ? `Cannot split this window. ${splitBlocked}`
    : offered
      ? 'Split — two sessions side by side, not installed. Press to install it.'
      : split
        ? `Split — press to show ${VIEW_NAME[shown]} on its own again`
        : 'Split — show two sessions side by side'

  return (
    <div className="mode-switch" role="group" aria-label={label}>
      <button
        type="button"
        className={`ms-icon${viewBlocked !== null ? ' ms-blocked' : ''}`}
        /*
         * No `aria-pressed` on this one, and that is deliberate rather than an
         * omission. It is not on or off — it is one of two named views — and a
         * pressed state would have a screen reader announce "Terminal, not
         * pressed" for a control that is fully doing its job. The name says
         * which view is on; the button beside it, which really is on or off,
         * carries the pressed state.
         */
        aria-disabled={viewBlocked !== null || undefined}
        aria-label={viewName}
        title={viewName}
        onClick={() => {
          if (viewBlocked !== null) return
          onChange(other)
        }}
      >
        {/* The destination, not the state — see the note at the top of this
            file for the sentence that chose it. `other` is exactly what the
            press produces, and it is the same value the refusal above is keyed
            on, so a blocked toggle draws the mode it is refusing to go to. */}
        <Glyph>{VIEW_GLYPH[other]}</Glyph>
      </button>

      <button
        type="button"
        className={`ms-icon${split ? ' ms-on' : ''}${offered ? ' ms-offer' : ''}${splitBlocked !== null ? ' ms-blocked' : ''}`}
        // The window's one mark for "this is available, press to add it",
        // shared with the globe in the sidebar and the microphone in the chat
        // box (`[data-offer]` in app.css). It replaces dimming the control,
        // which said the opposite of what was meant.
        data-offer={offered || undefined}
        aria-pressed={split}
        // Announced as disabled rather than *being* disabled, because a
        // `disabled` button is skipped by the keyboard and does not raise a
        // tooltip on hover — so the sentence explaining the refusal would be
        // reachable only by a pointer, and only by one that happened to stop.
        // The click is refused below instead.
        aria-disabled={splitBlocked !== null || undefined}
        aria-label={splitName}
        title={splitName}
        onClick={() => {
          if (splitBlocked !== null) return
          // Leaving a split hands back the session's own view, so a split taken
          // while reading a chat does not collapse into a terminal.
          onChange(split ? shown : 'split')
        }}
      >
        <Glyph>{SPLIT_GLYPH}</Glyph>
      </button>
    </div>
  )
}
