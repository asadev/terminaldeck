/**
 * Strips a parent agent run's session markers out of the environment.
 *
 * Every session this app spawns must be a *top-level* run of the CLI. If the
 * app itself was launched from a terminal that was already inside an agent
 * session — entirely plausible for this audience — the whole marker set is in
 * `process.env`, and spreading that into a new PTY makes the CLI believe it is
 * a child of that run. Claude Code then prints
 *
 *     ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker
 *
 * and writes no JSONL. That is not cosmetic: chat mode reads those transcripts,
 * and so do cost, tokens and context pressure. Two headline features go blank
 * with one warning line in a terminal nobody is reading.
 *
 * Observed on a real launch: 19 `CLAUDE*` variables inherited, including
 * `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID` and `CLAUDE_EFFORT` —
 * the last of which pins effort for the session so the effort control cannot
 * change it.
 */

import { VAULT_HOME_ENV, VAULT_SOCKET_ENV, VAULT_TICKET_ENV } from './account-vault/keychain-shim'

/**
 * Kept even though it matches the strip pattern: it is how a profile points the
 * CLI at an isolated login, set deliberately per session rather than inherited.
 */
const KEEP = new Set(['CLAUDE_CONFIG_DIR'])

/**
 * `ANTHROPIC_*` is deliberately absent. Those are the user's own configuration
 * — API key, base URL, model overrides — and removing them would break setups
 * that depend on them. Only the parent *run's* identity is stripped.
 */
const STRIP = /^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_AGENT_SDK_VERSION|CLAUDE_CODE_.*|CLAUDE_PREVIEW_.*)$/

/**
 * The account vault's two variables, never inherited.
 *
 * A session running as an account this app keeps is handed the vault's address
 * and that account's ticket (`account-vault/runtime.ts`). If this app was itself
 * launched from inside such a session, both are in `process.env` — and copying
 * them into every new session would hand a session on the machine's own login a
 * ticket for somebody else's account. The shim would refuse it (the address is
 * another run's), but a session should never carry a ticket it was not given.
 * Each spawn that is entitled to one sets it again explicitly, after this.
 */
const VAULT_VARS = new Set([VAULT_SOCKET_ENV, VAULT_TICKET_ENV, VAULT_HOME_ENV])

export function stripInheritedSessionEnv(
  env: Record<string, string | undefined>,
  ownSessionVar: string,
): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) continue
    // Our own marker from a parent copy of this app, for the same reason.
    if (key === ownSessionVar) continue
    if (KEEP.has(key)) {
      out[key] = value
      continue
    }
    if (STRIP.test(key)) continue
    if (VAULT_VARS.has(key)) continue
    out[key] = value
  }
  return out
}

/**
 * An environment with the account vault's two variables taken out, everything
 * else exactly as it was.
 *
 * For the places that build a child's environment straight from `process.env`
 * rather than through {@link stripInheritedSessionEnv} — the sign-in probe, the
 * usage probe. If this app was launched from inside a session on an account it
 * keeps, both variables are in `process.env`, and a probe about a *different*
 * account would otherwise carry that account's ticket. The account it is
 * actually about sets its own again, after this.
 */
export function withoutVaultEnv<V extends string | undefined>(env: Record<string, V>): Record<string, V> {
  const out: Record<string, V> = {}
  for (const [key, value] of Object.entries(env)) {
    if (VAULT_VARS.has(key)) continue
    out[key] = value
  }
  return out
}
