/**
 * What a store tool *is*, and the parser that refuses everything else.
 *
 * ## The decision this file exists to record
 *
 * Asad asked for a store:
 *
 *   > *"i think we can have a tools store for extensions to this browser with
 *   > all open source best tools in the market so people can use the tool of
 *   > their choice in the browser, which tools will not be here only when they
 *   > download."*
 *
 * The obvious reading is "fetch a program and run it". That reading is refused
 * here, and not on a hunch — this repository has already written down, twice, in
 * two separate files, the exact invariant it would break:
 *
 *  - `browser-drive-script.ts`: *"there is no arbitrary-evaluation tool, there
 *    never will be one, and the day somebody adds a sixth tool that takes a
 *    free-form string, the promise that a password cannot reach an agent's
 *    transcript stops being true."*
 *  - `browser-cdp.ts`, on why `Runtime.evaluate` is denied: *"Reading happens
 *    through `executeJavaScriptInIsolatedWorld` with a script this repository
 *    wrote; there is no path from a model's string to a page's JavaScript, and
 *    this entry is what keeps that true by construction rather than by intent."*
 *
 * A downloaded script running in a guest page's isolated world would have the
 * whole of the driver's reach over a page holding somebody's live login — the
 * DOM, the cookies that page can read, and every field on it. "A script this
 * repository wrote" would become false, and the two sentences above would become
 * decorative. So the store does not download scripts.
 *
 * **A store tool is a recipe: selectors and a closed set of operations over what
 * they match.** The engine that runs it is `browser-store-script.ts`, which is a
 * script this repository wrote, and a recipe reaches it the way a selector
 * already reaches every other script — as a JSON literal substituted into
 * `ARGS_TOKEN` by `withArgs`. That seam is already built, already argued for and
 * already tested, and it is exactly as wide after this feature as before it:
 *
 *   > *"A selector is not code: the worst a hostile one can do is match the
 *   > wrong element or throw a `SyntaxError`, both of which are handled. It is
 *   > never concatenated into an expression."*
 *
 * The consequence worth stating plainly, because it is the whole permission
 * answer: **a store tool can never exceed `browser.read`.** It reads a page the
 * caller already holds, through the same isolated world, with the same secret
 * guard, and returns strings. A site-bound recipe has strictly *less* reach than
 * `browser.read`, because it refuses to run on any page outside its own origins.
 *
 * ## Why the parser refuses unknown keys
 *
 * `session-tools.ts` makes the argument for a positive list over a remembered
 * deny-list, and the same reasoning decides the shape of {@link parseRecipe}: a
 * validator that ignores what it does not recognise is a validator that will
 * happily accept next year's dangerous field. Every key at every level is named
 * below; anything else is a refusal with the key in the message.
 *
 * The same goes for {@link GRANTS}. A recipe declaring `network` or `write`
 * today does not install — not because those grants are dangerous in some future
 * build, but because this build cannot enforce them, and a permission this app
 * prints on a screen and does not check is worse than one it never offered.
 */

/* ------------------------------------------------------------ the limits -- */

/**
 * How large a recipe may be, in bytes of JSON.
 *
 * Sixty-four kilobytes is roughly two hundred fields with prose names, which is
 * far past any honest extraction and small enough that a hostile or corrupt
 * response is rejected before it is parsed rather than after. The cap is applied
 * to the *bytes*, before `JSON.parse`, because that is the only measurement that
 * bounds the work.
 */
export const MAX_RECIPE_BYTES = 64 * 1024

/** Fields on the page itself, and fields inside one repeated row. */
export const MAX_FIELDS = 40
export const MAX_ROW_FIELDS = 24

/**
 * The longest selector a recipe may carry.
 *
 * The same 400 `browser-driver.ts` allows an agent to type, deliberately: a
 * recipe is not a more trusted author than the agent is, and two different
 * ceilings for one kind of string is how one of them ends up missing.
 */
export const MAX_SELECTOR_CHARS = 400

/* ------------------------------------------------------------ the grants -- */

/**
 * Everything a store tool may be permitted to touch, and there is one.
 *
 * `page-read` is the reach of `browser.read`, on a window the caller already
 * holds, bounded further by the recipe's own origins. There is no `network`,
 * no `download` and no `write`, because there is no code in this build that
 * would enforce them — see the header.
 */
export const GRANTS = ['page-read'] as const

export type Grant = (typeof GRANTS)[number]

/** One line a person reads on the store row, per grant. */
export const GRANT_WORDS: Readonly<Record<Grant, string>> = Object.freeze({
  'page-read': 'Reads the page you point it at',
})

/* --------------------------------------------------------------- the ops -- */

/**
 * What a recipe may ask for, and why each one is here.
 *
 * A closed set, in this repository's own code. A recipe picks one by name; it
 * never supplies an expression, so this list is the entire vocabulary of every
 * store tool that will ever be installed.
 *
 *  - `text` — the readable text of the match. `innerText`, not `textContent`;
 *    the reasoning is in `browser-drive-script.ts`'s preamble.
 *  - `attribute` — one named attribute, spelled out by the recipe.
 *  - `link` — an `href` or `src` resolved against the document, so a caller
 *    never has to guess a base. Relative links that were silently kept relative
 *    are how a crawl ends up fetching the wrong host.
 *  - `image` — **every** candidate URL an image declares, with the width each
 *    one claims, and nothing chosen. See {@link ExtractOp}.
 *  - `data` — the structured data the page publishes about itself: JSON-LD,
 *    `og:` meta, and `itemprop` values. On a property listing this is usually
 *    more complete and more stable than anything a selector reaches.
 *  - `count` — how many elements matched. Cheap, and it is the number a
 *    completeness check is made of.
 *  - `number` — the first integer in the matched text, commas and spaces
 *    stripped. This is how "1,248 properties" becomes 1248.
 */
export const OPS = ['text', 'attribute', 'link', 'image', 'data', 'count', 'number'] as const

export type ExtractOp = (typeof OPS)[number]

/** Ops that are meaningful with no selector, reading the whole document. */
const WHOLE_DOCUMENT_OPS: ReadonlySet<string> = new Set(['text', 'data', 'count'])

/* ------------------------------------------------------------- the shapes -- */

export interface RecipeField {
  name: string
  /** A CSS selector, or `''` meaning the document itself. */
  selector: string
  op: ExtractOp
  /** Required by `attribute`, refused by every other op. */
  attribute?: string
  /** Collect every match rather than the first. */
  all?: boolean
}

export interface RecipeRows {
  selector: string
  fields: RecipeField[]
}

export interface Recipe {
  id: string
  name: string
  summary: string
  version: string
  grants: Grant[]
  /**
   * The hosts this recipe may run on. `'*'` means any page.
   *
   * Explicit and required, never defaulted, because the default would be the
   * dangerous one and nobody would ever see it. A site recipe naming
   * `www.example.com` is refused on every other page in the browser — which is
   * a real containment, and the reason a recipe written for a property portal
   * cannot be pointed at a bank. `'*'` is honest for a site-agnostic tool and
   * the store row says so in those words.
   */
  origins: string[]
  fields: RecipeField[]
  /** A repeated block — a results list, a table of rows. */
  rows: RecipeRows | null
  /**
   * The total the page states about itself.
   *
   * This field is the whole reason a recipe has a shape at all rather than being
   * a bag of selectors. Seven per cent of a dataset shipped as complete because
   * nothing ever compared it against the number the page itself printed at the
   * top of the results. A recipe that names that number turns "how many did we
   * get" into an arithmetic check the tool performs on every call.
   */
  stated: RecipeField | null
  /** The link to the next page, for an orchestrator walking a list. */
  next: string | null
}

export type RecipeParse = { ok: true; recipe: Recipe } | { ok: false; why: string }

/* ---------------------------------------------------------- the validator -- */

const ID = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/
const FIELD_NAME = /^[a-z][a-z0-9_]{0,31}$/
const VERSION = /^\d+\.\d+\.\d+$/
const ATTRIBUTE = /^[a-zA-Z_:][-a-zA-Z0-9_:.]*$/
/** A host, or one wildcard label in front of one. Never a bare `*.tld`. */
const ORIGIN = /^(?:\*\.)?[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/

class Bad extends Error {}

function fail(why: string): never {
  throw new Bad(why)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Every key the caller sent that this build does not know about.
 *
 * The refusal names the key, because "the recipe is invalid" sends somebody
 * looking through forty fields for a typo the parser already found.
 */
function onlyKeys(where: string, value: Record<string, unknown>, allowed: readonly string[]): void {
  const known = new Set(allowed)
  for (const key of Object.keys(value)) {
    if (!known.has(key)) fail(`${where} has a key this app does not know about: ${key}`)
  }
}

function text(where: string, value: unknown, max: number): string {
  if (typeof value !== 'string') fail(`${where} must be text`)
  const trimmed = (value as string).trim()
  if (trimmed === '') fail(`${where} must not be empty`)
  if (trimmed.length > max) fail(`${where} must be ${max} characters or fewer`)
  if (/[\r\n]/.test(trimmed)) fail(`${where} must be a single line`)
  return trimmed
}

function selector(where: string, value: unknown, allowEmpty: boolean): string {
  if (typeof value !== 'string') fail(`${where} must be text`)
  const trimmed = (value as string).trim()
  if (trimmed === '') {
    if (allowEmpty) return ''
    fail(`${where} must not be empty`)
  }
  if (trimmed.length > MAX_SELECTOR_CHARS) {
    fail(`${where} must be ${MAX_SELECTOR_CHARS} characters or fewer`)
  }
  /*
   * A selector is not markup and it is not a script.
   *
   * Neither character can appear in a valid CSS selector, and both are the first
   * thing an injection attempt reaches for — so refusing them costs nothing that
   * a real recipe wanted and turns a whole class of "what if" into a parse
   * error. It is not the reason the design is safe; the reason is that the
   * selector is never concatenated into an expression. It is the cheap second
   * answer, in the spirit of the deny-list behind the allow-list in
   * `browser-cdp.ts`.
   */
  if (/[<>]/.test(trimmed)) fail(`${where} contains a character a CSS selector cannot have`)
  return trimmed
}

function field(where: string, raw: unknown): RecipeField {
  if (!isRecord(raw)) fail(`${where} must be an object`)
  onlyKeys(where, raw, ['name', 'selector', 'op', 'attribute', 'all'])

  const name = text(`${where}.name`, raw.name, 32)
  if (!FIELD_NAME.test(name)) {
    fail(`${where}.name must be lower-case letters, digits and underscores, starting with a letter`)
  }

  const op = raw.op
  if (typeof op !== 'string' || !(OPS as readonly string[]).includes(op)) {
    fail(`${where}.op must be one of: ${OPS.join(', ')}`)
  }
  const operation = op as ExtractOp

  const sel = selector(`${where}.selector`, raw.selector, WHOLE_DOCUMENT_OPS.has(operation))

  let attribute: string | undefined
  if (operation === 'attribute') {
    attribute = text(`${where}.attribute`, raw.attribute, 64)
    if (!ATTRIBUTE.test(attribute)) fail(`${where}.attribute is not an attribute name`)
  } else if (raw.attribute !== undefined) {
    fail(`${where}.attribute is only meaningful with op "attribute"`)
  }

  if (raw.all !== undefined && typeof raw.all !== 'boolean') fail(`${where}.all must be true or false`)

  const built: RecipeField = { name, selector: sel, op: operation }
  if (attribute !== undefined) built.attribute = attribute
  if (raw.all === true) built.all = true
  return built
}

function fieldList(where: string, raw: unknown, max: number): RecipeField[] {
  if (!Array.isArray(raw)) fail(`${where} must be a list`)
  if (raw.length === 0) fail(`${where} must name at least one field`)
  if (raw.length > max) fail(`${where} may name at most ${max} fields`)
  const fields = raw.map((entry, index) => field(`${where}[${index}]`, entry))
  const seen = new Set<string>()
  for (const one of fields) {
    if (seen.has(one.name)) fail(`${where} names ${one.name} twice`)
    seen.add(one.name)
  }
  return fields
}

/**
 * Turn the bytes of a recipe into a recipe, or say exactly why not.
 *
 * `expectedId` is the id the *catalogue* holds, and a recipe whose own id does
 * not match it is refused. That check is what stops a fetched document being
 * installed under a name it did not claim for itself — the store row a person
 * read said one thing and the file says another, and the honest answer to a
 * disagreement between them is neither.
 *
 * Never throws. Every refusal is a sentence a person can read on the store row.
 */
export function parseRecipe(bytes: string, expectedId: string): RecipeParse {
  try {
    if (Buffer.byteLength(bytes, 'utf8') > MAX_RECIPE_BYTES) {
      fail(`a recipe must be ${MAX_RECIPE_BYTES} bytes or fewer`)
    }
    let raw: unknown
    try {
      raw = JSON.parse(bytes)
    } catch {
      fail('this is not valid JSON')
    }
    if (!isRecord(raw)) fail('a recipe must be a JSON object')

    onlyKeys('the recipe', raw, [
      'id',
      'name',
      'summary',
      'version',
      'grants',
      'origins',
      'fields',
      'rows',
      'stated',
      'next',
    ])

    const id = text('id', raw.id, 40)
    if (!ID.test(id)) fail('id must be lower-case letters, digits and hyphens')
    if (id !== expectedId) fail(`this recipe calls itself ${id}, and it was offered as ${expectedId}`)

    const name = text('name', raw.name, 60)
    const summary = text('summary', raw.summary, 120)
    const version = text('version', raw.version, 20)
    if (!VERSION.test(version)) fail('version must look like 1.2.3')

    if (!Array.isArray(raw.grants) || raw.grants.length === 0) {
      fail('grants must be a list naming at least one thing this tool may touch')
    }
    const grants: Grant[] = []
    for (const grant of raw.grants) {
      if (typeof grant !== 'string' || !(GRANTS as readonly string[]).includes(grant)) {
        /*
         * The forward-compatible refusal, and it is deliberately a refusal.
         *
         * A recipe asking for something this build cannot enforce does not
         * install. Installing it with the unknown grant quietly dropped would
         * put a tool on screen whose permission line is a guess.
         */
        fail(
          `this tool asks to ${String(grant)}, which this version cannot grant. ` +
            `It may ask for: ${GRANTS.join(', ')}`,
        )
      }
      if (!grants.includes(grant as Grant)) grants.push(grant as Grant)
    }

    if (!Array.isArray(raw.origins) || raw.origins.length === 0) {
      fail('origins must be a list of hosts, or ["*"] for a tool that runs anywhere')
    }
    if (raw.origins.length > 40) fail('origins may name at most 40 hosts')
    const origins: string[] = []
    for (const origin of raw.origins) {
      if (typeof origin !== 'string') fail('every origin must be text')
      const host = origin.trim().toLowerCase()
      if (host !== '*' && !ORIGIN.test(host)) fail(`${origin} is not a host or "*"`)
      if (!origins.includes(host)) origins.push(host)
    }

    const fields = fieldList('fields', raw.fields, MAX_FIELDS)

    let rows: RecipeRows | null = null
    if (raw.rows !== undefined && raw.rows !== null) {
      if (!isRecord(raw.rows)) fail('rows must be an object')
      onlyKeys('rows', raw.rows, ['selector', 'fields'])
      rows = {
        selector: selector('rows.selector', raw.rows.selector, false),
        fields: fieldList('rows.fields', raw.rows.fields, MAX_ROW_FIELDS),
      }
    }

    let stated: RecipeField | null = null
    if (raw.stated !== undefined && raw.stated !== null) {
      stated = field('stated', raw.stated)
      if (stated.op !== 'number' && stated.op !== 'count') {
        fail('stated must use op "number" or "count" — it is the total the page claims')
      }
      if (stated.all === true) fail('stated is one number, so it cannot be a list')
    }

    let next: string | null = null
    if (raw.next !== undefined && raw.next !== null) next = selector('next', raw.next, false)

    return { ok: true, recipe: { id, name, summary, version, grants, origins, fields, rows, stated, next } }
  } catch (error) {
    return { ok: false, why: error instanceof Bad ? error.message : 'this recipe could not be read' }
  }
}

/* ---------------------------------------------------------- running it on -- */

/**
 * May this recipe run on this page?
 *
 * The origin gate, as a pure function over two strings so the tool, the store
 * row and a test all ask the same question of the same code. A page whose URL
 * cannot be parsed is refused, which is the conservative direction and the same
 * one `isPrivateOrigin` takes in `browser-tools.ts`.
 *
 * `*.example.com` matches a subdomain and **also** the bare host, because a
 * person writing it means "this site" and a recipe that worked on
 * `www.example.com` and refused `example.com` would read as a bug.
 */
export function recipeAllowsUrl(recipe: Pick<Recipe, 'origins'>, url: string): boolean {
  if (recipe.origins.includes('*')) return true
  let host: string
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false
    host = parsed.hostname.toLowerCase()
  } catch {
    return false
  }
  return recipe.origins.some((origin) => {
    if (origin.startsWith('*.')) {
      const bare = origin.slice(2)
      return host === bare || host.endsWith(`.${bare}`)
    }
    return host === origin
  })
}

/** The sentence a store row prints under "Runs on". */
export function originWords(origins: readonly string[]): string {
  if (origins.includes('*')) return 'any page'
  return origins.join(', ')
}
