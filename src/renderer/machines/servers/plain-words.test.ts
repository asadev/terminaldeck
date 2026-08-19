import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Nothing on these screens describes the mechanism to somebody who does not
 * already know it.
 *
 * ## The rule, in his words
 *
 * > *"User friendly with a smooth and simple user experience for non technical
 * > people who knows nothing about server."*
 *
 * So the words below never reach a screen in this area: `daemon`, `unit`,
 * `process`, `PID`, `sudo`, `root`, `systemd`, `stdout`, `SIGTERM`, `port`. Each
 * of them is precise, each of them is what the thing is actually called, and
 * each of them tells a person who does not already know exactly nothing.
 *
 * ## What is *not* banned, and why the line is there
 *
 * A real program's name may appear — *Served by nginx*, *Running in a
 * container*. `neutral-naming.test.ts` draws this line for the whole app and its
 * argument is the one this area needs: the rule *"bans naming a vendor while
 * describing a mechanism any vendor could serve; naming the vendor you are
 * actually talking to is not that."*
 *
 * So the **card** speaks in the person's words and the **detail line under it**
 * names what was actually found on their machine. Naming a thing we measured is
 * honesty and they are entitled to it. Naming a thing we assumed is the bug this
 * whole area is arranged against. That is also why those detail lines are
 * written on the other side of the bridge, where the measuring happens — none of
 * them are in the files this test reads.
 *
 * ## Why a test and not a careful afternoon
 *
 * Because copy rots one sentence at a time, and the sentence that reintroduces
 * `systemd` will be added by somebody debugging a real problem, for whom the
 * word is the clearest one available. It is the clearest one for them.
 */

const HERE = __dirname
const AREA = [
  ...readdirSync(HERE)
    .filter((name) => /\.tsx?$/.test(name) && !name.includes('.test.'))
    .map((name) => join(HERE, name)),
  // The umbrella that mounts all of it, and the only file outside this folder
  // that writes copy for this area.
  join(HERE, '..', 'MachinesPanel.tsx'),
]

/**
 * Source with its comments removed.
 *
 * A comment is the one part of a file that never reaches a screen, which is why
 * every explanation in this codebase is free to name whatever it needs to. This
 * strips block comments — which is what a JSX comment is — and whole-line `//`
 * ones, exactly as `reachable.test.ts` does for the same reason.
 */
function withoutComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')
}

/** Three alphabetic words in a row: the shape of a sentence rather than a type. */
const PROSE = /[A-Za-z]{2,}[^A-Za-z]+[A-Za-z]{2,}[^A-Za-z]+[A-Za-z]{2,}/

/**
 * Everything in a file that a person could read.
 *
 * Two nets, and the second is the one that matters: text between JSX tags is
 * the obvious half, and quoted strings that read like sentences catch the copy
 * nobody thought to route through a named prop — which is most of it. A class
 * name has no two spaces in it and a type has no three words in a row, so
 * neither is collected.
 */
function copyIn(file: string): string[] {
  const source = withoutComments(readFileSync(file, 'utf8'))
  const found: string[] = []
  if (file.endsWith('.tsx')) {
    for (const [, between] of source.matchAll(/>([^<>{}]+)</g)) {
      if (PROSE.test(between)) found.push(between)
    }
  }
  for (const [, literal] of source.matchAll(/'([^'\\\n]+)'/g)) {
    if (PROSE.test(literal)) found.push(literal)
  }
  for (const [, literal] of source.matchAll(/"([^"\\\n]+)"/g)) {
    if (PROSE.test(literal)) found.push(literal)
  }
  return found
}

const COPY = AREA.flatMap((file) => copyIn(file).map((text) => ({ file, text })))

describe('the words a person reads on these screens', () => {
  it('collected something, so a green result means the rule held rather than that nothing was read', () => {
    // The failure mode of every source-scanning guard: the collector breaks, it
    // finds nothing, and it passes forever.
    expect(COPY.length).toBeGreaterThan(30)
  })

  const BANNED = [
    /\bdaemons?\b/i,
    /\bunit files?\b/i,
    /\bprocess(es)?\b/i,
    /\bPIDs?\b/,
    /\bsudo\b/i,
    /\broot\b/i,
    /\bsystemd\b/i,
    /\bopenrc\b/i,
    /\bstd(out|err)\b/i,
    /\bSIG[A-Z]+\b/,
    /\bports?\b/i,
    /\bSSH\b/i,
    /\bhost keys?\b/i,
    /\bauthenticat(e|ion|ed)\b/i,
    /\bcredentials?\b/i,
  ]

  for (const pattern of BANNED) {
    it(`never says ${String(pattern)}`, () => {
      const offenders = COPY.filter((entry) => pattern.test(entry.text)).map(
        (entry) => `${entry.file}: ${entry.text.trim()}`,
      )
      expect(offenders).toEqual([])
    })
  }
})

/**
 * No sentence describing what an action will do is written on this side.
 *
 * Every one of them is composed in the main process, beside the code that
 * performs the action, and arrives on `CardAction.summary`. The same string is
 * rendered in three places — the confirmation, the action log, and the
 * copilot's consent question — and a client that wrote its own would be
 * describing an action it did not implement. The first time the two drifted,
 * somebody would approve one thing having read another.
 */
describe('consequence sentences are not composed here', () => {
  it('never builds one', () => {
    const shapes = [
      /it'?ll be (offline|back|running)/i,
      /be offline for/i,
      /about (a |one |two |five |ten |\d+ )?seconds?/i,
      /we'?ll (keep|remember|record)/i,
      /so you can go back/i,
    ]
    const offenders = COPY.filter((entry) => shapes.some((shape) => shape.test(entry.text))).map(
      (entry) => `${entry.file}: ${entry.text.trim()}`,
    )
    expect(offenders).toEqual([])
  })

  it('only ever reads a summary, never assigns one', () => {
    /*
     * Structural rather than by example, because the hole this guards is a
     * *second* code path somebody adds later. `summary` may be declared once, as
     * a field on the mirrored type, and read anywhere; a file that writes one
     * into an object is a file composing copy for an action it does not run.
     */
    const writers = AREA.filter((file) => !file.endsWith('types.ts')).filter((file) =>
      /\bsummary\s*:/.test(withoutComments(readFileSync(file, 'utf8'))),
    )
    expect(writers).toEqual([])
  })
})
