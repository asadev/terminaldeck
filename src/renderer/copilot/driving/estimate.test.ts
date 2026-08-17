import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  DEFAULT_PACE,
  DENSITY_MAX,
  DENSITY_SLOPE,
  FASTEST_WPM,
  FIXATION_MS,
  HOLD_ABOVE_MS,
  LEARN_ALPHA,
  MIN_DWELL_MS,
  PACES,
  PROSE_CHARS_PER_WORD,
  PROSE_SYMBOL_RATIO,
  SAMPLE_PARAGRAPH,
  SLOWEST_WPM,
  densityFor,
  effectiveWpm,
  forgetLearned,
  isHold,
  learn,
  normalizeSpeed,
  paceFor,
  paceSampleLabel,
  paceSampleMs,
  readingTimeMs,
  stopDwellMs,
  textStats,
  type ReadingSpeed,
} from './estimate'

/**
 * The reading-time model, checked against the corpus it was derived from.
 *
 * ## Why the fixtures are validated rather than trusted
 *
 * Every number in `estimate.ts` came out of a measurement over 8,760 real
 * assistant messages and 15,571 real tool results on this machine. The fixtures
 * below cannot be those transcripts — they are somebody's private work and they
 * are not in this repository — so the fixtures are hand-written, and a
 * hand-written fixture is exactly the kind of thing that quietly stops being
 * representative.
 *
 * So they are not asserted to be representative on anybody's say-so. Each one
 * is checked against the **measured tenth-to-ninetieth percentile band** of its
 * class from that corpus, and the bands are written down beside them. A fixture
 * that drifts out of its band fails here rather than silently making every
 * timing claim below meaningless.
 *
 * | class          | symbol ratio p10 | p50  | p90  |
 * |----------------|------------------|------|------|
 * | assistant prose| 0.04             | 0.07 | 0.12 |
 * | shell output   | 0.08             | 0.12 | 0.20 |
 * | source code    | 0.12             | 0.17 | 0.23 |
 * | stack traces   | 0.09             | 0.14 | 0.25 |
 * | diff hunks     | 0.11             | 0.16 | 0.22 |
 * | JSON           | 0.13             | 0.30 | 0.46 |
 *
 * ## What is deliberately not asserted
 *
 * That the estimate is *correct* for a person. It cannot be — that is the whole
 * reason `pacer.ts` treats it as a default and learns from behaviour. What is
 * asserted is that it is correct **relative to itself**: prose is faster than
 * code, a longer stop takes longer, a pace named slower is slower, and no
 * combination of settings and learning can produce a speed nobody chose.
 */

/* ---------------------------------------------------------------- corpus -- */

/** Measured symbol-ratio bands, p10 to p90, from the corpus described above. */
const BANDS = {
  prose: [0.04, 0.12],
  cmd: [0.08, 0.2],
  code: [0.12, 0.23],
  trace: [0.09, 0.25],
  diff: [0.11, 0.22],
  json: [0.13, 0.46],
} as const

const PROSE = [
  "I've stopped short of deleting anything. The migration ran twice against the same",
  "database, because the retry didn't check whether the first attempt had committed,",
  'so `orders` and `order_items` both hold duplicate rows now — and',
  "I'd rather you decided what happens to them.",
].join(' ')

const CODE = `export function stopDwellMs(stop: PacedStop, speed: ReadingSpeed): number {
  const wpm = effectiveWpm(speed)
  const reading = readingTimeMs(stop.quote, wpm) + readingTimeMs(stop.note, wpm)
  return Math.max(MIN_DWELL_MS, FIXATION_MS + reading)
}`

const TRACE = `Error: ENOENT: no such file or directory, open '/Users/apple/Projects/terminaldeck/out/main/index.js'
    at Object.openSync (node:fs:596:3)
    at readFileSync (node:fs:464:35)
    at loadHost (file:///Users/apple/Projects/terminaldeck/src/main/host-core.ts:118:19)
    at async start (file:///Users/apple/Projects/terminaldeck/src/main/index.ts:44:5)`

const DIFF = `@@ -70,7 +70,9 @@ export class PtyManager {
-  private readonly scrollback = 2000
+  private readonly scrollback = 4000
+  /** Matches SEARCH_BACK in anchor-terminal.ts. */
   private readonly sessions = new Map<string, Session>()`

const JSON_BLOB =
  '{"session":"7d2f7353","status":"blocked","tokens":{"input":184220,"output":9134},' +
  '"cwd":"/Users/apple/Projects/terminaldeck","tools":[{"name":"Bash","failures":6}]}'

const CMD = `> terminaldeck@0.3.0 test
> vitest run

 Test Files  4 failed | 329 passed | 2 skipped (335)
      Tests  14 failed | 8374 passed | 31 skipped (8419)`

const STEADY: ReadingSpeed = { pace: 'steady', scale: 1 }

describe('the fixtures still look like the corpus they stand in for', () => {
  const cases: Array<[keyof typeof BANDS, string]> = [
    ['prose', PROSE],
    ['code', CODE],
    ['trace', TRACE],
    ['diff', DIFF],
    ['json', JSON_BLOB],
    ['cmd', CMD],
  ]
  for (const [name, text] of cases) {
    it(`${name} sits inside the measured p10–p90 band`, () => {
      const [low, high] = BANDS[name]
      const ratio = textStats(text).symbolRatio
      expect(ratio, `${name} measured ${ratio.toFixed(3)}, band ${low}–${high}`).toBeGreaterThanOrEqual(low)
      expect(ratio).toBeLessThanOrEqual(high)
    })
  }

  it('keeps the sample paragraph in the prose band too', () => {
    // It is the paragraph every pace is described by, so if it stops reading
    // like prose the whole speed control starts describing something else.
    const ratio = textStats(SAMPLE_PARAGRAPH).symbolRatio
    expect(ratio).toBeGreaterThanOrEqual(BANDS.prose[0])
    expect(ratio).toBeLessThanOrEqual(BANDS.prose[1])
  })

  it('keeps the sample paragraph the length a real quote is', () => {
    // Long enough to be a paragraph rather than a sentence, well short of the
    // 600-character quote budget, which is a ceiling and not a typical stop.
    const stats = textStats(SAMPLE_PARAGRAPH)
    expect(stats.chars).toBeGreaterThan(150)
    expect(stats.chars).toBeLessThan(400)
  })
})

/* ------------------------------------------------------------- the counts -- */

describe('what counts as a word', () => {
  it('measures prose at close to the corpus’s characters per word', () => {
    const stats = textStats(PROSE)
    const perWord = stats.chars / stats.tokens
    // 5.94 measured, 5.25 to 6.80 across the tenth to ninetieth percentile.
    expect(perWord).toBeGreaterThan(5)
    expect(perWord).toBeLessThan(7)
  })

  it('does not call a 600-character blob one word', () => {
    // The failure this prevents: `words` from whitespace alone gives 1, the
    // estimate collapses to the floor, and a screenful of base64 flashes past.
    const blob = 'a1B2c3D4'.repeat(75)
    const stats = textStats(blob)
    expect(stats.tokens).toBe(1)
    expect(stats.words).toBeCloseTo(600 / PROSE_CHARS_PER_WORD, 1)
    expect(stopDwellMs({ quote: blob, note: '' }, STEADY)).toBeGreaterThan(20_000)
  })

  it('does not shortchange a sentence made of short words', () => {
    // 10 tokens, 32 characters: the character term alone says 5.4 words and
    // would give this half the time it needs. Real prose measures this short at
    // the tenth percentile, so it is not a contrived case.
    const short = 'I do not know if it is on or off'
    const stats = textStats(short)
    expect(stats.tokens).toBe(10)
    expect(stats.chars / stats.tokens).toBeLessThan(PROSE_CHARS_PER_WORD)
    expect(stats.words).toBe(10)
  })

  it('collapses whitespace, so a wrapped line is not a slower line', () => {
    // The point of counting words rather than lines: the same text wrapped
    // differently by a narrower pane must estimate identically.
    const wide = 'the session stopped and is waiting for an answer'
    const narrow = 'the session\n  stopped   and is\n\n  waiting for an answer'
    expect(textStats(narrow).words).toBe(textStats(wide).words)
    expect(stopDwellMs({ quote: narrow, note: '' }, STEADY)).toBe(
      stopDwellMs({ quote: wide, note: '' }, STEADY),
    )
  })

  it('counts an accented name as letters, not as symbols', () => {
    // A session's output is full of non-ASCII: the ❯ prompt glyph, box drawing,
    // somebody's surname. Classing every one as a symbol would mark an ordinary
    // sentence as dense because of a diaeresis.
    const plain = textStats('the review from Muller is done').symbolRatio
    const accented = textStats('the review from Müller is done').symbolRatio
    expect(accented).toBeCloseTo(plain, 5)
  })

  it('says nothing at all about empty text', () => {
    const stats = textStats('   \n  ')
    expect(stats.words).toBe(0)
    expect(stats.density).toBe(1)
    expect(readingTimeMs('', 190)).toBe(0)
  })
})

/* ------------------------------------------------------------ the density -- */

describe('density separates code from prose, which is the whole point', () => {
  it('leaves plain prose at exactly 1', () => {
    expect(textStats(PROSE).density).toBe(1)
  })

  it('orders the classes the way the corpus orders them', () => {
    const prose = textStats(PROSE).density
    const cmd = textStats(CMD).density
    const code = textStats(CODE).density
    const json = textStats(JSON_BLOB).density
    expect(prose).toBeLessThan(cmd)
    expect(cmd).toBeLessThan(code)
    expect(code).toBeLessThan(json)
  })

  it('makes code meaningfully slower, not marginally slower', () => {
    // The claim `DENSITY_SLOPE` encodes: at the measured symbol ratio of real
    // source code (0.17), a character costs about 1.35× a character of prose.
    expect(densityFor(0.17)).toBeCloseTo(1.35, 2)
    expect(densityFor(0.3)).toBeCloseTo(1.8, 2)
  })

  it('would have been a rounding error at the slope the design document proposed', () => {
    /*
     * DRIVING-MODE.md §5 proposes `1 + 0.6 × symbolRatio` and claims a stack
     * trace, a diff and a JSON blob "all land near 2.0". Against the measured
     * ratios that formula spans 1.04 to 1.18 — a 13 % difference between the
     * easiest and hardest thing on the screen — and its cap of 2.0 needs a
     * symbol ratio of 1.67, which is not a number a string can have.
     *
     * This is pinned because the constant is the sort of thing a later reader
     * "restores" to match the document. The document is wrong; it was written
     * before anybody measured.
     */
    const proposed = (ratio: number): number => 1 + 0.6 * ratio
    expect(proposed(0.3) - proposed(0.07)).toBeLessThan(0.15)
    expect(proposed(1)).toBeLessThan(DENSITY_MAX)
    expect(densityFor(0.3) - densityFor(0.07)).toBeGreaterThan(0.5)
  })

  it('never goes below 1, because the pace is already the prose rate', () => {
    expect(densityFor(0)).toBe(1)
    expect(densityFor(PROSE_SYMBOL_RATIO)).toBe(1)
    expect(densityFor(0.01)).toBe(1)
  })

  it('caps, and the cap is reachable by something real', () => {
    expect(densityFor(1)).toBe(DENSITY_MAX)
    // Reached at a ratio of 0.36, which in the corpus is dense JSON — inside
    // the JSON band's p50-to-p90 range, so the cap does real work.
    expect(densityFor(PROSE_SYMBOL_RATIO + (DENSITY_MAX - 1) / DENSITY_SLOPE)).toBe(DENSITY_MAX)
    expect(0.36).toBeLessThan(BANDS.json[1])
  })

  it('measures the quote and the note separately rather than as one blob', () => {
    /*
     * Joining them averages two symbol ratios, and the average is always kinder
     * to the harder half. A JSON blob with a one-line prose note under it would
     * get less time than the same blob alone, which is the wrong direction.
     */
    const separate = stopDwellMs({ quote: JSON_BLOB, note: 'This is what it sent back.' }, STEADY)
    const joined = stopDwellMs(
      { quote: `${JSON_BLOB} This is what it sent back.`, note: '' },
      STEADY,
    )
    expect(separate).toBeGreaterThan(joined)
  })
})

/* -------------------------------------------------------------- the clock -- */

describe('the fixation allowance', () => {
  it('is the box’s own fade plus one fixation, not a round number', () => {
    /*
     * Derived from `tokens.css`, and read back out of it here so the two cannot
     * drift. `--dur` is how long the box takes to fade in, during which there is
     * nothing legible to look at; ~250 ms more is finding a salient target and
     * landing a fixation on it.
     */
    const tokens = readFileSync(
      join(resolve(__dirname, '..', '..'), 'styles', 'tokens.css'),
      'utf8',
    )
    // Cut before the reduced-motion override, which sets the same custom
    // property to 0.01ms — matching that one instead would make this assert
    // that a fixation takes 250 ms, which is the opposite of the claim.
    const reduced = tokens.indexOf('@media (prefers-reduced-motion')
    expect(reduced, 'tokens.css no longer overrides motion').toBeGreaterThan(0)
    const root = tokens.slice(0, reduced)
    const match = /--dur:\s*(\d+)ms/.exec(root)
    expect(match, 'tokens.css no longer declares --dur in :root').not.toBeNull()
    const dur = Number((match as RegExpExecArray)[1])
    expect(FIXATION_MS).toBe(dur + 250)
  })

  it('is charged once per stop, not per word', () => {
    const one = stopDwellMs({ quote: PROSE, note: '' }, STEADY)
    const two = stopDwellMs({ quote: PROSE, note: PROSE }, STEADY)
    expect(two - one).toBeCloseTo(one - FIXATION_MS, 0)
  })
})

describe('the floor and the hand-over', () => {
  it('never lets a stop flash past', () => {
    expect(stopDwellMs({ quote: 'ok', note: '' }, STEADY)).toBe(MIN_DWELL_MS)
    expect(stopDwellMs({ quote: '', note: '' }, STEADY)).toBe(MIN_DWELL_MS)
    // Even at the fastest pace anyone can choose.
    expect(stopDwellMs({ quote: 'ok', note: '' }, { pace: 'quick', scale: 2.5 })).toBe(MIN_DWELL_MS)
  })

  it('hands over rather than clamping, so the number survives to be acted on', () => {
    const long = PROSE.repeat(3)
    const dwell = stopDwellMs({ quote: long, note: '' }, STEADY)
    expect(dwell).toBeGreaterThan(HOLD_ABOVE_MS)
    expect(isHold(dwell)).toBe(true)
  })

  it('auto-advances a stop of a couple of sentences and hands over a full-budget one', () => {
    /*
     * The measured consequence of `HOLD_ABOVE_MS`, and the thing it is telling
     * the tour's author: at the default pace a quote of a couple of hundred
     * characters plays on its own, and one that uses the whole 600-character
     * budget does not. A 600-character quote is two stops, not one.
     */
    const short = PROSE.slice(0, 200)
    expect(isHold(stopDwellMs({ quote: short, note: 'Worth knowing.' }, STEADY))).toBe(false)
    const budget = PROSE.repeat(3).slice(0, 600)
    expect(isHold(stopDwellMs({ quote: budget, note: 'Worth knowing.' }, STEADY))).toBe(true)
  })

  it('holds sooner for somebody who reads slowly, which is the right way round', () => {
    const middling = PROSE.slice(0, 300)
    expect(isHold(stopDwellMs({ quote: middling, note: '' }, { pace: 'unhurried', scale: 1 }))).toBe(
      true,
    )
    expect(isHold(stopDwellMs({ quote: middling, note: '' }, { pace: 'quick', scale: 1 }))).toBe(
      false,
    )
  })
})

/* --------------------------------------------------------------- the pace -- */

describe('the speed preference', () => {
  it('spans the range real readers cover', () => {
    // Reading speed varies by roughly 2–3× between people. Anything narrower is
    // a control that cannot reach the person it was added for.
    expect(FASTEST_WPM / SLOWEST_WPM).toBeCloseTo(3, 1)
  })

  it('starts below average, because the two failures do not cost the same', () => {
    /*
     * The meta-analytic figure for silent reading of English non-fiction is
     * about 238 wpm. The default sits at roughly 0.8 of that: too slow costs one
     * keypress, too fast costs the thread and — the expensive part — teaches him
     * the tour cannot be trusted to wait.
     */
    const wpm = paceFor(DEFAULT_PACE).wpm
    expect(wpm / 238).toBeGreaterThan(0.75)
    expect(wpm / 238).toBeLessThan(0.85)
  })

  it('is ordered, named, and never printed as a raw rate', () => {
    for (let index = 1; index < PACES.length; index += 1) {
      expect(PACES[index].wpm).toBeGreaterThan(PACES[index - 1].wpm)
      expect(PACES[index].label).not.toMatch(/\d/)
    }
  })

  it('describes each pace by how long a paragraph gets, all five distinct', () => {
    /*
     * The reason the labels exist: nobody knows their own reading speed in words
     * a minute, and everybody knows whether fourteen seconds on a paragraph is
     * too long. Two options that describe themselves identically would make the
     * control unusable for the one thing it is for — which is what happened at
     * five-second rounding, where Steady and Brisk both said "about 15 sec".
     */
    const labels = PACES.map((pace) => paceSampleLabel(pace.name))
    expect(new Set(labels).size).toBe(PACES.length)
    for (let index = 1; index < PACES.length; index += 1) {
      expect(paceSampleMs(PACES[index].name)).toBeLessThan(paceSampleMs(PACES[index - 1].name))
    }
  })

  it('falls back to the documented default rather than to a nearby pace', () => {
    expect(paceFor('steady').name).toBe('steady')
    expect(normalizeSpeed({ pace: 'blistering', scale: 1 }).pace).toBe(DEFAULT_PACE)
    expect(normalizeSpeed(null).pace).toBe(DEFAULT_PACE)
    expect(normalizeSpeed('steady').pace).toBe(DEFAULT_PACE)
    expect(normalizeSpeed({ pace: 'steady' }).scale).toBe(1)
    expect(normalizeSpeed({ pace: 'steady', scale: -4 }).scale).toBe(1)
    expect(normalizeSpeed({ pace: 'steady', scale: Number.NaN }).scale).toBe(1)
    expect(normalizeSpeed({ pace: 'steady', scale: 99 }).scale).toBeLessThanOrEqual(2.5)
  })
})

/* ------------------------------------------------------------- the learning -- */

describe('what the app is allowed to learn about a reader', () => {
  it('speeds up when the reader is faster than the estimate', () => {
    const faster = learn(STEADY, 1.5)
    expect(faster.scale).toBeGreaterThan(1)
    expect(effectiveWpm(faster)).toBeGreaterThan(effectiveWpm(STEADY))
  })

  it('slows down when the reader holds past it', () => {
    const slower = learn(STEADY, 0.6)
    expect(slower.scale).toBeLessThan(1)
    expect(effectiveWpm(slower)).toBeLessThan(effectiveWpm(STEADY))
  })

  it('converges inside four observations, which is inside the first tour', () => {
    // A correction that needed twenty stops would never arrive: a tour is a
    // dozen. `LEARN_ALPHA` is what buys this, and it is what this pins.
    let speed = STEADY
    for (let index = 0; index < 4; index += 1) speed = learn(speed, 1.6)
    expect(speed.scale).toBeGreaterThan(1.35)
    expect(LEARN_ALPHA).toBeGreaterThan(0.2)
  })

  it('never lets one observation claim more than a doubling', () => {
    // Without this, one → pressed a beat after the box appears is a sample of
    // fifteen, and a third of that nonsense survives into the next four stops.
    const wild = learn(STEADY, 500)
    expect(wild.scale).toBeLessThan(1.4)
    expect(learn(STEADY, 0.001).scale).toBeGreaterThan(0.8)
  })

  it('ignores an impossible observation instead of poisoning itself', () => {
    expect(learn(STEADY, 0)).toBe(STEADY)
    expect(learn(STEADY, -1)).toBe(STEADY)
    expect(learn(STEADY, Number.NaN)).toBe(STEADY)
    expect(learn(STEADY, Number.POSITIVE_INFINITY)).toBe(STEADY)
  })

  it('can never take the reader to a speed they could not have chosen', () => {
    /*
     * The rule that keeps a measurement from becoming an unaskable control. If
     * the learning decides he reads at 900 wpm, the tour goes as fast as Quick
     * and no faster — because a tour running at a speed with no name, that the
     * reader never picked and cannot un-pick, arrives by silent accumulation and
     * is the worst possible way for it to arrive.
     */
    expect(effectiveWpm({ pace: 'quick', scale: 2.5 })).toBe(FASTEST_WPM)
    expect(effectiveWpm({ pace: 'unhurried', scale: 0.4 })).toBe(SLOWEST_WPM)
    for (const pace of PACES) {
      for (const scale of [0.4, 0.7, 1, 1.6, 2.5]) {
        const wpm = effectiveWpm({ pace: pace.name, scale })
        expect(wpm).toBeGreaterThanOrEqual(SLOWEST_WPM)
        expect(wpm).toBeLessThanOrEqual(FASTEST_WPM)
      }
    }
  })

  it('forgets the measurement without forgetting the choice', () => {
    const learned: ReadingSpeed = { pace: 'brisk', scale: 1.7 }
    expect(forgetLearned(learned)).toEqual({ pace: 'brisk', scale: 1 })
  })
})

/* ------------------------------------------------------------ the estimate -- */

describe('the estimate as a whole', () => {
  it('is monotonic in length, in density and in pace', () => {
    const short = stopDwellMs({ quote: PROSE.slice(0, 100), note: '' }, STEADY)
    const long = stopDwellMs({ quote: PROSE, note: '' }, STEADY)
    expect(long).toBeGreaterThan(short)

    const equalLength = JSON_BLOB.slice(0, 160)
    const prose160 = PROSE.slice(0, 160)
    expect(stopDwellMs({ quote: equalLength, note: '' }, STEADY)).toBeGreaterThan(
      stopDwellMs({ quote: prose160, note: '' }, STEADY),
    )

    let previous = Number.POSITIVE_INFINITY
    for (const pace of PACES) {
      const dwell = stopDwellMs({ quote: PROSE, note: '' }, { pace: pace.name, scale: 1 })
      expect(dwell).toBeLessThan(previous)
      previous = dwell
    }
  })

  it('gives a couple of sentences a wait a person would recognise', () => {
    // Not a claim that this is right for anybody in particular — it cannot be.
    // A claim that it is in the right order of magnitude, so a first run is not
    // absurd before the learning has anything to go on.
    const seconds = stopDwellMs({ quote: PROSE.slice(0, 200), note: '' }, STEADY) / 1000
    expect(seconds).toBeGreaterThan(8)
    expect(seconds).toBeLessThan(18)
  })

  it('does not depend on line count, which is what was rejected', () => {
    /*
     * The design he half-proposed and the one thing this module exists to refuse:
     * seconds per line. The same words split across four lines and one line are
     * the same reading, and a pane resize changes the line count without
     * changing anybody's reading speed.
     */
    const oneLine = 'the migration ran twice and the second run duplicated every row it inserted'
    const fourLines = oneLine.split(' ').join('\n')
    expect(stopDwellMs({ quote: fourLines, note: '' }, STEADY)).toBe(
      stopDwellMs({ quote: oneLine, note: '' }, STEADY),
    )
  })
})
