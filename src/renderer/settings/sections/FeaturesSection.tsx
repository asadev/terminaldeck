import { useId, useState } from 'react'
import { Button, Explain, Group, SectionHead, Switch } from '../controls'
import { sectionMeta } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'
import { useFeatures } from '../../features/FeaturesProvider'
import type { Feature, FeatureId } from '../../features/registry'
import {
  availableFeatures,
  clearFeatureData,
  defaultFeatureState,
  installedFeatures,
  uninstallPlan,
} from '../../features/state'
import './FeaturesSection.css'

/**
 * The store, and the list of what is installed, on one screen.
 *
 * Two groups rather than two pages: the whole list is ten rows, and a person
 * asking "what else is there" and a person asking "what have I got" are looking
 * at the same ten things from opposite ends. Splitting them into separate
 * screens would add a navigation step to a list that fits without scrolling.
 *
 * ## The three states, and why the middle one exists
 *
 * A row is uninstalled, installed and off, or installed and on. **Off keeps your
 * settings and your data; uninstalled removes them.** That is stated on screen
 * rather than implied, because the only way to learn it otherwise is to
 * uninstall something and find out what went with it.
 *
 * ## What uninstalling says
 *
 * Exactly what it will delete, named. *"Are you sure?"* is not a question
 * anybody can answer — it asks for a decision while withholding the fact the
 * decision turns on. Where a feature stores nothing of yours, that is said too,
 * in words, because "nothing will be deleted" is precisely what somebody
 * hovering over the button wants to know.
 */

/**
 * The row's own state in words, or null when the switch beside it has already
 * said the same thing.
 *
 * An installed, switched-on row printed a literal "On" under its description —
 * a third line of type, left-aligned, six hundred pixels from the switch that
 * was already saying it, on every one of six rows. The two states that are
 * *not* obvious from a switch keep their line: "off" has to say that your
 * settings survived it, and "not installed" is not a switch position at all.
 */
export function statusLabel(status: 'on' | 'off' | 'uninstalled'): string | null {
  switch (status) {
    case 'on':
      return null
    case 'off':
      return 'Off — your settings are kept'
    case 'uninstalled':
      return 'Not installed'
  }
}

export function FeaturesSection({ save, bridge }: SectionProps) {
  const meta = sectionMeta('features')
  const features = useFeatures()
  const ids = useId()

  /** The uninstall waiting for an answer. One at a time, by construction. */
  const [confirming, setConfirming] = useState<FeatureId | null>(null)
  /**
   * The feature just installed.
   *
   * Held so the row can say where the thing went. That sentence is the whole of
   * the onboarding — it is the difference between "installed" and "installed,
   * and it is the button beside New session" — so it names a real place, from
   * the registry, and never a category.
   */
  const [justInstalled, setJustInstalled] = useState<FeatureId | null>(null)

  const installed = installedFeatures(features.state)
  const available = availableFeatures(features.state)

  /* Whether anything has been changed away from what a fresh install has.
     The reset offers itself only when it would do something. */
  const defaults = defaultFeatureState()
  const changed = Object.keys(defaults).some(
    (id) => features.state[id] !== undefined && features.state[id] !== defaults[id],
  )

  const installedRow = (entry: Feature) => {
    const status = features.status(entry.id)
    const nameId = `${ids}-${entry.id}-name`
    const plan = uninstallPlan(entry.id)
    const confirmingThis = confirming === entry.id
    const state = statusLabel(status)

    return (
      <li key={entry.id} className="feat-row" data-status={status}>
        <div className="feat-main">
          <div className="feat-text">
            <span className="feat-name" id={nameId}>
              {entry.name}
            </span>
            <span className="feat-summary">{entry.summary}</span>
            {state && <span className="feat-status">{state}</span>}
          </div>
          <div className="feat-actions">
            <Switch
              checked={status === 'on'}
              labelledBy={nameId}
              onChange={(next) => {
                features.setEnabled(entry.id, next)
                setJustInstalled(null)
              }}
            />
            <Button
              tone="danger"
              onClick={() => setConfirming(confirmingThis ? null : entry.id)}
            >
              Uninstall
            </Button>
          </div>
        </div>

        {justInstalled === entry.id && (
          <p className="feat-found" role="status">
            Installed. You will find it in {entry.where}
          </p>
        )}

        {confirmingThis && (
          <div className="feat-confirm" role="group" aria-label={`Uninstall ${entry.name}`}>
            {plan.length === 0 ? (
              <p className="feat-confirm-line">
                Nothing of yours is stored by this, so nothing will be deleted. Installing it again
                puts it back exactly as it is now.
              </p>
            ) : (
              <>
                <p className="feat-confirm-line">Uninstalling deletes:</p>
                <ul className="feat-confirm-list">
                  {plan.map((item) => (
                    <li key={item.label}>
                      {item.label}
                      {item.detail && <span className="feat-confirm-detail">{item.detail}</span>}
                    </li>
                  ))}
                </ul>
              </>
            )}
            {entry.keeps && <p className="feat-confirm-line feat-keeps">Kept: {entry.keeps}</p>}
            <div className="feat-confirm-actions">
              <Button
                tone="danger"
                onClick={() => {
                  // The data first, then the switch. In the other order a
                  // failure between the two leaves a feature that is gone from
                  // the window with its data still on disk and nothing on
                  // screen that could offer to finish the job.
                  clearFeatureData(entry.id, {
                    save,
                    clearBrowserData: bridge.clearBrowserData,
                  })
                  features.uninstall(entry.id)
                  setConfirming(null)
                  setJustInstalled(null)
                }}
              >
                Uninstall {entry.name}
              </Button>
              <Button onClick={() => setConfirming(null)}>Keep it</Button>
            </div>
          </div>
        )}
      </li>
    )
  }

  const availableRow = (entry: Feature) => (
    <li key={entry.id} className="feat-row" data-status="uninstalled">
      <div className="feat-main">
        <div className="feat-text">
          <span className="feat-name">{entry.name}</span>
          <span className="feat-summary">{entry.summary}</span>
        </div>
        <div className="feat-actions">
          {/*
            A plain button, not the accent one.

            Every available feature offering itself in filled blue put six of
            them on screen at once, plus the dialog's own Done — and "a screen
            where four things are blue has no accent at all". The accent marks
            *the* action of a screen, and this screen has ten equal ones: a list
            you read down and mostly leave alone. The FeatureOffer page is where
            Install is genuinely the one thing to do, and that is where it is
            filled.
          */}
          <Button
            onClick={() => {
              features.install(entry.id)
              setJustInstalled(entry.id)
              setConfirming(null)
            }}
          >
            Install
          </Button>
        </div>
      </div>
    </li>
  )

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <Explain title="Nothing is downloaded">
        Every feature is already inside the app, so installing one switches it on and putting one
        back is instant. Turning a feature off keeps its settings and its data; uninstalling clears
        them, and says exactly what it is clearing first.
      </Explain>

      <Group title="Installed">
        {installed.length === 0 ? (
          <p className="feat-empty">
            Nothing is installed. Everything below is one click away, and the app works without any
            of it.
          </p>
        ) : (
          <ul className="feat-list">{installed.map(installedRow)}</ul>
        )}
      </Group>

      <Group title="Available">
        {available.length === 0 ? (
          <p className="feat-empty">Everything is installed.</p>
        ) : (
          <ul className="feat-list">{available.map(availableRow)}</ul>
        )}
      </Group>

      {changed && (
        <Group>
          <div className="feat-reset">
            <Button
              onClick={() => {
                features.resetToDefaults()
                setConfirming(null)
                setJustInstalled(null)
              }}
            >
              Back to the starter set
            </Button>
            <span className="feat-summary">
              Puts every feature back to what a new install has. It deletes nothing.
            </span>
          </div>
        </Group>
      )}
    </>
  )
}
