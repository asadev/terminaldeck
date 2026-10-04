/**
 * Turning what Stays Fixed says into what the page and the tools say.
 *
 * Every function here is pure: raw JSON in (from `doctor --json`, `init --json`,
 * `check`, `ship --json`, `.staysfixed/v2/last-check.json`), a plain shape out.
 * The engine's own JSON is written for an agent — dense, exhaustive, with every
 * caveat inline — and this app's reader is a person who did not write the code.
 * So the translation is in one place, against shapes measured from real runs
 * (`read.test.ts` holds trimmed copies of them), and nothing downstream parses
 * the engine's output a second way.
 *
 * ## The rule the results follow
 *
 * Only the differences nobody asked for are listed. Everything unchanged is one
 * line with a count, never a list — the engine already leaves unchanged things
 * out, and this keeps it that way rather than "helpfully" showing the 51 steady
 * addresses. What was *not* looked at is also one line; the full list is in the
 * report, where somebody who wants it can read every word.
 *
 * ## Words
 *
 * The engine's own words are used wherever they are already plain — a finding's
 * title, a gap's `what`/`why`/`fix` were written for a person on purpose (see
 * Stays Fixed's `docs/getting-started.md`). What is rewritten is what was
 * written for an agent: the capitalised `NOT EVERYTHING WAS CHECKED`, `staysfixed
 * ship` as a fix (here it is a button), and escaped `\n` inside quoted values.
 */

import { STAYS_FIXED } from '../../shared/stays-fixed'

/* ----------------------------------------------------------------- types -- */

/** How the last check came out, in the four ways a person can act on. */
export type FixedVerdict = 'clean' | 'differences' | 'not-compared' | 'could-not-run'

export interface FixedChange {
  /** What moved, in the engine's plain description of it. */
  what: string
  before: string | null
  after: string | null
  kind: 'changed' | 'appeared' | 'vanished'
}

/** File names, relative to the run's picture folder; the service turns them into images. */
export interface FixedPictureFiles {
  journey: string
  before: string | null
  after: string | null
}

export interface FixedDifference {
  id: string
  title: string
  /** No agent may wave this through: money, signing in, lost data, a crash, or a bug already fixed once. */
  needsPerson: boolean
  needsPersonWhy: string
  /** How many places this one cause shows up in. */
  count: number
  changes: FixedChange[]
  /** Changes in this finding not shown in `changes`. */
  more: number
  journeys: string[]
}

export interface FixedResults {
  runId: string
  at: string
  durationMs: number
  verdict: FixedVerdict
  /** One line. */
  headline: string
  /** The known-good build this was compared against, by name, or null. */
  against: string | null
  /** The build that was checked, by name. */
  checked: string
  differences: FixedDifference[]
  /** One line about everything that did not change. Never a list. */
  unchanged: string
  /** One line about what was not looked at, or null when everything was. */
  notChecked: string | null
  /** Addresses that used to give one answer and now give two. */
  unsteady: number
  /** The engine's own paragraph, for the full report. */
  detail: string
  /** Every coverage gap, for the full report. */
  gaps: Array<{ what: string; why: string; unlockedBy: string }>
}

export interface FixedGap {
  /** What kind of product this is about: "websites", "the `greet` command". */
  name: string
  what: string
  why: string
  fix: string
  /** Only a person can do it — a licence, a device, a password. */
  byPerson: boolean
  unlocks: string
}

export interface FixedReadiness {
  /** Kinds of product that can be checked here right now. */
  ready: string[]
  gaps: FixedGap[]
  /** Kinds this machine cannot check, or that this project does not have. One line on the page. */
  notHere: string[]
  /** The engine's own paragraph about what a clean run would mean here. */
  summary: string
  /** Null when the answer did not say. */
  git: boolean | null
}

export interface FixedSetupOutcome {
  ok: boolean
  /** Files written, project-relative where possible. */
  wrote: string[]
  /** Why it did not work, in a sentence, when it did not. */
  problem: string | null
  readiness: FixedReadiness | null
}

export interface FixedMarkOutcome {
  ok: boolean
  /** The known-good build moved. */
  marked: boolean
  /** It was already the known-good build. */
  already: boolean
  /** It would not move without being forced, and why, in a sentence. */
  refused: string | null
  /**
   * What the refusal is about, so the page can offer the right next step:
   * `differences` — "mark good anyway" is a real choice;
   * `unchecked` — run a check first, and only that.
   */
  refusedFor: 'differences' | 'unchecked' | null
  /** One line. */
  summary: string
}

export interface FixedGuard {
  name: string
  because: string
  file: string
}

export interface FixedReference {
  buildId: string
  /** What to call it: its version, its commit, or its id. */
  name: string
  setAt: string
  setBy: string
  forced: boolean
}

export interface FixedDescription {
  product: string | null
  guards: FixedGuard[]
  guardProblem: string | null
  reference: FixedReference | null
}

/* -------------------------------------------------------------- helpers -- */

type Raw = Record<string, unknown>

function obj(value: unknown): Raw {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Raw) : {}
}

function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function str(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function num(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`
}

/** Longest value shown inline in a change before it is cut. The report has them whole. */
export const MAX_VALUE_CHARS = 400
/** Changes shown under one difference; the rest are counted. */
export const MAX_CHANGES = 6

/**
 * A value, as text a person can read.
 *
 * Strings stay strings — with their real line breaks, which the page draws in a
 * monospaced block — and anything else is JSON. Long values are cut with the
 * count of what was cut, because "…" alone reads as "that is the whole thing".
 */
export function valueText(value: unknown, whole = false): string | null {
  if (value === undefined || value === null) return null
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  if (text === undefined) return null
  if (whole || text.length <= MAX_VALUE_CHARS) return text
  return `${text.slice(0, MAX_VALUE_CHARS)}… (${text.length - MAX_VALUE_CHARS} more characters)`
}

/**
 * A finding's title without the escape sequences JSON put inside its quotes.
 *
 * The engine quotes values with `JSON.stringify`, so a printed line break in a
 * title arrives as the two characters `\n`. Shown raw that is noise; a real
 * line break would break the title. A space is what a person would have typed.
 */
export function plainTitle(title: string): string {
  return title.replace(/\\n/g, ' ').replace(/\\t/g, ' ').replace(/\\"/g, '"').replace(/\s{2,}/g, ' ').trim()
}

/** A build, named the way a person would name it: its version, its commit, or its id. */
export function buildName(build: unknown): string {
  const b = obj(build)
  const version = str(b.version)
  if (version !== '') return version
  const sha = str(b.gitSha)
  if (sha !== '') return sha.slice(0, 7)
  return str(b.id, 'this build')
}

/** Stays Fixed's `fileSafe` (src/v2/adapters/web.js), for matching the pictures it named. */
export function fileSafe(name: string): string {
  const clean = String(name).replace(/[^A-Za-z0-9._-]+/g, '-')
  return clean === '' ? 'checkpoint' : clean
}

/* -------------------------------------------------------------- results -- */

/**
 * A check's answer, as the page and the tools present it.
 *
 * `raw` is the verdict object `check --json` prints (or the `result` field of
 * `last-check.json`, which is the same object). An `{error}` object — what the
 * check script prints when the engine refused to run — becomes a
 * `could-not-run` result carrying the engine's sentence.
 */
export function toResults(raw: unknown, ranAt?: string, options: { full?: boolean } = {}): FixedResults {
  const v = obj(raw)
  const error = obj(v.error)
  const findings = arr(v.findings).map(obj)
  const coverage = obj(v.coverage)
  const reference = obj(v.reference)
  const candidate = obj(v.candidate)
  const at = str(v.startedAt, ranAt ?? new Date(0).toISOString())
  const base = {
    runId: str(v.runId),
    at,
    durationMs: num(v.durationMs),
    against: str(reference.id) === '' ? null : buildName(reference),
    checked: buildName(candidate),
    detail: str(v.summary),
    gaps: arr(coverage.gaps)
      .map(obj)
      .map((gap) => ({ what: str(gap.what), why: str(gap.why), unlockedBy: str(gap.unlockedBy) }))
      .filter((gap) => gap.what !== ''),
  }

  if (str(error.message) !== '' || v.blocked === true) {
    // A blocked verdict (`blocked()` in the engine's check.js) carries its reason
    // as the one coverage gap, "Everything.", whose `why` is the error itself.
    const blockedWhy = str(obj(arr(coverage.gaps)[0]).why)
    const why = str(error.message) || blockedWhy || str(v.summary) || 'The check could not run.'
    const hint = str(error.hint)
    return {
      ...base,
      verdict: 'could-not-run',
      headline: hint === '' ? why : `${why} ${hint}`,
      differences: [],
      unchanged: '',
      notChecked: null,
      unsteady: 0,
    }
  }

  const limit = options.full === true ? Number.POSITIVE_INFINITY : MAX_CHANGES
  const differences = findings.map((finding) => toDifference(finding, limit))
  const shown = differences.reduce((sum, d) => sum + d.count, 0)
  const paths = num(coverage.paths)
  const unsteady = arr(v.newlyUnstable).length
  const notCompared = str(reference.id) === '' || typeof v.comparedNothing === 'string'

  let verdict: FixedVerdict
  let headline: string
  if (notCompared) {
    verdict = 'not-compared'
    // Short, because it is the page's title line; the line under it says why
    // ("No build is marked as good yet") and the button beside it is the fix.
    headline =
      str(reference.id) === ''
        ? 'Nothing to compare against yet. Mark this build as good to start.'
        : 'Nothing was compared: the good build never walked these steps. Mark this build as good to start.'
  } else if (differences.length === 0 && unsteady === 0) {
    verdict = 'clean'
    headline = 'Nothing that worked has changed.'
  } else {
    verdict = 'differences'
    const parts: string[] = []
    if (differences.length > 0) parts.push(`${plural(differences.length, 'difference')} nobody asked for`)
    if (unsteady > 0) parts.push(`${plural(unsteady, 'thing')} that used to give one answer and now gives two`)
    headline = `${parts.join(', and ')}.`
  }

  const unchangedCount = Math.max(0, paths - shown)
  const unchanged =
    notCompared || paths === 0
      ? ''
      : differences.length === 0
        ? `All ${plural(paths, 'thing')} it looked at ${paths === 1 ? 'is' : 'are'} unchanged.`
        : `Everything else it looked at — ${plural(unchangedCount, 'thing')} — is unchanged.`

  return {
    ...base,
    verdict,
    headline,
    differences,
    unchanged,
    notChecked: notCheckedLine(coverage, num(v.doorsNeverOpened)),
    unsteady,
  }
}

function toDifference(f: Raw, limit: number): FixedDifference {
  const all = arr(f.differences).map(obj)
  const sealedBy = obj(f.sealedBy)
  const needsPerson = f.sealed === true || f.unwaivable === true
  const changes: FixedChange[] = all.slice(0, limit).map((d) => {
    const kind = str(d.kind)
    return {
      what: str(d.describe) || str(d.path),
      before: valueText(d.reference, limit === Number.POSITIVE_INFINITY),
      after: valueText(d.candidate, limit === Number.POSITIVE_INFINITY),
      kind: kind === 'appeared' || kind === 'vanished' ? kind : 'changed',
    }
  })
  const journeys = [...new Set(all.map((d) => str(d.journey)).filter((j) => j !== ''))]
  return {
    id: str(f.id),
    title: plainTitle(str(f.title, 'Something changed.')),
    needsPerson,
    needsPersonWhy: needsPerson ? str(f.unwaivableWhy) || str(sealedBy.why) || 'A person has to look at this one.' : '',
    count: Math.max(num(f.count, all.length), all.length, 1),
    changes,
    more: Math.max(0, all.length - changes.length),
    journeys,
  }
}

/**
 * What was not looked at, in one line, or null when everything was.
 *
 * Built from the counts rather than from the engine's sentence, which starts
 * `NOT EVERYTHING WAS CHECKED:` in capitals for an agent that skims. The
 * numbers are the same numbers; the full list is in the report.
 */
export function notCheckedLine(coverage: unknown, doorsNeverOpened: number): string | null {
  const gaps = arr(obj(coverage).gaps).length
  const doors = Math.max(0, doorsNeverOpened)
  if (gaps === 0 && doors === 0) return null
  const parts: string[] = []
  if (doors > 0) parts.push(`${plural(doors, 'way')} into it ${doors === 1 ? 'was' : 'were'} never walked`)
  if (gaps > 0) parts.push(`${plural(gaps, 'other thing')} ${gaps === 1 ? 'was' : 'were'} not looked at`)
  return `Not everything was checked: ${parts.join(', and ')}. The full report lists each one.`
}

/**
 * Which kept pictures belong to which difference.
 *
 * The engine names each picture `<build>-<run>-<journey>-<checkpoint>.png`
 * (`adapters/web.js`, through its own `fileSafe`), and a run that proved a
 * difference walked the old build live, so the folder holds both sides. "After"
 * is the checked build's first run (`-a-`), "before" the old build's live run.
 * Anything that does not match — a name long enough to have been hashed, a
 * product with no screen — is simply left without a picture.
 */
export function picturesFor(
  difference: Pick<FixedDifference, 'journeys'>,
  files: readonly string[],
  candidateId: string,
  referenceId: string | null,
): FixedPictureFiles[] {
  const out: FixedPictureFiles[] = []
  for (const journey of difference.journeys.slice(0, 2)) {
    const tag = `-${fileSafe(journey)}-`
    const of = (build: string): string[] =>
      files.filter((file) => file.endsWith('.png') && file.startsWith(`${fileSafe(build)}-`) && file.includes(tag)).sort()
    const mine = of(candidateId)
    const after = mine.find((file) => file.startsWith(`${fileSafe(candidateId)}-a-`)) ?? mine[0] ?? null
    const before = referenceId !== null && referenceId !== candidateId ? (of(referenceId)[0] ?? null) : null
    if (after !== null || before !== null) out.push({ journey, before, after })
  }
  return out
}

/* ------------------------------------------------------------ readiness -- */

const DOCTOR_READY = 'ready'
const DOCTOR_PERSON = 'only a person can do this'
const DOCTOR_IMPOSSIBLE = 'not possible here'

/**
 * Does this need stand for "mark a build as good"?
 *
 * The engine names that step as the command `staysfixed ship`, and it is the
 * page's own button here. Listed as a gap with a command beside it, it would be
 * telling somebody to open a terminal to do what the button above it does.
 */
function isTheShipStep(need: Raw): boolean {
  return /staysfixed ship/.test(str(need.fix))
}

function gapOf(name: string, need: Raw): FixedGap {
  return {
    name,
    what: str(need.what),
    why: str(need.why),
    fix: str(need.fix),
    byPerson: need.automatic === false || str(need.who) === 'a person' || str(need.who) === 'you',
    unlocks: str(need.unlocks),
  }
}

/** What `staysfixed doctor --json` says this machine can check, for a project that is not set up yet. */
export function readinessFromDoctor(raw: unknown): FixedReadiness {
  const d = obj(raw)
  const ready: string[] = []
  const gaps: FixedGap[] = []
  const notHere: string[] = []
  for (const surface of arr(d.surfaces).map(obj)) {
    const name = str(surface.name, str(surface.id))
    const state = str(surface.state)
    if (state === DOCTOR_READY) ready.push(name)
    else if (state === DOCTOR_IMPOSSIBLE) notHere.push(name)
    else {
      const needs = arr(surface.needs).map(obj).filter((need) => !isTheShipStep(need))
      for (const need of needs) gaps.push({ ...gapOf(name, need), byPerson: need.automatic === false || state === DOCTOR_PERSON })
      if (needs.length === 0) ready.push(name)
    }
  }
  const project = obj(d.project)
  const git = typeof project.isGitRepo === 'boolean' ? project.isGitRepo : null
  if (git === false) {
    gaps.unshift({
      name: 'this folder',
      what: 'a git repository',
      why: `${STAYS_FIXED} puts an old build back with git to compare against it, and refuses a folder with no git rather than compare against a guess.`,
      fix: 'git init',
      byPerson: false,
      unlocks: 'Every check in this folder.',
    })
  }
  return { ready, gaps, notHere, summary: str(obj(d.covers).short), git }
}

/**
 * What `staysfixed init --json` (or `--dry-run`) says about this project's own
 * products — the set-up project's answer, per thing it makes rather than per
 * kind of thing in the world.
 */
export function readinessFromPlan(raw: unknown): FixedReadiness {
  const plan = obj(obj(raw).plan)
  const ready: string[] = []
  const gaps: FixedGap[] = []
  const notHere: string[] = []
  for (const product of arr(plan.readiness).map(obj)) {
    const name = str(product.product, str(product.kind))
    const state = str(product.state)
    if (state === DOCTOR_READY) ready.push(name)
    else if (state === DOCTOR_IMPOSSIBLE) notHere.push(name)
    for (const need of arr(product.needs).map(obj)) {
      if (!isTheShipStep(need)) gaps.push({ ...gapOf(name, need), byPerson: state === DOCTOR_PERSON || need.automatic === false })
    }
  }
  const needs = obj(plan.needs)
  const seen = new Set(gaps.map((gap) => `${gap.what}|${gap.fix}`))
  for (const need of arr(needs.person).map(obj)) {
    if (isTheShipStep(need) || seen.has(`${str(need.what)}|${str(need.fix)}`)) continue
    gaps.push({ ...gapOf('this project', need), byPerson: true })
  }
  return { ready, gaps, notHere, summary: str(obj(plan.covers).short), git: null }
}

/** `staysfixed init --json`, as the Set up button reports it. */
export function toSetupOutcome(raw: unknown, root: string | readonly string[], failure: string | null): FixedSetupOutcome {
  // The engine names files by their real path, and a folder under a symlink —
  // every temporary folder on a Mac is `/var` → `/private/var` — has two.
  const roots = typeof root === 'string' ? [root] : root
  const v = obj(raw)
  if (failure !== null && Object.keys(v).length === 0) return { ok: false, wrote: [], problem: failure, readiness: null }
  const problems = arr(v.problems).map((p) => (typeof p === 'string' ? p : str(obj(p).message, str(obj(p).what))))
  const wrote = arr(v.written)
    .map((file) => str(file))
    .filter((file) => file !== '')
    .map((file) => {
      const under = roots.find((one) => file.startsWith(`${one}/`))
      return under === undefined ? file : file.slice(under.length + 1)
    })
  const ok = v.ok !== false && problems.length === 0
  return {
    ok,
    wrote,
    problem: ok ? null : problems.join(' ') || failure || 'Set up did not finish.',
    readiness: Object.keys(obj(v.plan)).length > 0 ? readinessFromPlan(v) : null,
  }
}

/* ------------------------------------------------------------- marking -- */

/** `staysfixed ship --json`, as "Mark this build as good" reports it. */
export function toMarkOutcome(raw: unknown, failure: string | null): FixedMarkOutcome {
  const v = obj(raw)
  if (Object.keys(v).length === 0) {
    return { ok: false, marked: false, already: false, refused: null, refusedFor: null, summary: failure ?? 'It could not be marked.' }
  }
  const decision = obj(v.decision)
  const state = str(decision.state)
  const marked = v.cut === true
  const already = v.unchanged === true || state === 'already-the-reference'
  const refused = marked || already ? null : str(v.refused) || str(decision.refusal) || null
  const refusedFor =
    refused === null ? null : state === 'broken' ? 'differences' : 'unchecked'
  let summary: string
  if (marked) summary = 'Marked as good. Every check from now on compares against this build.'
  else if (already) summary = 'This build is already the one marked as good.'
  else if (refusedFor === 'differences') {
    const n = num(decision.findings)
    summary = `The last check found ${n > 0 ? plural(n, 'difference') : 'differences'} nobody asked for. Marking this build as good makes ${n === 1 ? 'it' : 'them'} the new normal.`
  } else if (state === 'blocked') summary = 'The last check of this build could not run. Run a check first, then mark it as good.'
  else if (state === 'nothing-observed') summary = 'The last check of this build looked at nothing. Run a check first, then mark it as good.'
  else summary = 'This build has not been checked yet. Run a check first, then mark it as good.'
  return { ok: v.ok !== false, marked, already, refused, refusedFor, summary }
}

/* ------------------------------------------------------------- describe -- */

/** The describe script's answer. See `DESCRIBE_SCRIPT` in `engine.ts`. */
export function toDescription(raw: unknown): FixedDescription {
  const v = obj(raw)
  const ref = obj(v.reference)
  const buildId = str(ref.buildId)
  return {
    product: str(v.product) || null,
    guards: arr(v.guards)
      .map(obj)
      .map((g) => ({ name: str(g.name), because: str(g.because), file: str(g.file) }))
      .filter((g) => g.name !== ''),
    guardProblem: str(v.guardProblem) || null,
    reference:
      buildId === ''
        ? null
        : {
            buildId,
            name: buildName({ id: buildId, version: ref.version, gitSha: ref.gitSha }),
            setAt: str(ref.setAt),
            setBy: str(ref.setBy),
            forced: ref.forced === true,
          },
  }
}

/**
 * `.staysfixed/v2/last-check.json` — the last check anybody ran here, an agent
 * over MCP included — as results. Null when there is none or it cannot be read.
 *
 * The file carries the whole verdict as a JSON string under `result`, which is
 * the object `check --json` prints, so it goes through the same reader.
 */
export function lastRunFromFile(text: string): FixedResults | null {
  try {
    const record = obj(JSON.parse(text) as unknown)
    const result = typeof record.result === 'string' ? (JSON.parse(record.result) as unknown) : record.result
    if (Object.keys(obj(result)).length === 0) return null
    return toResults(result, str(record.at) || undefined)
  } catch {
    return null
  }
}
