import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import {
  liftAvailable,
  liftLine,
  readInjectAnswer,
  readLiftAnswer,
  readWorkersView,
  workerLine,
  workersAvailable,
  type InjectReport,
  type PaceSettings,
  type WorkersApi,
  type WorkersView,
} from './workers-bridge'

interface Props {
  open: boolean
  api: WorkersApi
  /**
   * The main-process id of the page in front of the person, or `''`.
   *
   * This is what makes the lift a gesture *on a page they are looking at*
   * rather than an action against a site named in a field. With no page there
   * is nothing to lift and the button is absent.
   */
  viewId: string
  /** That page's address, so the button can name the site before it is pressed. */
  pageUrl: string
  /** Open a page in one worker's jar, in this window's own tab strip. */
  onOpenInWorker(profileId: string): void
  onClose(): void
}

/** What the site of the page in front is called, or `''`. */
export function hostOf(url: string): string {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return ''
    return parsed.hostname
  } catch {
    return ''
  }
}

/**
 * Worker profiles, and the one button in this app that copies a login.
 *
 * ## What a worker is for
 *
 * Asad runs a data pipeline against two property platforms. A profile here is
 * already a real Chromium partition — its own cookie jar, its own storage, its
 * own cache — so N of them is N independent browsers that can be driven at
 * once. What was missing was the pool shape: mint several, see which is busy,
 * and cap how many run at a time.
 *
 * ## Why the Lift button is here and not in a tool
 *
 * Many sites permit exactly one login at a time. Signing in separately on eight
 * worker profiles invalidates the first seven, so the only workable shape is:
 * **sign in once, in a window you are watching, and copy that session into the
 * workers.**
 *
 * That is also, precisely, a button that exfiltrates a login — so it is a
 * button, on this screen, on the page in front of the person, and there is no
 * tool anywhere in the app that does it. An agent that needs a login asks
 * through the handover banner, which puts its sentence over the page and hands
 * the person the baton; they answer it by signing in and pressing this.
 * `browser-session-lift.ts` and `deck-control/session-tools.ts` both carry the
 * argument in full.
 *
 * ## And why the panel is careful about the word "signed in"
 *
 * Cookies are copied the instant Inject is pressed. Stored keys — the ones a
 * site keeps in `localStorage` — cannot be, because there is no way to write a
 * renderer's storage from outside a page and the only alternative would be a
 * hidden window, which is the beginning of headless and is refused. So they are
 * **queued**, and every row says so until the worker actually opens the site.
 * A row that said "signed in" for a worker whose token has not been written yet
 * would be the same failure as a resume ledger that skipped 48,473 assets and
 * exited reporting success.
 */
export function WorkersPanel({ open, api, viewId, pageUrl, onOpenInWorker, onClose }: Props) {
  const [view, setView] = useState<WorkersView | null>(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [reports, setReports] = useState<InjectReport[]>([])
  const [add, setAdd] = useState('4')
  /**
   * The three pace fields, held as typed text until they are left.
   *
   * Committing on every keystroke reads well in a diff and badly under a
   * keyboard: `30000` typed a character at a time is stored as 3, 30, 300, 3000
   * — and a field whose value comes back clamped would snap under the cursor
   * the moment a digit crossed the ceiling, so a number above it could not be
   * typed at all. So the field is the person's text and the store is updated on
   * blur or Enter, which is also when the clamp has something honest to say.
   */
  const [paceDraft, setPaceDraft] = useState<Record<string, string> | null>(null)

  const reload = useCallback(async () => {
    if (!api.browserWorkers) return
    setView(readWorkersView(await api.browserWorkers()))
  }, [api])

  useEffect(() => {
    if (!open) return
    setNote('')
    setReports([])
    setPaceDraft(null)
    void reload()
  }, [open, reload])

  /*
   * Not wired in this build: draw nothing.
   *
   * The alternative — an empty panel, or rows that cannot be pressed — is the
   * complaint the whole browser review is made of. `workersAvailable` is all or
   * nothing for exactly this reason.
   */
  if (!workersAvailable(api)) return null

  const host = hostOf(pageUrl)
  const canLift = liftAvailable(api) && viewId !== '' && host !== ''

  const run = async (what: () => Promise<void>): Promise<void> => {
    setBusy(true)
    try {
      await what()
    } finally {
      setBusy(false)
    }
  }

  const mint = (): Promise<void> =>
    run(async () => {
      if (!api.browserWorkersEnsure) return
      const wanted = Number.parseInt(add, 10)
      if (!Number.isFinite(wanted) || wanted <= 0) {
        setNote('Type how many workers you want in total.')
        return
      }
      setView(readWorkersView(await api.browserWorkersEnsure(wanted)))
      setNote('')
    })

  const commitPace = (): Promise<void> =>
    run(async () => {
      if (!api.browserWorkerPace || paceDraft === null) return
      const next: PaceSettings = {
        maxConcurrent: Number.parseInt(paceDraft.maxConcurrent, 10) || 1,
        minDelayMs: Number.parseInt(paceDraft.minDelayMs, 10) || 0,
        jitterMs: Number.parseInt(paceDraft.jitterMs, 10) || 0,
      }
      const answer = readWorkersView(await api.browserWorkerPace(next))
      setView(answer)
      setPaceDraft(null)
      // The clamp is shown rather than applied in silence: a field that stores a
      // different number from the one it displays is a control that lies.
      setNote(answer?.paceNote ?? '')
    })

  const unregister = (profileId: string): Promise<void> =>
    run(async () => {
      if (!api.browserWorkerUnregister) return
      setView(readWorkersView(await api.browserWorkerUnregister(profileId)))
      setNote('Taken out of the pool. Its cookies and its clearance are untouched.')
    })

  const lift = (): Promise<void> =>
    run(async () => {
      if (!api.browserWorkerLift) return
      const answer = readLiftAnswer(await api.browserWorkerLift({ viewId }))
      if (!answer.ok) {
        setNote(answer.reason)
        return
      }
      setReports([])
      await reload()
      /*
       * Said back, in the words of what was actually taken.
       *
       * A press whose only visible effect is a row appearing further down the
       * panel is a press somebody repeats. And the sentence is the summary's
       * own — counts and cookie names — so a person can see whether it caught
       * the login or a consent banner's preference before they copy it into
       * eight profiles.
       */
      setNote(`Taken: ${liftLine(answer.summary)}. Now put it into the workers.`)
    })

  const inject = (liftId: string): Promise<void> =>
    run(async () => {
      if (!api.browserWorkerInject) return
      const answer = readInjectAnswer(await api.browserWorkerInject({ liftId }))
      if (!answer.ok) {
        setNote(answer.reason)
        setReports([])
        return
      }
      setReports(answer.reports)
      setNote(answer.line)
      await reload()
    })

  const forget = (liftId: string): Promise<void> =>
    run(async () => {
      if (!api.browserWorkerForgetLift) return
      setView(readWorkersView(await api.browserWorkerForgetLift(liftId)))
      setReports([])
      setNote('Forgotten. Nothing of it is left in memory.')
    })

  const workers = view?.workers ?? []
  const pace = view?.pace ?? { maxConcurrent: 1, minDelayMs: 0, jitterMs: 0 }
  const wanted = Number.parseInt(add, 10)
  /** Nothing to add is a press that would do nothing, so there is no press. */
  const canMint = Number.isFinite(wanted) && wanted > workers.length

  /** One pace field: the typed text if there is any, otherwise what is stored. */
  const paceField = (
    key: 'maxConcurrent' | 'minDelayMs' | 'jitterMs',
    id: string,
    label: string,
  ) => (
    <>
      <label className="bw-menu-label" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className="bw-menu-input"
        value={paceDraft?.[key] ?? String(pace[key])}
        inputMode="numeric"
        spellCheck={false}
        onChange={(event) =>
          setPaceDraft({
            maxConcurrent: String(pace.maxConcurrent),
            minDelayMs: String(pace.minDelayMs),
            jitterMs: String(pace.jitterMs),
            ...paceDraft,
            [key]: event.target.value,
          })
        }
        onBlur={() => void commitPace()}
        onKeyDown={(event) => {
          if (event.key === 'Enter') void commitPace()
        }}
      />
    </>
  )

  return (
    <Modal open={open} title="Workers" onClose={onClose} size="lg">
      <p className="bw-muted">
        A worker is a profile with its own cookie jar, so several can be signed in and driven at once.
        Workers are never deleted from here — whatever a site decided about one is bound to that jar and
        cannot be earned again by making a new one.
      </p>

      <div className="bw-profile-head">
        <label className="bw-menu-label" htmlFor="bw-worker-count">
          Workers in total
        </label>
        <input
          id="bw-worker-count"
          className="bw-menu-input"
          value={add}
          inputMode="numeric"
          spellCheck={false}
          onChange={(event) => setAdd(event.target.value)}
        />
        <button type="button" className="bw-primary" disabled={busy || !canMint} onClick={() => void mint()}>
          Add
        </button>
      </div>
      {/* The field is a *total*, so Add with six already there and four typed is
          a press whose effect is nothing. The button is off rather than
          apologetic, and the line beside it says why. */}
      <p className="bw-muted">
        {workers.length === 0
          ? `None yet. At most ${view?.max ?? 0}.`
          : canMint
            ? `${workers.length} now, so this adds ${wanted - workers.length}.`
            : `${workers.length} now. This field is a total and it only ever adds — type a bigger number to make more. Nothing here removes one.`}
      </p>

      <h3 className="bw-history-heading">How hard they run</h3>
      <div className="bw-profile-head">
        {paceField('maxConcurrent', 'bw-worker-conc', 'At once')}
        {paceField('minDelayMs', 'bw-worker-delay', 'Wait (ms)')}
        {paceField('jitterMs', 'bw-worker-jitter', 'Jitter (ms)')}
      </div>
      <p className="bw-muted">
        The wait is served by the browser before a worker is handed over, so it happens whether or not
        whatever is driving remembers to wait.
      </p>

      <h3 className="bw-history-heading">Sign in once, use it everywhere</h3>
      {canLift ? (
        <>
          <p className="bw-muted">
            Sign in on the page in front of you, then take its session and put it into the workers. This
            is the only way to have several workers signed in to a site that allows one login at a time —
            signing in on each would knock the others out.
          </p>
          <button type="button" className="bw-primary" disabled={busy} onClick={() => void lift()}>
            Take the session from {host}
          </button>
        </>
      ) : (
        /* Absent rather than disabled where there is nothing to lift: a greyed
           button here would be a promise about a page that is not open. */
        <p className="bw-muted">
          Open a site in this window and sign in to it, and this is where you copy that session into the
          workers.
        </p>
      )}

      {(view?.lifts ?? []).map((summary) => (
        <div key={summary.id} className="bw-profile-doors">
          <span className="bw-menu-label">{liftLine(summary)}</span>
          <span className="bw-spacer" />
          <button
            type="button"
            className="bw-text-button"
            disabled={busy || workers.length === 0}
            onClick={() => void inject(summary.id)}
          >
            Put into every worker
          </button>
          <button type="button" className="bw-text-button" disabled={busy} onClick={() => void forget(summary.id)}>
            Forget
          </button>
        </div>
      ))}

      {view !== null && !view.canSeedStorage && (
        /* Never silent. A build that cannot seed web storage copies the cookies
           and nothing else, and a site that keeps its token in localStorage will
           simply not be signed in — which is an hour lost to a worker that looks
           identical to one that worked. */
        <p className="bw-menu-note">
          This build cannot write stored keys into a worker, so a site that keeps its token in
          localStorage will not be signed in there. Cookies still copy.
        </p>
      )}

      <h3 className="bw-history-heading">The workers</h3>
      {workers.length === 0 ? (
        <p className="bw-muted">None yet.</p>
      ) : (
        <ul className="bw-menu-list">
          {workers.map((worker) => (
            <li key={worker.profileId} className="bw-menu-row">
              <span className="bw-menu-label">{worker.name}</span>
              <span className="bw-muted">{workerLine(worker)}</span>
              <span className="bw-spacer" />
              <button
                type="button"
                className="bw-text-button"
                onClick={() => {
                  onOpenInWorker(worker.profileId)
                  onClose()
                }}
              >
                Open a page here
              </button>
              <button
                type="button"
                className="bw-text-button"
                disabled={busy}
                onClick={() => void unregister(worker.profileId)}
              >
                Take out of the pool
              </button>
            </li>
          ))}
        </ul>
      )}

      {reports.length > 0 && (
        <ul className="bw-menu-list">
          {reports.map((report) => (
            <li key={report.profileId} className="bw-menu-row">
              <span className="bw-menu-label">{report.name}</span>
              <span className="bw-muted">
                {report.cookiesSet} cookie{report.cookiesSet === 1 ? '' : 's'} copied
                {report.note === '' ? '' : ` · ${report.note}`}
              </span>
            </li>
          ))}
        </ul>
      )}

      {note !== '' && <p className="bw-menu-note">{note}</p>}

      <p className="bw-muted">
        To drive several workers at the same time, put one worker page in each browser window and attach
        those windows to the session. One window shows one page at a time, so an agent driving a window
        drives whichever worker is in front of it. Which pages are open in which worker is listed above,
        on that worker’s own row.
      </p>
    </Modal>
  )
}
