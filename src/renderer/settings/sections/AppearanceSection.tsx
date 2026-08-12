import { SectionHead, SettingList } from '../controls'
import { numberSetting, sectionMeta, stringSetting } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'

/**
 * Appearance.
 *
 * The one thing beyond generated rows is the terminal preview. A font family is
 * typed in by name, and a name the system does not have fails silently — the
 * browser substitutes and everything looks fine until a session opens. Showing
 * the chosen font rendering the prompt glyph the agents actually print (`❯`,
 * verified against real output) makes a wrong name visible while the field is
 * still focused.
 */
export function AppearanceSection({ values, save, loading }: SectionProps) {
  const meta = sectionMeta('appearance')
  const family = stringSetting(values, 'appearance.terminalFontFamily').trim()
  const size = numberSetting(values, 'appearance.terminalFontSize')

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />
      <SettingList
        section="appearance"
        values={values}
        save={save}
        disabled={loading}
        extras={{
          'appearance.terminalFontFamily': (
            <div
              className="settings-font-preview"
              // The fallback is the app's own mono stack, so an empty field and
              // an unavailable font both preview as what will actually be used.
              style={{
                fontFamily: family ? `${family}, var(--font-mono)` : 'var(--font-mono)',
                fontSize: `${size}px`,
              }}
            >
              <span className="settings-font-prompt">❯</span> npm run dev — 0123456789 illegal1O0
            </div>
          ),
        }}
      />
    </>
  )
}
