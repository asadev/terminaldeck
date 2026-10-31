import { useCallback, useEffect, useId, useMemo, useState } from 'react'
import { BRAND } from '../../../shared/brand'
import {
  CAPABILITY_WORDS,
  PROJECT_SCOPED,
  type PluginCapability,
  type PluginsState,
  type PluginView,
} from '../../../shared/plugins'
import { Button, Explain, Group, Notice, Row, SectionHead, Switch } from '../controls'
import { sectionMeta } from '../settings-schema'
import {
  projectName,
  resolvePluginsBridge,
  toPluginsResult,
  toPluginsState,
  type PluginsBridge,
} from '../../plugins/plugins-model'
import './PluginsSection.css'

/**
 * Settings → Plugins.
 *
 * Programs other people wrote, which the person put in the plugins folder by
 * hand. Each row says what the plugin asks for, what it was allowed, and what
 * state it is in, with the three things a person can do about it: allow (or
 * change what it is allowed), turn it on or off, and remove it.
 *
 * Allowing something new is never decided on this page. The Allow button sends
 * the choice to the main process, which puts the question in a dialog the
 * operating system draws; this page only shows what came back. Taking a
 * permission away is saved straight off, because that direction needs no
 * question.
 */

type Run = (change: () => Promise<unknown> | undefined) => Promise<boolean>

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

const STATE_WORDS: Readonly<Record<PluginView['state'], string>> = Object.freeze({
  off: 'Off',
  'needs-ok': 'Not allowed',
  changed: 'Changed',
  running: 'Running',
  stopped: 'Stopped',
  broken: 'Cannot be used',
})

export function PluginsSection({ bridge: injected }: { bridge?: Partial<PluginsBridge> } = {}) {
  const meta = sectionMeta('plugins')
  const bridge = useMemo(() => injected ?? resolvePluginsBridge(), [injected])
  const [state, setState] = useState<PluginsState | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const wired = typeof bridge.pluginsState === 'function'

  const load = useCallback(async () => {
    if (!bridge.pluginsState) return
    try {
      const next = toPluginsState(await bridge.pluginsState())
      setProblem(next === null ? 'The app answered with something this page cannot read.' : null)
      if (next !== null) setState(next)
    } catch (error) {
      setProblem(errorText(error))
    }
  }, [bridge])

  useEffect(() => {
    void load()
    return bridge.onPluginsChanged?.(() => void load())
  }, [bridge, load])

  /** Run one change, keep the state it came back with, and show its refusal if it was one. */
  const run = useCallback<Run>(async (change) => {
    const pending = change()
    if (!pending) return false
    setBusy(true)
    try {
      const result = toPluginsResult(await pending)
      if (result.state) setState(result.state)
      setProblem(result.ok ? null : (result.message ?? 'That did not go through.'))
      return result.ok
    } catch (error) {
      setProblem(errorText(error))
      return false
    } finally {
      setBusy(false)
    }
  }, [])

  if (!wired) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <Notice>This build has no channels for plugins wired into its preload.</Notice>
      </>
    )
  }

  return (
    <div className="plugins">
      <SectionHead title={meta.label} blurb={meta.blurb} />
      {problem && <Notice tone="error">{problem}</Notice>}
      {state === null ? (
        <p className="plugins-quiet">Reading the plugins folder…</p>
      ) : (
        <>
          <Explain title="Adding one">
            Put a plugin’s folder in {state.folder}. Nothing is ever downloaded for you, and nothing in a new folder runs
            until you allow it here.{' '}
            <Button disabled={busy || !bridge.pluginsOpenFolder} onClick={() => void bridge.pluginsOpenFolder?.()}>
              Show the folder
            </Button>
          </Explain>
          <Explain title="What holds it in">{state.confinement}</Explain>
          <PluginList state={state} busy={busy} bridge={bridge} run={run} />
        </>
      )}
    </div>
  )
}

/* ------------------------------------------------------------------ list -- */

export function PluginList({
  state,
  busy,
  bridge,
  run,
}: {
  state: PluginsState
  busy: boolean
  bridge: Partial<PluginsBridge>
  run: Run
}) {
  const [editing, setEditing] = useState<string | null>(null)
  const [removing, setRemoving] = useState<string | null>(null)
  const ids = useId()

  return (
    <Group title="Plugins">
      {state.plugins.length === 0 && <p className="plugins-quiet">No plugins yet.</p>}
      <ul className="settings-profiles">
        {state.plugins.map((plugin, index) => (
          <li key={plugin.id} className="settings-profile plugins-item" data-state={plugin.state}>
            <div className="settings-profile-main">
              <span className="settings-profile-name" id={`${ids}-${index}`}>
                {plugin.name}
                {plugin.version !== '' && <span className="settings-badge quiet">{plugin.version}</span>}
                <span className="settings-badge quiet">{STATE_WORDS[plugin.state]}</span>
              </span>
              {plugin.summary !== '' && <span className="settings-tool-note">{plugin.summary}</span>}
              <span className="settings-tool-note">{plugin.note}</span>
              <Capabilities plugin={plugin} />
              {plugin.tools.length > 0 && (
                <span className="settings-tool-note">
                  Tools for {BRAND.assistant}: {plugin.tools.map((tool) => `${tool.title} (${tool.tier})`).join(', ')}
                </span>
              )}
            </div>
            <div className="settings-profile-actions">
              {plugin.allowed && (
                <Switch
                  checked={plugin.enabled}
                  disabled={busy || !bridge.pluginsEnable}
                  labelledBy={`${ids}-${index}`}
                  onChange={(next) => void run(() => bridge.pluginsEnable?.(plugin.id, next))}
                />
              )}
              {plugin.state !== 'broken' && (
                <Button
                  tone={plugin.allowed ? 'default' : 'primary'}
                  disabled={busy}
                  onClick={() => setEditing(editing === plugin.id ? null : plugin.id)}
                >
                  {editing === plugin.id ? 'Close' : plugin.allowed ? 'Change' : plugin.state === 'changed' ? 'Allow again…' : 'Allow…'}
                </Button>
              )}
              <Button tone="danger" disabled={busy} onClick={() => setRemoving(removing === plugin.id ? null : plugin.id)}>
                Remove…
              </Button>
            </div>
            {editing === plugin.id && (
              <AllowForm
                plugin={plugin}
                projects={state.projects}
                busy={busy}
                onCancel={() => setEditing(null)}
                onAllow={async (input) => {
                  if (await run(() => bridge.pluginsAllow?.(plugin.id, input))) setEditing(null)
                }}
              />
            )}
            {removing === plugin.id && (
              <div className="settings-confirm" role="group" aria-label={`Remove ${plugin.name}`}>
                <span>Remove “{plugin.name}”? Its folder goes to the Trash, and its data and what it was allowed are forgotten.</span>
                <Button
                  tone="danger"
                  disabled={busy}
                  onClick={() => void run(() => bridge.pluginsRemove?.(plugin.id)).then(() => setRemoving(null))}
                >
                  Remove
                </Button>
                <Button onClick={() => setRemoving(null)}>Keep it</Button>
              </div>
            )}
          </li>
        ))}
      </ul>
    </Group>
  )
}

/** What it asks for, and which of that it has. */
function Capabilities({ plugin }: { plugin: PluginView }) {
  if (plugin.declared.length === 0) {
    return <span className="settings-tool-note">Asks for nothing beyond running.</span>
  }
  return (
    <ul className="plugins-caps" aria-label={`What ${plugin.name} asks for`}>
      {plugin.declared.map((capability) => {
        const granted = plugin.granted.includes(capability)
        const where =
          granted && PROJECT_SCOPED.includes(capability) && plugin.projects.length > 0
            ? `: ${plugin.projects.map(projectName).join(', ')}`
            : ''
        return (
          <li key={capability} className="plugins-cap" data-granted={granted ? '' : undefined}>
            {CAPABILITY_WORDS[capability]}
            {where} — {granted ? 'allowed' : 'not allowed'}
          </li>
        )
      })}
    </ul>
  )
}

/* ------------------------------------------------------------- allowing -- */

export function AllowForm({
  plugin,
  projects,
  busy,
  onAllow,
  onCancel,
}: {
  plugin: PluginView
  projects: string[]
  busy: boolean
  onAllow(input: { capabilities: PluginCapability[]; projects: string[] }): Promise<void>
  onCancel(): void
}) {
  const ids = useId()
  // A first allow starts from everything it asks for, which the person then trims; a change starts from what it has.
  const [chosen, setChosen] = useState<PluginCapability[]>(plugin.allowed ? plugin.granted : plugin.declared)
  const [places, setPlaces] = useState<string[]>(plugin.allowed ? plugin.projects : [])
  const scoped = chosen.some((capability) => PROJECT_SCOPED.includes(capability))
  const asks =
    !plugin.allowed ||
    chosen.some((capability) => !plugin.granted.includes(capability)) ||
    (scoped && places.some((place) => !plugin.projects.includes(place)))
  const missingPlace = scoped && places.length === 0

  const toggle = <T,>(list: T[], value: T, on: boolean): T[] => (on ? [...list.filter((one) => one !== value), value] : list.filter((one) => one !== value))

  return (
    <div className="plugins-edit">
      {plugin.declared.map((capability, index) => (
        <div key={capability} className="plugins-choice">
          <Row
            label={CAPABILITY_WORDS[capability]}
            labelId={`${ids}-cap-${index}`}
            control={
              <Switch
                checked={chosen.includes(capability)}
                disabled={busy}
                labelledBy={`${ids}-cap-${index}`}
                onChange={(on) => setChosen(toggle(chosen, capability, on))}
              />
            }
          />
          {PROJECT_SCOPED.includes(capability) && chosen.includes(capability) && (
            <div className="plugins-projects" role="group" aria-label="Which projects">
              {projects.length === 0 && <p className="plugins-quiet">This app has no projects yet, so there is nothing to choose.</p>}
              {projects.map((project, at) => (
                <Row
                  key={project}
                  label={projectName(project)}
                  help={project}
                  labelId={`${ids}-project-${index}-${at}`}
                  control={
                    <Switch
                      checked={places.includes(project)}
                      disabled={busy}
                      labelledBy={`${ids}-project-${index}-${at}`}
                      onChange={(on) => setPlaces(toggle(places, project, on))}
                    />
                  }
                />
              ))}
            </div>
          )}
        </div>
      ))}
      {plugin.declared.length === 0 && <p className="plugins-quiet">It asks for nothing; allowing it lets it run.</p>}
      <div className="settings-actions">
        <Button
          tone="primary"
          disabled={busy || missingPlace}
          title={missingPlace ? 'Choose at least one project, or turn that one off.' : asks ? 'You are asked to confirm in a dialog.' : undefined}
          onClick={() => void onAllow({ capabilities: chosen, projects: scoped ? places : [] })}
        >
          {asks ? 'Allow…' : 'Save'}
        </Button>
        <Button disabled={busy} onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </div>
  )
}
