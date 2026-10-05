/**
 * What each coding agent can be made to keep, setting by setting — the one
 * table the task agents' launch, their brief and their settings page all read.
 *
 * ## Three answers, and what each one promises
 *
 *  - `enforced` — this app hands the setting to the agent's own program, which
 *    applies it whatever the brief says: a launch flag, a config override, or a
 *    command typed into the session whose reply is read back.
 *  - `advisory` — the setting is written into the agent's brief and nothing
 *    more. The agent may follow it; nothing makes it.
 *  - `unsupported` — this app has no honest way to apply it. The field is off
 *    in Settings, a saved value is refused, and a start that carries an enforced
 *    one is refused rather than run without it.
 *
 * The answer is about **this build**, not about the CLI in general. Where a CLI
 * has a mechanism this app does not use yet, the entry says so in `evidence`
 * and still answers `unsupported` — a label that said "enforced" for a flag
 * nobody passes would be the exact lie this table exists to stop.
 *
 * ## Where each line was checked
 *
 * Every entry names what was run or read, against which version. Claude Code
 * and Codex were read from their own `--help` on this Mac (read-only; no agent
 * was started). Codex's config keys were measured with `codex debug
 * prompt-input`, which renders the model-visible prompt without calling a
 * model, under an empty `CODEX_HOME` and `HOME` so nothing of the owner's was
 * read. The Gemini CLI is not installed here: its lines cite its documentation
 * and say they are unverified, which is why none of them is `enforced`.
 *
 * Types and data only, so the renderer reads the same table as the main
 * process.
 */

import { AGENT_CATALOG } from './agent-catalog'

/** The versions the entries below were checked against. */
export const CHECKED_AGAINST = {
  claude: 'Claude Code 2.1.289',
  codex: 'codex-cli 0.159.3',
  gemini: 'Gemini CLI — not installed on this Mac; its documentation only',
} as const

export type Support = 'enforced' | 'advisory' | 'unsupported'

/**
 * Every setting a task agent has that depends on which coding agent runs it.
 *
 * `toolAdvice` is the "prefer / avoid" lists. `mcpConfig` and `resumeById` have
 * no field of their own in Settings — they are how a session is given tools and
 * how a reply continues the same conversation — and are here so the matrix is
 * whole.
 */
export const AGENT_SETTINGS = [
  'model',
  'effort',
  'instructions',
  'toolAdvice',
  'blockedTools',
  'skillsOff',
  'skillSelection',
  'mcpConfig',
  'resumeById',
] as const

export type AgentSetting = (typeof AGENT_SETTINGS)[number]

/** One row: a coding agent's kind. A person's own added agent is `custom`. */
export type AgentFamily = 'claude' | 'codex' | 'gemini' | 'shell' | 'custom'

export const AGENT_FAMILIES: readonly AgentFamily[] = ['claude', 'codex', 'gemini', 'shell', 'custom']

export interface Capability {
  support: Support
  /** How this build applies it, in one plain sentence. Shown under the field. */
  how: string
  /** What was run or read to know this, with the version. */
  evidence: string
}

type Row = Record<AgentSetting, Capability>

const BRIEF = 'Written into the brief this agent is given. A request: nothing makes it follow it.'

const CLAUDE: Row = {
  model: {
    support: 'enforced',
    how: 'Set in the session right after it starts, the way a person types /model.',
    evidence:
      '`claude --help` (2.1.289): `--model <model>`. The typed /model command and its confirmations are measured in `main/agent-controls.ts`; a refusal is said on the task.',
  },
  effort: {
    support: 'enforced',
    how: 'Set in the session right after it starts, the way a person types /effort.',
    evidence: '`claude --help` (2.1.289): `--effort <level>`. /effort is measured in `main/agent-controls.ts`.',
  },
  instructions: {
    support: 'enforced',
    how: 'Claude Code is started with the file added to its own system prompt, and the brief repeats it.',
    evidence:
      '`--append-system-prompt-file <file>`: not printed by `--help` in 2.1.289, but named there under `--bare` ("--append-system-prompt[-file]"), present in the binary’s option table, and Hoot is launched with it (`main/copilot-layer.ts`).',
  },
  toolAdvice: {
    support: 'advisory',
    how: `${BRIEF} Claude Code’s own permission settings still decide.`,
    evidence: 'No flag prefers a tool. `--allowedTools` pre-approves, which is a permission, not a preference.',
  },
  blockedTools: {
    support: 'enforced',
    how: 'Claude Code refuses these tools itself.',
    evidence: '`claude --help` (2.1.289): `--disallowedTools <tools...>` "Comma or space-separated list of tool names to deny".',
  },
  skillsOff: {
    support: 'enforced',
    how: 'Claude Code starts with no skills at all.',
    evidence: '`claude --help` (2.1.289): `--disable-slash-commands` "Disable all skills".',
  },
  skillSelection: {
    support: 'advisory',
    how: `${BRIEF} Claude Code cannot be limited to only these.`,
    evidence:
      'Investigated for 2.1.289: no flag limits the skills to a chosen set. `--disable-slash-commands` switches off every skill, including those in a folder added for one run with `--add-dir`, so a per-run skills folder cannot be the only one on; a `Skill(name)` deny rule refuses one named skill, not the built-in ones or any added later.',
  },
  mcpConfig: {
    support: 'enforced',
    how: 'Given its MCP servers on the command line.',
    evidence: '`claude --help` (2.1.289): `--mcp-config <configs...>` and `--strict-mcp-config`; every session this app starts gets its own tools this way.',
  },
  resumeById: {
    support: 'enforced',
    how: 'A reply continues the exact conversation, by its id.',
    evidence: '`claude --help` (2.1.289): `-r, --resume [value]` "Resume a conversation by session ID".',
  },
}

const CODEX: Row = {
  model: {
    support: 'unsupported',
    how: 'Not set for Codex by this app yet: the model is changed by typing Claude Code’s command, which Codex does not take.',
    evidence: '`codex --help` (0.159.3): `-m, --model <MODEL>` exists at launch; this app does not pass it.',
  },
  effort: {
    support: 'unsupported',
    how: 'Not set for Codex by this app yet.',
    evidence: 'Codex 0.159.3 has a `model_reasoning_effort` config key (in its `-c` schema) with levels of its own; this app does not pass it.',
  },
  instructions: {
    support: 'enforced',
    how: 'Codex is started with the file’s text as its developer instructions, and the brief repeats it.',
    evidence:
      '`codex --help` (0.159.3): `-c, --config <key=value>`. Measured 2026-10-05 with an empty CODEX_HOME and HOME: `codex debug prompt-input -c developer_instructions="…"` put the text first in the developer message, and a `-c` before a subcommand reaches it. `model_instructions_file` is not used: it stands in for Codex’s own base instructions rather than adding to them.',
  },
  toolAdvice: {
    support: 'advisory',
    how: BRIEF,
    evidence: 'Codex has sandbox and approval modes, not a preferred-tool list.',
  },
  blockedTools: {
    support: 'unsupported',
    how: 'Codex cannot refuse a named tool, so an agent with blocked tools is not started on it.',
    evidence:
      '`codex --help` (0.159.3) offers `--sandbox` and `--ask-for-approval`, not a per-tool deny list. `mcp_servers.<name>.disabled_tools` switches off an MCP server’s tools only, never Codex’s own.',
  },
  skillsOff: {
    support: 'unsupported',
    how: 'Not offered for Codex: switching every skill off could not be proven.',
    evidence:
      'Measured on 0.159.3: `-c skills.include_instructions=false` drops the skills list from the prompt, but whether a skill can still be found by its skill search was not established, so it is not called "off".',
  },
  skillSelection: {
    support: 'advisory',
    how: `${BRIEF} Codex cannot be limited to only these.`,
    evidence:
      'Measured on 0.159.3: `-c skills.config=[{path=…,enabled=false}]` hides one skill by its file, so Codex can switch off skills that were found, never limit itself to a chosen set. Skills are read from `$CODEX_HOME/skills`, `~/.agents/skills` and the project’s `.agents/skills`.',
  },
  mcpConfig: {
    support: 'unsupported',
    how: 'This app does not hand Codex an MCP configuration; it uses its own.',
    evidence: 'Codex reads `[mcp_servers]` from its config.toml and takes `-c mcp_servers.<name>…` overrides; not passed by this app.',
  },
  resumeById: {
    support: 'enforced',
    how: 'A reply continues the exact conversation, by its id.',
    evidence: '`codex resume --help` (0.159.3): `[SESSION_ID]` "Session id (UUID) or session name".',
  },
}

const UNVERIFIED = 'Not installed on this Mac, so unverified here.'

const GEMINI: Row = {
  model: {
    support: 'unsupported',
    how: 'Not set for Gemini by this app.',
    evidence: `${UNVERIFIED} The Gemini CLI documents \`-m, --model\`; this app does not pass it.`,
  },
  effort: {
    support: 'unsupported',
    how: 'Gemini has no effort setting.',
    evidence: `${UNVERIFIED} No effort or reasoning-level option in the Gemini CLI documentation.`,
  },
  instructions: {
    support: 'advisory',
    how: `${BRIEF} Gemini has no way to add standing instructions at the start.`,
    evidence: `${UNVERIFIED} Its documented \`GEMINI_SYSTEM_MD\` replaces the whole system prompt instead of adding to it, so it is not used.`,
  },
  toolAdvice: { support: 'advisory', how: BRIEF, evidence: 'Nothing to check: the brief is plain text.' },
  blockedTools: {
    support: 'unsupported',
    how: 'Gemini cannot be started with tools refused, so an agent with blocked tools is not started on it.',
    evidence: `${UNVERIFIED} Gemini documents \`excludeTools\` in its settings file, not as a launch option.`,
  },
  skillsOff: {
    support: 'unsupported',
    how: 'Not offered for Gemini.',
    evidence: `${UNVERIFIED} No launch option that switches skills off.`,
  },
  skillSelection: { support: 'advisory', how: BRIEF, evidence: 'Nothing to check: the brief is plain text.' },
  mcpConfig: {
    support: 'unsupported',
    how: 'This app does not hand Gemini an MCP configuration.',
    evidence: `${UNVERIFIED} Gemini documents \`--allowed-mcp-server-names\`; not used.`,
  },
  resumeById: {
    support: 'unsupported',
    how: 'A reply after the session closed starts a new conversation.',
    evidence: 'Gemini documents `--resume`, but resuming into an empty history was never exercised (`shared/agent-catalog.ts`), so it is not used.',
  },
}

const NOTHING = 'A shell reads no brief and takes no agent settings.'

const SHELL: Row = Object.fromEntries(
  AGENT_SETTINGS.map((setting) => [setting, { support: 'unsupported', how: NOTHING, evidence: 'The platform’s own login shell.' }]),
) as Row

const ADDED = 'An agent added on this Mac is a command and fixed arguments; nothing is known about its options.'

const CUSTOM: Row = {
  model: { support: 'unsupported', how: 'Not set for an added agent.', evidence: ADDED },
  effort: { support: 'unsupported', how: 'Not set for an added agent.', evidence: ADDED },
  instructions: { support: 'advisory', how: BRIEF, evidence: ADDED },
  toolAdvice: { support: 'advisory', how: BRIEF, evidence: ADDED },
  blockedTools: { support: 'unsupported', how: 'An added agent cannot be started with tools refused.', evidence: ADDED },
  skillsOff: { support: 'unsupported', how: 'Not offered for an added agent.', evidence: ADDED },
  skillSelection: { support: 'advisory', how: BRIEF, evidence: ADDED },
  mcpConfig: { support: 'unsupported', how: 'Not handed to an added agent.', evidence: ADDED },
  resumeById: { support: 'unsupported', how: 'A reply after the session closed starts afresh.', evidence: ADDED },
}

export const CAPABILITIES: Readonly<Record<AgentFamily, Readonly<Row>>> = {
  claude: CLAUDE,
  codex: CODEX,
  gemini: GEMINI,
  shell: SHELL,
  custom: CUSTOM,
}

/**
 * The row a provider id reads. Null — "the app's default" — reads Claude
 * Code's, the default a fresh install has; {@link capabilityFor} narrows the one
 * setting where that is not safe to assume.
 */
export function familyOf(provider: string | null): AgentFamily {
  if (provider === null || provider === 'claude') return 'claude'
  if (provider === 'codex' || provider === 'gemini' || provider === 'shell') return provider
  return 'custom'
}

/**
 * What a task agent with this provider gets for one setting.
 *
 * For the app's default agent the answer is Claude Code's, with one exception:
 * standing instructions. A limit like a blocked tool is safe to promise for an
 * agent not known yet, because a start on an agent that cannot keep it is
 * refused. Instructions add rather than limit, so refusing a start over them
 * would stop work for nothing — with the agent unknown they go in the brief, and
 * are said to be advice.
 */
export function capabilityFor(provider: string | null, setting: AgentSetting): Capability {
  if (provider === null && setting === 'instructions') {
    return {
      support: 'advisory',
      how: `${BRIEF} Choose Claude Code or Codex to have them given at the start as standing instructions.`,
      evidence: 'Which agent the app default is cannot be known when the agent is saved.',
    }
  }
  return CAPABILITIES[familyOf(provider)][setting]
}

/** Is this setting applied by the agent's own program for this provider? */
export function enforces(provider: string | null, setting: AgentSetting): boolean {
  return capabilityFor(provider, setting).support === 'enforced'
}

/** The small label beside a field. */
export const SUPPORT_TAG: Readonly<Record<Support, string>> = {
  enforced: 'Enforced',
  advisory: 'Advice only',
  unsupported: 'Not available',
}

/** The agents that can keep an enforced setting, by name — for the sentence a refusal says. */
export function familiesEnforcing(setting: AgentSetting): AgentFamily[] {
  return AGENT_FAMILIES.filter((family) => CAPABILITIES[family][setting].support === 'enforced')
}

/** A provider as a sentence names it. */
export function agentLabel(provider: string | null): string {
  if (provider === null) return 'The app’s default coding agent'
  return (AGENT_CATALOG as Record<string, { label: string } | undefined>)[provider]?.label ?? 'An added agent'
}
