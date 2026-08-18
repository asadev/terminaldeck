import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, resolve, sep } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'

/**
 * No shared screen names a specific AI tool, model or editor.
 *
 * ## The rule, in his words
 *
 * From the recorded review of 2026-08-17, said while looking at the copilot's
 * folder step but stated as a rule for the whole product:
 *
 *   > *"We are everywhere mentioning CLAUDE.md… if we mention Claude everywhere
 *   > then it will be specific to Claude, even the previous sections. You should
 *   > not mention in any settings or any pop-up a specific tool or LLM or
 *   > something, because they can use some other also. So we should not call
 *   > Claude. Maybe we can use some other keyword — we can give `.md` files or
 *   > MD files only or something else, whatever is the best word."*
 *
 * And again on the phone, about the sessions list:
 *
 *   > *"running in terminal or VS Code — we don't need to mention VS Code
 *   > because it's another one… but VS will be a specific thing."*
 *
 * So: **user-facing copy describes the category, not the vendor.** "Your
 * instructions file", not `CLAUDE.md`. "Your own terminal or editor", not
 * "Terminal or VS Code". This is the same class of rule as `BRAND.name` living
 * in one file — a name that leaks into prose is a name that has to be found
 * again in fifty places the next time it changes.
 *
 * ## Why it needs a test and not just a careful afternoon
 *
 * The sweep that produced this file found thirty-odd strings, and three of them
 * were not merely branded but **wrong**: a settings editor whose `aria-label`
 * announced `CLAUDE.md` while the file it edits is `instructions.md`, a
 * confirmation offering to keep a backup "as CLAUDE.md.bak" when the backup
 * written is `instructions.md.bak`, and a paragraph telling somebody a rule was
 * "written in its CLAUDE.md" when it is written into the layer file two blocks
 * above. Every one of those was defensible on the day it was typed and none of
 * them was caught by a compiler, a review or nine thousand tests, because a
 * string that is merely *untrue* type-checks perfectly.
 *
 * A vendor name in copy is therefore not only a style question. It is a claim
 * about a specific product's behaviour, made on a screen that may be showing a
 * different product entirely, and the way it decays is by being right when it
 * was written.
 *
 * ## This is not a ban on the word
 *
 * Three cases keep the name, and all three are the same case: **naming a thing
 * the person actually chose.**
 *
 *  1. **A row that *is* that agent.** The session card that says `Claude Code`
 *     under a Claude Code session, the catalogue entry for the Gemini CLI, the
 *     hooks row that writes `~/.gemini/settings.json`. Neutralising these would
 *     delete the only information on the row.
 *  2. **A quotation of a specific CLI.** `claude mcp add` in a `<code>` span, an
 *     error saying which binary could not be found, a paragraph about a feature
 *     that is one CLI's feature. Renaming a command makes it stop working.
 *  3. **A path.** `~/.claude/settings.json` is where a file is. A person told
 *     only that "some settings file" governs their prompts cannot go and change
 *     it, and renaming the directory in prose would send them to a place that
 *     does not exist.
 *
 * Code, identifiers, comments, ids and filenames are untouched. This is about
 * what a person reads.
 *
 * ## What counts as user-facing, mechanically
 *
 * Comments never appear — this walks the TypeScript AST, where a comment is not
 * a node — so the long explanations above every string in this codebase are free
 * to name whatever they need to. What is collected is:
 *
 *   - JSX text, unless it sits inside `<code>`, `<pre>` or `<kbd>`, which is
 *     case 2 above rendered as itself;
 *   - JSX attributes a person hears or reads: `title`, `placeholder`,
 *     `aria-label`, `alt`, and the copy props this codebase passes around;
 *   - object properties with those names, which is how the settings schema, the
 *     readiness checks and the widget catalogue carry their copy;
 *   - any string or template literal that reads like a sentence — three or more
 *     words. That last one is the net: it catches copy nobody thought to route
 *     through a named prop, which is most of it.
 *
 * Before matching, four shapes are cut out of the text, because they are not
 * prose even when they sit in the middle of it: URLs, paths, `SCREAMING_SNAKE`
 * environment variables, and spans inside backticks — which is how every
 * command in this codebase's prose is written.
 *
 * ## Three holes, closed on 2026-08-18
 *
 * A completeness audit of the 0.4.0 build found four vendor strings still live
 * on the two surfaces the review names — settings and pop-ups — with this file
 * green. Every one of them was a hole in the collector rather than a judgement
 * anybody had made, and all three holes were the same mistake in different
 * clothes: **the guard was reading something other than what a person reads.**
 *
 *  1. **Backticks sheltered anything at all.** `prosePartOf` deleted every
 *     backticked span before matching, so `` `CLAUDE.md` `` in the middle of a
 *     sentence was invisible. That was aimed at commands — case 2 — and it hit
 *     names as well. A span is now sheltered only when it holds no capitalised
 *     word, which is what tells `brew upgrade gemini-cli` (a thing you type)
 *     from `Claude Code` (a thing you say). See {@link shelters}.
 *
 *  2. **Nothing sheltered the two names he pointed at.** The stricter rule ran
 *     on the same stripped text as the loose one, so backticks and `<code>`
 *     hid `CLAUDE.md` from it too. It now reads the text with backticks
 *     *unwrapped* and reads the inside of `<code>` as well — paths still
 *     excepted, because `.vscode/*` in a `.gitignore` template is a location
 *     and not a sentence.
 *
 *  3. **A name composed at runtime was never a string.** `` `The copilot runs
 *     on ${PROVIDERS.claude.label}` `` holds no vendor name anywhere in the
 *     source. Template literals are now resolved: an interpolation of a string
 *     constant declared in the same file is substituted with its value, and one
 *     that cannot be resolved contributes the *property names* chosen off it —
 *     `claude` and `label` above — but never the root identifier, so ordinary
 *     variables cannot trip it.
 *
 * The fourth string the audit found is the one that proves where the line is,
 * and it is deliberately still invisible here: `Your own Claude Code install`
 * is composed from `AGENT_CATALOG[account.provider].label`, keyed by a value
 * only known at runtime. No scanner can see that, and none should — reading a
 * name out of the catalogue is the *correct* way to name an agent, and it is
 * what `AccountChip`'s Run button was changed to do on the same day. Where a
 * name is chosen at runtime, the neutrality of the screen is pinned by that
 * screen's own render test; `copilot-setup.test.tsx` carries that one.
 */

const ROOT = resolve(__dirname, '..')

/**
 * Every surface a person reads, on every platform this ships to.
 *
 * `src/main` is in the list and it is the one worth justifying: it looks like
 * back-end code and it is, but it is also where the readiness details, the MCP
 * errors, the cost warnings and the native dialogs are written. Two of the three
 * factually-wrong strings the sweep found were in here.
 */
const SURFACES = [
  'src/renderer',
  'src/shared',
  'src/main',
  'src/preload',
  'src/headless',
  'pwa/src',
  'ios/TerminalDeck',
] as const

/**
 * The one file in those directories that holds no copy at all.
 *
 * `copilot-instructions-history.ts` is every scaffold this app has ever written
 * into somebody's folder, kept verbatim so that an out-of-date file can be told
 * apart from a hand-edited one. The comparison is against **rendered bytes**, so
 * editing one of these strings changes the thing it exists to recognise and
 * quietly reclassifies somebody's untouched file as "yours, never overwrite" —
 * its own header says nothing in it should ever be tidied up. It is dead text
 * that is never rendered and never read, and the honest way to hold it to a copy
 * rule is not to hold it to one.
 *
 * This is a list of one on purpose. A module skipped here is a module where a
 * bad string cannot be caught at all, which is a much larger hole than an
 * exemption in {@link ABOUT_A_NAMED_AGENT} — those still fail on anything the
 * scanner has not seen before.
 */
const NOT_COPY_AT_ALL = new Set(['src/main/copilot-instructions-history.ts'])

/**
 * The names, and the ones deliberately left out.
 *
 * `Copilot` is absent because it is **this product's own word** for its
 * assistant — the review uses it on every page — and it is a common noun here,
 * not GitHub's product.
 *
 * `Cursor` is absent for the opposite reason: the editor shares its name with
 * the caret, and the only occurrences in this tree are "an unusable cursor" and
 * "the server repeated a cursor". A rule that fires on those teaches people to
 * add exemptions, which is how a guard stops guarding.
 *
 * `JetBrains` is present, but `JetBrains Mono` is cut out first — it is the
 * monospace font three terminals ask for by name, and a font family is not an
 * IDE.
 */
const VENDORS =
  /\b(claude|anthropic|gemini|codex|openai|chatgpt|vs ?code|vscode|visual studio|jetbrains|intellij)\b/i

/**
 * The two he named out loud, banned everywhere with no module exemption.
 *
 * These are the exact strings the review pointed at, so they get the stricter
 * rule: a module being "about Claude Code" is not a licence to tell somebody to
 * go and edit their CLAUDE.md, because the whole complaint was that the phrase
 * had spread into copy where any agent could be meant. The only way past this
 * one is {@link DISCLOSED_FILENAMES}, which is three strings long and each of
 * them is disclosing a file that is about to appear on somebody's disk.
 */
const NAMED_IN_THE_REVIEW = /\bCLAUDE\.md\b|\bGEMINI\.md\b|\bVS ?Code\b|\bVisual Studio Code\b/i

/**
 * Where a filename may still be spelled out, and why each one earns it.
 *
 * Exact strings rather than files: an exemption that covered `readiness.ts`
 * would let the *next* sentence in it name a filename too, and the point of the
 * hard rule is that nothing new gets in.
 */
const DISCLOSED_FILENAMES: ReadonlyArray<{ text: string; because: string }> = [
  {
    text: 'The file is CLAUDE.md.',
    because:
      'Said in the description of a fix that is about to create a file, immediately before somebody presses ' +
      'the button. What lands in their repository is a fact about their filesystem and they are entitled to ' +
      'it; the button itself says "Create instructions file".',
  },
  {
    text: '# CLAUDE.md',
    because:
      'The first line of the file that fix writes, not a line of this app. A Markdown document titling ' +
      'itself with its own filename is the convention every one of these files follows, and it is read in ' +
      'an editor rather than in this app.',
  },
]

/**
 * Modules whose subject genuinely is one named agent.
 *
 * Every entry says which of the three allowed cases it is and why the sentence
 * would be worse without the name. A module goes on this list only when
 * neutralising it would delete information or make a claim untrue — never
 * because the rewrite was awkward.
 *
 * The list is asserted to be exactly used, in both directions: an entry that
 * stops matching anything fails the suite rather than sitting here forever
 * describing a string somebody deleted two releases ago, and — since
 * 2026-08-18 — a *new* vendor name in an exempted module fails too.
 *
 * That second half is the whole of hole 2. `because` is one sentence about a
 * module; `allows` is the copy that sentence was written about, exactly as the
 * collector reads it. Before this existed, "this module is about Codex" was a
 * standing licence for anything anybody added to it afterwards, and twenty-three
 * modules held one. Now the licence covers the strings it was granted for and
 * nothing else, so a new leak in the most-exempted file in the tree still fails
 * this suite — which is the property the guard is supposed to have.
 *
 * Keeping `allows` up to date is meant to be a small, deliberate act: run the
 * suite, read the string it prints, and either neutralise it or paste it in.
 */
const ABOUT_A_NAMED_AGENT: ReadonlyArray<{
  file: string
  because: string
  /** The exact strings in that file the exemption covers, trimmed as collected. */
  allows: readonly string[]
}> = [
  {
    file: 'src/shared/agent-catalog.ts',
    because:
      'The catalogue itself. Every string is one agent’s row — its label, its one-line description, its ' +
      'install command, and the `verified` note recording what was run on a real machine and what it ' +
      'answered. This is case 1 in its purest form: the row is the agent.',
    allows: [
      'Claude Code',
      'Anthropic\'s agentic CLI. Writes transcripts, so token and context tracking work.',
      'Codex CLI',
      'OpenAI\'s coding agent. Sign in with a ChatGPT account.',
      '`~/.codex/plugins/.plugin-appserver/codex --version` → codex-cli 0.146.0-alpha.3.1, and `login status` → "Logged in using ChatGPT" while a fresh CODEX_HOME answers "Not logged in". The npm launcher on PATH exits 1 with a spawn ENOENT for its own vendored binary, which is why `alternateBins` is not empty.',
      'Gemini CLI',
      'Gemini keeps one login per machine, in a keychain entry that is the same for every configuration directory — so a second Gemini account here would replace the first rather than sit beside it. The one login below is the machine’s, and signing in from it signs Gemini in everywhere.',
    ],
  },
  {
    file: 'src/main/prerequisites.ts',
    because: 'Setup rows derived from the catalogue, one per agent. "Run Codex sessions" is that agent’s row.',
    allows: [
      'Run Claude Code sessions',
      'Run OpenAI Codex sessions',
      'Run Gemini CLI sessions',
    ],
  },
  {
    file: 'src/main/hooks.ts',
    because:
      '`HOOK_PROVIDERS`: one entry per agent, each naming its own settings file, its own event names and — ' +
      'for Codex — the config key that has to be set before it runs hooks at all. Neutralising the ' +
      'requirement line would leave a row that silently does nothing.',
    allows: [
      'Claude Code',
      'Codex CLI',
      'Codex only runs hooks with `codex_hooks = true` under [features] in ~/.codex/config.toml.',
      'Gemini CLI',
    ],
  },
  {
    file: 'src/renderer/settings/settings-schema.ts',
    because: 'Per-agent option labels in the settings schema, the same three names the catalogue declares.',
    allows: [
      'Claude Code',
      'Codex CLI',
      'Gemini CLI',
    ],
  },
  {
    file: 'src/main/gemini-signin.ts',
    because:
      'The Gemini sign-in flow. It exists because that CLI has no login subcommand and has to be driven ' +
      'through a session; every sentence in it is about that one CLI’s behaviour.',
    allows: [
      'Gemini API key',
      'Not signed in. Press Sign in and Gemini opens in a session, where it asks which Google account to use.',
    ],
  },
  {
    file: 'src/main/codex-usage.ts',
    because:
      'Reads the rollout files one named CLI writes, and nothing else. Its diagnostic prefix names that ' +
      'reader so a line in the console can be traced to the module that produced it.',
    allows: [
      '[codex-usage] could not read rollouts:',
    ],
  },
  {
    file: 'src/main/plan-limit.ts',
    because:
      'Parses the plan-limit line one CLI prints. The message says which CLI has not printed one yet, ' +
      'which is the difference between "nothing to show" and "something is broken".',
    allows: [
      'Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run.',
    ],
  },
  {
    file: 'src/main/usage-ipc.ts',
    because:
      'Answers "why is there no usage for this session" per agent, because the two agents record it at ' +
      'different moments — one near a limit, one when a turn completes.',
    allows: [
      'No usage has been reported for this session yet. Claude Code prints its limits only near one, or when /usage is run; Codex records them when a turn completes.',
      'Codex has not recorded a rate limit under this account yet — it writes one into its rollout when a turn completes.',
    ],
  },
  {
    file: 'src/renderer/shell/usage-bar-model.ts',
    because:
      'Captions naming which source a number came from — one CLI’s /usage panel, its limit warning, or ' +
      'the other’s rollout. The caption is the provenance.',
    allows: [
      'Read from Claude Code’s own /usage panel.',
      'Read from a limit warning Claude Code printed in this session.',
      'Read from the rollout Codex writes as it works — no need to ask it.',
    ],
  },
  {
    file: 'src/renderer/shell/UsageBar.tsx',
    because:
      'Describes an automation that types /usage and reads the panel that one CLI draws. It is that CLI’s ' +
      'command and that CLI’s panel.',
    allows: [
      'Read from Claude Code’s own /usage panel. This checks by itself whenever the session goes quiet, so there is nothing to press.',
    ],
  },
  {
    file: 'src/renderer/chat/usage/usage-model.ts',
    because: 'The same automation’s refusals, naming the prompt it looked for and did not find.',
    allows: [
      'No empty Claude Code prompt on screen — clear the prompt, or check this session is running Claude Code.',
      'Claude Code did not show its usage panel.',
      'Claude Code’s usage panel shows no plan limits for this account, so there is nothing to read.',
      'Claude Code’s usage panel was opened to read this and did not close — press Esc in the session.',
    ],
  },
  {
    file: 'src/renderer/chat/controls/catalog.ts',
    because:
      'The model, effort, fast and permission controls type one CLI’s slash commands into the pty. ' +
      '`unsupportedProviderNote` withdraws the whole panel for the other agents and says so in as many ' +
      'words, so nothing here is ever drawn where a different agent could be meant.',
    allows: [
      'Claude judges each call and blocks risky ones',
      'These work by typing Claude Code’s own commands into the session.  …  has its own, and this build has not been shown what they are — so nothing is offered here rather than a button that types the wrong thing.',
      'from Claude settings',
      'Claude prints the permission mode only when it changes, and no default is set in your Claude settings — so this session has not said which one it is in. Pick one and it will.',
    ],
  },
  {
    file: 'src/main/agent-controls.ts',
    because:
      'The authoritative refusal behind those controls. It quotes the slash commands it would have typed ' +
      'and says nothing on the session’s screen showed that CLI is the one running in it — a refusal that ' +
      'named no CLI would be indistinguishable from a bug.',
    allows: [
      'Nothing on this session’s screen says Claude Code is running in it, and these controls are Claude Code’s commands.',
      'These type Claude Code’s own commands into the session. How  …  changes this at runtime has not been established, so nothing is sent rather than something being guessed at.',
    ],
  },
  {
    file: 'src/main/mcp-add.ts',
    because:
      'Shells out to `claude mcp add` rather than writing another application’s live 70 KB config itself — ' +
      'the file header carries the argument. An error saying which binary is missing is case 2.',
    allows: [
      'Claude Code’s command line tool could not be found, and it is what writes this configuration. Install it, then try again.',
    ],
  },
  {
    file: 'src/main/mcp-client.ts',
    because:
      'Reads that same configuration and reports what it found in it — including the servers one CLI dials ' +
      'itself, which this panel cannot inspect, and the ones a project has declined. Both facts are about ' +
      'that CLI’s behaviour and mean nothing without its name.',
    allows: [
      'Claude Code dials  …  servers itself, so this panel cannot inspect it.',
      'Rejected for this project in Claude Code.',
    ],
  },
  {
    file: 'src/renderer/components/McpAddForm.tsx',
    because:
      'The form over that command. "Stays inactive until Claude Code asks you to approve it" is measured ' +
      'behaviour of the tool that owns the file; without it a working safeguard reads as a failed add.',
    allows: [
      'Stays inactive until Claude Code asks you to approve it.',
      'Where Claude Code connects.',
    ],
  },
  {
    file: 'src/renderer/components/McpInspector.tsx',
    because:
      'Shows that configuration on screen and says whose it is, because removing a server genuinely cannot ' +
      'be done from this window and a panel that stays quiet about what it cannot do reads as broken ' +
      'rather than as limited.',
    allows: [
      'From your Claude Code configuration. To remove one, run',
    ],
  },
  {
    file: 'src/renderer/components/HelpPanel.tsx',
    because:
      'The help page whose subject is installing and signing into the agent CLIs. Its first topic is called ' +
      '"Install an agent CLI" — the category — and it then names all three and gives the real commands, ' +
      'because a help page that will not say which thing to install is not help.',
    allows: [
      '{app} does not talk to any model API itself. It runs the agent CLI you already use — Claude Code, Codex or Gemini CLI — inside a real terminal, and puts a workspace around it. So the first step is having at least one of them installed and working in your own shell.',
      'which claude && claude --version',
      'Agent CLIs almost never live in that minimal set. Claude Code’s own installer puts it in `~/.local/bin`, Homebrew uses `/opt/homebrew/bin`, and an npm install through nvm puts it under `~/.nvm`. All three are invisible to a GUI app by default.',
      'In a terminal, run `which claude` (or codex, or gemini). If that fails too, it is genuinely not installed.',
      'There is no reliable, free way to ask an agent CLI whether it is signed in, so the app only claims that state where it can check something cheap. For Claude Code that is the credentials file or the login keychain entry:',
    ],
  },
  {
    file: 'src/renderer/settings/sections/AccountsSection.tsx',
    because:
      'States which agents can hold more than one login and which cannot. That is a per-agent fact, it was ' +
      'measured, and it is the reason a row is or is not offered.',
    allows: [
      'Claude and Codex can hold several; Gemini keeps one per machine.',
    ],
  },
  {
    file: 'src/renderer/settings/sections/AgentsSection.tsx',
    because:
      'Says a setting applies to one agent and that the others ignore it. Naming the limit is the honest ' +
      'form; the alternative is a control that quietly does nothing for two thirds of people.',
    allows: [
      'Claude Code only. Other agents ignore this and use whichever login they already have on this machine.',
    ],
  },
  {
    file: 'src/main/voice.ts',
    because:
      'Three transcription providers, each a row the person picks between, and each row genuinely is that ' +
      'company — the label sits beside that provider’s own endpoint, its own auth header and the URL where ' +
      'they fetch its key. Neutralising the labels would leave three unnamed rows asking for a key that only ' +
      'one of three companies will accept, which is not vendor-neutrality, it is a guessing game. The rule ' +
      'bans naming a vendor while describing a mechanism any vendor could serve; naming the vendor you are ' +
      'choosing is the opposite of that.',
    allows: [
      'OpenAI',
    ],
  },
  {
    file: 'src/main/copilot-session.ts',
    because:
      'Refuses to start the copilot when the CLI it runs on is absent, and names it. This is case 2: the ' +
      'refusal is actionable only if it says which thing to install, and a message that would not name it ' +
      'is indistinguishable from the app being broken. Invisible here until template literals were ' +
      'resolved, because the name arrives through the catalogue at runtime.',
    allows: [
      'The copilot runs on  claude label , which is not installed on this machine.',
    ],
  },
]

/* --------------------------------------------------------------- collecting -- */

/** JSX props and object keys that carry words a person reads. */
const COPY_KEYS = new Set([
  'title',
  'placeholder',
  'aria-label',
  'alt',
  'label',
  'description',
  'hint',
  'note',
  'message',
  'detail',
  'help',
  'summary',
  'tooltip',
  'caption',
  'subtitle',
  'heading',
  'confirmLabel',
  'emptyText',
  'because',
  'reason',
  'warning',
  'requirement',
  'purpose',
  'prompt',
  'why',
])

/**
 * Elements whose children are a quotation rather than prose.
 *
 * `<code>claude mcp add</code>` is the command, rendered as the command. This is
 * the one place the rule would otherwise force a lie.
 *
 * Their text is still *collected*, tagged {@link Found.quoted}, rather than
 * thrown away at the door as it used to be. The loose vendor rule skips it —
 * that is what quoting is for — but the strict one reads it, so a `<code>` span
 * cannot become the place somebody parks `CLAUDE.md`. Nothing in the tree does
 * today; the point is that nothing can start to.
 */
const QUOTING_ELEMENTS = new Set(['code', 'pre', 'kbd', 'samp'])

interface Found {
  file: string
  line: number
  text: string
  /** Inside `<code>` and friends: a quotation, exempt from the vendor rule only. */
  quoted: boolean
}

/**
 * Every `const NAME = 'literal'` in one file, including object literals, keyed
 * by the dotted path an interpolation would write.
 *
 * Half of hole 3. A sentence assembled at runtime is still a sentence a person
 * reads, and the cheapest form of that — a name in a constant, dropped into a
 * template two lines below — was invisible to every version of this file before
 * today. Resolution is deliberately confined to *this* file: a value imported
 * from somewhere else cannot be proved to be a name without type-checking the
 * program, and a guard that guesses is a guard that gets exempted.
 *
 * `as const` and parentheses are unwrapped on the way in, because that is how
 * most of the string tables in this codebase are declared.
 */
function constantsOf(sf: ts.SourceFile): Map<string, string> {
  const constants = new Map<string, string>()

  const record = (path: string, node: ts.Expression): void => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      constants.set(path, node.text)
      return
    }
    if (ts.isAsExpression(node) || ts.isParenthesizedExpression(node)) {
      record(path, node.expression)
      return
    }
    if (!ts.isObjectLiteralExpression(node)) return
    for (const property of node.properties) {
      if (!ts.isPropertyAssignment(property)) continue
      const key =
        ts.isIdentifier(property.name) || ts.isStringLiteral(property.name)
          ? property.name.text
          : null
      if (key !== null) record(`${path}.${key}`, property.initializer)
    }
  }

  const visit = (node: ts.Node): void => {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      record(node.name.text, node.initializer)
    }
    ts.forEachChild(node, visit)
  }
  visit(sf)
  return constants
}

/**
 * What one `${…}` puts into the sentence, as far as it can be proved.
 *
 * The other half of hole 3, and the half that decides whether this is a guard
 * or a nuisance. Three answers:
 *
 *  - the **property names** it reaches through — `claude` and `label` in
 *    `PROVIDERS.claude.label`. Choosing a vendor's key off a table is choosing
 *    that vendor's value, so the key is the leak, and reading it needs no type
 *    information and no import graph;
 *  - **and** the value, where the path resolves to a string constant declared
 *    in this same file. This is the leak the audit described, written the way
 *    somebody would actually write it: a name in a constant, dropped into a
 *    template two lines below;
 *  - nothing but an ellipsis for anything else — a call, an arithmetic
 *    expression, a bare local — which matches nothing.
 *
 * The root identifier is never contributed, and that omission is the whole
 * reason this produces no false positives: `${claudeAccounts.length}` names a
 * local variable, which the rule at the top of this file says is not something
 * a person reads. `${PROVIDERS.claude.label}` names a *key*, which is.
 */
function resolvedSpan(expression: ts.Expression, constants: Map<string, string>): string {
  const keys: Array<string | null> = []
  let node: ts.Expression = expression
  for (;;) {
    if (ts.isNonNullExpression(node) || ts.isParenthesizedExpression(node)) {
      node = node.expression
    } else if (ts.isPropertyAccessExpression(node)) {
      keys.unshift(node.name.text)
      node = node.expression
    } else if (ts.isElementAccessExpression(node)) {
      const argument = node.argumentExpression
      keys.unshift(ts.isStringLiteral(argument) ? argument.text : null)
      node = node.expression
    } else break
  }

  const resolved =
    ts.isIdentifier(node) && !keys.includes(null)
      ? constants.get([node.text, ...keys].join('.'))
      : undefined
  const named = keys.filter((key): key is string => key !== null)
  const parts = [resolved, named.length > 0 ? named.join(' ') : undefined].filter(
    (part): part is string => part !== undefined,
  )
  return parts.length > 0 ? ` ${parts.join(' ')} ` : ' … '
}

/**
 * Whether a backticked span is a thing somebody types rather than a thing
 * somebody says.
 *
 * This is the whole of hole 1's fix and it is one line, so it is worth being
 * explicit about what it decides. A backticked span in this codebase's prose is
 * how a command, a path, a config key or an identifier is written — case 2 and
 * case 3 above, rendered inline — and those genuinely have to keep their names:
 * renaming `brew upgrade gemini-cli` makes it stop working, and `~/.gemini`
 * is a place. Deleting the span before matching was a rough way of saying so,
 * and it also deleted `` `CLAUDE.md` `` and would have deleted `` `Claude
 * Code` ``, which are names in the middle of a sentence wearing a typeface.
 *
 * What tells the two apart, across all 173 backticked spans in this tree's
 * copy, is capitalisation. A command line is lower-case, or punctuated, or
 * both: `which claude`, `npm install -g @google/gemini-cli@latest`,
 * `codex_hooks = true`, `~/.codex/plugins/…`, `security.auth.selectedType`. A
 * product's name is a capitalised word with nothing but letters in it. So a
 * span shelters its contents only when no token in it is a capitalised word —
 * which lets every real command and path through untouched, and lets nothing
 * that reads as a name through at all.
 *
 * Two things this deliberately does not catch, both handled elsewhere: an
 * ALL-CAPS filename like `` `CLAUDE.md` `` is not a capitalised word by this
 * test, and it is caught by the stricter rule that reads through backticks
 * entirely; and a lower-case binary name — `` `claude` `` alone — is sheltered,
 * because at that point it *is* the command.
 */
function shelters(span: string): boolean {
  return !span
    .trim()
    .split(/\s+/)
    .some((token) => /^[A-Z][a-z]/.test(token) && /^[A-Za-z]+$/.test(token))
}

/**
 * Cut out the shapes that are not prose, so what is left can be matched
 * honestly.
 *
 * Order matters: backticked spans go first because they wrap commands that
 * contain paths, and a path stripped out of a span would leave its backticks
 * behind to swallow the wrong range.
 *
 * `backticks` is which of the two rules is asking. The loose vendor rule lets a
 * span shelter what it quotes, because a command that cannot say its own name
 * is a command that does not run. The strict rule — the two names the review
 * pointed at — unwraps every span instead, because "do not print CLAUDE.md on
 * my screen" is not a request that stops applying when the name is set in a
 * monospace font. Paths are still cut in both modes, which is what keeps the
 * `.gitignore` template this app writes — `.vscode/*` and all — out of it.
 */
function prosePartOf(text: string, backticks: 'shelter' | 'unwrap' = 'shelter'): string {
  return (
    text
      .replace(/`([^`]*)`/g, (_whole, span: string) =>
        backticks === 'unwrap' || !shelters(span) ? ` ${span} ` : ' ',
      )
      .replace(/https?:\/\/\S+/g, ' ')
      .replace(/JetBrains Mono/g, ' ')
      /*
       * A path or a package spec, and only where one can actually begin.
       *
       * The first version of this matched any token containing a slash, which
       * was a hole rather than a shortcut: "Claude/Codex sessions" is a token
       * containing a slash, so a sentence naming two vendors with an oblique
       * between them would have been cut out whole and passed. Requiring the
       * token to *start* with `~`, `.`, `/`, `\` or `@`, at a word boundary,
       * covers every real case — `~/.claude/settings.json`, `.claude/CLAUDE.md`,
       * `/opt/homebrew/bin`, `@anthropic-ai/claude-code`, `.vscode/*` — and
       * leaves prose alone, because a sentence never starts a word that way.
       *
       * The optional `!` is for the one path in this tree that is written as a
       * gitignore negation: `!.vscode/extensions.json`, in the template the
       * readiness fix writes. Still a path, still not a sentence.
       */
      .replace(/(?<=^|[\s(])!?[~./@\\][^\s)]*/g, ' ')
      .replace(/\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/g, ' ')
  )
}

/** Three words or more, at least one of them lettered. A sentence, not an id. */
function readsLikeASentence(text: string): boolean {
  return text.trim().split(/\s+/).filter((word) => /[A-Za-z]/.test(word)).length >= 3
}

function sourceFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === 'dist' || entry === '.build') continue
    const path = join(dir, entry)
    if (statSync(path).isDirectory()) sourceFiles(path, out)
    else if (/\.(ts|tsx|swift)$/.test(entry) && !/\.test\.tsx?$/.test(entry)) out.push(path)
  }
  return out
}

function collectFromTypeScript(file: string, rel: string, found: Found[]): void {
  const source = readFileSync(file, 'utf8')
  const sf = ts.createSourceFile(
    file,
    source,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  )
  const constants = constantsOf(sf)
  const take = (text: string, node: ts.Node, quoted = false): void => {
    found.push({
      file: rel,
      line: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1,
      text,
      quoted,
    })
  }

  const visit = (node: ts.Node): void => {
    if (ts.isJsxText(node)) {
      const parent = node.parent
      const tag =
        ts.isJsxElement(parent) ? parent.openingElement.tagName.getText(sf) : ''
      if (node.text.trim()) take(node.text, node, QUOTING_ELEMENTS.has(tag))
    } else if (ts.isJsxAttribute(node) && node.initializer) {
      if (COPY_KEYS.has(node.name.getText(sf))) {
        const init = node.initializer
        const literal = ts.isStringLiteral(init)
          ? init
          : ts.isJsxExpression(init) &&
              init.expression &&
              (ts.isStringLiteral(init.expression) ||
                ts.isNoSubstitutionTemplateLiteral(init.expression))
            ? init.expression
            : null
        if (literal) take(literal.text, node)
      }
    } else if (ts.isPropertyAssignment(node)) {
      const key =
        ts.isIdentifier(node.name) || ts.isStringLiteral(node.name) ? node.name.text : null
      const value = node.initializer
      if (
        key !== null &&
        COPY_KEYS.has(key) &&
        (ts.isStringLiteral(value) || ts.isNoSubstitutionTemplateLiteral(value))
      ) {
        take(value.text, node)
      }
    }

    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      if (readsLikeASentence(node.text)) take(node.text, node)
    } else if (ts.isTemplateExpression(node)) {
      // Assembled in order, with each `${…}` replaced by as much of its value
      // as can be proved — see `resolvedSpan`. Joined with nothing between the
      // pieces, because that is what the runtime does, and a name is often
      // welded to the words on either side of it.
      const parts = [node.head.text]
      for (const span of node.templateSpans) {
        parts.push(resolvedSpan(span.expression, constants), span.literal.text)
      }
      const sentence = parts.join('')
      if (readsLikeASentence(sentence)) take(sentence, node)
    }

    ts.forEachChild(node, visit)
  }
  visit(sf)
}

/**
 * Swift has no AST here, so comments are stripped by hand before the literals
 * are read. Both forms: `//` to end of line, and `/* … *\/` across lines — the
 * doc comments in `ios/` are the second kind and they quote the review at
 * length, which is exactly the text this must not read.
 */
function collectFromSwift(file: string, rel: string, found: Found[]): void {
  const stripped = readFileSync(file, 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, ' '))
    .replace(/\/\/[^\n]*/g, '')
  stripped.split('\n').forEach((line, index) => {
    for (const match of line.matchAll(/"([^"\\]*(?:\\.[^"\\]*)*)"/g)) {
      if (readsLikeASentence(match[1])) {
        found.push({ file: rel, line: index + 1, text: match[1], quoted: false })
      }
    }
  })
}

/** Everything a person reads, across every surface, with comments gone. */
function userFacingStrings(): Found[] {
  const found: Found[] = []
  for (const surface of SURFACES) {
    for (const file of sourceFiles(join(ROOT, surface))) {
      const rel = relative(ROOT, file).split(sep).join('/')
      if (NOT_COPY_AT_ALL.has(rel)) continue
      if (file.endsWith('.swift')) collectFromSwift(file, rel, found)
      else collectFromTypeScript(file, rel, found)
    }
  }
  return found
}

const STRINGS = userFacingStrings()
const show = (item: Found): string => `${item.file}:${item.line}  ${item.text.trim().slice(0, 160)}`

/**
 * Every collected string that still names a vendor once the quotations, the
 * paths and the three disclosures are out of it.
 *
 * One function rather than the same filter written four times, because the four
 * assertions below are four questions about *this* list and they must not be
 * able to disagree about what is on it.
 */
function vendorStrings(): Found[] {
  return STRINGS.filter(
    (item) => !item.quoted && VENDORS.test(prosePartOf(withoutDisclosures(item.text))),
  )
}

/**
 * A string carrying one of the three disclosures, and nothing else vendorish.
 *
 * The disclosure is *cut out* before matching rather than the whole string being
 * waved through, which is the difference that matters: the readiness fail detail
 * may list the three filenames it accepts, and it still cannot go on to mention
 * Claude Code in the next clause.
 */
function withoutDisclosures(text: string): string {
  let rest = text
  for (const entry of DISCLOSED_FILENAMES) rest = rest.split(entry.text).join(' ')
  return rest
}

describe('no shared UI names a specific AI tool, model or editor', () => {
  it('finds the copy at all, so a broken collector cannot pass by scanning nothing', () => {
    // Every number here is far below what the tree actually holds. They exist so
    // that a refactor which moves a directory, or a parser change that stops
    // producing JSX text nodes, fails loudly instead of reporting a clean sweep
    // of an empty list — which is the way a scanner test dies quietly.
    expect(STRINGS.length).toBeGreaterThan(1000)
    expect(STRINGS.filter((s) => s.file.startsWith('src/renderer/')).length).toBeGreaterThan(500)
    expect(STRINGS.filter((s) => s.file.startsWith('ios/')).length).toBeGreaterThan(20)
    expect(STRINGS.filter((s) => s.file.startsWith('pwa/')).length).toBeGreaterThan(10)
  })

  it('the two names the review called out are gone from every surface', () => {
    /*
     * `unwrap`, and quoted text included, which is hole 2. He asked not to see
     * these names; a name does not stop being on screen because it is inside a
     * `<code>` tag or a pair of backticks, and the sweep's own note that a
     * quotation "keeps the name" was about *commands*, which these are not.
     * Paths are still cut, so the `.gitignore` template this app writes keeps
     * its `.vscode/*` line.
     */
    const offenders = STRINGS.filter((item) =>
      NAMED_IN_THE_REVIEW.test(prosePartOf(withoutDisclosures(item.text), 'unwrap')),
    )
    expect(offenders.map(show)).toEqual([])
  })

  it('every disclosed filename is still somewhere, so the list cannot go stale', () => {
    for (const entry of DISCLOSED_FILENAMES) {
      expect(
        STRINGS.some((item) => item.text.includes(entry.text)),
        `nothing says ${JSON.stringify(entry.text)} any more — delete the entry`,
      ).toBe(true)
    }
  })

  it('every vendor name left is in a module whose subject is that vendor', () => {
    const exempt = new Set(ABOUT_A_NAMED_AGENT.map((entry) => entry.file))
    const offenders = vendorStrings().filter((item) => !exempt.has(item.file))
    expect(offenders.map(show)).toEqual([])
  })

  it('and is one of the strings that module was exempted for', () => {
    /*
     * Hole 2. Until today an entry in `ABOUT_A_NAMED_AGENT` waved through the
     * *whole file*, for ever, on the strength of a sentence written about the
     * strings that were in it at the time. Twenty-three files were exempt, and
     * a new vendor name added to any of them — a new error message in
     * `mcp-client.ts`, a fourth line of help in `HelpPanel.tsx` — was seen by
     * nothing.
     *
     * So the exemption is now the strings, not the module. `allows` is the
     * exact copy each entry was written for, and anything else naming a vendor
     * in the same file fails here with the string printed, which is a two-line
     * decision for whoever caused it: neutralise the sentence, or add it and
     * say in the entry why it earns the name.
     */
    const allowed = new Map(ABOUT_A_NAMED_AGENT.map((entry) => [entry.file, new Set(entry.allows)]))
    const offenders = vendorStrings().filter((item) => {
      const allows = allowed.get(item.file)
      return allows !== undefined && !allows.has(item.text.trim())
    })
    expect(offenders.map(show)).toEqual([])
  })

  it('no module, and no string in one, is exempted that no longer needs it', () => {
    // The other direction, and the reason both are needed: a list that only
    // grows is a list that stops describing the code. An `allows` entry that
    // matches nothing is copy somebody deleted or rewrote, and the exemption
    // for it has to go with it.
    const named = vendorStrings()
    const stale: string[] = []
    for (const entry of ABOUT_A_NAMED_AGENT) {
      const mine = named.filter((item) => item.file === entry.file)
      if (mine.length === 0) stale.push(entry.file)
      for (const allowed of entry.allows) {
        if (!mine.some((item) => item.text.trim() === allowed)) {
          stale.push(`${entry.file}  ${allowed.slice(0, 80)}`)
        }
      }
    }
    expect(stale).toEqual([])
  })

  it('every exemption carries a reason somebody can argue with', () => {
    for (const entry of [...ABOUT_A_NAMED_AGENT, ...DISCLOSED_FILENAMES]) {
      // A one-line "legacy" or "needed" is how these lists rot. Nothing shorter
      // than a sentence explains why removing a name would make a screen worse.
      expect(entry.because.split(/\s+/).length).toBeGreaterThan(12)
    }
  })
})

describe('the neutral vocabulary is used consistently', () => {
  /**
   * One phrase for one thing.
   *
   * The instruction was not only "stop saying Claude" — it was to find *the*
   * neutral word rather than three of them. Three synonyms scattered across the
   * settings pane, the readiness check and the cost warning read as three
   * different files, which is worse than one branded name used consistently.
   *
   * The settled phrase is **"instructions"** — "your instructions file", "the
   * folder's own instructions", "agent instructions". These assertions pin the
   * places the sweep rewrote, so the next edit cannot drift back to a filename
   * or off to a fourth synonym.
   */
  const says = (file: string, text: string): boolean =>
    STRINGS.some((item) => item.file === file && item.text.includes(text))

  it('the copilot describes a folder by what it reads, not by a filename', () => {
    // The setup flow shows the first of these through `CHOOSING_A_FOLDER`, and
    // the native folder panel sets it as its own message, so one string covers
    // three surfaces — which is why it lives in `shared/` rather than being said
    // again in each of them.
    expect(says('src/shared/copilot-text.ts', 'the folder’s own instructions and')).toBe(true)
    expect(
      says('src/renderer/settings/sections/CopilotSection.tsx', 'that folder’s own instructions'),
    ).toBe(true)
  })

  it('the readiness check is titled by category, and its fix by what it makes', () => {
    expect(says('src/main/readiness.ts', 'Agent instructions present and useful')).toBe(true)
    expect(says('src/main/readiness.ts', 'Create instructions file')).toBe(true)
  })

  it('the fixed-prefix warning and the pane above it use the same words', () => {
    expect(says('src/main/cost.ts', 'check your instructions file and MCP tool schemas')).toBe(true)
    expect(
      says('src/renderer/components/SessionInspector.tsx', 'system prompt, instructions file and tool schemas'),
    ).toBe(true)
  })

  it('the phone names the category of program, not two members of it', () => {
    expect(
      says('ios/TerminalDeck/Screens/SessionListView.swift', 'in your own terminal or editor.'),
    ).toBe(true)
  })
})
