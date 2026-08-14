import { HelpPanel } from '../../components/HelpPanel'
import { SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'

/**
 * Help — the ⌘? panel, rendered inside Preferences.
 *
 * `HelpPanel` is imported rather than copied, and that is the whole point of
 * this file. The help text is generated from `keymap.ts` and `shell/panels.ts`
 * precisely so it cannot drift; a second copy for this window would drift on
 * the first day, and the wrong copy is always the one the user is reading.
 * `HelpDialog` is the same component wrapped in a `Modal`, so both routes show
 * the same words, search the same topics and print the same shortcuts.
 *
 * Two adjustments, both about living inside a tab panel rather than a dialog:
 *
 *  - `autoFocus` is off. The panel focuses its search field on mount, which is
 *    right when a dialog opens on top of everything, and wrong here — the
 *    section list is an arrow-key tab list, so arrowing onto Help would have
 *    thrown focus into the search box and stranded the user outside the list.
 *  - No `onOpenDebug`. That link opens a panel in the main window, which this
 *    window is sitting in front of; a button that appears to do nothing is
 *    worse than no button.
 *  - No Shortcuts and no About. This window's own nav already has a row for
 *    each, two rows below Help, and the panel was drawing a second nav offering
 *    a second way into both — the same keymap and the same version numbers,
 *    reachable two ways from one screen.
 */
export const OWNED_BY_THE_SETTINGS_NAV = ['shortcuts', 'about'] as const

export function HelpSection() {
  const meta = sectionMeta('help')
  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />
      <HelpPanel autoFocus={false} hideSections={OWNED_BY_THE_SETTINGS_NAV} />
    </>
  )
}
