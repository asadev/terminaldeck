import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { claimMenu, releaseMenu } from './one-menu'

/**
 * The one-menu-at-a-time rule, pinned twice.
 *
 * The holder itself is a plain module, so the first half of this file drives it
 * directly — which is the whole reason it is a plain module rather than a React
 * context: this project has no DOM in its test setup, and a rule that could
 * only be exercised by clicking things would have no test at all.
 *
 * The second half reads the source of every menu on a session screen and
 * asserts each one takes part. That is the check that actually protects the
 * defect: the holder can be perfect and the app still show two menus at once if
 * one of the six forgets to opt in, and a menu that opted out would fail none
 * of its own tests. The list is the inventory — a *new* menu added to the chat
 * chrome without a line here is the next report.
 */

const SRC = join(__dirname, '..', '..')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

/** A menu that records whether it was told to close. */
function menu(): { id: symbol; close(): void; closed(): boolean } {
  let shut = false
  return {
    id: Symbol('test menu'),
    close: () => {
      shut = true
    },
    closed: () => shut,
  }
}

describe('opening a menu shuts the one that was open', () => {
  it('closes the previous holder', () => {
    const first = menu()
    const second = menu()
    claimMenu(first)
    claimMenu(second)
    expect(first.closed()).toBe(true)
    expect(second.closed()).toBe(false)
    releaseMenu(second.id)
  })

  it('does not close a menu that re-claims its own slot', () => {
    // A menu re-renders while it is open — these re-render on every chunk of
    // the session's output — and a claim that displaced itself would blink the
    // menu shut under the pointer.
    const only = menu()
    claimMenu(only)
    claimMenu(only)
    expect(only.closed()).toBe(false)
    releaseMenu(only.id)
  })

  it('lets a displaced menu clean up without clearing its successor', () => {
    /*
     * The ordering that makes the whole thing work.
     *
     * Closing a menu sets React state; the effect cleanup that calls
     * `releaseMenu` for it therefore arrives *after* the new menu has claimed
     * the slot. If that late release cleared the holder, the next menu to open
     * would find nothing to close and two would be on screen — which is the
     * original defect, reintroduced by the fix.
     */
    const first = menu()
    const second = menu()
    const third = menu()
    claimMenu(first)
    claimMenu(second)
    releaseMenu(first.id) // the displaced menu's cleanup, arriving late
    claimMenu(third)
    expect(second.closed()).toBe(true)
    releaseMenu(third.id)
  })

  it('closes nothing once the last menu has released the slot', () => {
    const first = menu()
    const second = menu()
    claimMenu(first)
    releaseMenu(first.id)
    claimMenu(second)
    expect(first.closed()).toBe(false)
    releaseMenu(second.id)
  })
})

describe('every menu on a session screen takes part', () => {
  /*
   * Every floating surface a session screen can have open, and where it lives.
   * Two are under the session's title, four are inside the chat box, and before
   * this rule existed the Options panel and either of the two chips beside it
   * could be on screen together — see `one-menu.ts` for why that pair in
   * particular, and why the other pairs only worked by accident of markup.
   */
  const MENUS: ReadonlyArray<[string, string]> = [
    ['the folder and account chips', 'renderer/shell/chip-menu.ts'],
    ['the plus behind the composer', 'renderer/chat/attach/AttachMenu.tsx'],
    ['the model and permission chips', 'renderer/chat/controls/ControlPicker.tsx'],
    ['the Options panel', 'renderer/chat/controls/AgentControls.tsx'],
    ['the microphone', 'renderer/chat/voice/DictateButton.tsx'],
  ]

  for (const [what, file] of MENUS) {
    it(`${what} closes when another opens`, () => {
      const source = read(file)
      expect(source, `${file} does not import the rule`).toMatch(/from '.*one-menu'/)
      expect(source, `${file} imports the rule but never uses it`).toMatch(/useOneMenu\(/)
    })
  }

  it('does not hand the attach menu its focus-returning close', () => {
    // `close()` there also pulls the caret back into the text box. Right when
    // the popover is being dismissed; wrong when it is being displaced, because
    // the user has just pressed a different control and focus would be yanked
    // off it.
    const source = read('renderer/chat/attach/AttachMenu.tsx')
    expect(source).not.toMatch(/useOneMenu\(\s*surface\s*!==\s*null\s*,\s*close\s*\)/)
  })
})
