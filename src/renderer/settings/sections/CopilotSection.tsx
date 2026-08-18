import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { BRAND } from '../../../shared/brand'
import { Button, Notice, Row, SectionHead, Switch } from '../controls'
import { HoverNote } from '../../components/HoverNote'
import { errorText } from '../settings-bridge'
import { CHOOSING_A_FOLDER, FOLDER_NEEDS_A_RESTART } from '../../../shared/copilot-text'
import { FileEditor, ReadOnlyFile } from './CopilotEditor'
import { useCopilotSetup, type CopilotSetup } from '../../copilot/useCopilotSetup'
import { DEFAULT_COPILOT_NAME } from '../../../shared/copilot-identity'
import {
  resolveCopilotBridge,
  INTERACTIVE_SETTING,
  toActionLog,
  toCopilotSignIn,
  toInteractiveDriving,
  toCopilotState,
  toFolderChange,
  toInstructionsRead,
  toLayerRead,
  toInstructionsWrite,
  toMemoryReport,
  toResetResult,
  toRevealMessage,
  toRoutineRows,
  toRoutineText,
  toRoutineWrite,
  toScaffoldResult,
  type ActionLogReport,
  type CopilotBridge,
  type CopilotFolder,
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
 * ## Five things, in the order somebody actually asks about them
 *
 *  1. **Its session.** Is it running, whose account is it, and can I stop it.
 *  2. **Its files** — everything it reads before it answers, each with the one
 *     button that acts on it. That is what "why did it say that" resolves to.
 *  3. **The action log** — every call, and who confirmed it. Read-only, and
 *     behind a View button rather than spread across the pane.
 *  4. **What it can and cannot reach**, stated rather than left in a design doc.
 *  5. **Routines**, including the one the engine paused after failing — each
 *     one's file editable in place.
 *
 * ## The 2026-08-17 pass, and what it took off this screen
 *
 * This pane was a listing before it was a control panel:
 *
 *   > *"Every file needs an Edit button beside it, opening the same editor style
 *   > already used, and saving. So they can actually control and fix and design
 *   > their copilot from here directly."*
 *   > *"Memory is the exception — do not list dated files. One Open folder
 *   > button… They don't need to edit memories. They need to edit the character,
 *   > identity and that related stuff only."*
 *   > *"The action log should not be listed either — a View button."*
 *   > *"This is busy for nothing, for no sensible reason."*
 *
 * Four blocks became two. "What it reads at startup" listed every file the
 * session loads, one row per memory, each with its absolute path; "Its memory"
 * then listed the same files again with an editor and a Forget on each; the
 * action log printed twelve three-line rows on open; and "Reading pace" set the
 * speed of a driving mode that has since been rebuilt around a machine-speed
 * scan, so it controlled nothing. The pane measured 4,946 pixels tall. It is now
 * 2,656, every row has exactly one button, and no path is on screen except the
 * one row whose subject *is* a path — the folder the copilot works in.
 *
 * The ⓘ went with it, from a disclosure that grew the page to a popup that does
 * not: {@link HoverNote}, and `Block` below carries the argument.
 *
 * ## What is editable here, and what never will be
 *
 * Asad, 2026-08-17: *"none of them is clickable or editable … I should be able
 * to click and make changes and click save."* Two files get a box and a Save,
 * through the one {@link FileEditor} in `CopilotEditor.tsx`: the copilot's own
 * instructions, and any routine. Two more get a read-only box, in full, because
 * they are generated from what is wired and a hand-edited copy would stop
 * matching it. Nothing is hidden — the founding argument for this feature was
 * *"so we can see and learn how our copilot is working"* — and nothing pretends
 * to be editable that is not.
 *
 * **The action log stays read-only, and that is not an omission.** It is the
 * record of what the copilot did, and the pane's own paragraph about it says the
 * audited party cannot compose it. A pane that let a *person* edit it would not
 * break that claim in the same way — a person is not the audited party — but it
 * would destroy what the file is for, which is being the one artefact a person
 * can check a claim against. There is no Save under it and there is no channel
 * behind one.
 *
 * **Memory is read-only here too, and that is his instruction rather than a
 * limitation.** It grows daily and it is the copilot's own record of what it
 * learned; the files worth a person's attention are the identity ones. One
 * button opens the folder, and everything in it is still readable and prunable
 * there.
 *
 * ## When an edit takes effect, said out loud under each box
 *
 * The two differ and the difference matters, so no editor here is allowed to be
 * quiet about it:
 *
 *  - **Its instructions** — at the copilot's *next start*. The CLI is handed the
 *    file as the session spawns and never again, so a save while it is running
 *    changes nothing about the conversation on screen. The editor says so and
 *    offers Restart when it is running, which is a stop and a start and is the
 *    only honest version of "apply".
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

/**
 * @param setUpCopilot ask the app to run the setup questions again. Absent in a
 *   panel rendered without a host — see `SectionProps.setUpCopilot` for why the
 *   flow cannot be opened from inside this sheet.
 */
export function CopilotSection({ setUpCopilot }: { setUpCopilot?(): void } = {}) {
  const bridge = useMemo<Partial<CopilotBridge>>(() => resolveCopilotBridge(), [])
  /*
   * What it is called, read out of the same instruction file this pane edits
   * further down.
   *
   * The hook rather than a fourth parse in this file: `useCopilotSetup` is what
   * the sidebar row and the tab pill read the name through, and a pane that
   * parsed it a second way could print a different name from the rail six
   * centimetres to its left.
   */
  const setup = useCopilotSetup()

  const [state, setState] = useState<CopilotState | null>(null)
  const [signIn, setSignIn] = useState<CopilotSignIn | null>(null)
  const [memory, setMemory] = useState<MemoryReport | null>(null)
  const [actions, setActions] = useState<ActionLogReport | null>(null)
  const [routines, setRoutines] = useState<RoutineRow[] | null>(null)
  /**
   * Whether the scan is put on the screen. See {@link ShowingGroup}.
   *
   * `null` until the settings file has answered, so the switch is drawn disabled
   * for that instant rather than drawn *on* — the documented default — and then
   * moving under somebody's eyes if their answer was off. A control that flips
   * itself a beat after it appears reads as a control that did not take.
   */
  const [interactive, setInteractive] = useState<boolean | null>(null)
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
    if (bridge.getSettings) {
      jobs.push(
        bridge.getSettings().then(
          (raw) => fresh(toInteractiveDriving(raw), setInteractive),
          // Left null, so the row draws disabled and says the file could not be
          // read rather than showing a switch in a position nobody chose.
          () => fresh(null, setInteractive),
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
        setup={setup}
        {...(setUpCopilot ? { setUpCopilot } : {})}
      />

      {/*
        One block where there were two. "What it reads at startup" listed every
        file including each memory, and "Its memory" then listed the memories
        again with an editor on each — so a copilot that had been running a while
        showed the same dated filenames twice, once as paths and once as boxes.
        `FilesGroup` carries the argument.
      */}
      <FilesGroup
        state={state}
        memory={memory}
        busy={busy}
        bridge={bridge}
        act={act}
        onReveal={reveal}
      />

      <ShowingGroup
        interactive={interactive}
        bridge={bridge}
        onChange={setInteractive}
        onProblem={setProblem}
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

/*
 * The "Reading pace" block used to sit here, and it is gone with the thing it
 * controlled.
 *
 * It set how long a driving-mode tour waited on each stop, computed from the
 * word count so every option could say how long a real paragraph would take.
 * That whole model was built for a read-along, and the read-along is what the
 * 2026-08-17 review replaced:
 *
 *   > *"Currently it stays for us to read. Let's not make it for us to read… it
 *   > is scanning everything very fast and we can see like a machine is
 *   > working."*
 *
 * `estimate.ts`, `reading-speed.ts` and `PaceControls.tsx` were deleted with the
 * rebuild, so this block's imports no longer resolve — but the reason it is not
 * being re-pointed at whatever replaces them is the other rule this pass is
 * held to: **a control that cannot act is removed, not disabled.** There is no
 * pace to set in a scan that runs at machine speed.
 *
 * The tour recap that rode along inside it went too. Its real home is beside the
 * conversation that produced it, which is where `TourRecap` is still mounted; a
 * second copy in Settings was the one that would drift, and this pane is being
 * cut down rather than added to.
 */

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
 * ## The ⓘ is a popup now, and that is the instruction
 *
 * Asad, 2026-08-17: *"the ⓘ dot shows its detail **on hover, as a popup** — not
 * by expanding the pane downward."*
 *
 * This used to be the settings window's own expanding ⓘ, which is a disclosure: the
 * paragraph was inserted into the flow under the heading. That is the right
 * pattern for a settings row and the wrong one for a pane with six of them —
 * every press moved everything below it, so reading the second explanation put
 * the third somewhere else, on a pane that was already a screen and a half long.
 * {@link HoverNote} costs nothing below it: open it, read it, move on, and the
 * page has not shifted a pixel.
 *
 * The rhythm the flat sheet groups by is preserved: 40 above the heading, 8
 * below it, 8 to the list, against 20 between two entries — so a heading is
 * always nearer what it names than what it names is to itself.
 *
 * All the blocks go through this, because a hand-written copy of a heading and a
 * paragraph is one more chance to drift into a different shape.
 */
function Block({
  title,
  says,
  more,
  children,
}: {
  title: string
  says: string
  /** The rest of the explanation, behind the ⓘ, shown as a popup on hover. */
  more?: string
  children: ReactNode
}) {
  return (
    <section className="settings-group">
      <h4 className="settings-group-title">
        <span className="settings-label-line">
          {title}
          {more && <HoverNote label={title}>{more}</HoverNote>}
        </span>
      </h4>
      <p className="settings-explain-body copilot-says">{says}</p>
      {children}
    </section>
  )
}

/*
 * `PathLine` — a path with its own Open button — used to live here, and it is
 * gone with its last caller.
 *
 * It put a second button inside the row's *text* column while the row's real
 * controls sat in the actions column to the right, so the copilot's folder row
 * drew "Open" one line below and two hundred pixels left of "Choose a folder…".
 * Two buttons for one row on two different axes reads as a mistake, because it
 * is one. The path is a plain `<code>` line now and both buttons are where every
 * other row on this pane keeps them.
 */

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
  setup,
  setUpCopilot,
}: Acts & {
  state: CopilotState | null
  signIn: CopilotSignIn | null
  onSignIn(next: CopilotSignIn | null): void
  setup: CopilotSetup
  setUpCopilot?(): void
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
      more={
        'It is a real session, so everything the app can already do to one works on it: a ' +
        'transcript you can read, an account, a working directory, a line in the usage pane. ' +
        'That is why it is a session rather than a chat box built into this app.'
      }
    >
      <ul className="settings-paths">
        {/*
          What it is called, and the way back to the questions that named it.

          First in the list because it is the first thing about it a person
          knows, and because the row has to be where the answer to "how do I
          rename this" is looked for.

          The name is not a setting and there is no box for it here: it lives in
          a sentence in the copilot's own instruction file — the one this pane
          puts in an editable box further down — so it can be changed in either
          place and there is only ever one copy of it. `shared/copilot-identity.ts`
          carries that argument in full.
        */}
        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Its name
              <span
                className={setup.identity.name === null ? 'settings-badge quiet' : 'settings-badge'}
              >
                {setup.identity.name === null ? 'not named' : 'yours'}
              </span>
            </span>
            {/*
              One line where there were two, and the mechanism moved behind the
              dot. It used to say what the copilot is called, then what it calls
              you, then a third clause naming the heading inside the instruction
              file to edit — which is a sentence for somebody who has already
              opened that file, on the row of somebody who has not.
            */}
            <span className="settings-help">
              {setup.identity.name === null
                ? `Nobody has named it, so this app calls it the ${DEFAULT_COPILOT_NAME}.`
                : `It is called ${setup.identity.name}.`}
              {setup.identity.callThem === null
                ? ' It has not been told what to call you.'
                : ` It calls you ${setup.identity.callThem}.`}
              <HoverNote label="its name">
                {'The name is not a setting — it is a sentence in the copilot’s own instructions, ' +
                  'which is why there is one copy of it and not two. Running these questions again ' +
                  'rewrites that sentence, and so does editing it yourself under Its files.'}
              </HoverNote>
            </span>
            {setUpCopilot === undefined && (
              <span className="settings-help">
                Set up again: this window was opened without the app behind it, so the questions
                cannot be shown from here.
              </span>
            )}
          </span>
          <span className="settings-path-actions">
            <Button disabled={setUpCopilot === undefined} onClick={() => setUpCopilot?.()}>
              {setup.status === 'unset' ? 'Set it up…' : 'Set it up again…'}
            </Button>
          </span>
        </li>

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

        <FolderRow
          state={state}
          bridge={bridge}
          act={act}
          busy={busy}
          loading={loading}
          onReveal={onReveal}
        />
      </ul>
    </Block>
  )
}

/**
 * Which folder it works in, and the two things a person can do about it.
 *
 * Asad, 2026-08-17: *"What if we want our copilot to have a folder of our
 * choice? … if I point it to your folder, it means everything inside will start
 * from where we left off here."* Choosing an assistant workspace they already
 * built is the case this exists for, and it works because the copilot is a real
 * session: the CLI reads that folder's own `CLAUDE.md` and memory the ordinary
 * way, with nothing in this app that knows what an assistant is.
 *
 * Three sentences this row is not allowed to stop saying:
 *
 *  - **Nothing of this app's is written into a chosen folder.** Not
 *    instructions, not `memory/`, not a marker. It is the promise the whole
 *    design turns on, and it is stated where the choice is made rather than
 *    somewhere in a document.
 *  - **What choosing means for what it can read.** {@link CHOOSING_A_FOLDER},
 *    the same string the native panel carries, because a folder may hold
 *    credentials and that should be chosen rather than discovered. There is no
 *    scanner behind it and there is not going to be one — see that constant.
 *  - **It takes a restart.** A working directory is fixed at `exec`. The row
 *    reports where the *running* copilot actually is, separately from where the
 *    next one will start, because those differ for as long as somebody has not
 *    restarted and a pane that showed only the setting would be lying about a
 *    live process.
 */
function FolderRow({
  state,
  bridge,
  act,
  busy,
  loading,
  onReveal,
}: Acts & { state: CopilotState | null }) {
  const folder: CopilotFolder | null = state?.folder ?? null
  const chosen = folder !== null && !folder.isDefault
  const pickBecause = !bridge.copilotPickFolder
    ? 'This build cannot change it — the channel is not wired.'
    : null

  return (
    <li className="settings-path-row">
      <span className="settings-path-main">
        <span className="settings-label">
          Its folder
          {folder && (
            <span className={chosen ? 'settings-badge' : 'settings-badge quiet'}>
              {chosen ? 'yours' : 'this app’s'}
            </span>
          )}
        </span>
        <span className="settings-help">
          {/*
            "That folder's own instructions" rather than a filename, and the
            same words the setup flow and `shared/copilot-text.ts` use. Which
            file gets read out of a folder is the agent's own convention and
            differs between the three this build ships, so a filename here was
            a guess dressed up as a fact — on the row whose entire job is to say
            what the copilot can see.
          */}
          {chosen
            ? 'You pointed it at a folder of your own. It reads that folder’s own instructions and its memory the same way any session you start there would — and this app writes nothing into it.'
            : 'A folder this app made for it. Point it at one of your own and it picks up whatever assistant already lives there.'}
          {/*
            What choosing a folder costs, behind the dot rather than standing
            under the button as a four-sentence paragraph.

            It is a warning and it is not being dropped — a chosen folder may
            hold credentials, and that is a thing to be chosen rather than
            discovered. But it was the longest single paragraph on this pane and
            it was permanently on screen, including for the ninety per cent of
            people who have never changed the folder and never will. Same string,
            one hover away, still {@link CHOOSING_A_FOLDER}.
          */}
          <HoverNote label="choosing a folder">{CHOOSING_A_FOLDER}</HoverNote>
        </span>
        <code className="settings-path" title={folder?.home ?? state?.paths.root ?? '—'}>
          {folder?.home ?? state?.paths.root ?? '—'}
        </code>

        {folder?.problem && (
          <Notice tone="warn">
            {folder.chosen ? `${folder.chosen} — ` : ''}
            {folder.problem} It is running in {folder.home} instead.
          </Notice>
        )}

        {folder?.restartNeeded && (
          <Notice tone="info">
            The copilot running now is still working in {folder.runningIn}. {FOLDER_NEEDS_A_RESTART}
          </Notice>
        )}

        {pickBecause !== null && <span className="settings-help">Choose: {pickBecause}</span>}
      </span>
      <span className="settings-path-actions">
        <Button onClick={() => onReveal('root')} disabled={!bridge.copilotReveal}>
          Open
        </Button>
        <Button
          disabled={pickBecause !== null || busy !== null || loading}
          onClick={() =>
            act('folder-pick', async () => {
              const result = toFolderChange(await bridge.copilotPickFolder?.())
              if (result.cancelled) return null
              if (result.problem !== null) return result.problem
              return result.folder === null
                ? 'The folder could not be changed.'
                : `The copilot will start in ${result.folder.home}. ${FOLDER_NEEDS_A_RESTART}`
            })
          }
        >
          {busy === 'folder-pick' ? 'Choosing…' : 'Choose a folder…'}
        </Button>
        {chosen && (
          <Button
            disabled={!bridge.copilotClearFolder || busy !== null}
            onClick={() =>
              act('folder-clear', async () => {
                const result = toFolderChange(await bridge.copilotClearFolder?.())
                return result.folder === null
                  ? 'That did not work.'
                  : `Back to ${result.folder.home}. Nothing was moved out of the folder you had chosen. ${FOLDER_NEEDS_A_RESTART}`
              })
            }
          >
            Use this app’s folder
          </Button>
        )}
      </span>
    </li>
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

/**
 * One file on the pane: what it is, what state it is in, and **one button that
 * acts on it**.
 *
 * Asad, 2026-08-17, looking at what this block used to be — an ordered list of
 * absolute paths with no controls on any of them:
 *
 *   > *"Every file needs an Edit button beside it, opening the same editor style
 *   > already used, and saving. So they can actually control and fix and design
 *   > their copilot from here directly."*
 *   > *"This is busy for nothing, for no sensible reason."*
 *
 * Both halves are this component. The path is gone from the row — it is a
 * settings pane for people who are, in his words, *"mostly non-technical vibe
 * coders"*, and `/Users/…/Library/Application Support/terminaldeck/copilot-layer/instructions.md`
 * answers no question any of them are asking — and in its place is the button
 * that opens the file.
 *
 * **The verb is the truth about the file.** Edit for the two files a person owns
 * and this app can write; View for the two it generates, which are shown in full
 * and cannot be edited because they are descriptions of what is wired rather
 * than opinions; Open for the folder's own instructions, which live on the
 * person's disk in a folder this app has promised never to write into. A row
 * whose verb outran what the app can do would be the fake control this whole
 * review was about.
 */
function FileRow({
  label,
  badges,
  says,
  action,
  onAction,
  disabledBecause,
  children,
}: {
  label: string
  /** Short state words: whose it is, whether it is current, whether it exists. */
  badges: Array<{ text: string; quiet?: boolean }>
  /** One line about what the file is for. Never a path. */
  says: string
  /** What the button says right now — `Edit`/`Close`, `View`/`Close`, `Open`. */
  action: string
  onAction(): void
  /** Why the button cannot act, or null. Rendered beside it, never swallowed. */
  disabledBecause?: string | null
  /** The editor or viewer this row opens, when it is open. */
  children?: ReactNode
}) {
  return (
    <li className="settings-path-row">
      <span className="settings-path-main">
        <span className="settings-label">
          {label}
          {badges.map((badge) => (
            <span key={badge.text} className={badge.quiet === false ? 'settings-badge' : 'settings-badge quiet'}>
              {badge.text}
            </span>
          ))}
        </span>
        <span className="settings-help">{says}</span>
        {disabledBecause != null && <span className="settings-help">{action}: {disabledBecause}</span>}
        {children}
      </span>
      <span className="settings-path-actions">
        <Button disabled={disabledBecause != null} onClick={onAction}>
          {action}
        </Button>
      </span>
    </li>
  )
}

/**
 * Read a file when its box is opened, and not before.
 *
 * The pane used to read the instruction file and the tool contract on every
 * mount, because both boxes were always on screen. Now that they are behind
 * buttons, the read belongs to the opening — which also means a pane opened to
 * check whether the copilot is running costs two IPC calls instead of four.
 *
 * `key` re-reads when what is on disk changed underneath an open box: a Restore
 * rewrites the file from a control in this same block, and a box still holding
 * the pre-restore text would put it straight back the next time Save was
 * pressed.
 */
function useFileText(
  read: (() => Promise<unknown>) | undefined,
  parse: (raw: unknown) => { text: string | null; error: string | null },
  key: string,
  open: boolean,
  unwired: string,
): {
  text: string | null
  problem: string | null
  /** Set after a save, because the bytes just written *are* the bytes on disk. */
  accept(next: string): void
} {
  const [text, setText] = useState<string | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const readKey = useRef<string | null>(null)

  useEffect(() => {
    if (!open) {
      // Dropped on close, so re-opening re-reads rather than showing a snapshot
      // from before somebody edited the file in their own editor.
      readKey.current = null
      return
    }
    if (!read) {
      setText(null)
      setProblem(unwired)
      return
    }
    if (readKey.current === key) return
    readKey.current = key
    void read().then(
      (raw) => {
        const result = parse(raw)
        setText(result.text)
        setProblem(result.error)
      },
      (cause: unknown) => {
        setText(null)
        setProblem(errorText(cause, 'That file could not be read.'))
      },
    )
  }, [read, parse, key, open, unwired])

  return { text, problem, accept: setText }
}

/** `toInstructionsRead`'s union, in the shape {@link useFileText} wants. */
function readInstructions(raw: unknown): { text: string | null; error: string | null } {
  const result = toInstructionsRead(raw)
  return result.ok ? { text: result.text, error: null } : { text: null, error: result.error }
}

function readLayer(raw: unknown): { text: string | null; error: string | null } {
  const result = toLayerRead(raw)
  return { text: result.text, error: result.error }
}

/**
 * Everything the copilot reads, as a control panel rather than a file listing.
 *
 * ## What this replaced, and why the memory list is not in it
 *
 * It used to be an ordered list of every file the session loads — the composed
 * layer, the folder's own instructions, the memory index, and then **one row per
 * memory file**, each with its full absolute path — followed by a second block
 * that listed the same memory files again, each with its own Edit and Forget.
 * On a copilot that had been running a while that is a screen of dated
 * filenames, which is exactly what he said to stop:
 *
 *   > *"Memory is the exception — do not list dated files. One Open folder
 *   > button. Memory grows daily; the identity files do not."*
 *   > *"They don't need to edit memories. They need to edit the character,
 *   > identity and that related stuff only."*
 *
 * So memory is one row with a count and one button. The claim the pane has
 * always made about it — that what it remembers is its own conversation and
 * never another session's, and that this is a rule in its instructions rather
 * than something the machine refuses — moved onto that row's own ⓘ, because it
 * is a true and load-bearing thing to say and it is not worth a paragraph on
 * screen.
 *
 * What is left is five rows, and every one of them has a button that does
 * something. The verb is the truth about the file, which is the other half of
 * the same instruction — *"a control that cannot act is removed or disabled with
 * a reason"*:
 *
 *  - **Edit** — its instructions, the one file here that is a person's own and
 *    that this app writes. The box saves, and says when the save takes effect.
 *  - **View** — the tool list and the composed text. Shown in full, and
 *    read-only on purpose: both are generated from what is wired, so a
 *    hand-edited copy would stop matching the thing it describes.
 *  - **Show** — the folder's own instructions, which live on somebody else's
 *    disk in a directory this app has promised never to write into.
 *  - **Open the folder** — memory, which grows on its own.
 */
function FilesGroup({
  state,
  memory,
  bridge,
  act,
  busy,
  onReveal,
}: Omit<Acts, 'loading'> & { state: CopilotState | null; memory: MemoryReport | null }) {
  const [confirm, setConfirm] = useState(false)
  /** Which of the three boxes is open. One at a time — see the note on Edit. */
  const [open, setOpen] = useState<'yours' | 'contract' | 'composed' | null>(null)
  const [saveNote, setSaveNote] = useState<{ text: string; ok: boolean } | null>(null)

  const instructions = state?.instructions ?? 'missing'
  const note = INSTRUCTIONS[instructions]
  const running = state?.status === 'running'
  const layerFiles = state?.layerFiles ?? []
  const yoursFile = layerFiles.find((file) => file.owner === 'yours') ?? null
  const contractFile = layerFiles.find((file) => file.path.endsWith('tools.md')) ?? null
  const composedFile = layerFiles.find((file) => file.path.endsWith('copilot.md')) ?? null

  /*
   * The person's own instructions file in the working directory, picked out of
   * the startup list by elimination rather than by filename.
   *
   * `copilotStartupFiles` labels the memory entries `Memory` and `Memory index`
   * and everything else in that folder is the one file the CLI discovers from
   * the working directory. Matching on the filename instead would mean naming
   * one agent's convention on a screen that must not name any — the three CLIs
   * this build can run each look for a different file.
   */
  const folderFile =
    (state?.startupFiles ?? []).find(
      (file) => file.owner === 'folder' && file.purpose !== 'Memory' && file.purpose !== 'Memory index',
    ) ?? null

  const yours = useFileText(
    bridge.copilotReadInstructions,
    readInstructions,
    `${instructions}:${yoursFile?.modifiedAt ?? 0}`,
    open === 'yours',
    'This build cannot read its instructions — the channel is not wired.',
  )
  const contract = useFileText(
    bridge.copilotReadContract,
    readLayer,
    `${contractFile?.modifiedAt ?? 0}`,
    open === 'contract',
    'This build cannot read it — the channel is not wired.',
  )
  const composed = useFileText(
    bridge.copilotReadComposed,
    readLayer,
    `${composedFile?.modifiedAt ?? 0}`,
    open === 'composed',
    'This build cannot read it — the channel is not wired.',
  )

  const saveBecause = !bridge.copilotWriteInstructions
    ? 'This build cannot save it — the channel is not wired.'
    : null

  const resetBecause = !bridge.copilotResetInstructions
    ? 'This build cannot restore it — the channel is not wired.'
    : instructions === 'current'
      ? 'It already matches this build.'
      : instructions === 'missing'
        ? 'There is no file yet. Create its files instead.'
        : null

  const toggle = (which: 'yours' | 'contract' | 'composed') => () => {
    // One box at a time. Three textareas open at once is the wall of text this
    // pass exists to remove, and the note under a box belongs to that box.
    setSaveNote(null)
    setOpen((was) => (was === which ? null : which))
  }

  const facts = memory?.facts.length ?? 0

  return (
    <Block
      title="Its files"
      says="What it reads before it answers anything — and what you can change."
      more={
        'This is the answer to “why did it say that”. The list is read off the disk every time ' +
        'this pane opens rather than remembered, so an edit you just made — here or in your own ' +
        'editor — shows up straight away.'
      }
    >
      {/*
        The rows are drawn before anything has been read, not after.

        A single "Reading…" in place of the whole list was the first version, and
        it is the wrong trade twice over: the structure of this block is the
        answer to *"what does my copilot read"*, which does not change while a
        read is in flight, and a pane that shows nothing for a beat and then five
        rows moves everything under it. Each row says what state it is in
        instead — a badge reading `not read`, a box saying `Reading…` when it is
        opened — which is the same rule the rest of this pane follows.
      */}
      <ul className="settings-paths">
          {/*
            Its own instructions, first, and the only editor on this pane that
            changes what the copilot *is*. Everything else here describes.
          */}
          <FileRow
            label="Its instructions"
            badges={[
              { text: 'yours', quiet: false },
              { text: note.badge, quiet: note.quiet },
            ]}
            says={note.says}
            action={open === 'yours' ? 'Close' : 'Edit'}
            onAction={toggle('yours')}
          >
            {open === 'yours' && (
              <>
                <FileEditor
                  label={baseName(yoursFile?.path ?? 'instructions.md')}
                  text={yours.text}
                  problem={yours.problem}
                  rows={18}
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
                        // The saved bytes are what is on disk, so the box goes
                        // clean at once rather than waiting for the re-read the
                        // mtime triggers. Without this the box stayed dirty
                        // after a successful save — Save still blue, the line
                        // still reading "Unsaved." — which makes somebody press
                        // Save twice and then doubt the first press.
                        yours.accept(next)
                        const where = result.backup === null ? '' : ` What was there is at ${result.backup}.`
                        setSaveNote({
                          text: running
                            ? `Saved.${where} The running copilot still has the old text — restart it to apply this.`
                            : `Saved.${where} It applies the next time the copilot starts.`,
                          ok: true,
                        })
                      }
                      // Nothing for the pane-level notice: the sentence is under
                      // the box that produced it.
                      return null
                    })
                  }}
                >
                  {/*
                    Restart, beside Save, and only while something is running.
                    "It applies at the next start" is a true sentence that leaves
                    somebody with a job to do, and the job is two clicks on the
                    other side of this pane. Stop-then-start rather than a
                    reload, because there is no reload: the CLI is handed its
                    instructions as it spawns.
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
                           * The restart's own result replaces the save's, in the
                           * same place, because they are the two halves of one
                           * sentence: the save says "the running copilot still
                           * has the old text" and this is the answer to it.
                           */
                          setSaveNote(
                            next?.status === 'running'
                              ? { text: 'Restarted. It has read the current instructions.', ok: true }
                              : { text: next?.problem ?? 'It stopped, and did not come back up.', ok: false },
                          )
                          return null
                        })
                      }}
                    >
                      {busy === 'restart' ? 'Restarting…' : 'Restart it'}
                    </Button>
                  )}
                  <Button onClick={() => onReveal('instructions')} disabled={!bridge.copilotReveal}>
                    Show the file
                  </Button>
                </FileEditor>

                {/*
                  The way back to the shipped wording, inside the editor's own
                  disclosure rather than standing under the row. It is still a
                  confirmation rather than another Save: the editor above never
                  replaces anything without somebody having read what is in the
                  box first, and this one puts *this build's* text over whatever
                  is there. A copy is kept either way, and the note after it
                  prints where.
                */}
                {resetBecause !== null ? (
                  <span className="settings-help">Restore: {resetBecause}</span>
                ) : confirm ? (
                  <div className="settings-confirm">
                    <span>
                      {instructions === 'edited'
                        ? 'Replace your version with the one this build ships? A copy of yours is kept beside it.'
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
                          setSaveNote(
                            result.error !== null
                              ? { text: result.error, ok: false }
                              : {
                                  text:
                                    result.backup === null
                                      ? 'Restored. The box above is this build’s wording again.'
                                      : `Restored. What was there is at ${result.backup}.`,
                                  ok: true,
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
              </>
            )}
          </FileRow>

          {/*
            The generated half: shown in full, and not editable.

            Hiding it would contradict the reason this whole pane exists — *"so
            we can see and learn how our copilot is working"* — and editing it
            would be worse than hiding it. It is composed from the live tool
            catalogue, the tier each tool declares and the paths this machine
            really refuses, every time the copilot starts. Hand-edit it and it
            stops matching the thing it describes, which is this project's stated
            bug class and a defect this feature has already shipped twice: an
            instruction file claiming a jail that had been removed, and one
            denying powers the copilot had.
          */}
          <FileRow
            label="Its tool list"
            badges={[{ text: 'the app’s' }, { text: 'generated' }]}
            says="What it may do, written fresh from the tools that are actually wired every time it starts."
            action={open === 'contract' ? 'Close' : 'View'}
            onAction={toggle('contract')}
          >
            {open === 'contract' && (
              <ReadOnlyFile
                label={baseName(contractFile?.path ?? 'tools.md')}
                text={contract.text}
                problem={contract.problem}
                rows={16}
                because={
                  'This one is not editable, because it is a description of what is wired rather ' +
                  'than an opinion: hand-edit the tool list and it stops matching the tools that ' +
                  'exist, which is how an assistant ends up refusing work it can do. To change ' +
                  'what it says, change the thing it describes. To change how it behaves, edit ' +
                  'its instructions above.'
                }
              >
                <Button onClick={() => onReveal('contract')} disabled={!bridge.copilotReveal}>
                  Show the file
                </Button>
              </ReadOnlyFile>
            )}
          </FileRow>

          <FileRow
            label="What it was handed"
            badges={[{ text: 'the app’s' }, { text: 'generated' }]}
            says="The two halves above, composed — byte for byte what the running copilot was given, and never written into its folder."
            action={open === 'composed' ? 'Close' : 'View'}
            onAction={toggle('composed')}
          >
            {open === 'composed' && (
              <ReadOnlyFile
                label={baseName(composedFile?.path ?? 'copilot.md')}
                text={composed.text}
                problem={
                  composed.problem ??
                  (composedFile !== null && !composedFile.exists
                    ? 'It has not been written yet — it is composed when the copilot starts.'
                    : null)
                }
                rows={16}
                because={
                  'A copy, made at the moment it started. Editing it would change nothing: it is ' +
                  'written again from the two halves every time the copilot starts.'
                }
              >
                <Button onClick={() => onReveal('composed')} disabled={!bridge.copilotReveal}>
                  Show the file
                </Button>
              </ReadOnlyFile>
            )}
          </FileRow>

          {/*
            The folder's own file, listed even when it is not there.

            Its absence is the most reassuring row on this pane: it is the
            visible proof that nothing in that folder claims to be a copilot, so
            an ordinary terminal opened there reads nothing of ours. A row saying
            "not there" states it; leaving the row out would leave somebody to
            infer it.

            **Open, not Edit, and that is a promise rather than missing work.**
            This app writes nothing into a folder somebody chose — not
            instructions, not `memory/`, not a marker — and a Save button here
            would be this pane quietly breaking the one guarantee the folder
            feature turns on. It opens where it lives instead, in their own
            editor, which is whose file it is.
          */}
          <FileRow
            label="The folder’s own instructions"
            badges={
              folderFile?.exists === true
                ? [{ text: 'the folder’s' }]
                : [{ text: 'the folder’s' }, { text: 'not there' }]
            }
            says={
              folderFile?.exists === true
                ? 'Whatever assistant already lives in that folder’s own instructions, read the ordinary way. This app never writes it.'
                : 'Nothing in that folder claims to be the copilot, which is why an ordinary terminal opened there is not it.'
            }
            action="Show"
            onAction={() => onReveal('root')}
            disabledBecause={
              !bridge.copilotReveal
                ? 'This build cannot open a folder — the channel is not wired.'
                : folderFile?.exists === true
                  ? null
                  : 'There is no such file yet. Put one in that folder and it is read from the next start.'
            }
          />

          {/*
            Memory, as a count and a folder — never as a list of dated files.
          */}
          <li className="settings-path-row">
            <span className="settings-path-main">
              <span className="settings-label">
                Its memory
                <span className="settings-badge quiet">
                  {memory === null
                    ? 'not read'
                    : !memory.exists
                      ? 'none yet'
                      : `${facts} file${facts === 1 ? '' : 's'}`}
                </span>
                <HoverNote label="its memory">
                  {'One file per fact, and every one of them is its own — never another session’s. ' +
                    'What it reads out of another session is evidence it reports on, never a fact ' +
                    'it keeps. That is a rule in its instructions rather than something the machine ' +
                    'refuses, and this folder is yours to read and prune.'}
                </HoverNote>
              </span>
              <span className="settings-help">
                {memory !== null && !memory.exists
                  ? 'One is created the first time it runs.'
                  : 'What it has learned about you and your projects, one file per fact.'}
              </span>
            </span>
            <span className="settings-path-actions">
              <Button onClick={() => onReveal('memory')} disabled={!bridge.copilotReveal}>
                Open the folder
              </Button>
            </span>
          </li>
      </ul>

      {/*
        The one button that brings the files into existence, and it is only on
        screen while there is something to create. A permanently visible "Create
        its files" over a folder that already has them is a control that cannot
        act, which is the thing this pass is removing everywhere.
      */}
      {instructions === 'missing' && (
        <div className="settings-actions">
          <Button
            disabled={!bridge.copilotScaffold || busy !== null}
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
      )}
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

/**
 * The action log, behind a View button rather than spread across the pane.
 *
 * Asad, 2026-08-17: *"The action log should not be listed either — a **View**
 * button."* Twelve rows of tool calls were on screen the moment this pane
 * opened, each three lines deep, on a pane he had already called *"busy for
 * nothing, for no sensible reason."*
 *
 * ## Why a disclosure and not a link to the file
 *
 * The obvious reading of "View" is a button that opens `actions.jsonl` in
 * whatever the machine has registered for `.jsonl`, which for most people is
 * nothing at all, and for the rest is a text editor showing one JSON object per
 * line. That is not viewing a log, it is exporting one. The rows are already in
 * this window — the pane read them on open — so View shows them here, formatted,
 * and Open the folder is still beside it for anyone who wants the bytes.
 *
 * ## What stays on screen with the list closed
 *
 * The count, and the sentence saying whether the file can be trusted. The count
 * is the reason to press the button; the trust line is the pane's whole claim
 * about this file and it must **flip** if the path ever moves back inside the
 * copilot's writable folder — reporting a defect rather than going on reassuring
 * somebody about a boundary that is no longer there. Hiding that behind the same
 * button would hide it exactly when it matters.
 */
/* -------------------------------------------------------------- 3. showing -- */

/**
 * One switch: whether the copilot shows you the work, or just does it.
 *
 * Asad, 2026-08-17, asking for it by name and for both halves of it:
 *
 *   > *"Interactive mode ON — the visible scan. Interactive mode OFF — it does
 *   > the work in the background and returns the final answer normally, with
 *   > none of the driving."*
 *
 * Both modes are required, which means the switch is required: a feature with
 * two intended states and one door into them has one state in practice. The one
 * door it had was *"Don't show me next time"* in the scan panel — exactly the
 * right place to *turn it off*, because that is the moment somebody decides they
 * would rather not watch, and no place at all to turn it back on. Somebody who
 * pressed it once had silently given up the feature.
 *
 * ## Why this is the only stored value on a pane that stores nothing
 *
 * Because what it switches is the copilot, not the window. Every other block
 * here reads a folder, a log or a list; this writes one key. It could have gone
 * to Appearance — it changes what the screen does — and that would file it under
 * the surface it paints rather than the agent it belongs to, against the rule
 * the settings rail is built on: a section is a *subject*. Somebody looking for
 * "why does my copilot take over the screen" opens Copilot.
 *
 * ## Optimistic, and honest when the write fails
 *
 * The same contract the settings window states for every one of its own toggles:
 * the switch moves the moment it is pressed, because a disk round trip is not
 * something a switch should wait for, and a failed write says so rather than
 * silently reverting under somebody's finger. Here it also puts the switch back,
 * because unlike the settings window this pane has no footer to carry the
 * message — so leaving it in the position that did not take would be the pane
 * asserting a state that is not stored anywhere.
 */
function ShowingGroup({
  interactive,
  bridge,
  onChange,
  onProblem,
}: {
  interactive: boolean | null
  bridge: Partial<CopilotBridge>
  onChange(next: boolean | null): void
  onProblem(message: string | null): void
}) {
  const canWrite = bridge.setSettings !== undefined && interactive !== null

  return (
    <Block
      title="While it works"
      says="Whether it takes you along when it looks through your sessions, or works quietly and answers."
      more={
        'With this on, it moves the window to whatever it is reading, boxes the exact words and dulls ' +
        'the rest — at machine speed, to watch rather than to read. The answer arrives in its chat ' +
        'either way; with it off, nothing on your screen moves.'
      }
    >
      <Row
        label="Show me what it is looking at"
        help={
          bridge.setSettings === undefined
            ? 'This build has no settings channel wired into its preload, so this cannot be changed here.'
            : interactive === null
              ? 'The settings file could not be read, so this cannot be changed here.'
              : 'It jumps to each session and highlights what it read. The answer is the same either way.'
        }
        control={
          <Switch
            checked={interactive ?? true}
            disabled={!canWrite}
            onChange={(next) => {
              onChange(next)
              onProblem(null)
              void bridge.setSettings?.({ [INTERACTIVE_SETTING]: next })?.catch((cause: unknown) => {
                onChange(!next)
                onProblem(errorText(cause, 'That setting could not be saved.'))
              })
            }}
          />
        }
      />
    </Block>
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
  const [open, setOpen] = useState(false)
  const [all, setAll] = useState(false)
  const rows = actions?.rows ?? []
  const shown = all ? [...rows].reverse() : [...rows].reverse().slice(0, 12)

  return (
    <Block
      title="The action log"
      says="Every tool call it made, what came back, and whether a human said yes."
      more={
        'Append-only, and kept outside the copilot’s own folder on purpose — a record the ' +
        'audited party can compose is not a record. The app writes every line; the copilot’s ' +
        'only way to add one is a log.note call, which is itself recorded.'
      }
    >
      <ul className="settings-paths">
        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              What it has done
              <span className="settings-badge quiet">
                {loading && actions === null
                  ? 'reading'
                  : rows.length === 0
                    ? 'nothing yet'
                    : `${rows.length} record${rows.length === 1 ? '' : 's'}`}
              </span>
            </span>
            {actions !== null && <span className="settings-help">{logTrustLine(actions)}</span>}
            {rows.length === 0 && !loading && (
              <span className="settings-help">
                {actions?.exists
                  ? 'The file is there and has nothing in it yet.'
                  : 'Nothing has been recorded — the copilot has done nothing yet.'}
              </span>
            )}

            {open && rows.length > 0 && (
              <>
                <ul className="copilot-actions">
                  {shown.map((row, index) => (
                    <ActionRow key={`${row.at}-${row.action}-${index}`} row={row} />
                  ))}
                </ul>
                {rows.length > shown.length && (
                  <div className="settings-actions">
                    <Button onClick={() => setAll(true)}>
                      Show the other {rows.length - shown.length}
                    </Button>
                  </div>
                )}
              </>
            )}
          </span>
          <span className="settings-path-actions">
            <Button
              disabled={rows.length === 0}
              onClick={() => setOpen((was) => !was)}
            >
              {open ? 'Hide' : 'View'}
            </Button>
            <Button onClick={() => onReveal('log')}>Open the folder</Button>
          </span>
        </li>
      </ul>
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
      more={
        'It was confined once, and the jail made it worse at its job than the sessions it ' +
        'supervises: it started signed out and could not read a line of your code. What bounds ' +
        'it instead is the tool tiers, the confirmation you are shown, and the refusals below.'
      }
    >
      <ul className="settings-paths">
        <li className="settings-path-row">
          <span className="settings-path-main">
            <span className="settings-label">
              Reads and writes
              <span className="settings-badge quiet">not sandboxed</span>
            </span>
            {/*
              One sentence on the page and the argument behind the dot.

              The second paragraph — why reading and writing are worth it, and
              that this app's own state is always confirmed — is a good paragraph
              and it was permanently on screen under a heading that had already
              said "not sandboxed". The uncomfortable fact leads, which is the
              order this block was inverted for; the reasoning is one hover away.
            */}
            <span className="settings-help">
              Your home directory, your projects, your shell and your tools, your git and GitHub
              logins, your keychain, the network — the same as any session you open yourself.
              <HoverNote label="what it can reach">
                {'Reading your code is what lets it look at the failing test instead of asking you ' +
                  'to paste it; writing is what lets it fix a line rather than describe the fix. ' +
                  'Anything that touches this app’s own state — your settings, your sessions, your ' +
                  'routines — goes through a confirmation you see, whatever else is set.'}
              </HoverNote>
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
              turning off the CLI's prompts and believing they turned off this
              app's, or seeing this app ask and assuming the CLI asked too.

              The prose names the *actor* by category — "the CLI the copilot runs
              on" — and keeps the one concrete path, because the path is the half
              a person can act on. It said "Claude Code's own prompts" until the
              naming sweep, and the sweep's rule is about vendor names in prose
              that describes a mechanism, not about the location of a file: told
              only that some settings file governs this, nobody can go and change
              it. So the sentence describes and the <code>path</code> discloses.
            */}
            <span className="settings-help">
              The CLI the copilot runs on has prompts of its own — before it runs a command or
              edits a file — and they follow <em>your</em> settings for it, in{' '}
              <code>~/.claude/settings.json</code>, exactly as they do in every other session you
              open. If you have set that to bypass them, the copilot will not stop to ask either.
              This app does not change that setting in either direction.
            </span>
            <span className="settings-help">
              The confirmation <em>this app</em> shows you is a separate thing, asked by the desktop
              rather than by the CLI. Nothing in that settings file turns it off.
              <HoverNote label="this app’s confirmation">
                {'It is asked before this app writes a setting, starts a session or changes a ' +
                  'routine, over a request the agent cannot answer for itself — so nothing the ' +
                  'copilot says can wave itself through. With no window open to ask, it is refused ' +
                  'rather than allowed.'}
              </HoverNote>
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
            {/*
              "Its instructions", not a filename. The rule this paragraph is
              about lives in the layer file this pane edits four blocks above —
              `<userData>/copilot-layer/instructions.md`, handed over at exec —
              so `CLAUDE.md` was the wrong file as well as the wrong kind of
              name. Somebody who followed this sentence and went looking for a
              CLAUDE.md holding that rule would not have found one.
            */}
            {/*
              One line, because the memory row under Its files carries the same
              claim behind its own ⓘ, and two copies of a promise are two copies
              that can drift. What this row adds — and why it stays — is the
              *kind* of promise: nothing on this machine enforces it.
            */}
            <span className="settings-help">
              It can read your other sessions’ transcripts, and its instructions tell it never to
              copy any of that into its own memory. Nothing on this machine enforces that.
              <HoverNote label="its memory rule">
                {'Memory is the folder it loads at the start of every conversation, so a fact ' +
                  'copied out of somebody else’s agent would be in its head in every future one. ' +
                  'It is a rule written into its instructions in those words — not a wall — and ' +
                  'the folder is one you can read and prune yourself.'}
              </HoverNote>
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
      more={
        'A routine is a trigger, a prompt and a folder — one file each. They are kept in the ' +
        'app’s own storage, which the copilot may read and cannot write, so one can only be ' +
        'created or changed by you: here, in your own editor, or by a tool call you confirm.'
      }
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
