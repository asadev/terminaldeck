import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { BRAND } from '../../../shared/brand'
import { Explain, Notice, Row, SectionHead, Switch } from '../controls'
import { sectionMeta } from '../settings-schema'
import { errorText } from '../settings-bridge'
import { detectPlatform, machineNoun, osName, ThisMachine, thisMachine, type UiPlatform } from '../../platform'

/**
 * Power — one switch, and the honest paragraph that has to go with it.
 *
 * ## What the switch is actually bound to
 *
 * Not a preference. `disablesleep` on macOS and the lid-close action on Windows
 * are **system** settings: they outlive this app, they are visible to every
 * other app, and `sudo pmset` or the Windows power panel can change them while
 * this pane is open. So this section stores nothing, remembers nothing, and
 * draws nothing until the main process has read the machine — which is why the
 * switch is `on` only when `known` is true. A switch drawn from a value this
 * app last wrote would eventually be a picture of yesterday.
 *
 * ## Why the description is long, and why it stays long
 *
 * Every one of these sentences is load-bearing, and they were written after
 * checking the behaviour rather than from memory:
 *
 *   - **It is not an app setting.** Turning it on changes the machine, for
 *     everything on it, until it is turned off. Somebody who does not know that
 *     will find their laptop hot in a bag and have no idea which app did it.
 *   - **A closed lid has no airflow.** This is the physical consequence and the
 *     app cannot mitigate it; the only honest thing is to say so before the
 *     first click, not after.
 *   - **On battery it drains, and nothing will stop it.** The app warns and
 *     does not act — see `lowBatteryWarning` in `src/main/lid-awake.ts` for why
 *     dropping the lock automatically would be the worse of the two failures.
 *   - **macOS asks for a password; Windows does not.** Two platforms, two
 *     truths, and printing the wrong one is a mistake this codebase has made in
 *     bulk before.
 *   - **The power button is unaffected.** Asad asked for that specifically, and
 *     it is true for a structural reason rather than a hopeful one: sleeping on
 *     a power-button press is a separate setting and nothing here writes it.
 *
 * ## No spinner that resolves into a lie
 *
 * `changing` covers a call that may sit for a minute with the OS's password
 * sheet on screen. What comes back is a message the main process wrote after
 * re-reading the machine, so a cancelled prompt says it was cancelled and a
 * command that ran without changing anything says *that* — never "done".
 */

/* -------------------------------------------------------------- the bridge -- */

/**
 * What this pane needs from `window.deck`.
 *
 * The names are the preload's rather than this file's preference: the contract
 * test matches these strings against what the preload exposes, so a near miss
 * fails a build instead of quietly rendering the "not in this build" fallback.
 */
export interface LidAwakeBridge {
  lidAwakeStatus(): Promise<unknown>
  setLidAwake(on: boolean): Promise<unknown>
  onLidAwakeState(callback: (state: unknown) => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof LidAwakeBridge> = [
  'lidAwakeStatus',
  'setLidAwake',
  'onLidAwakeState',
]

/**
 * The bridge as it actually exists, each method called through its host.
 *
 * `globalThis` rather than `window` because this file is rendered to a string in
 * its own test, where there is no window. Methods are wrapped rather than copied
 * for the reason `settings-bridge.ts` gives: a preload whose functions sit on a
 * prototype throws on `this` the first time a switch is pressed, and that only
 * ever shows up in a packaged build.
 */
export function resolveLidAwakeBridge(host?: unknown): Partial<LidAwakeBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<LidAwakeBridge>
}

/* ------------------------------------------------------------- what arrives -- */

/** Mirrors `BatteryReading` in `src/main/lid-awake.ts`. */
export interface BatteryReading {
  present: boolean
  discharging: boolean
  percent: number | null
}

/** Mirrors `LidAwakeState` in `src/main/lid-awake.ts`. */
export interface LidAwakeState {
  supported: boolean
  on: boolean
  known: boolean
  needsAuthorization: boolean
  preexisting: boolean
  battery: BatteryReading | null
  detail: string | null
  warning: string | null
  /**
   * Is the app holding this machine's idle sleep off right now?
   *
   * A different fact from `on`, and the reason this pane stopped looking broken.
   * The switch is the *privileged* lid setting; this is the app's own free wake
   * lock, which is held for as long as the app is open whatever the switch says.
   * With only `on` to draw from, the screen had to imply that an off switch
   * meant nothing at all was protecting a running session — which was true of
   * the old behaviour and is the fault Asad reported.
   */
  idleBlocked: boolean
}

/** Mirrors `LidAwakeResult`. `outcome` is the half that decides the tone. */
export interface LidAwakeResult {
  outcome: 'changed' | 'unchanged' | 'cancelled' | 'failed' | 'unsupported'
  state: LidAwakeState | null
  message: string
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

function asBoolean(value: unknown): boolean {
  return value === true
}

/**
 * Narrowed pessimistically, and `known` most pessimistically of all.
 *
 * Anything that is not literally `true` reads as "the app cannot say", which
 * draws a disabled switch and a sentence admitting it. The alternative — a
 * default of `known: true, on: false` — would draw a confident *off* switch for
 * a machine whose state was never read, which is the one wrong answer that
 * hides a running battery drain behind something that looks harmless.
 */
export function toLidAwakeState(raw: unknown): LidAwakeState | null {
  const record = asRecord(raw)
  if (!record) return null
  const battery = asRecord(record.battery)
  return {
    supported: asBoolean(record.supported),
    on: asBoolean(record.on),
    known: asBoolean(record.known),
    needsAuthorization: asBoolean(record.needsAuthorization),
    preexisting: asBoolean(record.preexisting),
    battery: battery
      ? {
          present: asBoolean(battery.present),
          discharging: asBoolean(battery.discharging),
          percent: typeof battery.percent === 'number' ? battery.percent : null,
        }
      : null,
    detail: typeof record.detail === 'string' && record.detail !== '' ? record.detail : null,
    warning: typeof record.warning === 'string' && record.warning !== '' ? record.warning : null,
    // Pessimistic like the rest: a build whose main process does not send this
    // field draws no claim about a lock, rather than promising one.
    idleBlocked: asBoolean(record.idleBlocked),
  }
}

const OUTCOMES = new Set(['changed', 'unchanged', 'cancelled', 'failed', 'unsupported'])

export function toLidAwakeResult(raw: unknown): LidAwakeResult {
  const record = asRecord(raw)
  const outcome = typeof record?.outcome === 'string' && OUTCOMES.has(record.outcome) ? record.outcome : 'failed'
  return {
    // 'failed' for anything unrecognised, never 'changed'. A success reported by
    // something that did not check is the disease this whole feature avoids.
    outcome: outcome as LidAwakeResult['outcome'],
    state: toLidAwakeState(record?.state),
    message:
      typeof record?.message === 'string' && record.message !== ''
        ? record.message
        : 'The change finished without saying what happened.',
  }
}

/* ------------------------------------------------------------------- copy -- */

/**
 * Whether the machine being described has a lid to close.
 *
 * Both paragraphs below are about closing a lid, and a Mac mini has none — nor
 * does a desktop PC. `disablesleep` still works there and is still worth
 * offering, so the row stays; what changes is that it stops describing a lid
 * that is not on the desk. Rendering the pane and reading it is what surfaced
 * this: the copy read "close the lid and the screen goes off" on a machine the
 * app had itself identified as having no battery and no lid.
 */
export interface MachineShape {
  hasLid?: boolean
}

/**
 * `osName` at the start of a sentence.
 *
 * `platform.ts` has `thisMachine`/`ThisMachine` as a pair for exactly this
 * reason but no capitalised `osName`, and the phrase it returns for an
 * unrecognised platform is "your operating system" — lower case, because every
 * other caller uses it mid-sentence. Rendered at the head of one it read
 * "your operating system asks for your password", which is the kind of thing
 * that is invisible in the source and obvious on screen. Capitalised here
 * rather than in `platform.ts`, which is shared and not this section's to edit.
 *
 * The uppercase test is the whole trick, and it was added after the naive
 * version rendered **"MacOS asks for your password"** — one bug traded for a
 * worse one, since Apple's spelling starts lower case deliberately and getting
 * it wrong is the sort of thing a Mac user reads as sloppiness. A name that
 * already carries a capital is a product name and is left exactly as it is;
 * only an all-lowercase phrase is a generic description that needs one.
 */
function OsName(platform: UiPlatform): string {
  const name = osName(platform)
  if (/[A-Z]/.test(name)) return name
  return name.charAt(0).toUpperCase() + name.slice(1)
}

/**
 * The paragraph under the switch.
 *
 * Pure and exported so the wording can be tested, for the same reason
 * `deliveryCopy` is: on a screen whose entire job is to be honest about a
 * trade-off, the wording *is* the feature, and a test that could not read it
 * would be testing the wrong half.
 */
export function lidAwakeHelp(platform: UiPlatform, { hasLid = true }: MachineShape = {}): string {
  const machine = thisMachine(platform)
  const password =
    platform === 'windows'
      ? 'No password is needed on Windows.'
      : `${OsName(platform)} asks for your password the first time, and again if you turn it off.`
  const what = hasLid
    ? `Close the lid and the screen goes off while ${machine} keeps running — every session, every process. `
    : `${ThisMachine(platform)} has no lid to close, so this simply stops it going to sleep on its own — every session, every process keeps running. `
  return (
    what +
    `This changes a setting on the machine itself, not just in this app, so it stays that way until it is turned off here. ` +
    password
  )
}

/**
 * The standing warning, said before the first click rather than after it — or
 * null when there is honestly nothing to warn about.
 *
 * Both halves of it are consequences of a *closed lid on a laptop*: heat with
 * nowhere to go, and a battery with nothing to stop it draining. A desktop has
 * neither, so it gets neither sentence rather than a scary paragraph about
 * hardware it does not have.
 */
export function lidAwakeCaution(platform: UiPlatform, { hasLid = true }: MachineShape = {}): string | null {
  if (!hasLid) return null
  return (
    `A closed lid means no airflow, so ${thisMachine(platform)} will run hotter than usual. ` +
    'On battery it will keep draining until it is flat — nothing here will stop it, and the app will say so rather than turning itself off behind your back.'
  )
}

/**
 * The one line about what the app is already doing on its own.
 *
 * Short on purpose — Asad's broadest note on the whole recording was *"we don't
 * need this much of big descriptions under each"* — but it earns its place,
 * because without it this screen has only the switch to speak with and a switch
 * that is off reads as "nothing is protecting my session". That was true until
 * the wake lock was decoupled from the privileged setting, and the sentence is
 * what makes the change visible instead of merely correct.
 *
 * Both halves are load-bearing and both are literally true of
 * `powerSaveBlocker.start('prevent-app-suspension')`: it stops the machine
 * dropping off by itself, and it stops nothing else — a closed lid, the Sleep
 * menu item and a critical battery all still sleep it. Promising more than that
 * is the failure this module's own header spends four paragraphs on.
 */
export function idleBlockedNote(platform: UiPlatform, { hasLid = true }: MachineShape = {}): string {
  // Lid-aware for the same reason `lidAwakeHelp` is: a Mac mini has no lid, and
  // a sentence naming one on a machine that has none is the kind of thing that
  // is invisible in the source and obvious on screen.
  const still = hasLid ? 'Closing the lid or choosing Sleep still does.' : 'Choosing Sleep still does.'
  return `While ${BRAND.name} is open, ${thisMachine(platform)} will not fall asleep on its own. ${still}`
}

/** What the switch is allowed to say when the machine could not be read. */
export function unknownStateNote(platform: UiPlatform): string {
  return `${ThisMachine(platform)} did not report this setting, so the app cannot say whether it is on.`
}

/* --------------------------------------------------------------- the view -- */

export interface PowerViewProps {
  state: LidAwakeState | null
  /** True until the first read lands. */
  loading: boolean
  /** True while the OS is being asked to change it — possibly for a long time. */
  changing: boolean
  /** The last thing the main process said, or null. */
  result: LidAwakeResult | null
  /** Set when the channel is missing from this build entirely. */
  unwired: boolean
  platform?: UiPlatform
  onChange(next: boolean): void
}

/**
 * Everything this section draws, taking everything it draws.
 *
 * Split from the fetching for the reason `RemoteView` is: `renderToStaticMarkup`
 * never runs an effect, so a component that read its own status would be
 * testable in exactly one state — the empty one — and the states that matter
 * here are the other five.
 */
export function PowerView({
  state,
  loading,
  changing,
  result,
  unwired,
  platform = detectPlatform(),
  onChange,
}: PowerViewProps) {
  const meta = sectionMeta('power')
  const ids = useId()
  const labelId = `${ids}-label`
  const helpId = `${ids}-help`

  const supported = state?.supported === true
  const known = state?.known === true
  const on = known && state?.on === true
  const hasLid = state?.battery === null || state?.battery?.present !== false
  const caution = lidAwakeCaution(platform, { hasLid })

  /*
   * Has the machine actually answered yet?
   *
   * The distinction matters because `supported` is false before the first read
   * lands as well as on a platform that cannot do this, and the two deserve
   * opposite treatments: while loading, the row is drawn with a disabled switch
   * so the pane does not flicker into existence; once the answer is in and it
   * is "no", the row goes away entirely.
   */
  const answered = !loading && state !== null
  const unavailable = answered && !supported

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {/*
        Nothing is offered on a machine that cannot do this.

        It used to render the switch disabled with the reason underneath, which
        sounds honest and is not: the paragraph above the dead switch still said
        "close the lid and the screen goes off while this computer keeps
        running", and promised a password prompt, on a platform where none of it
        is true. A disabled control is still a description of a feature. The
        `Notice` below carries the operating system's own reason, which is the
        only thing on this screen that is true there.
      */}
      {!unavailable && (
        <div className="settings-item">
          <Row
            label={
              hasLid
                ? 'Keep running with the lid closed'
                : `Keep ${thisMachine(platform)} from going to sleep`
            }
            help={lidAwakeHelp(platform, { hasLid })}
            labelId={labelId}
            helpId={helpId}
            control={
              <Switch
                checked={on}
                // Disabled only for reasons that are stated on screen right below
                // it: a machine that would not answer, a build with no channel,
                // or a change already in flight.
                disabled={unwired || loading || changing || !supported || !known}
                labelledBy={labelId}
                describedBy={helpId}
                onChange={onChange}
              />
            }
          />
        </div>
      )}

      {/*
        The standing warning, given a line of its own.

        It used to be a third piece of grey type stacked inside the switch's
        card, immediately under a help line that was already three sentences —
        so the row a reader most needed to slow down for was the one that looked
        most like a paragraph with no shape. Same words (`lidAwakeCaution` is
        unchanged and its wording is pinned by this section's test), same place
        in the reading order, directly under the control it is about. What it
        gains is a title to scan and space around it.
      */}
      {/*
        Said whenever it is true, including on a platform where the switch
        itself is not offered.

        It sits *outside* the `unavailable` guard on purpose: the wake lock is
        this app's own and needs no platform support, so a Linux box or a
        Windows desktop with no lid-close action still gets it — and those are
        exactly the machines where the rest of this screen has nothing to say.
        Answering "the app cannot hold this machine awake through a lid close"
        and then staying silent about the thing it *is* doing was the shape of
        the original complaint.
      */}
      {state?.idleBlocked === true && (
        <Notice tone="info">{idleBlockedNote(platform, { hasLid })}</Notice>
      )}

      {!unavailable && caution && <Explain title="Heat and battery">{caution}</Explain>}

      {changing && (
        <Notice tone="info">
          {state?.needsAuthorization === true
            ? `Waiting for ${osName(platform)} — its password box is on screen, and this will not finish until it is answered or dismissed.`
            : `Asking ${osName(platform)} to change it…`}
        </Notice>
      )}

      {unwired && (
        <Notice tone="warn">This build has no way to read or change that setting yet.</Notice>
      )}

      {/*
        `unavailable`, not `!supported`. They differ in the case that used to be
        wrong: a read that *failed* leaves `state` null, which makes `supported`
        false without anything having said this platform is unsupported — and
        the pane would answer a failed read with "the app cannot hold this Mac
        awake through a lid close", blaming the platform for what was really a
        command that would not run. The real reason is already on screen in the
        result notice below.
      */}
      {!unwired && unavailable && (
        <Notice tone="warn">
          {state?.detail ?? `The app cannot hold ${thisMachine(platform)} awake through a lid close.`}
        </Notice>
      )}

      {!unwired && !loading && supported && !known && (
        <Notice tone="warn">
          {unknownStateNote(platform)} {state?.detail ?? ''}
        </Notice>
      )}

      {/*
        Someone else's doing, said out loud. `disablesleep` survives a restart
        and can be set by a terminal, so an on switch at first launch is not
        necessarily this app's work — and a user who sees one has every right to
        wonder what turned it on.
      */}
      {on && state?.preexisting === true && (
        <Notice tone="info">
          This was already on before the app started — it is a setting on the {machineNoun(platform)}, so
          something else may have set it.
        </Notice>
      )}

      {state?.warning && <Notice tone="warn">{state.warning}</Notice>}

      {result && (
        <Notice tone={result.outcome === 'changed' || result.outcome === 'unchanged' ? 'info' : 'warn'}>
          {result.message}
        </Notice>
      )}
    </>
  )
}

/* ------------------------------------------------------------ the section -- */

export interface PowerSectionProps {
  /** Injected by the test; the real one is resolved off `window.deck`. */
  bridge?: Partial<LidAwakeBridge>
}

export function PowerSection({ bridge: injected }: PowerSectionProps = {}) {
  const bridge = useMemo(() => injected ?? resolveLidAwakeBridge(), [injected])
  const [state, setState] = useState<LidAwakeState | null>(null)
  const [loading, setLoading] = useState(true)
  const [changing, setChanging] = useState(false)
  const [result, setResult] = useState<LidAwakeResult | null>(null)

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const status = bridge.lidAwakeStatus
  const subscribe = bridge.onLidAwakeState
  const change = bridge.setLidAwake

  /*
   * Read once on mount, then let the main process push.
   *
   * No interval anywhere in this file. The controller broadcasts on every read
   * it takes — at launch, on a mains/battery transition, on its battery watch
   * and after every change — so a pane that polled would be strictly worse in
   * every dimension: later than the push, and awake when nothing had happened.
   */
  useEffect(() => {
    if (!status) {
      setLoading(false)
      return
    }
    void status().then(
      (raw) => {
        if (!alive.current) return
        setState(toLidAwakeState(raw))
        setLoading(false)
      },
      (cause: unknown) => {
        if (!alive.current) return
        setLoading(false)
        setResult({
          outcome: 'failed',
          state: null,
          message: errorText(cause, 'The app could not read this machine’s sleep setting.'),
        })
      },
    )
  }, [status])

  useEffect(() => {
    if (!subscribe) return
    return subscribe((raw) => {
      if (!alive.current) return
      const next = toLidAwakeState(raw)
      if (next) setState(next)
    })
  }, [subscribe])

  const onChange = useCallback(
    (next: boolean) => {
      if (!change) return
      // Cleared before the call, not after: leaving the previous outcome under a
      // switch that is being changed again is how a pane ends up answering a
      // question nobody asked.
      setResult(null)
      setChanging(true)
      void change(next).then(
        (raw) => {
          if (!alive.current) return
          const answer = toLidAwakeResult(raw)
          setChanging(false)
          setResult(answer)
          // The state that comes back was read from the OS after the write, so
          // it wins over anything this pane believed a moment ago.
          if (answer.state) setState(answer.state)
        },
        (cause: unknown) => {
          if (!alive.current) return
          setChanging(false)
          setResult({
            outcome: 'failed',
            state: null,
            message: errorText(cause, 'That change could not be made.'),
          })
        },
      )
    },
    [change],
  )

  return (
    <PowerView
      state={state}
      loading={loading}
      changing={changing}
      result={result}
      unwired={status === undefined || change === undefined}
      onChange={onChange}
    />
  )
}
