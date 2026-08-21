import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  anchorsByTab,
  ARRANGEMENT_KEY,
  nextArrangement,
  readArrangement,
  sameArrangement,
  seedArrangement,
  sessionAnchor,
  tabsByAnchor,
  writeArrangement,
  type AnchoredTab,
} from './strip-arrangement'
import { MAX_PROMOTED } from './workspace-strip'

/**
 * The strip's arrangement, across a restart it cannot see.
 *
 * Every test here is written from the two ends of a quit: what the last run
 * wrote down, and what this run makes of it once the sessions come back with
 * new ids. That is the only shape in which the thing under test is worth
 * anything — a function that turns tabs into strings is trivially right and
 * proves nothing about whether somebody's bar comes back.
 */

/** A store with the memory of a real one and none of the environment. */
function store(seed: Record<string, string> = {}): Storage {
  const held = new Map<string, string>(Object.entries(seed))
  return {
    get length() {
      return held.size
    },
    clear: () => held.clear(),
    getItem: (key: string) => held.get(key) ?? null,
    key: (index: number) => [...held.keys()][index] ?? null,
    removeItem: (key: string) => {
      held.delete(key)
    },
    setItem: (key: string, value: string) => {
      held.set(key, value)
    },
  } as Storage
}

const tab = (id: string, anchor?: string): AnchoredTab =>
  anchor === undefined ? { id } : { id, anchor }

const claude = (folder: string, profile?: string): string =>
  sessionAnchor({ provider: 'claude', cwd: folder, profileId: profile })

describe('sessionAnchor', () => {
  it('separates the three fields with something no field can contain', () => {
    // Provider `a` + folder `b/c` and provider `a/b` + folder `c` are different
    // sessions; joined on any character a path may hold they are one string.
    const one = sessionAnchor({ provider: 'claude', cwd: 'b/c' })
    const two = sessionAnchor({ provider: 'claude/b' as 'claude', cwd: 'c' })
    expect(one).not.toBe(two)
    expect(one).toContain('\u0000')
  })

  it('tells two accounts in one folder apart', () => {
    expect(claude('/w', 'work')).not.toBe(claude('/w', 'home'))
  })

  it('treats no account as its own answer rather than as a default', () => {
    expect(claude('/w')).toBe(claude('/w', undefined))
    expect(claude('/w')).not.toBe(claude('/w', 'work'))
  })
})

describe('anchorsByTab', () => {
  it('numbers two tabs of the same agent in the same folder apart', () => {
    const anchors = anchorsByTab([tab('s1', claude('/w')), tab('s2', claude('/w'))])
    expect(anchors.get('s1')).not.toBe(anchors.get('s2'))
  })

  it('leaves out everything a restart does not bring back', () => {
    // A browser page, a session on a paired machine, a shell on a server.
    const anchors = anchorsByTab([tab('b1'), tab('m:host:9'), tab('s1', claude('/w'))])
    expect([...anchors.keys()]).toEqual(['s1'])
  })

  it('gives the same tab the same anchor on both sides of a restart', () => {
    const before = anchorsByTab([tab('s1', claude('/w')), tab('s2', claude('/x'))])
    // Same tabs, new run, new ids.
    const after = anchorsByTab([tab('s7', claude('/w')), tab('s9', claude('/x'))])
    expect(after.get('s7')).toBe(before.get('s1'))
    expect(after.get('s9')).toBe(before.get('s2'))
  })

  it('reads back the other way for a restore', () => {
    const anchors = anchorsByTab([tab('s1', claude('/w'))])
    expect(tabsByAnchor(anchors).get(anchors.get('s1') ?? '')).toBe('s1')
  })
})

describe('nextArrangement', () => {
  const anchors = (...tabs: AnchoredTab[]) => anchorsByTab(tabs)

  it('writes the promoted order down in anchors', () => {
    const map = anchors(tab('s1', claude('/a')), tab('s2', claude('/b')))
    const out = nextArrangement(['s2', 's1'], map, [], new Set(['s1', 's2']))
    expect(out).toEqual([map.get('s2'), map.get('s1')])
  })

  it('keeps an anchor whose tab has not arrived yet', () => {
    // The launch hazard `pruneOrder` was measured against, in the other list: a
    // wave of sessions lands, and the ones still on their way must not be
    // written out of the arrangement in the meantime.
    const waiting = `${claude('/late')}\u00000`
    const map = anchors(tab('s1', claude('/a')))
    const out = nextArrangement(['s1'], map, [waiting], new Set(['s1']))
    expect(out).toEqual([map.get('s1'), waiting])
  })

  it('drops an anchor whose tab arrived and was folded away', () => {
    // Not the same as the case above and the difference is the whole guard: the
    // tab is here, the person took it off the bar, and that is a current fact.
    const map = anchors(tab('s1', claude('/a')), tab('s2', claude('/b')))
    const folded = map.get('s2') ?? ''
    const out = nextArrangement(['s1'], map, [map.get('s1') ?? '', folded], new Set(['s1', 's2']))
    expect(out).toEqual([map.get('s1')])
  })

  it('puts the live ones ahead of the ones still unaccounted for', () => {
    const waiting = `${claude('/gone')}\u00000`
    const map = anchors(tab('s1', claude('/a')))
    const out = nextArrangement(['s1'], map, [waiting, map.get('s1') ?? ''], new Set(['s1']))
    expect(out[0]).toBe(map.get('s1'))
  })

  it('never grows past the cap, however many runs never resolved', () => {
    const stale = Array.from({ length: 40 }, (_, index) => `${claude('/gone')}\u0000${index}`)
    const map = anchors(tab('s1', claude('/a')))
    const out = nextArrangement(['s1'], map, stale, new Set(['s1']))
    expect(out).toHaveLength(MAX_PROMOTED)
    expect(out[0]).toBe(map.get('s1'))
  })

  it('ignores a promoted id that has no anchor', () => {
    // A browser page is drawn in the strip whether or not anything promoted it,
    // so it has nothing to come back to and nothing to write down.
    const map = anchors(tab('s1', claude('/a')))
    expect(nextArrangement(['b1', 's1'], map, [], new Set(['b1', 's1']))).toEqual([map.get('s1')])
  })
})

describe('seedArrangement', () => {
  it('puts the bar back after a restart, in the order it was left', () => {
    const before = anchorsByTab([tab('s1', claude('/a')), tab('s2', claude('/b'))])
    const saved = [before.get('s2') ?? '', before.get('s1') ?? '']

    // Next launch: same two sessions, new ids, in the order the ledger restores
    // them rather than the order they were arranged in.
    const now = anchorsByTab([tab('n1', claude('/a')), tab('n2', claude('/b'))])
    expect(seedArrangement([], saved, now, new Set(['n1', 'n2']))).toEqual(['n2', 'n1'])
  })

  it('lands a tab that arrives late between the neighbours it was saved between', () => {
    const anchors = anchorsByTab([
      tab('n1', claude('/a')),
      tab('n2', claude('/b')),
      tab('n3', claude('/c')),
    ])
    const saved = [anchors.get('n1') ?? '', anchors.get('n2') ?? '', anchors.get('n3') ?? '']

    // First wave: the outer two.
    const first = seedArrangement([], saved, anchors, new Set(['n1', 'n3']))
    expect(first).toEqual(['n1', 'n3'])
    // Second wave: the middle one, which must not simply go on the end.
    expect(seedArrangement(first, saved, anchors, new Set(['n2']))).toEqual(['n1', 'n2', 'n3'])
  })

  it('leaves a tab alone once it has been seen, so folding one away sticks', () => {
    const anchors = anchorsByTab([tab('n1', claude('/a'))])
    const saved = [anchors.get('n1') ?? '']
    // Not arriving any more: the window has seen it, and the person took it off.
    expect(seedArrangement([], saved, anchors, new Set())).toEqual([])
  })

  it('never promotes the same tab twice', () => {
    const anchors = anchorsByTab([tab('n1', claude('/a'))])
    const saved = [anchors.get('n1') ?? '', anchors.get('n1') ?? '']
    expect(seedArrangement([], saved, anchors, new Set(['n1']))).toEqual(['n1'])
  })

  it('skips an anchor nothing came back for', () => {
    const anchors = anchorsByTab([tab('n1', claude('/a'))])
    const gone = `${claude('/unmounted')}\u00000`
    expect(seedArrangement([], [gone, anchors.get('n1') ?? ''], anchors, new Set(['n1']))).toEqual([
      'n1',
    ])
  })

  it('refuses at the cap rather than evicting a tab already on the bar', () => {
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    const anchors = anchorsByTab([tab('n1', claude('/a'))])
    const out = seedArrangement(full, [anchors.get('n1') ?? ''], anchors, new Set(['n1']))
    expect(out).toEqual(full)
  })

  it('adds nothing when there is no saved arrangement', () => {
    const anchors = anchorsByTab([tab('n1', claude('/a'))])
    expect(seedArrangement(['b1'], [], anchors, new Set(['n1']))).toEqual(['b1'])
  })
})

describe('sameArrangement', () => {
  it('is order-sensitive, because the order is the whole of it', () => {
    expect(sameArrangement(['a', 'b'], ['a', 'b'])).toBe(true)
    expect(sameArrangement(['a', 'b'], ['b', 'a'])).toBe(false)
    expect(sameArrangement(['a'], ['a', 'b'])).toBe(false)
  })
})

describe('storage', () => {
  it('survives the round trip', () => {
    const disk = store()
    writeArrangement(disk, ['one', 'two'])
    expect(readArrangement(disk)).toEqual(['one', 'two'])
    expect(disk.getItem(ARRANGEMENT_KEY)).toBe(JSON.stringify(['one', 'two']))
  })

  it('answers an empty arrangement for anything it cannot read', () => {
    expect(readArrangement(null)).toEqual([])
    expect(readArrangement(store())).toEqual([])
    expect(readArrangement(store({ [ARRANGEMENT_KEY]: 'not json' }))).toEqual([])
    expect(readArrangement(store({ [ARRANGEMENT_KEY]: '{"a":1}' }))).toEqual([])
    expect(readArrangement(store({ [ARRANGEMENT_KEY]: '[1,null,"a",""]' }))).toEqual(['a'])
  })

  it('bounds what it will read back, whatever is on disk', () => {
    const many = JSON.stringify(Array.from({ length: 200 }, (_, index) => `a${index}`))
    expect(readArrangement(store({ [ARRANGEMENT_KEY]: many }))).toHaveLength(MAX_PROMOTED)
  })

  it('does not throw when the store refuses to be written to', () => {
    const refusing = {
      getItem: () => null,
      setItem: () => {
        throw new Error('quota')
      },
    } as unknown as Storage
    expect(() => writeArrangement(refusing, ['one'])).not.toThrow()
    expect(() => writeArrangement(null, ['one'])).not.toThrow()
  })
})

/* ------------------------------------------------------------- the wiring -- */

/**
 * The half no pure function can hold: that somebody calls these, on the two
 * events that make them mean anything.
 *
 * Read as source rather than rendered, because both claims are about *when* —
 * the seeding must happen before the window has seen a tab, and the write must
 * happen after the prune — and neither is visible in a snapshot of a bar.
 */
describe('the strip is wired to it', () => {
  const strip = readFileSync(join(__dirname, 'WorkspaceTabStrip.tsx'), 'utf8')
  const app = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

  it('gives every local session tab something that outlives its pty', () => {
    const built = /const windowTab = \(session: Session\): WorkspaceTab => \(\{[\s\S]*?\n {2}\}\)/.exec(app)?.[0] ?? ''
    expect(built, 'windowTab has changed shape').not.toBe('')
    expect(built).toContain('anchor: sessionAnchor(session)')
  })

  it('seeds before it marks a tab as seen, or it would seed nothing', () => {
    // `arriving` is the difference between "this tab has just turned up" and
    // "this tab is here" — computed against `seen` and therefore only correct
    // while `seen` still predates this render.
    const seed = strip.indexOf('seedArrangement(')
    const mark = strip.indexOf('seen.current.add(tab.id)\n    const pruned')
    expect(seed).toBeGreaterThan(0)
    expect(mark).toBeGreaterThan(0)
    expect(seed).toBeLessThan(mark)
  })

  it('writes the arrangement after the prune, so what is saved is what is on the bar', () => {
    const prune = strip.indexOf('const pruned = pruneOrder(')
    const write = strip.indexOf('const next = nextArrangement(')
    expect(prune).toBeGreaterThan(0)
    expect(write).toBeGreaterThan(prune)
  })

  it('guards the write, because the effect runs on every render', () => {
    expect(strip).toContain('if (!sameArrangement(next, arrangement.current))')
  })

  it('reads what was saved once rather than on every render', () => {
    // Re-reading would undo this run's own writes; treating unread as empty
    // would throw the saved arrangement away on the launch frame.
    expect(strip).toContain('if (arrangement.current === null) arrangement.current = readArrangement(storage)')
  })
})
