import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { controlName, optionsFor, type ControlId } from './catalog'

/**
 * Every control has exactly one place a person can reach it, and this file knows
 * which place, for each of them, and why.
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
 * so deleting the row without noticing would have deleted a working control,
 * which is the same failure this project has already had reported at it twice —
 * *"you actually removed everything rather than making it simple"* — arrived at
 * from the opposite direction.
 *
 * ## And then permission mode left the bar too, which is not the same event
 *
 * On 2026-08-19 the permission chip came off `CHROME_CONTROLS`. Asad, looking at
 * a chip reading `Bypass`:
 *
 *   > *"we don't need this part also at the end, now bypass read things because
 *   > we have this here already inside."*
 *
 * That would trip every assertion this file originally made, and it *should*
 * have to answer them rather than be exempted, so the answer is written as the
 * test instead of as a deletion. Permission mode has a home. It is not in this
 * app's chrome — it is the CLI's own indicator, which Claude Code redraws along
 * the bottom of every session it runs:
 *
 *     ⏵⏵ bypass permissions on (shift+tab to cycle)
 *
 * That is a better home than the chip was, and the reason is not taste. The chip
 * was a *second* reading of one fact, scraped off a frame this app happened to
 * parse; the line below it is drawn by the process that owns the fact, so it
 * cannot lag, and it names the gesture that changes it in the same breath. Two
 * readings that can disagree is worse than one that cannot.
 *
 * So the invariant this file pins has become sharper rather than weaker: every
 * control is reachable somewhere, no control is in the chat box, and the one
 * control that is not in the chrome is the one whose absence is *argued in the
 * source* — with the CLI's own line named. A silent deletion of any of the four
 * still fails here, which is the whole job.
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

/**
 * The one control this app deliberately does not draw, and the line it defers to.
 *
 * `CLI_OWNED` is a list of one and it is meant to stay that way. Every entry is
 * a control whose value the app still *reads* but never draws a switch for,
 * because the agent underneath already draws it and cannot be stale about it.
 * Adding to this list is how a control would leave the app quietly, so the
 * checks below make each entry pay for its place: the source has to name the
 * line it is deferring to, in the CLI's own characters.
 */
const CLI_OWNED: ReadonlyArray<{ control: ControlId; indicator: RegExp }> = [
  // Captured verbatim off `claude 2.1.234` in `src/main/cli-screens.capture.json`
  // and asserted from two other test files. `shift+tab` is in the pattern
  // because a reader told a control has moved needs to be told where to.
  { control: 'permission', indicator: /shift\+tab/ },
]

describe('every control has somewhere to be', () => {
  const source = read('renderer/shell/SessionControls.tsx')
  const chrome = listNamed(source, 'CHROME_CONTROLS')
  const owned = new Set(CLI_OWNED.map((row) => row.control))

  it('reads the window bar’s list at all', () => {
    // If this fails the rest of the file is vacuous, so it is asserted first
    // rather than left to be inferred from four confusing failures.
    expect(chrome.length, 'CHROME_CONTROLS could not be parsed — check the literal').toBeGreaterThan(0)
  })

  for (const control of CONTROLS.filter((id) => !owned.has(id))) {
    it(`draws ${controlName(control)} in the window bar`, () => {
      expect(
        chrome,
        `${controlName(control)} is not drawn anywhere — the composer no longer has a controls row, so this bar is its only home`,
      ).toContain(control)
    })
  }

  for (const { control, indicator } of CLI_OWNED) {
    it(`leaves ${controlName(control)} to the agent, and says so where it was removed`, () => {
      /*
       * Both halves, and neither is optional.
       *
       * Absent from the bar is the change. Argued in the source is what makes it
       * a decision rather than a deletion — and the argument has to name the
       * thing that took over the job, because "we removed it" and "something
       * else does it better" look identical in a diff six months later.
       */
      expect(
        chrome,
        `${controlName(control)} is back on the bar — the CLI already draws it under every session, and two readings of one fact can disagree`,
      ).not.toContain(control)
      expect(
        source,
        `nothing in SessionControls.tsx says where ${controlName(control)} went`,
      ).toMatch(indicator)
    })
  }

  it('offers real values for each of them, not an empty menu', () => {
    // A chip with nothing behind it is the "control that cannot act" the whole
    // review is about, and it would satisfy every check above. Asserted for the
    // CLI-owned ones too: the reading still crosses the bridge and is still
    // mirrored in `ControlsReading`, so an empty list here would mean the app
    // had lost the vocabulary to describe a mode it still displays.
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
