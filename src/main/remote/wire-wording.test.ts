import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The pattern guard for "this Mac" in something a phone reads.
 *
 * ## Why this is a scanning test and not another careful sweep
 *
 * `uploads.ts` states the rule in its header: every message in these files is
 * sealed up and read on a phone, one phone can be paired to several machines at
 * once — a Mac and a Windows PC, which is the arrangement this app has to be
 * correct for since tonight — and the phone already prints that machine's own
 * label beside anything it says. So "This Mac could not write that file" next to
 * a row reading `desktop-ddgmncv` is redundant at best and, on a Windows host,
 * simply false. Copy the *host* user reads may name the platform, and
 * `machineNoun()` in `platform/host.ts` is how; copy that crosses the wire names
 * nothing.
 *
 * The interesting fact is not the rule, it is the recurrence. `machineNoun()`
 * was written because "this Mac" appears in over a hundred sentences in the
 * remote code. It has now been swept three times by three different hands —
 * `tailnet.ts` first, then `uploads.ts`, then `server.ts` — and each pass
 * believed it had finished. `reachable.test.ts` could not catch any of it even
 * in principle, and neither could a code review, because there is nothing wrong
 * with the line: it is a correct sentence about the wrong computer.
 *
 * So it is scanned. A literal in one of these files may not name a platform.
 *
 * ## What is scanned, and what is deliberately not
 *
 * Only string literals, and only in the modules whose output crosses the sealed
 * channel. Comments are stripped first: prose explaining why a Mac behaves some
 * way is documentation, nobody reads it in a phone app, and forbidding the word
 * there would make this test an obstacle rather than a guard.
 *
 * The word list is the nouns a person would recognise as a platform claim.
 * `macOS`, `Windows` and `win32` survive when they are naming a *platform* to
 * code rather than to a person — `process.platform === 'win32'` is not a
 * sentence — which is why the check is on the words as words, inside quotes.
 */

const WIRE_MODULES = ['server.ts', 'uploads.ts', 'tunnel.ts', 'session-create.ts', 'credentials.ts']

/** Words that name the reader's computer, as a person would write them. */
const PLATFORM_NOUNS = /\b(Mac|Macs|MacBook|PC|iMac)\b/

/**
 * The file with comments removed.
 *
 * Line comments and whole-line block-comment bodies, which is every comment in
 * this codebase's style. A trailing `// …` after code is handled too. Nothing
 * here needs to be a parser: a false *negative* would let a string through, and
 * the only way that happens is a platform noun on the same line as something
 * that looks like a comment opener inside a string — which would be caught by
 * the reviewer this test exists to help rather than replace.
 */
function withoutComments(source: string): string[] {
  const lines: string[] = []
  let inBlock = false
  for (const raw of source.split('\n')) {
    const trimmed = raw.trim()
    if (inBlock) {
      if (trimmed.includes('*/')) inBlock = false
      continue
    }
    if (trimmed.startsWith('/*')) {
      if (!trimmed.includes('*/')) inBlock = true
      continue
    }
    if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue
    lines.push(raw.replace(/\/\/.*$/, ''))
  }
  return lines
}

/** Every single-quoted, double-quoted or template literal on a line. */
function literalsIn(line: string): string[] {
  return [...line.matchAll(/'([^'\\]*(?:\\.[^'\\]*)*)'|"([^"\\]*(?:\\.[^"\\]*)*)"|`([^`\\]*(?:\\.[^`\\]*)*)`/g)].map(
    (match) => match[1] ?? match[2] ?? match[3] ?? '',
  )
}

describe('nothing sent to a phone names the computer it came from', () => {
  for (const name of WIRE_MODULES) {
    it(`${name} has no platform noun in a string literal`, () => {
      const source = readFileSync(join(__dirname, name), 'utf8')
      const offenders: string[] = []
      for (const [index, line] of withoutComments(source).entries()) {
        for (const literal of literalsIn(line)) {
          if (PLATFORM_NOUNS.test(literal)) offenders.push(`${index + 1}: ${literal.slice(0, 120)}`)
        }
      }
      // The message names them, because the fix is to rewrite the sentence and
      // the person doing it needs to see which sentences.
      expect(offenders, `use machineNoun() host-side, or name nothing:\n${offenders.join('\n')}`).toEqual([])
    })
  }

  it('scans files that exist, so a rename cannot silently disable it', () => {
    // The failure this guards against is the guard itself going quiet: a module
    // renamed out from under the list leaves a passing test that reads nothing.
    for (const name of WIRE_MODULES) {
      expect(() => readFileSync(join(__dirname, name), 'utf8'), name).not.toThrow()
    }
  })

  it('catches the sentence it was written for', () => {
    // The rule has been swept three times and come back twice. A guard nobody
    // has watched fail is a guard nobody knows the shape of.
    const sample = ["      message: 'This Mac cannot start sessions from a phone.',"]
    const found = sample.flatMap((line) => literalsIn(line)).filter((text) => PLATFORM_NOUNS.test(text))
    expect(found).toEqual(['This Mac cannot start sessions from a phone.'])
  })

  it('leaves alone the places a platform genuinely is the subject', () => {
    // `machineNoun()` renders the word at runtime, so host-side copy passes
    // through here untouched — and a platform key is not a sentence.
    const allowed = [
      "      `This ${machineNoun()} could not save the key it needs.`,",
      "  if (platform === 'win32') return 'netstat+tasklist'",
      "  return isWindows(platform) ? 'PC' : 'Mac'",
    ]
    const flagged = allowed
      .slice(0, 2)
      .flatMap((line) => literalsIn(line))
      .filter((text) => PLATFORM_NOUNS.test(text))
    expect(flagged).toEqual([])
    // The third is `platform/host.ts`, which is where the two words are allowed
    // to be written down — it is not in WIRE_MODULES, and this asserts that the
    // pattern would otherwise catch it, so the exclusion is deliberate.
    expect(literalsIn(allowed[2]).filter((text) => PLATFORM_NOUNS.test(text))).toEqual(['PC', 'Mac'])
  })
})
