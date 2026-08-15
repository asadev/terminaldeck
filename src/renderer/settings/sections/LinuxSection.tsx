import { useCallback, useEffect, useState } from 'react'
import { Button, Notice, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import { errorText } from '../settings-bridge'
import { machineNoun, type UiPlatform } from '../../platform'

/**
 * Linux — which distribution a session in a Linux folder runs inside.
 *
 * ## Why this pane is so small
 *
 * Because the decision it looks like it should be making is already made
 * somewhere better. A session opens where its folder is: a project inside the
 * distribution runs inside the distribution, a project on the Windows drive runs
 * on Windows. That rule needs no switch, and a switch would be worse than
 * useless — it would let the shell and the files end up on opposite sides of the
 * boundary, which is the one arrangement that is slow *and* confusing.
 *
 * So there is exactly one choice on this screen, and it only exists because a
 * path genuinely cannot answer it: `/home/asad/proj` exists in Ubuntu and in
 * Debian and is a different directory in each. It is chosen once, for the
 * machine, not per session — most people will never open this pane at all,
 * because a machine with one distribution has nothing to choose.
 *
 * ## What it must never claim
 *
 * That anything is sandboxed, or that this app installed anything. It reads what
 * Windows reports and remembers one name. When Windows refuses, its own sentence
 * is shown rather than a summary — `wsl.exe` says specific, actionable things
 * ("the Virtual Machine Platform feature is not enabled") and paraphrasing them
 * throws away the only accurate line on the screen.
 */

/* -------------------------------------------------------------- the bridge -- */

/**
 * What this pane needs from `window.deck`.
 *
 * The names are the preload's, not this file's preference: `contract.test.ts`
 * matches these strings against what the preload exposes, so a near miss fails a
 * build instead of quietly rendering the "not in this build" fallback.
 */
export interface WslBridge {
  wslStatus(force?: boolean): Promise<unknown>
  chooseWslDistro(distro: string | null): Promise<unknown>
}

const BRIDGE_METHODS: ReadonlyArray<keyof WslBridge> = ['wslStatus', 'chooseWslDistro']

/**
 * The bridge as it actually exists, each method called through its host.
 *
 * `globalThis` rather than `window` because this file is rendered to a string in
 * its own test, where there is no window. Methods are wrapped rather than copied
 * because a preload whose functions sit on a prototype throws on `this` the
 * first time a button is pressed — and that only ever shows up in a packaged
 * build.
 */
export function resolveWslBridge(host?: unknown): Partial<WslBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<WslBridge>
}

/* ------------------------------------------------------------- what arrives -- */

/** Mirrors `WslDistro` in `src/main/wsl.ts`. */
export interface Distro {
  name: string
  version: number
  running: boolean
  isDefault: boolean
}

/** Mirrors `WslSnapshot`. */
export interface WslSnapshot {
  supported: boolean
  state: 'absent' | 'no-distros' | 'ready'
  distros: Distro[]
  chosen: string | null
  active: string | null
  home: string | null
  detail: string | null
  read: boolean
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/**
 * Narrowed pessimistically, and `state` most pessimistically of all.
 *
 * Anything this cannot recognise becomes `absent`, which draws the pane that
 * offers nothing. The opposite default would draw a distribution picker from a
 * malformed message and let somebody choose a distribution that is not there.
 */
export function toSnapshot(raw: unknown): WslSnapshot | null {
  const record = asRecord(raw)
  if (!record) return null
  const state =
    record.state === 'ready' || record.state === 'no-distros' ? record.state : 'absent'
  const distros = Array.isArray(record.distros)
    ? record.distros.flatMap((entry): Distro[] => {
        const row = asRecord(entry)
        const name = asString(row?.name)
        if (row === null || name === null) return []
        return [
          {
            name,
            version: typeof row.version === 'number' ? row.version : 0,
            running: row.running === true,
            isDefault: row.isDefault === true,
          },
        ]
      })
    : []
  return {
    supported: record.supported === true,
    state,
    distros,
    chosen: asString(record.chosen),
    active: asString(record.active),
    home: asString(record.home),
    detail: asString(record.detail),
    read: record.read === true,
  }
}

/* ------------------------------------------------------------------- copy -- */

/** Where to go when there is nothing installed to run in. */
const INSTALL_DOCS = 'https://learn.microsoft.com/windows/wsl/install'

/**
 * What a distribution's row says under its name.
 *
 * "Not running" is deliberately not a warning. A stopped distribution is the
 * ordinary state of one nobody has opened yet, and it starts by itself the
 * moment a session opens in it — saying so is the difference between a fact and
 * a problem the reader now has to solve.
 */
export function distroNote(distro: Distro): string {
  return distro.running ? 'Running now.' : 'Not running — it starts when you open a session in it.'
}

/* ------------------------------------------------------------------- view -- */

export interface LinuxViewProps {
  snapshot: WslSnapshot | null
  loading: boolean
  /** True when the build exposes no channel for this at all. */
  unwired: boolean
  error: string | null
  platform?: UiPlatform
  onChoose(distro: string): void
  onRefresh(): void
}

/**
 * Split from the fetching for the reason `PowerView` is: `renderToStaticMarkup`
 * never runs an effect, so a component that read its own status would be
 * testable in exactly one state — the empty one — and the states that matter
 * here are the other four.
 */
export function LinuxView({
  snapshot,
  loading,
  unwired,
  error,
  platform = 'windows',
  onChoose,
  onRefresh,
}: LinuxViewProps) {
  const meta = sectionMeta('linux')
  const here = machineNoun(platform)
  const ready = snapshot?.state === 'ready'

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {/*
        The rule, in one sentence, before anything can be clicked.

        It is the whole mental model and it is not obvious: people expect an app
        to have a "use Linux" switch. Saying that the folder decides — and that
        the two halves are kept together on purpose — is what stops somebody
        looking for the switch that is deliberately not here.
      */}
      <p className="settings-prose">
        A session opens where its folder is. A project inside Linux runs inside Linux, and a project
        on this {here}’s own drive runs on Windows. Keeping the shell and the files on the same side
        is what makes either of them fast.
      </p>

      {unwired && (
        <Notice tone="warn">This build cannot read the Linux side yet.</Notice>
      )}

      {!unwired && !snapshot?.read && (
        <Notice tone="info">Checking what this {here} has…</Notice>
      )}

      {!unwired && snapshot?.read && snapshot.state === 'absent' && (
        <Notice tone="info">
          Windows Subsystem for Linux is not installed on this {here}, so every session runs on
          Windows. <LinkOutInstall />
        </Notice>
      )}

      {!unwired && snapshot?.read && snapshot.state === 'no-distros' && (
        <Notice tone="warn">
          Windows Subsystem for Linux is here but has no Linux installed in it, so there is nothing
          to open a session in. <LinkOutInstall />
        </Notice>
      )}

      {/*
        Windows' own words, never a summary of them. The real messages name the
        actual problem — "the Virtual Machine Platform feature is not enabled" —
        and a paraphrase would be the only inaccurate line on the screen.
      */}
      {!unwired && snapshot?.detail && (
        <p className="settings-code">{snapshot.detail}</p>
      )}

      {ready && (
        <ul className="settings-tools">
          {snapshot.distros.map((distro) => {
            const inUse = distro.name === snapshot.active
            return (
              <li
                key={distro.name}
                className="settings-tool"
                // Green for awake, grey for asleep. Not red: a stopped
                // distribution is normal, not a fault.
                data-state={distro.running ? 'ready' : 'missing'}
              >
                <span className="settings-tool-dot" aria-hidden="true" />
                <div className="settings-tool-main">
                  <span className="settings-tool-name">
                    {distro.name}
                    {inUse && <span className="settings-badge">In use</span>}
                    {distro.isDefault && !inUse && (
                      <span className="settings-badge quiet">Windows’ default</span>
                    )}
                  </span>
                  <span className="settings-tool-note">{distroNote(distro)}</span>
                </div>
                <span className="settings-tool-state">
                  {/*
                    Nothing to press on the one already in use. A disabled button
                    on the selected row is a control that looks pressable and is
                    not, which is the promise this project does not break.
                  */}
                  {!inUse && (
                    <Button disabled={loading} onClick={() => onChoose(distro.name)}>
                      Use this one
                    </Button>
                  )}
                </span>
              </li>
            )
          })}
        </ul>
      )}

      {/*
        Only worth saying when there is more than one. On a machine with a single
        distribution the sentence would be explaining a choice nobody has.
      */}
      {ready && snapshot.distros.length > 1 && (
        <p className="settings-prose">
          Sessions in a Linux folder use {snapshot.active}. This is remembered for this {here},
          not asked again per session.
        </p>
      )}

      {ready && snapshot.home && (
        <p className="settings-prose">
          A session with no folder of its own starts in <code className="settings-path">{snapshot.home}</code>.
        </p>
      )}

      <div className="settings-actions">
        <Button disabled={unwired || loading} onClick={onRefresh}>
          {loading ? 'Checking…' : 'Check again'}
        </Button>
      </div>

      {error && <Notice tone="error">{error}</Notice>}
    </>
  )
}

/** One link, written once, because both empty states end in it. */
function LinkOutInstall() {
  return (
    <a className="settings-link" href={INSTALL_DOCS} target="_blank" rel="noreferrer">
      How to install it
    </a>
  )
}

/* -------------------------------------------------------------- the pane -- */

export interface LinuxSectionProps {
  bridge?: Partial<WslBridge>
  platform?: UiPlatform
}

export function LinuxSection({ bridge: injected, platform }: LinuxSectionProps) {
  const [bridge] = useState<Partial<WslBridge>>(() => injected ?? resolveWslBridge())
  const [snapshot, setSnapshot] = useState<WslSnapshot | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const unwired = bridge.wslStatus === undefined || bridge.chooseWslDistro === undefined

  const load = useCallback(
    (force: boolean) => {
      const ask = bridge.wslStatus
      if (!ask) return
      setLoading(true)
      setError(null)
      void ask(force).then(
        (raw) => {
          setSnapshot(toSnapshot(raw))
          setLoading(false)
        },
        (cause: unknown) => {
          setError(errorText(cause, 'Could not ask Windows what it has.'))
          setLoading(false)
        },
      )
    },
    [bridge],
  )

  // Without `force`, the main process answers from the reading it already took
  // at launch — so opening this pane costs nothing and the button is the only
  // thing that re-reads the machine.
  useEffect(() => load(false), [load])

  const choose = useCallback(
    (distro: string) => {
      const write = bridge.chooseWslDistro
      if (!write) return
      setLoading(true)
      setError(null)
      void write(distro).then(
        (raw) => {
          // The answer *is* the new state, so nothing is guessed here: a name
          // the machine refused leaves the list showing what is really in use
          // rather than what was clicked.
          setSnapshot(toSnapshot(raw))
          setLoading(false)
        },
        (cause: unknown) => {
          setError(errorText(cause, 'Could not save that choice.'))
          setLoading(false)
        },
      )
    },
    [bridge],
  )

  return (
    <LinuxView
      snapshot={snapshot}
      loading={loading}
      unwired={unwired}
      error={error}
      platform={platform}
      onChoose={choose}
      onRefresh={() => load(true)}
    />
  )
}
