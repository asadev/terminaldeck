/**
 * The tour, as the window receives it — and the two translations that make it
 * playable.
 *
 * The plan on the wire has already been through `main/deck-control/tour.ts`:
 * every `why` re-checked against the app's own data, every quote found in a real
 * transcript or a real terminal, every stop that failed either dropped and the
 * drop listed. **Nothing in this file re-decides any of that**, and that is a
 * rule rather than a division of labour. `importance.ts` exists because two
 * modules each growing their own idea of "important" is how the morning report
 * and the tour of the same night come to name different sessions, after which
 * neither is believed. The window's judgement about a stop begins and ends at
 * *where is it on screen*.
 *
 * ## What this module does do
 *
 * One translation: {@link focusOf} turns a stop into a {@link FocusTarget},
 * which is what the overlay understands. That type is a closed set with no
 * selector escape hatch, for reasons `focus-target.ts` sets out at length, and
 * this is the only place a wire stop becomes one.
 *
 * There used to be a second, `pacedOf`, which reduced a stop to the two pieces
 * of text the reading-time estimate measured. It went with `estimate.ts` when
 * driving mode stopped being a read-along: the scan holds every stop for the
 * same 260 ms whatever it says, so nothing in this feature measures text any
 * more, and a converter into a shape nobody consumes is dead weight that reads
 * like an API.
 *
 * ## Why the reason set is written out again here
 *
 * `main/deck-control/importance.ts` is the canonical copy and says so in its own
 * header; the renderer's tsconfig does not include `src/main`, so a type cannot
 * be shared across that line. `AlertsPanel.tsx` already mirrors `AlertKind` from
 * `alerts.ts` for exactly this reason and says so too. The mirror is safe in one
 * direction only: a reason the main process adds and this file has not learned
 * arrives as a string this file cannot label, so {@link reasonLabel} answers with
 * the raw value rather than throwing. A badge reading `tool-failing` is worse
 * than one reading "Tool failing" and infinitely better than a blank panel.
 */

import type { DriveAnchor, FocusTarget } from '../../driving/focus-target'

/* ------------------------------------------------------------------ shapes -- */

/** Mirrors `main/deck-control/importance.ts`. That file is canonical. */
export type StopReason =
  | 'blocked-on-you'
  | 'failed'
  | 'finished'
  | 'looping'
  | 'tool-failing'
  | 'compacted'
  | 'expensive'
  | 'files-changed'
  | 'question-asked'
  | 'decision'

export type TourAnchorAt = 'git-file' | 'usage'

export interface TourStopBase {
  sessionId: string
  note: string
  why: StopReason
}

export type TourStop =
  | (TourStopBase & { kind: 'message'; messageId: string; quote: string })
  | (TourStopBase & { kind: 'screen'; quote: string })
  | (TourStopBase & { kind: 'anchor'; at: TourAnchorAt; path?: string })

export type DropReason = 'quote-not-found' | 'session-gone' | 'over-budget' | 'reason-unsupported'

export interface DroppedStop {
  title: string
  why: DropReason
  detail: string
}

export interface TourStopRecord {
  index: number
  sessionId: string
  sessionTitle: string
  /**
   * Enough to point at this stop again, weeks later.
   *
   * Mirrors `main/deck-control/tour.ts`. It is here so the recap's **Take me
   * there** can rebuild the same target the tour used, which a quote alone
   * cannot: a `screen` stop is anchored by its text, a `message` stop by an id,
   * an `anchor` stop by a place and a path. `cwd` rather than a lookup, because
   * a two-week-old recap has no live session to ask.
   */
  kind: 'message' | 'screen' | 'anchor'
  cwd: string
  messageId?: string
  at?: TourAnchorAt
  path?: string
  why: StopReason
  quote: string
  note: string
  shownAt: number | null
  dwellMs: number | null
  degraded: boolean
  degradedWhy: string | null
}

export interface TourRecord {
  v: 1
  id: string
  startedAt: number
  endedAt: number | null
  askedBy: 'user' | 'offer'
  question: string
  headline: string
  /**
   * Whether this scan was put on the screen or done quietly.
   *
   * Mirrors `main/deck-control/tour.ts`, which is canonical. Interactive mode
   * off does the same work and shows none of it, so a background record has no
   * stop with a `shownAt` — and the answer card has to know that means "nothing
   * was drawn" rather than "nothing was found", which are opposite claims made
   * from identical data.
   *
   * Optional on the way in, because records written before the toggle existed
   * are still on disk and are all screen scans.
   */
  shown?: 'screen' | 'background'
  stops: TourStopRecord[]
  stoppedAfter: number | null
  dropped: DroppedStop[]
}

/** What arrives on `deck-control:tour`: the record, and the stops to play. */
export interface TourMessage {
  record: TourRecord
  stops: TourStop[]
}

/* ------------------------------------------------------------------ arrival -- */

/**
 * Whatever came over the bridge, made into a tour, or null.
 *
 * Narrowed here rather than trusted, even though the sender is this app's own
 * main process. The bridge carries `unknown` by house rule — `CLAUDE.md`:
 * *"Feature types stay in their own module and cross the bridge as `unknown`,
 * duplicating them in `shared/types.ts` lets the two drift apart"* — so the
 * narrowing has to happen somewhere, and doing it once at the door is what keeps
 * every function below able to assume its argument.
 *
 * Null rather than a throw. A malformed tour is a tour that does not play, and
 * a window that threw inside an IPC listener would take down whatever else that
 * listener was in the middle of.
 */
export function readTour(value: unknown): TourMessage | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as { record?: unknown; stops?: unknown }
  const record = raw.record
  if (typeof record !== 'object' || record === null) return null
  const asRecord = record as TourRecord
  if (asRecord.v !== 1 || typeof asRecord.id !== 'string') return null
  if (!Array.isArray(raw.stops)) return null

  const stops: TourStop[] = []
  for (const entry of raw.stops) {
    const stop = readStop(entry)
    if (stop !== null) stops.push(stop)
  }
  if (stops.length === 0) return null
  return { record: asRecord, stops }
}

function readStop(value: unknown): TourStop | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const sessionId = text(raw.sessionId)
  const note = text(raw.note)
  const why = text(raw.why)
  if (sessionId === null || note === null || why === null) return null
  const base = { sessionId, note, why: why as StopReason }

  if (raw.kind === 'message') {
    const messageId = text(raw.messageId)
    const quote = text(raw.quote)
    if (messageId === null || quote === null) return null
    return { ...base, kind: 'message', messageId, quote }
  }
  if (raw.kind === 'screen') {
    const quote = text(raw.quote)
    if (quote === null) return null
    return { ...base, kind: 'screen', quote }
  }
  if (raw.kind === 'anchor') {
    const at = text(raw.at)
    if (at === null) return null
    return {
      ...base,
      kind: 'anchor',
      at: at as TourAnchorAt,
      ...(text(raw.path) === null ? {} : { path: raw.path as string }),
    }
  }
  return null
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/* ------------------------------------------------------------- translations -- */

/**
 * Where the overlay should point for this stop, and the folder a `git-file`
 * anchor needs.
 *
 * `cwd` is a separate argument rather than a field on the stop, and that is the
 * one place the wire shape and the overlay's shape genuinely disagree.
 * `focus-target.ts` keys a git anchor on the **project folder** — because
 * `PanelView` renders `<GitPanel cwd={projectPath}/>` and has no session in
 * scope, a folder with four sessions open in it having one working tree — while
 * a stop is keyed on a session, because every reason it can carry is a fact
 * about one. Both are right for their own side, so the join happens here, with
 * the session's cwd supplied by whoever is playing.
 *
 * Returns null when the stop names an anchor this build does not know. That is
 * the mirror's one failure mode (see the header) and it degrades to a
 * panel-only stop rather than to a wrong box.
 */
export function focusOf(stop: TourStop, cwd: string | null): FocusTarget | null {
  switch (stop.kind) {
    case 'screen':
      return { kind: 'terminal', sessionId: stop.sessionId, quote: stop.quote }
    case 'message':
      return { kind: 'anchor', anchor: { at: 'message', messageId: stop.messageId } }
    case 'anchor': {
      const anchor = anchorOf(stop, cwd)
      return anchor === null ? null : { kind: 'anchor', anchor }
    }
  }
}

function anchorOf(
  stop: TourStop & { kind: 'anchor' },
  cwd: string | null,
): DriveAnchor | null {
  switch (stop.at) {
    case 'usage':
      return { at: 'usage', sessionId: stop.sessionId }
    case 'git-file':
      if (stop.path === undefined || cwd === null) return null
      return { at: 'git-file', cwd, path: stop.path }
    default:
      // A kind the main process knows and this build does not — the mirror's
      // one failure mode. Null degrades the stop to a panel-only one rather
      // than guessing at a box.
      return null
  }
}

/**
 * The target a *recorded* stop points at, rebuilt from the record alone.
 *
 * The recap's **Take me there** replays one stop long after the tour, when the
 * plan is gone and only the record survives — so this reads the record rather
 * than a {@link TourStop}. It is deliberately a second small function instead of
 * a conversion back into a stop: a record is not a plan, and pretending it is
 * would invite somebody to try to *play* one.
 */
export function focusOfRecord(stop: TourStopRecord): FocusTarget | null {
  switch (stop.kind) {
    case 'screen':
      return stop.quote === ''
        ? null
        : { kind: 'terminal', sessionId: stop.sessionId, quote: stop.quote }
    case 'message':
      return stop.messageId === undefined
        ? null
        : { kind: 'anchor', anchor: { at: 'message', messageId: stop.messageId } }
    case 'anchor':
      if (stop.at === 'usage') {
        return { kind: 'anchor', anchor: { at: 'usage', sessionId: stop.sessionId } }
      }
      if (stop.at === 'git-file' && stop.path !== undefined && stop.cwd !== '') {
        return { kind: 'anchor', anchor: { at: 'git-file', cwd: stop.cwd, path: stop.path } }
      }
      return null
    default:
      return null
  }
}

/**
 * Which pane this stop needs in front.
 *
 * A `message` stop is a bubble in the chat view and a `screen` stop is a
 * passage of terminal output; there is no mapping between the two and there
 * cannot be one — the JSONL is written by the CLI, the pty carries the CLI's
 * *rendering* of it, and `session-transcript.ts` records that a transcript line
 * says "nothing whatsoever about the terminal that produced it". So a stop is
 * either one or the other, which is why the plan has two variants rather than
 * one with an optional field, and why this function is total.
 *
 * An anchor stop asks for nothing: the sidebar row, the alerts panel and the
 * git panel are not inside a session's pane, and switching the pane under a
 * reader for a stop that does not need it is the app twitching.
 */
export function paneFor(stop: TourStop): 'terminal' | 'chat' | null {
  switch (stop.kind) {
    case 'screen':
      return 'terminal'
    case 'message':
      return 'chat'
    case 'anchor':
      return null
  }
}

/* ---------------------------------------------------------------- wording -- */

/** The badge on a stop row. Falls back to the raw value — see the header. */
export function reasonLabel(why: StopReason): string {
  switch (why) {
    case 'blocked-on-you':
      return 'Waiting on you'
    case 'failed':
      return 'Failed'
    case 'finished':
      return 'Finished'
    case 'looping':
      return 'Looping'
    case 'tool-failing':
      return 'Tool failing'
    case 'compacted':
      return 'Compacted'
    case 'expensive':
      return 'Expensive'
    case 'files-changed':
      return 'Files changed'
    case 'question-asked':
      return 'Asked a question'
    case 'decision':
      return 'Decision'
    default:
      return why
  }
}

/**
 * The line the panel and the recap both print about dropped stops.
 *
 * One sentence, with the count, because *"2 stops were dropped — the text was no
 * longer on screen"* is the difference between a tour that looks short and a
 * tour that says why it is short. Empty string when nothing was dropped, so the
 * caller renders nothing rather than "0 stops were dropped".
 */
export function droppedSentence(dropped: readonly DroppedStop[]): string {
  if (dropped.length === 0) return ''
  const count = `${dropped.length} stop${dropped.length === 1 ? '' : 's'}`
  const reasons = new Set(dropped.map((entry) => entry.why))
  if (reasons.size === 1) {
    const [only] = [...reasons]
    return `${count} dropped — ${dropReason(only)}.`
  }
  return `${count} dropped — the checks did not hold.`
}

function dropReason(why: DropReason): string {
  switch (why) {
    case 'quote-not-found':
      return 'the quoted text was not there'
    case 'session-gone':
      return 'the session had gone'
    case 'over-budget':
      return 'they were over what a tour may carry'
    case 'reason-unsupported':
      return 'this app’s own data did not support the reason given'
    default:
      return 'the checks did not hold'
  }
}

/**
 * "stopped after 4 of 11", or the empty string for a tour that ran to the end.
 *
 * `stoppedAfter` is an index and the sentence is one-based, which is the one
 * conversion worth doing in exactly one place: the panel counts from one because
 * a reader does, and every record on disk counts from zero because an array
 * does.
 */
export function stoppedSentence(record: TourRecord): string {
  if (record.stoppedAfter === null) return ''
  const shown = record.stoppedAfter + 1
  if (shown >= record.stops.length) return ''
  return `Stopped after ${shown} of ${record.stops.length}.`
}
