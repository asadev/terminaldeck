import { useCallback, useEffect, useRef, useState } from 'react'
import { clearFocus, setFocus } from '../../driving/focus-controller'
import { watchCopilotFrontmost } from '../../driving/where'
import { answerSummary, groupBySession } from '../../../shared/scan'
import { navigator as driveNavigator } from './navigator'
import {
  droppedSentence,
  focusOfRecord,
  reasonLabel,
  stoppedSentence,
  type TourRecord,
  type TourStopRecord,
} from './tour'
import './tour-recap.css'

/**
 * The answer — phase two, and the only part of driving mode meant to be read.
 *
 * Asad, 2026-08-17, on what should happen when the scan stops:
 *
 *   > *"It returns to its own chat and combines everything into one structured
 *   > response: this session did this, this session did that. Then it stops and
 *   > he reads at his own pace, in one place."*
 *
 * So the scan is watched and this is read, and the split between the two is the
 * whole shape of the feature. Nothing on screen during a scan asks anybody to
 * read anything; everything worth reading ends up here, once, in the copilot's
 * own window, which is where the scan navigates back to when it finishes.
 *
 * ## Why it is grouped by session and not by stop
 *
 * Because that is the sentence he used — *"this session did this, this session
 * did that"* — and because the alternative makes the reader do the work the
 * feature exists to save. A scan visits stops in **importance** order, and one
 * session can come up twice with two different reasons; rendering that back as
 * a flat list means reassembling "what happened in session X" in your head from
 * rows four apart. `groupBySession` in `shared/scan.ts` does the regrouping, and
 * it lives there rather than here because the web client will need exactly this
 * the day it grows a copilot — porting it is how the two come to summarise the
 * same night differently.
 *
 * Sessions keep the order of their first stop, so the most important session is
 * still first and the grouping never quietly reorders the fleet against what was
 * just on screen.
 *
 * ## Two artefacts, and the split matters
 *
 * - **The copilot's own words go in its own transcript.** The copilot is a real
 *   session; the CLI writes its transcript, and the app must never inject into
 *   it. So the `headline` reaches the chat pane because the copilot *said* it,
 *   before it called `tour.play`. Nothing is faked and nothing is forged.
 * - **The record is written by the app**, into `<userData>/copilot-log/tours/`,
 *   which is outside `<userData>/copilot/` — the folder the copilot can write
 *   to. This card renders that file.
 *
 * The label is the whole value of writing it outside the copilot's reach: the
 * audited party must not be able to author, edit or delete the record of what it
 * did. A scan record is evidence about what the app **showed a person under the
 * copilot's name**, and a copilot that could rewrite it afterwards makes every
 * quote in it worth nothing.
 *
 * ## The two honest lines
 *
 * *"Stopped after 4 of 11"* and *"2 stops dropped — the quoted text was not
 * there"*. An interrupted scan still leaves a complete account of what it did
 * and did not show — which matters more now than it did at reading speed,
 * because at 260 ms a stop nobody can tell from watching whether something was
 * skipped.
 *
 * ## When it re-reads, and what tells it to
 *
 * This read once, at mount, and so it answered every scan except the one you had
 * just watched — which is the half of the feature it exists to be. The reason is
 * that nothing here remounts at the useful moment: `CopilotView` is mounted for
 * the whole life of the copilot session and merely hidden when something else is
 * in front (`App.tsx` renders it as `{copilotSession && copilotWindow(…)}` and
 * passes `visible` as a prop), and the copilot has to already be running to have
 * called `tour.play` at all. So the fetch that filled this list happened before
 * the scan existed; the scan then drove the screen, wrote its record, navigated
 * back here — and landed the person on a list of everything *but* the answer
 * they had just watched being assembled. Present, populated, and missing the one
 * card it was opened for, which is the worst shape a bug can take on a surface
 * whose whole job is "here is what it found".
 *
 * It re-reads on events rather than on a clock, which is his standing rule —
 * *"events, not polling, they make the system heavier"* — and both events
 * already existed with no reader:
 *
 *  1. **The copilot's page arriving in front.** Not a proxy for "the scan
 *     ended": it is literally how a scan ends. `tour-player.ts`'s `finish()`
 *     calls `returnToCopilot()`, which is `selectTab(copilotSessionId)`, which
 *     makes the rail mark its copilot row `data-copilot-active`. `where.ts`
 *     already watches exactly that attribute — a `MutationObserver` filtered to
 *     the single attribute, written because `DriveHost` needs the same fact to
 *     decide whether the panel may be up — so this costs one more callback on an
 *     observer that is already running and nothing at all when nothing moves. It
 *     also covers the arrival no tour event could: somebody who walks back onto
 *     this page an hour later gets what is on disk now.
 *  2. **A `tour.play` row on the action log.** For the scan that never touches
 *     the screen at all. With `copilot.interactive` off, `tour-tool.ts` takes the
 *     `stage.quietly()` path, which writes a record already stamped `endedAt` and
 *     sends nothing to any window — no navigation, so (1) never fires, and the
 *     answer would sit unread on disk while the copilot's own reply talks about
 *     it. `deck-control:action` carries every tool call as it is written to
 *     `actions.jsonl`, and this reads one tool id off it. It is the only reader
 *     left in the window: the rail's scrape panel used to read the same stream
 *     for its trace, and became a conversation on 2026-08-21.
 *
 * **`deck.onTour` is deliberately not one of them**, though it is the obvious
 * candidate, it is already bridged, and `DriveHost` already listens to it. It
 * carries the plan *arriving* — the start. A read at that moment finds a record
 * whose `endedAt` is null and whose stops have no `shownAt`, and this card
 * renders that as a scan in which every line says *"Not reached"*: the opposite
 * claim to the truth, made at the exact moment the scan is playing perfectly.
 *
 * Which is the same reason `readRecords` now drops a record the main process has
 * not closed. Both triggers above can genuinely fire mid-scan — the dot beside
 * the copilot's name in the drive panel folds you back onto this page while the
 * scan carries on behind it (`DriveHost.tsx`'s `fold`), which is a control, not
 * an edge case — and "still playing" is not a state this card has an honest
 * rendering for.
 *
 * The re-read does not race the record's write, and it is worth saying why
 * rather than hoping. The player posts `reportTour` *before* it navigates
 * (`finish()` reports, then calls `returnToCopilot()`), the main process handles
 * both messages in order and handles them synchronously, and `TourStage.finish`
 * writes with `writeFileSync` — so by the time the attribute change has been
 * observed and `deck.tours()` asked for, the file is already there. If that ever
 * stopped holding, the failure would be this card showing the *previous* scans
 * rather than showing a wrong one, and the next arrival on the page would
 * correct it.
 */

interface Props {
  /** Injectable for tests and the harness; defaults to the preload bridge. */
  read?: () => Promise<unknown>
  /** How many past scans to offer. One card each, newest first. */
  limit?: number
  /** What tells it to read again. Injectable for the same reason `read` is. */
  watch?: RecapWatch
}

/** The tool whose calls can leave a new scan on disk. */
const SCAN_TOOL = 'tour.play'

/**
 * The two announcements this card listens for, as something a test can fake.
 *
 * Both optional and both called with `?.`, which is the harness rather than
 * doubt about the preload — `.harness/answer.tsx` mounts this component alone
 * against a stubbed bridge, and a page that stopped rendering because a stub has
 * not grown a method is a page nobody looks at again. `DriveHost`'s own
 * `DriveBridge` takes the same shape for the same reason.
 */
export interface RecapWatch {
  /** `deck.onCopilotAction` — every tool call, as the log receives it. */
  onCopilotAction?(handler: (row: unknown) => void): () => void
  /** `watchCopilotFrontmost` — this page arriving in front, which is how a scan ends. */
  watchFront?(handler: (front: boolean) => void): () => void
}

/** The real two, wired to the window. Built inside an effect, so never on a server render. */
function liveWatch(): RecapWatch {
  const deck = (
    globalThis as {
      deck?: { onCopilotAction?(handler: (row: unknown) => void): () => void }
    }
  ).deck
  const rows = deck?.onCopilotAction
  return {
    onCopilotAction: typeof rows === 'function' ? rows.bind(deck) : undefined,
    watchFront: (handler) => watchCopilotFrontmost(handler),
  }
}

/**
 * Re-read on either announcement; give both subscriptions back on the way out.
 *
 * Exported, and taking its watchers as an argument, because this repository has
 * no jsdom — `where.ts` says so where it explains why it takes its `document` —
 * and the wiring is the part that has to be pinned: which events re-read, which
 * do not, and that nothing is left subscribed. Two fakes and it is driven
 * directly, with no window and no React.
 */
export function watchForFinishedScans(reread: () => void, watch: RecapWatch): () => void {
  const stops: Array<() => void> = []

  /*
   * The first call carries the current answer, not a change.
   *
   * `watchCopilotFrontmost` publishes what is true at the moment you subscribe
   * before it publishes anything else, deliberately: the panel it was written
   * for has to know where it stands on its first render. Here that first call is
   * a duplicate of the read the mount effect is already making, so it is
   * dropped. What this wants is the *arrival* — the edge that means a scan just
   * brought the screen back to this page.
   */
  let firstFront = true
  const front = watch.watchFront?.((inFront) => {
    if (firstFront) {
      firstFront = false
      return
    }
    if (inFront) reread()
  })
  if (front !== undefined) stops.push(front)

  const rows = watch.onCopilotAction?.((row) => {
    if (isScanRow(row)) reread()
  })
  if (rows !== undefined) stops.push(rows)

  return () => {
    for (const stop of stops) stop()
  }
}

/**
 * Is this action row a scan?
 *
 * Matched on the row's canonical dotted `tool` id, the way `browser-trace.ts`
 * matches `browser.*` on this same stream. Nothing else about the row is
 * assumed: it crossed the bridge as `unknown` and came out of a log a different
 * process appends to, so the one field being read is checked and the rest is
 * left alone.
 */
function isScanRow(raw: unknown): boolean {
  if (typeof raw !== 'object' || raw === null) return false
  return (raw as { tool?: unknown }).tool === SCAN_TOOL
}

function bridgeRead(limit: number): (() => Promise<unknown>) | null {
  const deck = (globalThis as { deck?: { tours?: (count?: number) => Promise<unknown> } }).deck
  if (!deck || typeof deck.tours !== 'function') return null
  const tours = deck.tours.bind(deck)
  return () => tours(limit)
}

/**
 * Whatever came back from the bridge, as records. Malformed ones are dropped,
 * and so is one that is still playing.
 */
export function readRecords(value: unknown): TourRecord[] {
  if (!Array.isArray(value)) return []
  const out: TourRecord[] = []
  for (const entry of value) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as TourRecord
    if (record.v !== 1 || typeof record.id !== 'string' || !Array.isArray(record.stops)) continue
    /*
     * A scan that is still on the screen is not an answer yet.
     *
     * This mattered the moment the card began re-reading, because the re-read
     * genuinely can happen mid-scan: the dot in the drive panel folds the
     * copilot's page back in front while the scan carries on behind it. What is
     * on disk at that instant is a record with no `endedAt` and stops with no
     * `shownAt`, which this card would render as a scan where every line says
     * *"Not reached"* — an account of a failure, drawn over one that is going
     * fine. There is no honest rendering of "playing" here; the panel is the
     * surface for that, and it is up.
     *
     * Only an explicit `null` is dropped — the value `openRecord` writes and
     * `TourStage.finish` overwrites when it closes the record. A record with no
     * `endedAt` field at all is not a shape this app has ever written, and
     * treating it as playing would hide it for ever on a guess.
     */
    if (record.endedAt === null) continue
    out.push(record)
  }
  return out
}

export function TourRecap({ read, limit = 5, watch }: Props) {
  const [records, setRecords] = useState<TourRecord[]>([])
  const [open, setOpen] = useState<string | null>(null)
  const [pointed, setPointed] = useState<string | null>(null)

  /*
   * Still mounted? — a ref now rather than a local `live` flag, because the read
   * no longer belongs to one effect.
   *
   * Set in the effect body as well as cleared in its teardown, which looks
   * redundant and is not: `main.tsx` renders the tree inside `<StrictMode>`, so
   * in development React mounts, unmounts and remounts every component once —
   * and `useRef(true)` initialises on the first of those only. Without the
   * assignment the remounted card would run with `alive` already `false`, fetch,
   * and throw the answer away; in development alone, which is the kind of
   * difference that gets diagnosed as "the IPC is flaky".
   */
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  /** The newest record this card has opened by itself. See `load`. */
  const opened = useRef<string | null>(null)

  const load = useCallback(() => {
    const reader = read ?? bridgeRead(limit)
    if (reader === null) return
    void reader()
      .then((value) => {
        if (!alive.current) return
        const found = readRecords(value)
        setRecords(found)
        const newest = found[0]?.id ?? null
        /*
         * The newest one open, the rest folded. Somebody arriving on this page
         * has just watched a scan and wants its answer; the others are history.
         *
         * Only when the newest one has *changed*, now that this runs more than
         * once. A re-read fires whenever this page comes back to the front, and
         * re-opening a card the person had folded away would be the disclosure
         * triangle moving under their hand — the app arguing with a choice they
         * had just made, every time they walked past.
         */
        if (newest === opened.current) return
        opened.current = newest
        setOpen(newest)
        /*
         * And nothing is boxed any more. A scan clears the focus on its way here
         * (`finish()` calls `clearFocus`), so a row still offering **Take the box
         * off** would be offering to remove a box that is not on the screen.
         */
        setPointed(null)
      })
      .catch(() => {
        // No scans yet, or the folder could not be read. The section simply does
        // not appear — nothing here claims a record it cannot show.
      })
  }, [read, limit])

  useEffect(load, [load])

  /*
   * And again whenever something says a scan may have finished. The header
   * argues which announcements those are, and why the obvious third one — the
   * tour arriving on `deck.onTour` — is not among them.
   */
  useEffect(() => watchForFinishedScans(load, watch ?? liveWatch()), [load, watch])

  /**
   * Take me back to one thing: navigate, box, dim, **no clock**.
   *
   * Not a scan of one. A scan drives; this points, and then stops, because the
   * person asked for this specific thing and driving them somewhere they did not
   * ask to go is the behaviour the whole feature is careful about. Nothing counts
   * down, and the highlight stays until they take it off — which is what a second
   * press of the same button does.
   */
  const takeMeThere = useCallback(
    (stop: TourStopRecord, key: string) => {
      if (pointed === key) {
        setPointed(null)
        clearFocus()
        return
      }
      const nav = driveNavigator()
      if (nav !== null) {
        if (stop.kind === 'anchor' && stop.at === 'git-file') {
          nav.selectTab(stop.sessionId)
          nav.showPanel('git')
        } else {
          nav.setSessionMode(stop.sessionId, stop.kind === 'message' ? 'chat' : 'terminal')
          nav.selectTab(stop.sessionId)
        }
      }
      const target = focusOfRecord(stop)
      if (target !== null) setFocus(target, true)
      setPointed(key)
    },
    [pointed],
  )

  if (records.length === 0) return null

  return (
    <section className="tr">
      <h2 className="tr-title">What it found</h2>
      {/*
        Said once, at the top, rather than on every card. It is the sentence that
        makes the quotes below worth reading: they are what the app checked and
        drew a box around, not what a model remembers having written.
      */}
      <p className="tr-provenance">
        Written by the app, outside the copilot’s folder — every quote is the text it checked
        before it put a box around it.
      </p>
      {records.map((record) => (
        <AnswerCard
          key={record.id}
          record={record}
          open={open === record.id}
          pointed={pointed}
          onToggle={() => setOpen(open === record.id ? null : record.id)}
          onTakeMeThere={takeMeThere}
        />
      ))}
    </section>
  )
}

function AnswerCard({
  record,
  open,
  pointed,
  onToggle,
  onTakeMeThere,
}: {
  record: TourRecord
  open: boolean
  pointed: string | null
  onToggle(): void
  onTakeMeThere(stop: TourStopRecord, key: string): void
}) {
  const stopped = stoppedSentence(record)
  const dropped = droppedSentence(record.dropped)
  /*
   * Grouped for the reading, indexed for the pointing.
   *
   * `groupBySession` deliberately takes and returns plain text, so it can be
   * shared with a client that has no `TourStopRecord` — which means the grouped
   * lines cannot carry a **Take me there**. The record is walked once more here
   * to pair each line back up with the stop it came from. One extra pass over a
   * dozen entries, in exchange for the grouping being a fact about scans rather
   * than a fact about this component.
   */
  const background = record.shown === 'background'
  const grouped = groupBySession(record.stops, { background })
  const summary = answerSummary(grouped)

  return (
    <article className="tr-card">
      <button type="button" className="tr-head" onClick={onToggle} aria-expanded={open}>
        <span className="tr-question">{record.question}</span>
        <span className="tr-when">
          {when(record.startedAt)} · {summary}
          {background ? ' Found without driving.' : ''}
        </span>
      </button>

      {open ? (
        <div className="tr-body">
          <p className="tr-headline">{record.headline}</p>

          {stopped === '' && dropped === '' ? null : (
            <p className="tr-honest">
              {stopped}
              {stopped !== '' && dropped !== '' ? ' ' : ''}
              {dropped}
            </p>
          )}

          {grouped.map((session) => (
            <section className="tr-session" key={`${record.id}:${session.sessionId}`}>
              <h3 className="tr-session-name">{session.title}</h3>
              <ul className="tr-lines">
                {session.lines.map((line, position) => {
                  const stop = nthStopOf(record, session.sessionId, position)
                  const key = `${record.id}:${session.sessionId}:${position}`
                  return (
                    <li key={key} className="tr-line" data-unseen={line.shown ? undefined : ''}>
                      <div className="tr-line-top">
                        <span className="tr-badge" data-why={line.why}>
                          {reasonLabel(line.why as TourStopRecord['why'])}
                        </span>
                        {line.shown ? null : <span className="tr-unseen">Not reached</span>}
                      </div>
                      <p className="tr-note">{line.note}</p>
                      {/*
                        In full and inline, never a link. That is the literal ask —
                        read it from here instead of going back to the sessions —
                        and a link back into a session is exactly the trip this
                        exists to save. Plain text, because this is somebody else's
                        agent's output under the app's chrome.
                      */}
                      {line.quote === '' ? null : <pre className="tr-quote">{line.quote}</pre>}
                      {stop?.degradedWhy === null || stop === null ? null : (
                        <p className="tr-degraded">{stop.degradedWhy}</p>
                      )}
                      {stop === null ? null : (
                        <button
                          type="button"
                          className="tr-goto"
                          data-pointed={pointed === key || undefined}
                          onClick={() => onTakeMeThere(stop, key)}
                        >
                          {pointed === key ? 'Take the box off' : 'Take me there'}
                        </button>
                      )}
                    </li>
                  )
                })}
              </ul>
            </section>
          ))}

          {record.dropped.length === 0 ? null : (
            <div className="tr-dropped">
              <h3>Not shown</h3>
              <ul>
                {record.dropped.map((entry, index) => (
                  <li key={`${record.id}:drop:${index}`}>
                    <span className="tr-drop-title">{entry.title}</span>
                    <span className="tr-drop-why">{entry.detail}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      ) : null}
    </article>
  )
}

/**
 * The nth stop this record holds for one session, in record order.
 *
 * The pairing that puts **Take me there** back on a grouped line. It is a
 * position lookup rather than a match on the note's text, because two stops in
 * one session can legitimately carry the same note — and matching on text would
 * silently point the second one at the first one's evidence.
 */
export function nthStopOf(
  record: TourRecord,
  sessionId: string,
  position: number,
): TourStopRecord | null {
  let seen = 0
  for (const stop of record.stops) {
    if (stop.sessionId !== sessionId) continue
    if (seen === position) return stop
    seen += 1
  }
  return null
}

function when(at: number): string {
  if (!Number.isFinite(at) || at <= 0) return ''
  return new Date(at).toLocaleString()
}
