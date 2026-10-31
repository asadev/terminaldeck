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

/**
 * A tab's name, as the main process mints it.
 *
 * Opaque on purpose — nothing in this file may read anything out of one — and
 * so the fixtures spell them `k1`, `k2` rather than building something that
 * looks derivable. A real one is a UUID; what matters here is only that two
 * tabs never share one and that a tab keeps its own across a restart.
 */
const KEYS = { one: 'k1', two: 'k2', three: 'k3' } as const

describe('sessionAnchor', () => {
  it('is the name the main process gave the session, and nothing derived', () => {
    expect(sessionAnchor({ tabKey: 'k1' })).toBe('k1')
  })

  it('says nothing at all about a session no launch brings back', () => {
    // A browser page, a session on a paired machine, a shell on a server, the
    // copilot's own. `host-core.ts` mints no key for any of them, from the same
    // condition that decides whether it writes the session down — so absence
    // here is the main process's answer rather than this window's guess.
    expect(sessionAnchor({})).toBeUndefined()
  })

  it('tells two tabs apart when every fact about them is the same', () => {
    /*
     * The pair this whole change exists for: same agent, same folder, same
     * account, neither typed into. Everything a renderer can compute about
     * these two is one string, which is why the arrangement used to number them
     * by position — and why closing one moved the other.
     */
    expect(sessionAnchor({ tabKey: KEYS.one })).not.toBe(sessionAnchor({ tabKey: KEYS.two }))
  })
})

describe('anchorsByTab', () => {
  it('leaves out everything a restart does not bring back', () => {
    // A browser page, a session on a paired machine, a shell on a server.
    const anchors = anchorsByTab([tab('b1'), tab('m:host:9'), tab('s1', KEYS.one)])
    expect([...anchors.keys()]).toEqual(['s1'])
  })

  it('gives the same tab the same name on both sides of a restart', () => {
    const before = anchorsByTab([tab('s1', KEYS.one), tab('s2', KEYS.two)])
    // Same tabs, new run, new session ids — and, deliberately, announced in the
    // other order, because the order a restore finishes its spawns in is not a
    // fact about anybody's bar.
    const after = anchorsByTab([tab('s9', KEYS.two), tab('s7', KEYS.one)])
    expect(after.get('s7')).toBe(before.get('s1'))
    expect(after.get('s9')).toBe(before.get('s2'))
  })

  it('does not rename the survivor when its sibling closes', () => {
    /*
     * The second half of the failure. Numbering by position meant the right-hand
     * sibling became number 0 the moment the left one was shut — taking over the
     * name its neighbour had, and leaving the saved arrangement holding a number
     * nothing answered to.
     */
    const both = anchorsByTab([tab('s1', KEYS.one), tab('s2', KEYS.two)])
    const alone = anchorsByTab([tab('s2', KEYS.two)])
    expect(alone.get('s2')).toBe(both.get('s2'))
  })

  it('keeps the first of two tabs that somehow arrive under one name', () => {
    // It cannot happen — a key is minted per session — but these arrive over a
    // bridge, and a duplicate that got through would silently make one tab
    // shadow the other in `tabsByAnchor`. The second is left unarranged, which
    // costs a drag; putting a tab back into somebody else's place does not.
    const anchors = anchorsByTab([tab('s1', KEYS.one), tab('s2', KEYS.one)])
    expect([...anchors.keys()]).toEqual(['s1'])
  })

  it('reads back the other way for a restore', () => {
    const anchors = anchorsByTab([tab('s1', KEYS.one)])
    expect(tabsByAnchor(anchors).get(anchors.get('s1') ?? '')).toBe('s1')
  })
})

describe('nextArrangement', () => {
  const anchors = (...tabs: AnchoredTab[]) => anchorsByTab(tabs)

  it('writes the promoted order down in the names that survive a quit', () => {
    const map = anchors(tab('s1', KEYS.one), tab('s2', KEYS.two))
    const out = nextArrangement(['s2', 's1'], map, [], new Set([KEYS.one, KEYS.two]))
    expect(out).toEqual([KEYS.two, KEYS.one])
  })

  it('keeps a name whose tab has not arrived yet', () => {
    // The launch hazard `pruneOrder` was measured against, in the other list: a
    // wave of sessions lands, and the ones still on their way must not be
    // written out of the arrangement in the meantime.
    const map = anchors(tab('s1', KEYS.one))
    const out = nextArrangement(['s1'], map, ['k-late'], new Set([KEYS.one]))
    expect(out).toEqual([KEYS.one, 'k-late'])
  })

  it('drops a name whose tab arrived and was folded away', () => {
    // Not the same as the case above and the difference is the whole guard: the
    // tab is here, the person took it off the bar, and that is a current fact.
    const map = anchors(tab('s1', KEYS.one), tab('s2', KEYS.two))
    const out = nextArrangement(['s1'], map, [KEYS.one, KEYS.two], new Set([KEYS.one, KEYS.two]))
    expect(out).toEqual([KEYS.one])
  })

  it('drops a name whose tab was closed, rather than carrying it for ever', () => {
    /*
     * Closing one of two siblings, from the arrangement's side.
     *
     * A closed tab is not in `anchors` any more, so an arrived set derived from
     * the live tabs put its name back into "has not turned up yet" and carried
     * it on every launch afterwards — bounded by the cap, resolving to nothing,
     * and holding a slot. The set handed in is every name this window has ever
     * had a tab for, which is a fact that only grows.
     */
    const map = anchors(tab('s2', KEYS.two))
    const out = nextArrangement(['s2'], map, [KEYS.one, KEYS.two], new Set([KEYS.one, KEYS.two]))
    expect(out).toEqual([KEYS.two])
  })

  it('puts the live ones ahead of the ones still unaccounted for', () => {
    const map = anchors(tab('s1', KEYS.one))
    const out = nextArrangement(['s1'], map, ['k-gone', KEYS.one], new Set([KEYS.one]))
    expect(out[0]).toBe(KEYS.one)
  })

  it('never grows past the cap, however many runs never resolved', () => {
    const stale = Array.from({ length: 40 }, (_, index) => `k-gone-${index}`)
    const map = anchors(tab('s1', KEYS.one))
    const out = nextArrangement(['s1'], map, stale, new Set([KEYS.one]))
    expect(out).toHaveLength(MAX_PROMOTED)
    expect(out[0]).toBe(KEYS.one)
  })

  it('ignores a promoted id that has no name', () => {
    // A browser page is drawn in the strip whether or not anything promoted it,
    // so it has nothing to come back to and nothing to write down.
    const map = anchors(tab('s1', KEYS.one))
    expect(nextArrangement(['b1', 's1'], map, [], new Set([KEYS.one]))).toEqual([KEYS.one])
  })
})

describe('seedArrangement', () => {
  it('puts the bar back after a restart, in the order it was left', () => {
    const before = anchorsByTab([tab('s1', KEYS.one), tab('s2', KEYS.two)])
    const saved = [before.get('s2') ?? '', before.get('s1') ?? '']

    // Next launch: same two sessions, new ids, in the order the ledger restores
    // them rather than the order they were arranged in.
    const now = anchorsByTab([tab('n1', KEYS.one), tab('n2', KEYS.two)])
    expect(seedArrangement([], saved, now, new Set(['n1', 'n2']))).toEqual(['n2', 'n1'])
  })

  it('brings two identical siblings back the way round they were left', () => {
    /*
     * The failure, end to end, in the one shape nothing could tell apart.
     *
     * Two Claude sessions in `/w`, same account, neither typed into. The person
     * arranges them with the second one first. On the next launch the restore
     * announces them in the other order — which it is entitled to do, because
     * the two are identical and the order is whichever spawn finished first —
     * and the bar has to come back the way it was left anyway.
     *
     * Under position-numbering this was not possible even in principle: both
     * tabs' names were the same string plus their place in the list, so
     * whichever arrived first *was* number 0, and the pair came back swapped.
     */
    const saved = [KEYS.two, KEYS.one]
    const arriving = anchorsByTab([tab('n1', KEYS.two), tab('n2', KEYS.one)])
    const bar = seedArrangement([], saved, arriving, new Set(['n1', 'n2']))

    expect(bar.map((id) => arriving.get(id))).toEqual(saved)
  })

  it('lands a tab that arrives late between the neighbours it was saved between', () => {
    const anchors = anchorsByTab([
      tab('n1', KEYS.one),
      tab('n2', KEYS.two),
      tab('n3', KEYS.three),
    ])
    const saved = [anchors.get('n1') ?? '', anchors.get('n2') ?? '', anchors.get('n3') ?? '']

    // First wave: the outer two.
    const first = seedArrangement([], saved, anchors, new Set(['n1', 'n3']))
    expect(first).toEqual(['n1', 'n3'])
    // Second wave: the middle one, which must not simply go on the end.
    expect(seedArrangement(first, saved, anchors, new Set(['n2']))).toEqual(['n1', 'n2', 'n3'])
  })

  it('leaves a tab alone once it has been seen, so folding one away sticks', () => {
    const anchors = anchorsByTab([tab('n1', KEYS.one)])
    const saved = [anchors.get('n1') ?? '']
    // Not arriving any more: the window has seen it, and the person took it off.
    expect(seedArrangement([], saved, anchors, new Set())).toEqual([])
  })

  it('never promotes the same tab twice', () => {
    const anchors = anchorsByTab([tab('n1', KEYS.one)])
    const saved = [anchors.get('n1') ?? '', anchors.get('n1') ?? '']
    expect(seedArrangement([], saved, anchors, new Set(['n1']))).toEqual(['n1'])
  })

  it('skips a name nothing came back for', () => {
    const anchors = anchorsByTab([tab('n1', KEYS.one)])
    expect(seedArrangement([], ['k-unmounted', anchors.get('n1') ?? ''], anchors, new Set(['n1']))).toEqual([
      'n1',
    ])
  })

  it('refuses at the cap rather than evicting a tab already on the bar', () => {
    const full = Array.from({ length: MAX_PROMOTED }, (_, index) => `t${index}`)
    const anchors = anchorsByTab([tab('n1', KEYS.one)])
    const out = seedArrangement(full, [anchors.get('n1') ?? ''], anchors, new Set(['n1']))
    expect(out).toEqual(full)
  })

  it('adds nothing when there is no saved arrangement', () => {
    const anchors = anchorsByTab([tab('n1', KEYS.one)])
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

  it('gives every local session tab the name the main process gave it', () => {
    const built = /const windowTab = \(session: Session\): WorkspaceTab => \(\{[\s\S]*?\n {2}\}\)/.exec(app)?.[0] ?? ''
    expect(built, 'windowTab has changed shape').not.toBe('')
    expect(built).toContain('anchor: sessionAnchor(session)')
  })

  it('remembers the names it has seen, not only the tabs that are still open', () => {
    // The arrived set `nextArrangement` reads. Derived from the live tabs, a
    // closed tab's name fell back to "has not turned up yet" and was carried in
    // the saved arrangement for ever after — see the test for it above.
    expect(strip).toContain('const seenAnchors = useRef<Set<string>>(new Set())')
    expect(strip).toContain('for (const anchor of anchors.values()) seenAnchors.current.add(anchor)')
    expect(strip).toContain('nextArrangement(pruned, anchors, arrangement.current, seenAnchors.current)')
  })

  it('seeds before it marks a tab as seen, or it would seed nothing', () => {
    // `arriving` is the difference between "this tab has just turned up" and
    // "this tab is here" — computed against `seen` and therefore only correct
    // while `seen` still predates this render.
    const seed = strip.indexOf('seedArrangement(')
    const mark = strip.indexOf('for (const tab of tabs) seen.current.add(tab.id)')
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
