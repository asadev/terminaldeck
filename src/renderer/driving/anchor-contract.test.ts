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
   * Only `usage-strip` needs it. That component has three separate returns —
   * populated, "nothing yet", and "not wired into this build" — and all three
   * carry the anchor, because "this session has spent nothing" is a thing a
   * tour has a reason to point at. Repeating the expression three times would
   * be three places for it to drift, and an absent session has to produce an
   * absent attribute rather than the string `usage-strip:undefined`, which is
   * an anchor that exists and names nothing. So the value is built once into a
   * variable and this pins both halves separately.
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
  {
    sample: { at: 'usage-strip', sessionId: 's' },
    file: 'src/renderer/chat/usage/UsageStrip.tsx',
    written: 'usage-strip:${sessionId}',
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
    expect(kinds).toEqual(['alert', 'git-file', 'message', 'session-row', 'usage-strip'])
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
