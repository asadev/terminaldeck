import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { BRAND } from '../../../shared/brand'
import { Button, Info, MoreBody, Notice, SectionHead, Switch, useMore } from '../controls'
import { errorText } from '../settings-bridge'
import {
  resolveCopilotBridge,
  toActionLog,
  toCopilotSignIn,
  toCopilotState,
  toMemoryDelete,
  toMemoryRead,
  toMemoryReport,
  toResetResult,
  toRevealMessage,
  toRoutineRows,
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
 *     "why did it say that" resolves to.
 *  3. **Its memory**, one file per fact, readable and deletable.
 *  4. **The action log** — every call, and who confirmed it.
 *  5. **What it can and cannot reach**, stated rather than left in a design doc.
 *  6. **Routines**, including the one the engine paused after failing.
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
  unavailable: 'Cannot run on this machine',
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
   * `unavailable` is the one that matters: this machine has no boundary the app
   * can prove, and `copilot-session.ts` refuses to start an unconfined agent
   * with the app's name on it rather than downgrading quietly. Saying "start is
   * greyed out" and nothing else would make that look like a bug.
   */
  const startBecause =
    !bridge.ensureCopilot
      ? 'This build cannot start it — the channel is not wired.'
      : status === 'unavailable'
        ? (state?.problem ??
          'This machine has no folder boundary this app can prove, and it will not run the copilot without one.')
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
      says={`It runs as an ordinary ${BRAND.name} session, in a folder of its own, under its own login.`}
      more={`Everything the app can already do to a session works on this one: it has a transcript you can read, an account chip, a working directory, and it appears in the usage pane. That is the whole reason it is a session rather than a chat backend — a bespoke agent would have had to re-implement all of that, and every piece of it would have been a black box.`}
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
                  ? `Started ${when(state.startedAt)}. Its confinement is ${
                      state.confinement.enforced ? 'enforced by the operating system' : 'not proven'
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
                : 'Pinned to a login of its own. It does not follow the account you are using in a project, so switching accounts for your own work never moves what the copilot answers as or what it spends against.'}
            </span>
            <code className="settings-path" title={state?.home}>
              {state?.home ?? '—'}
            </code>
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
                        ? 'It is signed out. Starting it opens its own login, in its own terminal.'
                        : 'Its login could not be determined from inside its boundary.'
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
              Its working directory, and the only place on this machine it may write.
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
        <Button onClick={() => onReveal('instructions')} disabled={!bridge.copilotReveal}>
          Show CLAUDE.md in Finder
        </Button>
      </div>
      {instructions !== 'missing' && (
        <p className="settings-help copilot-aside">
          Its files exist, so there is nothing to create. Editing them is yours to do.
        </p>
      )}

      <div className="copilot-instructions">
        <span className="settings-label">
          CLAUDE.md
          <span className={note.quiet ? 'settings-badge quiet' : 'settings-badge'}>{note.badge}</span>
        </span>
        <span className="settings-help">{note.says}</span>

        {resetBecause !== null ? (
          <span className="settings-help">{resetBecause}</span>
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
                act('reset', async () => {
                  const result = toResetResult(await bridge.copilotResetInstructions?.())
                  return result.error !== null
                    ? result.error
                    : result.backup === null
                      ? 'Restored.'
                      : `Restored. What was there is at ${result.backup}.`
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
  const [confirm, setConfirm] = useState<string | null>(null)

  const read = useCallback(
    (name: string) => {
      if (open === name) {
        setOpen(null)
        setText(null)
        return
      }
      setOpen(name)
      setText(null)
      if (!bridge.copilotMemoryRead) {
        setText('This build cannot read a memory file — the channel is not wired.')
        return
      }
      void bridge.copilotMemoryRead(name).then(
        (raw) => {
          const result = toMemoryRead(raw)
          setText(
            result.ok
              ? result.truncated
                ? `${result.text}\n\n… the rest of this file is longer than the pane will show.`
                : result.text
              : result.error,
          )
        },
        (cause: unknown) => setText(errorText(cause, 'That file could not be read.')),
      )
    },
    [bridge, open],
  )

  const facts = memory?.facts ?? []

  return (
    <Block
      title="Its memory"
      says="One file per fact, and every one of them is its own — never another session's."
      more={`Its memory is built from its conversation with you and nothing else. What it reads out of another session — a transcript, a diff, terminal output — is evidence it reports on, and its instructions forbid any of that from being written here, because memory is loaded at startup and a fact copied out of somebody else's agent would then be in its head in every future conversation. Credentials never go in either. You can read every file, and you can delete any of them.`}
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
                  <pre className="settings-code">{text ?? 'Reading…'}</pre>
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
                <Button onClick={() => read(fact.name)}>{open === fact.name ? 'Hide' : 'Read'}</Button>
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
      more={`It is append-only, one JSON object per line, and it is kept outside the copilot's own folder on purpose. That folder is the one directory on this machine the copilot may write to, so a log inside it could be appended to, edited, truncated or deleted by the thing it is a record of — and a record the audited party can compose is not a record. The app writes every line. The copilot's only way to add one is a log.note tool call, which is itself logged, so a row it wrote can never impersonate a row the app wrote.`}
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

/* ------------------------------------------------------------ 5. boundary -- */

function ReachGroup({ state }: { state: CopilotState | null }) {
  const projects = state?.projects
  const enforced = state?.confinement.enforced === true
  const kind = state?.confinement.kind ?? 'none'

  return (
    <Block
      title="What it can and cannot reach"
      says="A boundary the operating system holds, not a rule the copilot is asked to keep."
      more={`It runs inside the same folder confinement a session from a paired device runs inside, and it is not exempt because it is part of the app. On a machine where that boundary cannot be proven, the app refuses to start it rather than running an unconfined agent with its name on it. The lists below are read from the plan the app would actually apply, not from a document.`}
    >
      <ul className="settings-paths">
        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Writes
              <span className="settings-badge quiet">{kind === 'none' ? 'unconfined' : kind}</span>
            </span>
            <span className="settings-help">
              Its own folder and its own home directory — its login, its caches, its transcripts.
              Nothing else on this machine, including everywhere below.
            </span>
            {state && (
              <span className="settings-help">
                {enforced
                  ? 'The running process is inside a proven boundary.'
                  : state.status === 'running'
                    ? 'The running process is NOT inside a proven boundary.'
                    : 'Nothing is running, so nothing is granted right now.'}
              </span>
            )}
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">Reads, and can never write</span>
            <span className="settings-help">
              The projects you have added to {BRAND.name}, and the operating system and its installed
              tools. Reading your code is what lets it look at the failing test instead of asking you
              to paste it; changing a line of it is a session’s job, behind something you confirm.
            </span>
            {projects && !projects.enforceable && (
              <span className="settings-help">
                {projects.reason ??
                  'This platform cannot hold a read-only project grant, so it is given nothing rather than something that looks like it.'}
              </span>
            )}
            {projects && projects.granted.length > 0 && (
              <ul className="copilot-plain">
                {projects.granted.map((path) => (
                  <li key={path}>
                    <code className="settings-path">{path}</code>
                  </li>
                ))}
              </ul>
            )}
            {projects && projects.granted.length === 0 && projects.available.length > 0 && (
              <span className="settings-help">
                Nothing is granted right now because nothing is running. A start would grant{' '}
                {projects.available.length}{' '}
                {projects.available.length === 1 ? 'project' : 'projects'}.
              </span>
            )}
            {projects && projects.enforceable && projects.available.length === 0 && (
              /*
                The empty case, said out loud.
                The paragraph above promises "the projects you have added", and
                on a machine with none the block would otherwise show that
                sentence over nothing at all — which reads as a list that failed
                to load rather than as a person who has not added a project.
              */
              <span className="settings-help">
                You have not added any projects yet, so there is nothing here for it to read.
              </span>
            )}
            {projects && projects.pending.length > 0 && (
              <span className="settings-help">
                {projects.pending.length}{' '}
                {projects.pending.length === 1 ? 'project was' : 'projects were'} added since it
                started. A sandbox cannot be widened once a process is inside it, so those become
                readable after a stop and a start — not before.
              </span>
            )}
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">Refused, even inside a folder it can read</span>
            <span className="settings-help">
              Credential-shaped files are carved back out by the same profile, so a project it can
              read is not a project whose secrets it can read. These are the kinds it refuses —
              each one is a rule in the generated profile rather than a single filename:
            </span>
            {projects && projects.excluded.length > 0 && (
              <span className="copilot-chips">
                {/*
                  Not `<code>`, and not monospace.

                  What the main process sends is `SECRET_SHAPES[].name` — the
                  *kind* of thing refused (`dotenv`, `ssh-private-key`), not the
                  pattern. Set in a code face these read as literal filenames,
                  which would be the pane quietly claiming that a file called
                  `dotenv` is what gets refused. Measured against the real app,
                  where the list comes back as eleven kind names.
                */}
                {projects.excluded.map((shape) => (
                  <span className="copilot-chip" key={shape}>
                    {shape}
                  </span>
                ))}
              </span>
            )}
            <span className="settings-help">
              It is a list of shapes rather than a guarantee: a password sitting in an ordinary
              config file is readable, because nothing can recognise it.
            </span>
          </span>
        </li>

        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">Cannot reach at all</span>
            <span className="settings-help">
              Your home directory, your SSH keys, your git and GitHub credentials, your keychain and
              therefore every other login on this machine, any folder you have not added as a
              project, and {BRAND.name}’s own storage — its settings, its database, its saved
              routines, its own action log, and the transcripts of your other sessions as files on
              disk.
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
       */
      `${routine.reason ?? 'It is off in its own file.'} Change it there — the app will not edit a file you wrote.`
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
            <pre className="settings-code">{routine.prompt || '(no prompt)'}</pre>
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
        <Button onClick={() => setOpen((was) => !was)}>{open ? 'Hide' : 'Inspect'}</Button>
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
      says="Saved instructions the app runs on its own, kept where the copilot cannot reach them."
      more={`A routine is a trigger, a prompt and a folder, one file each, readable and editable by hand. They live in the app's own storage rather than in the copilot's folder, and the reason is not tidiness: the directory is the database, so a file dropped into it is a real automation that really runs — which would have made writing one a way around the confirmation a person is owed. The copilot has no read or write access to that folder at all, so a routine can only be created by you or by a tool call you confirm.`}
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
