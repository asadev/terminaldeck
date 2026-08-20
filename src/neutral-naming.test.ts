import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, resolve, sep } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'

/**
 * No shared screen uses an outside product as an illustration, and no screen
 * offers one agent where a choice exists.
 *
 * ## The rule, in his words, in two passes
 *
 * The first pass, from the recorded review of 2026-08-17, said while looking at
 * the copilot's folder step but stated as a rule for the whole product:
 *
 *   > *"We are everywhere mentioning CLAUDE.md… if we mention Claude everywhere
 *   > then it will be specific to Claude, even the previous sections. You should
 *   > not mention in any settings or any pop-up a specific tool or LLM or
 *   > something, because they can use some other also. So we should not call
 *   > Claude. Maybe we can use some other keyword — we can give `.md` files or
 *   > MD files only or something else, whatever is the best word."*
 *
 * This file read that as *"no user-facing string names a specific AI tool"*, and
 * that reading was too strict. On 2026-08-19 he **refined** it — and refined is
 * the word, because nothing above is withdrawn; what changes is which half of it
 * was doing the work:
 *
 *   > *"I didn't mean that you cannot use the Claude name — you must use the
 *   > Claude name where it actually makes sense, and if you are not prioritizing
 *   > Claude only. The only thing is I just did not want to use the name of
 *   > third-party applications — as an example, where we say, you name in one
 *   > field VS Code as an example just to give people an example in the
 *   > description, 'this is similar to that' or something like that. So in your
 *   > examples, when you are describing something and you are giving examples of
 *   > anything, don't give the examples of the other tools. And the second thing
 *   > — where we can have an option between Claude, Codex, Gemini, in those
 *   > places don't name only Claude. Give all the options, so they don't feel
 *   > like it is all about Claude. Maybe some users are only using Codex, they
 *   > never use Claude. You can use the name of Claude, Codex and all of these
 *   > names wherever it is needed — just don't give only one single option
 *   > everywhere."*
 *
 * So the rule has three parts, and only two of them are things a string scan can
 * be trusted with.
 *
 *  1. **Naming an agent is fine when the text is about that agent.** *"Claude
 *     Code 2.1.235, signed in"* on a server that has Claude Code on it is
 *     correct and stays. So does `claude mcp add` in a `<code>` span, so does
 *     `~/.gemini/settings.json`, and so does every row in the catalogue. This is
 *     not an exemption any more — it is the rule. **Not checked here**, because
 *     there is nothing left to check: it is the permitted case.
 *  2. **Never an outside product as an illustration.** *"similar to VS Code"*,
 *     *"like Codex does"*, *"think of it as X"*. This is the part he actually
 *     objected to, and it is checked below, twice over: editor and IDE names are
 *     refused outright, and any outside product is refused when it follows a
 *     comparison lead-in.
 *  3. **Never one agent where a choice should exist.** A screen that could carry
 *     Claude Code, Codex and Gemini offers all three. **This is a product rule,
 *     not a lint, and this file does not pretend to check it.** Whether a screen
 *     *could* support three agents is a question about what the code behind it
 *     can do, and no scan over string literals can answer it — a Claude-only
 *     wizard whose every sentence says "an agent" would pass every assertion in
 *     this file while being exactly the thing he complained about. It is checked
 *     by the screens' own tests, where the question is answerable: server setup
 *     offers all three (`setup.test.ts`), and the copilot's picker does
 *     (`copilot-setup.test.tsx`).
 *
 * The two filenames survive part 3 rather than part 2, and that is why they are
 * still refused below: a settings pane that tells everybody to go and edit their
 * CLAUDE.md is naming one agent's file on a screen where three agents' files
 * would do, which is *"don't give only one single option everywhere"* in its
 * most literal form.
 *
 * ## What was deleted when the rule was refined, and why that is not a weakening
 *
 * Until today this file carried `ABOUT_A_NAMED_AGENT`: twenty-three modules,
 * each with a paragraph arguing that its subject genuinely was one named agent,
 * and a list of the exact strings the argument covered. Every one of those
 * arguments is now simply **part 1**, which is allowed outright, so the list was
 * a licence for something that no longer needs licensing. Keeping it would mean
 * this suite went on enforcing the reading he corrected — and it would have
 * blocked the work that corrected it, since server setup now has to say the
 * words "Codex CLI" and "Gemini CLI" on the same screen as "Claude Code".
 *
 * What replaces it needs no exemptions at all, which is the stronger shape: two
 * universal rules that no module can buy its way out of. Nothing in this app is
 * legitimately *about* a third-party editor, and nothing in it legitimately
 * makes a comparison to somebody else's product, so neither rule has a case to
 * carve out. The only escape hatch left is {@link DISCLOSED_FILENAMES}, which is
 * two strings long and each one discloses a file about to appear on somebody's
 * disk.
 *
 * ## Why any of it needs a test and not just a careful afternoon
 *
 * The sweep that produced this file found thirty-odd strings, and three of them
 * were not merely branded but **wrong**: a settings editor whose `aria-label`
 * announced `CLAUDE.md` while the file it edits is `instructions.md`, a
 * confirmation offering to keep a backup "as CLAUDE.md.bak" when the backup
 * written is `instructions.md.bak`, and a paragraph telling somebody a rule was
 * "written in its CLAUDE.md" when it is written into the layer file two blocks
 * above. Every one was defensible on the day it was typed and none was caught by
 * a compiler, a review or nine thousand tests, because a string that is merely
 * *untrue* type-checks perfectly.
 *
 * That argument survives the refinement intact, and it is worth being clear that
 * it now cuts the other way as often as not: the repair for those three was to
 * make the sentence true, and under part 1 the true sentence is sometimes the
 * one with the name in it.
 *
 * ## What counts as user-facing, mechanically
 *
 * Comments never appear — this walks the TypeScript AST, where a comment is not
 * a node — so the long explanations above every string in this codebase are free
 * to name whatever they need to, including this one. What is collected is:
 *
 *   - JSX text, unless it sits inside `<code>`, `<pre>` or `<kbd>`, which is a
 *     quotation rendered as itself;
 *   - JSX attributes a person hears or reads: `title`, `placeholder`,
 *     `aria-label`, `alt`, and the copy props this codebase passes around;
 *   - object properties with those names, which is how the settings schema, the
 *     readiness checks and the widget catalogue carry their copy;
 *   - any string or template literal that reads like a sentence — three or more
 *     words. That last one is the net: it catches copy nobody thought to route
 *     through a named prop, which is most of it.
 *
 * The middle two are read *through whatever they are built out of* and at any
 * length — a call, an array, a ternary, an object — because a copy key is a
 * declaration that its value is words on a screen, and a label is a label at one
 * word. See {@link copyLiteralsIn}.
 *
 * Before matching, four shapes are cut out of the text, because they are not
 * prose even when they sit in the middle of it: URLs, paths, `SCREAMING_SNAKE`
 * environment variables, and spans inside backticks — which is how every command
 * in this codebase's prose is written.
 *
 * ## Four holes in the collector, closed on 2026-08-18 and 2026-08-19
 *
 * These are about **where the collector was willing to look**, and they outlive
 * the change of rule entirely — a scanner that cannot see a string cannot apply
 * any rule to it. All four were the same mistake in different clothes: *the
 * guard was reading something other than what a person reads.*
 *
 *  1. **Backticks sheltered anything at all.** `prosePartOf` deleted every
 *     backticked span before matching. A span is now sheltered only when it
 *     holds no capitalised word, which is what tells `brew upgrade gemini-cli`
 *     (a thing you type) from `Claude Code` (a thing you say). See
 *     {@link shelters}.
 *  2. **Nothing sheltered the two filenames.** The strict rule ran on the same
 *     stripped text as the loose one. It now reads the text with backticks
 *     *unwrapped* and reads the inside of `<code>` as well — paths still
 *     excepted, because `.vscode/*` in a `.gitignore` template is a location and
 *     not a sentence.
 *  3. **A name composed at runtime was never a string.** Template literals are
 *     now resolved: an interpolation of a string constant declared in the same
 *     file is substituted with its value, and one that cannot be resolved
 *     contributes the *property names* chosen off it — never the root
 *     identifier, so ordinary variables cannot trip it.
 *  4. **A copy key was only read when its value was a bare string literal.**
 *     `label={baseName(folderFile?.path ?? 'CLAUDE.md')}` and
 *     `touches: ['CLAUDE.md']` both reached a shipped screen with this file
 *     green. The repair is positional rather than lexical, and
 *     {@link readsLikeASentence} argues why counting one word as a sentence
 *     would have been the wrong fix.
 *
 * Since a clean tree is also what a collector with a hole in it reports, the last
 * `describe` in this file hands the collector a few lines of source and asks what
 * it saw, rather than inferring its reach from today's sources being tidy.
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
 * This is a list of one on purpose, and since the module exemptions were deleted
 * it is the only place in this file where a string is not looked at. A module
 * skipped here is a module where a bad string cannot be caught at all, which is
 * a much larger hole than {@link DISCLOSED_FILENAMES} — those are two exact
 * strings, and anything else in the same sentence still fails.
 */
const NOT_COPY_AT_ALL = new Set(['src/main/copilot-instructions-history.ts'])

/**
 * Somebody else's editor, banned outright and with nowhere to appeal.
 *
 * These are the *"third-party applications"* of the correction, and they get the
 * absolute rule because this app has no honest use for their names. It is a
 * terminal workspace: it does not integrate with any of them, cannot launch one,
 * and reports nothing about one. The only reason a name from this list has ever
 * reached this tree's copy is the reason he gave — as an example — so banning the
 * word and banning the illustration come to the same thing, and a rule where
 * those two coincide is the only kind worth automating.
 *
 * `Cursor` is deliberately absent, and it is the one that proves the list is
 * chosen rather than copied off a search: the editor shares its name with the
 * caret, and the only occurrences in this tree are *"an unusable cursor"* and
 * *"the server repeated a cursor"*. A rule that fires on those teaches people to
 * add exemptions, and a guard answered with exemptions has stopped guarding.
 *
 * `Emacs` and `Eclipse` are out for the same reason in different clothes — one
 * names a keybinding mode a terminal may legitimately offer, the other is an
 * ordinary English word.
 *
 * `Xcode` and `Android Studio` came off this list the first time it was run, and
 * they are the entries worth reading twice. The tree answered with
 * `confine/seatbelt.ts`, which writes *"The Xcode tool shim's cache, and nothing
 * else in that shared directory"* into a generated macOS sandbox profile beside
 * the rule that grants that one path. That is part 1 in a place nobody would
 * think to look for it: the directory really is Xcode's, and a comment naming
 * its owner is the only thing that makes the rule below it reviewable. A
 * toolchain whose files this app has to name on disk cannot carry an *absolute*
 * ban, or the ban starts collecting exemptions — which is precisely how the
 * previous version of this file lost its teeth. They remain covered by
 * {@link comparisons}, which is the rule that was actually being asked for.
 *
 * `JetBrains` is in, but `JetBrains Mono` is cut out first by {@link prosePartOf}:
 * it is the monospace font three terminals ask for by name, and a font family is
 * not an IDE.
 */
const EDITORS =
  /\b(vs ?code|vscode|visual studio|jetbrains|intellij|pycharm|webstorm|goland|rubymine|sublime text|textmate|windsurf|notepad\+\+)\b/i

/**
 * Every outside product whose name must not be used to illustrate something.
 *
 * Wider than {@link EDITORS} on purpose, and the agents are on it: part 2 of the
 * rule is about *examples*, and *"works like Claude Code does"* in the
 * description of an unrelated feature is the same move as *"similar to VS
 * Code"*. Naming Claude Code while describing Claude Code is part 1 and is not
 * matched here, because {@link comparisons} only looks at what follows a
 * comparison.
 *
 * `Copilot` is absent because it is **this product's own word** for its
 * assistant — the review uses it on every page — and it is a common noun here,
 * not GitHub's product.
 *
 * `Chrome`, `Edge` and `Cursor` are absent for a sharper version of the same
 * reason: this codebase already uses all three words for its own things — the
 * window chrome and `--chrome-solid*`, the edge of a pane, the text caret. A
 * lead-in immediately before one of them would be a real comparison, but so
 * would *"sits at the edge, like Edge"*, and the rate at which those two are
 * confused is not worth the exemptions it would buy. `Docker Desktop` and
 * `Warp Terminal` are spelled in full for the same reason: plain `docker` is a
 * fact this app reports about a server, and a plain `warp` is a thing a cursor
 * does.
 */
const OUTSIDE_PRODUCTS = new RegExp(
  `${EDITORS.source}|\\b(claude|anthropic|gemini|codex|openai|chatgpt|github|slack|notion|xcode|android studio|docker desktop|iterm|warp terminal|tmux)\\b`,
  'i',
)

/**
 * The lead-ins that turn a name into an illustration.
 *
 * This is the mechanical half of part 2, and it is deliberately the **narrow**
 * half. The rule as he stated it is *"when you are describing something and you
 * are giving examples of anything, don't give the examples of the other tools"*
 * — which is about any outside product, whoever makes it, and no list can hold
 * all of those. The general version was tried and it does not work: a check for
 * *any* capitalised word after `such as` fires on this app's own vocabulary —
 * "alerts like Alerts", "a pane such as Servers" — and the exemptions it would
 * collect are exactly what killed the previous version of this file.
 *
 * So the automatic check is confined to {@link OUTSIDE_PRODUCTS}, a list of
 * names somebody has to have typed on purpose, and **the general rule is written
 * down here for a person to apply**: if you are reaching for another company's
 * product to explain what one of ours does, delete it and describe the thing
 * itself. A reader who needs the comparison to understand the sentence is a
 * reader the sentence has already failed.
 *
 * `the way` earns its place on the list because it is the form this codebase
 * actually reaches for — `the way Finder does`, `the way Windows does` — and it
 * is only a comparison when a proper name follows it, which is what the pattern
 * requires. `the way this app looks for an assistant` is prose and matches
 * nothing.
 */
const COMPARISON_LEAD_IN =
  /\b(?:like|similar to|similarly to|such as|e\.?g\.?|for example|for instance|just like|much like|the way|analogous to|akin to|the same as|compared to|compare with|think of it as|in the style of|as in)\s+(?:the\s+|a\s+|an\s+)?["'“‘(]*$/i

/**
 * Where one of those names is being used as an illustration rather than named.
 *
 * The text is walked once per occurrence of an outside product's name, and what
 * decides it is **what comes before the name, not the name itself** — which is
 * the whole distinction the correction draws. `Claude Code 2.1.235, signed in`
 * has a sentence start before it and passes. `works similar to Claude Code` has
 * a comparison before it and fails.
 */
function comparisons(text: string): string[] {
  const found: string[] = []
  const scan = new RegExp(OUTSIDE_PRODUCTS.source, 'gi')
  for (const hit of text.matchAll(scan)) {
    const before = text.slice(0, hit.index)
    if (COMPARISON_LEAD_IN.test(before)) found.push(`${before.trimStart().slice(-40)}${hit[0]}`)
  }
  return found
}

/**
 * The filenames that pick one agent for a reader who may be running another.
 *
 * Still banned everywhere with no module exemption, and now for part 3's reason
 * rather than part 1's: a settings pane or a pop-up that says *"edit your
 * CLAUDE.md"* has silently chosen one of three agents on a screen where all
 * three are possible, which is the *"don't give only one single option"* half of
 * the correction. `VS Code` is here as well as in {@link EDITORS} because it is
 * the string he pointed at by name, on the phone, about the sessions list:
 *
 *   > *"running in terminal or VS Code — we don't need to mention VS Code
 *   > because it's another one… but VS will be a specific thing."*
 *
 * The only way past this one is {@link DISCLOSED_FILENAMES}.
 */
const NAMED_IN_THE_REVIEW = /\bCLAUDE\.md\b|\bGEMINI\.md\b|\bVS ?Code\b|\bVisual Studio Code\b/i

/**
 * Where a filename may still be spelled out, and why each one earns it.
 *
 * Exact strings rather than files: an exemption that covered `readiness.ts`
 * would let the *next* sentence in it name a filename too, and the point of the
 * hard rule is that nothing new gets in.
 *
 * This is now the only exemption list in the file. Both entries survive the
 * 2026-08-19 correction unchanged, because neither is choosing an agent for
 * anybody — they are both disclosing what is about to be written where, after
 * the choice has already been made.
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

/* --------------------------------------------------------------- collecting -- */

/**
 * JSX props and object keys that carry words a person reads.
 *
 * A key on this list declares its value to be copy, so the value is read
 * **whatever shape it has and however short it is** — see {@link copyLiteralsIn}
 * for why that is now the collector's rule rather than "a string literal of
 * three words or more".
 */
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
  /*
   * `touches` is the readiness fix's list of what it writes, printed under
   * "Changes" on the always-visible part of the card. It is on this list since
   * 2026-08-19 because it was the field that carried `CLAUDE.md` onto that card
   * for every project and every user while this suite stayed green — the value
   * is an array of one-word strings, so neither the object-property branch (a
   * string literal only) nor the catch-all (three words or more) could see it.
   * Its other values are project paths, which `prosePartOf` cuts out anyway.
   */
  'touches',
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

/**
 * Three words or more, at least one of them lettered. A sentence, not an id.
 *
 * This is the *catch-all's* test and it stays where it is, which is worth
 * defending because the fourth hole (below) was a one-word string sailing past
 * it. The obvious repair — count one word as copy — is the wrong one, and
 * loudly so: `'CLAUDE.md'` appears in this tree as an argument to `createFile`,
 * as a member of `CLAUDE_MD_CANDIDATES`, and inside `join(paths.root, …)`. Those
 * are filesystem operations, not sentences; the header of this file says in as
 * many words that code, identifiers and filenames are untouched. A guard that
 * fired on them would be answered with exemptions, and a guard answered with
 * exemptions has stopped guarding.
 *
 * So the widening is **positional, not lexical**: a string is copy because of
 * where it sits, not because of how many words it has. Three words remains the
 * heuristic for a bare literal *somewhere in code* — the net that catches copy
 * nobody routed through a named prop. Everywhere a string has been *declared* to
 * be copy, by sitting under a {@link COPY_KEYS} key or in a JSX attribute of
 * that name, length stops mattering entirely: a label is a label at one word.
 */
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

/**
 * Everything a copy key's value can put on a screen, however it is assembled.
 *
 * ## The fourth hole, found on 2026-08-19
 *
 * The three holes closed on 2026-08-18 were all about *what the text says*.
 * This one is about **where the collector was willing to look**, and it let two
 * live strings through on the two surfaces the review named:
 *
 *  1. `label={baseName(folderFile?.path ?? 'CLAUDE.md')}` in the copilot's
 *     settings pane. `label` is a copy key and `label` is exactly what the
 *     editor puts on the textarea's `aria-label`, so this was a vendor's
 *     filename read aloud to every screen-reader user on every machine. The
 *     attribute branch accepted a `StringLiteral` and nothing else, so a call
 *     was not looked inside at all — and because the collector never saw the
 *     string, no exemption was ever argued for it and nobody was ever asked.
 *  2. `touches: ['CLAUDE.md']` on the readiness fix. An array under a key,
 *     holding a single one-word string: too short for the catch-all and the
 *     wrong shape for the object-property branch, which also took a bare
 *     literal only.
 *
 * Both are the same mistake, and it is the mistake this file's own header warns
 * about in a different costume: **the guard was reading something other than
 * what a person reads.** A copy key is a *declaration* that its value is words
 * on a screen. Once that is declared, how the value is built — a literal, a
 * ternary, a call, an array, a `??` chain, an object of them — is the author's
 * business and none of the guard's, and so is how long it is.
 *
 * ## What it takes, and what it refuses to take
 *
 * Every string and template literal in the value's subtree, at any depth, with
 * no length test. Templates are resolved the same way the catch-all resolves
 * them, through {@link resolvedSpan}, so a name welded in from a constant still
 * arrives.
 *
 * JSX elements inside the value are stepped over, and that is deliberate rather
 * than lazy. `hint={<>…<code>claude mcp add</code>…</>}` is a subtree the main
 * visitor already walks, with the quoting rules the `<code>` tag is entitled to;
 * reading it a second time here would strip that context off it and report a
 * quotation as prose. Two readings that disagree is worse than one.
 *
 * Duplicates are not deduplicated, because the collector has always produced
 * them — `<Foo title="a long enough sentence" />` is taken by the attribute
 * branch and again by the catch-all as it descends — and every assertion in this
 * file is a question about *whether* a string is on the list, never how often.
 *
 * ## The false positives this buys, and why they are cheap
 *
 * A copy key whose value happens to contain a non-copy string now contributes
 * it: `title={formatWhen(at, 'en-GB')}` puts `en-GB` on the list. That is fine.
 * The list is only ever matched against a vendor name, and a locale, a format
 * string or a CSS length matches nothing. The cost of being over-inclusive here
 * is a longer list; the cost of being under-inclusive was `CLAUDE.md` in an
 * `aria-label` for a whole release.
 */
function copyLiteralsIn(
  value: ts.Expression,
  constants: Map<string, string>,
  take: (text: string, node: ts.Node) => void,
): void {
  const walk = (node: ts.Node): void => {
    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node) || ts.isJsxFragment(node)) return
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      take(node.text, node)
      return
    }
    if (ts.isTemplateExpression(node)) {
      const parts = [node.head.text]
      for (const span of node.templateSpans) {
        parts.push(resolvedSpan(span.expression, constants), span.literal.text)
      }
      take(parts.join(''), node)
      return
    }
    ts.forEachChild(node, walk)
  }
  walk(value)
}

function collectFromTypeScript(file: string, rel: string, found: Found[]): void {
  collectFromSource(readFileSync(file, 'utf8'), rel, file.endsWith('.tsx'), found)
}

/**
 * The collector proper, over text rather than over a path.
 *
 * Split out from {@link collectFromTypeScript} on 2026-08-19 so that the last
 * test in this file can hand it a few lines of source and ask what it saw. That
 * test is the only reason the seam exists, and it earns it: every other
 * assertion here asks whether *today's tree* is clean, which a collector that
 * has quietly stopped looking somewhere also answers yes to. The `> 1000`
 * counts at the top catch a collector that has died altogether; nothing caught
 * one that had a hole in a particular shape, which is what all four holes were.
 */
function collectFromSource(source: string, rel: string, tsx: boolean, found: Found[]): void {
  const sf = ts.createSourceFile(
    rel,
    source,
    ts.ScriptTarget.Latest,
    true,
    tsx ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
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
        const value = ts.isJsxExpression(init) ? init.expression : init
        if (value) copyLiteralsIn(value, constants, take)
      }
    } else if (ts.isPropertyAssignment(node)) {
      const key =
        ts.isIdentifier(node.name) || ts.isStringLiteral(node.name) ? node.name.text : null
      if (key !== null && COPY_KEYS.has(key)) copyLiteralsIn(node.initializer, constants, take)
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
 * A string carrying one of the disclosures, and nothing else that offends.
 *
 * The disclosure is *cut out* before matching rather than the whole string being
 * waved through, which is the difference that matters: the readiness fail detail
 * may name the file it accepts, and it still cannot go on to say "similar to VS
 * Code" in the next clause.
 */
function withoutDisclosures(text: string): string {
  let rest = text
  for (const entry of DISCLOSED_FILENAMES) rest = rest.split(entry.text).join(' ')
  return rest
}

describe('no shared screen holds up somebody else’s product as an example', () => {
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

  it('never names an outside product to illustrate what one of ours does', () => {
    /*
     * Part 2, and the assertion this file now exists for. Quotations are read as
     * well as prose: `<code>claude mcp add</code>` is a command and stays, but a
     * `<code>` tag is not a place to park a comparison, and nothing that follows
     * "similar to" is a command anybody types.
     */
    const offenders = STRINGS.filter(
      (item) => comparisons(prosePartOf(withoutDisclosures(item.text), 'unwrap')).length > 0,
    )
    expect(offenders.map(show)).toEqual([])
  })

  it('never names an editor at all, which it has no occasion to do', () => {
    // The absolute half of part 2. No exemption list, because there is no screen
    // in this app whose subject is somebody else's editor — see `EDITORS`.
    const offenders = STRINGS.filter((item) =>
      EDITORS.test(prosePartOf(withoutDisclosures(item.text), 'unwrap')),
    )
    expect(offenders.map(show)).toEqual([])
  })

  it('the filenames that would pick one agent for a reader are gone from every surface', () => {
    /*
     * `unwrap`, and quoted text included. He asked not to see these names; a name
     * does not stop choosing an agent for somebody because it is inside a
     * `<code>` tag or a pair of backticks. Paths are still cut, so the
     * `.gitignore` template this app writes keeps its `.vscode/*` line — that is
     * a location on a disk, not a sentence recommending an editor.
     */
    const offenders = STRINGS.filter((item) =>
      NAMED_IN_THE_REVIEW.test(prosePartOf(withoutDisclosures(item.text), 'unwrap')),
    )
    expect(offenders.map(show)).toEqual([])
  })

  it('every disclosed filename is still somewhere, so the list cannot go stale', () => {
    // A list that only grows is a list that stops describing the code.
    for (const entry of DISCLOSED_FILENAMES) {
      expect(
        STRINGS.some((item) => item.text.includes(entry.text)),
        `nothing says ${JSON.stringify(entry.text)} any more — delete the entry`,
      ).toBe(true)
    }
  })

  it('every exemption carries a reason somebody can argue with', () => {
    for (const entry of DISCLOSED_FILENAMES) {
      // A one-line "legacy" or "needed" is how these lists rot. Nothing shorter
      // than a sentence explains why removing a name would make a screen worse.
      expect(entry.because.split(/\s+/).length).toBeGreaterThan(12)
    }
  })
})

/**
 * The two rules, asked directly — because a clean tree is also what a rule that
 * matches nothing at all reports.
 *
 * Both of these went green the moment they were written, which is exactly the
 * condition under which a guard is worth nothing and looks perfect. So each one
 * is handed the sentence it was written to catch, and the sentence it must not
 * catch, side by side.
 */
describe('the rule bites, and only where it should', () => {
  const offends = (text: string): boolean =>
    comparisons(prosePartOf(text, 'unwrap')).length > 0 || EDITORS.test(prosePartOf(text, 'unwrap'))

  it('catches the illustration he objected to, in the words he used', () => {
    expect(offends('A workspace for your agents, similar to VS Code.')).toBe(true)
    expect(offends('Pin a session, like Notion does with pages.')).toBe(true)
    expect(offends('Runs your agent in a real terminal, such as Codex or Gemini.')).toBe(true)
    expect(offends('Hooks fire on events, e.g. Claude Code’s PreToolUse.')).toBe(true)
    // The one from `confine/seatbelt.ts`, which is why `Xcode` is not banned
    // outright — as an illustration it still fails, which is the whole point of
    // splitting the absolute rule from the comparison rule.
    expect(offends('Sandboxes each session, much like Xcode does.')).toBe(true)
    expect(offends('The Xcode tool shim’s cache, and nothing else in that shared directory.')).toBe(
      false,
    )
  })

  it('leaves an agent named as the subject of its own sentence alone', () => {
    // Part 1, which is the permission this file was rewritten to grant. Every
    // one of these is a real line from this tree, or the shape of one.
    expect(offends('Claude Code 2.1.235, signed in.')).toBe(false)
    expect(offends('Codex CLI 0.148.0 — not signed in.')).toBe(false)
    expect(offends('Gemini does not record how full its context window is.')).toBe(false)
    expect(offends('Claude Code’s command line tool could not be found.')).toBe(false)
    expect(offends('Read from the rollout Codex writes as it works — no need to ask it.')).toBe(false)
  })

  it('leaves this codebase’s own comparisons to non-products alone', () => {
    // `the way` is on the lead-in list, so these are the sentences that decide
    // whether it was safe to put it there. None of them names a product.
    expect(offends('It moves the way this app already moves elsewhere.')).toBe(false)
    expect(offends('Sorted the way Finder sorts, newest first.')).toBe(false)
    expect(offends('Press a key such as Escape to go back.')).toBe(false)
  })

  it('does not fire on a command a person types, or on a path', () => {
    // The two shapes `prosePartOf` exists to protect. Renaming either makes it
    // stop working, which is the one place the rule would force a lie.
    expect(offends('Run `npm install -g @google/gemini-cli@latest` first.')).toBe(false)
    expect(offends('Its settings live in ~/.codex/config.toml on that machine.')).toBe(false)
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

  it('the box that edits that folder’s file is named by category, not by the file', () => {
    /*
     * The `aria-label` on the textarea, which is the only thing `FileEditor`
     * does with `label` and the only way anybody hears which box they are in.
     * It read `baseName(folderFile?.path ?? 'CLAUDE.md')` until 2026-08-19 —
     * a vendor's filename, unconditionally, on the pane the review was looking
     * at when it asked for none.
     *
     * Pinned by the row's exact visible words rather than by any neutral
     * phrase, because the point is that the two agree: what a screen reader
     * announces is what the person next to it is reading.
     */
    expect(
      says('src/renderer/settings/sections/CopilotSection.tsx', 'The folder’s own instructions'),
    ).toBe(true)
  })

  it('the readiness card says what a fix changes by category on its visible line', () => {
    // `touches` is printed under "Changes" the moment the card is drawn, on any
    // repository with any agent in it. The filename is still disclosed — in the
    // fix's `description`, which is on the {@link DISCLOSED_FILENAMES} list and
    // is asserted to still exist by the staleness test above.
    expect(says('src/main/readiness.ts', 'your instructions file')).toBe(true)
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

/**
 * The guard's own reach, asked directly rather than inferred from a clean tree.
 *
 * Every other assertion in this file is a question about today's source, and a
 * collector with a hole in it answers all of them "clean". All four holes found
 * so far were exactly that: not a judgement anybody made, not a string anybody
 * argued for, but a shape the scanner declined to look at. The two below are the
 * ones that reached a screen in the 0.5.0 build and were never seen here.
 *
 * Written as source text on purpose. A test that called `copyLiteralsIn` with a
 * hand-built node would pin the function; this pins the thing that matters,
 * which is what happens when somebody types those lines into a `.tsx` file.
 */
describe('the collector reads copy in the shapes people actually write it', () => {
  const seen = (source: string, tsx = true): string[] => {
    const found: Found[] = []
    collectFromSource(source, tsx ? 'fixture.tsx' : 'fixture.ts', tsx, found)
    return found.map((item) => item.text)
  }

  it('reads a copy prop whose value is computed, not written out', () => {
    // The settings-pane leak, in miniature: a copy key, a call, and the name
    // inside it. `label` is what `FileEditor` puts on the textarea's
    // `aria-label`, so this is a person hearing "CLAUDE dot M D".
    const texts = seen(`
      const x = <FileEditor label={baseName(file?.path ?? 'CLAUDE.md')} />
    `)
    expect(texts).toContain('CLAUDE.md')
  })

  it('reads a copy key holding a list, and each one-word entry in it', () => {
    // The readiness leak. Neither the old object-property branch (a bare string
    // literal only) nor the catch-all (three lettered words or more) could see
    // a single short string inside an array.
    const texts = seen(`const fix = { touches: ['CLAUDE.md'] }`, false)
    expect(texts).toContain('CLAUDE.md')
  })

  it('reads through the other shapes a value gets built out of', () => {
    // Not a wish-list: each of these is how some existing copy prop in this
    // tree is written, and any of them could have been where the name landed.
    const texts = seen(`
      const a = <B title={busy ? 'Working…' : 'VS Code'} />
      const c = <D hint={['first', 'GEMINI.md']} />
      const e = <F note={{ text: 'Visual Studio Code', ok: true }} />
    `)
    expect(texts).toEqual(expect.arrayContaining(['VS Code', 'GEMINI.md', 'Visual Studio Code']))
  })

  it('and the whole thing is caught by the rule, not merely collected', () => {
    // Collection is only half of it. This is the assertion that would have gone
    // red on 0.5.0: the strict rule, run over what the collector now returns.
    const offenders = seen(`
      const x = <FileEditor label={baseName(file?.path ?? 'CLAUDE.md')} />
      const fix = { touches: ['CLAUDE.md'] }
    `).filter((text) => NAMED_IN_THE_REVIEW.test(prosePartOf(withoutDisclosures(text), 'unwrap')))
    expect(offenders).toHaveLength(2)
  })

  it('steps over JSX inside a copy prop rather than reading it twice', () => {
    /*
     * `<code>` is the one place the rule would force a lie, and the main visitor
     * is where that exemption lives — it tags the text `quoted` from the tag it
     * sits under. Reading the same span again from in here would report a
     * quotation as prose, so the walk stops at a JSX element and lets the
     * ordinary pass handle it, with the context intact.
     */
    const found: Found[] = []
    collectFromSource(
      `const x = <Row hint={<span>run <code>claude mcp add</code> first</span>} />`,
      'fixture.tsx',
      true,
      found,
    )
    const quoted = found.filter((item) => item.text.includes('claude mcp add'))
    expect(quoted).toHaveLength(1)
    expect(quoted[0].quoted).toBe(true)
  })
})
