import { describe, expect, it } from 'vitest'
import { groupReasons } from './group-notes'
import type { AbsentAction, ServerCard } from './types'

/**
 * Said once when it is true of everything, and per card when it is not.
 *
 * The case this exists for was counted on a real server: fifty-nine cards under
 * *Other things running*, every one of them carrying the same sentence about
 * not knowing how to put it back. The failure mode being guarded against on the
 * other side is subtler and worse — a sentence lifted to a heading is a claim
 * about every card under it, so hoisting one that only some cards carry would
 * make the page state something false about somebody's server in the course of
 * tidying itself up.
 */

function card(id: string): ServerCard {
  return { id, kind: 'other', name: id, detail: '', running: true, url: null }
}

const PUT_BACK = 'We can’t tell how this was set up, so we don’t know how to put it back.'
const NO_BACKUP = 'This app can’t copy files off a server yet.'

function absent(rows: Record<string, string[]>): Record<string, AbsentAction[]> {
  const out: Record<string, AbsentAction[]> = {}
  for (const [id, because] of Object.entries(rows)) {
    out[id] = because.map((text, at) => ({ actionId: `a${at}`, because: text }))
  }
  return out
}

describe('a reason every card gives is the group’s reason', () => {
  it('says it once and takes it off the cards', () => {
    const cards = [card('c1'), card('c2'), card('c3')]
    const { shared, own } = groupReasons(
      cards,
      absent({ c1: [PUT_BACK], c2: [PUT_BACK], c3: [PUT_BACK] }),
    )
    expect(shared).toEqual([PUT_BACK])
    expect(own.c1).toEqual([])
    expect(own.c3).toEqual([])
  })

  it('leaves a reason only some cards give exactly where it was', () => {
    /*
     * The important direction. Lifting this would tell somebody that `c3`
     * cannot be backed up either, which is not what the main process said about
     * `c3` — a false claim about the actions available on their machine,
     * produced by a layout decision.
     */
    const cards = [card('c1'), card('c2'), card('c3')]
    const { shared, own } = groupReasons(
      cards,
      absent({ c1: [PUT_BACK, NO_BACKUP], c2: [PUT_BACK, NO_BACKUP], c3: [PUT_BACK] }),
    )
    expect(shared).toEqual([PUT_BACK])
    expect(own.c1).toEqual([{ actionId: 'a1', because: NO_BACKUP }])
    expect(own.c2).toEqual([{ actionId: 'a1', because: NO_BACKUP }])
    expect(own.c3).toEqual([])
  })

  it('does not hoist anything out of a group of one', () => {
    // There is nothing to de-duplicate, and moving the sentence away from the
    // single card it describes would only put it further from its subject.
    const { shared, own } = groupReasons([card('c1')], absent({ c1: [PUT_BACK] }))
    expect(shared).toEqual([])
    expect(own.c1).toEqual([{ actionId: 'a0', because: PUT_BACK }])
  })

  it('copes with a card the main process said nothing about', () => {
    const cards = [card('c1'), card('c2')]
    const { shared, own } = groupReasons(cards, absent({ c1: [PUT_BACK] }))
    expect(shared).toEqual([])
    expect(own.c2).toEqual([])
  })

  it('answers for every card when there are no absences at all', () => {
    const { shared, own } = groupReasons([card('c1'), card('c2')], undefined)
    expect(shared).toEqual([])
    expect(Object.keys(own).sort()).toEqual(['c1', 'c2'])
  })
})
