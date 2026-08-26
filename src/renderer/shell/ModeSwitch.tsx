import type { ReactNode } from 'react'
import './ModeSwitch.css'

/**
 * The control in the top-right of the window: whether this window is split.
 *
 * ## It was two buttons, and the first one is gone — 2026-08-26
 *
 * > *"we need to remove the chat mode from all of the applications including
 * > Mac Windows and mobile application because I don't think so it can work
 * > smoothly so it's better to completely remove this instead of struggling
 * > with it."*
 *
 * The other button was the Terminal/Chat toggle — a session drawn as a
 * conversation instead of as an emulator. It is not withdrawn here and left
 * alive underneath: `SessionViewMode` is gone, the pane that drew the bubbles is
 * gone, and the two wire verbs that fed it a transcript are gone with it. There
 * is no state left for a control to flip, which is the only honest way to
 * remove a mode — a toggle that quietly always returns the same answer is a
 * mode still shipping, with a lie on top of it.
 *
 * **The copilot's conversation is not this and did not go.** It is a different
 * thing that happens to be drawn with the same bubbles: the rail panel
 * (`CopilotRailPanel`) is the copilot's own surface and reads the copilot's own
 * transcript. What was removed is *a session pretending to be a chat*, which is
 * what never worked.
 *
 * ## Why Split is a toggle rather than a third mode, which is unchanged
 *
 * Because the renderer cannot draw a third mode. `renderPane` in `App.tsx`
 * mounts a `TerminalView` for every pane that holds a session. Split is
 * therefore on or off, it carries `aria-pressed` to say which, and its icon
 * never changes: one frame divided down the middle, whichever session is
 * underneath.
 */

/**
 * What fills the window.
 *
 * `terminal` is a window showing one session; `split` is several at once. It
 * stays a union of two rather than becoming a boolean because that is the shape
 * `onChange` and `unavailable` are keyed on, and because a boolean called
 * `split` on a control called a mode switch reads worse at every call site than
 * the two words do.
 */
export type WorkspaceMode = 'terminal' | 'split'

export interface ModeSwitchProps {
  mode: WorkspaceMode
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
   * machine or a terminal on a server, and vanishing was the wrong answer: an
   * empty stretch of toolbar cannot tell "not built" from "not possible".
   *
   * Keyed by mode rather than by a boolean so the *reason* is unavoidable: there
   * is no way to disable this without writing the sentence a person reads when
   * they press it.
   */
  unavailable?: Partial<Record<WorkspaceMode, string>>
}

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
  onChange,
  label = 'What this window is showing',
  splitOffer = false,
  unavailable,
}: ModeSwitchProps) {
  const split = mode === 'split'

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
   * One string, used as both the accessible name and the tooltip.
   *
   * It names the state *and* what pressing does, in that order, which is the
   * thing that makes an icon-only toggle safe. There is no visible label left to
   * carry any of this.
   *
   * A refusal names the *act*, not the mode, because the sentences these are
   * given already start with the mode's own name — `Split arranges this
   * window's own panes…` — and `Split — Split arranges…` is a stutter a screen
   * reader has to read out loud.
   */
  const splitName = splitBlocked
    ? `Cannot split this window. ${splitBlocked}`
    : offered
      ? 'Split — two sessions side by side, not installed. Press to install it.'
      : split
        ? 'Split — press to show one session on its own again'
        : 'Split — show two sessions side by side'

  return (
    <div className="mode-switch" role="group" aria-label={label}>
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
          onChange(split ? 'terminal' : 'split')
        }}
      >
        <Glyph>{SPLIT_GLYPH}</Glyph>
      </button>
    </div>
  )
}
