import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, resolve, sep } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { BRAND } from './brand'
import { DEFAULT_COPILOT_NAME } from './copilot-identity'

/**
 * The assistant is called Hoot, everywhere a person or an outside AI reads it.
 *
 * ## Why this exists
 *
 * Until 2026-10-03 the assistant built into this app was called "Copilot",
 * which is Microsoft's trademark. Asad named it Hoot, and the name now lives in
 * one place, `BRAND.assistant` in `brand.ts`, beside the product's. A rename
 * done by hand across a codebase this size is exactly the kind of change that
 * leaves a tooltip, an error sentence or an MCP description behind, and the old
 * name in a dialog is a trademark problem rather than a typo. So this reads
 * every string the app ships and fails on the old name.
 *
 * ## What counts as something people read
 *
 * Every string literal, template literal and piece of JSX text in the shipped
 * TypeScript (`src/`, tests and fixtures excluded): labels, menus, tooltips,
 * notifications, dialog text, the Settings section name, empty states, error
 * sentences, the MCP tools' titles and descriptions, the server's
 * `instructions`, the setup snippets, the instructions handed to the assistant
 * itself. Read through the TypeScript parser rather than a regex over the file,
 * so comments, which explain the history and may name it, are never read.
 *
 * ## What is deliberately not counted
 *
 *  - **Storage and wire identifiers.** `copilot.enabled`, the `copilot/` and
 *    `copilot-log/` folders, the `copilot:*` IPC channels and the relay's
 *    `copilot.*` frames stay exactly as they are, because existing installs and
 *    paired phones already hold them. A string with no space in it that spells
 *    the word in lower case is one of those (`'copilot'`, `'copilot:state'`),
 *    and so is the word glued to `.`, `:`, `_`, `/` or `-` inside prose (the
 *    settings prefix `copilot.`). Written in backticks or as a quoted value
 *    (`"copilot"`) inside a sentence, it is an identifier too.
 *  - **GitHub Copilot**, the third-party coding agent this app detects and
 *    lists. That is Microsoft's product called by its own name, which is the
 *    correct use of a trademark, not a borrowing of one.
 *  - **Developer logs**: the arguments to `console.*`, read by whoever is
 *    debugging and never shown in the window.
 *  - The few files and strings in {@link EXEMPT}, each with its reason.
 */

const SRC = resolve(__dirname, '..')

/** Files whose strings are not read here at all, and why. */
const EXEMPT_FILES = new Map<string, string>([
  [
    'main/copilot-instructions-history.ts',
    'frozen copies of the instructions older builds wrote, compared byte for byte to tell an untouched old file from somebody’s own writing; changing a word would stop recognising it',
  ],
  ['main/copilot.ts', 'GitHub Copilot, the third-party agent, named correctly'],
])

/** Single strings that must keep the old word, and why. */
const EXEMPT = new Map<string, string>([
  [
    'meantime this app calls you the Copilot, which is a description',
    'one line of the exact paragraph older builds wrote into the person’s instructions; `withCurrentDefaultName` matches it byte for byte to replace it with the new one when the layer is composed',
  ],
])

/** Every shipped `.ts`/`.tsx` under `src/`, as paths relative to it. */
function sources(): string[] {
  const out: string[] = []
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) walk(path)
      else if (/\.tsx?$/.test(entry.name) && !/\.test\.tsx?$|\.d\.ts$|\.fixture\.tsx?$/.test(entry.name)) {
        out.push(relative(SRC, path).split(sep).join('/'))
      }
    }
  }
  walk(SRC)
  return out.sort()
}

/** The parts of a sentence that are identifiers or someone else's product. */
const NOT_THE_NAME =
  /GitHub Copilot( CLI)?|gh[ -]copilot|@github\/copilot|Copilot CLI|`[^`]*`|\\?"copilot\\?"|[\w./@:$-]copilot|copilot(?=[.:_/$-]\w)|copilot(?=\.(,|\s+(setting|prefix)))/gi

/** The old name, used as a word. */
const OLD_NAME = /\bcopilot\b/i

/**
 * Whether a string a person might read uses the old name.
 *
 * Capitalised, it is the name wherever it appears. In lower case it is the name
 * only in prose, a string with a space in it; on its own it is a key.
 */
export function namesTheOldAssistant(text: string): boolean {
  const left = text.replace(NOT_THE_NAME, ' ')
  const match = OLD_NAME.exec(left)
  if (!match) return false
  return /Copilot/.test(match[0]) || /\s/.test(text.trim())
}

function isConsoleArgument(node: ts.Node): boolean {
  let at: ts.Node | undefined = node.parent
  while (at && (ts.isBinaryExpression(at) || ts.isTemplateSpan(at) || ts.isParenthesizedExpression(at))) at = at.parent
  if (!at || !ts.isCallExpression(at)) return false
  const callee = at.expression
  return ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression) && callee.expression.text === 'console'
}

/** Every string in one file that names the old assistant, as `file:line: text`. */
function offendersIn(file: string): string[] {
  const text = readFileSync(join(SRC, file), 'utf8')
  if (!/copilot/i.test(text)) return []
  const source = ts.createSourceFile(
    file,
    text,
    ts.ScriptTarget.Latest,
    true,
    file.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  )
  const found: string[] = []
  const check = (node: ts.Node, value: string): void => {
    if (!namesTheOldAssistant(value)) return
    if ([...EXEMPT.keys()].some((allowed) => value.includes(allowed))) return
    if (isConsoleArgument(node)) return
    const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1
    found.push(`${file}:${line}: ${JSON.stringify(value.trim().slice(0, 120))}`)
  }
  const visit = (node: ts.Node): void => {
    // A module path is where code lives, not something anybody reads.
    if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) return
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) check(node, node.text)
    else if (ts.isTemplateExpression(node)) {
      check(node, [node.head.text, ...node.templateSpans.map((span) => span.literal.text)].join(' … '))
    } else if (ts.isJsxText(node)) check(node, node.text)
    ts.forEachChild(node, visit)
  }
  visit(source)
  return found
}

describe('the assistant is called Hoot in everything the app shows', () => {
  it('keeps the name in one place', () => {
    expect(BRAND.assistant).toBe('Hoot')
    // What every surface prints when nobody has given it a name of their own.
    expect(DEFAULT_COPILOT_NAME).toBe(BRAND.assistant)
  })

  it('never shows the old name in a string the app ships', () => {
    const files = sources().filter((file) => !EXEMPT_FILES.has(file))
    expect(files.flatMap(offendersIn)).toEqual([])
  })

  it('reads the files it claims to read', () => {
    // A guard on the walker: an empty list would pass by finding nothing.
    const files = sources()
    expect(files.length).toBeGreaterThan(500)
    expect(files).toContain('renderer/settings/sections/CopilotSection.tsx')
    expect(files).toContain('main/deck-control/copilot-admin-tools.ts')
    for (const file of EXEMPT_FILES.keys()) expect(files, file).toContain(file)
  })

  it('would catch the sentences it exists for', () => {
    expect(namesTheOldAssistant('The copilot is not running')).toBe(true)
    expect(namesTheOldAssistant('Copilot')).toBe(true)
    expect(namesTheOldAssistant('Settings → Copilot has the file itself.')).toBe(true)
    expect(namesTheOldAssistant('Ask the copilot on office-pc')).toBe(true)
    expect(namesTheOldAssistant('Copilot is driving')).toBe(true)
  })

  it('leaves identifiers and the real GitHub Copilot alone', () => {
    expect(namesTheOldAssistant('copilot')).toBe(false)
    expect(namesTheOldAssistant('copilot:state')).toBe(false)
    expect(namesTheOldAssistant('copilot.enabled')).toBe(false)
    expect(namesTheOldAssistant('anything under `copilot.`, `remote.` or `security.`')).toBe(false)
    expect(namesTheOldAssistant('opens Settings at a section ("general", "copilot", …)')).toBe(false)
    expect(namesTheOldAssistant('Install the GitHub Copilot CLI, then check again.')).toBe(false)
    expect(namesTheOldAssistant('Ask Hoot')).toBe(false)
  })

  it('keeps every exemption true', () => {
    // An exemption that no longer matches anything is an excuse outliving its
    // reason, and the next person reads it as precedent.
    const everything = sources().map((file) => readFileSync(join(SRC, file), 'utf8'))
    for (const allowed of EXEMPT.keys()) {
      expect(everything.some((text) => text.includes(allowed)), allowed).toBe(true)
    }
  })
})
