import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { BRAND } from '../../../shared/brand'
import { Button, Info, MoreBody, Notice, SectionHead, Switch, useMore } from '../controls'
import { errorText } from '../settings-bridge'
import { ReadingSpeedControl } from '../../copilot/driving/PaceControls'
import { DEFAULT_SPEED, type ReadingSpeed } from '../../copilot/driving/estimate'
import { loadSpeed, saveSpeed } from '../../copilot/driving/reading-speed'
import { TourRecap } from '../../copilot/driving/TourRecap'
import { FileEditor } from './CopilotEditor'
import {
  resolveCopilotBridge,
  toActionLog,
  toCopilotSignIn,
  toCopilotState,
  toInstructionsRead,
  toInstructionsWrite,
  toMemoryDelete,
  toMemoryRead,
  toMemoryReport,
  toMemoryWrite,
  toResetResult,
  toRevealMessage,
  toRoutineRows,
  toRoutineText,
  toRoutineWrite,
  toScaffoldResult,
  type ActionLogReport,
  type CopilotBridge,
  type CopilotSignIn,
  type CopilotState,
  type LoggedAction,
  type MemoryReport,
  type RoutineRow,
} from './copilot-bridge'
import './CopilotSection.css'

/**
 * Settings → Copilot — the pane that makes the machinery visible.
 *
 * Asad, 2026-08-17: *"we should be able to see all of his files, the things it
 * reads before it starts and all those things… its files can be in proper
 * boxes… so we can see and learn how our copilot is working."*
 *
 * So this is not a settings form with a few toggles, and it holds no settings
 * at all. It is a window into an agent, and the whole reason the copilot was
 * built as a real session rather than a bespoke backend is that a session has
 * these things to show: a working directory, an instruction file, a memory
 * directory, a transcript, a boundary the kernel holds. A chat widget with a
 * hidden prompt would have had nothing to put on this screen, which is the
 * point `COPILOT-DESIGN.md` settles every decision by.
 *
 * ## Six things, in the order somebody actually asks about them
 *
 *  1. **Its session.** Is it running, whose account is it, and can I stop it.
 *  2. **What it reads at startup**, as the actual files, because that is what
 *     "why did it say that" resolves to — and `CLAUDE.md` in a box, editable.
 *  3. **Its memory**, one file per fact, readable, editable and deletable.
 *  4. **The action log** — every call, and who confirmed it. Read-only.
 *  5. **What it can and cannot reach**, stated rather than left in a design doc.
 *  6. **Routines**, including the one the engine paused after failing — each
 *     one's file editable in place.
 *
 * ## Three of the four are editable here, and the fourth never will be
 *
 * Asad, 2026-08-17: *"none of them is clickable or editable … I should be able
 * to click and make changes and click save, and those folders, instructions,
 * everything should be directly changed from here."* So the instruction file,
 * every memory and every routine each get a box and a Save, through the one
 * {@link FileEditor} in `CopilotEditor.tsx`.
 *
 * **The action log stays read-only, and that is not an omission.** It is the
 * record of what the copilot did, and the pane's own paragraph about it says the
 * audited party cannot compose it. A pane that let a *person* edit it would not
 * break that claim in the same way — a person is not the audited party — but it
 * would destroy what the file is for, which is being the one artefact a person
 * can check a claim against. There is no Save under it and there is no channel
 * behind one.
 *
 * ## When an edit takes effect, said out loud under each box
 *
 * The three differ and the difference matters, so no editor here is allowed to
 * be quiet about it:
 *
 *  - **`CLAUDE.md`** — at the copilot's *next start*. The CLI reads it as the
 *    session spawns and never again, so a save while it is running changes
 *    nothing about the conversation on screen. The editor says so and offers
 *    Restart when it is running, which is a stop and a start and is the only
 *    honest version of "apply".
 *  - **A memory** — the same, for the same reason: `memory/` is loaded at
 *    startup.
 *  - **A routine** — immediately. The engine reloads the folder on the save, so
 *    the next trigger uses the new text.
 *
 * ## Nothing here starts it
 *
 * Opening a settings pane must not spend somebody's money. `copilot:state`
 * reads the disk and starts nothing; `copilot:scaffold` writes the folder and
 * the two files so a person can *read* what their assistant would be told
 * before deciding to run it. Only the Start button starts a session, and it
 * says so.
 *
 * ## Two rules this pane is held to
 *
 * **No money on screen.** Not a figure, not a currency symbol, not a per-run
 * estimate. Tokens and context are shown elsewhere in the app; this pane names
 * spending only as a consequence — "starting a session spends" — never as a
 * number.
 *
 * **A control that cannot act is disabled with a reason.** Every button below
 * that can be unavailable carries the sentence saying why, next to it, rather
 * than being greyed out silently or — worse — being live and doing nothing.
 * That is the design brief's never-dead-clicks rule, and it is why so much of
 * this file is `disabledBecause` strings.
 *
 * ## The flat sheet
 *
 * Settings is one surface per theme — rail, pane and content the same colour,
 * no cards, grouping by spacing and heading weight. `settings-surface.test.ts`
 * fails a section stylesheet that paints a `--bg-*` background, so everything
 * in `CopilotSection.css` that needs to be visibly separate uses a `--fill-*`,
 * which is defined as a lift off whatever is behind it and therefore cannot
 * come to be the same colour as the page.
 */

/* ------------------------------------------------------------- formatting -- */

/** Bytes, at the precision a person reading a file listing cares about. */
function bytes(size: number): string {
  if (size < 1024) return `${size} B`
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`
  return `${(size / (1024 * 1024)).toFixed(1)} MB`
}

/**
 * A moment, as short as it can be while staying unambiguous.
 *
 * Today is a clock time, because "14:02" is what somebody comparing a log row
 * to what they were doing needs. Anything older carries the date, because a
 * bare time on a row from Tuesday is the kind of thing that gets misread once
 * and then distrusted forever.
 */
function when(at: number | null): string {
  if (at === null) return 'never'
  const date = new Date(at)
  if (Number.isNaN(date.getTime())) return 'unknown'
  const today = new Date()
  const sameDay =
    date.getFullYear() === today.getFullYear() &&
    date.getMonth() === today.getMonth() &&
    date.getDate() === today.getDate()
  return sameDay
    ? date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : date.toLocaleString([], {
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
      })
}

function whenIso(at: string): string {
  const parsed = Date.parse(at)
  return Number.isNaN(parsed) ? at : when(parsed)
}

/** The file name at the end of a path, on either platform's separator. */
function baseName(path: string): string {
  const at = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'))
  return at < 0 ? path : path.slice(at + 1)
}

/* ------------------------------------------------------ the two judgements -- */

/**
 * Has the copilot ever run on this machine?
 *
 * Both halves are needed and that is why this is a function rather than an
 * expression inline. A missing `CLAUDE.md` alone is also true of somebody who
 * deleted the file out of a folder full of memories, and an absent `memory/`
 * alone is true for the one moment between the scaffolder making the folder and
 * writing the index. Together they mean nothing has ever run here — which is a
 * state this pane has to draw honestly, rather than as a row of empty lists that
 * look like a failed load.
 *
 * `null` for either input means "not read yet", which is not the same as "never
 * started" and must not be drawn as it.
 */
export function hasNeverStarted(
  state: CopilotState | null,
  memory: MemoryReport | null,
): boolean {
  if (state === null) return false
  return state.instructions === 'missing' && memory?.exists !== true
}

/**
 * The sentence under the action-log heading that says whether the file can be
 * trusted, and the reason it has two branches.
 *
 * The pane's whole claim about the log is that the copilot cannot write it. That
 * claim is only worth printing if something checks it, and it must **flip** if
 * the path ever moves back inside the copilot's writable folder — reporting a
 * defect rather than going on reassuring somebody about a boundary that is no
 * longer there. `copilot-inspect.ts` measures it; this is where the measurement
 * becomes a sentence.
 */
export function logTrustLine(report: ActionLogReport): string {
  return report.outsideCopilotFolder
    ? 'Checked just now: this file is outside every path the copilot can write to.'
    : 'This file is inside the copilot’s own folder, which it can write to. That is a defect — the log is not trustworthy until it moves.'
}

/* --------------------------------------------------------------- section -- */

const STATUS_LABEL: Record<CopilotState['status'], string> = {
  stopped: 'Not running',
  starting: 'Starting…',
  running: 'Running',
}

export function CopilotSection() {
  const bridge = useMemo<Partial<CopilotBridge>>(() => resolveCopilotBridge(), [])

  const [state, setState] = useState<CopilotState | null>(null)
  const [signIn, setSignIn] = useState<CopilotSignIn | null>(null)
  const [memory, setMemory] = useState<MemoryReport | null>(null)
  const [actions, setActions] = useState<ActionLogReport | null>(null)
  const [routines, setRoutines] = useState<RoutineRow[] | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState<string | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  /**
   * Which load is the current one.
   *
   * Six reads land independently and a person can press Start while three are
   * still in flight, so an older answer arriving last would put the pre-start
   * picture back on screen. The same guard `SettingsWindow` keeps for its own
   * two stores, for the same reason.
   */
  const generation = useRef(0)

  const load = useCallback(() => {
    const mine = (generation.current += 1)
    setLoading(true)
    const fresh = <T,>(next: T, apply: (value: T) => void): void => {
      if (generation.current === mine) apply(next)
    }

    const jobs: Array<Promise<unknown>> = []

    if (bridge.copilotState) {
      jobs.push(
        bridge.copilotState().then(
          (raw) => fresh(toCopilotState(raw), setState),
          (cause: unknown) =>
            fresh(errorText(cause, 'Could not read the copilot’s state.'), setProblem),
        ),
      )
    }
    if (bridge.copilotMemory) {
      jobs.push(
        bridge.copilotMemory().then(
          (raw) => fresh(toMemoryReport(raw), setMemory),
          () => fresh(null, setMemory),
        ),
      )
    }
    if (bridge.copilotActions) {
      jobs.push(
        bridge.copilotActions(200).then(
          (raw) => fresh(toActionLog(raw), setActions),
          () => fresh(null, setActions),
        ),
      )
    }
    if (bridge.routinesList) {
      jobs.push(
        bridge.routinesList().then(
          (raw) => fresh(toRoutineRows(raw), setRoutines),
          () => fresh(null, setRoutines),
        ),
      )
    }

    void Promise.all(jobs).finally(() => {
      if (generation.current === mine) setLoading(false)
    })
  }, [bridge])

  useEffect(load, [load])

  // Every load is torn off on unmount, so a reply that lands after the pane has
  // closed cannot set state into a tree that is gone.
  useEffect(() => () => void (generation.current += 1), [])

  /**
   * Run one action, then re-read everything.
   *
   * Every write on this pane changes something another part of it is showing —
   * starting the copilot creates the folder the file list describes and writes
   * two rows the log shows; deleting a memory changes the log too. Re-reading
   * the lot is four small IPC calls and it is the only way the pane cannot
   * disagree with itself, which is the rule this whole feature exists to keep.
   */
  const act = useCallback(
    (key: string, work: () => Promise<string | null>) => {
      setBusy(key)
      setStatus(null)
      void work()
        .then(
          (message) => setStatus(message),
          (cause: unknown) => setStatus(errorText(cause, 'That did not work.')),
        )
        .finally(() => {
          setBusy(null)
          load()
        })
    },
    [load],
  )

  const reveal = useCallback(
    (place: string) => {
      if (!bridge.copilotReveal) return
      act(`reveal:${place}`, async () => toRevealMessage(await bridge.copilotReveal?.(place)))
    },
    [act, bridge],
  )

  if (!bridge.copilotState) {
    return (
      <>
        <SectionHead title="Copilot" blurb={BLURB} />
        <Notice tone="warn">
          This build has no copilot channels wired into its preload, so there is nothing here to
          show. Nothing is broken on disk — the pane simply cannot ask.
        </Notice>
      </>
    )
  }

  const neverStarted = hasNeverStarted(state, memory)

  return (
    <>
      <SectionHead title="Copilot" blurb={BLURB} />

      {problem && <Notice tone="error">{problem}</Notice>}

      {neverStarted && (
        <Notice tone="info">
          It has never been started. Its folder, its instructions and its memory are all written
          the first time it runs — nothing below exists on disk yet.
        </Notice>
      )}

      <SessionGroup
        state={state}
        signIn={signIn}
        loading={loading}
        busy={busy}
        bridge={bridge}
        act={act}
        onSignIn={setSignIn}
        onReveal={reveal}
      />

      <StartupGroup state={state} loading={loading} busy={busy} bridge={bridge} act={act} onReveal={reveal} />

      <MemoryGroup
        memory={memory}
        loading={loading}
        busy={busy}
        bridge={bridge}
        act={act}
        onReveal={reveal}
      />

      <ActionsGroup actions={actions} loading={loading} onReveal={reveal} />

      <DrivingGroup />

      <ReachGroup state={state} />

      <RoutinesGroup
        routines={routines}
        loading={loading}
        busy={busy}
        bridge={bridge}
        act={act}
        onReveal={reveal}
      />

      {status && <Notice tone="info">{status}</Notice>}
    </>
  )
}

const BLURB = 'The one agent that can see every session — and every file it reads, remembers and writes.'

/* -------------------------------------------------------------- driving -- */

/**
 * How fast a tour goes, which is the one part of driving mode that belongs to
 * the reader rather than to the copilot.
 *
 * The control itself is `ReadingSpeedControl`, and every option in it says how
 * long a real paragraph gets at that pace — computed by `estimate.ts` from
 * `SAMPLE_PARAGRAPH` rather than written into the label, so it cannot survive a
 * change to the model that makes it false.
 *
 * It is here rather than in `settings-schema.ts` for a mechanical reason, not a
 * stylistic one: `SettingsWindow.tsx` maps the `copilot` section to this
 * component, which renders none of the schema's rows, so a setting declared into
 * that section would be declared and drawn nowhere. `estimate.ts` carries the
 * rest of the argument, including why five names beat a words-a-minute spinner.
 *
 * **The copilot cannot change it.** `WRITABLE_PREFERENCES` is a short allowlist
 * and this key is not on it, so `settings.write` refuses it with no new work.
 * The reader's pace is the reader's.
 */
function DrivingGroup() {
  const [speed, setSpeed] = useState<ReadingSpeed>(DEFAULT_SPEED)

  useEffect(() => {
    let live = true
    void loadSpeed().then((stored) => {
      if (live) setSpeed(stored)
    })
    return () => {
      live = false
    }
  }, [])

  const store = (next: ReadingSpeed): void => {
    setSpeed(next)
    void saveSpeed(next)
  }

  return (
    <Block
      title="Reading pace"
      says="How long a tour waits on each stop before it moves on."
      more={
        'A tour never waits on this alone. Anything you do — scrolling, clicking, typing, ' +
        'leaving the window — pauses it where it is; resting the pointer on the box stops the ' +
        'clock; and the right arrow moves on immediately. This is only where it starts from, ' +
        'and the app corrects it from how you actually read. The sentence below is what it has ' +
        'measured, and Reset throws that away without changing your choice.'
      }
    >
      <ReadingSpeedControl
        speed={speed}
        onPick={(pace) => store({ pace, scale: speed.scale })}
        onForget={() => store({ pace: speed.pace, scale: 1 })}
      />
      {/*
        The tours themselves, listed here as well as beside the conversation.

        `DRIVING-MODE.md` §6 asks for both and they answer different questions.
        The card in the copilot's own pane is *"read it from here instead of
        going back to the sessions"* — it belongs next to the turn that produced
        it. This is the other half of the same section: **"Settings → Copilot
        lists them and can delete them, in the same pane that already lists
        memory and the action log."** It is the pane a person opens to see
        everything this app is keeping *about* the copilot, and a record written
        outside the copilot's reach is exactly that.

        One component rather than two views of one list, because the second copy
        is the one that drifts — and because the interesting content is the same
        content: the quotes, the drops, and how far it got.
      */}
      <TourRecap limit={3} />
    </Block>
  )
}

/* ---------------------------------------------------------- shared props -- */

interface Acts {
  bridge: Partial<CopilotBridge>
  act(key: string, work: () => Promise<string | null>): void
  busy: string | null
  loading: boolean
  onReveal(place: string): void
}

/**
 * A block: the group heading, one line that has to be read, and then a list.
 *
 * Assembled from `Info`, `useMore` and `MoreBody` rather than from `Explain`,
 * and the difference is not cosmetic. `Explain` draws its own `h5` title and
 * hangs the ⓘ off *that*, so it only offers the long half of an explanation
 * when it has a title of its own — passing it `more` with no `title` silently
 * drops the ⓘ, and every long paragraph on this pane would have been
 * unreachable. Written out here, the ⓘ hangs off the group's own `h4` and the
 * pane keeps the sheet's heading weight instead of introducing a second one.
 *
 * The rhythm the flat sheet groups by is preserved: 40 above the heading, 8
 * below it, 8 to the list, against 20 between two entries — so a heading is
 * always nearer what it names than what it names is to itself.
 *
 * All six blocks go through this, because six hand-written copies of a heading
 * and a paragraph is six chances for one of them to drift into a different
 * shape.
 */
function Block({
  title,
  says,
  more,
  children,
}: {
  title: string
  says: string
  /** The rest of the explanation, behind an ⓘ — the pattern the window uses. */
  more?: string
  children: ReactNode
}) {
  const rest = useMore()
  return (
    <section className="settings-group">
      <h4 className="settings-group-title">
        <span className="settings-label-line">
          {title}
          {more && (
            <Info label={title} open={rest.open} onToggle={rest.toggle}>
              {more}
            </Info>
          )}
        </span>
      </h4>
      <p className="settings-explain-body copilot-says">{says}</p>
      {more && rest.open && <MoreBody>{more}</MoreBody>}
      {children}
    </section>
  )
}

/** A path, with the one action that is always safe for it. */
function PathLine({ path, onOpen, label }: { path: string; onOpen?(): void; label?: string }) {
  return (
    <div className="copilot-pathline">
      <code className="settings-path" title={path}>
        {path}
      </code>
      {onOpen && (
        <Button onClick={onOpen}>{label ?? 'Open'}</Button>
      )}
    </div>
  )
}

/* -------------------------------------------------------------- 1. session -- */

function SessionGroup({
  state,
  signIn,
  bridge,
  act,
  busy,
  loading,
  onSignIn,
  onReveal,
}: Acts & {
  state: CopilotState | null
  signIn: CopilotSignIn | null
  onSignIn(next: CopilotSignIn | null): void
}) {
  const status = state?.status ?? 'stopped'
  const running = status === 'running'

  /*
   * Why Start might not be pressable, in the words a person can act on.
   *
   * There used to be a fourth branch here — a machine with no confinement
   * mechanism the app could prove, where the copilot refused to start at all.
   * That was every Windows machine, and removing it is the change: the copilot
   * is an ordinary session and needs no boundary in order to exist. What is left
   * are the two ordinary reasons and the wiring one.
   *
   * `state.problem` is still drawn, in the status line above — a start that
   * failed because Claude Code is not installed is a sentence somebody can act
   * on, and it is the only place it appears.
   */
  const startBecause = !bridge.ensureCopilot
    ? 'This build cannot start it — the channel is not wired.'
    : running
      ? 'It is already running.'
      : status === 'starting'
        ? 'It is starting.'
        : null

  const stopBecause = !bridge.stopCopilot
    ? 'This build cannot stop it — the channel is not wired.'
    : running
      ? null
      : 'It is not running.'

  return (
    <Block
      title="Its session"
      says={`It runs as an ordinary ${BRAND.name} session, in a folder of its own, as one of your accounts.`}
      more={`Everything the app can already do to a session works on this one: it has a transcript you can read, an account chip, a working directory, and it appears in the usage pane. That is the whole reason it is a session rather than a chat backend — a bespoke agent would have had to re-implement all of that, and every piece of it would have been a black box. It is also why it is not sandboxed: an assistant held to a smaller boundary than the sessions it supervises is worse at supervising them, and it started out signed out and unable to read a line of your code.`}
    >
      <ul className="settings-paths">
        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Status
              <span className="settings-badge" data-copilot-status={status}>
                {STATUS_LABEL[status]}
              </span>
            </span>
            <span className="settings-help">
              {state === null
                ? 'Reading…'
                : running && state.startedAt !== null
                  ? `Started ${when(state.startedAt)}${
                      state.profile === null ? '' : ` as ${state.profile.name}`
                    }. This app’s routines and its action log are ${
                      state.records.enforced ? 'held against it' : 'NOT held against it'
                    }.`
                  : (state.problem ?? 'Nothing is running. Starting it opens a session, which spends.')}
            </span>
            {/*
              The rule, in the place it applies: a control that cannot act says
              why, rather than being greyed out and leaving somebody to guess
              whether the app is broken or the machine is.

              Inside the row rather than under the list. As its own entry it read
              as a floating sentence belonging to nothing — twenty pixels of air
              on both sides is what separates two *rows*, and this is not one; it
              is the caption on the two buttons to its right.

              Both are drawn when both apply. Showing only the first would hide
              the interesting one exactly when the pane is at its least
              informative, which is a build with no channels wired.
            */}
            {startBecause !== null && <span className="settings-help">Start: {startBecause}</span>}
            {stopBecause !== null && <span className="settings-help">Stop: {stopBecause}</span>}
          </span>
          <span className="settings-path-actions">
            <Button
              tone="primary"
              disabled={startBecause !== null || busy !== null || loading}
              onClick={() =>
                act('start', async () => {
                  const next = toCopilotState(await bridge.ensureCopilot?.())
                  return next?.status === 'running'
                    ? 'The copilot is running.'
                    : (next?.problem ?? 'It did not start, and said nothing about why.')
                })
              }
            >
              {busy === 'start' ? 'Starting…' : 'Start it'}
            </Button>
            <Button
              disabled={stopBecause !== null || busy !== null}
              onClick={() =>
                act('stop', async () => {
                  await bridge.stopCopilot?.()
                  return 'Stopped.'
                })
              }
            >
              Stop
            </Button>
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Its account
              {signIn && (
                <span className={signIn.state === 'signed-in' ? 'settings-badge' : 'settings-badge quiet'}>
                  {signIn.state === 'signed-in'
                    ? 'signed in'
                    : signIn.state === 'signed-out'
                      ? 'signed out'
                      : 'unknown'}
                </span>
              )}
            </span>
            <span className="settings-help">
              {signIn?.account
                ? `${signIn.account}${signIn.plan ? ` — ${signIn.plan}` : ''}`
                : 'One of the accounts in Accounts, resolved the same way any session in this folder resolves one. It signs in there, with you, rather than having a login of its own.'}
            </span>
            <span className="settings-help">
              {signIn === null
                ? `Running as ${state?.profile?.name ?? 'your default account'}.`
                : `Running as ${signIn.profileName || state?.profile?.name || 'your default account'}. Pin a different one by setting an account for its folder; it takes effect the next time it starts.`}
            </span>
          </span>
          <span className="settings-path-actions">
            <Button
              disabled={!bridge.copilotSignIn || busy !== null}
              onClick={() =>
                act('signin', async () => {
                  const next = toCopilotSignIn(await bridge.copilotSignIn?.())
                  onSignIn(next)
                  return next === null
                    ? 'Its login could not be read.'
                    : next.state === 'signed-in'
                      ? `Signed in${next.account ? ` as ${next.account}` : ''}.`
                      : next.state === 'signed-out'
                        ? `${next.profileName || 'That account'} is signed out. Sign it in under Accounts, the same as any other.`
                        : 'That account’s sign-in state could not be read.'
                })
              }
            >
              {busy === 'signin' ? 'Checking…' : 'Check'}
            </Button>
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">Its folder</span>
            <span className="settings-help">
              Its working directory, and where its instructions and its memory live.
            </span>
            <PathLine path={state?.paths.root ?? '—'} onOpen={() => onReveal('root')} />
          </span>
        </li>
      </ul>
    </Block>
  )
}

/* ------------------------------------------------------------- 2. startup -- */

/**
 * The four states `CLAUDE.md` can be in, and what each one licenses.
 *
 * The distinction that earns its keep is between the middle two, and
 * `copilot-home.ts` argues it at length: `superseded` is a default *this app*
 * wrote in an older build that nobody has touched — safe to replace, and worth
 * offering loudly, because an out-of-date instruction file makes the copilot
 * wrong about its own powers. `edited` is somebody's own writing, and the app
 * never puts its wording back over it without being asked twice.
 *
 * Reporting both as "edited" is the failure this table exists to prevent: it is
 * how a person ends up running a copilot whose instruction file tells it that
 * it cannot read their projects, with no offer on screen to fix it.
 */
const INSTRUCTIONS: Record<
  CopilotState['instructions'],
  { badge: string; quiet: boolean; says: string }
> = {
  missing: {
    badge: 'not written yet',
    quiet: true,
    says: 'The file does not exist. Creating its files writes the version this build ships.',
  },
  current: {
    badge: 'as shipped',
    quiet: true,
    says: 'Byte for byte what this build ships. You can edit it — the app will never write over your version.',
  },
  superseded: {
    badge: 'out of date',
    quiet: false,
    says: 'A default an older build wrote, untouched since — nothing in it is yours. It describes powers this build has changed, so the copilot is being told something untrue about itself.',
  },
  edited: {
    badge: 'yours',
    quiet: true,
    says: 'These are your words, and they are the truth for the copilot rather than this build’s wording. Nothing in the app will replace them.',
  },
}

function StartupGroup({
  state,
  bridge,
  act,
  busy,
  loading,
  onReveal,
}: Acts & { state: CopilotState | null }) {
  const [confirm, setConfirm] = useState(false)
  const files = state?.startupFiles ?? []
  const instructions = state?.instructions ?? 'missing'
  const note = INSTRUCTIONS[instructions]

  const resetBecause = !bridge.copilotResetInstructions
    ? 'This build cannot restore it — the channel is not wired.'
    : instructions === 'current'
      ? 'It already matches this build.'
      : instructions === 'missing'
        ? 'There is no file yet. Create its files instead.'
        : null

  /*
   * The file is re-read whenever the pane's own state changed underneath it.
   *
   * Keyed on `instructions` and on the file's own mtime rather than on a mount:
   * pressing Restore rewrites the file from another control in this same block,
   * and an editor still holding the pre-restore text would put it straight back
   * the next time somebody pressed Save. Both keys are needed — a restore
   * changes `instructions`, and an edit made in a real editor while this pane is
   * open changes only the time.
   */
  const claudeFile = files.find((file) => baseName(file.path) === 'CLAUDE.md') ?? null
  const [text, setText] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const key = `${instructions}:${claudeFile?.modifiedAt ?? 0}`
  const readKey = useRef<string | null>(null)

  useEffect(() => {
    if (instructions === 'missing') {
      setText(null)
      setProblem('There is no CLAUDE.md yet — create its files above, and it appears here.')
      return
    }
    if (!bridge.copilotReadInstructions) {
      setText(null)
      setProblem('This build cannot read its instructions — the channel is not wired.')
      return
    }
    if (readKey.current === key) return
    readKey.current = key
    void bridge.copilotReadInstructions().then(
      (raw) => {
        const result = toInstructionsRead(raw)
        if (result.ok) {
          setText(result.text)
          setProblem(null)
        } else {
          setText(null)
          setProblem(result.error)
        }
      },
      (cause: unknown) => {
        setText(null)
        setProblem(errorText(cause, 'Its instructions could not be read.'))
      },
    )
  }, [bridge, instructions, key])

  const running = state?.status === 'running'
  const saveBecause = !bridge.copilotWriteInstructions
    ? 'This build cannot save it — the channel is not wired.'
    : null

  /*
   * What the last save did, kept here rather than in the pane's status notice.
   *
   * That notice renders after all six blocks, and this editor sits near the top
   * of a screen and a half of content — so pressing Save put the sentence naming
   * the backup file somewhere nobody would look. Each editor's `onSave` returns
   * `null` to `act`, which leaves the pane-level notice empty, and puts its own
   * result under its own box.
   */
  const [saveNote, setSaveNote] = useState<{ text: string; ok: boolean } | null>(null)

  return (
    <Block
      title="What it reads at startup"
      says="These files, in this order, before it answers anything."
      more={`This is the answer to "why did it say that". A person who wants to know why their assistant behaved a certain way can read exactly the files the assistant read — the list is computed from the filesystem every time this pane opens, not remembered, so an edit you just made shows up here.`}
    >
      {files.length === 0 ? (
        <p className="settings-prose">
          {loading ? 'Reading…' : 'Nothing yet — its folder has not been created.'}
        </p>
      ) : (
        <ol className="settings-paths copilot-ordered">
          {files.map((file, index) => (
            <li className="settings-path-row" key={file.path}>
              <span className="copilot-ordinal" aria-hidden="true">
                {index + 1}
              </span>
              <span className="settings-path-main">
                <span className="settings-label">
                  {baseName(file.path)}
                  {!file.exists && <span className="settings-badge quiet">not there</span>}
                </span>
                <span className="settings-help">
                  {file.purpose}
                  {file.exists && file.size !== null
                    ? ` — ${bytes(file.size)}, changed ${when(file.modifiedAt)}`
                    : ''}
                </span>
                <code className="settings-path" title={file.path}>
                  {file.path}
                </code>
              </span>
            </li>
          ))}
        </ol>
      )}

      <div className="settings-actions">
        <Button
          disabled={!bridge.copilotScaffold || instructions !== 'missing' || busy !== null}
          onClick={() =>
            act('scaffold', async () => {
              const result = toScaffoldResult(await bridge.copilotScaffold?.())
              return result.error !== null
                ? result.error
                : result.created.length === 0
                  ? 'Everything was already there.'
                  : `Created ${result.created.length} file${result.created.length === 1 ? '' : 's'}. Nothing was started.`
            })
          }
        >
          Create its files
        </Button>
      </div>
      {instructions !== 'missing' && (
        <p className="settings-help copilot-aside">
          Its files exist, so there is nothing to create. Its instructions are below, and every
          memory further down, editable here or in your own editor.
        </p>
      )}

      <div className="copilot-instructions">
        <span className="settings-label">
          CLAUDE.md
          <span className={note.quiet ? 'settings-badge quiet' : 'settings-badge'}>{note.badge}</span>
        </span>
        <span className="settings-help">{note.says}</span>

        {/*
          The box, and it is the copilot's real system instruction rather than a
          preview of one. Editing it is editing the agent — which is why the
          effect line under it is about *when*, and why Restart is offered beside
          Save rather than left for somebody to work out.

          Kept ahead of the Restore control, not after it: the thing a person
          came here to do is read and change their assistant's instructions, and
          the way back to the shipped wording is a fallback under it.
        */}
        <FileEditor
          label="CLAUDE.md"
          text={text}
          problem={problem}
          rows={20}
          saveBecause={saveBecause}
          saving={busy === 'instructions-save'}
          note={saveNote}
          effect={
            running
              ? 'Saving changes what it is told the next time it starts. The copilot running now still has the old text — restart it to hand it the new one.'
              : 'Saving changes what it is told the next time it starts.'
          }
          onSave={(next) => {
            setSaveNote(null)
            act('instructions-save', async () => {
              const result = toInstructionsWrite(await bridge.copilotWriteInstructions?.(next))
              if (result.error !== null) {
                setSaveNote({ text: result.error, ok: false })
              } else {
                // The saved bytes are what is on disk, so the box goes clean at
                // once rather than waiting for the re-read the mtime triggers.
                // See the memory editor for what leaving this out looks like.
                setText(next)
                const where = result.backup === null ? '' : ` What was there is at ${result.backup}.`
                setSaveNote({
                  text: running
                    ? `Saved.${where} The running copilot still has the old text — restart it to apply this.`
                    : `Saved.${where} It applies the next time the copilot starts.`,
                  ok: true,
                })
              }
              // Nothing for the pane-level notice: the sentence is under the box.
              return null
            })
          }}
        >
          {/*
            Restart, beside Save, and only while something is running.
            "It applies at the next start" is a true sentence that leaves
            somebody with a job to do, and the job is two clicks on the other
            side of this pane. Stop-then-start rather than a reload, because
            there is no reload: the CLI reads `CLAUDE.md` as it spawns.
          */}
          {running && (
            <Button
              disabled={!bridge.stopCopilot || !bridge.ensureCopilot || busy !== null}
              onClick={() => {
                setSaveNote(null)
                act('restart', async () => {
                  await bridge.stopCopilot?.()
                  const next = toCopilotState(await bridge.ensureCopilot?.())
                  /*
                   * The restart's own result replaces the save's, in the same
                   * place, because they are the two halves of one sentence: the
                   * save says "the running copilot still has the old text" and
                   * this is the answer to it. Leaving both on screen would have
                   * the box telling somebody to restart directly above the line
                   * saying they just did.
                   */
                  setSaveNote(
                    next?.status === 'running'
                      ? { text: 'Restarted. It has read the current instructions.', ok: true }
                      : {
                          text: next?.problem ?? 'It stopped, and did not come back up.',
                          ok: false,
                        },
                  )
                  return null
                })
              }}
            >
              {busy === 'restart' ? 'Restarting…' : 'Restart it'}
            </Button>
          )}
          <Button onClick={() => onReveal('instructions')} disabled={!bridge.copilotReveal}>
            Open in Finder
          </Button>
        </FileEditor>

        {/*
          The way back to the shipped wording, and the reason it is still a
          confirmation rather than another Save. The editor above never replaces
          anything without somebody having read what is in the box first; this
          one puts *this build's* text over whatever is there, which for an
          `edited` file means throwing away writing nobody has looked at in this
          session. A copy is kept either way, and the sentence says where.
        */}
        {resetBecause !== null ? (
          <span className="settings-help">Restore: {resetBecause}</span>
        ) : confirm ? (
          <div className="settings-confirm">
            <span>
              {instructions === 'edited'
                ? 'Replace your version with the one this build ships? A copy of yours is kept beside it as CLAUDE.md.bak.'
                : 'Replace this older default with the one this build ships? A copy of the old one is kept beside it.'}
            </span>
            <Button
              tone={instructions === 'edited' ? 'danger' : 'primary'}
              disabled={busy !== null}
              onClick={() => {
                setConfirm(false)
                setSaveNote(null)
                act('reset', async () => {
                  const result = toResetResult(await bridge.copilotResetInstructions?.())
                  /*
                   * Into the editor's own note, replacing whatever the last save
                   * said. Both controls act on one file, and a "Saved." from
                   * five seconds ago sitting beside "Restored." is two claims
                   * about `CLAUDE.md` where only the newer one is true.
                   */
                  setSaveNote(
                    result.error !== null
                      ? { text: result.error, ok: false }
                      : {
                          text:
                            result.backup === null
                              ? 'Restored. The box above is this build’s wording again.'
                              : `Restored. What was there is at ${result.backup}.`,
                          ok: result.error === null,
                        },
                  )
                  return null
                })
              }}
            >
              Restore the shipped instructions
            </Button>
            <Button onClick={() => setConfirm(false)}>Cancel</Button>
          </div>
        ) : (
          <div className="settings-actions">
            <Button
              tone={instructions === 'superseded' ? 'primary' : 'default'}
              onClick={() => setConfirm(true)}
              disabled={busy !== null}
            >
              Restore the shipped instructions…
            </Button>
          </div>
        )}
      </div>
    </Block>
  )
}

/* -------------------------------------------------------------- 3. memory -- */

function MemoryGroup({
  memory,
  bridge,
  act,
  busy,
  loading,
  onReveal,
}: Acts & { memory: MemoryReport | null }) {
  const [open, setOpen] = useState<string | null>(null)
  const [text, setText] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  /**
   * True when the reader could only hand back the head of the file.
   *
   * The single most dangerous state on this pane, and the reason it is tracked
   * separately from the text rather than folded into it as a trailing note the
   * way the read-only version did. `readMemoryFact` stops at 256 KB; a Save from
   * a box holding the first 256 KB of a longer file would write exactly that and
   * delete the rest. So the flag disables Save with the sentence saying why, and
   * points at the editor that can open the whole thing.
   */
  const [truncated, setTruncated] = useState(false)
  const [confirm, setConfirm] = useState<string | null>(null)
  /** What the last save said, under the box that produced it — see `StartupGroup`. */
  const [note, setNote] = useState<{ text: string; ok: boolean } | null>(null)

  const read = useCallback(
    (name: string) => {
      // The note belongs to the fact that produced it. One `note` serves the
      // whole list because only one editor is open at a time — which is only
      // true if closing or switching clears it, or "Saved." follows you onto the
      // next memory you open.
      setNote(null)
      if (open === name) {
        setOpen(null)
        setText(null)
        setProblem(null)
        setTruncated(false)
        return
      }
      setOpen(name)
      setText(null)
      setProblem(null)
      setTruncated(false)
      if (!bridge.copilotMemoryRead) {
        setProblem('This build cannot read a memory file — the channel is not wired.')
        return
      }
      void bridge.copilotMemoryRead(name).then(
        (raw) => {
          const result = toMemoryRead(raw)
          if (result.ok) {
            setText(result.text)
            setTruncated(result.truncated)
          } else {
            setProblem(result.error)
          }
        },
        (cause: unknown) => setProblem(errorText(cause, 'That file could not be read.')),
      )
    },
    [bridge, open],
  )

  const facts = memory?.facts ?? []
  const writeBecause = !bridge.copilotMemoryWrite
    ? 'This build cannot save a memory — the channel is not wired.'
    : null

  return (
    <Block
      title="Its memory"
      says="One file per fact, and every one of them is its own — never another session's."
      more={`Its memory is built from its conversation with you and nothing else. What it reads out of another session — a transcript, a diff, terminal output — is evidence it reports on, and its instructions forbid any of that from being written here, because memory is loaded at startup and a fact copied out of somebody else's agent would then be in its head in every future conversation. Credentials never go in either. Say plainly what that is: a rule in its instructions rather than something the machine refuses, which is why you can read every file in this folder. You can read every file, correct one in place, and delete any of them — a fact whose path has moved is worth fixing rather than throwing away, which is what its own instructions tell it to do too.`}
    >
      {memory === null ? (
        <p className="settings-prose">{loading ? 'Reading…' : 'The memory folder could not be read.'}</p>
      ) : !memory.exists ? (
        <p className="settings-prose">
          It has no memory folder yet. One is created the first time it runs, or when you create its
          files above.
        </p>
      ) : facts.length === 0 ? (
        <p className="settings-prose">The folder is there and it is empty. It has learned nothing yet.</p>
      ) : (
        <ul className="settings-paths">
          {facts.map((fact) => (
            <li className="settings-path-row copilot-fact" key={fact.name}>
              <span className="settings-path-main">
                <span className="settings-label">
                  {fact.name}
                  {fact.index && <span className="settings-badge quiet">index</span>}
                  {fact.type && <span className="settings-badge quiet">{fact.type}</span>}
                </span>
                <span className="settings-help">
                  {fact.description ?? (fact.index ? 'The list it keeps of everything below.' : 'No description in its front matter.')}
                </span>
                <span className="settings-help">
                  {[
                    fact.scope ? `scope ${fact.scope}` : null,
                    /* `verified` is surfaced because the copilot's own
                       instructions make a promise about it: a fact whose check
                       is over a month old has to be quoted with its date. A
                       person can only hold it to that if the date is visible
                       without opening the file. */
                    fact.verified ? `verified ${fact.verified}` : null,
                    `${bytes(fact.bytes)}, changed ${when(fact.modifiedAt)}`,
                  ]
                    .filter((part): part is string => part !== null)
                    .join(' · ')}
                </span>

                {open === fact.name && (
                  <FileEditor
                    label={fact.name}
                    text={text}
                    problem={problem}
                    rows={12}
                    saving={busy === `memory-save:${fact.name}`}
                    saveBecause={
                      truncated
                        ? 'this file is longer than the pane can show, so saving from here would throw the rest of it away. Open the memory folder and edit it there.'
                        : writeBecause
                    }
                    note={note}
                    effect="Saving changes what it knows the next time it starts — its memory is read as the session spawns."
                    onSave={(next) => {
                      setNote(null)
                      act(`memory-save:${fact.name}`, async () => {
                        const result = toMemoryWrite(
                          await bridge.copilotMemoryWrite?.(fact.name, next),
                        )
                        /*
                         * What was written *is* what is now on disk, so say so
                         * rather than re-reading it.
                         *
                         * Without this the box stayed dirty after a successful
                         * save — Save still blue, the line still reading
                         * "Unsaved." — because the editor compares its draft
                         * against the text this component last read, and that
                         * read happened when the fact was opened. Seen on the
                         * real pane; it is the kind of thing that makes somebody
                         * press Save twice and then doubt the first press.
                         * `writeMemoryFact` writes verbatim, so `next` is exact.
                         */
                        if (result.ok) setText(next)
                        setNote(
                          result.ok
                            ? { text: 'Saved. The edit is in its action log, recorded as yours.', ok: true }
                            : { text: result.error ?? 'That file could not be saved.', ok: false },
                        )
                        return null
                      })
                    }}
                  />
                )}

                {confirm === fact.name && (
                  <div className="settings-confirm">
                    <span>Forget {fact.name}? It is deleted from disk.</span>
                    <Button
                      tone="danger"
                      disabled={busy !== null}
                      onClick={() => {
                        setConfirm(null)
                        setOpen(null)
                        act(`forget:${fact.name}`, async () => {
                          const result = toMemoryDelete(await bridge.copilotMemoryDelete?.(fact.name))
                          return result.ok
                            ? `Forgotten. The deletion is in its action log, recorded as yours.`
                            : (result.error ?? 'That file could not be deleted.')
                        })
                      }}
                    >
                      Forget it
                    </Button>
                    <Button onClick={() => setConfirm(null)}>Cancel</Button>
                  </div>
                )}
              </span>
              <span className="settings-path-actions">
                {/*
                  One button rather than a Read and an Edit. The box is
                  readable, so a separate viewer would be a second control
                  doing the lesser half of what this one already does — and on
                  a list of facts that is two buttons per row before the delete
                  is counted.
                */}
                <Button onClick={() => read(fact.name)}>{open === fact.name ? 'Close' : 'Edit'}</Button>
                {/*
                  Plain here, red in the confirmation.

                  Advanced draws its one destructive button in the danger tone
                  and that is right for one button on a pane. A memory directory
                  is a list, and a list of red buttons is a page that reads as a
                  warning — which teaches the eye to stop seeing red, exactly
                  where the next red thing might matter. The click that actually
                  deletes is the one that wears the colour.
                */}
                <Button
                  disabled={!bridge.copilotMemoryDelete || busy !== null}
                  onClick={() => setConfirm(fact.name)}
                >
                  Forget
                </Button>
              </span>
            </li>
          ))}
        </ul>
      )}

      <div className="settings-actions">
        <Button onClick={() => onReveal('memory')} disabled={!bridge.copilotReveal}>
          Open the memory folder
        </Button>
        {memory?.dir && <code className="settings-path">{memory.dir}</code>}
      </div>
    </Block>
  )
}

/* ---------------------------------------------------------- 4. action log -- */

/** One row, in the shape that tells an app event from a tool call at a glance. */
function ActionRow({ row }: { row: LoggedAction }) {
  const refused = row.outcome === 'refused'
  const failed = row.outcome === 'error'
  return (
    <li className="copilot-action" data-outcome={row.outcome ?? 'event'}>
      <span className="copilot-action-time">{whenIso(row.at)}</span>
      <span className="copilot-action-body">
        <span className="copilot-action-head">
          <code className="copilot-action-name">{row.tool ?? row.action}</code>
          {row.tier && <span className="settings-badge quiet">{row.tier}</span>}
          {refused && <span className="settings-badge quiet">refused</span>}
          {failed && <span className="settings-badge quiet">failed</span>}
          {row.caller === 'remote' && <span className="settings-badge quiet">from a paired device</span>}
        </span>
        <span className="settings-help">{row.detail || '—'}</span>
        {row.error && <span className="settings-help">{row.error}</span>}
        <span className="settings-help">
          {/*
            Who confirmed, spelled out rather than left as a tick.
            `confirmed === null` means this row is not a tool call at all — it
            is the app recording something it did — and saying "no human
            confirmed" of those would be true and misleading in the same
            breath.
          */}
          {row.confirmed === null
            ? `${BRAND.name} wrote this row itself`
            : row.confirmationRequired === false
              ? 'no confirmation needed at this tier'
              : row.confirmed
                ? `you confirmed it${row.confirmedBy ? ` (${row.confirmedBy})` : ''}`
                : `not confirmed${row.refusedReason ? ` — ${row.refusedReason}` : ''}`}
          {row.ms !== null ? ` · ${row.ms} ms` : ''}
        </span>
      </span>
    </li>
  )
}

function ActionsGroup({
  actions,
  loading,
  onReveal,
}: {
  actions: ActionLogReport | null
  loading: boolean
  onReveal(place: string): void
}) {
  const [all, setAll] = useState(false)
  const rows = actions?.rows ?? []
  const shown = all ? [...rows].reverse() : [...rows].reverse().slice(0, 12)

  return (
    <Block
      title="The action log"
      says="Every tool call it made, what came back, and whether a human said yes."
      more={`It is append-only, one JSON object per line, and it is kept outside the copilot's own folder on purpose — and, on macOS, refused to it by the operating system. Without that, a log the copilot can write is one it could append to, edit, truncate or delete, and a record the audited party can compose is not a record. The app writes every line. The copilot's only way to add one is a log.note tool call, which is itself logged, so a row it wrote can never impersonate a row the app wrote.`}
    >
      {actions !== null && (
        <p className="settings-help copilot-aside">{logTrustLine(actions)}</p>
      )}

      {rows.length === 0 ? (
        <p className="settings-prose">
          {loading
            ? 'Reading…'
            : actions?.exists
              ? 'The file is there and has nothing in it yet.'
              : 'Nothing has been recorded — the copilot has done nothing yet.'}
        </p>
      ) : (
        <>
          <ul className="copilot-actions">
            {shown.map((row, index) => (
              <ActionRow key={`${row.at}-${row.action}-${index}`} row={row} />
            ))}
          </ul>
          {rows.length > shown.length && (
            <Button onClick={() => setAll(true)}>
              Show the other {rows.length - shown.length}
            </Button>
          )}
        </>
      )}

      <div className="settings-actions">
        <Button onClick={() => onReveal('log')}>Open the log folder</Button>
        {actions && (
          <code className="settings-path" title={actions.file}>
            {actions.file}
            {actions.exists ? ` — ${bytes(actions.bytes)}` : ''}
          </code>
        )}
      </div>
    </Block>
  )
}

/* --------------------------------------------------------------- 5. reach -- */

/**
 * What the copilot can reach, said the way round it is actually true.
 *
 * This block used to describe a jail: two writable directories, your projects
 * read-only, credential shapes carved out, your home directory and keychain
 * unreachable. Every one of those sentences was true when it was written, and
 * the jail is gone — it cost the copilot its login, its ability to write
 * anything, and its existence on Windows entirely. `confine/records.ts` carries
 * that argument.
 *
 * So the block is inverted. The old one led with a long list of refusals and
 * buried the capability; this one leads with the single fact a person needs —
 * *it can do what you can do* — and then names the three exceptions, which is a
 * list short enough to print in full. A screen that lists ten reassurances is
 * one nobody reads; a screen that says one uncomfortable thing plainly is one
 * they believe.
 *
 * The order is deliberate too: the responsibility comes before the exceptions.
 * Somebody scanning this needs to know they are looking at an unsandboxed agent
 * before they are told what it cannot touch, or the exceptions read as the whole
 * story.
 */
function ReachGroup({ state }: { state: CopilotState | null }) {
  const records = state?.records
  const held = records?.enforced === true
  const fenceable = (records?.kind ?? 'none') !== 'none'

  return (
    <Block
      title="What it can reach"
      says={`Everything you can. It is an ordinary ${BRAND.name} session running as your account, not a sandboxed one.`}
      more={`It was confined once, and the confinement made it worse at its job than any session it supervises: it started signed out, because its login would have lived in a keychain a sandboxed process cannot open, and it could not read a line of your code. A jail also never stopped anything leaving — the network is open to every session, because closing it would break git and npm — so what it bought was a smaller pool of things to read, at the cost of the feature. What bounds the copilot instead is the tool tiers and the confirmation you are shown before it changes anything, plus the three refusals below.`}
    >
      <ul className="settings-paths">
        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Reads and writes
              <span className="settings-badge quiet">not sandboxed</span>
            </span>
            <span className="settings-help">
              Your home directory, your projects, your shell and your tools, your git and GitHub
              logins, your keychain, the network. The same as any session you open yourself, and the
              same as the sessions it supervises.
            </span>
            <span className="settings-help">
              Reading your code is what lets it look at the failing test instead of asking you to
              paste it. Writing is what lets it fix a line rather than describing the fix. Anything
              that touches this app’s own state — your settings, your sessions, your routines —
              goes through a confirmation you see, whatever else is set.
            </span>
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">Two kinds of prompt, and only one is ours</span>
            {/*
              The one screen in the app where two permission systems meet, said
              plainly because they look like one and are not.

              Claude Code has its own prompts, governed by `permissions.defaultMode`
              in the person's own settings file. The copilot is an ordinary session
              running as them, so it reads that file like every other session they
              open — and on a machine set to bypass, it will not stop before running
              a command or editing a file. That is their setting, applied to their
              own agent, and this app neither loosens nor tightens it: the launch
              carries no `--permission-mode` and no `--dangerously-skip-permissions`,
              which `copilot-session.test.ts` pins in both directions.

              This app's confirmation is a different mechanism entirely — asked by
              the desktop, of the person at the desk, after the tier check, over an
              HTTP request the agent cannot answer for itself. Nothing in the CLI's
              settings can reach it. `deck-control/index.test.ts` proves that with a
              tool call carrying every field a client could invent to wave itself
              through.

              The failure this paragraph exists to prevent is the quiet one: somebody
              turning off Claude Code's prompts and believing they turned off this
              app's, or seeing this app ask and assuming the CLI asked too.
            */}
            <span className="settings-help">
              Claude Code’s own prompts — before it runs a command or edits a file — follow{' '}
              <em>your</em> settings, in <code>~/.claude/settings.json</code>, exactly as they do in
              every other session you open. If you have set that to bypass them, the copilot will
              not stop to ask either. This app does not change that setting in either direction.
            </span>
            <span className="settings-help">
              The confirmation <em>this app</em> shows you — before it writes a setting, starts a
              session or changes a routine — is a separate thing, asked by the desktop rather than
              by the CLI. Nothing in your Claude Code settings turns it off, and nothing the copilot
              can say answers it. With no window open to ask, it is refused rather than allowed.
            </span>
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Refused: this app’s own records
              <span className={held ? 'settings-badge' : 'settings-badge quiet'}>
                {held ? 'held' : fenceable ? 'not proven' : 'not enforced here'}
              </span>
            </span>
            <span className="settings-help">
              Five paths, and only five. It cannot write a routine — an agent that can write its
              own next trigger is an automation loop with no human in it — it cannot read or
              write the log of what it did, because a record its subject can compose is worth
              nothing, and it cannot touch the two files that decide which of your paired devices
              may reach it, because a permission an agent can grant itself is not a permission.
            </span>
            {records && records.paths.length > 0 && (
              <ul className="copilot-plain">
                {records.paths.map((path) => (
                  <li key={path}>
                    <code className="settings-path">{path}</code>
                  </li>
                ))}
              </ul>
            )}
            {state && (
              <span className="settings-help">
                {held
                  ? 'The running process was started inside that refusal, measured against this machine rather than assumed.'
                  : records?.reason !== null && records?.reason !== undefined
                    ? records.reason
                    : state.status === 'running'
                      ? 'The running process is NOT inside that refusal.'
                      : 'Nothing is running, so nothing is being held right now.'}
              </span>
            )}
            {!fenceable && (
              <span className="settings-help">
                {/*
                  The honest half, in its own sentence rather than folded into
                  the one above. `CONFINEMENT.md`'s first rule is that one
                  sentence never covers two platforms, and this is the same
                  situation: on a machine that cannot hold the refusal, the
                  copilot is asked not to touch these files and that is all.
                */}
                Here it is a rule in its instructions rather than a refusal by the operating system.
                Its actions are still recorded; the record is not held against it.
              </span>
            )}
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">A rule, not a wall: its memory</span>
            <span className="settings-help">
              It can read your other sessions’ transcripts — that is one of the things it is for —
              and its instructions tell it never to copy any of that into its own <code>memory/</code>,
              which is the folder it loads at the start of every conversation. Nothing on this
              machine enforces that. It is a rule it keeps, written in its <code>CLAUDE.md</code> in
              those words, and <code>memory/</code> is a folder you can read and prune yourself.
            </span>
          </span>
        </li>
      </ul>
    </Block>
  )
}

/* ------------------------------------------------------------ 6. routines -- */

const ROUTINE_STATE_TEXT: Record<RoutineRow['state'], string> = {
  armed: 'armed',
  running: 'running now',
  disabled: 'off in its own file',
  broken: 'broken',
  unarmed: 'nothing is listening',
  paused: 'paused',
  stale: 'stale',
}

function RoutineEntry({
  routine,
  bridge,
  act,
  busy,
}: {
  routine: RoutineRow
  bridge: Partial<CopilotBridge>
  act(key: string, work: () => Promise<string | null>): void
  busy: string | null
}) {
  const [open, setOpen] = useState(false)
  const [confirm, setConfirm] = useState(false)
  const [text, setText] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  /** What the last save said, under this routine's own box — see `StartupGroup`. */
  const [note, setNote] = useState<{ text: string; ok: boolean } | null>(null)

  /**
   * Open the file, as text.
   *
   * `routine.prompt` is already on this row and the earlier version of this
   * control showed exactly that, which was the wrong half: the prompt is the
   * part a person is *least* likely to need to change, because the trigger and
   * the folder are what a routine gets wrong. And the prompt as the engine holds
   * it has been through the parser, so writing it back would have quietly
   * dropped whatever notes were in the file. So the box holds the file.
   */
  const toggle = useCallback(() => {
    setNote(null)
    if (open) {
      setOpen(false)
      setText(null)
      setProblem(null)
      return
    }
    setOpen(true)
    setText(null)
    setProblem(null)
    if (!bridge.routinesText) {
      setProblem('This build cannot open a routine file — the channel is not wired.')
      return
    }
    void bridge.routinesText(routine.id).then(
      (raw) => {
        const result = toRoutineText(raw)
        if (result.ok) setText(result.text)
        else setProblem(result.problems.join(' '))
      },
      (cause: unknown) => setProblem(errorText(cause, 'That routine could not be read.')),
    )
  }, [bridge, open, routine.id])

  /*
   * The case this whole block exists for.
   *
   * A routine the engine stopped after it kept failing and a routine that
   * simply has not been triggered lately look exactly alike in any list that
   * shows only a name and a last-run time — and the first one is a thing
   * somebody has to act on. So it is called out in its own line, with the
   * engine's reason and the failure count, above everything else about the
   * routine.
   */
  const brokenOff = routine.state === 'paused' && routine.consecutiveFailures > 0

  /*
   * The switch is Armed, not Enabled, because pause is what it writes.
   *
   * `enabled:` is a line in the routine's own file — a file a person wrote and
   * may have hand-edited — and a switch in Settings that silently rewrote it
   * would be the app editing somebody's work to record a preference of its own.
   * Pause and resume are engine state, kept beside the file rather than in it,
   * which is exactly the right place for "not right now".
   */
  const fileOff = routine.state === 'disabled'
  const armed = !fileOff && routine.state !== 'paused'
  const switchBecause = fileOff
    ? /*
       * Composed from the engine's own sentence rather than restated.
       *
       * `stateOf` in `engine.ts` writes "Turned off in its file (`enabled: no`)",
       * and a second copy of that fact here would be a second copy that can
       * drift — which on this pane means two lines in the same entry saying
       * nearly the same thing, one of them eventually wrong. The engine says
       * what is true; this adds only what to do about it.
       *
       * What to do about it changed when the file became editable here. It used
       * to end "the app will not edit a file you wrote", which was the honest
       * answer while the only writer was the pause state — and would now be a
       * lie sitting directly above a Save button. The switch still never touches
       * the file; Edit does, and only on a press.
       */
      `${routine.reason ?? 'It is off in its own file.'} Press Edit and change its \`enabled:\` line — the switch never writes to the file.`
    : !bridge.routinesPause || !bridge.routinesResume
      ? 'This build cannot pause a routine — the channel is not wired.'
      : null

  const runBecause = !bridge.routinesRun
    ? 'This build cannot run a routine — the channel is not wired.'
    : routine.running
      ? 'It is running now.'
      : routine.state === 'broken'
        ? // Nothing to run: the file did not parse, so there is no prompt and no
          // trigger. The engine's own first problem is the sentence that says why.
          (routine.problems[0] ?? routine.reason ?? 'This routine could not be read.')
        : null

  return (
    <li className="settings-path-row copilot-routine" data-state={routine.state}>
      <span className="settings-path-main">
        <span className="settings-label">
          {routine.name}
          {/*
            The state, in the badge, coloured by what it means.

            This carries the whole "a paused routine and a quiet one look
            identical" problem at a glance, which is why the colour is on the
            badge rather than on a rule beside the entry: a line down the side
            would indent every routine name away from the headings and the rows
            above them, and the design brief's order is space, then a tint, then
            — only then — a line.
          */}
          <span className="settings-badge quiet" data-routine-state={routine.state}>
            {ROUTINE_STATE_TEXT[routine.state]}
          </span>
        </span>

        {brokenOff && (
          <Notice tone="warn">
            {routine.reason ??
              `Stopped after ${routine.consecutiveFailures} failures in a row.`}{' '}
            {routine.pausedUntil === null
              ? 'It will not run again until you resume it.'
              : `It comes back on its own at ${when(routine.pausedUntil)}.`}
          </Notice>
        )}

        {/* `fileOff` is excluded because `switchBecause` below is built from
            this same sentence and adds what to do about it. Printing both puts
            two nearly-identical lines in one entry. */}
        {!brokenOff && !fileOff && routine.reason && (
          <span className="settings-help">{routine.reason}</span>
        )}

        <span className="settings-help">
          {routine.triggers.length > 0 ? routine.triggers.join(' · ') : 'no trigger'}
          {routine.folder ? ` — in ${routine.folder}` : ''}
        </span>

        <span className="settings-help">
          {routine.lastFinishedAt === null
            ? 'It has never run.'
            : `Last run ${when(routine.lastFinishedAt)} — ${
                routine.lastOutcome === 'ok'
                  ? 'finished'
                  : routine.lastOutcome === 'failed'
                    ? `failed${routine.lastError ? `: ${routine.lastError}` : ''}`
                    : 'outcome unknown'
              }.`}
          {routine.nextDueAt !== null ? ` Next due ${when(routine.nextDueAt)}.` : ''}
          {routine.missedWhileClosed > 0
            ? ` ${routine.missedWhileClosed} due while the app was closed.`
            : ''}
        </span>

        {routine.refusedCalls.length > 0 && (
          <span className="settings-help">
            {/* An unattended run cannot answer a confirmation, so an alter-tier
                call is refused at the boundary rather than hanging on a dialog
                nobody will see. That is the boundary working — and it is also
                the only answer to "it ran and nothing happened". */}
            {routine.refusedCalls.length} call
            {routine.refusedCalls.length === 1 ? ' was' : 's were'} refused during its runs — a
            decision is waiting for you rather than the routine being broken.
          </span>
        )}

        {routine.problems.map((line) => (
          <span className="settings-help" key={line}>
            {line}
          </span>
        ))}

        {open && (
          <>
            <FileEditor
              label={baseName(routine.file)}
              text={text}
              problem={problem}
              rows={14}
              saving={busy === `routine-save:${routine.id}`}
              saveBecause={
                !bridge.routinesSaveText
                  ? 'This build cannot save a routine — the channel is not wired.'
                  : null
              }
              /*
               * The one editor on this pane whose edit is live, and it says so
               * rather than borrowing the "next start" sentence from the other
               * two. The engine reloads the folder as part of the save, so the
               * routine's *next* trigger uses the new file — this run, if one is
               * in flight, is already going and finishes on the old text.
               */
              effect="Saved changes are picked up straight away — the next time this routine fires, it fires on the new file."
              note={note}
              onSave={(next) => {
                setNote(null)
                act(`routine-save:${routine.id}`, async () => {
                  const result = toRoutineWrite(
                    await bridge.routinesSaveText?.(routine.id, next),
                  )
                  /*
                   * The refusal is the interesting half, and it is drawn in the
                   * error tone rather than beside "Saved" in the same quiet ink.
                   * A routine whose file no longer parses does not vanish — it
                   * stays listed and stops firing — so a person who missed the
                   * message would find out weeks later that an automation had
                   * silently stopped. The parser's own sentences come back
                   * verbatim; they name the missing line.
                   */
                  // The saved bytes are what is on disk — see the memory editor.
                  if (result.ok) setText(next)
                  setNote(
                    result.ok
                      ? { text: `Saved. ${routine.name} is running from the new file.`, ok: true }
                      : { text: result.problems.join(' '), ok: false },
                  )
                  return null
                })
              }}
            />
            <code className="settings-path" title={routine.file}>
              {routine.file}
            </code>
          </>
        )}

        {confirm && (
          <div className="settings-confirm">
            <span>Delete {routine.name}? Its file is removed from disk.</span>
            <Button
              tone="danger"
              disabled={busy !== null}
              onClick={() => {
                setConfirm(false)
                act(`routine-delete:${routine.id}`, async () => {
                  await bridge.routinesDelete?.(routine.id)
                  return `Deleted ${routine.name}.`
                })
              }}
            >
              Delete it
            </Button>
            <Button onClick={() => setConfirm(false)}>Cancel</Button>
          </div>
        )}

        {/* Both reasons, beside the routine they belong to. A switch and a
            button that cannot act have different causes — one is the file's own
            `enabled:` line, the other is a channel this build did not wire —
            and collapsing them into one sentence would mean guessing which. */}
        {switchBecause !== null && <span className="settings-help">{switchBecause}</span>}
        {runBecause !== null && <span className="settings-help">Run now: {runBecause}</span>}
      </span>

      <span className="settings-path-actions copilot-routine-actions">
        <Switch
          checked={armed}
          disabled={switchBecause !== null || busy !== null}
          onChange={(next) =>
            act(`routine-arm:${routine.id}`, async () => {
              if (next) {
                await bridge.routinesResume?.(routine.id)
                return `${routine.name} is armed again.`
              }
              await bridge.routinesPause?.(routine.id, 'Paused from Settings.')
              return `${routine.name} is paused. Its file is untouched.`
            })
          }
        />
        <Button onClick={toggle}>{open ? 'Close' : 'Edit'}</Button>
        <Button
          disabled={runBecause !== null || busy !== null}
          onClick={() =>
            act(`routine-run:${routine.id}`, async () => {
              const raw = await bridge.routinesRun?.(routine.id)
              const result = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
              return result.started === true
                ? `${routine.name} is running.`
                : typeof result.reason === 'string'
                  ? result.reason
                  : 'It did not start, and said nothing about why.'
            })
          }
        >
          Run now
        </Button>
        {/* Plain here, red in the confirmation — see the note on Forget. */}
        <Button disabled={!bridge.routinesDelete || busy !== null} onClick={() => setConfirm(true)}>
          Delete
        </Button>
      </span>
    </li>
  )
}

function RoutinesGroup({
  routines,
  bridge,
  act,
  busy,
  loading,
  onReveal,
}: Acts & { routines: RoutineRow[] | null }) {
  return (
    <Block
      title="Routines"
      says="Saved instructions the app runs on its own, kept where the copilot cannot reach them — and editable here, by you."
      more={`A routine is a trigger, a prompt and a folder, one file each, readable and editable by hand. They live in the app's own storage rather than in the copilot's folder, and the reason is not tidiness: the directory is the database, so a file dropped into it is a real automation that really runs — which would have made writing one a way around the confirmation a person is owed. The copilot may read that folder and, on macOS, cannot write it, so a routine can only be created or changed by you, here or in your own editor, or by a tool call you confirm. Editing one from this pane is that first door, not a new one for the copilot: writing the exact text of a routine file is wider than anything the copilot could ever be given a tool for, and it is marked in the code as reachable only from a window.`}
    >
      {routines === null ? (
        <p className="settings-prose">
          {loading ? 'Reading…' : 'This build cannot list routines — the channel is not wired.'}
        </p>
      ) : routines.length === 0 ? (
        <p className="settings-prose">
          There are none. A routine is a Markdown file in the folder below; the app arms whatever it
          finds there at launch.
        </p>
      ) : (
        <ul className="settings-paths">
          {routines.map((routine) => (
            <RoutineEntry
              key={routine.id}
              routine={routine}
              bridge={bridge}
              act={act}
              busy={busy}
            />
          ))}
        </ul>
      )}

      <div className="settings-actions">
        <Button onClick={() => onReveal('routines')} disabled={!bridge.copilotReveal}>
          Open the routines folder
        </Button>
      </div>
    </Block>
  )
}
