import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { MAX_TOURS_KEPT, TourStage, mergeProgress, type TourWindow } from './tour-stage'
import type { TourRecord, ValidatedTour } from './tour'

/**
 * The stage answers one question for `control.ts` — *is the copilot driving
 * right now* — and gets it wrong in two directions that both matter.
 *
 * Latching **on** with no window means every later `sessions.send` is refused
 * for being "while driving" with no tour anywhere, and nothing can clear it.
 * Latching **off** while a tour plays means the copilot can change something the
 * person cannot attribute to it, which is the whole reason the gate exists.
 *
 * So every transition below is pinned, including the ones nobody would think to
 * try: a window that never answers, a window that reloads mid-tour, a shutdown.
 */

let dirs: string[] = []

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'tour-stage-'))
  dirs.push(dir)
  return dir
}

afterEach(() => {
  dirs = []
})

function validated(id = 'one'): ValidatedTour {
  return {
    plan: {
      v: 1,
      id: `tour_1700000000000_${id.padEnd(8, '0').slice(0, 8)}`,
      question: 'what happened?',
      headline: 'this happened',
      askedBy: 'user',
      stops: [
        { kind: 'screen', sessionId: 's1', quote: 'the build failed', note: 'it failed', why: 'files-changed' },
      ],
    },
    dropped: [],
    titles: { s1: 'api' },
    folders: { s1: '/work/api' },
  }
}

interface Rig {
  stage: TourStage
  dir: string
  sent: TourRecord[]
  gone(): void
  watches: number
  unwatches: number
}

function rig(options: { window?: Partial<TourWindow> } = {}): Rig {
  const dir = scratch()
  const sent: TourRecord[] = []
  let onGone: (() => void) | null = null
  const state = { watches: 0, unwatches: 0 }
  const window: TourWindow = {
    send: (record) => {
      sent.push(record)
      return true
    },
    watch: (handler) => {
      state.watches += 1
      onGone = handler
      return () => {
        state.unwatches += 1
      }
    },
    ...options.window,
  }
  const stage = new TourStage({ dir, window, now: () => 1_000, ackTimeoutMs: 40 })
  return {
    stage,
    dir,
    sent,
    gone: () => onGone?.(),
    get watches() {
      return state.watches
    },
    get unwatches() {
      return state.unwatches
    },
  }
}

const tours = (dir: string): string[] => readdirSync(join(dir, 'tours'))

describe('driving is true only while a window says it is', () => {
  it('is false before anything is played', () => {
    expect(rig().stage.driving()).toBe(false)
  })

  it('is still false while a plan is in flight and unacknowledged', async () => {
    const r = rig()
    const playing = r.stage.play(validated())
    // The plan has been sent; nobody has said they took it. A tour that latched
    // the gate here would lock the copilot out on any build where the window is
    // on a different version and ignores the channel.
    expect(r.stage.driving()).toBe(false)
    expect(r.sent).toHaveLength(1)
    r.stage.acknowledge(r.sent[0].id)
    await playing
    expect(r.stage.driving()).toBe(true)
  })

  it('answers the tool with the record once the window acknowledges', async () => {
    const r = rig()
    const playing = r.stage.play(validated())
    r.stage.acknowledge(r.sent[0].id)
    const outcome = await playing
    expect(outcome.ok).toBe(true)
    expect(outcome.ok && outcome.record.question).toBe('what happened?')
  })

  it('refuses a second tour while one is playing', async () => {
    const r = rig()
    const playing = r.stage.play(validated('a'))
    r.stage.acknowledge(r.sent[0].id)
    await playing
    expect(await r.stage.play(validated('b'))).toEqual({ ok: false, why: 'already-driving' })
  })

  it('says there is no window rather than reporting a tour nobody saw', async () => {
    const r = rig({ window: { send: () => false } })
    expect(await r.stage.play(validated())).toEqual({ ok: false, why: 'no-window' })
    expect(r.stage.driving()).toBe(false)
    // Still recorded, with an end: the tour was written, was checked, and had
    // nowhere to go, which is a fact worth keeping.
    const [name] = tours(r.dir)
    const record = JSON.parse(readFileSync(join(r.dir, 'tours', name), 'utf8')) as TourRecord
    expect(record.endedAt).not.toBeNull()
    expect(record.stops.every((stop) => stop.shownAt === null)).toBe(true)
  })

  it('gives up on a window that was told and never answered', async () => {
    const r = rig()
    expect(await r.stage.play(validated())).toEqual({ ok: false, why: 'no-answer' })
    expect(r.stage.driving()).toBe(false)
  })

  it('ends the tour when the window reloads or goes away', async () => {
    const r = rig()
    const playing = r.stage.play(validated())
    r.stage.acknowledge(r.sent[0].id)
    await playing
    expect(r.stage.driving()).toBe(true)

    // A renderer reload takes the playhead with it — the player is component
    // state. This side has to notice, or the gate stays shut for the rest of the
    // run. DRIVING-MODE.md §8: a tour never survives a reload.
    r.gone()
    expect(r.stage.driving()).toBe(false)
    expect(r.unwatches).toBe(1)
  })

  it('closes the record at shutdown rather than leaving it open for ever', async () => {
    const r = rig()
    const playing = r.stage.play(validated())
    r.stage.acknowledge(r.sent[0].id)
    await playing
    r.stage.stop()
    const [name] = tours(r.dir)
    const record = JSON.parse(readFileSync(join(r.dir, 'tours', name), 'utf8')) as TourRecord
    expect(record.endedAt).toBe(1_000)
  })

  it('ignores an acknowledgement for a tour that is not the one playing', async () => {
    const r = rig()
    const playing = r.stage.play(validated())
    expect(r.stage.acknowledge('tour_1_deadbeef')).toBe(false)
    r.stage.acknowledge(r.sent[0].id)
    await playing
    expect(r.stage.driving()).toBe(true)
  })
})

describe('the record on disk', () => {
  it('is written before the window is even offered the plan', async () => {
    const r = rig({
      window: {
        send: (record) => {
          // Already on disk at the moment the offer is made: the account of what
          // is about to be shown has to exist before it is shown, or the one
          // case with no record is the one where something went wrong.
          expect(tours(r.dir)).toContain(`${record.id}.json`)
          return true
        },
      },
    })
    const playing = r.stage.play(validated())
    r.stage.acknowledge(r.sent.length > 0 ? r.sent[0].id : validated().plan.id)
    await playing
  })

  it('reads back newest first', async () => {
    const r = rig()
    const dir = join(r.dir, 'tours')
    const write = (id: string, startedAt: number): void => {
      const record: TourRecord = {
        v: 1,
        id,
        startedAt,
        endedAt: startedAt + 1,
        askedBy: 'user',
        question: 'q',
        headline: 'h',
        stops: [],
        stoppedAfter: null,
        dropped: [],
      }
      writeFileSync(join(dir, `${id}.json`), JSON.stringify(record))
    }
    // One real play first, so the directory exists the way the app makes it.
    const playing = r.stage.play(validated())
    r.stage.acknowledge(r.sent[0].id)
    await playing
    write('tour_1700000000001_aaaaaaaa', 5)
    write('tour_1700000000002_bbbbbbbb', 9)
    expect(r.stage.list().map((entry) => entry.startedAt)[0]).toBe(1_000)
  })

  it('skips a record it cannot parse rather than losing the rest', async () => {
    const r = rig()
    const playing = r.stage.play(validated())
    r.stage.acknowledge(r.sent[0].id)
    await playing
    writeFileSync(join(r.dir, 'tours', 'tour_1700000000009_cccccccc.json'), 'not json at all')
    expect(r.stage.list()).toHaveLength(1)
  })

  it('refuses to delete anything that is not a tour id', () => {
    const r = rig()
    expect(r.stage.forget('../../etc/passwd')).toBe(false)
    expect(r.stage.forget('tour_1_ab')).toBe(true)
  })

  it('keeps fifty', () => {
    expect(MAX_TOURS_KEPT).toBe(50)
  })
})

describe('the window says what happened, never what was said', () => {
  const record: TourRecord = {
    v: 1,
    id: 'tour_1700000000000_aaaaaaaa',
    startedAt: 1,
    endedAt: null,
    askedBy: 'user',
    question: 'q',
    headline: 'h',
    stops: [
      {
        index: 0,
        sessionId: 's1',
        sessionTitle: 'api',
        kind: 'screen',
        cwd: '/work/api',
        why: 'files-changed',
        quote: 'the checked text',
        note: 'the checked note',
        shownAt: null,
        dwellMs: null,
        degraded: false,
        degradedWhy: null,
      },
    ],
    stoppedAfter: null,
    dropped: [],
  }

  it('takes the progress fields', () => {
    const merged = mergeProgress(record, {
      stoppedAfter: 0,
      stops: [{ ...record.stops[0], shownAt: 55, dwellMs: 900, degraded: true, degradedWhy: 'in vim' }],
    })
    expect(merged.stops[0].shownAt).toBe(55)
    expect(merged.stops[0].dwellMs).toBe(900)
    expect(merged.stops[0].degraded).toBe(true)
    expect(merged.stoppedAfter).toBe(0)
  })

  it('overwrites the quote and the note with its own checked copy', () => {
    // The record is an audit artefact. A renderer bug — or a renderer at all —
    // must not be able to put text into it that nothing checked.
    const merged = mergeProgress(record, {
      stops: [{ ...record.stops[0], quote: 'something else entirely', note: 'and a different note' }],
    })
    expect(merged.stops[0].quote).toBe('the checked text')
    expect(merged.stops[0].note).toBe('the checked note')
  })

  it('ignores a stop index it does not know', () => {
    const merged = mergeProgress(record, {
      stops: [{ ...record.stops[0], index: 7, shownAt: 55 }],
    })
    expect(merged.stops[0].shownAt).toBeNull()
  })
})
