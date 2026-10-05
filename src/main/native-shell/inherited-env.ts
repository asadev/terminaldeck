import { existsSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'

/**
 * What the engine must not inherit from whoever started the native app.
 *
 * ## The fault this closes, measured on 2026-10-05
 *
 * The native app was started from inside an agent session running in the
 * installed Terminal Deck, and passes its whole environment to the engine. So
 * the engine — and every session it started — carried that session's identity:
 *
 *  - `CLAUDE_CONFIG_DIR` pointing at the **installed app's** account folder
 *    (`…/terminaldeck/profiles/<account>`). `session-env.ts` keeps that variable
 *    on purpose, because the app sets it per session; inherited, it sent every
 *    Claude session in the native app to another app's login and transcripts.
 *    The restore looked for the conversation where this app keeps it and said
 *    *"the saved conversation was not found"*; Claude asked to trust the folder
 *    all over again (trust is per config folder) and then ended with status 1.
 *  - `PATH` starting with the installed app's **account-vault shim** and its
 *    `open` shim, so a login lookup and every `open <url>` went to the other
 *    app — whose vault refuses a session it never gave a ticket to.
 *  - That app's session id and vault ticket.
 *
 * None of this is specific to the bridge or to a terminal: it is the
 * environment. A copy of the app started from the Dock has none of it. The
 * engine drops it once, at start, before anything reads `process.env`.
 */

/** A parent agent run's markers — the same set `session-env.ts` strips from each session. */
const RUN_MARKERS = /^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_AGENT_SDK_VERSION|CLAUDE_CODE_.*|CLAUDE_PREVIEW_.*)$/

/** The installed app's own per-session variables. */
const APP_SESSION_VARS = /^TERMINALDECK_(SESSION_ID|ACCOUNT_VAULT|ACCOUNT_TICKET|ACCOUNT_HOME)$/

/** The two folders a copy of this app puts at the front of a session's PATH. */
const APP_SHIM_DIRS = new Set(['shim', 'account-vault-shim'])

export interface ScrubOptions {
  /** This engine's own data folder: its shims stay. */
  ownUserData: string
  /** Is this folder the data folder of a copy of this app? Looks for its `state.json`. */
  isAppDataDir?(dir: string): boolean
  /** The PATH separator. */
  delimiter?: string
}

export interface Scrubbed {
  env: Record<string, string>
  /** What went, by name — values are never reported, a ticket is a secret. */
  removed: string[]
}

export function scrubInheritedEnv(source: Readonly<Record<string, string | undefined>>, options: ScrubOptions): Scrubbed {
  const isAppDataDir = options.isAppDataDir ?? ((dir: string) => existsSync(join(dir, 'state.json')))
  const delimiter = options.delimiter ?? ':'
  const own = resolve(options.ownUserData)
  const removed: string[] = []
  /*
   * A config folder that arrived *with* a parent run's markers was that run's,
   * not this person's standing choice — the case measured above. One that
   * arrived alone (set in a login profile, say) is a deliberate setting and is
   * left exactly as it was.
   */
  const fromAParentRun = Object.keys(source).some((key) => RUN_MARKERS.test(key) || APP_SESSION_VARS.test(key))

  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(source)) {
    if (value === undefined) continue
    if (RUN_MARKERS.test(key) || APP_SESSION_VARS.test(key) || (key === 'CLAUDE_CONFIG_DIR' && fromAParentRun)) {
      removed.push(key)
      continue
    }
    env[key] = value
  }

  if (env.PATH !== undefined) {
    const kept = env.PATH.split(delimiter).filter((entry) => {
      if (entry === '' || !APP_SHIM_DIRS.has(basename(entry))) return true
      const home = resolve(dirname(entry))
      // Ours stays; another copy's goes — but only when it really is a copy of
      // this app's data folder, never a `shim` directory of something else.
      return home === own || !isAppDataDir(home)
    })
    if (kept.join(delimiter) !== env.PATH) {
      removed.push('PATH (another copy’s shims)')
      env.PATH = kept.join(delimiter)
    }
  }
  return { env, removed }
}

/** Apply it to the live `process.env`, in place, and say what went. */
export function scrubProcessEnv(options: ScrubOptions): string[] {
  const { env, removed } = scrubInheritedEnv(process.env, options)
  for (const key of Object.keys(process.env)) {
    if (!(key in env)) delete process.env[key]
  }
  if (env.PATH !== undefined) process.env.PATH = env.PATH
  return removed
}
