/**
 * The rule that keeps the second half of his sentence, pinned.
 *
 * > *"Every action is a sentence with a consequence, and nothing destructive
 * > happens without a way back."*
 *
 * `SERVERS-DESIGN.md` §4.1 turns that into a mechanism rather than a promise:
 * three classes, no fourth, and the `kept` class records what it takes to go
 * back **before** it changes anything and refuses to proceed if it could not.
 * Anything genuinely irreversible is absent from the list rather than guarded
 * by a scarier dialog, because — as `deck-control/catalogue.ts` already records
 * — a refusal that arrives after a run of harmless confirmations *"has already
 * trained them to click yes."*
 *
 * This file fails if any of that is undone: a fourth class, a `kept` action
 * with no `keep`, a `kept` action that reaches the server when the record could
 * not be written, or a deletion appearing in the catalogue.
 */

import { describe, expect, it, vi } from 'vitest'
import {
  ACTION_CLASSES,
  ACTION_IDS,
  ActionRefused,
  MemoryJournal,
  perform,
  SERVER_ACTIONS,
  type ActionDeps,
  type ActionTarget,
  type CommandResult,
  type WayBack,
  type WayBackJournal,
} from './actions'
import { cmd, containerCard, facts, repoCard } from './test-fixtures'

function runner(results: Record<string, CommandResult> = {}): {
  run: ActionDeps['run']
  calls: string[][]
} {
  const calls: string[][] = []
  const run: ActionDeps['run'] = async (_serverId, argv) => {
    calls.push([...argv])
    const key = argv.join(' ')
    for (const [prefix, result] of Object.entries(results)) {
      if (key.includes(prefix)) return result
    }
    return cmd()
  }
  return { run, calls }
}

describe('the three classes, and no fourth', () => {
  it('gives every action one of exactly three classes', () => {
    for (const id of ACTION_IDS) {
      expect(ACTION_CLASSES, `${id} has a class outside the three`).toContain(SERVER_ACTIONS[id].klass)
    }
  })

  it('ships no action that deletes anything', () => {
    /*
     * §7: deleting a site, an app, a database or a file is out of scope for v1
     * because none of them has a way back. The guard is on the *name* as well
     * as on the class, because the way this rule decays is somebody adding a
     * `remove` that they have classed as `reversible` on the grounds that you
     * could always put it back by hand.
     */
    for (const id of ACTION_IDS) {
      expect(id).not.toMatch(/delete|remove|destroy|purge|drop|wipe|reset/)
    }
  })

  it('gives every kept action a way of recording the way back', () => {
    for (const id of ACTION_IDS) {
      const action = SERVER_ACTIONS[id]
      if (action.klass !== 'kept') continue
      expect(action.keep, `${id} is kept but records nothing`).toBeTypeOf('function')
    }
  })

  it('names the button that puts it back in every reversible action’s own sentence', () => {
    // §4.1: "one press puts it back exactly as it was, and the button that does
    // it is named in the confirmation." A reversible action whose sentence does
    // not say how to undo it is a reversible action nobody knows is reversible.
    const target: ActionTarget = { serverId: 's1', card: repoCard(), facts: facts() }
    expect(SERVER_ACTIONS.stop.summary(target)).toMatch(/start it again/i)
    expect(SERVER_ACTIONS['go-back'].summary(target)).toMatch(/Update will bring it forward again/i)
  })
})

describe('a kept action cannot run without having recorded its way back', () => {
  const target = (): ActionTarget => ({ serverId: 's1', card: repoCard(), facts: facts() })

  it('does not touch the server when the record cannot be written', async () => {
    const { run, calls } = runner({ 'rev-parse HEAD': cmd({ stdout: 'a'.repeat(40) }) })
    const journal: WayBackJournal = {
      put: vi.fn(async () => {
        throw new Error('disk full')
      }),
      get: async () => null,
      clear: async () => undefined,
    }

    await expect(perform({ run, journal }, 'update', target())).rejects.toBeInstanceOf(ActionRefused)

    /*
     * The assertion that matters is not the rejection — it is that nothing
     * that *changes* the server ran. `keep` legitimately reads (status,
     * rev-parse); a `fetch` or a `merge` in this list would mean the way back
     * failed after the change, which is the one ordering this class exists to
     * forbid.
     */
    const changed = calls.filter((argv) => argv.includes('fetch') || argv.includes('merge'))
    expect(changed).toEqual([])
  })

  it('does not touch the server when the record cannot be read back', async () => {
    // A write that silently did nothing is indistinguishable from one that
    // worked, right up to the moment somebody needs it. So the record is read
    // back before anything changes.
    const { run, calls } = runner({ 'rev-parse HEAD': cmd({ stdout: 'b'.repeat(40) }) })
    const journal: WayBackJournal = {
      put: async () => undefined,
      get: async () => null,
      clear: async () => undefined,
    }

    await expect(perform({ run, journal }, 'update', target())).rejects.toBeInstanceOf(ActionRefused)
    expect(calls.filter((argv) => argv.includes('merge'))).toEqual([])
  })

  it('records the exact version before it changes anything, in that order', async () => {
    const journal = new MemoryJournal()
    const seen: string[] = []
    const run: ActionDeps['run'] = async (_serverId, argv) => {
      seen.push(argv.join(' '))
      if (argv.includes('rev-parse')) return cmd({ stdout: `${'c'.repeat(40)}\n` })
      return cmd()
    }

    const outcome = await perform({ run, journal }, 'update', target())

    const kept = (await journal.get('s1', repoCard().id)) as WayBack
    expect(kept.kind).toBe('repo-commit')
    expect(kept.kind === 'repo-commit' && kept.commit).toBe('c'.repeat(40))
    // Recorded strictly before the fetch that changes it.
    expect(seen.findIndex((line) => line.includes('rev-parse'))).toBeLessThan(
      seen.findIndex((line) => line.includes('fetch')),
    )
    expect(outcome.wayBack?.actionId).toBe('go-back')
  })

  it('refuses to update a checkout somebody has hand-edited', async () => {
    /*
     * A dirty checkout has no way back: `git reset --hard` to the recorded
     * commit would destroy the edit. Stashing it would be this app deciding
     * what happens to somebody's work on their own server. So the update does
     * not happen, and the sentence says why.
     */
    const { run, calls } = runner({ 'status --porcelain': cmd({ stdout: ' M app.js\n' }) })
    await expect(perform({ run, journal: new MemoryJournal() }, 'update', target())).rejects.toThrow(
      /changed this on the server itself/i,
    )
    expect(calls.filter((argv) => argv.includes('merge'))).toEqual([])
  })

  it('refuses to update a database it cannot copy first', async () => {
    /*
     * The way back for a container update restores the *program*. It does
     * nothing about a migration the new version ran over the data on its way
     * up. So a database whose contents cannot be copied first has no complete
     * way back, and §4.1 says an action without one does not ship.
     */
    const card = containerCard({ engine: 'postgres' })
    const { run, calls } = runner()
    await expect(
      // No `download`, so no copy is possible on this build.
      perform({ run, journal: new MemoryJournal() }, 'update', { serverId: 's1', card, facts: facts() }),
    ).rejects.toThrow(/can’t copy files off a server/i)
    expect(calls.filter((argv) => argv.includes('pull'))).toEqual([])
  })
})
