import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { SERVER_CONTROLS, controlsWith } from './server-scope'
import { SETTINGS } from '../settings-schema'

/**
 * The comparison itself, checked against the code it describes.
 *
 * A table of claims about other files is the easiest kind of documentation to
 * leave behind: nothing fails when it goes stale, and the sentence it produces
 * on somebody's screen goes on being printed long after it stopped being true.
 * These three checks are what make it a claim with a cost.
 */

const ROOT = join(__dirname, '..', '..', '..', '..')

describe('every control this window offers is answered for', () => {
  it('names every setting the schema declares, exactly once', () => {
    const claimed = SERVER_CONTROLS.flatMap((entry) => entry.mirrors)
    expect(new Set(claimed).size, 'a setting is claimed by two rows').toBe(claimed.length)

    const declared = SETTINGS.map((setting) => setting.id).sort()
    /*
     * The failure to read here is the *second* list being short: a settings row
     * was added and nothing said what it means for a server. Answering it is one
     * line in `server-scope.ts` — carried, cannot with a trace, app-wide, or a
     * control that answers it instead — and the answer is only obvious to the
     * person adding the row, on the day they add it.
     */
    expect([...claimed].sort()).toEqual(declared)
  })

  it('claims no setting the schema has dropped', () => {
    const declared = new Set(SETTINGS.map((setting) => setting.id))
    for (const entry of SERVER_CONTROLS) {
      for (const id of entry.mirrors) expect(declared.has(id), `${entry.local}: ${id}`).toBe(true)
    }
  })
})

describe('every reason a server cannot carry something is traced', () => {
  it('names a file and a string that is still in it', () => {
    const owed = [...controlsWith('cannot'), ...controlsWith('instead')]
    // The guard's own guard: a filter that stopped matching would pass this file
    // for ever by checking nothing at all.
    expect(owed.length).toBeGreaterThan(8)

    for (const entry of owed) {
      const trace = entry.traced
      expect(trace, `${entry.local} has no trace`).toBeDefined()
      if (trace === undefined) continue
      const path = join(ROOT, trace.file)
      expect(existsSync(path), `${entry.local}: ${trace.file} is gone`).toBe(true)
      /*
       * The interesting failure. When this goes red, the thing to do is *not* to
       * update the string — it is to read what that file says now and decide
       * whether the sentence on the Servers pane is still true.
       */
      expect(
        readFileSync(path, 'utf8').includes(trace.says),
        `${entry.local}: ${trace.file} no longer says ${JSON.stringify(trace.says)}`,
      ).toBe(true)
    }
  })

  it('leaves a carried control untraced only when the app itself carries it', () => {
    // Not a rule about tidiness: a `carried` row that names a file is claiming
    // *this* code makes it true, and those are the ones worth pinning. The rest
    // are carried by the server itself.
    for (const entry of controlsWith('carried')) {
      if (entry.traced === undefined) continue
      const path = join(ROOT, entry.traced.file)
      expect(existsSync(path), entry.local).toBe(true)
      expect(readFileSync(path, 'utf8').includes(entry.traced.says), entry.local).toBe(true)
    }
  })
})

describe('the sentences are the shape a pane can print', () => {
  /**
   * One sentence, not a paragraph.
   *
   * The window's own budget is 55 words for a standing paragraph and these are
   * meant to be shorter than that — they stand in for a control somebody was
   * looking for, and a reader who has to work through forty words to find out
   * that a switch is not there has been charged twice.
   */
  it('says each one in at most 30 words', () => {
    for (const entry of SERVER_CONTROLS) {
      const words = entry.say.trim().split(/\s+/).length
      expect(words, `${entry.local}: ${entry.say}`).toBeLessThanOrEqual(30)
    }
  })

  it('gives every row a sentence and a name', () => {
    for (const entry of SERVER_CONTROLS) {
      expect(entry.local).not.toBe('')
      expect(entry.say.endsWith('.'), entry.local).toBe(true)
    }
  })

  /**
   * The words the whole servers area is held to — `plain-words.test.ts` bans
   * them on the screens in `machines/servers`, and a sentence written here is
   * printed on one of those screens' subject even though it lives in a
   * different folder.
   */
  it('uses none of the words a person who has never signed in to a server would not know', () => {
    const banned = [/\bdaemons?\b/i, /\bPIDs?\b/, /\bsudo\b/i, /\bsystemd\b/i, /\bstd(out|err)\b/i]
    for (const entry of SERVER_CONTROLS) {
      for (const word of banned) {
        expect(word.test(entry.say), `${entry.local}: ${entry.say}`).toBe(false)
      }
    }
  })
})
