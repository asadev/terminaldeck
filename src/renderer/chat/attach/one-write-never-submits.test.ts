import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, sep } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * No composer in this app sends a message as one write with a `\r` on the end.
 *
 * ## The defect, and why a unit test of the helper was not enough
 *
 * `mentions.ts` has carried the measurement since the attach menu was built: the
 * CLI classifies each stdin chunk before it looks at the keys in it, and a chunk
 * of **64 bytes or more is pasted text**, where a carriage return is a newline
 * rather than submit. `terminalWrites` exists to be the correct sequence and had
 * a passing test.
 *
 * Every chat composer in the app ignored it anyway. On 2026-08-22, driving the
 * packed build, a 145-character message typed into chat mode was written as
 * `writeToSession(id, text + '\r')`, arrived in Claude Code's input box, and the
 * cursor dropped to the next line. Nothing was submitted, so nothing was ever
 * written to the transcript, so the chat pane — correctly — showed nothing new.
 * That is the whole of the report this file is named after:
 *
 *   > "when we send our message mostly it is page still stays blank"
 *
 * *Mostly*, and the word is the diagnosis: short messages went through and
 * anything past half a line did not. Four call sites had the same line —
 * `App.tsx`, `ServerChatPane`, `CopilotView` and `DriveHost` — which is what a
 * rule that lives only in a comment costs.
 *
 * ## What this checks
 *
 * The failing *shape*, across the whole renderer: a write into a session whose
 * argument is a template literal ending in `\r`. `sendToTerminal` is the only
 * way to send a message, and it splits the two writes with a real gap.
 *
 * Deliberately not a check on the helper's behaviour — `mentions.test.ts` owns
 * that. This one is about the thing the helper could not prevent: somebody
 * writing the one-liner again, three files away, where it looks obviously right.
 */

const RENDERER = resolve(__dirname, '..', '..')

/** Every `.ts`/`.tsx` under the renderer that is not a test. */
function sources(dir: string, found: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === 'assets') continue
    const path = join(dir, entry)
    if (statSync(path).isDirectory()) {
      sources(path, found)
      continue
    }
    if (!/\.tsx?$/.test(entry)) continue
    if (/\.test\.tsx?$/.test(entry)) continue
    found.push(path)
  }
  return found
}

/**
 * A single write that ends in a carriage return.
 *
 * `write…(<anything>, `…${…}…\r`)` on one line. The name is matched loosely —
 * `writeToSession`, `writeToServerShell`, `writeToMachineSession` and any
 * future sibling — because the mistake is about the *shape* of the argument and
 * not about which transport carries it.
 */
const ONE_WRITE_SUBMIT = /\bwrite[A-Za-z]*\s*\([^)]*`[^`]*\$\{[^`]*\}\\r`/

/**
 * The one place this shape is allowed, and why.
 *
 * `ServerTerminal` opens an SSH shell and types the command it was opened to
 * run at that shell's prompt. It is not a message to an agent, and the 64-byte
 * rule is Claude Code's own stdin classifier rather than anything a shell does —
 * so the single write is not known to be broken there. It is listed rather than
 * quietly excluded by a narrower pattern, because "not known to be broken" is a
 * different claim from "checked", and this one has not been driven against a
 * real server. A long `runCommand` on a shell with bracketed paste turned on is
 * the case that would prove it either way.
 */
const ALLOWED = new Set(['machines/servers/ServerTerminal.tsx:476'])

describe('a message is never sent as one write', () => {
  it('has no composer appending a carriage return to a template', () => {
    const offenders: string[] = []
    for (const path of sources(RENDERER)) {
      const text = readFileSync(path, 'utf8')
      // `/\r?\n/`, not `'\n'`. Git checks this repository out with CRLF on
      // Windows, so splitting on the newline alone leaves a `\r` on the end of
      // EVERY line — and this case hunts for a `\r` on the end of a line. It
      // matched all of them and failed the Windows job while macOS stayed green.
      for (const [index, line] of text.split(/\r?\n/).entries()) {
        // A line of prose describing the defect is not the defect. Comments are
        // where this rule is explained, so they have to be allowed to quote it.
        const code = line.replace(/^\s*(\/\/|\*|\/\*).*$/, '')
        if (!ONE_WRITE_SUBMIT.test(code)) continue
        // Forward slashes, always. `join` builds these with the host's own
        // separator, so on Windows the same file reports as
        // `machines\servers\ServerTerminal.tsx` and misses an ALLOWED entry
        // written the POSIX way — the exception silently stops applying and
        // only the Windows job fails.
        const where = `${path.slice(RENDERER.length + 1).split(sep).join('/')}:${index + 1}`
        if (!ALLOWED.has(where)) offenders.push(where)
      }
    }
    expect(offenders).toEqual([])
  })

  it('would catch the line that shipped', () => {
    // The exact text that was in `App.tsx`, so a change to the pattern that
    // stopped matching it would fail here rather than pass silently.
    expect(ONE_WRITE_SUBMIT.test('window.deck.writeToSession(session.id, `${text}\\r`)')).toBe(true)
    expect(ONE_WRITE_SUBMIT.test('void bridge.writeToServerShell(shellId, `${text}\\r`)')).toBe(true)
  })

  it('keeps the exception honest by naming it', () => {
    // If that line moves or goes away, this fails and somebody has to decide
    // again rather than inheriting a stale exemption.
    const [file, line] = [...ALLOWED][0].split(':')
    const text = readFileSync(join(RENDERER, file), 'utf8').split(/\r?\n/)[Number(line) - 1]
    expect(ONE_WRITE_SUBMIT.test(text)).toBe(true)
    expect(text).toContain('runCommand')
  })

  it('leaves the correct form alone', () => {
    expect(ONE_WRITE_SUBMIT.test('void sendToTerminal(text, (data) => write(id, data))')).toBe(false)
    // And a control sequence that is genuinely one keystroke, which is what a
    // write of a bare `\r` is.
    expect(ONE_WRITE_SUBMIT.test("write(id, '\\r')")).toBe(false)
  })
})
