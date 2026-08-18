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
 * Before matching, three shapes are cut out of the text, because they are not
 * prose even when they sit in the middle of it: URLs, anything containing a
 * path separator, `SCREAMING_SNAKE` environment variables, and spans inside
 * backticks — which is how every command in this codebase's prose is written.
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
    text: 'No instructions file — none of CLAUDE.md, .claude/CLAUDE.md or AGENTS.md is here.',
    because:
      'The only branch of the readiness check that has no real file to name, because there is not one. ' +
      'Listing the three names it would accept is the actionable half: "no instructions file" with no ' +
      'accepted spellings is a finding nobody can act on, and somebody whose project carries an AGENTS.md ' +
      'deserves to see that it counts.',
  },
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
 * The list is asserted to be exactly used: an entry that stops matching anything
 * fails the suite rather than sitting here forever describing a string somebody
 * deleted two releases ago.
 */
const ABOUT_A_NAMED_AGENT: ReadonlyArray<{ file: string; because: string }> = [
  {
    file: 'src/shared/agent-catalog.ts',
    because:
      'The catalogue itself. Every string is one agent’s row — its label, its one-line description, its ' +
      'install command, and the `verified` note recording what was run on a real machine and what it ' +
      'answered. This is case 1 in its purest form: the row is the agent.',
  },
  {
    file: 'src/main/prerequisites.ts',
    because: 'Setup rows derived from the catalogue, one per agent. "Run Codex sessions" is that agent’s row.',
  },
  {
    file: 'src/main/hooks.ts',
    because:
      '`HOOK_PROVIDERS`: one entry per agent, each naming its own settings file, its own event names and — ' +
      'for Codex — the config key that has to be set before it runs hooks at all. Neutralising the ' +
      'requirement line would leave a row that silently does nothing.',
  },
  {
    file: 'src/renderer/settings/settings-schema.ts',
    because: 'Per-agent option labels in the settings schema, the same three names the catalogue declares.',
  },
  {
    file: 'src/main/gemini-signin.ts',
    because:
      'The Gemini sign-in flow. It exists because that CLI has no login subcommand and has to be driven ' +
      'through a session; every sentence in it is about that one CLI’s behaviour.',
  },
  {
    file: 'src/main/codex-usage.ts',
    because:
      'Reads the rollout files one named CLI writes, and nothing else. Its diagnostic prefix names that ' +
      'reader so a line in the console can be traced to the module that produced it.',
  },
  {
    file: 'src/main/plan-limit.ts',
    because:
      'Parses the plan-limit line one CLI prints. The message says which CLI has not printed one yet, ' +
      'which is the difference between "nothing to show" and "something is broken".',
  },
  {
    file: 'src/main/usage-ipc.ts',
    because:
      'Answers "why is there no usage for this session" per agent, because the two agents record it at ' +
      'different moments — one near a limit, one when a turn completes.',
  },
  {
    file: 'src/renderer/shell/usage-bar-model.ts',
    because:
      'Captions naming which source a number came from — one CLI’s /usage panel, its limit warning, or ' +
      'the other’s rollout. The caption is the provenance.',
  },
  {
    file: 'src/renderer/shell/UsageBar.tsx',
    because:
      'Describes an automation that types /usage and reads the panel that one CLI draws. It is that CLI’s ' +
      'command and that CLI’s panel.',
  },
  {
    file: 'src/renderer/chat/usage/usage-model.ts',
    because: 'The same automation’s refusals, naming the prompt it looked for and did not find.',
  },
  {
    file: 'src/renderer/chat/controls/catalog.ts',
    because:
      'The model, effort, fast and permission controls type one CLI’s slash commands into the pty. ' +
      '`unsupportedProviderNote` withdraws the whole panel for the other agents and says so in as many ' +
      'words, so nothing here is ever drawn where a different agent could be meant.',
  },
  {
    file: 'src/main/agent-controls.ts',
    because:
      'The authoritative refusal behind those controls. It quotes the slash commands it would have typed ' +
      'and says nothing on the session’s screen showed that CLI is the one running in it — a refusal that ' +
      'named no CLI would be indistinguishable from a bug.',
  },
  {
    file: 'src/main/mcp-add.ts',
    because:
      'Shells out to `claude mcp add` rather than writing another application’s live 70 KB config itself — ' +
      'the file header carries the argument. An error saying which binary is missing is case 2.',
  },
  {
    file: 'src/main/mcp-client.ts',
    because:
      'Reads that same configuration and reports what it found in it — including the servers one CLI dials ' +
      'itself, which this panel cannot inspect, and the ones a project has declined. Both facts are about ' +
      'that CLI’s behaviour and mean nothing without its name.',
  },
  {
    file: 'src/renderer/components/McpAddForm.tsx',
    because:
      'The form over that command. "Stays inactive until Claude Code asks you to approve it" is measured ' +
      'behaviour of the tool that owns the file; without it a working safeguard reads as a failed add.',
  },
  {
    file: 'src/renderer/components/McpInspector.tsx',
    because:
      'Shows that configuration on screen and says whose it is, because removing a server genuinely cannot ' +
      'be done from this window and a panel that stays quiet about what it cannot do reads as broken ' +
      'rather than as limited.',
  },
  {
    file: 'src/renderer/components/HelpPanel.tsx',
    because:
      'The help page whose subject is installing and signing into the agent CLIs. Its first topic is called ' +
      '"Install an agent CLI" — the category — and it then names all three and gives the real commands, ' +
      'because a help page that will not say which thing to install is not help.',
  },
  {
    file: 'src/renderer/settings/sections/AccountsSection.tsx',
    because:
      'States which agents can hold more than one login and which cannot. That is a per-agent fact, it was ' +
      'measured, and it is the reason a row is or is not offered.',
  },
  {
    file: 'src/renderer/settings/sections/AgentsSection.tsx',
    because:
      'Says a setting applies to one agent and that the others ignore it. Naming the limit is the honest ' +
      'form; the alternative is a control that quietly does nothing for two thirds of people.',
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
  },
  {
    file: 'src/renderer/shell/AccountChip.tsx',
    because:
      'The Run button types the literal string `claude` into the session. The label is the command, so ' +
      'renaming the label without changing what it types would make the button lie about what it does — ' +
      'the exact failure the review is about. Follow-up owned elsewhere: offer the session’s own agent.',
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
 */
const QUOTING_ELEMENTS = new Set(['code', 'pre', 'kbd', 'samp'])

interface Found {
  file: string
  line: number
  text: string
}

/**
 * Cut out the shapes that are not prose, so what is left can be matched
 * honestly.
 *
 * Order matters: backticked spans go first because they wrap commands that
 * contain paths, and a path stripped out of a span would leave its backticks
 * behind to swallow the wrong range.
 */
function prosePartOf(text: string): string {
  return (
    text
      .replace(/`[^`]*`/g, ' ')
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
  const take = (text: string, node: ts.Node): void => {
    found.push({ file: rel, line: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1, text })
  }

  const visit = (node: ts.Node): void => {
    if (ts.isJsxText(node)) {
      const parent = node.parent
      const tag =
        ts.isJsxElement(parent) ? parent.openingElement.tagName.getText(sf) : ''
      if (node.text.trim() && !QUOTING_ELEMENTS.has(tag)) take(node.text, node)
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
      const parts = [node.head.text, ...node.templateSpans.map((span) => span.literal.text)]
      if (readsLikeASentence(parts.join(' '))) take(parts.join(' … '), node)
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
      if (readsLikeASentence(match[1])) found.push({ file: rel, line: index + 1, text: match[1] })
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
    const offenders = STRINGS.filter((item) =>
      NAMED_IN_THE_REVIEW.test(prosePartOf(withoutDisclosures(item.text))),
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
    const offenders = STRINGS.filter(
      (item) =>
        !exempt.has(item.file) && VENDORS.test(prosePartOf(withoutDisclosures(item.text))),
    )
    expect(offenders.map(show)).toEqual([])
  })

  it('no module is exempted that no longer needs it', () => {
    const stale = ABOUT_A_NAMED_AGENT.filter(
      (entry) =>
        !STRINGS.some(
          (item) =>
            item.file === entry.file && VENDORS.test(prosePartOf(withoutDisclosures(item.text))),
        ),
    )
    expect(stale.map((entry) => entry.file)).toEqual([])
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
