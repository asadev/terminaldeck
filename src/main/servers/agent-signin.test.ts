import { describe, expect, it } from 'vitest'
import {
  AGENT_ENV_PROBE,
  AGENT_VERSION_AWK,
  readAgentEnv,
  signInCases,
  signInSnippet,
  type SignInVars,
} from './agent-signin'
import { PROBE_SCRIPT } from './probe.sh'
import { findScript } from './setup'

/**
 * The one place that knows how to ask a server which coding logins it holds.
 *
 * These are guards against the failure that produced this file rather than a
 * re-test of shell: the question was asked in two places, `probe.sh.ts` and
 * `setup.ts`, and the two copies gave different answers about the same machine —
 * a different field of `--version`, and a Codex check that could not tell "not
 * signed in" from "did not answer". What is pinned below is exactly the shape of
 * each of those mistakes, so that reintroducing one fails here rather than on
 * somebody's server.
 *
 * Everything the snippets do was measured on a real Hetzner Ubuntu box against
 * `@openai/codex` 0.149.0 and `@google/gemini-cli` 0.56.0, in every state each
 * of them has. See the header of the file under test for what was run.
 */

const VARS: SignInVars = {
  binary: 'b',
  state: 'i',
  account: 'e',
  codexHome: 'CXH',
  geminiEnv: 'GENV',
}

describe('asking a server which coding logins it holds', () => {
  it('reads Codex’s exit status rather than its output', () => {
    /*
     * Measured: signed out, `codex login status` exits **1** and prints *"Not
     * logged in"* on **stderr**. The version that read stdout therefore saw an
     * empty string and answered `unknown` — the state that draws no button and
     * says the question cannot be put — about a machine that had answered it
     * perfectly.
     */
    const codex = signInSnippet('codex', VARS)
    expect(codex).toContain('login status >/dev/null 2>&1')
    expect(codex).toContain('i=yes; else i=no; fi')
    expect(codex).not.toContain('Not logged in')
  })

  it('honours a CODEX_HOME the person set in their own shell', () => {
    // Both the status call and the file the address is read out of. Asking the
    // default directory on a machine whose shell names another one answers
    // "not signed in" about an account that signs in perfectly.
    const codex = signInSnippet('codex', VARS)
    expect(codex).toContain('CODEX_HOME="${CXH:-$HOME/.codex}" "$b" login status')
    expect(codex).toContain('"${CXH:-$HOME/.codex}/auth.json"')
  })

  it('takes only the address out of Codex’s token, and only from the public half of it', () => {
    /*
     * `auth.json` holds an access token and a refresh token beside the id token.
     * The id token's middle segment is base64url JSON with an `email` claim in
     * it and is not a secret; nothing else in that file is read, printed, or
     * carried anywhere.
     */
    const codex = signInSnippet('codex', VARS)
    expect(codex).toContain('cut -d. -f2')
    expect(codex).toContain('"email":"')
    expect(codex).not.toContain('access_token')
    expect(codex).not.toContain('refresh_token')
  })

  it('pads base64url before decoding it, and tries more than one decoder', () => {
    // Unpadded input is the ordinary case and every decoder rejects it; and
    // `base64 -d` is GNU and busybox, `-D` is BSD, and plenty of small servers
    // have only `openssl`.
    const codex = signInSnippet('codex', VARS)
    expect(codex).toContain('${#tdt} % 4')
    expect(codex).toContain('base64 -d')
    expect(codex).toContain('base64 -D')
    expect(codex).toContain('openssl base64 -d -A')
  })

  it('applies Gemini’s own stated rule for whether it is signed in', () => {
    /*
     * Measured: with no account it answers *"Please set an Auth method in your
     * <home>/.gemini/settings.json or specify one of the following environment
     * variables before running: GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI,
     * GOOGLE_GENAI_USE_GCA"*. That sentence is the check.
     */
    const gemini = signInSnippet('gemini', VARS)
    expect(gemini).toContain('"selectedType"')
    // The older spelling of the same setting, still on installs that predate it
    // moving under `security.auth`.
    expect(gemini).toContain('"selectedAuthType"')
    expect(gemini).toContain('tdg=$GENV')
    expect(AGENT_ENV_PROBE).toContain('GEMINI_API_KEY')
    expect(AGENT_ENV_PROBE).toContain('GOOGLE_GENAI_USE_VERTEXAI')
    expect(AGENT_ENV_PROBE).toContain('GOOGLE_GENAI_USE_GCA')
  })

  it('never runs an agent to find out, because that would spend somebody’s quota', () => {
    // `gemini -p hi` answers this question perfectly and bills a stranger for a
    // prompt they did not type, every time a server page is opened.
    for (const id of ['claude', 'codex', 'gemini'] as const) {
      expect(signInSnippet(id, VARS)).not.toContain('-p ')
    }
  })

  it('reads Gemini’s address only where there is one to read', () => {
    // Present for the Google sign-in and absent for an API key, which has
    // nobody's address on it. An absent file leaves the address empty rather
    // than making one up.
    const gemini = signInSnippet('gemini', VARS)
    expect(gemini).toContain('google_accounts.json')
    expect(gemini).toContain('"active"')
  })

  it('picks the version field the same way for all three', () => {
    /*
     * The three print it three ways — `2.1.238 (Claude Code)`, `codex-cli
     * 0.149.0`, `0.56.0` — and the two copies of this took opposite ends. Both
     * were on screen: `Codex CLI codex-cli — not signed in` on one pane, and
     * `Claude Code Code) is installed` on the other.
     */
    expect(AGENT_VERSION_AWK).toContain('^v?[0-9]+\\.[0-9]')
    expect(AGENT_VERSION_AWK).not.toContain('print $1}')
    expect(AGENT_VERSION_AWK).not.toContain('print $NF')
  })

  it('names the caller’s own variables, so one script can be spliced into two', () => {
    const other = signInSnippet('claude', { ...VARS, binary: 'ab', state: 'ai', account: 'ae' })
    expect(other).toContain('"$ab" auth status --json')
    expect(other).toContain('ai=yes')
    expect(other).toContain('ae=$(')
  })

  it('pulls the login shell’s settings out of one row rather than a second spawn', () => {
    const lines = readAgentEnv('ALOGIN', VARS)
    expect(lines).toContain("grep '^TDENV'")
    expect(lines).toContain('CXH=$(printf')
    expect(lines).toContain('GENV=$(printf')
  })

  it('is what the probe actually sends, rather than a second copy of it', () => {
    // The guard that makes all of the above worth anything: the emitted script
    // contains these snippets, so a probe that stopped using them fails here.
    const inProbe = signInCases('a', { ...VARS, binary: 'ab', state: 'ai', account: 'ae' })
    for (const line of inProbe.split('\n')) {
      if (line.trim() === '') continue
      expect(PROBE_SCRIPT).toContain(line)
    }
    expect(PROBE_SCRIPT).toContain(AGENT_VERSION_AWK)
    expect(PROBE_SCRIPT).toContain(AGENT_ENV_PROBE)
  })

  it('is what the second caller sends too, which is the whole point of one copy', () => {
    /*
     * `setup.ts` asks this again the moment an install or a sign-in finishes, to
     * say what the row should now read, and that was the copy that had drifted.
     * Both callers, one script.
     */
    for (const id of ['claude', 'codex', 'gemini'] as const) {
      const script = findScript(id)
      expect(script).toContain(AGENT_VERSION_AWK)
      expect(script).toContain(AGENT_ENV_PROBE)
      for (const line of signInSnippet(id, VARS).split('\n')) {
        if (line.trim() === '') continue
        expect(script).toContain(line)
      }
    }
  })
})
