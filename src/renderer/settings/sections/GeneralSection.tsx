import { SectionHead, SettingList } from '../controls'
import { sectionMeta } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'

/**
 * General — the handful of choices that change how a session behaves without
 * changing how it looks. Every row here is generated from the schema; there is
 * deliberately nothing bespoke to explain.
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
