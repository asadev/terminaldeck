import { Refused } from './surface'
import type { JsonSchema, ToolSpec } from './catalogue'

/**
 * The advertised schema, enforced — for every tool, at the one door.
 *
 * ## The call that succeeded at doing nothing
 *
 * `browser.step` declares `additionalProperties: false` and names the text it
 * types `value`. On 2026-08-20 a caller passed `text:` by mistake:
 *
 *     browser_step { verb: 'type', selector: '#q', text: 'hello' }
 *
 * Nothing rejected it. `text` was ignored because nothing reads it, `value` was
 * absent, and `browser-driver.ts` typed `input.value ?? ''` — an empty string,
 * into a real field, on a real page — and the tool **reported success**. The
 * agent had every reason to believe it had typed `hello` and to carry on: click
 * search, read the results, explain why the results were odd.
 *
 * That is worse than a failure. A refusal costs one turn and the model tries
 * something else; a success that did nothing costs the rest of the turn and
 * ends in a confident wrong answer. It is the same shape as a control that
 * cannot act and does not say so, one layer down.
 *
 * ## Why it is here and not in each tool
 *
 * Because the schema is already written down. Every tool in `catalogue.ts` and
 * every tool contributed through `extraTools` publishes an `inputSchema` that
 * says exactly which arguments it takes, which are required and which values
 * are allowed — and that document crossed to the model, which is why the model
 * believed it. A per-tool `precheck` re-stating a fraction of it is how twenty
 * tools come to enforce nineteen different subsets of their own documentation.
 *
 * So this runs before every `precheck`, on every tool, from one place. A tool
 * that adds an argument gets it enforced the moment it is advertised, and a
 * tool that forgets to check one is still checked.
 *
 * ## What it validates, and deliberately no more
 *
 * The vocabulary these schemas actually use, and nothing else: `type` over
 * `object`, `string`, `number`, `integer`, `boolean` and `array`; `properties`;
 * `required`; `enum`; `items`; and `additionalProperties: false`. A keyword
 * this does not know is **ignored rather than guessed at** — a validator that
 * invented a meaning for `format` would refuse calls the advertised schema
 * permits, which is the same lie in the other direction.
 */

/** How many characters of an offending value ever reach a refusal. */
const SHOWN_CHARS = 40

/**
 * Every argument this tool takes, in the order the schema lists them.
 *
 * Named in the refusal because the mistake is nearly always a near-miss — the
 * caller had the shape right and the word wrong — and a list of the real names
 * is what turns a retry into the right call instead of a second guess.
 */
function accepted(schema: JsonSchema): string[] {
  const properties = schema.properties
  if (typeof properties !== 'object' || properties === null) return []
  return Object.keys(properties as Record<string, unknown>)
}

/** What a value is, in the words a schema uses for it. */
function kindOf(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  const type = typeof value
  if (type === 'number') return Number.isInteger(value) ? 'integer' : 'number'
  return type
}

/**
 * Does a value match one declared type?
 *
 * `integer` accepts only whole finite numbers, and `number` accepts any finite
 * one. A `NaN` or an `Infinity` is refused by both: they serialise to `null` in
 * JSON, so a tool that accepted one would be acting on a value its own result
 * could not report back.
 */
function matches(value: unknown, type: string): boolean {
  switch (type) {
    case 'string':
      return typeof value === 'string'
    case 'boolean':
      return typeof value === 'boolean'
    case 'number':
      return typeof value === 'number' && Number.isFinite(value)
    case 'integer':
      return typeof value === 'number' && Number.isInteger(value)
    case 'array':
      return Array.isArray(value)
    case 'object':
      return typeof value === 'object' && value !== null && !Array.isArray(value)
    case 'null':
      return value === null
    default:
      // A type this does not know is not a type this may refuse on.
      return true
  }
}

/** A value, short enough to put in a sentence and never long enough to be a payload. */
function shown(value: unknown): string {
  if (typeof value === 'string') {
    return value.length > SHOWN_CHARS ? `${JSON.stringify(value.slice(0, SHOWN_CHARS))}…` : JSON.stringify(value)
  }
  if (typeof value === 'number' || typeof value === 'boolean' || value === null) return String(value)
  return kindOf(value)
}

/** One value against one property schema. `where` is what the refusal calls it. */
function checkValue(where: string, value: unknown, schema: JsonSchema): void {
  const type = schema.type
  if (typeof type === 'string' && !matches(value, type)) {
    throw new Refused('not-permitted', `${where} must be ${type}, not ${kindOf(value)}`)
  }
  if (Array.isArray(type) && !type.some((one) => typeof one === 'string' && matches(value, one))) {
    throw new Refused(
      'not-permitted',
      `${where} must be one of: ${type.filter((one) => typeof one === 'string').join(', ')}`,
    )
  }

  const values = schema.enum
  if (Array.isArray(values) && !values.includes(value as never)) {
    throw new Refused(
      'not-permitted',
      `${where} must be one of: ${values.map((one) => String(one)).join(', ')} — not ${shown(value)}`,
    )
  }

  const items = schema.items
  if (Array.isArray(value) && typeof items === 'object' && items !== null) {
    value.forEach((entry, index) => checkValue(`${where}[${index}]`, entry, items as JsonSchema))
  }
}

/**
 * Check one call's arguments against the schema its tool advertised.
 *
 * Throws {@link Refused} — a rule, not a fault, so the action log keeps "the
 * copilot was told no" and "the copilot broke" in different columns, exactly as
 * every other refusal on this path does.
 *
 * An argument explicitly set to `undefined` is treated as absent, because that
 * is what it is: `JSON.stringify` drops it on the way out and no client can
 * send one. `null` is **not** absent — a caller that sent `null` sent something,
 * and a schema that does not allow it should say so rather than quietly reading
 * it as "unset".
 */
export function checkArgs(schema: JsonSchema, args: Record<string, unknown>): void {
  if (typeof schema !== 'object' || schema === null) return

  const properties = (
    typeof schema.properties === 'object' && schema.properties !== null ? schema.properties : {}
  ) as Record<string, JsonSchema>

  /*
   * Unknown arguments first, because this is the check the whole module exists
   * for and because it is the one whose sentence is most useful: a caller who
   * wrote `text` for `value` has the shape right and one word wrong, and the
   * list of real names is what makes the next attempt the right one.
   */
  if (schema.additionalProperties === false) {
    const strangers = Object.keys(args).filter(
      (key) => args[key] !== undefined && !Object.hasOwn(properties, key),
    )
    if (strangers.length > 0) {
      const takes = accepted(schema)
      throw new Refused(
        'not-permitted',
        `${strangers.join(', ')} ${strangers.length === 1 ? 'is not an argument' : 'are not arguments'} ` +
          `this tool takes. It takes: ${takes.length === 0 ? 'nothing' : takes.join(', ')}.`,
      )
    }
  }

  for (const [key, property] of Object.entries(properties)) {
    const value = args[key]
    if (value === undefined) continue
    if (typeof property !== 'object' || property === null) continue
    checkValue(key, value, property)
  }

  /*
   * Required last, so that a call which got a *name* wrong is told about the
   * name rather than about the argument that is now missing because of it.
   * `browser_step { verb, selector, text }` is missing nothing the caller meant
   * to send; it has one word wrong, and that is the sentence worth having.
   */
  const required = schema.required
  if (Array.isArray(required)) {
    const missing = required.filter(
      (key) => typeof key === 'string' && args[key as string] === undefined,
    )
    if (missing.length > 0) {
      throw new Refused(
        'not-permitted',
        `${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} required`,
      )
    }
  }
}

/** The same, named by the tool it is about. One line at the call site. */
export function checkToolArgs(spec: ToolSpec, args: Record<string, unknown>): void {
  checkArgs(spec.inputSchema, args)
}
