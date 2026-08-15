import { useCallback, useEffect, useState } from 'react'
import { Notice, SectionHead, SettingList, type OptionState } from '../controls'
import { sectionMeta } from '../settings-schema'
import { turnedOnABanner, useNotificationCheck } from '../notification-check'
import {
  errorText,
  toPrerequisites,
  type Prerequisites,
  type SectionProps,
} from '../settings-bridge'

/**
 * General — the nine settings someone actually opens this window to change.
 *
 * Every row is generated from the schema, so the order and the wording live in
 * `settings-schema.ts` and not here. The one thing this file adds is the state
 * of the coding-tool picker: which tools exist is *discovered* by
 * `prerequisites.ts` asking the login shell what is on PATH, so an option is
 * disabled and labelled "not installed" rather than quietly offered. Choosing a
 * default that cannot start is how you get a session that opens and closes.
 *
 * Nothing here talks to `profiles.ts` or lists what is installed — Agents still
 * owns both, and this section links to it instead of growing a second copy.
 */

/** Suffix for the picker. Short — it renders inside an <option>. */
export function optionStateFor(prereq: Prerequisites | null, value: string): OptionState {
  // A plain shell is always available; it is the fallback the main process
  // already falls back to when a requested provider is missing.
  if (value === 'shell' || !prereq) return {}
  const tool = prereq.tools.find((entry) => entry.id === value)
  if (!tool) return {}
  if (tool.state === 'missing') return { disabled: true, suffix: 'not installed' }
  if (tool.state === 'installed-not-authed') return { suffix: 'sign-in needed' }
  return {}
}

export function GeneralSection({ values, save, bridge, loading, goTo }: SectionProps) {
  const meta = sectionMeta('general')
  const [prereq, setPrereq] = useState<Prerequisites | null>(null)
  const [error, setError] = useState<string | null>(null)
  const check = useNotificationCheck({ bridge })

  /**
   * Save, and prove it when a banner setting is the thing being switched on.
   *
   * The OS only ever asks for notification authorisation once, and on macOS it
   * asks *with a banner* whose Allow is hidden under an `Options` control. The
   * only safe moment to trigger that is while the user is looking at the switch
   * they just flipped — see `notification-check.ts`. This switch lives in
   * General and the test button lives in Notifications, so without this the
   * user could turn banners on here and never once be in front of the prompt.
   *
   * `turnedOnABanner` rather than this section's own id, so that a switch
   * moving between sections cannot detach the ask from the switch.
   */
  const saveAndProve = useCallback(
    (patch: Record<string, unknown>) => {
      save(patch)
      if (turnedOnABanner(patch)) check.confirmEnabled()
    },
    [save, check],
  )

  useEffect(() => {
    if (!bridge.checkPrerequisites) return
    // The window can be closed while this is in flight, and Agents runs the
    // same check — whichever answer arrives after the section is gone must not
    // set state into an unmounted tree.
    let live = true
    void bridge.checkPrerequisites().then(
      (raw) => {
        if (live) setPrereq(toPrerequisites(raw))
      },
      (cause: unknown) => {
        if (live) setError(errorText(cause, 'Could not check which coding tools are installed.'))
      },
    )
    return () => {
      live = false
    }
  }, [bridge])

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {error && <Notice tone="error">{error}</Notice>}

      <SettingList
        section="general"
        values={values}
        save={saveAndProve}
        disabled={loading}
        optionStates={{
          'general.defaultProvider': (value) => optionStateFor(prereq, value),
        }}
        extras={{
          'general.defaultProvider': (
            <span className="settings-help">
              Greyed-out tools are not on your PATH.{' '}
              <button type="button" className="settings-inline-btn" onClick={() => goTo('agents')}>
                See what is installed
              </button>
            </span>
          ),
        }}
      />

      {check.state && (
        <Notice tone={check.state.tone}>
          {check.state.text}
          {check.state.offerSettings && check.canOpenSettings && (
            <>
              {' '}
              <button
                type="button"
                className="settings-inline-btn"
                onClick={check.openSettings}
              >
                Open notification settings
              </button>
            </>
          )}
        </Notice>
      )}
    </>
  )
}
