import { describe, expect, it } from 'vitest'
import {
  asOf,
  busyness,
  howLong,
  nextAgeChange,
  overallSentence,
  readings,
  runningTone,
  runningWord,
} from './words'
import type { Fact, ServerCard, ServerFacts } from './types'

/**
 * The words on a server's page, and the arithmetic behind them.
 *
 * Everything checked here is a pure function, and that is not a coincidence:
 * these are the decisions most likely to be quietly wrong on somebody else's
 * machine, and they are the only part of this feature that can be checked
 * without a server to point at.
 *
 * Two of these tests exist because a two-state model would have passed them
 * while being wrong — the container case and the "we could not tell" case. Both
 * were measured on real machines before the code was written, and both are the
 * reason the fact model has three states rather than two.
 */

const NOW = 1_700_000_000_000

function yes<T>(value: T): Fact<T> {
  return { known: 'yes', value, measuredAt: NOW, how: 'measured' }
}

function cannot<T>(why: string): Fact<T> {
  return { known: 'cannot', measuredAt: NOW, why }
}

function card(over: Partial<ServerCard> = {}): ServerCard {
  return { id: 'c1', kind: 'app', name: 'Thing', detail: '', running: true, url: null, ...over }
}

describe('the one sentence at the top', () => {
  it('says nothing at all before anything has been measured', () => {
    expect(overallSentence(undefined)).toBe('')
  })

  it('says everything is running only when everything is', () => {
    expect(overallSentence([card({ running: true }), card({ id: 'c2', running: true })])).toBe(
      "Everything's running.",
    )
  })

  it('names the one thing that stopped, rather than counting to one', () => {
    expect(
      overallSentence([
        card({ name: 'Shop', running: false }),
        card({ id: 'c2', running: true }),
      ]),
    ).toBe("Shop isn't running.")
  })

  it('counts once there is more than one, because four names is a list', () => {
    expect(
      overallSentence([
        card({ name: 'Shop', running: false }),
        card({ id: 'c2', name: 'Blog', running: false }),
      ]),
    ).toBe("2 things aren't running.")
  })

  /*
   * The case a two-state model cannot express, and the reason for the third.
   *
   * A card whose state we could not read is not a stopped card and it is not a
   * running one. Drawing a green tick over it is the single most damaging thing
   * this page could do, because a summary is the part somebody glances at and
   * then stops thinking about.
   */
  it('refuses to say everything is running over a fact it could not read', () => {
    // Still the rule this file was written for — the sentence must not put a
    // tick over an unanswered question. What changed is only its *proportion*:
    // it now bounds the claim instead of leading with the failure, which is a
    // stronger version of the same promise. "Everything we can check" says both
    // halves out loud.
    expect(
      overallSentence([
        card({ running: true }),
        card({ id: 'c2', running: null }),
      ]),
    ).toBe('Everything we can check is running.')
  })

  it('treats a card that never reported a state as one it could not read', () => {
    expect(overallSentence([card({ running: true }), card({ id: 'c2', running: null })])).toBe(
      'Everything we can check is running.',
    )
  })

  it('does not call a healthy server broken because one thing was unreadable', () => {
    /*
     * The case that sent this back, seen on a real machine: eleven containers
     * running, storage 28%, memory 41%, workload light, up 83 days — and one
     * website whose start-and-stop arrangement this app could not recognise.
     * The headline read "We couldn't check everything on this server", which is
     * the only sentence a non-technical person reads, and it described a
     * perfectly healthy box as a failure.
     *
     * The doubt has not been hidden — that one card still says `Can't tell` on
     * itself, which is where somebody could act on it. It has stopped being the
     * whole server's news.
     */
    const many = [
      ...Array.from({ length: 11 }, (_, i) => card({ id: `ok${i}`, running: true })),
      card({ id: 'site', running: null }),
    ]
    expect(overallSentence(many)).toBe('Everything we can check is running.')
  })

  it('makes the doubt the headline when there is no other news', () => {
    // Nothing readable at all is different in kind, not in degree: there is no
    // true thing to report instead, so the doubt *is* the report.
    expect(
      overallSentence([card({ running: null }), card({ id: 'c2', running: null })]),
    ).toBe("We couldn't check anything on this server.")
  })

  it('puts something stopped ahead of something unreadable, because one is actionable', () => {
    expect(
      overallSentence([
        card({ name: 'Shop', running: false }),
        card({ id: 'c2', running: null }),
      ]),
    ).toBe("Shop isn't running.")
  })

  it('says so plainly when a server keeps nothing we could find', () => {
    // A bare container, a machine using an init system this app has never met,
    // a fresh box: all three are somebody's real server and all three land here.
    expect(overallSentence([])).toBe("There's nothing here we can check on.")
  })
})

describe('running, stopped, and not knowing', () => {
  it('says all three, and never turns not-knowing into stopped', () => {
    expect(runningWord(true)).toBe('Running')
    expect(runningWord(false)).toBe('Stopped')
    // Null is "we found it and could not tell". Rendering that as Stopped would
    // send somebody to restart a thing that is running perfectly well.
    expect(runningWord(null)).toBe("Can't tell")
  })

  it('gives not-knowing its own tone rather than borrowing the stopped one', () => {
    expect(runningTone(true)).toBe('on')
    expect(runningTone(false)).toBe('off')
    expect(runningTone(null)).toBe('unsure')
  })
})

describe('the numbers in the calm zone', () => {
  const full: ServerFacts = {
    disk: yes({ usedKb: 34, totalKb: 100 }),
    memory: yes({ usedKb: 41, totalKb: 100 }),
    load: yes(0.5),
    cpus: yes(4),
    uptimeSeconds: yes(90_000),
  }

  it('shows the four when all four were measured', () => {
    expect(readings(full).map((reading) => `${reading.label} ${reading.value}`)).toEqual([
      'Storage 34% full',
      'Memory 41% in use',
      'Workload Light',
      'On for 1 day',
    ])
  })

  it('drops a reading it could not take, rather than drawing a zero or a dash', () => {
    const some = readings({ ...full, disk: cannot('not allowed to look') })
    expect(some.some((reading) => reading.id === 'disk')).toBe(false)
    // And the drop is a drop, not a blank row that happens to be empty.
    expect(some).toHaveLength(3)
  })

  it('drops a reading nobody has asked for yet', () => {
    expect(readings({}).length).toBe(0)
    expect(readings(undefined).length).toBe(0)
  })

  /*
   * The trap that was measured rather than imagined.
   *
   * Inside a container, `df`, the memory file, the load average and the uptime
   * all report the **host's** numbers. A real container on a rented box
   * answered 39 GB of disk and a 64-hour uptime, both of which belonged to the
   * box. So a "Storage 16% full" on that card is not imprecise — it is a fact
   * about a different computer.
   */
  it('shows no host numbers at all for something running inside a container', () => {
    expect(readings({ ...full, init: yes('container-none') })).toEqual([])
  })

  it('will not interpret a workload without knowing how many processors there are', () => {
    // The measurement means nothing on its own: 2.0 is idle on a large machine
    // and hopeless on a small one. Printing it raw would be jargon that teaches
    // nothing, and inventing a share of it would be a number about nothing.
    const noCpus = readings({ load: yes(2), uptimeSeconds: yes(60) })
    expect(noCpus.some((reading) => reading.id === 'load')).toBe(false)
  })

  it('reads the workload against the number of processors', () => {
    expect(busyness(0.5, 4)).toBe('Light')
    expect(busyness(3.4, 4)).toBe('Steady')
    expect(busyness(8, 4)).toBe('Busy')
    expect(busyness(1, 0)).toBe('')
  })
})

describe('how long, and how long ago', () => {
  it('rounds down, so a restart is never described on a day it did not happen', () => {
    // 47 hours is one day. Two would be a claim about yesterday.
    expect(howLong(47 * 3600)).toBe('1 day')
    expect(howLong(90)).toBe('1 minute')
    expect(howLong(30)).toBe('less than a minute')
    expect(howLong(3600)).toBe('1 hour')
    expect(howLong(-1)).toBe('')
  })

  it('says how old a measurement is in the words a person would use', () => {
    expect(asOf(NOW, NOW)).toBe('just now')
    expect(asOf(NOW - 20 * 60_000, NOW)).toBe('20 minutes ago')
    expect(asOf(NOW - 90 * 60_000, NOW)).toBe('1 hour ago')
    expect(asOf(NOW - 30 * 3_600_000, NOW)).toBe('yesterday')
  })

  it('treats a clock that ran backwards as just now rather than as a paradox', () => {
    expect(asOf(NOW + 5_000, NOW)).toBe('just now')
  })

  /*
   * The age has to change or it is a lie — "just now" still on screen twenty
   * minutes later is worse than no age at all, because the age is the whole
   * reason a cached page is honest. What it must not be is a tick.
   */
  it('names the exact moment the label stops being true, so one timeout does it', () => {
    expect(nextAgeChange(NOW, NOW)).toBe(NOW + 45_000)
    // "1 minute ago" is rounded, so it turns over on the half-minute.
    expect(asOf(NOW - 50_000, NOW)).toBe('1 minute ago')
    const measuredAt = NOW - 50_000
    const turns = nextAgeChange(measuredAt, NOW)
    expect(turns).toBe(measuredAt + 90_000)
    // Exact, in both directions: one millisecond before that moment the old
    // label is still true, and at it the new one is. A repaint scheduled here
    // is never early and never late.
    expect(asOf(measuredAt, turns - 1)).toBe('1 minute ago')
    expect(asOf(measuredAt, turns)).toBe('2 minutes ago')
  })
})
