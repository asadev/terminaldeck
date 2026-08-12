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
    out[key] = value
  }
  return out
}
