import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ANCHOR_ATTR, anchorId, PAGE_SELECTOR, type DriveAnchor } from './focus-target'

/**
 * The anchors are a contract between two files that never import each other,
 * so something has to hold the two ends together.
 *
 * `focus-target.ts` builds `[data-drive-anchor="session-row:<id>"]`; `Sidebar.tsx`
 * writes that attribute. Neither knows about the other. A rename, a refactor or
 * a deleted line breaks the highlight in the way that is hardest to notice:
 * `querySelector` returns null, the overlay reports `anchor-missing`, and the
 * only symptom is that a stop in a tour quietly stops boxing.
 *
 * This is the same class of problem `styles/tokens.test.ts` was written for —
 * "a comment asking a human to remember is not a mechanism" — and the same
 * answer: read the real files and assert the claim.
 */

const ROOT = resolve(__dirname, '..', '..', '..')
const read = (rel: string): string => readFileSync(resolve(ROOT, rel), 'utf8')

/**
 * Every anchor kind, with the file that is supposed to carry it and the
 * expression that writes it.
 *
 * An entry with no `file` is a kind that is declared but not yet wired to
 * anything, and it is listed rather than omitted so this test is a map of the
 * whole surface: wiring one means moving a line here, not remembering that a
 * test exists. All five are wired today.
 */
const ANCHORS: ReadonlyArray<{
  sample: DriveAnchor
  file: string | null
  /** The template literal the component builds the value from, verbatim. */
  written: string | null
  /**
   * The whole JSX attribute, when it is not simply the template inline.
   *
   * Only `usage` needs it, and for the reason that outlived the component it
   * used to name. `UsageBar.tsx` is split into a container that knows the
   * session and a presentational view that draws the bar — the arrangement its
   * own tests depend on — so the value is built in the container and handed
   * over as a prop. That split is what makes the absent case expressible: a
   * view rendered with no session gets no attribute at all, rather than the
   * string `usage:undefined`, which is an anchor that exists, matches a
   * selector and names nothing. So the template and the attribute are pinned
   * separately, in the two places they now live.
   */
  attribute?: string
}> = [
  {
    sample: { at: 'message', messageId: 'm' },
    file: 'src/renderer/components/ChatView.tsx',
    written: 'message:${message.id}',
  },
  {
    sample: { at: 'session-row', sessionId: 's' },
    file: 'src/renderer/shell/Sidebar.tsx',
    written: 'session-row:${tab.id}',
  },
  {
    sample: { at: 'alert', alertId: 'a' },
    file: 'src/renderer/components/AlertsPanel.tsx',
    written: 'alert:${alert.id}',
  },
  {
    sample: { at: 'git-file', cwd: '/w', path: 'p' },
    file: 'src/renderer/components/GitPanel.tsx',
    written: 'git-file:${cwd}:${file.path}',
  },
  /*
   * Retargeted, and renamed with it.
   *
   * This entry named `src/renderer/chat/usage/UsageStrip.tsx` and that file is
   * **deleted** — it was the token and cost readout folded inside the chat
   * composer, and it went with the composer's control row when the review asked
   * to *"remove them from the chat box side completely."* This test is the thing
   * that noticed: `readFileSync` threw ENOENT, which is exactly the failure it
   * was written to produce rather than a silent stop that no longer boxes.
   *
   * The capability had to survive the component, because a tour has a real
   * reason to point at a session's usage. The reading now lives in the chrome's
   * `UsageBar`, which takes a `sessionId` and is mounted on every session screen
   * through `SessionControls` — a wider surface than the one it left, not a
   * narrower one. So the kind is `usage`, which is what it is, rather than
   * `usage-strip`, which is a strip that no longer exists.
   */
  {
    sample: { at: 'usage', sessionId: 's' },
    file: 'src/renderer/shell/UsageBar.tsx',
    written: 'usage:${sessionId}',
    attribute: `${ANCHOR_ATTR}={anchor}`,
  },
]

describe('every wired anchor is really in the DOM it claims to be in', () => {
  for (const { sample, file, written, attribute } of ANCHORS) {
    if (file === null || written === null) continue

    it(`${sample.at} is written by ${file}`, () => {
      const source = read(file)
      expect(source).toContain(`\`${written}\``)
      expect(source).toContain(attribute ?? `${ANCHOR_ATTR}={\`${written}\`}`)
    })

    /*
     * And the *prefix* agrees. The attribute could be present and spell the
     * kind differently — `session:` instead of `session-row:` — which would
     * pass a contains-check on the attribute name and fail every lookup.
     */
    it(`${sample.at} is written with the prefix the selector builds`, () => {
      const prefix = anchorId(sample).split(':')[0]
      expect(written.startsWith(`${prefix}:`)).toBe(true)
    })
  }
})

describe('the set of anchors is declared, not forgotten', () => {
  it('lists every kind in the union exactly once', () => {
    const kinds = ANCHORS.map((entry) => entry.sample.at).sort()
    // If a kind is added to `DriveAnchor` and not to this list, this fails and
    // names the gap. Kept as a literal rather than derived from the type,
    // because a type cannot be enumerated at runtime and a derived list would
    // agree with itself no matter what.
    expect(kinds).toEqual(['alert', 'git-file', 'message', 'session-row', 'usage'])
  })
})

/**
 * An anchor kind is spelled in **six** files, and only one of them can fail
 * loudly on its own.
 *
 * The chain a tour stop travels is: the copilot reads the JSON-schema `enum` in
 * `tour-tool.ts` and picks a word; `tour.ts` in the main process validates that
 * word against `ANCHORS` and writes it into the plan and into the on-disk
 * record; the renderer's mirror of that type accepts it; `tour.ts` there turns
 * it into a `DriveAnchor`; `focus-target.ts` turns that into an attribute
 * selector; and one component writes the attribute. TypeScript holds three of
 * those six joins and cannot hold the other three — `tour-tool.ts`'s enum is a
 * string array inside a JSON schema, the main and renderer types are mirrors
 * across a bridge that carries `unknown`, and the attribute is a string in JSX.
 *
 * The failure mode of a half-rename is therefore not a compile error. It is a
 * copilot that emits a word the validator refuses (a tour that never starts and
 * blames the model), or a word the validator accepts and no element carries (a
 * stop that navigates, boxes nothing, and reports `anchor-missing`). This test
 * exists because `usage-strip` was renamed to `usage` across exactly these six
 * files, and reading them back is the only way to know it was done in all six.
 *
 * The dead name is asserted absent as well as the live one present. Half of a
 * rename passing a contains-check on the new name is the whole hazard.
 */
describe('the tour and the overlay agree on what an anchor is called', () => {
  /** The union members out of a `export type TourAnchorAt = 'a' | 'b'` line. */
  function unionOf(source: string): string[] {
    const line = /export type TourAnchorAt =([^\n]*)/.exec(source)
    expect(line, 'TourAnchorAt is declared').not.toBeNull()
    return [...(line?.[1] ?? '').matchAll(/'([^']+)'/g)].map((match) => match[1]).sort()
  }

  const anchorKinds = ANCHORS.map((entry) => entry.sample.at)

  it('names the same kinds on both sides of the bridge', () => {
    const main = unionOf(read('src/main/deck-control/tour.ts'))
    const renderer = unionOf(read('src/renderer/copilot/driving/tour.ts'))
    expect(main).toEqual(renderer)
    // And every one of them is a real place the overlay can point at. A tour
    // may name fewer kinds than the overlay supports — `session-row` and
    // `alert` are excluded on purpose, see `tour.ts` — but never a kind that
    // does not exist.
    for (const kind of main) expect(anchorKinds).toContain(kind)
  })

  it('offers the copilot exactly those words, and no stale one', () => {
    const tool = read('src/main/deck-control/tour-tool.ts')
    const offered = /enum: \[([^\]]*)\]/g
    const enums = [...tool.matchAll(offered)].map((match) =>
      [...match[1].matchAll(/'([^']+)'/g)].map((inner) => inner[1]),
    )
    // The anchor enum is the one containing `git-file`; the file carries three
    // others (stop kinds, reasons, and the tour's own arguments) and picking it
    // by position would break the next time one is added.
    const anchors = enums.find((entry) => entry.includes('git-file'))
    expect(anchors?.sort()).toEqual(unionOf(read('src/main/deck-control/tour.ts')))
  })

  it('leaves the deleted name nowhere a lookup can reach it', () => {
    for (const file of [
      'src/renderer/driving/focus-target.ts',
      'src/renderer/copilot/driving/tour.ts',
      'src/main/deck-control/tour.ts',
      'src/main/deck-control/tour-tool.ts',
      'src/renderer/shell/UsageBar.tsx',
    ]) {
      // The three ways this codebase can spell a *value*: a single-quoted
      // string, a double-quoted JSX attribute, and the template literal the
      // selector used to be built from — which is why the backtick form is
      // matched only with its colon. Everything else is prose, and the essays
      // above these declarations have to stay free to say what the kind used to
      // be called and why it is not called that any more. A rule that forbade
      // naming the old name would make the reason for the rename unwritable.
      expect(read(file), file).not.toMatch(/'usage-strip'|"usage-strip"|`usage-strip:/)
    }
  })
})

describe('the browser stage is still the element that gets measured', () => {
  /*
   * `PAGE_SELECTOR` is the one place this feature depends on a class name
   * rather than an attribute, and it is deliberate: `BrowserWorkspace.tsx`
   * describes `.bw-stage` as "an empty div whose only job is to be measured",
   * and the main process is handed exactly that rectangle as the native view's
   * bounds. Measuring it is measuring the page. If the class is renamed, a
   * `page` focus silently becomes "no page on screen".
   */
  it('BrowserWorkspace still renders it', () => {
    const source = read('src/renderer/browser/BrowserWorkspace.tsx')
    expect(PAGE_SELECTOR).toBe('.bw-stage')
    expect(source).toContain('className="bw-stage"')
  })
})

describe('the terminal registry is actually fed', () => {
  /*
   * Without this line the overlay can never point at a terminal, and it fails
   * as `not-registered` — which reads as "that session has no terminal" rather
   * than as "somebody deleted the registration". `wiring.test.ts` uses the same
   * device to pin `subscribeTheme` to the component that had never called it.
   */
  it('TerminalView registers every terminal it opens, and unregisters it', () => {
    const source = read('src/renderer/components/TerminalView.tsx')
    expect(source).toContain('registerTerminal(sessionId, { term, host })')
    expect(source).toContain('unregister()')
  })
})
