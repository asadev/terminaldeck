/**
 * How long a tour stop takes to read.
 *
 * This is DRIVING-MODE.md §5's `estimate.ts`, and it is the file the pacing
 * argument is actually settled in. Everything else in the pacing engine —
 * the playhead, the transport, the interruption watch — is machinery around
 * the number this module produces.
 *
 * ## The thing he asked for, and the answer that was rejected
 *
 * Asad, 2026-08-17:
 *
 *   > "There will be a problem that it might be too speedy — some people will
 *   > be reading and it keeps moving; some people are slower, some are faster
 *   > and are waiting for it to move on. We need some strategic things for
 *   > that. Maybe settings, wait per line how many seconds — or something
 *   > better than that."
 *
 * Seconds per line is wrong three times over and he half-suspected it himself.
 * A line of `ls` output and a line of a stack trace are not the same reading; a
 * one-line stop and a fifteen-line stop are not the same wait; and, worst, a
 * number of seconds is a promise the app cannot keep, because a "line" in a
 * terminal is whatever the window width happened to be when the text wrapped.
 * The same paragraph is nine lines in a narrow pane and four in a wide one, and
 * nobody's reading speed changed when they dragged the divider.
 *
 * So the unit here is **words**, corrected for **density**, and neither number
 * is guessed — see the measurements below.
 *
 * ## Measured on this machine, not assumed
 *
 * `CLAUDE.md` says: *"If you can check an assumption against something real on
 * this machine, do it before writing code that depends on it."* Both constants
 * below were measured against 8,760 real assistant messages and 15,571 real
 * tool results, pulled out of 67 transcripts under
 * `~/.claude/projects/-Users-apple-Projects-terminaldeck` and
 * `-Users-apple-ClaudeAsad`, clipped to `MAX_QUOTE_CHARS` (600) because that is
 * the largest a stop's quote is allowed to be. Source code was sampled straight
 * off this repository with its block comments stripped, so "code" means code
 * rather than prose in code's clothing.
 *
 * | content              | chars per word (p50) | symbol ratio (p50) |
 * |----------------------|----------------------|--------------------|
 * | assistant prose      | 5.94                 | 0.07               |
 * | shell / tool output  | 7.75                 | 0.12               |
 * | TypeScript source    | 7.82                 | 0.17               |
 * | diff hunks           | 8.23                 | 0.16               |
 * | stack traces         | 8.89                 | 0.14               |
 * | JSON                 | 7.97                 | 0.30               |
 *
 * Two facts come out of that table and both change the design.
 *
 * **1. A word of code is a third longer than a word of prose.** 7.8 characters
 * against 5.9. So a plain word count under-counts code by about 30 % on ink
 * alone, before anything about comprehension. `readingWords` fixes that by
 * normalising to a prose-sized word rather than by counting whitespace.
 *
 * **2. The density formula in the design document does not survive contact
 * with the data.** DRIVING-MODE.md §5 proposes `density = 1 + 0.6 × symbolRatio`
 * and claims "a stack trace, a diff hunk and a JSON blob all land near 2.0;
 * prose lands near 1.0." Against the measured ratios that formula produces 1.04
 * for prose and 1.18 for JSON — a 13 % spread, and its cap of 2.0 is
 * unreachable, because `1 + 0.6 × 1.0` is 1.6 and a symbol ratio of 1.0 means a
 * string with no letters or digits in it at all. The shape was right and the
 * constants were written without measuring. They are re-derived here.
 *
 * ## What the numbers mean, stated so they can be argued with
 *
 * - Reading rate is **words a minute of English prose, read silently, on a
 *   screen, for comprehension**. The reference point is the commonly cited
 *   meta-analytic figure for silent reading of non-fiction, about 238 wpm, with
 *   a wide individual spread — roughly 175 to 300 for the middle of the range.
 * - `density` is a **comprehension** multiplier and nothing else. The ink
 *   correction already happened in `readingWords`; this is the separate claim
 *   that a character of JSON costs more thought than a character of English.
 * - The assumption pinned by `DENSITY_SLOPE`: at the measured symbol ratio of
 *   real source code (0.17), a character costs about **1.35×** what the same
 *   character of prose costs. Together with the ink correction that makes code
 *   roughly 1.8× slower than prose per character, which is the right order —
 *   code is read non-linearly and re-read, and every eye-tracking study of code
 *   reading finds it far slower than prose. It is a *claim*, it is written down
 *   here, and `estimate.test.ts` fails if anybody changes it by accident.
 *
 * ## What this module deliberately does not do
 *
 * It does not decide when to advance. It answers "how long would this take to
 * read"; `pacer.ts` decides what to do with that answer, and the reader
 * overrules both. The estimate is a default, never an authority — which is the
 * actual fix for the problem he named, because no formula is going to be right
 * for a specific person on a specific morning.
 */

/* ------------------------------------------------------------- the corpus -- */

/**
 * Characters per word in real prose, measured (p50 = 5.94, p10 = 5.25,
 * p90 = 6.80 over 8,294 assistant messages).
 *
 * This is the unit `readingWords` normalises to: one "reading word" is 5.9
 * characters of text with its whitespace collapsed. Rounded down from the
 * measurement rather than up, because rounding down counts *more* words and so
 * allows *more* time, and being slow costs one keypress while being fast costs
 * the reader the thread.
 */
export const PROSE_CHARS_PER_WORD = 5.9

/**
 * The share of visible characters that are neither letters nor digits, in real
 * prose (p50 = 0.07 over the same corpus).
 *
 * Prose is not symbol-free — it has full stops, commas, apostrophes and the
 * occasional backtick — so this is the baseline that `density` measures *from*.
 * Subtracting it is what makes a plain English stop land at exactly 1.0 instead
 * of at a number slightly above it for no reason anybody could explain.
 */
export const PROSE_SYMBOL_RATIO = 0.07

/**
 * How much slower a character gets per point of symbol ratio above prose.
 *
 * Derived from the target stated in the header: real source code measures a
 * symbol ratio of 0.17, and the assumption is that it costs 1.35× prose to
 * comprehend. So the slope is (1.35 − 1.00) / (0.17 − 0.07) = 3.5.
 *
 * What that produces on the measured corpus, at 200-character quotes:
 * prose 1.07, shell output 1.23, source code 1.28, stack traces 1.27, diffs
 * 1.38, JSON 1.60. A real spread, in the right order, with JSON — the one thing
 * in the table that is genuinely punishing to read off a screen — at the top.
 */
export const DENSITY_SLOPE = 3.5

/**
 * The ceiling on the comprehension multiplier.
 *
 * Reached at a symbol ratio of 0.36, which in the corpus is dense JSON and
 * nothing else. It is a real cap rather than the decorative one in the design
 * document: 3 % of 200-character JSON quotes hit it. Past this the estimate
 * stops being about reading and starts being about staring, and the honest
 * answer for a stop that dense is `HOLD_ABOVE_MS` — hand the reader the wheel.
 */
export const DENSITY_MAX = 2

/* -------------------------------------------------------------- the clock -- */

/**
 * Time between the box being drawn and the first word being read.
 *
 * Derived from the app's own tokens rather than picked: the box fades in over
 * `--dur` (200 ms in `tokens.css`), during which there is nothing legible to
 * fixate on, and finding a salient target and landing a fixation on it takes
 * roughly another 250 ms. `estimate.test.ts` reads `--dur` out of `tokens.css`
 * and fails if the two drift apart.
 *
 * It matters because of a specific failure: counting travel and fade time as
 * reading time is how a tour that looks correctly paced on paper feels rushed
 * on screen. The clock in `pacer.ts` does not start until the pane has settled,
 * and this is the allowance for the moment after that.
 */
export const FIXATION_MS = 450

/**
 * The shortest a stop may last.
 *
 * Under this a box appears and leaves inside one glance, which reads as a
 * flicker in the corner of the eye rather than as a thing the app meant to show
 * you — and a reader who sees a flicker rewinds, which costs far more than the
 * second this floor spends. It binds only on stops of about four words or
 * fewer; a two-word quote such as `npm test` lands exactly here.
 */
export const MIN_DWELL_MS = 1_400

/**
 * Above this, the tour stops driving itself and waits.
 *
 * **This is a hand-over, not a clamp**, and the distinction is the whole point:
 * a forty-second automatic stop is not pacing, it is being held hostage by a
 * progress ring. Past this the panel says *"long one — press → when you're
 * ready"* and nothing moves until the reader says so.
 *
 * The number is chosen against the estimate's own error rather than picked
 * round. An estimate for a specific person is comfortably ±30 % wrong; on a
 * 12-second stop that is under four seconds either way, which is recoverable,
 * and on a 40-second stop it is twelve, which is either a long stare at
 * something already finished or a yank away mid-sentence. 25 seconds is where
 * that cost stops being worth automating.
 *
 * Measured consequence, at the default pace: quotes up to about 400 characters
 * of prose auto-advance, and 7 % of 300-character stops hand over. That is the
 * pacing engine telling the tour's author something true — **a 600-character
 * quote is two stops, not one** — rather than quietly racing the reader through
 * it. `MAX_QUOTE_CHARS` is a budget ceiling, not a target.
 */
export const HOLD_ABOVE_MS = 25_000

/* --------------------------------------------------------------- the pace -- */

export type PaceName = 'unhurried' | 'relaxed' | 'steady' | 'brisk' | 'quick'

export interface Pace {
  readonly name: PaceName
  /** What the control says. Never a number — see `PACES` below. */
  readonly label: string
  readonly wpm: number
}

/**
 * The speed preference, in human terms.
 *
 * Five named paces spanning **110 to 330 words a minute — exactly 3.0×**, which
 * is the spread real readers actually cover: the meta-analytic middle for
 * silent reading of non-fiction sits near 238 wpm, slow readers run near 110
 * and fast ones past 330.
 *
 * Named rather than numeric, and that is not decoration. Nobody knows their own
 * reading speed in words a minute — it is not a fact anybody has ever been told
 * about themselves — so a spinner reading "190" is a control that can only be
 * set by trial and error. What a person *can* answer is "was that too fast?".
 * So the control shows a name and, beside it, how long a real paragraph gets at
 * that pace (`paceSampleMs`), computed by this very module. The label cannot
 * drift from the behaviour because it is derived from it.
 *
 * The design document specifies a `NumberSetting` of words-a-minute in
 * `settings-schema.ts` instead. Two reasons that is not what shipped here.
 * First, it is the wrong unit for the person setting it, per the paragraph
 * above. Second, it would not work: `SettingsWindow.tsx` maps the `copilot`
 * section to a bespoke `CopilotSection`, which renders none of the schema's
 * rows, so a setting declared into that section is declared and drawn nowhere —
 * and `settings/nothing-dropped.test.tsx` exists precisely to fail on that.
 */
export const PACES: readonly Pace[] = [
  { name: 'unhurried', label: 'Unhurried', wpm: 110 },
  { name: 'relaxed', label: 'Relaxed', wpm: 150 },
  { name: 'steady', label: 'Steady', wpm: 190 },
  { name: 'brisk', label: 'Brisk', wpm: 250 },
  { name: 'quick', label: 'Quick', wpm: 330 },
]

/**
 * Where an untouched install starts.
 *
 * 190 wpm, which is about 0.8× the meta-analytic average for silent reading of
 * non-fiction (238) and sits inside the measured spread rather than below it.
 * The 0.8 is the asymmetry, not modesty: **being too fast and being too slow
 * are not equally bad.** Too slow costs one keypress on `→`. Too fast means he
 * loses the thread, rewinds, and — the expensive part — learns that the tour
 * cannot be trusted to wait for him, which is a one-way door on a feature whose
 * whole value is that he does not have to read the sessions himself.
 *
 * So the default errs in the direction whose failure is cheap, and `density`
 * pushes it slower again on anything code-shaped.
 */
export const DEFAULT_PACE: PaceName = 'steady'

/** The slowest and fastest a person can ask for, from `PACES`. */
export const SLOWEST_WPM = PACES[0].wpm
export const FASTEST_WPM = PACES[PACES.length - 1].wpm

export function paceFor(name: PaceName): Pace {
  // Total by construction: `PaceName` is the union of the names in the table,
  // so the find cannot miss. The non-null assertion is avoided by falling back
  // to the default, which is also what a corrupted stored value deserves.
  return PACES.find((pace) => pace.name === name) ?? PACES[2]
}

/* ------------------------------------------------------- the learned part -- */

/**
 * A pace, plus what the app has learned about this reader at it.
 *
 * The split is deliberate and it is the answer to "why is there a knob *and* a
 * measurement". `pace` is a **choice** — the reader's declared speed, which
 * only they may change. `scale` is a **measurement** — a correction the player
 * derives from how they actually behave, which is never presented as a control
 * because there is nothing sensible for a person to type into it.
 */
export interface ReadingSpeed {
  readonly pace: PaceName
  /** Multiplies the pace's wpm. 1 means "the named pace, unmodified". */
  readonly scale: number
}

export const DEFAULT_SPEED: ReadingSpeed = { pace: DEFAULT_PACE, scale: 1 }

/**
 * How much of a new observation to believe.
 *
 * 0.35 converges inside about four stops — which matters, because a tour is
 * around a dozen stops and a correction that needed twenty would never arrive.
 * Higher than that and one long interruption rewrites the reader's speed.
 */
export const LEARN_ALPHA = 0.35

/**
 * The most one observation is allowed to claim.
 *
 * A single sample says "he was twice as fast" or "half as fast" and no more.
 * Without this, one `→` pressed a beat after the box appears is a sample of 15,
 * and the EWMA — which is supposed to smooth — carries a fifth of that
 * nonsense forward into the next four stops.
 */
export const MAX_SAMPLE = 2
export const MIN_SAMPLE = 0.5

/**
 * The band the stored correction lives in.
 *
 * Wider than one observation may move it, because a genuinely fast reader
 * should be able to accumulate to the top of it. The *effect* is bounded
 * separately and more tightly — see `effectiveWpm`.
 */
export const MIN_SCALE = 0.4
export const MAX_SCALE = 2.5

/**
 * The reading rate actually used, given a pace and what has been learned.
 *
 * Clamped to the range the five named paces span, and that clamp is the rule
 * worth stating on its own: **the learned correction can never take the reader
 * somewhere they could not have chosen by hand.** If the measurement decides he
 * reads at 600 wpm, the tour goes as fast as `Quick` and no faster. A tour
 * running at a speed with no name, that the reader never picked and cannot
 * un-pick, is the exact failure the whole "the reader is the authority" line
 * exists to prevent — and it would arrive by silent accumulation, which is the
 * worst way for it to arrive.
 */
export function effectiveWpm(speed: ReadingSpeed): number {
  const raw = paceFor(speed.pace).wpm * clamp(speed.scale, MIN_SCALE, MAX_SCALE)
  return clamp(raw, SLOWEST_WPM, FASTEST_WPM)
}

/**
 * Fold one observation into the learned correction.
 *
 * `sample` is estimated-over-observed: above 1 means the reader got through it
 * faster than predicted and the tour should speed up; below 1 means slower.
 * Callers must only produce a sample from **evidence** — see `pacer.ts`, which
 * is deliberate about which of the reader's behaviours count as evidence and
 * which are just a person looking at their phone.
 */
export function learn(speed: ReadingSpeed, sample: number): ReadingSpeed {
  if (!Number.isFinite(sample) || sample <= 0) return speed
  const bounded = clamp(sample, MIN_SAMPLE, MAX_SAMPLE)
  const next = speed.scale + LEARN_ALPHA * (bounded - speed.scale)
  return { pace: speed.pace, scale: clamp(next, MIN_SCALE, MAX_SCALE) }
}

/** Forget the measurement, keep the choice. What the Reset beside it does. */
export function forgetLearned(speed: ReadingSpeed): ReadingSpeed {
  return { pace: speed.pace, scale: 1 }
}

/**
 * Whatever came back from storage, made into a speed.
 *
 * Forgiving in one direction and strict in the other, on the same principle
 * `copilot-model.ts` states: a field that cannot be read becomes the default
 * rather than an exception, because a window that will not open because a
 * preferences file lost a key is a worse failure than one that starts at
 * Steady. Nothing is invented, though — an unreadable pace does not become a
 * *nearby* pace, it becomes the documented default.
 */
export function normalizeSpeed(raw: unknown): ReadingSpeed {
  if (typeof raw !== 'object' || raw === null) return DEFAULT_SPEED
  const value = raw as Record<string, unknown>
  const pace = PACES.some((p) => p.name === value.pace) ? (value.pace as PaceName) : DEFAULT_PACE
  const scale =
    typeof value.scale === 'number' && Number.isFinite(value.scale) && value.scale > 0
      ? clamp(value.scale, MIN_SCALE, MAX_SCALE)
      : 1
  return { pace, scale }
}

/* ---------------------------------------------------------- the estimate -- */

/** The two pieces of text a stop puts in front of the reader. */
export interface PacedStop {
  /** Verbatim content lifted off another session. Any shape: prose, code, JSON. */
  readonly quote: string
  /** The copilot's one line about why it matters. Always prose. */
  readonly note: string
}

export interface TextStats {
  /** Visible characters, with runs of whitespace collapsed to one space. */
  readonly chars: number
  /** Whitespace-separated tokens. */
  readonly tokens: number
  /** What the estimate counts: tokens, or prose-sized words, whichever is more. */
  readonly words: number
  /** Share of non-whitespace characters that are neither letters nor digits. */
  readonly symbolRatio: number
  /** The comprehension multiplier this text earns. 1 for plain prose. */
  readonly density: number
}

/**
 * Everything the estimate needs to know about a piece of text.
 *
 * `words` is `max(tokens, chars / PROSE_CHARS_PER_WORD)` and the `max` is doing
 * real work at both ends.
 *
 * Without the character term, a 600-character base64 blob with no spaces in it
 * counts as **one word** and gets the 1.4-second floor — a stop that flashes
 * past something nobody could have read. Without the token term, a sentence of
 * short words ("I do not know if it is on or off": 32 characters, 11 words)
 * counts as 5.4 words and gets half the time it needs; real prose measures as
 * low as 5.25 characters a word at the tenth percentile, so this is not a
 * contrived case.
 *
 * Taking the larger of the two is the conservative reading in both directions,
 * and conservative here means *slower*, which is the failure that costs one
 * keypress.
 */
export function textStats(text: string): TextStats {
  const collapsed = text.replace(/\s+/g, ' ').trim()
  if (collapsed === '') {
    return { chars: 0, tokens: 0, words: 0, symbolRatio: 0, density: 1 }
  }
  const tokens = collapsed.split(' ').filter((word) => word !== '').length
  const words = Math.max(tokens, collapsed.length / PROSE_CHARS_PER_WORD)

  let visible = 0
  let symbols = 0
  for (const character of collapsed) {
    if (character === ' ') continue
    visible += 1
    // Unicode property escapes rather than [a-zA-Z0-9]: a session's output is
    // full of non-ASCII letters — the prompt glyph, box-drawing, accented names
    // in a path — and classing every one of them as a "symbol" would mark an
    // ordinary sentence as dense because somebody's surname has an accent in it.
    if (!/[\p{L}\p{N}]/u.test(character)) symbols += 1
  }
  const symbolRatio = visible === 0 ? 0 : symbols / visible

  return { chars: collapsed.length, tokens, words, symbolRatio, density: densityFor(symbolRatio) }
}

/**
 * The comprehension multiplier for a measured symbol ratio.
 *
 * Floored at 1 rather than allowed below it, because the pace *is* the prose
 * rate — text cannot be easier to read than prose, only harder. Prose measured
 * below the baseline (the tenth percentile is 0.04) lands at exactly 1.
 */
export function densityFor(symbolRatio: number): number {
  const above = Math.max(0, symbolRatio - PROSE_SYMBOL_RATIO)
  return clamp(1 + DENSITY_SLOPE * above, 1, DENSITY_MAX)
}

/** Pure reading time for one piece of text, with no fixation allowance. */
export function readingTimeMs(text: string, wpm: number): number {
  const stats = textStats(text)
  if (stats.words === 0) return 0
  return (stats.words / wpm) * 60_000 * stats.density
}

/**
 * How long to hold on a stop before moving to the next one.
 *
 * The quote and the note are measured **separately and added**, rather than
 * concatenated and measured once. They are different reading: the note is
 * always the copilot's own prose and the quote is whatever was on somebody
 * else's screen. Joining them averages the two symbol ratios, so a one-line
 * prose note attached to a JSON blob drags the blob's density down and the
 * reader gets less time for the hard half than they would have had on its own.
 *
 * The result is floored but **not** ceilinged. Anything above `HOLD_ABOVE_MS`
 * is a real number that `pacer.ts` uses to decide to stop driving; clamping it
 * here would throw away the very fact that decision needs.
 */
export function stopDwellMs(stop: PacedStop, speed: ReadingSpeed): number {
  const wpm = effectiveWpm(speed)
  const reading = readingTimeMs(stop.quote, wpm) + readingTimeMs(stop.note, wpm)
  return Math.max(MIN_DWELL_MS, FIXATION_MS + reading)
}

/** True when a stop is long enough that the reader should be handed the wheel. */
export function isHold(dwell: number): boolean {
  return dwell > HOLD_ABOVE_MS
}

/**
 * A real paragraph, used to say what each pace *feels* like.
 *
 * The speed control shows "a paragraph like this gets about N seconds" beside
 * every option, and this is the paragraph. It has to be representative rather
 * than convenient, so it is written the way the copilot's notes and the
 * sessions' prose actually read — one plain sentence about a session, one
 * clause of detail — and `estimate.test.ts` pins its shape: prose-density, and
 * a length inside the band real quotes occupy.
 */
export const SAMPLE_PARAGRAPH =
  'The migration ran twice against the same database — the retry never checked ' +
  'whether the first attempt had already committed — so `orders` and `order_items` ' +
  'now hold duplicate rows, and the session has stopped to ask what you want done ' +
  'about it.'

/** How long the sample paragraph gets at a pace, before any learning. */
export function paceSampleMs(pace: PaceName): number {
  return stopDwellMs({ quote: SAMPLE_PARAGRAPH, note: '' }, { pace, scale: 1 })
}

/**
 * The sample time as the speed control says it, rounded to the second.
 *
 * Finer than `aboutDuration`, which buckets to five seconds and is right for a
 * countdown nobody should read as a promise. Here the number is the *only*
 * difference between two options in a list, and at five-second buckets Steady
 * and Brisk both came out as "about 15 sec" — two radio buttons with identical
 * descriptions, which is a control that cannot be used for the thing it exists
 * for. `estimate.test.ts` pins that all five stay distinct.
 */
export function paceSampleLabel(pace: PaceName): string {
  return `about ${Math.round(paceSampleMs(pace) / 1000)} seconds`
}

/* --------------------------------------------------------------- helpers -- */

export function clamp(value: number, low: number, high: number): number {
  return Math.min(high, Math.max(low, value))
}
