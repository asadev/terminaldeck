import type { ReactNode } from 'react'

/**
 * The heading over a run of sessions — a project's, and a machine's.
 *
 * ## Why this is a component and not two pieces of markup
 *
 * It was two pieces of markup for exactly one night, and that is what produced
 * the complaint. A project heading was a fold arrow, a name, and three hover
 * actions; a machine heading was a monitor glyph and a name, with a "New session
 * on …" row bolted underneath it. Asad, 2026-08-18, looking at the two of them
 * ten pixels apart:
 *
 *   > *"You will give this exactly same, like this kind of pill to drop, with
 *   > same drop-down, same button — continue last session, new session, or
 *   > close."*
 *
 * "Exactly same" is not a look that can be maintained by copying: two components
 * that must agree forever are two components that will stop agreeing the first
 * time one of them is touched. So the project heading moved in here whole and
 * the machine heading calls the same function. Nothing about this file knows
 * what a project or a machine is, which is the property that keeps it true — it
 * takes a name, a fold and up to three actions, and every decision about which
 * of those exist is made by the caller.
 *
 * ## Why every label and tooltip is a prop
 *
 * Because they are the one thing that genuinely differs, and the difference is
 * about honesty rather than wording. The ＋ on a project heading carries ⌘T in
 * its tooltip, read out of the keymap, because ⌘T really does start a session in
 * the project you are in. The ＋ on a *machine* heading starts one on that
 * machine, which no chord does — printing the same shortcut there would be the
 * app claiming a key that goes somewhere else. The same argument holds for the
 * accessible names, which have to say *which* project or *which* machine so that
 * a screen reader hears three distinguishable buttons rather than three called
 * "New session".
 *
 * ## Continue is absent rather than inert, and that is the same rule as before
 *
 * `onResume` is optional and the glyph is simply not drawn without it. A project
 * heading passes one only when the agent a new session would run has a resume
 * command — `canResumeDefault` in `App.tsx` — because on an agent without one
 * this control started a *fresh* session and said nothing. A machine heading
 * passes none at all today, for a reason recorded where it is called.
 */

/** The disclosure triangle. The same path the rail has always used. */
const DISCLOSURE = 'M9.5 6.5l5.5 5.5-5.5 5.5'
const PLUS = 'M12 5.5v13M5.5 12h13'
const RESUME = 'M4 12a8 8 0 1 0 2.7-6M4 4.5v4h4'
const CLOSE = 'M6.5 6.5l11 11M17.5 6.5l-11 11'

function Glyph({
  path,
  size = 13,
  className,
}: {
  path: string
  size?: number
  className?: string
}) {
  return (
    <svg
      className={className ? `sb-glyph ${className}` : 'sb-glyph'}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={path} />
    </svg>
  )
}

export interface GroupAction {
  label: string
  title: string
  onPress(): void
  /**
   * Why this action cannot act right now, or null when it can.
   *
   * A sentence rather than a boolean, and the button is drawn **disabled
   * carrying that sentence** rather than removed. Which of the two an absent
   * action gets is the caller's call and the rule is the one this whole product
   * is being held to: a control that can never act here is not passed at all, and
   * a control that is momentarily unable to act says why. A machine whose app is
   * too old to end sessions is the second kind — Close belongs on that heading,
   * it is simply refused by the other end, and a person is owed the reason
   * rather than a heading that is silently missing a button its neighbours have.
   */
  disabledReason?: string | null
}

export interface GroupHeadProps {
  /** What the run is called. A project's folder name, a machine's name. */
  name: string
  /** The whole truth behind the name — a path, a machine's platform. */
  title?: string
  /** Whether the run below is showing. Drives the triangle and `aria-expanded`. */
  open: boolean
  onToggle(): void
  /**
   * A mark between the triangle and the name — today, the machine's monitor.
   *
   * This is the *only* place a remote group wears that mark, and putting it here
   * is half the fix he asked for: *"You don't need to give icon of the remote
   * next to all of them — only above there, next to the PC, the remote device."*
   * The rows underneath take the icons a local session row takes, because being
   * under this heading is already what says where they are running.
   */
  icon?: string
  /** Continue the last conversation here. Absent when there is none to continue. */
  resume?: GroupAction
  /** Start something here. */
  add: GroupAction
  /** Put the run away. What that costs is entirely the caller's business. */
  close: GroupAction
  /** Anything the caller wants after the name — a count, a state. */
  children?: ReactNode
}

export function GroupHead({
  name,
  title,
  open,
  onToggle,
  icon,
  resume,
  add,
  close,
  children,
}: GroupHeadProps) {
  const action = (spec: GroupAction, path: string) => {
    const blocked = spec.disabledReason ?? null
    return (
      <button
        type="button"
        className="sb-row-action"
        onClick={() => {
          if (blocked === null) spec.onPress()
        }}
        aria-label={spec.label}
        // `aria-disabled` and not `disabled`, so the button keeps its place in
        // the tab order and — the part that matters — keeps showing its title.
        // A `disabled` button in Chromium does not fire the hover that produces
        // a tooltip, so the one sentence explaining why it cannot act would be
        // unreachable by the person it was written for.
        aria-disabled={blocked !== null || undefined}
        data-blocked={blocked !== null || undefined}
        title={blocked ?? spec.title}
      >
        <Glyph path={path} />
      </button>
    )
  }

  return (
    <div className="sb-row sb-project-head">
      {/* A disclosure, the way a macOS sidebar folds a group. It has never
          started a session, which is what the ＋ beside it does — one
          affordance, one meaning. */}
      <button
        type="button"
        className="sb-row-main"
        title={title ?? name}
        aria-expanded={open}
        onClick={onToggle}
      >
        <Glyph path={DISCLOSURE} size={12} className={`sb-disclosure${open ? ' open' : ''}`} />
        {icon && <Glyph path={icon} size={12} className="sb-machine-mark" />}
        <span className="sb-project-name">{name}</span>
        {children}
      </button>
      {resume && action(resume, RESUME)}
      {action(add, PLUS)}
      {action(close, CLOSE)}
    </div>
  )
}
