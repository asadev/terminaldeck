import { parseCapture, sanitizeLine, type ElementCapture } from './selector'

/**
 * The recorded-flow model: turning a stream of "the user did something to the
 * page" messages into a short, readable, replayable list of steps.
 *
 * Pure and DOM-free, like `selector.ts`, and for the same reason — every message
 * it parses came from an untrusted page. The guest recorder reports facts; this
 * decides what a step *is*, what may be shown, and what is allowed to reach an
 * agent's prompt.
 *
 * ## Why coalescing is part of the model and not a display detail
 *
 * A raw event stream is not a flow. Typing an email address fires one `change`
 * per visit to the field, a double-click is two clicks, and a single-page app
 * reports the same URL twice on one navigation. A list that shows all of that
 * is a log, and nobody can replay a log. The rules below are what turn one into
 * the other, so they are tested rather than eyeballed.
 */

/* ------------------------------------------------------------------ types -- */

export type StepKind = 'navigate' | 'click' | 'type' | 'select' | 'check' | 'press' | 'submit'

/**
 * One step. Deliberately flat with every field present rather than a
 * discriminated union: this crosses the IPC bridge as `unknown` and gets
 * re-declared on the renderer side, and a flat record survives that trip
 * without the two declarations having to agree about which members exist.
 */
export interface RecordedStep {
  kind: StepKind
  /** CSS selector for the element. Empty for `navigate`. */
  selector: string
  /** Human handle — the element's text, or the field's name. May be empty. */
  label: string
  /** Element tag, when it was one we would emit. */
  tag: string
  /** What was typed or chosen. Empty when redacted or not applicable. */
  value: string
  /** The value was deliberately withheld: a password or a file path. */
  redacted: boolean
  /** For `press`. One of {@link NOTABLE_KEYS}. */
  key: string
  /** For `check`. */
  checked: boolean
  /** The page this happened on, as the *main process* knows it. */
  url: string
  /** Main-process clock. The page never gets to stamp its own steps. */
  at: number
}

/** Keys the recorder is allowed to report. Anything else is not a step. */
export const NOTABLE_KEYS = ['Enter', 'Escape', 'Tab'] as const

/**
 * Where a recording stops growing. A long session would otherwise turn into
 * thousands of steps nobody will read, held in memory per tab, and pushed to
 * the renderer on every click.
 */
export const MAX_STEPS = 200

/** Longest value carried into a step. Long enough for a URL in a text field. */
const MAX_VALUE = 200
const MAX_LABEL = 120
const MAX_URL = 400
/** One line pasted into a prompt, matching `composeAgentContext`. */
const MAX_FLOW_LINE = 1200

/**
 * Two clicks closer together than this on the same element are one gesture — a
 * double-click, or a button that moved under a second press. Chromium's own
 * double-click threshold is 500ms; a little under it keeps deliberate repeat
 * clicks (a stepper, a "+" button) as separate steps, which they are.
 */
const CLICK_MERGE_MS = 400

const EMPTY: Omit<RecordedStep, 'kind' | 'at'> = {
  selector: '',
  label: '',
  tag: '',
  value: '',
  redacted: false,
  key: '',
  checked: false,
  url: '',
}

/* ----------------------------------------------------------------- parsing -- */

const KINDS = new Set<string>(['click', 'type', 'select', 'check', 'press', 'submit'])

/**
 * The best name for a *field*, which is not the best name for a button.
 *
 * Only the naming attributes, and never the element's own text or value. Both
 * fallbacks are wrong here in ways that were seen rather than guessed, driving a
 * real page from a real recording:
 *
 * - `parseCapture` falls back to an element's live value when it has no text,
 *   which labels the email box with the email address: `Type "a@b.com" into
 *   a@b.com`.
 * - a `<select>`'s text content is the concatenation of its own options, so the
 *   city picker in the probe came back named `DubaiLahore`. A `<textarea>`'s is
 *   whatever it was seeded with. Neither names the field.
 *
 * An unnamed field is left unnamed; the selector alone reads better than a
 * confident wrong label.
 */
function fieldLabel(capture: ElementCapture): string {
  const attrs = capture.attributes
  const named = attrs['aria-label'] || attrs.placeholder || attrs.title || attrs.name
  return named ? sanitizeLine(named, MAX_LABEL) : ''
}

/**
 * A field whose value belongs to the user rather than to the page.
 *
 * `file` counts for the same reason `password` does: the value is a path on the
 * user's own disk, usually starting with their name. The guest already refuses
 * to send either, so this is the second, independent check the doc on
 * {@link parseGuestStep} promises — and it only means that if it covers both.
 */
function isSecretCapture(capture: ElementCapture): boolean {
  const type = (capture.attributes.type || '').toLowerCase()
  return type === 'password' || type === 'file'
}

/**
 * Validate one message from the guest recorder.
 *
 * `url` is the main process's own view of where the tab is — never the page's
 * claim about itself, for the same reason `parseCapture` insists on it: a page
 * that can forge these messages must not also get to name the site whose flow
 * the user is about to hand an agent.
 *
 * Returns null for anything malformed. The caller drops it silently rather than
 * showing a page-authored complaint.
 */
export function parseGuestStep(raw: unknown, url: string, at: number): RecordedStep | null {
  if (typeof raw !== 'object' || raw === null) return null
  const payload = raw as Record<string, unknown>
  if (payload.v !== 1) return null
  const kind = payload.kind
  if (typeof kind !== 'string' || !KINDS.has(kind)) return null

  const capture = parseCapture(payload.target, url)
  if (!capture) return null

  const step: RecordedStep = {
    ...EMPTY,
    kind: kind as StepKind,
    selector: capture.selector,
    tag: capture.tag,
    url: capture.url,
    at,
    label: kind === 'click' || kind === 'submit' ? capture.label : fieldLabel(capture),
  }

  if (kind === 'press') {
    const key = typeof payload.key === 'string' ? payload.key : ''
    if (!(NOTABLE_KEYS as readonly string[]).includes(key)) return null
    step.key = key
    return step
  }

  if (kind === 'check') {
    step.checked = payload.checked === true
    return step
  }

  if (kind === 'type' || kind === 'select') {
    // Two independent reasons to withhold, both checked. The guest flags the
    // field it knows to be secret; the capture's own `type` attribute catches a
    // payload where that flag was stripped on the way here.
    if (payload.secret === true || isSecretCapture(capture)) {
      step.redacted = true
      return step
    }
    step.value = sanitizeLine(payload.value, MAX_VALUE)
    return step
  }

  return step
}

/** A navigation. Built in the main process from the view's own events. */
export function navigateStep(url: string, at: number): RecordedStep {
  return { ...EMPTY, kind: 'navigate', url: sanitizeLine(url, MAX_URL), at }
}

/* --------------------------------------------------------------- appending -- */

function sameTarget(a: RecordedStep, b: RecordedStep): boolean {
  return a.selector !== '' && a.selector === b.selector
}

/**
 * Add a step, folding it into the previous one where they are really the same
 * action. Never mutates: the array is handed to the renderer, and a recording
 * that changed underneath a render would tear.
 *
 * The rules, and why each exists:
 *
 * - **Repeated typing in one field replaces itself.** `change` fires every time
 *   the field is left, so tabbing back to fix a typo would otherwise record the
 *   half-typed value *and* the finished one, and a replay would use the first.
 * - **A repeat navigation to the same URL is dropped.** A single-page app fires
 *   `did-navigate-in-page` alongside `did-navigate`, and a redirect chain ends
 *   where it started often enough to matter.
 * - **Two fast clicks on one element merge.** That is a double-click, not two
 *   steps, and no replay wants the second.
 *
 * Once {@link MAX_STEPS} is reached the list stops growing rather than dropping
 * its oldest steps: a flow is a sequence, and one missing its beginning cannot
 * be replayed at all, while one missing its end is still a shorter true flow.
 */
export function appendStep(steps: RecordedStep[], next: RecordedStep): RecordedStep[] {
  const last = steps.length > 0 ? steps[steps.length - 1] : null

  if (last) {
    if ((next.kind === 'type' || next.kind === 'select') && last.kind === next.kind && sameTarget(last, next)) {
      return [...steps.slice(0, -1), next]
    }
    if (next.kind === 'navigate' && last.kind === 'navigate' && last.url === next.url) {
      return steps
    }
    if (
      next.kind === 'click' &&
      last.kind === 'click' &&
      sameTarget(last, next) &&
      next.at - last.at < CLICK_MERGE_MS
    ) {
      return steps
    }
  }

  if (steps.length >= MAX_STEPS) return steps
  return [...steps, next]
}

export function isFull(steps: RecordedStep[]): boolean {
  return steps.length >= MAX_STEPS
}

/* ---------------------------------------------------------------- printing -- */

function target(step: RecordedStep): string {
  const named = step.label ? `"${step.label}"` : ''
  const where = step.selector ? `\`${step.selector}\`` : step.tag ? `<${step.tag}>` : 'the page'
  return named ? `${named} (${where})` : where
}

/** One step in a sentence a person can follow and a machine can replay. */
export function describeStep(step: RecordedStep): string {
  switch (step.kind) {
    case 'navigate':
      return `Go to ${step.url}`
    case 'click':
      return `Click ${target(step)}`
    case 'type':
      return step.redacted
        ? `Type the password into ${target(step)}`
        : `Type "${step.value}" into ${target(step)}`
    case 'select':
      return step.redacted
        ? `Choose a value in ${target(step)}`
        : `Choose "${step.value}" in ${target(step)}`
    case 'check':
      return `${step.checked ? 'Check' : 'Uncheck'} ${target(step)}`
    case 'press':
      return `Press ${step.key} in ${target(step)}`
    case 'submit':
      return `Submit ${target(step)}`
  }
}

/** The whole flow as a numbered list, for the panel and for the clipboard. */
export function formatFlow(steps: RecordedStep[]): string {
  if (steps.length === 0) return ''
  const lines = steps.map((step, index) => `${index + 1}. ${describeStep(step)}`)
  if (isFull(steps)) lines.push(`(stopped at ${MAX_STEPS} steps)`)
  return lines.join('\n')
}

/**
 * The whole flow on one line, for handing to an agent.
 *
 * Single line by construction, like `composeAgentContext`: Pawl types this into
 * a PTY running a coding CLI, where a newline submits — a multi-line flow would
 * send `1. Go to…` as the entire instruction.
 */
export function flowLine(steps: RecordedStep[]): string {
  if (steps.length === 0) return ''
  const body = steps.map((step, index) => `${index + 1}) ${describeStep(step)}`).join('; ')
  return sanitizeLine(`[browser flow: ${body}]`, MAX_FLOW_LINE)
}
