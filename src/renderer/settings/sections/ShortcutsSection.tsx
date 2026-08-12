import { SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import { ShortcutsList } from '../../components/ShortcutsSheet'

/**
 * Shortcuts.
 *
 * Rendered by `ShortcutsList`, which already builds the whole sheet out of
 * `KEYMAP` with `formatBinding` and groups it by scope. Reusing it is the whole
 * point of that split: a second implementation here would be a second copy of
 * the keymap's presentation, and the printed copy is the one that silently
 * rots — which is exactly what the list this window replaces had done.
 *
 * Read-only, deliberately. Nothing in the app can rebind a chord yet, and a
 * control that looked editable would be a promise the keymap cannot keep.
 */
export function ShortcutsSection() {
  const meta = sectionMeta('shortcuts')
  return (
    <>
      <SectionHead title={meta.label} blurb={`${meta.blurb} They cannot be changed yet.`} />
      <ShortcutsList />
    </>
  )
}
