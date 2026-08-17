import { useCallback, useEffect, useState } from 'react'
import { clearFocus, setFocus } from '../../driving/focus-controller'
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
 * What the tour showed, kept where it can be read instead of the sessions.
 *
 * > *"Once it is all done it takes us back to its own chat box, and it keeps
 * > those parts inside its own chat also, so we can just read from there instead
 * > of the other sessions."*
 *
 * That is the literal ask this component answers, and the shape of the answer is
 * settled by `DRIVING-MODE.md` §6, which splits the artefact in two:
 *
 * - **The copilot's own words go in its own transcript.** The copilot is a real
 *   session; the CLI writes its transcript, and the app must never inject into
 *   it. So the `headline` reaches the chat pane because the copilot *said* it,
 *   before it called `tour.play`. Nothing is faked and nothing is forged.
 * - **The record is written by the app**, into `<userData>/copilot-log/tours/`,
 *   which is outside `<userData>/copilot/` — the folder the copilot can write
 *   to. This card renders that file.
 *
 * ## Why it says whose record it is
 *
 * The label is the whole value of writing it outside the copilot's reach. Same
 * argument `COPILOT-CAPABILITIES.md` §7 used to move the action log out: the
 * audited party must not be able to author, edit or delete the record of what it
 * did. A tour record is evidence about what the app **showed a person under the
 * copilot's name**, and a copilot that could rewrite it afterwards makes every
 * quote in it worth nothing. So the card says it is the app's, and the quotes in
 * it are the ones the app checked and drew a box around, not the ones a model
 * remembers writing.
 *
 * ## The two honest lines
 *
 * *"Stopped after 4 of 11"* and *"2 stops dropped — the quoted text was not
 * there"*. An interrupted tour still leaves a complete account of what it did
 * and did not show, which is the thing that makes an auto-advancing tour bearable
 * at all: a stop that scrolled past is never lost.
 */

interface Props {
  /** Injectable for tests and the harness; defaults to the preload bridge. */
  read?: () => Promise<unknown>
  /** How many past tours to offer. One card each, newest first. */
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

  useEffect(() => {
    const reader = read ?? bridgeRead(limit)
    if (reader === null) return
    let live = true
    void reader()
      .then((value) => {
        if (!live) return
        const found = readRecords(value)
        setRecords(found)
        // The newest one open, the rest folded. A person coming back to this
        // page wants the tour they just watched; the others are history.
        setOpen(found[0]?.id ?? null)
      })
      .catch(() => {
        // No tours yet, or the folder could not be read. The section simply
        // does not appear — nothing here claims a record it cannot show.
      })
    return () => {
      live = false
    }
  }, [read, limit])

  /**
   * Replay one stop: navigate, box, dim, **no timer**.
   *
   * Not a tour of one. A tour drives; this points, and then stops, because the
   * person asked for this specific thing and driving them somewhere they did not
   * ask to go is the behaviour the whole feature is careful about. There is no
   * transport, nothing counts down, and the highlight stays until they take it
   * off — which is what the second press of the same button does.
   */
  const takeMeThere = useCallback(
    (stop: TourStopRecord, key: string) => {
      if (open === key) {
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
    },
    [open],
  )

  if (records.length === 0) return null

  return (
    <section className="tr">
      <h2 className="tr-title">Tours</h2>
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
        <TourCard
          key={record.id}
          record={record}
          open={open === record.id}
          onToggle={() => setOpen(open === record.id ? null : record.id)}
          onTakeMeThere={takeMeThere}
        />
      ))}
    </section>
  )
}

function TourCard({
  record,
  open,
  onToggle,
  onTakeMeThere,
}: {
  record: TourRecord
  open: boolean
  onToggle(): void
  onTakeMeThere(stop: TourStopRecord, key: string): void
}) {
  const stopped = stoppedSentence(record)
  const dropped = droppedSentence(record.dropped)
  const shown = record.stops.filter((stop) => stop.shownAt !== null).length

  return (
    <article className="tr-card">
      <button type="button" className="tr-head" onClick={onToggle} aria-expanded={open}>
        <span className="tr-question">{record.question}</span>
        <span className="tr-when">
          {when(record.startedAt)} · {shown} of {record.stops.length} shown
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

          <ol className="tr-stops">
            {record.stops.map((stop) => {
              const key = `${record.id}:${stop.index}`
              return (
                <li key={key} className="tr-stop" data-unseen={stop.shownAt === null || undefined}>
                  <div className="tr-stop-top">
                    <span className="tr-where">{stop.sessionTitle}</span>
                    <span className="tr-badge" data-why={stop.why}>
                      {reasonLabel(stop.why)}
                    </span>
                    {stop.shownAt === null ? <span className="tr-unseen">Not reached</span> : null}
                  </div>
                  <p className="tr-note">{stop.note}</p>
                  {/*
                    In full and inline, never a link. That is the literal ask —
                    read it from here instead of going back to the sessions — and
                    a link back into a session is exactly the trip this exists to
                    save. Plain text, for the reason in `drive-panel.css`: this
                    is somebody else's agent's output under the app's chrome.
                  */}
                  {stop.quote === '' ? null : <pre className="tr-quote">{stop.quote}</pre>}
                  {stop.degradedWhy === null ? null : (
                    <p className="tr-degraded">{stop.degradedWhy}</p>
                  )}
                  <button
                    type="button"
                    className="tr-goto"
                    onClick={() => onTakeMeThere(stop, key)}
                  >
                    Take me there
                  </button>
                </li>
              )
            })}
          </ol>

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

function when(at: number): string {
  if (!Number.isFinite(at) || at <= 0) return ''
  return new Date(at).toLocaleString()
}
