import { describe, expect, it } from 'vitest'
import {
  AGENT_CATALOG,
  AGENT_ENTRIES,
  LOGIN_AGENTS,
  LOOKUP_AGENTS,
  MULTI_LOGIN_AGENTS,
  hasAnyLogin,
  hasMultipleLogins,
  loginsNote,
} from './agent-catalog'

/**
 * The one declaration every other list is built from.
 *
 * These are not tests of values — a label is a label — they are tests of the
 * *invariants* that make the table safe to extend, because the point of the
 * table is that adding an agent is one entry and nothing else. An entry that
 * breaks one of these produces exactly the failure the table replaced: a picker
 * offering something that cannot start, or an agent that exists in one list and
 * not the next.
 */

describe('every entry', () => {
  it('records what was actually run to check it', () => {
    /*
     * The rule with no exceptions: never declare an agent that has not been
     * launched. A picker full of rows that die on selection is the bug this pass
     * was opened to fix — a recorded session where pressing Add on a Codex
     * account opened a blank terminal holding a Node stack trace.
     */
    for (const entry of AGENT_ENTRIES) {
      expect(entry.verified.length, `${entry.id} has no verification note`).toBeGreaterThan(40)
    }
  })

  it('gives anything with an install command somewhere to read about it', () => {
    for (const entry of AGENT_ENTRIES) {
      if (entry.install === null) continue
      expect(entry.url, `${entry.id} can be installed but links nowhere`).not.toBeNull()
    }
  })

  it('explains itself whenever it is not offered two logins', () => {
    // A refusal with no reason leaves a person unable to tell whether the app
    // looked or gave up, and the old copy — "Separate accounts are Claude-only
    // for now" — was one sentence covering three agents and wrong about two.
    for (const entry of AGENT_ENTRIES) {
      if (entry.logins === 'multiple') continue
      expect(entry.loginsNote, `${entry.id} refuses a second login silently`).not.toBeNull()
    }
  })

  it('keys itself by its own id', () => {
    for (const [key, entry] of Object.entries(AGENT_CATALOG)) {
      expect(entry.id).toBe(key)
    }
  })

  it('only claims a status format it can be asked for', () => {
    /*
     * `statusArgs` and `statusFormat` are two halves of one answer, with exactly
     * one legitimate asymmetry: `gemini-local` is read off the machine rather
     * than from a CLI, because `gemini --help` lists no auth or login
     * subcommand. Any other mismatch is a probe that would spawn with nothing to
     * parse, or a parser waiting for a probe that never runs.
     */
    for (const entry of AGENT_ENTRIES) {
      if (entry.statusArgs !== null) {
        expect(entry.statusFormat, `${entry.id} probes with no parser`).not.toBeNull()
        expect(entry.statusFormat).not.toBe('gemini-local')
      }
      if (entry.statusFormat !== null && entry.statusFormat !== 'gemini-local') {
        expect(entry.statusArgs, `${entry.id} parses output it never asks for`).not.toBeNull()
      }
    }
  })

  it('never offers isolation without a variable to isolate with', () => {
    // `configEnv: null` with `logins: 'multiple'` would be an account mechanism
    // with nothing to export — two names for one login, which is the failure
    // `provider-accounts.ts` exists to prevent.
    for (const entry of AGENT_ENTRIES) {
      if (entry.logins !== 'multiple') continue
      expect(entry.configEnv, `${entry.id} isolates with no variable`).not.toBeNull()
    }
  })
})

describe('the derived lists', () => {
  it('leaves the shell out of everything that looks a binary up', () => {
    // Its binary is `$SHELL` or `%COMSPEC%`, which is a platform question and
    // not a PATH one. Looking up the empty string would report it missing.
    expect(LOOKUP_AGENTS.map((entry) => entry.id)).toEqual(['claude', 'codex', 'gemini'])
  })

  it('separates "may there be two?" from "is there one?"', () => {
    /*
     * The distinction the Gemini bug turned on, pinned at its source.
     *
     * While these were one boolean, Gemini answered false to both — so it was
     * left out of the Accounts list entirely and the machine's single Gemini
     * login could not be signed in from this app: *"I want to bring only one
     * login for Gemini… but here currently I cannot even bring one login."*
     */
    expect(MULTI_LOGIN_AGENTS).toEqual(['claude', 'codex'])
    expect(LOGIN_AGENTS).toEqual(['claude', 'codex', 'gemini'])
    expect(hasMultipleLogins('gemini')).toBe(false)
    expect(hasAnyLogin('gemini')).toBe(true)
    expect(hasAnyLogin('shell')).toBe(false)
  })

  it('answers with the agent’s own sentence, never a generic one', () => {
    expect(loginsNote('gemini')).toContain('keychain')
    expect(loginsNote('shell')).toContain('shell')
    expect(loginsNote('gemini')).not.toBe(loginsNote('shell'))
  })
})
