import { homedir } from 'node:os'
import { isAbsolute, normalize, sep } from 'node:path'
import { BadArgument } from './catalogue'
import { KeyError, NAMED_KEYS as NAMED_KEYS_TABLE, resolveKeys, type ResolvedKey } from './session-typing'
import { Refused, actsAsOwner, type Caller } from './surface'
import { BRAND } from '../../shared/brand'

/**
 * What the machine, server, device and GitHub tools share, in one place.
 *
 * Four tool files (`machine-tools.ts`, `server-room-tools.ts`, `remote-tools.ts`,
 * `github-tools.ts`) take the same kinds of argument and draw the same line
 * about who may call them. A copy of either in each file is four answers to one
 * question, and the one that drifts is the one nobody is reading.
 */

/* ------------------------------------------------------------- arguments -- */

/*
 * Hand-written, for the reason `catalogue.ts` gives about its own: the schema is
 * advertised and enforced at the door by `schema.ts`, but these are the lines a
 * run actually depends on, and each throws a sentence a model can act on.
 */

export function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new BadArgument(`${key} is required and must be a non-empty string`)
  }
  return value
}

export function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new BadArgument(`${key} must be a string`)
  return value
}

export function optBool(args: Record<string, unknown>, key: string, fallback: boolean): boolean {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'boolean') throw new BadArgument(`${key} must be true or false`)
  return value
}

export function bool(args: Record<string, unknown>, key: string): boolean {
  const value = args[key]
  if (typeof value !== 'boolean') throw new BadArgument(`${key} is required and must be true or false`)
  return value
}

export function int(args: Record<string, unknown>, key: string, min: number, max: number): number {
  const value = args[key]
  if (typeof value !== 'number' || !Number.isFinite(value) || Math.trunc(value) !== value) {
    throw new BadArgument(`${key} is required and must be a whole number`)
  }
  if (value < min || value > max) throw new BadArgument(`${key} must be between ${min} and ${max}`)
  return value
}

export function strList(args: Record<string, unknown>, key: string): string[] {
  const value = args[key]
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    throw new BadArgument(`${key} is required and must be a list of strings`)
  }
  return value as string[]
}

/** One of a closed list, or a refusal naming the list. */
export function oneOf<T extends string>(args: Record<string, unknown>, key: string, allowed: readonly T[]): T {
  const value = str(args, key)
  const found = allowed.find((candidate) => candidate === value)
  if (found === undefined) throw new BadArgument(`${key} must be one of: ${allowed.join(', ')}`)
  return found
}

/** The `do` of a tool whose verbs are a closed list, read without throwing — for `summary` and `escalate`. */
export function verbOf(args: Record<string, unknown>): string {
  return typeof args.do === 'string' ? args.do : ''
}

/* ------------------------------------------------------------ who may ask -- */

/**
 * The one line every tool in these four files draws about where a call came from.
 *
 * **Only the person at this computer, and the copilot they are talking to.** A
 * paired phone, a session's own token and any caller kind added later are
 * refused — before the tier is consulted, so nobody is ever shown a dialog for a
 * call that could not be allowed.
 *
 * The rule is `surface.ts`'s, applied to a whole area: *"a tool's effect for a
 * remote caller may never exceed what that device's own protocol frames already
 * permit."* A paired device's protocol has no frame for reaching through this
 * desktop to *another* machine, for adding a server, for approving a device or
 * for signing this app into GitHub, so the permitted effect for it is nothing.
 * `servers/tools.ts` drew the same line for `servers.control` and argued it at
 * length; this is that line, once, for everything beside it.
 *
 * Written as `caller.kind !== 'local'`, the shape every gate in this codebase
 * uses, so a caller kind that did not exist when this was written is refused by
 * default rather than let through by an oversight. **If a new kind of caller —
 * a named access key from another application, say — should reach these tools,
 * this is the one function to widen, deliberately, with the argument written
 * beside it.**
 */
export function hereOnly(caller: Caller, what: string): void {
  /*
   * Widened, deliberately, on 2026-10-03, as the paragraph above asked: an AI app
   * holding an access key the owner made acts as the owner here. Its level is
   * still the bound — the tier check reads it per call — so a Look only key
   * reads these and a Full control key changes them, asking first unless he
   * turned that off. `actsAsOwner` in `surface.ts` carries the argument; a
   * paired device and an ordinary session are refused exactly as before.
   */
  if (actsAsOwner(caller)) return
  throw new Refused(
    'not-granted',
    `${what} only works for the person at this computer, ${BRAND.assistant} (the assistant they talk to here), and AI apps they ` +
      'gave an access key to. A paired device cannot do it from here. Say what you would have done and let them do it.',
  )
}

/* -------------------------------------------------------------- keys ---- */

/*
 * The keys a tool may press, and how a line is typed, are `session-typing.ts`'s
 * — one table and one send sequence for every terminal a tool reaches, here or
 * on another computer.
 *
 * This file had its own table, sixteen keys joined into one string and written
 * in one go, and its own `${text}\r` for a line. Both were the bug class
 * `session-typing.ts` is named for: one chunk of 64 bytes or more is a paste to
 * the agent CLIs, so the return inside it is a newline and the message is never
 * sent; and Escape followed in the same chunk by a digit is read as Alt-digit,
 * not as two keys. Two tables would also have given one key two names on two
 * kinds of session. So the names, the cap and the writing all come from there.
 */
export { pressKeys, typeLine } from './session-typing'

/** The key names, for a description. A single printable character is also a key. */
export const KEY_NAMES = Object.keys(NAMED_KEYS_TABLE)

/**
 * The keys a call named, checked, or a refusal a model can act on.
 *
 * Run in the precheck — so a dialog never quotes a key that does not exist —
 * and again in the handler before anything is pressed.
 */
export function keysFrom(names: unknown): ResolvedKey[] {
  try {
    return resolveKeys(names)
  } catch (error) {
    throw new BadArgument(error instanceof KeyError ? error.message : String(error))
  }
}

/* --------------------------------------------------------- local files -- */

/**
 * Folders under the home directory a file is never sent out of.
 *
 * A file leaving this computer — to a paired machine or onto a server — is
 * `alter` in both tools that do it, so a person always reads the path first.
 * These are refused *before* that question, because the dialog would look the
 * same for `~/Downloads/report.pdf` and `~/.ssh/id_ed25519`, and an approval
 * given to the first shape trains the click for the second. Every entry is a
 * place credentials are kept by convention; the app's own data folder is added
 * by the caller, because only it knows where that is.
 */
const SECRET_HOME_FOLDERS = ['.ssh', '.aws', '.gnupg', '.kube', '.docker', '.config/gh', 'Library/Keychains']

/**
 * A file on this computer that may be sent somewhere else, or a refusal.
 *
 * Absolute only: a relative path has no meaning to a tool whose caller is in
 * another process with another working directory, and guessing one is how a
 * call reaches a file nobody named.
 */
export function sendableFile(path: string, alsoRefuse: readonly string[] = []): string {
  if (!isAbsolute(path)) throw new BadArgument('path must be an absolute path to a file on this computer')
  const clean = normalize(path)
  const home = homedir()
  const refused = [...SECRET_HOME_FOLDERS.map((folder) => `${home}${sep}${folder}`), ...alsoRefuse]
  for (const folder of refused) {
    if (clean === folder || clean.startsWith(`${folder}${sep}`)) {
      throw new Refused(
        'not-permitted',
        `${clean} is inside ${folder}, where sign-in keys and credentials are kept. Files there are never sent ` +
          'from this computer by a tool.',
      )
    }
  }
  return clean
}

/** Shorten a long free text for a one-line consent sentence, saying that it was shortened. */
export function shown(text: string, most = 160): string {
  return text.length > most ? `${text.slice(0, most)}… (${text.length} characters)` : text
}
