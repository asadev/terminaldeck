/**
 * Which login a coding agent on a server is on, asked one way.
 *
 * ## Why this file exists
 *
 * Because the question was being asked in two places with two different
 * answers. `probe.sh.ts` asks it for the server page and the account list;
 * `setup.ts`'s `findScript` asks it again the moment an install or a sign-in
 * finishes, to say what the row should now read. They drifted exactly as far as
 * two copies of anything drift:
 *
 *  - one took the **first** field of `--version` and the other the **last**, so
 *    the same Codex CLI was `codex-cli` on one screen and `0.149.0` on the
 *    other, and the same Claude Code was `2.1.238` on one and `Code)` on the
 *    other. Both were on screen, in a row that reads *"Claude Code Code) is
 *    installed"*.
 *  - one asked Codex `login status` and read its **stdout**, which is empty
 *    when nobody is signed in — measured: *"Not logged in"* goes to stderr and
 *    the exit status is 1 — so a machine with no Codex login answered
 *    `unknown`, which is the state that draws no button and says the question
 *    cannot be put.
 *
 * So the snippets live here, once, and both callers name their own variables.
 *
 * ## Everything below was measured on a real server
 *
 * A Hetzner Ubuntu 24.04 box on 2026-08-21, with `@openai/codex` 0.149.0 and
 * `@google/gemini-cli` 0.56.0 installed into a scratch home the same way this
 * app installs them — `npm install -g --prefix "$HOME/.local"` — and driven
 * through every state each one has:
 *
 *  - **Claude Code** answers `auth status --json` with a `loggedIn` flag and the
 *    address on the account. Unchanged; it was already right.
 *  - **Codex CLI** has `codex login status`. Signed out it exits **1** and
 *    prints *"Not logged in"* on stderr; signed in with ChatGPT it exits 0 and
 *    prints *"Logged in using ChatGPT"*; signed in with an API key it exits 0
 *    and prints *"Logged in using an API key - sk-…-real"*. **The exit status is
 *    the signal**, because it is the one that is right in all three and does not
 *    depend on a sentence nobody promised not to reword.
 *  - Codex prints no address in any of those, and there is one: `auth.json`
 *    holds an OpenID `id_token` whose payload carries an `email` claim. That
 *    payload is public — it is the middle segment of a JWT, base64url, not a
 *    secret and not the credential — and {@link codexAccount} decodes exactly
 *    it and takes exactly that one claim. The access and refresh tokens beside
 *    it are never read, never printed and never leave that machine.
 *  - **Gemini CLI** has no login command at all — measured against its own
 *    `--help`, whose subcommands are mcp, extensions, skills, hooks and gemma.
 *    What it *does* have is a rule it states itself. Run with no account it
 *    answers: *"Please set an Auth method in your <home>/.gemini/settings.json
 *    or specify one of the following environment variables before running:
 *    GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA"*. So the
 *    check below is that sentence, read rather than invented: a chosen auth type
 *    in its settings file, or one of the three environment variables in the
 *    login shell. Where the chosen type is the Google sign-in, the address is in
 *    `google_accounts.json` under `active` — verified against a real signed-in
 *    install, where `old` holds the previous addresses in the same shape.
 *
 * That last one is not a guess dressed as a fact. It is the same condition the
 * CLI applies to itself before it refuses to run, and when it says yes with no
 * address the answer carries no address rather than inventing one.
 *
 * ## What is deliberately not here
 *
 * Nothing runs the agent. `gemini -p` would answer the question perfectly and
 * would also spend somebody's quota on a prompt they did not type, every time a
 * server page is opened. A probe that costs the person money is not a probe.
 */

import type { AgentId } from './facts'

/**
 * Which field of `--version` is the version.
 *
 * The three print it in three shapes — `2.1.238 (Claude Code)`, `codex-cli
 * 0.149.0`, `0.56.0` — so neither the first field nor the last is right for all
 * of them, and both were being used. This picks the first field that looks like
 * a version and drops a leading `v`, which is right for all three and answers
 * nothing at all for a binary that would not start. Empty is a state the callers
 * already have a sentence for: *"installed, and would not start."*
 */
export const AGENT_VERSION_AWK =
  "{for(i=1;i<=NF;i++) if ($i ~ /^v?[0-9]+\\.[0-9]/) {sub(/^v/,\"\",$i); print $i; exit}}"

/**
 * The line that asks the **login shell** for the two settings that decide two of
 * the three answers, printed as one tab-separated row tagged `TDENV`.
 *
 * It has to be the login shell rather than the one this script is running in:
 * `sshd` starts a non-interactive command with a bare environment, so a
 * `CODEX_HOME` or a `GEMINI_API_KEY` exported from somebody's `.profile` — which
 * is where they live, and which every terminal in this app inherits — is simply
 * not set here. Asking the wrong shell would answer *not signed in* about a
 * machine whose own terminal signs in perfectly.
 *
 * One spawn, and both callers already pay for it: they each run a login shell to
 * find the binaries in the first place, and this rides that same call.
 */
export const AGENT_ENV_PROBE =
  'printf "TDENV\\t%s\\t%s\\n" "${CODEX_HOME:-}" "${GEMINI_API_KEY:+k}${GOOGLE_GENAI_USE_VERTEXAI:+v}${GOOGLE_GENAI_USE_GCA:+g}"'

/** The shell variables one snippet reads and writes. Named by the caller. */
export interface SignInVars {
  /** Holds the absolute path of the agent's binary. */
  binary: string
  /** Set to `yes`, `no`, or left as it was — which the callers seed as `unknown`. */
  state: string
  /** Set to the address, or left empty when there is none to read. */
  account: string
  /** Holds the login shell's `CODEX_HOME`, empty when it has none. */
  codexHome: string
  /** Holds the login shell's answer to {@link AGENT_ENV_PROBE}'s second column. */
  geminiEnv: string
}

/** The four lines that pull `TDENV` out of a login shell's output. */
export function readAgentEnv(from: string, vars: Pick<SignInVars, 'codexHome' | 'geminiEnv'>): string {
  return [
    `TDENV=$(printf '%s\\n' "$${from}" | grep '^TDENV' | head -n 1)`,
    `${vars.codexHome}=$(printf '%s' "$TDENV" | cut -f2)`,
    `${vars.geminiEnv}=$(printf '%s' "$TDENV" | cut -f3)`,
  ].join('\n')
}

/**
 * How one agent is asked, in POSIX `sh`.
 *
 * `sh`, not `bash`: plenty of real servers have neither bash nor GNU coreutils,
 * and the two places this is spliced into are both already written that way.
 * `${#var}` and `$((…))` are POSIX; `base64 -d` is not universal, which is why
 * the decode below tries three spellings and gives up quietly rather than
 * printing an error into a probe's output.
 */
export function signInSnippet(id: AgentId, v: SignInVars): string {
  if (id === 'claude') {
    return [
      `tds=$("$${v.binary}" auth status --json 2>/dev/null | tr -d ' \\t\\n\\r')`,
      'case "$tds" in',
      `  *'"loggedIn":true'*)  ${v.state}=yes ;;`,
      `  *'"loggedIn":false'*) ${v.state}=no ;;`,
      'esac',
      `${v.account}=$(printf '%s' "$tds" | sed -n 's/.*"email":"\\([^"]*\\)".*/\\1/p')`,
    ].join('\n')
  }
  if (id === 'codex') {
    return [
      // The exit status, not the sentence. See the header: signed out is exit 1
      // with its whole answer on stderr, so reading stdout finds nothing at all
      // and cannot tell "no" from "did not answer".
      `if CODEX_HOME="\${${v.codexHome}:-$HOME/.codex}" "$${v.binary}" login status >/dev/null 2>&1; then ${v.state}=yes; else ${v.state}=no; fi`,
      `if [ "$${v.state}" = yes ]; then`,
      codexAccount(v),
      'fi',
    ].join('\n')
  }
  return [
    // The CLI's own rule, in the CLI's own words. See the header.
    `tdg=$(sed -n 's/.*"selectedType"[^"]*"\\([^"]*\\)".*/\\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)`,
    // The older spelling of the same setting, still on installs that predate the
    // move under `security.auth`.
    `[ -n "$tdg" ] || tdg=$(sed -n 's/.*"selectedAuthType"[^"]*"\\([^"]*\\)".*/\\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)`,
    `[ -n "$tdg" ] || tdg=$${v.geminiEnv}`,
    `if [ -n "$tdg" ]; then ${v.state}=yes; else ${v.state}=no; fi`,
    `if [ "$${v.state}" = yes ]; then`,
    // Present only for the Google sign-in; an API key has no address, and an
    // absent file leaves this empty, which is the honest "signed in, and this
    // machine does not record as whom".
    `  ${v.account}=$(sed -n 's/.*"active"[^"]*"\\([^"]*\\)".*/\\1/p' "$HOME/.gemini/google_accounts.json" 2>/dev/null | head -n 1)`,
    'fi',
  ].join('\n')
}

/**
 * The address on a Codex login, out of the public half of its own id token.
 *
 * Base64url has no padding, so the length is restored before decoding — a
 * payload whose length is 2 or 3 past a multiple of four is the ordinary case
 * and every decoder rejects it unpadded. The three decoders are tried in the
 * order of how likely they are to exist: GNU and busybox `base64 -d`, BSD's
 * `-D`, then `openssl`, which is on a great many servers that have none of the
 * others.
 */
function codexAccount(v: SignInVars): string {
  return [
    `  tdt=$(sed -n 's/.*"id_token"[^"]*"\\([^"]*\\)".*/\\1/p' "\${${v.codexHome}:-$HOME/.codex}/auth.json" 2>/dev/null | head -n 1 | cut -d. -f2)`,
    '  if [ -n "$tdt" ]; then',
    '    case $(( ${#tdt} % 4 )) in 2) tdt="$tdt==" ;; 3) tdt="$tdt=" ;; esac',
    `    tdp=$(printf '%s' "$tdt" | tr '_-' '/+')`,
    `    tdj=$(printf '%s' "$tdp" | base64 -d 2>/dev/null)`,
    `    [ -n "$tdj" ] || tdj=$(printf '%s' "$tdp" | base64 -D 2>/dev/null)`,
    `    [ -n "$tdj" ] || tdj=$(printf '%s' "$tdp" | openssl base64 -d -A 2>/dev/null)`,
    `    ${v.account}=$(printf '%s' "$tdj" | tr -d ' \\t\\n\\r' | sed -n 's/.*"email":"\\([^"]*\\)".*/\\1/p' | head -n 1)`,
    '  fi',
  ].join('\n')
}

/** The three, spliced into one `case` over a variable holding the agent's id. */
export function signInCases(agentVar: string, v: SignInVars): string {
  const ids: AgentId[] = ['claude', 'codex', 'gemini']
  return [
    `case "$${agentVar}" in`,
    ...ids.flatMap((id) => [`${id})`, signInSnippet(id, v), '  ;;']),
    'esac',
  ].join('\n')
}
