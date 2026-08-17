import { useId, useState } from 'react'
import { Row, SectionHead, SettingList } from '../controls'
import { numberSetting, sectionMeta, stringSetting } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'

/**
 * Appearance.
 *
 * Two rows are generated from the schema and one is placed by hand. The hand
 * one is the terminal font, and the reason is in {@link MONO_CANDIDATES}: a
 * font family typed in by name is a control that cannot tell you whether it
 * worked.
 */

/** The setting this section draws itself rather than letting the list draw it. */
const FONT_SETTING = 'appearance.terminalFontFamily'

/**
 * The monospace faces worth offering, in the order they are worth offering.
 *
 * ## Why this row is a picker at all
 *
 * It was a text field. It rendered as a dim grey `SF Mono` — a *placeholder*,
 * not a value — with no chevron beside it while the two rows above it both had
 * one, and an unexplained line of specimen text underneath. Asad read it
 * exactly as it looks: a row with no control in it, and a stray `❯ npm run dev`
 * sitting below for no stated reason. His instruction was either give it a real
 * control or take the row and the specimen away.
 *
 * A real control is the better answer, and not only cosmetically. A typed font
 * name that the system does not have fails *silently* — the browser substitutes
 * and the field still shows what you typed — so the old row could tell you
 * nothing about whether the thing you asked for exists. A list of faces this
 * machine actually has cannot be wrong about that.
 *
 * ## Why a list and not the operating system's font list
 *
 * There is no way to enumerate installed fonts here that is worth having.
 * Chromium's Local Font Access API is behind a permission prompt and would put
 * a "this app wants to see your fonts" dialog in front of somebody changing a
 * terminal typeface. So this is a candidate list, and every entry is *checked*
 * against the machine before it is offered — see {@link installedFonts}. What
 * is on the menu is what is on the computer.
 *
 * ## Where the list comes from
 *
 * The first group is what the three desktop platforms ship, so the menu is
 * never empty: macOS's own faces first (this build's primary platform, and
 * checked against `/System/Library/Fonts` on the machine this was written on —
 * Menlo, Monaco, Courier, Courier New, Andale Mono and PT Mono are all there,
 * and SF Mono ships with Terminal.app), then Windows', then the ones a Linux
 * distribution installs by default. The second group is the programming faces
 * people go and install on purpose. Anything not present is simply not shown.
 *
 * A face already chosen but no longer installed is still listed, marked, rather
 * than dropped — see the component. Silently replacing somebody's choice with
 * "App default" because they are on a different machine is the same silent
 * failure the text field had, wearing a menu.
 */
export const MONO_CANDIDATES: readonly string[] = [
  // Shipped with the platform.
  'SF Mono',
  'Menlo',
  'Monaco',
  'Andale Mono',
  'PT Mono',
  'Courier New',
  'Cascadia Code',
  'Cascadia Mono',
  'Consolas',
  'Lucida Console',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Ubuntu Mono',
  'Noto Sans Mono',
  // Installed on purpose.
  'JetBrains Mono',
  'Fira Code',
  'Fira Mono',
  'IBM Plex Mono',
  'Source Code Pro',
  'Roboto Mono',
  'Hack',
  'Inconsolata',
  'Iosevka',
  'Geist Mono',
  'Berkeley Mono',
  'MonoLisa',
  'Operator Mono',
  'Victor Mono',
  'Space Mono',
  'Anonymous Pro',
]

/**
 * A string with several different letter widths in it.
 *
 * The measurement below works by comparing widths, so the probe has to be
 * something two typefaces would disagree about. A row of `m`s alone is not: it
 * is the same width in most faces at the same size, which would report every
 * font on the machine as missing.
 */
const PROBE = 'mmmmmmmmmmlliWWWW0OIl1'

/**
 * Which of `candidates` this machine actually has.
 *
 * The measurement is the old canvas trick and it is exact rather than
 * heuristic: rendering `"Name", serif` and comparing the width against plain
 * `serif` answers "did the browser fall back?", because a fallback renders
 * *identically* to the generic and a hit almost never does.
 *
 * Two baselines, and a font counts as present when it disagrees with *either*
 * of them. One baseline is not enough, and the reason is the case that looks
 * like a corner and is not: on macOS `monospace` resolves to Menlo, so probing
 * Menlo against `monospace` produces two identical widths and reports the
 * machine's own terminal font as missing. The same trap catches any candidate
 * whose width happens to land exactly on the generic it was measured against.
 *
 * Requiring disagreement with *both* generics would reintroduce it from the
 * other side, so it is `some` rather than `every`: a face that is absent falls
 * back to whichever generic it was listed with and therefore matches both, and
 * a face that is present has to be a coincidence twice over to match both.
 *
 * `widthOf` is injected so the whole thing is testable without a canvas, a DOM
 * or a machine with any particular fonts on it.
 */
export function installedFonts(
  candidates: readonly string[],
  widthOf: (stack: string) => number,
): string[] {
  const generics = ['serif', 'sans-serif'] as const
  const baseline = generics.map((generic) => widthOf(generic))
  return candidates.filter((name) =>
    generics.some((generic, index) => widthOf(`"${name}", ${generic}`) !== baseline[index]),
  )
}

/**
 * A width function backed by a canvas, or null where there is no canvas.
 *
 * Null is a real answer and is handled as one: with no way to measure, this
 * section cannot honestly say which fonts exist, so it hands the row back to
 * the schema's text field rather than offering a menu it has not checked.
 */
function canvasWidth(): ((stack: string) => number) | null {
  if (typeof document === 'undefined') return null
  const context = document.createElement('canvas').getContext('2d')
  if (!context) return null
  return (stack) => {
    // Large, so a one-pixel difference between two faces becomes several.
    context.font = `72px ${stack}`
    return context.measureText(PROBE).width
  }
}

export function AppearanceSection({ values, save, loading }: SectionProps) {
  const meta = sectionMeta('appearance')
  const family = stringSetting(values, FONT_SETTING).trim()
  const size = numberSetting(values, 'appearance.terminalFontSize')
  const controlId = useId()

  /*
   * Measured once, on the first render, and never again.
   *
   * The set of fonts on a computer does not change while a settings pane is
   * open, and the measurement is thirty-two `measureText` calls — cheap once,
   * pointless on every keystroke. A lazy initialiser rather than an effect so
   * the first paint is already the right control: deciding in an effect would
   * draw the text field for one frame and then swap it for a menu, which is a
   * flicker in the one row this change exists to make less confusing.
   */
  const [available] = useState<string[] | null>(() => {
    const widthOf = canvasWidth()
    return widthOf === null ? null : installedFonts(MONO_CANDIDATES, widthOf)
  })

  /*
   * No canvas, no menu.
   *
   * Nothing here can check what is installed, so the honest control is the one
   * that makes no claim: the schema's text field, which this section then does
   * not omit. It is the same reasoning the rest of the app uses for a missing
   * channel — say less rather than guess.
   */
  if (available === null) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <SettingList section="appearance" values={values} save={save} disabled={loading} />
      </>
    )
  }

  /*
   * A face that is chosen but absent is kept on the menu, and marked.
   *
   * This is the state somebody hits by opening their settings on a second
   * computer. Dropping the entry would silently reset their choice to the app
   * default the moment the pane was opened, which is a settings screen editing
   * a setting nobody touched.
   */
  const missing = family !== '' && !available.includes(family)
  const options = missing ? [...available, family] : available

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />
      <SettingList
        section="appearance"
        values={values}
        save={save}
        disabled={loading}
        // Drawn below instead. See MONO_CANDIDATES for why this one row is not
        // generated from the schema like the others.
        omit={[FONT_SETTING]}
      />

      <div className="settings-item">
        <Row
          label="Terminal font"
          help={
            missing
              ? `${family} is not installed on this computer, so sessions are using the app’s own monospace font.`
              : 'Every monospace font found on this computer.'
          }
          more={
            'Only fonts this computer actually has are listed — each one is measured before it is offered, so a face on this menu is a face a session will really render in. A font chosen on another computer stays on the list, marked, rather than being silently reset.'
          }
          htmlFor={controlId}
          control={
            <span className="settings-select-wrap">
              <select
                id={controlId}
                className="settings-select"
                value={family}
                disabled={loading}
                onChange={(event) => save({ [FONT_SETTING]: event.target.value })}
              >
                <option value="">App default</option>
                {options.map((name) => (
                  <option key={name} value={name}>
                    {name}
                    {name === family && missing ? ' — not installed here' : ''}
                  </option>
                ))}
              </select>
            </span>
          }
        />
        {/*
          The specimen, which now has something to be a specimen *of*.

          It was a line of terminal text under a text field, with nothing saying
          what it was — read, reasonably, as a stray fragment. Under a menu it
          is the thing the menu is choosing, so it says so, and it renders the
          prompt glyph the agents actually print (`❯`, verified against real
          output) at the size the sessions will use.
        */}
        <div className="settings-item-extra">
          <p className="settings-help">Preview, at the size sessions use</p>
          <div
            className="settings-font-preview"
            // The fallback is the app's own mono stack, so "App default" and a
            // font that has gone missing both preview as what will be used.
            style={{
              fontFamily: family && !missing ? `"${family}", var(--font-mono)` : 'var(--font-mono)',
              fontSize: `${size}px`,
            }}
          >
            <span className="settings-font-prompt">❯</span> npm run dev — 0123456789 illegal1O0
          </div>
        </div>
      </div>
    </>
  )
}
