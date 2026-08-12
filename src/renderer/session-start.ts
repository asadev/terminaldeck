/**
 * Deciding exactly what a new session will spawn.
 *
 * Until now a session started the moment a project was clicked, on a guessed
 * provider, with no say over the login it ran as. This module is the decision
 * that guess used to make — pulled out of the click handler, given every input
 * it needs, and made testable. The dialog collects answers; this turns them
 * into one spawn request and says out loud where it had to overrule the user.
 *
 * ## Why this file has no React in it
 *
 * The two hard parts of starting a session are both invisible: which of three
 * remembered defaults wins, and what happens when the thing the user picked has
 * since been uninstalled. Neither is observable through a rendered dialog, and
 * both are exactly the kind of thing that silently does the wrong thing for
 * months. So they live here as data-in/data-out, and the dialog is left with
 * nothing to get wrong but layout.
 *
 * The input shapes are structural on purpose. `ProviderRow` from
 * `ProviderPicker` already satisfies {@link StartProvider} bar one field, and
 * `ProfileView` from `ProfilePicker` already satisfies {@link StartProfile} —
 * so the catalogue, the PATH detection and the profile list all stay where they
 * are and this module never grows a second copy of them.
 *
 * ## Precedence
 *
 * For the provider, the profile and the resume flag alike:
 *
 *   1. what the user chose in the dialog for *this* session
 *   2. what was remembered for this project
 *   3. the global default
 *   4. a safe fallback that always exists
 *
 * Every level is checked against what is actually installed or actually
 * present, and a level that no longer resolves falls through to the next
 * instead of failing. A remembered provider that has since been uninstalled is
 * the common case — `profiles.ts` takes the same line for the same reason.
 */

import { normalizeProjectKey } from './components/ProfilePicker'
import {
  cleanTitleText,
  deriveSessionTitle,
  isUsableTitle,
  MAX_TITLE_LENGTH,
  truncateOnWordBoundary,
  type DerivedTitle,
} from './session-title'
import type { ProviderId } from '@shared/types'

/* ---------------------------------------------------------------- inputs -- */

/**
 * A provider as the decision needs it.
 *
 * `ProviderRow` (from `ProviderPicker`) supplies everything except
 * `supportsProfiles`, which the dialog fills from `ProfilePicker`'s
 * `isolationNotice` — the renderer's single statement of which agents have a
 * config directory that can be redirected.
 */
export interface StartProvider {
  id: ProviderId
  label: string
  /** Found on PATH. An unavailable provider is never spawned. */
  available: boolean
  /** Has a documented command for continuing the last conversation. */
  canResume: boolean
  /** Runs under a config directory this app can point somewhere else. */
  supportsProfiles: boolean
}

/** A profile as the decision needs it. `ProfileView` satisfies this. */
export interface StartProfile {
  id: string
  name: string
  /** The user's own install — the fallback the chain always terminates on. */
  system?: boolean
}

/** What the dialog remembered the last time a session started in a folder. */
export interface ProjectStartDefaults {
  provider?: ProviderId | null
  profileId?: string | null
  resume?: boolean
}

/** Remembered choices, keyed by project path. */
export type StartMemory = Record<string, ProjectStartDefaults>

/** What the user actually chose in the dialog, this time. */
export interface StartSelection {
  /** Absolute project folder. Nothing can start without one. */
  projectPath: string | null
  provider?: ProviderId | null
  profileId?: string | null
  resume?: boolean
  /** Sent into the session once it is ready. Optional. */
  firstPrompt?: string
}

/** Everything the decision knows that did not come from this dialog visit. */
export interface StartContext {
  providers: readonly StartProvider[]
  profiles: readonly StartProfile[]
  memory?: StartMemory
  /** `preferences.defaultProvider`. */
  defaultProvider?: ProviderId | null
  /** Whatever `profiles:resolve` answered for this project, if anything. */
  defaultProfileId?: string | null
  cols?: number
  rows?: number
  maxTitleLength?: number
}

/** Terminal geometry a session starts at, before the view measures itself. */
export const DEFAULT_COLS = 100
export const DEFAULT_ROWS = 30

/* --------------------------------------------------------------- outputs -- */

/**
 * Somewhere the resolution did not do what was asked of it.
 *
 * These are shown, not swallowed. Falling back silently is how a user ends up
 * in a plain shell wondering why the agent never started.
 */
export type StartNoticeCode =
  | 'provider-substituted'
  | 'resume-unsupported'
  | 'profile-missing'
  | 'profile-not-applicable'

export interface StartNotice {
  code: StartNoticeCode
  message: string
}

/** Why nothing can start at all. */
export interface StartProblem {
  code: 'no-project' | 'no-provider'
  message: string
}

/** A fully decided launch. Nothing here is optional or guessed. */
export interface SpawnRequest {
  cwd: string
  provider: ProviderId
  resume: boolean
  /**
   * Which profile the user asked this session to run as, or null when the
   * chosen agent has no login this app could isolate even in principle.
   *
   * A non-null id is a *request*, not a guarantee. Applying it means spawning
   * the CLI with a redirected config directory, which is `sessionEnv()` in
   * `main/profiles.ts` — and nothing calls that yet. `CreateSessionInput` has
   * no field to carry this, so today it is recorded and shown, not enforced.
   * The dialog says as much rather than implying the login was switched.
   */
  profileId: string | null
  cols: number
  rows: number
  /** Typed into the session once it is ready; empty string when there is none. */
  firstPrompt: string
  /**
   * Provisional tab label taken from the first prompt, or null when the prompt
   * was empty or was not a task. Superseded by `deriveSessionTitle` as soon as
   * the session produces real evidence.
   */
  title: string | null
}

export type StartResolution =
  | { ok: true; request: SpawnRequest; notices: StartNotice[] }
  | { ok: false; problem: StartProblem; notices: StartNotice[] }

/* ------------------------------------------------------------- the prompt -- */

/**
 * Characters that are instructions to a terminal rather than text.
 *
 * The first prompt is typed by the user but arrives at a PTY as raw bytes, so
 * an escape sequence pasted into the field would be executed by the agent's
 * TUI rather than read by the agent. Tab is in the range too, and a tab is
 * completion in every one of these CLIs.
 */
const PROMPT_CONTROLS = /[\u0000-\u001f\u007f]/g

/**
 * Reduce a typed prompt to something safe to send as one message.
 *
 * Line breaks collapse to spaces because Enter *is* submit in every agent TUI —
 * sending a three-line prompt verbatim submits three separate half-thoughts.
 * The dialog says so next to the field rather than letting it surprise anyone.
 *
 * Deliberately not `cleanTitleText`: that strips leading UUIDs and injected
 * blocks, which is right for a label and wrong for text the user will actually
 * be asking with.
 */
export function normalizeFirstPrompt(raw: string): string {
  return raw
    .replace(/[\r\n]+/g, ' ')
    .replace(PROMPT_CONTROLS, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * A tab label derived from the opening prompt.
 *
 * The first prompt is the strongest evidence that exists at spawn time — the
 * transcript has not been written yet, and the folder name says nothing about
 * what this session is for. `session-title.ts` already knows which strings are
 * worth putting on a tab, so this is a hand-off to it, not a second opinion:
 * a slash command, a bracketed status line or three characters all come back
 * null and let the folder name stand.
 */
export function titleFromFirstPrompt(prompt: string, maxLength = MAX_TITLE_LENGTH): string | null {
  const cleaned = cleanTitleText(prompt)
  if (!isUsableTitle(cleaned)) return null
  return truncateOnWordBoundary(cleaned, maxLength)
}

/**
 * The label a tab shows before the session has produced anything.
 *
 * Exposed separately from `deriveSessionTitle` so the tab bar has one call to
 * make at spawn time and one to make afterwards, and so the source is honest:
 * this title came from a prompt, not from something the user named.
 */
export function initialSessionTitle(
  request: SpawnRequest,
  maxLength = MAX_TITLE_LENGTH,
): DerivedTitle {
  if (request.title !== null && request.title !== '') {
    return { title: truncateOnWordBoundary(request.title, maxLength), source: 'prompt' }
  }
  return deriveSessionTitle({ cwd: request.cwd, maxLength })
}

/* -------------------------------------------------------------- remembering -- */

/**
 * Where the dialog's memory lives.
 *
 * No product-name prefix: `localStorage` is already scoped to this app's
 * renderer origin, so a namespace would buy nothing — and the product name is
 * allowed in exactly one file, which is not this one.
 */
export const START_MEMORY_KEY = 'session-start.defaults.v1'

/**
 * How many projects are worth remembering.
 *
 * The blob is written on every start and nothing ever pruned it, so it grew for
 * the life of the install. That matters more than the bytes: `writeStartMemory`
 * swallows a quota error on purpose, so the first write that overflows
 * `localStorage` silently freezes the memory at whatever it held — and every
 * later session would be resolved against stale defaults with no way to tell.
 * Bounding the write means the failure never arrives.
 *
 * Entries are trimmed oldest-first by insertion order, which `rememberStart`
 * maintains by re-appending the project it just wrote.
 */
export const MAX_REMEMBERED_PROJECTS = 100

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Attach one entry under a key that came from outside.
 *
 * `memory[key] = entry` is not safe here. The key is whatever was in the stored
 * blob, and `JSON.parse` happily produces an own `__proto__` property — so a
 * corrupted or hand-edited blob containing one would hit the `__proto__` setter
 * and *replace the prototype* of the object being built, losing the entry and
 * leaving every unrelated lookup on it answering out of attacker-shaped data.
 * `defineProperty` stores it as the plain own property it was meant to be.
 */
function setEntry(target: StartMemory, key: string, entry: ProjectStartDefaults): void {
  Object.defineProperty(target, key, {
    value: entry,
    enumerable: true,
    writable: true,
    configurable: true,
  })
}

/**
 * Narrow one remembered entry, dropping anything that no longer makes sense.
 *
 * `known` is the provider catalogue, passed in rather than restated here so
 * there is still only one list of providers in the renderer. A remembered
 * provider that is not in it — written by a future version, or by a version
 * that spelled an id differently — is dropped rather than carried forward as a
 * value the resolver would have to keep stepping over.
 */
function parseDefaults(raw: unknown, known: readonly ProviderId[]): ProjectStartDefaults | null {
  if (!isRecord(raw)) return null
  const entry: ProjectStartDefaults = {}
  if (typeof raw.provider === 'string' && (known as readonly string[]).includes(raw.provider)) {
    entry.provider = raw.provider as ProviderId
  }
  if (typeof raw.profileId === 'string' && raw.profileId !== '') entry.profileId = raw.profileId
  if (typeof raw.resume === 'boolean') entry.resume = raw.resume
  return entry
}

/**
 * Read the memory blob back into something the resolver can use.
 *
 * Total by construction: this parses a string the user could have edited by
 * hand in devtools, and a malformed blob must cost the memory, never the
 * ability to start a session.
 */
export function parseStartMemory(raw: unknown, known: readonly ProviderId[]): StartMemory {
  const source = typeof raw === 'string' ? safeParse(raw) : raw
  if (!isRecord(source)) return {}

  const memory: StartMemory = {}
  for (const [path, value] of Object.entries(source)) {
    if (path === '') continue
    const entry = parseDefaults(value, known)
    if (entry) setEntry(memory, path, entry)
  }
  return memory
}

function safeParse(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

/**
 * What was remembered for a folder, however the path was written.
 *
 * The same problem `ProfilePicker.projectDefaultFor` solves for its own map: a
 * trailing slash, a doubled separator or a `..` segment all arrive from a
 * dropped folder, and comparing raw strings loses the memory without ever
 * saying so. The normaliser is shared; the lookup is not, because the values
 * are objects here and ids there.
 */
export function projectDefaultsFor(
  memory: StartMemory | undefined,
  projectPath: string,
): ProjectStartDefaults {
  if (!memory || projectPath === '') return {}

  // `Object.hasOwn` rather than truthiness: a project literally called
  // `__proto__` would otherwise read straight off Object.prototype.
  if (Object.hasOwn(memory, projectPath)) return memory[projectPath]

  const wanted = normalizeProjectKey(projectPath)
  if (wanted === '') return {}
  for (const [key, value] of Object.entries(memory)) {
    if (normalizeProjectKey(key) === wanted) return value
  }
  return {}
}

/**
 * Fold a completed request back into the memory, ready to be persisted.
 *
 * Pure so the merge is testable and the write is a one-liner at the edge. The
 * key is normalised, so starting a session in `/w/app/` and then in `/w/app`
 * updates one entry rather than accumulating two that disagree.
 */
export function rememberStart(memory: StartMemory, request: SpawnRequest): StartMemory {
  const key = normalizeProjectKey(request.cwd)
  if (key === '') return memory

  // Rebuilt rather than spread-and-overwrite: an older entry stored under an
  // un-normalised spelling of the same path would otherwise survive alongside
  // the new one and win the next exact-match lookup.
  const kept = Object.entries(memory).filter(([path]) => normalizeProjectKey(path) !== key)

  // Oldest first, and the project being written is appended below — so dropping
  // from the front discards the least recently started project. One slot is
  // reserved for that append.
  const trimmed = kept.slice(Math.max(0, kept.length - (MAX_REMEMBERED_PROJECTS - 1)))

  const next: StartMemory = {}
  for (const [path, value] of trimmed) setEntry(next, path, value)
  setEntry(next, key, {
    provider: request.provider,
    profileId: request.profileId,
    resume: request.resume,
  })
  return next
}

/* ------------------------------------------------------------- resolution -- */

/** The profile every chain falls back to: the user's own install. */
export function fallbackProfileId(profiles: readonly StartProfile[]): string | null {
  return (profiles.find((profile) => profile.system) ?? profiles[0])?.id ?? null
}

/** First provider that can actually be spawned, in catalogue order. */
export function firstAvailableProvider(
  providers: readonly StartProvider[],
): StartProvider | null {
  return providers.find((provider) => provider.available) ?? null
}

interface ProviderOutcome {
  chosen: StartProvider | null
  /** The highest-precedence thing that was asked for and could not be used. */
  denied: StartProvider | null
}

function chooseProvider(
  providers: readonly StartProvider[],
  wanted: ReadonlyArray<ProviderId | null | undefined>,
): ProviderOutcome {
  let denied: StartProvider | null = null

  for (const id of wanted) {
    if (!id) continue
    const provider = providers.find((entry) => entry.id === id)
    // An id that is not in the catalogue at all cannot be explained to the
    // user, so it is skipped silently rather than reported as "unavailable".
    if (!provider) continue
    if (provider.available) return { chosen: provider, denied }
    denied ??= provider
  }

  return { chosen: firstAvailableProvider(providers), denied }
}

interface ProfileOutcome {
  chosen: string | null
  /** An id that was asked for and no longer exists. */
  missing: string | null
}

function chooseProfile(
  profiles: readonly StartProfile[],
  wanted: ReadonlyArray<string | null | undefined>,
): ProfileOutcome {
  let missing: string | null = null

  for (const id of wanted) {
    if (!id) continue
    if (profiles.some((profile) => profile.id === id)) return { chosen: id, missing }
    missing ??= id
  }

  return { chosen: fallbackProfileId(profiles), missing }
}

/**
 * Turn a dialog's answers into the one thing the main process needs.
 *
 * Never throws and never returns a half-decided request: either there is a
 * complete launch, or there is a reason there is not.
 */
export function resolveStart(context: StartContext, selection: StartSelection): StartResolution {
  const notices: StartNotice[] = []
  const cwd = (selection.projectPath ?? '').trim()

  if (cwd === '') {
    return {
      ok: false,
      problem: { code: 'no-project', message: 'Choose a project folder to run the session in.' },
      notices,
    }
  }

  const remembered = projectDefaultsFor(context.memory, cwd)

  const provider = chooseProvider(context.providers, [
    selection.provider,
    remembered.provider,
    context.defaultProvider,
  ])

  if (!provider.chosen) {
    return {
      ok: false,
      problem: {
        code: 'no-provider',
        // Honest about the cause: this is a PATH problem rather than an app
        // problem, and the user can only fix it if the message says so.
        message: 'No agent could be found on your PATH, so there is nothing to start.',
      },
      notices,
    }
  }

  if (provider.denied && provider.denied.id !== provider.chosen.id) {
    notices.push({
      code: 'provider-substituted',
      message: `${provider.denied.label} is not installed — starting ${provider.chosen.label} instead.`,
    })
  }

  const wantsResume = selection.resume ?? remembered.resume ?? false
  const resume = wantsResume && provider.chosen.canResume
  if (wantsResume && !resume) {
    notices.push({
      code: 'resume-unsupported',
      message: `${provider.chosen.label} has no resume command — starting a fresh conversation.`,
    })
  }

  let profileId: string | null = null
  if (provider.chosen.supportsProfiles) {
    const profile = chooseProfile(context.profiles, [
      selection.profileId,
      remembered.profileId,
      context.defaultProfileId,
    ])
    profileId = profile.chosen
    if (profile.missing && profile.missing !== profile.chosen) {
      notices.push({
        code: 'profile-missing',
        // The fallback chain can end on nothing when the profile list itself is
        // empty or failed to load. Promising "the default login" there names a
        // thing that was not chosen, in the one notice whose whole job is to
        // say what happened instead.
        message:
          profile.chosen === null
            ? 'That profile no longer exists, and no other login is available.'
            : 'That profile no longer exists — using the default login instead.',
      })
    }
  } else if (selection.profileId || remembered.profileId) {
    notices.push({
      code: 'profile-not-applicable',
      message: `${provider.chosen.label} uses its own login, so no profile is applied.`,
    })
  }

  const firstPrompt = normalizeFirstPrompt(selection.firstPrompt ?? '')

  return {
    ok: true,
    notices,
    request: {
      cwd,
      provider: provider.chosen.id,
      resume,
      profileId,
      cols: context.cols ?? DEFAULT_COLS,
      rows: context.rows ?? DEFAULT_ROWS,
      firstPrompt,
      title: firstPrompt === '' ? null : titleFromFirstPrompt(firstPrompt, context.maxTitleLength),
    },
  }
}
