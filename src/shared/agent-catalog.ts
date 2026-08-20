import type { ProviderId } from './types'

/**
 * Every agent this build knows how to run, declared once.
 *
 * ## Why this file exists
 *
 * Adding an agent used to mean editing four hardcoded lists that nothing kept
 * in step: the spawn table in `main/providers.ts`, the account strategies in
 * `main/provider-accounts.ts`, the rows a Setup panel draws in
 * `main/prerequisites.ts`, and the catalogue the New-session dialog renders in
 * `renderer/components/ProviderPicker.tsx`. Four places, four chances to forget
 * one, and the comments in those files record what forgetting one costs — a
 * provider added to the union and silently skipped by a detection loop, an
 * account row with nothing in it, a dialog offering an agent the spawn declines.
 *
 * The brief was explicit about where that has to go:
 *
 *   > *"there should be a plus button to add with the big list of type of AI
 *   > agents to connect, not only codex not only cloud code. There are so many
 *   > grok agents… take a look how many types of agents cursor and VS Code
 *   > have."*
 *
 * A list that long cannot be four hardcoded branches. So an agent is an entry
 * here and everything else reads it: `providersFor` builds its spawn table from
 * `bin`/`args`/`resumeArgs`, `ACCOUNT_STRATEGIES` from `logins`/`configEnv`,
 * `PROVIDER_OPTIONS` from `label`/`description`/`install`, and
 * `agent-binaries.ts` from `alternateBins`/`versionArgs`. Tests in each of those
 * modules assert the derivation rather than the values, so a new entry cannot be
 * half-wired.
 *
 * ## The rule for adding one, and it has no exceptions
 *
 * **Never declare an agent that has not been launched on a real machine.** A
 * picker full of rows that die on selection is the exact bug this pass was
 * opened to fix: a recorded session where pressing Add on a Codex account opened
 * a blank terminal that printed a raw Node `ENOENT` stack trace and exited. So
 * every entry below carries a `verified` line saying what was run and what it
 * answered, and an entry without one does not belong in the table.
 *
 * ## Agents verified on this machine but not yet in the table
 *
 * These are real, they install from npm, and each one was installed into a
 * throwaway prefix and launched on 2026-08-17 — the package name, the binary
 * name and the version each one printed are recorded here so the next person
 * does not have to guess any of the three:
 *
 *     @github/copilot        → copilot   "GitHub Copilot CLI 1.0.80"
 *     opencode-ai            → opencode  "1.18.18"
 *     @qwen-code/qwen-code   → qwen      "0.21.12"
 *     @charmland/crush       → crush     "crush version v0.89.0"
 *     @vibe-kit/grok-cli     → grok      "1.0.1"
 *     @augmentcode/auggie    → auggie    "0.35.0 (commit 9a7f3836)"
 *     @sourcegraph/amp       → amp       "0.0.1786910444-gbc03aa"
 *
 * They are *not* declared below, and the reason is a type rather than a doubt:
 * `ProviderId` in `types.ts` is a closed union of four names, and every
 * `Record<ProviderId, …>` in the main process — the spawn table, the detection
 * answer, the account strategies — is total over it by construction, which is
 * what makes a missed provider a compile error instead of a silent skip. Adding
 * a fifth id is therefore a change to `types.ts` and to the session-start path
 * in `main/host-core.ts`, both of which are shared files this pass was told not
 * to edit. Everything on *this* side of that line is done: an entry below plus
 * the id in the union is the whole of the work, and nothing else needs touching.
 */

/**
 * How many logins of this agent this app can keep apart.
 *
 *  - `multiple` — a config-directory variable was watched move a login, so two
 *    accounts are genuinely two accounts.
 *  - `single` — the agent has exactly one login per machine. It still gets an
 *    account row, because a row is how a person signs in; what it does not get
 *    is a second one.
 *  - `none` — nothing to sign in to.
 *  - `unmeasured` — nobody here has looked. Only ever an agent somebody added
 *    themselves; see below.
 *
 * The distinction between `multiple` and `single` is the one that matters, and
 * it is not cosmetic: Gemini keeps its OAuth token in one keychain entry whose
 * coordinates do not read the config directory, so a second Gemini account would
 * *overwrite* the first rather than sit beside it. `provider-accounts.ts` holds
 * the measurement. Before this field existed the two answers were one boolean,
 * Gemini was false, and the consequence was the reported bug: no Gemini row at
 * all, so a person could not sign in even once.
 *
 * ## Why `unmeasured` is a fourth answer and not `none`
 *
 * Nothing in this table is ever `unmeasured` — every entry below carries a
 * measurement, which is the rule. It exists for `customEntry` in
 * `shared/custom-agents.ts`, which turns an agent the person added into one of
 * these so that every screen can read one shape. That agent is a command on this
 * machine's PATH and nothing else is known about it, and `none` would not be
 * ignorance written down, it would be a claim: *this agent has no login*. Half
 * the CLIs somebody would add do have one. Saying so wrongly puts a person in
 * front of a session that will ask them to sign in on a screen that has just
 * told them there is nothing to sign into.
 *
 * The two predicates below both answer false for it, and that is the intended
 * reading: an account row is offered where a mechanism was measured, and nowhere
 * else. `loginsNote` carries the sentence.
 */
export type AgentLogins = 'multiple' | 'single' | 'none' | 'unmeasured'

/** How an agent's "am I signed in?" output has to be read. */
export type AgentStatusFormat = 'claude-json' | 'codex-text' | 'gemini-local'

export interface AgentEntry {
  id: ProviderId
  label: string
  /** One line under the label in a picker: what this agent is. */
  description: string
  /**
   * The name to look up on PATH, or null for the platform's own login shell.
   *
   * Null is not "unknown": a shell's binary is `$SHELL` on POSIX and `%COMSPEC%`
   * on Windows, which is a platform question rather than a catalogue one, and
   * `providersFor` answers it. Everything that asks "is this installed?" skips a
   * null `bin` rather than looking up the empty string.
   */
  bin: string | null
  /** Args for a fresh session. */
  args: readonly string[]
  /**
   * Args to continue the most recent session in a folder; empty means no resume.
   *
   * **These are not safe to pass unconditionally, and the reason is a silent
   * data loss.** `--continue` names no conversation — it means *the most recent
   * one in this folder*, resolved by the CLI at spawn — so two sessions started
   * in one folder both attach to the same transcript and both append to it from
   * the same parent message. `ACCOUNT-MODEL.md` has the measurement: two
   * divergent branches, one session id, one file, every line parsing, no error
   * anywhere, and whichever branch the next `--continue` lands on orphans the
   * other. Neither session ever sees the other's turns.
   *
   * It is not an account problem — two sessions of one login do it too — and it
   * cannot be detected or repaired afterwards, so it is prevented at the spawn
   * instead. This table stays a table: the rule lives in `main/one-conversation.ts`
   * and is applied by `host-core.ts` at the one line that chooses between these
   * args and `args`. Nothing may pass `resumeArgs` to a spawn without going
   * through it.
   */
  resumeArgs: readonly string[]
  /** What a person would type to get it. Null when there is nothing to install. */
  install: string | null
  /** Where to read about it. */
  url: string | null
  /**
   * Absolute paths to try when `bin` resolves on PATH but will not run.
   *
   * `~/` is the user's home and is expanded by `main/agent-binaries.ts`; nothing
   * in the renderer ever resolves one of these.
   *
   * This exists because of one real, reproducible failure rather than as a
   * general safety net. The npm `@openai/codex` package installs a JavaScript
   * launcher that spawns a vendored native binary, and on this machine that
   * binary is absent — `vendor/aarch64-apple-darwin/` contains a `path/` folder
   * and nothing else — so `codex --version` exits 1 having printed a Node
   * `ENOENT` stack trace naming the missing file. `which codex` still answers,
   * so every "is it installed?" check said yes and every spawn died. A complete
   * and working copy of the same CLI ships inside Codex's own plugin directory
   * and answers `codex-cli 0.146.0-alpha.3.1`, which is where this points.
   */
  alternateBins: readonly string[]
  /**
   * Args that make the binary print its version and exit.
   *
   * The runnability probe, not a nicety: a version read is the cheapest thing
   * that proves a binary can actually be executed, and proving that *before* a
   * PTY is opened is the difference between a sentence on screen and a stack
   * trace in a terminal the user did not ask for. Null for an agent with no such
   * flag, which is then reported unknown rather than guessed at.
   */
  versionArgs: readonly string[] | null
  logins: AgentLogins
  /** The variable that relocates this agent's configuration, when it has one. */
  configEnv: string | null
  /** Where the credential lands inside that directory, or null for a keychain. */
  credentialFile: string | null
  /** Args that ask the CLI whether a directory is signed in. */
  statusArgs: readonly string[] | null
  /** How to read that answer. `gemini-local` reads the machine, not a CLI. */
  statusFormat: AgentStatusFormat | null
  /** Args that start an interactive sign-in. Shown to the user; never run behind their back. */
  signInArgs: readonly string[] | null
  /**
   * One sentence for the screen when `logins` is not `multiple`. Never generic —
   * a reason that does not match the agent leaves a person unable to tell
   * whether the app looked or gave up.
   */
  loginsNote: string | null
  /** What was run to check this entry, and what it answered. */
  verified: string
}

/**
 * The table.
 *
 * A `Record<ProviderId, …>` rather than an array so a provider added to the
 * union fails to compile *here*, at the one place that would otherwise be
 * silently skipped — the same reason `detectProviders` names its agents instead
 * of deriving them from `Object.keys`.
 */
export const AGENT_CATALOG: Record<ProviderId, AgentEntry> = {
  claude: {
    id: 'claude',
    label: 'Claude Code',
    description:
      "Anthropic's agentic CLI. Writes transcripts, so token and context tracking work.",
    bin: 'claude',
    args: [],
    resumeArgs: ['--continue'],
    install: 'npm install -g @anthropic-ai/claude-code',
    url: 'https://docs.anthropic.com/en/docs/claude-code',
    alternateBins: [],
    versionArgs: ['--version'],
    logins: 'multiple',
    configEnv: 'CLAUDE_CONFIG_DIR',
    // Present on Windows and on installs that keep credentials in the tree; on
    // macOS the Keychain holds it instead and its absence proves nothing.
    credentialFile: '.credentials.json',
    statusArgs: ['auth', 'status', '--json'],
    statusFormat: 'claude-json',
    signInArgs: ['auth', 'login'],
    loginsNote: null,
    verified:
      '`claude --version` → 2.1.233. `CLAUDE_CONFIG_DIR=/tmp/fresh claude auth status --json` → loggedIn false, while the default directory answers loggedIn true — same binary, two directories, two logins.',
  },
  codex: {
    id: 'codex',
    label: 'Codex CLI',
    description: "OpenAI's coding agent. Sign in with a ChatGPT account.",
    bin: 'codex',
    args: [],
    resumeArgs: ['resume', '--last'],
    install: 'npm install -g @openai/codex',
    url: 'https://github.com/openai/codex',
    // See `alternateBins` on the interface: the npm launcher's vendored binary
    // is missing on this machine and this is the working copy of the same CLI.
    alternateBins: ['~/.codex/plugins/.plugin-appserver/codex'],
    versionArgs: ['--version'],
    logins: 'multiple',
    configEnv: 'CODEX_HOME',
    credentialFile: 'auth.json',
    statusArgs: ['login', 'status'],
    // `codex login status` has no `--json`; the parser reads its sentences.
    statusFormat: 'codex-text',
    signInArgs: ['login'],
    loginsNote: null,
    verified:
      '`~/.codex/plugins/.plugin-appserver/codex --version` → codex-cli 0.146.0-alpha.3.1, and `login status` → "Logged in using ChatGPT" while a fresh CODEX_HOME answers "Not logged in". The npm launcher on PATH exits 1 with a spawn ENOENT for its own vendored binary, which is why `alternateBins` is not empty.',
  },
  gemini: {
    id: 'gemini',
    label: 'Gemini CLI',
    description: "Google's coding agent.",
    bin: 'gemini',
    args: [],
    /*
     * Gemini's resume flag exists and is deliberately unused.
     *
     * `gemini --help` (0.32.1, installed) documents `-r, --resume`. What could
     * not be exercised is the case that decides whether it is safe: `--resume
     * latest` in a folder with no previous session. A resume flag that turns out
     * to error on an empty history kills the tab with no explanation, which is
     * worse than not offering resume — so the option is simply not offered, and
     * `canResume` on the picker row says the same thing.
     */
    resumeArgs: [],
    install: 'npm install -g @google/gemini-cli',
    url: 'https://github.com/google-gemini/gemini-cli',
    alternateBins: [],
    versionArgs: ['--version'],
    /*
     * One login, and that is a whole answer rather than a refusal.
     *
     * `GEMINI_CLI_HOME` is real and moves the settings, the history and the
     * chosen auth *method*. What it does not move is the OAuth token:
     * `OAuthCredentialStorage` in the shipped `@google/gemini-cli-core` writes
     * through `HybridTokenStorage` to keychain service `gemini-cli-oauth`,
     * account `main-account`, and neither constant reads the home. So two Gemini
     * "accounts" would address one keychain item and the second sign-in would
     * *overwrite* the first.
     *
     * That is an argument against a *second* account. It was read as an argument
     * against having any, and the consequence is the reported bug — no Gemini row
     * anywhere, so the machine's one Gemini login could not be signed in from
     * this app at all: *"I want to bring only one login for Gemini… but here
     * currently I cannot even bring one login."* `single` is the honest answer:
     * one row, one login, no second.
     */
    logins: 'single',
    // Named rather than nulled, because "there is no variable" would be false
    // and the next person would go looking for one.
    configEnv: 'GEMINI_CLI_HOME',
    credentialFile: null,
    // Gemini has no `auth status` subcommand — `gemini --help` lists mcp,
    // extensions, skills and hooks and nothing else — so the machine is read
    // instead of the CLI. `main/gemini-signin.ts` does the reading.
    statusArgs: null,
    statusFormat: 'gemini-local',
    // Nor a `login` subcommand: signing in happens inside a session, where the
    // CLI draws its own auth-method dialog on first run.
    signInArgs: null,
    loginsNote:
      'Gemini keeps one login per machine, in a keychain entry that is the same for every configuration directory — so a second Gemini account here would replace the first rather than sit beside it. The one login below is the machine’s, and signing in from it signs Gemini in everywhere.',
    verified:
      '`gemini --version` → 0.32.1. `gemini --help` lists no auth or login subcommand, so sign-in state is read from the machine: keychain service `gemini-cli-oauth`, `~/.gemini/oauth_creds.json`, `~/.gemini/google_accounts.json` and `security.auth.selectedType` in `~/.gemini/settings.json`. On this machine none of the four is present, which matches the CLI refusing to start with "Please set an Auth method".',
  },
  shell: {
    id: 'shell',
    label: 'Shell',
    description: 'A plain login shell. No agent, no telemetry — just a terminal.',
    // The platform's own login shell. See the note on `bin`.
    bin: null,
    args: [],
    resumeArgs: [],
    install: null,
    url: null,
    alternateBins: [],
    versionArgs: null,
    logins: 'none',
    configEnv: null,
    credentialFile: null,
    statusArgs: null,
    statusFormat: null,
    signInArgs: null,
    loginsNote: 'A plain shell has no account to sign in to.',
    verified: 'Resolved from $SHELL / %COMSPEC% at runtime; never looked up on PATH.',
  },
}

/** Every entry, in the order screens should list them. */
export const AGENT_ENTRIES: readonly AgentEntry[] = [
  AGENT_CATALOG.claude,
  AGENT_CATALOG.codex,
  AGENT_CATALOG.gemini,
  AGENT_CATALOG.shell,
]

/**
 * The agents with a binary to look up — everything except the shell.
 *
 * Derived from `bin` rather than by naming three ids, so a fifth entry joins
 * every detection loop in the app by existing.
 */
export const LOOKUP_AGENTS: readonly AgentEntry[] = AGENT_ENTRIES.filter(
  (entry) => entry.bin !== null,
)

/** True when two logins of this agent are genuinely two logins. */
export function hasMultipleLogins(id: ProviderId): boolean {
  return AGENT_CATALOG[id]?.logins === 'multiple'
}

/**
 * True when this agent has a login at all — one or many.
 *
 * The predicate the Accounts screen lists rows from. `hasMultipleLogins` is the
 * one that decides whether *Add* is offered, and keeping them apart is the whole
 * of the Gemini fix.
 */
export function hasAnyLogin(id: ProviderId): boolean {
  const logins = AGENT_CATALOG[id]?.logins
  return logins === 'multiple' || logins === 'single'
}

/** Ids that can hold more than one account, in catalogue order. */
export const MULTI_LOGIN_AGENTS: readonly ProviderId[] = AGENT_ENTRIES.filter((entry) =>
  hasMultipleLogins(entry.id),
).map((entry) => entry.id)

/** Ids with a login of any kind, in catalogue order. */
export const LOGIN_AGENTS: readonly ProviderId[] = AGENT_ENTRIES.filter((entry) =>
  hasAnyLogin(entry.id),
).map((entry) => entry.id)

/**
 * Why this agent is not offered a second account.
 *
 * Always the agent's own sentence. The copy this replaced said "Separate
 * accounts are Claude-only for now" against every other provider, which was
 * wrong about Codex and was never an explanation for Gemini.
 */
export function loginsNote(id: ProviderId): string {
  return (
    AGENT_CATALOG[id]?.loginsNote ??
    'This agent signs in its own way, and nothing here has verified a way to keep two of its logins apart — so a session on it uses whichever login this machine already has.'
  )
}
