/**
 * One sentence, written where the action is implemented, rendered by three
 * surfaces.
 *
 * `SERVERS-DESIGN.md` §4.3, and the reason is already written down one
 * directory over. `remote/copilot-consent.ts`, on why a client may never
 * compose a consent sentence:
 *
 * > A client that wrote its own sentence *"would be describing an action it did
 * > not implement, and the first time the two drifted somebody would approve
 * > one thing having read another."*
 *
 * The three surfaces here are the confirmation dialog, the action log, and the
 * copilot's consent question. All three render {@link ServerAction.summary};
 * none of them builds a sentence. The failure this guards against is not a
 * compile error and not a wrong result — it is a renderer growing its own copy
 * of *"it'll be offline for about five seconds"*, which is correct on the day
 * it is typed and silently wrong the first time the action's timing or its way
 * back changes.
 *
 * So this is a string-matching test across files, which is the class of problem
 * `src/preload/contract.test.ts` exists for and which a compiler cannot see.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { SERVER_ACTIONS, ACTION_IDS, previewOf } from './actions'
import { containerCard, facts, repoCard, siteCard } from './test-fixtures'

const ROOT = join(__dirname, '..', '..')

function filesUnder(dir: string, match: RegExp, acc: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) filesUnder(path, match, acc)
    else if (match.test(entry.name)) acc.push(path)
  }
  return acc
}

/**
 * The distinctive halves of every consequence sentence.
 *
 * Fragments rather than whole sentences, because a whole sentence contains the
 * person's own name for the thing and would therefore never match anywhere.
 * Each of these is the part that carries the *claim* — the timing, or the
 * promise of a way back — which is the part that must not be duplicated.
 */
const FRAGMENTS: readonly string[] = [
  'It’ll be running again in a few seconds.',
  'It’ll be offline for about five seconds while it starts again.',
  'It’ll be off until you start it again',
  'We’ll keep the current version so you can go back.',
  'We’ll remember where it is now so you can go back.',
  'Copy everything in',
  'Nothing on the server changes.',
  'This can take a minute or two.',
]

describe('the consequence sentence is written where the action is implemented', () => {
  it('composes every sentence in the action layer', () => {
    const source = readFileSync(join(__dirname, 'actions.ts'), 'utf8')
    for (const fragment of FRAGMENTS) {
      expect(source, `${fragment} is not written in actions.ts`).toContain(fragment)
    }
  })

  it('never lets a renderer compose one', () => {
    /*
     * The renderer's job is `preview.sentence` — a string it was handed. A hit
     * here means somebody has typed a consequence into a component, and the two
     * copies will disagree the first time either changes.
     */
    const offenders: string[] = []
    for (const path of filesUnder(join(ROOT, 'renderer'), /\.tsx?$/)) {
      const text = readFileSync(path, 'utf8')
      for (const fragment of FRAGMENTS) {
        if (text.includes(fragment)) offenders.push(`${path.slice(ROOT.length + 1)} → ${fragment}`)
      }
    }
    expect(offenders).toEqual([])
  })

  it('gives every action a sentence, and never an empty one', () => {
    const targets = [
      { serverId: 's1', card: repoCard(), facts: facts() },
      { serverId: 's1', card: containerCard(), facts: facts() },
      { serverId: 's1', card: siteCard(), facts: facts() },
    ]
    for (const id of ACTION_IDS) {
      for (const target of targets) {
        const sentence = SERVER_ACTIONS[id].summary(target)
        expect(sentence.length, `${id} has no sentence`).toBeGreaterThan(4)
        // It names the thing, so somebody reading it in a log a week later
        // knows what it was about.
        expect(sentence, `${id} does not name what it acts on`).toContain(target.card.name)
      }
    }
  })

  it('hands the preview the same string the action wrote', () => {
    // The dialog draws `preview.sentence` and the copilot's consent question
    // draws `summary()`. If those two were built separately they would be two
    // sentences about one action.
    const target = { serverId: 's1', card: repoCard(), facts: facts() }
    for (const id of ACTION_IDS) {
      expect(previewOf(id, target).sentence).toBe(SERVER_ACTIONS[id].summary(target))
    }
  })

  it('says what will be written down before a kept action changes anything', () => {
    // "What will happen, to what, and for how long" — plus, for the kept class,
    // what is being kept. A person approving an update is owed the fact that a
    // copy is being taken, not only the fact that one could be.
    const database = previewOf('update', { serverId: 's1', card: containerCard({ engine: 'postgres' }), facts: facts() })
    expect(database.klass).toBe('kept')
    expect(database.keeps).toMatch(/copy of everything in this database/i)
    expect(database.sentence).toMatch(/copy everything in it to your computer first/i)

    const plain = previewOf('update', { serverId: 's1', card: containerCard(), facts: facts() })
    expect(plain.keeps).toMatch(/the version that is running now/i)
    expect(plain.wayBack).toBe('Go back to the previous version')
  })

  it('never invents a number for a step whose length it cannot know', () => {
    /*
     * §4.4. A pull over a link this app has never measured is not "about ten
     * seconds", and a person who planned around that number is worse off than
     * one who read "a minute or two".
     */
    const database = previewOf('update', { serverId: 's1', card: containerCard({ engine: 'postgres' }), facts: facts() })
    expect(database.sentence).not.toMatch(/about \w+ seconds/i)
    expect(database.sentence).toMatch(/a minute or two/i)
  })
})
