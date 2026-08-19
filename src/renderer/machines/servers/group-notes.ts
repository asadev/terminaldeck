import type { AbsentAction, ServerCard } from './types'

/**
 * A sentence that is true of every card in a group is said once, over the
 * group, rather than once per card.
 *
 * ## The measurement
 *
 * On a real Ubuntu server the remainder group came back with **fifty-nine**
 * cards, and every one of them carried *"We can't tell how this was set up, so
 * we don't know how to put it back."* — the `update` absence, which is the
 * correct thing for each of those cards to say and the wrong thing for a page
 * to say fifty-nine times. It stopped being an explanation somewhere around the
 * third repetition and became texture, which is the state in which nobody reads
 * the one that is different.
 *
 * ## Why "every card" and not "most of them"
 *
 * Because a sentence hoisted to a heading is a claim about everything under
 * that heading. Lift one that six of ten cards carry and the page has just told
 * somebody the other four cannot be updated either — a false statement,
 * produced by a tidying pass, about the actions available on their server. So
 * the bar is all of them, and a group where it does not hold repeats itself
 * rather than lies.
 *
 * The sentence is not rewritten on the way up. §5.2 keeps every one of these
 * verbatim from where the decision was made, so that the string the card draws,
 * the string the action log records and the string the copilot has to get a yes
 * to are the same string. Prefixing a count here would have made this the one
 * place that paraphrases.
 */
export interface GroupReasons {
  /** Said once, under the heading — every card below carries it. */
  shared: string[]
  /** What is left to say on each card, keyed by card id. */
  own: Record<string, AbsentAction[]>
}

export function groupReasons(
  cards: readonly ServerCard[],
  absent: Record<string, readonly AbsentAction[]> | undefined,
): GroupReasons {
  const per = cards.map((card) => absent?.[card.id] ?? [])
  /*
   * One card is not a repetition. Hoisting there would move its sentence away
   * from the thing it is about and gain nothing, and a group of one is where
   * the remainder heading usually starts out.
   */
  if (cards.length < 2) {
    const own: Record<string, AbsentAction[]> = {}
    cards.forEach((card, at) => {
      own[card.id] = [...per[at]]
    })
    return { shared: [], own }
  }

  const first = per[0]
  const shared = first
    .map((row) => row.because)
    .filter((because, at, all) => all.indexOf(because) === at)
    .filter((because) => per.every((rows) => rows.some((row) => row.because === because)))

  const own: Record<string, AbsentAction[]> = {}
  cards.forEach((card, at) => {
    own[card.id] = per[at].filter((row) => !shared.includes(row.because))
  })
  return { shared, own }
}
