/**
 * Asking a site for the big copy of a file, and never losing the small one.
 *
 * ## The loss
 *
 * Almost every image on the web is served at several sizes, and the sizes are
 * usually one path segment or one query parameter apart:
 *
 *     .../images/498/floorplan.jpg      .../images/1920/floorplan.jpg
 *     .../photo.jpg?w=498               .../photo.jpg?w=1920
 *     .../photo_thumb.jpg               .../photo.jpg
 *
 * Asad's pipeline captured **62,000 images at 498 pixels** while the 1920-pixel
 * original was one word away in the URL. Nothing was broken; nobody had told it
 * the rule.
 *
 * ## The part that must not be got wrong
 *
 * A rewrite rule is a *guess about a stranger's URL scheme*. It will sometimes
 * be wrong, and when it is wrong the upgraded URL 404s — or, worse, answers 200
 * with an HTML error page under a `.jpg` name. So the rule this module is built
 * around is:
 *
 * > **A bad guess degrades to lower quality, never to nothing.** The original
 * > URL is always the last candidate and it is always tried.
 *
 * That is the difference between a run that comes home with 62,000 small images
 * and one that comes home with 62,000 zero-byte files, and it is the reason
 * {@link chooseRendition} cannot return "no answer": the original is appended to
 * the candidate list by construction, not by a fallback branch somebody could
 * later restructure away.
 *
 * ## And why a 200 is not enough
 *
 * A CDN handed a size it does not recognise very often answers 200 with a
 * placeholder, a redirect to a marketing page, or the *same* preview it was
 * already serving. Accepting those is worse than 404ing, because the run then
 * records an upgrade that never happened. So a candidate has to survive three
 * checks, each of which is a real failure that has been seen:
 *
 *  - the status is a success,
 *  - the body is not a page where a file was asked for,
 *  - and — when both sides state a length — the upgrade is not *smaller* than
 *    the original. That last one is on by default. It costs one extra `HEAD`
 *    against the original, and it is the only check that catches "the server
 *    politely served you the 498px preview again".
 *
 * ## What is not here
 *
 * No site's URL scheme. Not one. Every rule is supplied by the caller, because a
 * built-in rule for a named property portal is a guess this repository would be
 * making on somebody else's behalf, in a release, months before it is wrong.
 * {@link RENDITION_RULE_EXAMPLES} exists so the shape is obvious; it is
 * documentation and nothing reads it.
 */

/* ------------------------------------------------------------------ rules -- */

/**
 * One rewrite: a regular expression over the whole URL, and what to put back.
 *
 * Over the *whole* URL rather than over the path, because the two places a size
 * hides are the path and the query and a caller should not have to say which.
 */
export interface RenditionRule {
  /**
   * What the ledger and the download row record when this rule is the one that
   * won. A run that discovers its images are all wrong needs to know which rule
   * produced them, and a rule that cannot be named cannot be withdrawn.
   */
  id: string
  /** Regular-expression source, tested against the whole URL. */
  match: string
  /** The replacement, with `$1`-style back-references. */
  replace: string
  /** Regular-expression flags. `g` when a size appears twice in one URL. */
  flags?: string
}

/** Shapes that are worth knowing about, as documentation. Nothing reads this. */
export const RENDITION_RULE_EXAMPLES: readonly RenditionRule[] = Object.freeze([
  Object.freeze({ id: 'path-size', match: '/(\\d{2,4})/', replace: '/1920/' }),
  Object.freeze({ id: 'query-width', match: '([?&]w=)\\d+', replace: '$11920', flags: 'g' }),
  Object.freeze({ id: 'thumb-suffix', match: '_thumb(\\.[a-z]+)$', replace: '$1', flags: 'i' }),
])

/** Anything longer is not a rule somebody wrote; it is a payload. */
const MAX_RULE_CHARS = 400
const MAX_RULES = 20

/**
 * Read rules off a tool call or a settings file into rules that are safe to run.
 *
 * A regular expression from a caller is code this process executes, so the two
 * ways one goes wrong are both closed here rather than at the call site:
 *
 *  - it does not compile, which is refused with the engine's own message,
 *  - or it compiles and backtracks for ever on a long URL, which is not
 *    detectable by reading it. The length cap is the blunt half of that answer;
 *    the sharp half is that {@link applyRule} is only ever run against a URL,
 *    which is bounded, and never against a page.
 *
 * Throws with a sentence naming the rule, because a rule set that silently
 * dropped its third entry would produce a run that captured previews and said
 * nothing.
 */
export function readRenditionRules(raw: unknown): RenditionRule[] {
  if (raw === undefined || raw === null) return []
  if (!Array.isArray(raw)) throw new Error('rules must be a list')
  if (raw.length > MAX_RULES) throw new Error(`that is more than ${MAX_RULES} rules`)
  const rules: RenditionRule[] = []
  const seen = new Set<string>()
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) throw new Error('every rule must be an object')
    const value = entry as Record<string, unknown>
    const id = typeof value.id === 'string' ? value.id.trim() : ''
    const match = typeof value.match === 'string' ? value.match : ''
    const replace = typeof value.replace === 'string' ? value.replace : ''
    const flags = typeof value.flags === 'string' ? value.flags : ''
    if (id === '') throw new Error('every rule needs an id, so a bad one can be named and withdrawn')
    if (seen.has(id)) throw new Error(`two rules are called ${id}`)
    seen.add(id)
    if (match === '') throw new Error(`rule ${id} has no match`)
    if (match.length > MAX_RULE_CHARS || replace.length > MAX_RULE_CHARS) {
      throw new Error(`rule ${id} is longer than ${MAX_RULE_CHARS} characters`)
    }
    if (!/^[gimsuy]*$/.test(flags)) throw new Error(`rule ${id} has flags that are not flags`)
    try {
      // Compiled here so a broken expression is a refusal at the door rather
      // than an exception in the middle of a run of 60,000.
      void new RegExp(match, flags)
    } catch (error) {
      throw new Error(`rule ${id} is not a valid expression: ${
        error instanceof Error ? error.message : 'unknown reason'
      }`)
    }
    rules.push({ id, match, replace, ...(flags === '' ? {} : { flags }) })
  }
  return rules
}

/** One rule against one URL. The URL unchanged when it did not match. */
export function applyRule(url: string, rule: RenditionRule): string {
  try {
    return url.replace(new RegExp(rule.match, rule.flags ?? ''), rule.replace)
  } catch {
    // A rule that compiled at the door and threw here is not a reason to lose
    // the asset. The original is still in the candidate list.
    return url
  }
}

/* ------------------------------------------------------------- candidates -- */

export interface RenditionCandidate {
  url: string
  /** The rule that produced it. `''` is the original, and it is always last. */
  ruleId: string
}

/**
 * Every URL worth trying, best first, original last.
 *
 * Three kinds of candidate, in this order:
 *
 *  1. **All the rules applied together**, when that produces something no single
 *     rule does. This is the case a single rule cannot express: a URL that
 *     carries the size *twice*, once in the path and once in the query, needs
 *     both rewritten or the server sees a contradiction and falls back to the
 *     small one.
 *  2. **Each rule on its own**, in the order the caller wrote them. The order is
 *     the caller's preference and is preserved exactly; nothing here reorders by
 *     a guess about which is more likely.
 *  3. **The original.** Always present, always last, never removed. This is the
 *     guarantee in the header, expressed as a line of code rather than as a
 *     branch: there is no path through this function that returns a list without
 *     it.
 *
 * Duplicates are dropped keeping the earliest, so a rule that happens to produce
 * the original URL does not cost a second request.
 */
export function renditionCandidates(
  url: string,
  rules: readonly RenditionRule[],
): RenditionCandidate[] {
  const out: RenditionCandidate[] = []
  const seen = new Set<string>()
  const add = (candidate: RenditionCandidate): void => {
    if (seen.has(candidate.url)) return
    seen.add(candidate.url)
    out.push(candidate)
  }

  if (rules.length > 1) {
    let combined = url
    const used: string[] = []
    for (const rule of rules) {
      const next = applyRule(combined, rule)
      if (next !== combined) used.push(rule.id)
      combined = next
    }
    if (used.length > 1) add({ url: combined, ruleId: used.join('+') })
  }
  for (const rule of rules) {
    const next = applyRule(url, rule)
    if (next !== url) add({ url: next, ruleId: rule.id })
  }
  // The original, last and unconditional. See the header.
  add({ url, ruleId: '' })
  return out
}

/* ----------------------------------------------------------------- probes -- */

/** What a `HEAD` (or a ranged `GET`) told us about a candidate. */
export interface RenditionProbe {
  status: number
  /** `Content-Length`, or `null` when the server did not state one. */
  bytes: number | null
  /** `Content-Type` without its parameters, lower case. `''` when unstated. */
  contentType: string
}

/** Ask a URL what it is. `null` means the request itself failed. */
export type RenditionProbeFn = (url: string) => Promise<RenditionProbe | null>

export interface RenditionOptions {
  /**
   * Refuse an upgrade whose length is below this. Zero-byte and few-hundred-byte
   * answers are placeholder images, and a run that accepts them looks complete.
   */
  minBytes?: number
  /**
   * Probe the original too, and refuse an upgrade that is not larger.
   *
   * **On by default**, and that default is the whole lesson of the 62,000. A
   * server handed an unrecognised size very often answers 200 with the same
   * preview, and without this check the run records an upgrade, writes a 498px
   * file, and reports success. The cost is one extra `HEAD` per asset against a
   * URL that is about to be fetched anyway.
   *
   * When either side does not state a length the comparison cannot be made; the
   * candidate is then accepted on the other two checks and the result says the
   * lengths were never compared, rather than pretending they were.
   */
  requireLarger?: boolean
}

const DEFAULTS: Required<RenditionOptions> = { minBytes: 0, requireLarger: true }

/** The file extensions for which an HTML answer is proof of a wrong guess. */
const ASSET_EXTENSION =
  /\.(?:jpe?g|png|gif|webp|avif|bmp|tiff?|svg|pdf|mp4|webm|mov|zip|dwg|dxf)(?:$|[?#])/i

/**
 * Is this candidate the file we asked for?
 *
 * Split out and exported because it is the judgement, and a judgement made in
 * the middle of an async loop is one nobody can test at the boundaries.
 */
export function acceptsRendition(input: {
  candidateUrl: string
  probe: RenditionProbe | null
  originalProbe?: RenditionProbe | null
  options?: RenditionOptions
}): { ok: boolean; reason: string; comparedBytes: boolean } {
  const options = { ...DEFAULTS, ...(input.options ?? {}) }
  const probe = input.probe
  if (probe === null) return { ok: false, reason: 'the request failed', comparedBytes: false }
  if (probe.status < 200 || probe.status >= 300) {
    return { ok: false, reason: `HTTP ${probe.status}`, comparedBytes: false }
  }
  /*
   * A page where a file was asked for.
   *
   * Only when the URL claims to be a file: a caller upgrading something with no
   * extension — a signed CDN path, an `/image/12345` route — gets no opinion
   * from this check rather than a wrong one.
   */
  if (ASSET_EXTENSION.test(input.candidateUrl) && probe.contentType.startsWith('text/')) {
    return {
      ok: false,
      reason: `the server answered with ${probe.contentType}, which is a page rather than the file`,
      comparedBytes: false,
    }
  }
  if (probe.bytes !== null && probe.bytes === 0) {
    return { ok: false, reason: 'the server answered with nothing', comparedBytes: false }
  }
  if (options.minBytes > 0 && probe.bytes !== null && probe.bytes < options.minBytes) {
    return {
      ok: false,
      reason: `${probe.bytes} bytes is below the ${options.minBytes} this run will accept`,
      comparedBytes: false,
    }
  }
  if (options.requireLarger) {
    const original = input.originalProbe ?? null
    if (original === null || original.bytes === null || probe.bytes === null) {
      return { ok: true, reason: '', comparedBytes: false }
    }
    if (probe.bytes <= original.bytes) {
      return {
        ok: false,
        reason: `it is ${probe.bytes} bytes against the original's ${original.bytes}, so it is not a bigger copy`,
        comparedBytes: true,
      }
    }
    return { ok: true, reason: '', comparedBytes: true }
  }
  return { ok: true, reason: '', comparedBytes: false }
}

/* ------------------------------------------------------------ the choice -- */

export interface RenditionAttempt {
  url: string
  ruleId: string
  ok: boolean
  /** Why it was refused. Empty when it was accepted. */
  reason: string
  status: number | null
  bytes: number | null
}

export interface RenditionChoice {
  /** The URL to actually fetch. Never empty. */
  url: string
  /** The rule that won, or `''` when the original did. */
  ruleId: string
  upgraded: boolean
  /** An upgrade was tried and refused, so this is the original by fallback. */
  fellBack: boolean
  /**
   * Did the chosen URL itself answer? `false` means every candidate failed and
   * this is the original being returned anyway — fetch it and find out, rather
   * than skipping the asset on the strength of a `HEAD`.
   */
  reachable: boolean
  /** Were the lengths of the upgrade and the original actually compared? */
  comparedBytes: boolean
  originalUrl: string
  attempts: RenditionAttempt[]
  /** One line for a log or a tool result. */
  line: string
}

/**
 * Pick the URL to fetch for one asset.
 *
 * Never throws for a bad guess and never answers "nothing": the worst case is
 * the original URL with `reachable: false` and every attempt written down, which
 * is a thing the caller can fetch and a thing a person can read afterwards.
 *
 * `attempts` is the whole audit trail — what was tried, in what order, what each
 * one answered. It is what turns *"why are these images small"* from an
 * afternoon into a line.
 */
export async function chooseRendition(input: {
  url: string
  rules: readonly RenditionRule[]
  probe: RenditionProbeFn
  options?: RenditionOptions
}): Promise<RenditionChoice> {
  const options = { ...DEFAULTS, ...(input.options ?? {}) }
  const candidates = renditionCandidates(input.url, input.rules)
  const attempts: RenditionAttempt[] = []

  /*
   * The original is probed once, up front, and only when it is needed as a
   * yardstick — which is when there is an upgrade to measure and
   * `requireLarger` is on. A run with no rules pays for nothing.
   */
  let originalProbe: RenditionProbe | null = null
  let originalProbed = false
  const upgrades = candidates.filter((candidate) => candidate.ruleId !== '')
  if (options.requireLarger && upgrades.length > 0) {
    originalProbe = await input.probe(input.url).catch(() => null)
    originalProbed = true
  }

  for (const candidate of candidates) {
    const isOriginal = candidate.ruleId === ''
    const probe =
      isOriginal && originalProbed
        ? originalProbe
        : await input.probe(candidate.url).catch(() => null)
    const verdict = acceptsRendition({
      candidateUrl: candidate.url,
      probe,
      originalProbe,
      // The original is never measured against itself.
      options: isOriginal ? { ...options, requireLarger: false } : options,
    })
    attempts.push({
      url: candidate.url,
      ruleId: candidate.ruleId,
      ok: verdict.ok,
      reason: verdict.reason,
      status: probe?.status ?? null,
      bytes: probe?.bytes ?? null,
    })
    if (!verdict.ok) continue
    const fellBack = isOriginal && attempts.length > 1
    return {
      url: candidate.url,
      ruleId: candidate.ruleId,
      upgraded: !isOriginal,
      fellBack,
      reachable: true,
      comparedBytes: verdict.comparedBytes,
      originalUrl: input.url,
      attempts,
      line: isOriginal
        ? fellBack
          ? `No upgrade held, so the original URL was used: ${describeFailures(attempts)}`
          : 'No rule changed this URL, so the original was used.'
        : `Upgraded by ${candidate.ruleId}${
            verdict.comparedBytes ? ' and it is a bigger file than the original' : ''
          }.`,
    }
  }

  /*
   * Nothing answered, including the original.
   *
   * The original is still handed back. A `HEAD` that fails is not proof that a
   * `GET` will — servers refuse `HEAD`, proxies drop it, and a run that skipped
   * an asset on that evidence would be discarding a file that was there. The
   * caller fetches it, and if that fails too the failure is a real one with a
   * real error on it.
   */
  return {
    url: input.url,
    ruleId: '',
    upgraded: false,
    fellBack: attempts.length > 1,
    reachable: false,
    comparedBytes: false,
    originalUrl: input.url,
    attempts,
    line: `Nothing answered for this asset, so the original URL is being handed back to be fetched anyway: ${describeFailures(
      attempts,
    )}`,
  }
}

function describeFailures(attempts: readonly RenditionAttempt[]): string {
  return attempts
    .filter((attempt) => !attempt.ok)
    .map((attempt) => `${attempt.ruleId === '' ? 'original' : attempt.ruleId} — ${attempt.reason}`)
    .join('; ')
}
