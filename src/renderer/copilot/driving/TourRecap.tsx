import { useCallback, useEffect, useState } from 'react'
import { clearFocus, setFocus } from '../../driving/focus-controller'
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
 */

interface Props {
  /** Injectable for tests and the harness; defaults to the preload bridge. */
  read?: () => Promise<unknown>
  /** How many past scans to offer. One card each, newest first. */
  limit?: number
}

function bridgeRead(limit: number): (() => Promise<unknown>) | null {
  const deck = (globalThis as { deck?: { tours?: (count?: number) => Promise<unknown> } }).deck
  if (!deck || typeof deck.tours !== 'function') return null
  const tours = deck.tours.bind(deck)
  return () => tours(limit)
}

/** Whatever came back from the bridge, as records. Anything malformed is dropped. */
export function readRecords(value: unknown): TourRecord[] {
  if (!Array.isArray(value)) return []
  const out: TourRecord[] = []
  for (const entry of value) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as TourRecord
    if (record.v !== 1 || typeof record.id !== 'string' || !Array.isArray(record.stops)) continue
    out.push(record)
  }
  return out
}

export function TourRecap({ read, limit = 5 }: Props) {
  const [records, setRecords] = useState<TourRecord[]>([])
  const [open, setOpen] = useState<string | null>(null)
  const [pointed, setPointed] = useState<string | null>(null)

  useEffect(() => {
    const reader = read ?? bridgeRead(limit)
    if (reader === null) return
    let live = true
    void reader()
      .then((value) => {
        if (!live) return
        const found = readRecords(value)
        setRecords(found)
        // The newest one open, the rest folded. Somebody arriving on this page
        // has just watched a scan and wants its answer; the others are history.
        setOpen(found[0]?.id ?? null)
      })
      .catch(() => {
        // No scans yet, or the folder could not be read. The section simply does
        // not appear — nothing here claims a record it cannot show.
      })
    return () => {
      live = false
    }
  }, [read, limit])

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
