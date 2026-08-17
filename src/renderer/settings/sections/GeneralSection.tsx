import { SectionHead, SettingList } from '../controls'
import { sectionMeta } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'

/**
 * General — how a session behaves while you work, and nothing else.
 *
 * This section used to be the drawer everything ended up in. It held the
 * coding-tool picker with a link to Agents underneath it, and two notification
 * switches whose own help text pointed at Notifications, which is a section
 * apologising for its own contents. Both subjects have gone to the sections
 * that own them:
 *
 *   > "if this is related to agent, it should be either inside the agents…
 *   > everything should be in one place so they don't have to think."
 *
 * What arrived in exchange is "Pick up where you left off", which had been
 * filed under Advanced next to the log folder and the reset button. What
 * happens to your sessions is this section's subject; diagnostics is not.
 *
 * Every row is generated from the schema, so the order and the wording live in
 * `settings-schema.ts`. There is nothing else on this pane on purpose — no
 * standing prose at all, which is the state every pane in this window is aiming
 * at and the one General can actually reach.
 */
export function GeneralSection({ values, save, loading }: SectionProps) {
  const meta = sectionMeta('general')
  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />
      <SettingList section="general" values={values} save={save} disabled={loading} />
    </>
  )
}
