/**
 * The argument checks and small shared rules for the agents-area tools.
 *
 * ## Why a file of its own
 *
 * Every factory in this folder has carried its own six-line `optStr`, and that
 * is fine at one tool per file. The agents area is nine files and fifty-eight tools,
 * and nine copies of "a string, trimmed, or a message a model can act on" is
 * nine chances for one of them to accept `''` as a name. So the checks live
 * here once, and they throw `BadArgument` — the same class `catalogue.ts` uses
 * — so the dispatcher logs a malformed call as an *error the model can fix*
 * rather than as a refusal.
 *
 * The schema each tool advertises is a hint to a language model, not a
 * contract it is bound by; these functions are the actual boundary.
 *
 * ## The two rules that are not argument checks
 *
 *  - {@link sessionTier}: typing into somebody else's session is theirs to
 *    allow, exactly as `sessions.send` and `sessions.stop` already decide. A
 *    second copy of that rule with a different answer would let a model pick
 *    whichever tool asks fewer questions.
 *  - {@link withoutSecrets}: the account and MCP readings carry other
 *    programs' configuration, and the release that adds an encrypted account
 *    vault is being built beside this one. A field that comes to hold a token
 *    next month must not reach an outside model because this file passed
 *    objects through untouched today.
 */

import { BadArgument, type ToolContext } from './catalogue'
import type { Tier } from './surface'

export function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new BadArgument(`${key} is required and must be a non-empty string`)
  }
  return value.trim()
}

export function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new BadArgument(`${key} must be a string`)
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

export function optBool(args: Record<string, unknown>, key: string, fallback: boolean): boolean {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'boolean') throw new BadArgument(`${key} must be true or false`)
  return value
}

export function optInt(
  args: Record<string, unknown>,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new BadArgument(`${key} must be a number`)
  return Math.min(Math.max(Math.trunc(value), min), max)
}

export function optNumber(args: Record<string, unknown>, key: string): number | undefined {
  const value = args[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new BadArgument(`${key} must be a number`)
  return value
}

/** One of a closed set, or a sentence naming the set. */
export function oneOf<T extends string>(
  args: Record<string, unknown>,
  key: string,
  allowed: readonly T[],
  fallback?: T,
): T {
  const value = args[key]
  if ((value === undefined || value === null || value === '') && fallback !== undefined) return fallback
  if (typeof value === 'string' && (allowed as readonly string[]).includes(value)) return value as T
  throw new BadArgument(`${key} must be one of: ${allowed.join(', ')}`)
}

export function optRecord(args: Record<string, unknown>, key: string): Record<string, unknown> | null {
  const value = args[key]
  if (value === undefined || value === null) return null
  if (typeof value !== 'object' || Array.isArray(value)) throw new BadArgument(`${key} must be an object`)
  return value as Record<string, unknown>
}

/** A list of strings, tolerating one bare string — a model sends either. */
export function optStrings(args: Record<string, unknown>, key: string): string[] | null {
  const value = args[key]
  if (value === undefined || value === null) return null
  if (typeof value === 'string') return value.trim() === '' ? [] : [value]
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string')) {
    throw new BadArgument(`${key} must be a list of strings`)
  }
  return value as string[]
}

/** The message of whatever a main-process function threw, as one sentence. */
export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * The tier for touching a session: ordinary for one this run started, the
 * person's to confirm for any other.
 *
 * The same decision `sessions.send` makes, applied to the tools that type into
 * a session to read or change its agent's controls. Opening `/model` in
 * somebody's terminal while they are mid-thought is the interruption that rule
 * exists for — the CLI draws a picker over their screen.
 */
export function sessionTier(args: Record<string, unknown>, context: ToolContext): Tier {
  const id = args['sessionId']
  return typeof id === 'string' && context.startedByCopilot(id) ? 'act' : 'alter'
}

/**
 * Field names that hold a credential, whoever wrote the object.
 *
 * The same family the action log scrubs by (`action-log.ts`), plus `key` on its
 * own, which the log deliberately leaves alone because it is too common a word
 * there. In a *result* the cost runs the other way: a stray `key` field dropped
 * from a reading is a follow-up question, a stray API key handed to a model in
 * another application is a leaked credential.
 */
const SECRET_FIELD = /^key$|token|secret|password|passwd|api[-_]?key|credential|cookie|authorization|bearer|private/i

/**
 * Drop every *string* that sits under a secret-sounding name, at any depth.
 *
 * Strings only, on purpose. `credentialsRetained: true` is a fact about where a
 * login lives and is exactly what a person needs to be told before deleting an
 * account; a boolean or a count under that name is never the secret itself.
 * The name survives with `[withheld]` in place of the value, so a reader can
 * tell "there is one and you may not see it" from "there is none".
 */
export function withoutSecrets<T>(value: T, depth = 0): T {
  if (depth > 8 || value === null || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map((entry) => withoutSecrets(entry, depth + 1)) as T
  const out: Record<string, unknown> = {}
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    out[key] = typeof entry === 'string' && SECRET_FIELD.test(key) ? '[withheld]' : withoutSecrets(entry, depth + 1)
  }
  return out as T
}
