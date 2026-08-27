/**
 * Agents this build has never heard of, added by the person using it.
 *
 * ## What this is for
 *
 * `agent-catalog.ts` is the table of agents that were installed and launched on
 * a real machine before they were written down. It is long now, and it will
 * never be long enough — the brief asked for the other thing as well:
 *
 *   > *"There should be a plus button to add, with the big list of type of AI
 *   > agents to connect — not only Codex, not only Claude Code. There are so
 *   > many, Grok agents… Just take a look how many types of agents and setup
 *   > they have in Cursor and in Visual Studio Code… They should be able to
 *   > connect a huge number of type of agents."*
 *
 * Both halves of that are shipped, and they are different mechanisms. The
 * gallery is the catalogue: a known agent comes with the name it is called by,
 * the command that installs it, where to read about it, and — where it was
 * measured — resume, accounts and hooks. This file is the other half: a form
 * with a name and a command in it, for the agent that is not in the gallery
 * and never will be, because it was released last week or because it is a shell
 * script in somebody's home directory.
 *
 * ## The honest floor
 *
 * An agent this build has never seen cannot have a transcript parser, because a
 * transcript parser is a reader for one specific file format. It cannot have a
 * model picker, because that types one specific CLI's slash commands. It cannot
 * have isolated accounts, because that needs a configuration-directory variable
 * that somebody watched move a login. What it *can* have is the thing every
 * agent in this app actually is underneath:
 *
 *     run this command, with these arguments, in this folder, in a real pty,
 *     and show me what it prints.
 *
 * That is the floor, it is a complete product on its own — it is what a terminal
 * is — and everything above it degrades by *saying so* rather than by appearing
 * and doing nothing.
 *
 * There is no `capabilities` list saying which of them are off, and the absence
 * is deliberate rather than an omission. An earlier draft of this file returned
 * `capabilities: []` on every added agent and described it as the thing "every
 * screen that offers one of those features reads". No screen read it, because no
 * such field exists on {@link AgentEntry} — it was a list of withdrawn features
 * that withdrew nothing, which is the same defect as a feature that does not
 * work, wearing the costume of the fix for it. The withdrawal is already carried
 * by the fields the screens genuinely do read, and `customEntry` sets every one
 * of them: `statusArgs` and `statusFormat` null, so nothing probes it for a
 * login; `configEnv` null and `logins: 'unmeasured'`, so the Accounts screen
 * offers it no row; `versionArgs` null, so nothing claims to have proved it
 * runs; `install` and `url` null, so a missing one is reported with the command
 * rather than with an install line this build made up.
 *
 * ## Nothing fake, applied to a form
 *
 * The catalogue's rule has no exceptions — never declare an agent that has not
 * been launched — and a form that let somebody type any string into a picker
 * would drive straight through it: a row that dies on selection is the exact
 * bug this whole area was opened to fix. So the rule is enforced on the form
 * too, by the main process rather than by the person filling it in.
 * `addCustomAgent` resolves the command against the user's login PATH and
 * refuses the draft when it cannot find it, and the sentence it refuses with
 * quotes what the machine said. An agent that exists in the picker is an agent
 * whose command was found on this machine at the moment it was added.
 */

import type { CustomProviderId, ProviderId } from './types'
import type { AgentEntry } from './agent-catalog'

/**
 * The prefix, spelled once.
 *
 * `CustomProviderId` in `types.ts` is `` `custom:${string}` ``, so this string
 * and that type have to agree; they are three characters apart and there is no
 * compiler check that would catch a disagreement, which is why nothing else in
 * the codebase is allowed to write the literal. Everything tests through
 * `isCustomProviderId` and builds through `customAgentId`.
 */
export const CUSTOM_PROVIDER_PREFIX = 'custom:'

/** True when this id names an agent somebody added rather than one we ship. */
export function isCustomProviderId(value: unknown): value is CustomProviderId {
  return typeof value === 'string' && value.startsWith(CUSTOM_PROVIDER_PREFIX) && value.length > CUSTOM_PROVIDER_PREFIX.length
}

/**
 * One agent somebody added, as it is stored and as it crosses the bridge.
 *
 * Deliberately smaller than `AgentEntry`. Every field an `AgentEntry` has that
 * is not here — `configEnv`, `statusArgs`, `credentialFile`, `alternateBins`,
 * `versionArgs` — is a claim about how a specific CLI behaves, and a form
 * cannot establish any of them. They are filled in as null by `customEntry`
 * below, which is what makes the degradation honest rather than absent.
 */
export interface CustomAgent {
  id: CustomProviderId
  /** What it is called on screen. The person's own words. */
  label: string
  /** One line under the label in the picker. May be empty. */
  description: string
  /** A name to look up on PATH, or an absolute path. */
  command: string
  /** Arguments for a fresh session. */
  args: readonly string[]
  /**
   * Arguments that continue the last conversation in a folder, or empty.
   *
   * Empty is the default and the safe answer: a resume flag that turns out to
   * error in a folder with no history kills the tab with no explanation, which
   * is worse than not offering resume. The catalogue takes the same line about
   * Gemini for the same reason.
   */
  resumeArgs: readonly string[]
  /** When it was added, and where the command resolved at that moment. */
  addedAt: number
  /**
   * The absolute path the command resolved to when it was added.
   *
   * Kept as evidence rather than as a route: the spawn still goes through the
   * name, so an agent the person upgrades keeps working. What this is for is
   * the `verified` sentence — the catalogue requires every entry to say what
   * was run and what answered, and for an added agent the answer is this.
   */
  resolvedPath: string
}

/**
 * What the form collects, before anything has been parsed or checked.
 *
 * `args` and `resumeArgs` are the raw text out of two single-line fields rather
 * than arrays, because splitting a command line is exactly the step that has to
 * happen identically on both sides of the bridge — the form shows the person
 * what it parsed, the main process stores what it parsed, and if those two
 * disagreed the preview would be a lie. `splitArgs` is the one splitter.
 */
export interface CustomAgentDraft {
  label: string
  description: string
  command: string
  args: string
  resumeArgs: string
}

/**
 * Why an added agent is offered no account, in the sentence every screen shows.
 *
 * A constant rather than a literal inside {@link customEntry}, because two
 * screens need it and only one of them has an `AgentEntry` to read it from: the
 * New-session dialog asks `isolationNotice` for a *provider id* — the catalogue
 * it consults is the static one, which by definition cannot hold an agent this
 * machine added — so without a name to import it would answer null and the Login
 * row would offer an account picker for an agent nothing has measured. The
 * session would then run under whatever login the machine already has while the
 * dialog named a different one.
 *
 * Ignorance, not absence: it says nothing has been measured, which is true, and
 * not that there is no login, which would frequently be false.
 */
export const CUSTOM_LOGINS_NOTE =
  'You added this agent, so nothing here has measured how it stores a login or whether two of them can be kept apart. It runs under whatever login this machine already has.'

/** An empty form. */
export const EMPTY_DRAFT: CustomAgentDraft = {
  label: '',
  description: '',
  command: '',
  args: '',
  resumeArgs: '',
}

/** Which field a complaint belongs to, so the form can put it under the field. */
export type CustomAgentField = 'label' | 'description' | 'command' | 'args' | 'resumeArgs'

/** What is wrong with a draft, per field. Empty means nothing is. */
export type CustomAgentProblems = Partial<Record<CustomAgentField, string>>

/* ---------------------------------------------------------------- limits -- */

/** Long enough for "GitHub Copilot CLI", short enough to sit in a tab. */
export const MAX_LABEL = 40
export const MAX_DESCRIPTION = 120
export const MAX_COMMAND = 512
/** More than any real agent takes, and a bound on what gets written to disk. */
export const MAX_ARGS = 24

/**
 * A bare command name, as `agent-binaries.ts` already defines one.
 *
 * The same expression, deliberately: that module refuses to look up anything
 * that does not match, so a command this accepted and that refused would be an
 * agent that saved and then reported itself missing forever.
 */
const SAFE_BIN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

/**
 * Characters that mean something to a command processor.
 *
 * Rejected in the command and in every argument, and the reason is one specific
 * platform rather than general nervousness. On macOS and Linux this app hands
 * the command and its arguments to `node-pty` as a file and an argv array — no
 * shell is involved, and a `;` is just a semicolon. On Windows it cannot:
 * `CreateProcess` will not run the `.cmd` shim that npm installs, so
 * `providersFor` wraps the launch as `cmd.exe /c <command> <args…>` — and
 * inside that line every one of these characters is an instruction. A command
 * of `foo & del /q *` would be two commands there.
 *
 * ## The backslash used to be in this set, and it made the feature unusable
 *
 * The first version of this line read `` /[&|;<>^"'`$()%!\\\n\r\t]/ `` and
 * justified the backslash with "nothing in this repository runs on Windows, so
 * the rule is the one that needs no verification to be safe". The sentence was
 * already false when it was written — this repository ships a signed Windows
 * installer from the same tag as the dmg — and the rule it justified was not
 * safe, it was merely strict in a direction nobody here could feel. Every
 * absolute path on Windows contains backslashes, so `C:\Windows\System32\
 * cmd.exe` was refused by this expression, and the sentence the person got back
 * told them to "give the full path to it" — advice that cannot be followed on
 * the platform they are standing on. A Windows user could add an agent only by
 * bare name; a program not on PATH could not be added at all. That is a broken
 * feature, not a strict one, and it is how it was found: the fixture in
 * `host-core.agents.test.ts` that adds an agent so the rest of the file means
 * anything could not add one on the Windows CI runner.
 *
 * A backslash is **not** a metacharacter to the thing this set is guarding
 * against. `cmd.exe` reads `&`, `|`, `<`, `>`, `^`, `%`, `(`, `)` and `!` as
 * instructions; a backslash is an ordinary character to it, and a path
 * separator to everything downstream. The one place a backslash *is* special is
 * the argv→command-line conversion `CreateProcess` needs, and node-pty already
 * implements the standard rules for it — `argsToCommandLine` in
 * `windowsPtyAgent.js` doubles a run of backslashes before a quote and before a
 * closing quote it added itself, which is read out of the installed copy rather
 * than assumed. A quote cannot arrive here anyway: `"` and `'` stay in this set.
 *
 * What kept UNC paths out was never this expression either, and they are still
 * out. `\\server\share\tool.exe` matches neither {@link SAFE_BIN} nor
 * {@link isAbsoluteCommand}, so it lands on the "neither a plain command name
 * nor a full path" refusal — as does every relative path with a separator in
 * it. The shape rule is what does that work, and it does it on both platforms.
 */
const SHELL_META = /[&|;<>^"'`$()%!\n\r\t]/

/** Anything a terminal would read as an instruction rather than as text. */
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/

/**
 * Is this an absolute path this app is willing to launch?
 *
 * Both spellings, because the store is per machine and the shapes are
 * different: `/usr/local/bin/thing` and `C:\tools\thing.exe`. A UNC path
 * (`\\server\share`) answers false here and does not match {@link SAFE_BIN}
 * either, so it is refused as neither a name nor a path — which is the right
 * answer, because a launch off somebody else's file server is not a thing to
 * make one click away. That refusal used to come from a backslash ban inside
 * {@link SHELL_META}, which also refused every ordinary Windows path; the shape
 * rule here is what was actually doing the work worth keeping.
 */
function isAbsoluteCommand(command: string): boolean {
  return command.startsWith('/') || /^[A-Za-z]:[\\/]/.test(command)
}

/* --------------------------------------------------------------- parsing -- */

/**
 * Split a line of arguments the way a person expects it to split.
 *
 * Quote-aware, because `--system-prompt "answer in French"` is one argument and
 * splitting it on whitespace would send two. Deliberately *not* a shell parser:
 * there is no variable expansion, no globbing, no escaping beyond a quote pair,
 * and nothing here is ever handed to a shell — so implementing more of a shell
 * would mean implementing behaviour that has nowhere to happen.
 *
 * An unclosed quote yields the rest of the line as one argument rather than an
 * error. The form shows what was parsed, so the person can see that and fix it;
 * refusing to parse would leave the preview empty and say nothing about why.
 */
export function splitArgs(raw: string): string[] {
  const args: string[] = []
  let current = ''
  let quote: '"' | "'" | null = null
  let started = false

  for (const char of raw) {
    if (quote !== null) {
      if (char === quote) {
        quote = null
        continue
      }
      current += char
      continue
    }
    if (char === '"' || char === "'") {
      quote = char
      // A quote *starts* an argument even when what it encloses is empty, so
      // `--flag ""` sends an empty argument rather than dropping it.
      started = true
      continue
    }
    if (/\s/.test(char)) {
      if (started || current !== '') args.push(current)
      current = ''
      started = false
      continue
    }
    current += char
  }
  if (started || current !== '') args.push(current)
  return args
}

/** How the parsed arguments read back, so the form can show what it understood. */
export function describeArgs(args: readonly string[]): string {
  if (args.length === 0) return 'no arguments'
  return args.map((arg) => (arg.includes(' ') || arg === '' ? JSON.stringify(arg) : arg)).join(' ')
}

/**
 * The id for a new agent, derived from its name and never colliding.
 *
 * A slug rather than a counter, because the id is what a session carries in
 * `SessionMeta.provider` and what a restored session is matched by — so an id a
 * person can recognise in `state.json` is worth the eight lines. `taken` is
 * every id already in use; a clash appends `-2`, `-3` and so on rather than
 * silently overwriting, which is the failure mode of keying on the name.
 */
export function customAgentId(label: string, taken: readonly string[] = []): CustomProviderId {
  const slug =
    label
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 32) || 'agent'

  const used = new Set(taken)
  let candidate: CustomProviderId = `${CUSTOM_PROVIDER_PREFIX}${slug}`
  let suffix = 2
  while (used.has(candidate)) {
    candidate = `${CUSTOM_PROVIDER_PREFIX}${slug}-${suffix}`
    suffix += 1
  }
  return candidate
}

/* ------------------------------------------------------------ validation -- */

/**
 * What is wrong with this draft, field by field.
 *
 * Runs in the renderer so the form can complain while it is being typed in, and
 * again in the main process before anything is written, because a renderer is
 * not a place to enforce a rule that decides what gets executed. The two calls
 * are the same function on purpose: a form that accepted what the store then
 * rejected would be a form that loses somebody's work at the last click.
 *
 * `takenLabels` is every name already in use — builtin labels included. Two
 * agents called "Copilot" in one picker is not a duplicate-key bug, it is
 * worse: the rows are indistinguishable and one of them cannot do what the
 * other can.
 */
export function validateDraft(
  draft: CustomAgentDraft,
  takenLabels: readonly string[] = [],
): CustomAgentProblems {
  const problems: CustomAgentProblems = {}

  const label = draft.label.trim()
  if (label === '') {
    problems.label = 'Give it a name — this is what the picker and the tab will call it.'
  } else if (label.length > MAX_LABEL) {
    problems.label = `Keep the name under ${MAX_LABEL} characters.`
  } else if (CONTROL_CHARS.test(label)) {
    problems.label = 'The name cannot contain control characters.'
  } else if (takenLabels.some((taken) => taken.toLowerCase() === label.toLowerCase())) {
    problems.label = `There is already an agent called “${label}”. Two rows with one name cannot be told apart.`
  }

  if (draft.description.length > MAX_DESCRIPTION) {
    problems.description = `Keep the description under ${MAX_DESCRIPTION} characters.`
  } else if (CONTROL_CHARS.test(draft.description)) {
    problems.description = 'The description cannot contain control characters.'
  }

  const command = draft.command.trim()
  if (command === '') {
    problems.command = 'Name the command to run. A name on your PATH, or a full path to it.'
  } else if (command.length > MAX_COMMAND) {
    problems.command = `That is longer than ${MAX_COMMAND} characters.`
  } else if (SHELL_META.test(command) || CONTROL_CHARS.test(command) || /\s/.test(command)) {
    /*
     * One sentence for three refusals, because from where the person is sitting
     * they are one situation: what they typed is a command *line* and this
     * field takes a command. Saying which character offended would invite them
     * to remove it and try again with something that still will not work.
     */
    problems.command =
      'Just the program — no spaces, quotes, pipes or redirects. Put the rest in Arguments below, or point this at a wrapper script.'
  } else if (!SAFE_BIN.test(command) && !isAbsoluteCommand(command)) {
    problems.command =
      'That is neither a plain command name nor a full path. Use the name you would type in a terminal, or the whole path to the program.'
  }

  const args = splitArgs(draft.args)
  const resumeArgs = splitArgs(draft.resumeArgs)
  const argProblem = (list: readonly string[]): string | null => {
    if (list.length > MAX_ARGS) return `That is more than ${MAX_ARGS} arguments.`
    for (const arg of list) {
      if (CONTROL_CHARS.test(arg)) return 'Arguments cannot contain control characters.'
      if (SHELL_META.test(arg)) {
        // Backslashes are deliberately absent from this sentence and from the
        // set behind it. An argument on Windows is very often a path, and
        // refusing `--config C:\tools\agent.json` was the same defect as
        // refusing the command itself — see {@link SHELL_META}.
        return 'Arguments cannot contain shell characters like & | ; < > $ or %.'
      }
    }
    return null
  }
  const argsProblem = argProblem(args)
  if (argsProblem) problems.args = argsProblem
  const resumeProblem = argProblem(resumeArgs)
  if (resumeProblem) problems.resumeArgs = resumeProblem

  return problems
}

/** True when {@link validateDraft} found nothing. */
export function draftIsValid(problems: CustomAgentProblems): boolean {
  return Object.keys(problems).length === 0
}

/* -------------------------------------------------------- the catalogue view -- */

/**
 * A custom agent as the rest of the app already knows how to read one.
 *
 * The whole reason there is one `AgentEntry` shape rather than two lists is
 * here: the spawn table, the binary probe, the picker, the Setup rows and the
 * account machinery all read `AgentEntry`, so an added agent joins every one of
 * them by being converted once. What makes it *degrade* rather than pretend is
 * the nulls — and each of them is a decision:
 *
 *  - `install` / `url` — null, because we do not know where this came from.
 *    A picker row for a missing custom agent therefore says the command was not
 *    found and shows the command, which is the only actionable thing there is.
 *  - `alternateBins` — empty. The Codex fallback exists because a specific
 *    broken npm package was measured; there is nothing to measure here.
 *  - `versionArgs` — null, which `agent-binaries.ts` reads as "no way to prove
 *    it runs", so presence on PATH is all that is claimed. Guessing `--version`
 *    would be worse than not asking: a working agent without that flag would
 *    report itself broken and vanish from the picker.
 *  - `logins` — `unmeasured`, never `none`. The agent may well have a login;
 *    what is true is that nothing here has watched a configuration directory
 *    move one, and `none` would say the opposite. `hasAnyLogin` answers false
 *    for it, so no account row appears — but the sentence on the row explains
 *    ignorance rather than asserting absence.
 *  - `statusArgs` / `statusFormat` / `configEnv` / `credentialFile` /
 *    `signInArgs` — all null, which is what withdraws the sign-in probe, the
 *    account isolation and the credential check. There is no separate list of
 *    switched-off features; these fields *are* the list, and they are the ones
 *    the screens already read.
 *
 * There is deliberately no `custom: true` flag on the entry either. Whether an
 * agent was added here is answered by {@link isCustomProviderId} on its id,
 * which `types.ts` argues at length is the single place the prefix is spelled —
 * a second spelling of the same fact is a second thing to keep in step.
 */
export function customEntry(agent: CustomAgent): AgentEntry {
  return {
    id: agent.id,
    label: agent.label,
    description:
      agent.description.trim() !== ''
        ? agent.description.trim()
        : `Runs \`${agent.command}\` in the project folder.`,
    bin: agent.command,
    args: agent.args,
    resumeArgs: agent.resumeArgs,
    install: null,
    url: null,
    alternateBins: [],
    versionArgs: null,
    logins: 'unmeasured',
    configEnv: null,
    credentialFile: null,
    statusArgs: null,
    statusFormat: null,
    signInArgs: null,
    // Null for the same reason `signInArgs` is: nothing here has measured a way
    // to sign this added agent in or out, so neither command is claimed. With
    // `logins: 'unmeasured'` it grows no account row at all, so the note is never
    // read — but it is set rather than left to the accessor's generic fallback,
    // in the same spirit as `loginsNote` above.
    signOutArgs: null,
    signOutNote: CUSTOM_LOGINS_NOTE,
    loginsNote: CUSTOM_LOGINS_NOTE,
    verified: `Added by you. \`${agent.command}\` resolved to ${agent.resolvedPath} on this machine when it was added; nothing about it has been measured since.`,
  }
}

/**
 * Narrow one agent off the wire or off disk.
 *
 * Total, and it has to be: this parses a JSON file a person can open in a text
 * editor, and one bad entry must cost that entry rather than the whole list.
 * Everything is re-checked rather than trusted — including the command, because
 * the file is the one place a shell metacharacter could arrive without passing
 * through the form.
 */
export function parseCustomAgent(raw: unknown): CustomAgent | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (!isCustomProviderId(value.id)) return null

  const label = typeof value.label === 'string' ? value.label.trim() : ''
  const command = typeof value.command === 'string' ? value.command.trim() : ''
  const description = typeof value.description === 'string' ? value.description.trim() : ''
  const args = Array.isArray(value.args) ? value.args.filter((a): a is string => typeof a === 'string') : []
  const resumeArgs = Array.isArray(value.resumeArgs)
    ? value.resumeArgs.filter((a): a is string => typeof a === 'string')
    : []

  const problems = validateDraft({
    label,
    description,
    command,
    args: args.map((a) => JSON.stringify(a)).join(' '),
    resumeArgs: resumeArgs.map((a) => JSON.stringify(a)).join(' '),
  })
  // The label check is the one that cannot run here: uniqueness is a property of
  // the list, and the list is what is being parsed. `readAgents` de-duplicates.
  delete problems.label
  if (!draftIsValid(problems)) return null

  return {
    id: value.id,
    label,
    description,
    command,
    args,
    resumeArgs,
    addedAt: typeof value.addedAt === 'number' && Number.isFinite(value.addedAt) ? value.addedAt : 0,
    resolvedPath: typeof value.resolvedPath === 'string' ? value.resolvedPath : command,
  }
}

/** Narrow a whole list, dropping entries that no longer make sense. */
export function parseCustomAgents(raw: unknown): CustomAgent[] {
  if (!Array.isArray(raw)) return []
  const seen = new Set<string>()
  const agents: CustomAgent[] = []
  for (const item of raw) {
    const agent = parseCustomAgent(item)
    if (!agent || seen.has(agent.id)) continue
    seen.add(agent.id)
    agents.push(agent)
  }
  return agents
}

/** Narrow a draft off the bridge. Missing fields become empty, never undefined. */
export function parseDraft(raw: unknown): CustomAgentDraft {
  if (typeof raw !== 'object' || raw === null) return { ...EMPTY_DRAFT }
  const value = raw as Record<string, unknown>
  const text = (key: keyof CustomAgentDraft): string =>
    typeof value[key] === 'string' ? (value[key] as string) : ''
  return {
    label: text('label'),
    description: text('description'),
    command: text('command'),
    args: text('args'),
    resumeArgs: text('resumeArgs'),
  }
}

/**
 * Every agent this app can offer right now: what it ships with, then what you
 * added.
 *
 * Order is deliberate and not alphabetical. The builtins come first because
 * they are the ones with resume, accounts and — for Claude Code — everything
 * else; a person's own additions sit under them the way "Your agents" sits
 * under a gallery in every editor that does this. `agentEntry` below is the
 * lookup that goes with it.
 */
export function allAgentEntries(
  builtin: readonly AgentEntry[],
  custom: readonly CustomAgent[],
): readonly AgentEntry[] {
  return [...builtin, ...custom.map(customEntry)]
}

/** One entry by id, from either half, or undefined for a name nothing knows. */
export function agentEntry(
  id: ProviderId | string,
  entries: readonly AgentEntry[],
): AgentEntry | undefined {
  return entries.find((entry) => entry.id === id)
}
