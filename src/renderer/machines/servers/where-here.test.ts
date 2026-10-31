import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Every action the main process marked as happening *here* is actually done here.
 *
 * ## The bug this exists for
 *
 * `actions.ts` tags each action with `where`, and `'here'` means the work is the
 * window's: the main process can work out an address, but it cannot open this
 * computer's browser or write this computer's clipboard from inside an action.
 * So those rows compute the address, answer it, and rely on the window to
 * finish the job.
 *
 * **Copy address did not finish it.** The button ran the action, the action
 * answered `done: 'Copied.'`, the card printed *"Copied."* — and nothing had
 * touched the clipboard. Measured on a real server page: pressing it left the
 * system pasteboard holding what it had held five minutes earlier, while the
 * screen said otherwise. That is the one thing a control on this page may never
 * do, and it is invisible from both sides: the main process did everything its
 * own tests ask of it, and the window rendered exactly what it was handed.
 *
 * ## Why it is a structural test
 *
 * Because the hole it guards is a *second* action somebody adds later — the same
 * argument `servers/host-key-checked.test.ts` makes about a connection path
 * built without a host-key check. There is no DOM testing library in this
 * repository (every renderer test is `renderToStaticMarkup`), so a click cannot
 * be exercised; what can be checked, and is the thing that actually goes wrong,
 * is whether the window knows the action exists at all.
 */

const ACTIONS = join(__dirname, '..', '..', '..', 'main', 'servers', 'actions.ts')
const CARD = join(__dirname, 'ServerCard.tsx')

/** Every `id` whose action declares `where: 'here'`. */
function actionsDoneHere(source: string): string[] {
  const ids: string[] = []
  // Each action is an object literal with `id` a few lines above `where`. Read
  // the pair rather than the whole file, so an unrelated `where` in prose or in
  // another shape cannot contribute an id.
  const re = /id:\s*'([a-z-]+)',[\s\S]{0,400}?where:\s*'(here|server)'/g
  let m: RegExpExecArray | null
  while ((m = re.exec(source)) !== null) {
    if (m[2] === 'here') ids.push(m[1])
  }
  return ids
}

describe('actions that happen in the window', () => {
  const actions = readFileSync(ACTIONS, 'utf8')
  const card = readFileSync(CARD, 'utf8')

  it('finds the ones the main process says are ours', () => {
    // A guard on the guard: if the shape of `actions.ts` changes so that this
    // scan finds nothing, the test below would pass by knowing about nothing.
    expect(actionsDoneHere(actions).sort()).toEqual(['copy-address', 'open'])
  })

  it('has the card do each one, by name', () => {
    for (const id of actionsDoneHere(actions)) {
      expect(
        card.includes(`'${id}'`),
        `ServerCard.tsx never mentions '${id}', which actions.ts marks as work for the window. ` +
          'The main process will answer a cheerful "done" sentence for it and nothing on this ' +
          'computer will have happened — which is exactly how Copy address came to report ' +
          '"Copied." while the clipboard kept whatever was already on it.',
      ).toBe(true)
    }
  })

  it('reaches the clipboard through a guard rather than assuming it is there', () => {
    /*
     * `navigator.clipboard` is absent outside a secure context and `writeText`
     * can be refused outright, and the honest answer then is to say so — the
     * address is on screen, so a person can still copy it by hand. Claiming the
     * copy is the failure above wearing a different coat.
     */
    expect(card).toMatch(/navigator\.clipboard/)
    expect(card).toMatch(/cannot reach the clipboard|would not let us use the clipboard/)
  })
})
