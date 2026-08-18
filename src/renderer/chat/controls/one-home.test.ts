import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { controlName, optionsFor, type ControlId } from './catalog'

/**
 * Every control has exactly one place a person can reach it, and that place is
 * not the chat box.
 *
 * ## Why this file exists
 *
 * Because the composer's control row was removed, and removing a row of
 * duplicates is one small mistake away from removing a control:
 *
 *   > *"Options is showing the same options that we already have here… since we
 *   > have it on top we actually don't need them here. Let's keep them only on
 *   > top and let's not keep them here — remove them from the chat box side
 *   > completely, only keep the maybe add files or something."*
 *
 * Three of the four controls genuinely were duplicates — model, effort and fast
 * mode are all drawn by `shell/SessionControls.tsx` in the window's own bar.
 * **Permission mode was not.** It had a chip in the composer and nowhere else,
 * and the note in `SessionControls.tsx` says so in as many words ("it keeps its
 * chip in the composer"). Deleting the row without noticing that would have
 * deleted a working control, which is the same failure this project has already
 * had reported at it twice — *"you actually removed everything rather than
 * making it simple"* — arrived at from the opposite direction.
 *
 * So this asserts the invariant rather than the implementation: whatever the
 * lists say, every `ControlId` is drawn somewhere, and no `ControlId` is drawn
 * in the composer. Both halves have to hold at once. Either on its own is
 * satisfiable by a change nobody wants — delete the control (first passes),
 * or put it back in the box (second passes).
 *
 * ## Why it reads the source
 *
 * There is no DOM in this project's tests, and the row this is about is a list
 * of components rendered from an array. A control that is not in the array
 * still passes every test ever written about the control itself; that is the
 * entire subject of `wiring.test.ts`, and this is the same technique aimed at
 * one specific promise.
 */

const SRC = join(__dirname, '..', '..', '..')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

const CONTROLS: readonly ControlId[] = ['model', 'effort', 'fast', 'permission']

/**
 * The array literal a file assigns to `name`, as a list of quoted strings.
 *
 * Parsed rather than imported because `SessionControls.tsx` cannot be imported
 * here: it pulls in CSS and a window-measuring hook, and this project's vitest
 * setup has neither. A regex over one array literal is a small enough contract
 * to be honest about — and it fails loudly, as an empty list, if the literal is
 * ever reshaped, which is exactly when this check should be looked at again.
 */
function listNamed(source: string, name: string): string[] {
  const match = new RegExp(`${name}[^=]*=\\s*\\[([^\\]]*)\\]`).exec(source)
  if (!match) return []
  return [...match[1].matchAll(/'([^']+)'/g)].map((hit) => hit[1] as string)
}

describe('every control has somewhere to be', () => {
  const chrome = listNamed(read('renderer/shell/SessionControls.tsx'), 'CHROME_CONTROLS')

  it('reads the window bar’s list at all', () => {
    // If this fails the rest of the file is vacuous, so it is asserted first
    // rather than left to be inferred from four confusing failures.
    expect(chrome.length, 'CHROME_CONTROLS could not be parsed — check the literal').toBeGreaterThan(0)
  })

  for (const control of CONTROLS) {
    it(`draws ${controlName(control)} in the window bar`, () => {
      expect(
        chrome,
        `${controlName(control)} is not drawn anywhere — the composer no longer has a controls row, so this bar is its only home`,
      ).toContain(control)
    })
  }

  it('offers real values for each of them, not an empty menu', () => {
    // A chip with nothing behind it is the "control that cannot act" the whole
    // review is about, and it would satisfy every check above.
    for (const control of CONTROLS) {
      expect(optionsFor(control).length, controlName(control)).toBeGreaterThan(0)
    }
  })
})

describe('and it is not the chat box', () => {
  const composer = read('renderer/components/ChatComposer.tsx')
  const view = read('renderer/components/ChatView.tsx')

  it('the composer takes no controls slot', () => {
    // The prop is how they got there. Without it, putting them back is a change
    // to this component rather than a change at a call site, which is the point.
    expect(composer, 'the composer accepts a controls slot again').not.toMatch(/controls\??:/)
    expect(composer).not.toContain('{controls}')
  })

  it('the chat view mounts neither the controls nor the usage strip', () => {
    for (const gone of ['AgentControls', 'UsageStrip']) {
      expect(view, `${gone} is mounted in the chat view again`).not.toMatch(
        new RegExp(`<${gone}[\\s/>]`),
      )
    }
  })

  it('leaves attach behind, which is the one thing he asked to keep', () => {
    // *"only keep the maybe add files or something."*
    expect(composer).toMatch(/<AttachMenu[\s\n]/)
  })
})
