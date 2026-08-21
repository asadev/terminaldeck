import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SegmentedSwitch } from './SegmentedSwitch'
import { ScopeSwitch } from '../settings/sections/AgentsSection'

/**
 * The one segmented switch, and the two ways a second one gets built by accident.
 *
 * Asad asked for the Coding AI switch *"and all other applicable places too"*,
 * with *"exactly means exactly"* attached to it. A control that is copied to a
 * second place is a control that will differ in a third, and this file pins the
 * two failures that had already happened before anybody looked:
 *
 *  1. **A copy of the markup.** Four files drew `<div class="settings-scope">`
 *     with their own buttons inside. Nothing failed when one of them diverged.
 *  2. **A class beside it with no rule.** `DeviceApproval` asked for
 *     `settings-scope da-scope` and no stylesheet in this repo defines
 *     `.da-scope` — so it kept a `--sp-6` bottom margin inside a `--sp-2`
 *     column, and the ticks under that switch sat three times further away than
 *     anything else on the step.
 *
 * Both are checked against the source rather than against a string typed here,
 * because both are *absences* — a copy nobody imported, a rule nobody wrote —
 * and an absence is exactly what a rendering test cannot see.
 */

const ROOT = resolve(__dirname, '..', '..', '..')

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry.startsWith('.')) continue
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) walk(full, out)
    else out.push(full)
  }
  return out
}

const FILES = walk(join(ROOT, 'src', 'renderer'))
const SOURCE = FILES.filter((file) => file.endsWith('.tsx') || file.endsWith('.ts'))
const SHEETS = FILES.filter((file) => file.endsWith('.css'))
const ALL_CSS = SHEETS.map((file) => readFileSync(file, 'utf8')).join('\n')

/** The component's own file is allowed to say the class; it is the one that owns it. */
const OWNER = join(ROOT, 'src', 'renderer', 'components', 'SegmentedSwitch.tsx')

describe('one segmented switch', () => {
  it('draws the run with exactly one button on, and says so twice', () => {
    const html = renderToStaticMarkup(
      <SegmentedSwitch
        options={[
          { id: 'all', label: 'All' },
          { id: 'selected', label: 'Selected' },
        ]}
        value="selected"
        onChange={() => {}}
        label="Logins it can use"
      />,
    )
    // `data-on` for the stylesheet and `aria-pressed` for the reader, from one
    // prop — a button cannot look chosen and read as unchosen.
    expect(html).toMatch(/data-on=""[^>]*aria-pressed="true"[^>]*>Selected/)
    expect(html).toMatch(/aria-pressed="false"[^>]*>All/)
    expect(html.match(/aria-pressed="true"/g)).toHaveLength(1)
    expect(html).toContain('aria-label="Logins it can use"')
  })

  /**
   * A value matching no option leaves nothing on, rather than falling back to
   * the first button.
   *
   * That is the state `AgentsSection` guards against — a device forgotten while
   * its scope is on screen — and the guard is only worth writing if this is what
   * happens without it. `McpInspector` grew the same guard on 2026-08-22.
   */
  it('lights nothing when the value names no option', () => {
    const html = renderToStaticMarkup(
      <SegmentedSwitch
        options={[{ id: 'all', label: 'All' }]}
        value={'gone' as 'all'}
        onChange={() => {}}
        label="Logins it can use"
      />,
    )
    expect(html).not.toContain('aria-pressed="true"')
  })

  it('carries a title only where one was given', () => {
    const html = renderToStaticMarkup(
      <SegmentedSwitch
        options={[
          { id: 'here', label: 'Studio', title: 'The configuration on Studio' },
          { id: 'm1', label: 'DESKTOP-DDGMNCV' },
        ]}
        value="here"
        onChange={() => {}}
        label="Which machine"
      />,
    )
    expect(html).toContain('title="The configuration on Studio"')
    expect(html.match(/title=/g)).toHaveLength(1)
  })

  it('disables every button at once, so a write in flight cannot be raced', () => {
    const html = renderToStaticMarkup(
      <SegmentedSwitch
        options={[
          { id: 'all', label: 'All' },
          { id: 'selected', label: 'Selected' },
        ]}
        value="all"
        onChange={() => {}}
        label="Logins it can use"
        disabled
      />,
    )
    expect(html.match(/disabled=""/g)).toHaveLength(2)
  })

  /**
   * The margin cancellation is an attribute with a rule behind it, not a class
   * each caller invents. `.da-scope` is what inventing one looks like.
   */
  it('cancels the pane-top margin with an attribute the stylesheet knows', () => {
    const html = renderToStaticMarkup(
      <SegmentedSwitch
        options={[{ id: 'all', label: 'All' }]}
        value="all"
        onChange={() => {}}
        label="Logins it can use"
        inline
      />,
    )
    expect(html).toContain('data-inline=""')
    expect(ALL_CSS).toMatch(/\.settings-scope\[data-inline\]\s*\{/)
  })

  it('leaves the margin alone when it is at the top of a pane', () => {
    const html = renderToStaticMarkup(
      <SegmentedSwitch
        options={[{ id: 'all', label: 'All' }]}
        value="all"
        onChange={() => {}}
        label="Logins it can use"
      />,
    )
    expect(html).not.toContain('data-inline')
  })
})

describe('nobody builds a second one', () => {
  /**
   * Nothing outside this component may write the class into markup.
   *
   * A `className="settings-scope"` anywhere else is a copy of the control by
   * definition — that string is how the copy gets its look — and every copy this
   * repo has had was made that way. Stylesheets and comments are not searched;
   * only what a component hands to React.
   */
  it('is the only file that puts the class into markup', () => {
    const offenders = SOURCE.filter((file) => {
      if (file === OWNER) return false
      const text = readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
      return /className=["'`][^"'`]*settings-scope/.test(text)
    }).map((file) => file.slice(ROOT.length + 1))
    expect(offenders).toEqual([])
  })

  /**
   * And nobody re-types the two words either.
   *
   * `SHARE_MODES` in `remote/share-mode.ts` holds them, because the ternary
   * `mode === 'all' ? 'All' : 'Selected'` had been typed three times, once per
   * copy of the switch. Words drift the way markup does, and a fourth panel
   * asking the same question calling it *Some* or *Chosen* would leave the
   * screen holding two names for one idea.
   */
  it('has one spelling of All and Selected', () => {
    const offenders = SOURCE.filter((file) => {
      if (file.endsWith('.test.tsx') || file.endsWith('.test.ts')) return false
      // Comments out: `share-mode.ts` quotes the ternary it replaced, and a
      // scan that counted the explanation would be a check on its own prose.
      const text = readFileSync(file, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
      return /\?\s*'All'\s*:\s*'Selected'/.test(text)
    }).map((file) => file.slice(ROOT.length + 1))
    expect(offenders).toEqual([])
  })

  /**
   * The Coding AI switch is this component, rather than a lookalike.
   *
   * `ScopeSwitch` is the control Asad names when he asks for one *"just like in
   * coding ai page in settings"*, and the way that stays true is that it is not
   * a separate implementation to keep in step. Rendered side by side, the two
   * produce the same element with the same attributes.
   */
  it('is what the Coding AI scope switch renders', () => {
    const scope = renderToStaticMarkup(<ScopeSwitch scope="servers" onScope={() => {}} />)
    const shared = renderToStaticMarkup(
      <SegmentedSwitch
        options={[
          { id: 'this-machine', label: 'This machine' },
          { id: 'servers', label: 'Servers' },
        ]}
        value="servers"
        onChange={() => {}}
        label="Where these agents run"
      />,
    )
    expect(scope).toBe(shared)
  })

  /**
   * And every class a component *does* put in its markup has a rule somewhere.
   *
   * This is `.da-scope`, generalised. That class was in the markup for weeks, in
   * a file carrying 293 lines of its own tests, and nothing could see it because
   * **a class that styles nothing renders perfectly** — no error, no warning, no
   * failing assertion, just a control sitting in somebody else's spacing.
   *
   * Running it repo-wide the first time found seventeen, in eight files. Three
   * were on the very step this round was auditing: `.da-logins`, `.da-login` and
   * `.da-login-name` on the approval card, which is why that step drew a
   * browser-default bulleted list of checkboxes one card away from an identical,
   * styled list of folders. Those three are fixed.
   *
   * ## Why this is a floor and not an equality
   *
   * The rest are in files this lane does not own, and a test asserting the exact
   * set would go red the moment somebody *fixed* one — which is a check that
   * punishes the repair. So the assertion is **no new ones**: the ledger below
   * may only ever shrink, and the fix for a name that is not in it is a CSS rule,
   * never another line in the ledger.
   *
   * Test files are not searched. Their markup is stand-ins — `.folders-stand-in`,
   * `.probe` — which is exactly what a stand-in should be: unstyled.
   */
  /**
   * The names that were already unstyled when this check was written.
   *
   * Not all of them are defects, which is the other reason this is a ledger
   * rather than a sweep: `bw-start-port-mark` says in place that its size and
   * ink are attributes and *"the class is there for a rule that may later want
   * one"*, and `cc-reading` is a hook `control-room.ts` measures the cluster by,
   * read from JavaScript and never from CSS. A class with no rule is sometimes a
   * decision. The point of the check is that the **next** one has to be a
   * decision too, rather than a typo nothing can see.
   */
  const KNOWN_DANGLING: readonly string[] = [
    // gridstack's own, from the stylesheet it ships in node_modules. Real rules,
    // just not ones this repo wrote — the scan reads only `src`.
    'grid-stack-item-content',
    'widget-drag-handle',
    // Deliberate, and argued in place at the element.
    'bw-start-port-mark',
    'cc-reading',
    // Not investigated by this lane, in files it does not own.
    'ac-reach-scope',
    'file-tree-branch',
    'servers-card-said-text',
    'account-chip-run',
    'account-menu-editing',
    'ub-cx-amount',
  ]

  it('has a rule for every class it puts in markup', () => {
    const dangling: string[] = []
    for (const file of SOURCE) {
      if (file.endsWith('.test.tsx') || file.endsWith('.test.ts')) continue
      const text = readFileSync(file, 'utf8')
      for (const match of text.matchAll(/className=["']([a-z][a-z0-9- ]*)["']/g)) {
        for (const name of match[1].split(/\s+/).filter((part) => part !== '')) {
          if (name === 'settings-scope') continue
          if (KNOWN_DANGLING.includes(name)) continue
          if (!ALL_CSS.includes(`.${name}`)) {
            dangling.push(`${file.slice(ROOT.length + 1)}: .${name} styles nothing`)
          }
        }
      }
    }
    expect(dangling).toEqual([])
  })
})
