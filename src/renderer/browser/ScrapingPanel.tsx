import { useCallback, useEffect, useMemo, useState } from 'react'
// Relative rather than '@shared/…': vitest runs without the electron-vite alias,
// so a *value* import through it resolves in the app and throws in a test.
import { MAX_KEEP_MB, MAX_PACE_MS, MAX_WORKERS } from '../../shared/scrape-limits'
import { Modal } from '../components/Modal'
import { readProfileState, type AccountsApi, type BrowserProfile } from './accounts-bridge'
import type { DownloadsView } from './downloads-bridge'
import { timeLabel } from './history-view'
import { profileInitial } from './profile-badge'
import { formatBytes } from './SessionModal'
import {
  RESOURCE_TYPES,
  blockCaptureAvailable,
  liftAvailable,
  liftRequestsAvailable,
  mintAvailable,
  readLiftRequests,
  readFlag,
  readOutcome,
  readScrapingConfig,
  readScrapingStatus,
  readToolListings,
  scrapingConfigAvailable,
  scrapingStatusAvailable,
  storeAvailable,
  workersAvailable,
  type LiftRequest,
  type RequestRule,
  type ScrapingApi,
  type ScrapingConfig,
  type ScrapingConfigPatch,
  type ScrapingStatus,
  type ToolListing,
} from './scraping-bridge'
import {
  FULFILL_NOTE,
  NOT_ENROLLED,
  NOT_MEASURED,
  REQUEST_RULES,
  bytesLine,
  canInstall,
  countLine,
  coverageVerdict,
  droppedLine,
  enrollable,
  fleetLine,
  installBlockedReason,
  liftBlockedReason,
  liftLine,
  liftRequestLine,
  mintPlan,
  reachLine,
  resourceLabel,
  ruleChange,
  ruleLabel,
  scopeLabel,
  workerRows,
  workerStateLabel,
  type SettingScope,
} from './scraping-view'

/**
 * Everything the body needs, on whichever surface is drawing it.
 *
 * There are two: the browser's own Scraping panel, and Settings → Scraping.
 * They are the *same* controls with the same labels and the same help text
 * because they are the same component — see {@link ScrapingBody}.
 */
export interface ScrapingBodyProps {
  /**
   * Is this body on screen right now?
   *
   * It gates every read and both subscriptions. In the modal it is the modal
   * being open; on a settings pane it is the pane being mounted, which is what
   * `SettingsWindow` does with its `key` — a closed surface that keeps a
   * subscription is a listener nobody can see and nobody unsubscribes.
   */
  live: boolean
  /** The scraping seams — mostly unwired today. See `scraping-bridge.ts`. */
  api: ScrapingApi
  /** Profiles, which are real and shipped: a worker *is* a profile. */
  accounts: AccountsApi
  /**
   * Where downloads land, or `null` on a build that cannot say.
   *
   * Passed in rather than read here because the workspace is already holding it
   * and already subscribed to its push — a second reader would be a second
   * answer to one question, drifting by a frame.
   */
  downloads: DownloadsView | null
  /** The profile the browser is on, which is the one this panel opens editing. */
  profileId: string
  /**
   * Is there a page in front of the person right now?
   *
   * The Session section's one act takes a session off that page — see
   * `scraping-adapter.ts` — so with nothing open there is nothing to lift, and
   * the button says so before it is pressed rather than after.
   */
  pageOpen: boolean
  /**
   * May the session lift be offered here at all?
   *
   * The one gesture on this screen that is a fact about a **window** rather
   * than about this machine: it takes the signed-in session off the page in
   * front of the person. A settings pane has no page and never will have one,
   * so it passes `false` and the section says so in a sentence instead of
   * drawing a button that is disabled forever — see the note on `Unavailable`
   * for why a control that cannot act is not drawn at all.
   */
  canLift: boolean
}

interface Props extends Omit<ScrapingBodyProps, 'live' | 'canLift'> {
  open: boolean
  onClose(): void
}

/**
 * Everything this browser can do to a website it is taking apart, on one screen.
 *
 * ## Why a panel at all
 *
 * The capability is being built in four pieces at once — durable worker
 * profiles and the session lift; per-resource-type request rules and passive
 * capture; byte-exact assets, rendition upgrades and a resume ledger; and a
 * store that fetches and verifies a tool before it can be installed. Four pieces
 * with no single place to see them is four features nobody can find, which is
 * the complaint the whole browser was rebuilt around. So the panel came first
 * and the seams it calls are named and typed in `scraping-bridge.ts`, one
 * contract per lane.
 *
 * ## What it may say
 *
 * **Only what it has been told.** Every count that arrives is `number | null`,
 * `null` prints as *"not measured"*, and no section fills a gap with a
 * reasonable-looking default. A tool that skipped 48,473 assets and exited
 * reporting success is the reason that rule is absolute rather than a
 * preference, and a coverage check whose page stated no total returns **no
 * verdict** rather than a green one — `coverageVerdict` in `scraping-view.ts`
 * carries that argument.
 *
 * Zero workers is *"No workers yet."* and not a row: an example row on a
 * configuration screen is indistinguishable from a real one, and somebody would
 * eventually press Retire on it.
 *
 * ## What an unwired seam looks like
 *
 * The section is drawn, named, and says it is unavailable. Not hidden — a
 * section that vanishes takes the knowledge that the capability exists with it —
 * and **no control is drawn inside it**, because the standing rule in this panel
 * is that a control which cannot do anything is not offered. That is the same
 * bargain `BrowserMenu.tsx` makes for its rows, applied one level down: the door
 * is visible, what is behind it is honest about being empty.
 *
 * ## Headful, and no switch for it
 *
 * The browser works in a window you can watch, and that is a feature rather than
 * a limitation: the targets worth scraping refuse a headless client outright. So
 * there is no hidden mode here and this panel deliberately does not offer one —
 * the line at the top says so, because a person looking for the switch deserves
 * to find the reason instead of hunting for it.
 */
export function ScrapingBody({
  live,
  api,
  accounts,
  downloads,
  profileId,
  pageOpen,
  canLift,
}: ScrapingBodyProps) {
  const [profiles, setProfiles] = useState<BrowserProfile[]>([])
  /**
   * The profile whose settings are on screen.
   *
   * Its own state rather than the browser's active profile: reading Work's
   * request rules must not put the next tab into Work. The panel opens on
   * whatever the browser is on, and says which one it is on every section.
   */
  const [editing, setEditing] = useState(profileId)
  const [config, setConfig] = useState<ScrapingConfig | null>(null)
  /**
   * Whether this profile's browser photographs the pages that refuse it.
   *
   * Its own state rather than a field of `config`, because it has its own seam:
   * the camera is real and the configuration store is not, and holding them in
   * one object would mean the switch went unavailable with the four sections
   * that have no engine. `null` is *this build did not say* and draws as unset,
   * never as off — the whole panel's rule, and here the difference between
   * "nothing is being photographed" and "nobody asked".
   */
  const [camera, setCamera] = useState<boolean | null>(null)
  const [status, setStatus] = useState<ScrapingStatus | null>(null)
  const [asks, setAsks] = useState<LiftRequest[]>([])
  const [tools, setTools] = useState<ToolListing[]>([])
  const [note, setNote] = useState('')

  /** The lift, which is the one act on this screen that needs two presses. */
  const [liftFrom, setLiftFrom] = useState('')
  const [liftInto, setLiftInto] = useState<string[]>([])
  const [liftArming, setLiftArming] = useState(false)
  /** Emptying the resume ledger, which is the other thing with no undo. */
  const [ledgerArming, setLedgerArming] = useState(false)
  /**
   * How many workers there should be in total, as typed.
   *
   * Held as text rather than a number for the reason `NumberField` gives: a
   * field that parses every keystroke cannot be typed into, because 12 becomes
   * 1 the moment somebody starts replacing it.
   */
  const [mintTo, setMintTo] = useState('4')
  /**
   * The ask being approved, if one is.
   *
   * Approving is armed exactly as pressing Lift is, and for the same reason
   * rather than for symmetry: granting an ask copies a live logged-in session
   * into other profiles on disk, and a request that arrived on its own must not
   * be answerable with one press that lands where Decline was a moment ago.
   */
  const [approving, setApproving] = useState('')

  const canConfigure = scrapingConfigAvailable(api)
  const canMeasure = scrapingStatusAvailable(api)

  const loadProfiles = useCallback(async () => {
    if (!accounts.browserProfiles) return
    const state = readProfileState(await accounts.browserProfiles())
    setProfiles(state?.profiles ?? [])
  }, [accounts])

  const loadConfig = useCallback(async () => {
    if (!api.browserScrapingConfig || editing === '') return
    setConfig(readScrapingConfig(await api.browserScrapingConfig(editing)))
  }, [api, editing])

  const loadCamera = useCallback(async () => {
    if (!api.browserBlockCapture || editing === '') return
    setCamera(readFlag(await api.browserBlockCapture(editing)))
  }, [api, editing])

  const loadStatus = useCallback(async () => {
    if (!api.browserScrapingStatus || editing === '') return
    setStatus(readScrapingStatus(await api.browserScrapingStatus(editing)))
  }, [api, editing])

  const loadAsks = useCallback(async () => {
    if (!api.browserScrapingLiftRequests) return
    setAsks(readLiftRequests(await api.browserScrapingLiftRequests()))
  }, [api])

  const loadTools = useCallback(async () => {
    if (!api.browserScrapingTools) return
    setTools(readToolListings(await api.browserScrapingTools()))
  }, [api])

  /*
   * A different profile is a different configuration, blanked before it is
   * asked for — the rule `HistoryPanel.tsx` states: showing Default's rules for
   * the round trip after somebody picked Work is the one thing a per-profile
   * store must never appear to do.
   */
  useEffect(() => {
    setConfig(null)
    setStatus(null)
    setCamera(null)
    setNote('')
    setLiftArming(false)
    setLedgerArming(false)
    setApproving('')
  }, [editing])

  useEffect(() => {
    if (!live) return
    setEditing(profileId)
    setLiftFrom(profileId)
    setLiftInto([])
    void loadProfiles()
    void loadAsks()
    void loadTools()
  }, [live, profileId, loadProfiles, loadAsks, loadTools])

  useEffect(() => {
    if (!live) return
    void loadConfig()
    void loadStatus()
    void loadCamera()
  }, [live, loadConfig, loadStatus, loadCamera])

  /* The pushes, held only while the panel is up: a closed panel that keeps a
     subscription is a listener nobody can see and nobody unsubscribes. */
  useEffect(() => {
    if (!live || !api.onBrowserScrapingStatus) return
    return api.onBrowserScrapingStatus((raw) => setStatus(readScrapingStatus(raw)))
  }, [live, api])

  useEffect(() => {
    if (!live || !api.onBrowserScrapingLiftRequest) return
    return api.onBrowserScrapingLiftRequest(() => void loadAsks())
  }, [live, api, loadAsks])

  const profileName = useMemo(
    () => profiles.find((profile) => profile.id === editing)?.name ?? '',
    [profiles, editing],
  )
  const nameOf = useCallback(
    (id: string) => profiles.find((profile) => profile.id === id)?.name ?? id,
    [profiles],
  )

  const rows = useMemo(
    () => workerRows(config?.fleet ?? null, status, profiles),
    [config, status, profiles],
  )
  const spare = useMemo(() => enrollable(config?.fleet ?? null, profiles), [config, profiles])

  /**
   * Store one change and take the answer as the new truth.
   *
   * The reply is the stored configuration, not a boolean, so a value the engine
   * clamped or refused appears clamped or refused on screen rather than sitting
   * in the field as typed. An unreadable reply is not treated as a success: the
   * note says so and the panel reloads rather than drawing what it hoped.
   */
  const patch = useCallback(
    async (change: ScrapingConfigPatch): Promise<void> => {
      if (!api.browserScrapingConfigSet || editing === '') return
      const stored = readScrapingConfig(await api.browserScrapingConfigSet(editing, change))
      if (stored === null) {
        setNote('That change was not confirmed, so nothing here claims it was stored.')
        await loadConfig()
        return
      }
      setNote('')
      setConfig(stored)
    },
    [api, editing, loadConfig],
  )

  /**
   * Turn the block camera off, or back on.
   *
   * The stored answer is what lands in state, not the value that was clicked.
   * That matters more here than anywhere else on this screen: what is being
   * switched has no output when it is working, so a switch that moved on its own
   * say-so would be the only evidence of a setting that had not been saved.
   */
  const setCameraOn = useCallback(
    async (on: boolean): Promise<void> => {
      if (!api.browserBlockCaptureSet || editing === '') return
      const stored = readFlag(await api.browserBlockCaptureSet(editing, on))
      if (stored === null) {
        setNote('That change was not confirmed, so nothing here claims it was stored.')
        await loadCamera()
        return
      }
      setNote('')
      setCamera(stored)
    },
    [api, editing, loadCamera],
  )

  const lift = async (): Promise<void> => {
    if (!api.browserScrapingLift) return
    setLiftArming(false)
    const outcome = readOutcome(await api.browserScrapingLift(liftFrom, liftInto))
    // The count is the whole of it: "done" with nothing counted is the shape of
    // report this panel exists to refuse, so the sentence says what was moved or
    // says that nothing said.
    setNote(
      outcome.ok
        ? outcome.count === null
          ? `${outcome.message} Nothing counted what moved, so this is unconfirmed.`
          : `${countLine(outcome.count, 'cookie', 'cookies')} copied into ${liftInto.length === 1 ? nameOf(liftInto[0]) : `${liftInto.length} workers`}. ${outcome.message}`
        : outcome.message,
    )
    await loadStatus()
  }

  const answerAsk = async (request: LiftRequest, approve: boolean): Promise<void> => {
    if (!api.browserScrapingLiftAnswer) return
    setApproving('')
    const outcome = readOutcome(await api.browserScrapingLiftAnswer(request.id, approve))
    setNote(outcome.message)
    await loadAsks()
    await loadStatus()
  }

  const install = async (tool: ToolListing): Promise<void> => {
    if (!api.browserScrapingToolInstall) return
    const outcome = readOutcome(await api.browserScrapingToolInstall(tool.id))
    setNote(outcome.ok ? `${tool.name} installed.` : outcome.message)
    await loadTools()
  }

  const remove = async (tool: ToolListing): Promise<void> => {
    if (!api.browserScrapingToolRemove) return
    const outcome = readOutcome(await api.browserScrapingToolRemove(tool.id))
    setNote(outcome.ok ? `${tool.name} removed.` : outcome.message)
    await loadTools()
  }

  /*
   * The verbs, every one of them written out rather than chained off an
   * optional call at the call site: a `?.()` answers `undefined` on a build
   * without the method, and `.then` on that is a crash inside a click handler
   * on exactly the builds this panel is written to survive.
   */

  /**
   * Take the fleet the engine answers with, and say when it did not change.
   *
   * The reply is the stored fleet rather than a boolean, exactly as `patch`
   * takes its reply, and for a sharper reason here: `registerWorker` refuses
   * the default profile and a full fleet **in silence**, so a panel that only
   * reloaded would put the same name back in the dropdown and leave somebody
   * pressing a control that does nothing.
   */
  const storeFleet = async (
    answer: Promise<unknown>,
    expect: (ids: readonly string[]) => string,
  ): Promise<void> => {
    const stored = readScrapingConfig(await answer)
    if (stored === null) {
      setNote('That change was not confirmed, so nothing here claims it was stored.')
      await loadConfig()
      return
    }
    setConfig(stored)
    setNote(expect(stored.fleet?.profileIds ?? []))
    await loadStatus()
  }

  const enrol = async (id: string): Promise<void> => {
    if (!api.browserScrapingWorkerAdd) return
    await storeFleet(api.browserScrapingWorkerAdd(id), (ids) =>
      ids.includes(id) ? '' : `${nameOf(id)} was not enrolled. ${NOT_ENROLLED}`,
    )
  }

  const retire = async (id: string): Promise<void> => {
    if (!api.browserScrapingWorkerRemove) return
    await storeFleet(api.browserScrapingWorkerRemove(id), (ids) =>
      ids.includes(id)
        ? `${nameOf(id)} is still a worker — the engine did not retire it.`
        : 'Retired. Its cookies and whatever a site decided about it are untouched.',
    )
  }

  /** Make workers until there are `total` of them. Only ever adds. */
  const mint = async (total: number): Promise<void> => {
    if (!api.browserScrapingWorkerMint) return
    await storeFleet(api.browserScrapingWorkerMint(total), () => '')
  }

  const clearCapture = async (): Promise<void> => {
    if (!api.browserScrapingCaptureClear) return
    await api.browserScrapingCaptureClear(editing)
    await loadStatus()
  }

  const clearLedger = async (): Promise<void> => {
    if (!api.browserScrapingLedgerClear) return
    setLedgerArming(false)
    await api.browserScrapingLedgerClear(editing)
    await loadStatus()
  }

  /* What the total field would do if it were pressed, and the line beside it. */
  const plan = mintPlan(mintTo, rows.length)
  const mintTotal = plan.total
  const liftNames = liftInto.map(nameOf)
  const liftRefusal = liftBlockedReason(pageOpen, liftFrom, liftInto)
  const requests = config?.requests ?? null
  const capture = config?.capture ?? null
  const assets = config?.assets ?? null
  const checks = config?.checks ?? null
  const verdict = coverageVerdict(status?.lastCheck ?? null)

  return (
    <div className="bw-scrape">
      {/* Which profile, at the top and again on every section head. A panel
          that edits per-profile settings and does not say whose is a panel
          somebody configures twice and loses once. */}
      <div className="bw-scrape-profile">
        <span className="bw-avatar" aria-hidden="true">
          {profileInitial(profileName, profiles.find((p) => p.id === editing)?.avatar ?? '')}
        </span>
        <label className="bw-scrape-field">
          <span className="bw-scrape-field-label">Settings for</span>
          <select
            className="bw-menu-input"
            value={editing}
            onChange={(event) => setEditing(event.target.value)}
          >
            {profiles.length === 0 && <option value={editing}>Loading…</option>}
            {profiles.map((profile) => (
              <option key={profile.id} value={profile.id}>
                {profile.name}
              </option>
            ))}
          </select>
        </label>
      </div>

      {/*
        Headful, stated rather than switchable.

        The window being visible is what makes this browser work against the
        targets worth scraping — they refuse a headless client — and it is also
        what lets somebody watch a run go wrong. There is no hidden mode and
        this panel does not pretend one is coming.
      */}
      <p className="bw-scrape-headful">
        Scraping happens in a window you can watch. There is no hidden mode: the sites worth
        taking apart refuse a browser that has no screen.
      </p>

      {note !== '' && (
        <p className="bw-menu-note" role="status">
          {note}
        </p>
      )}

      {/* The exception is named rather than glossed over. "Nothing on this
          screen can be set" was true until the block camera got a seam of its
          own, and a banner that had gone one control out of date would be the
          panel telling somebody their switch does nothing while it works. */}
      {!canConfigure && (
        <p className="bw-scrape-unwired">
          This build has no scraping configuration behind it, so most of this screen cannot be
          set
          {blockCaptureAvailable(api)
            ? ' — the exception is the block camera under Checks, which is wired and does what it says.'
            : '.'}{' '}
          What is listed below is what the panel will show once an engine is.
        </p>
      )}

      {/* ---------------------------------------------------------- workers -- */}

      <Head title="Workers" scope="browser" profileName={profileName} />
      {!canConfigure ? (
        <Unavailable what="no engine keeps a fleet of worker profiles" />
      ) : (
        <>
          {rows.length === 0 ? (
            <p className="bw-muted">No workers yet.</p>
          ) : (
            <p className="bw-scrape-facts">{fleetLine(rows, canMeasure)}</p>
          )}
          {rows.length > 0 && (
            <ul className="bw-menu-list">
              {rows.map((row) => (
                <li key={row.profileId} className="bw-menu-row">
                  <span className="bw-avatar" aria-hidden="true">
                    {profileInitial(row.name, row.avatar)}
                  </span>
                  <span className="bw-menu-label">{row.name}</span>
                  {row.orphaned && <span className="bw-badge">profile deleted</span>}
                  {!row.enrolled && <span className="bw-badge">not enrolled</span>}
                  <span className="bw-spacer" />
                  <span className="bw-scrape-state" data-state={row.state}>
                    {workerStateLabel(row.state)}
                  </span>
                  <span className="bw-menu-count">
                    {countLine(row.requests, 'request', 'requests')}
                  </span>
                  {workersAvailable(api) && (
                    <button
                      type="button"
                      className="bw-text-button"
                      aria-label={`Retire ${row.name}`}
                      onClick={() => void retire(row.profileId)}
                    >
                      Retire
                    </button>
                  )}
                </li>
              ))}
            </ul>
          )}

          {/* Enrolling is choosing an existing profile, never minting one: a
              worker is a profile with a cookie jar somebody may already be
              signed into, and this panel does not create those. */}
          {workersAvailable(api) && (
            <div className="bw-scrape-row">
              <select
                className="bw-menu-input"
                aria-label="Profile to enrol as a worker"
                value=""
                disabled={spare.length === 0}
                onChange={(event) => {
                  if (event.target.value !== '') void enrol(event.target.value)
                }}
              >
                <option value="">{spare.length === 0 ? 'Every profile is a worker' : 'Add a worker…'}</option>
                {spare.map((profile) => (
                  <option key={profile.id} value={profile.id}>
                    {profile.name}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Minting, which is the other half and not the same act: enrolling
              takes a profile somebody already has, and this makes fresh ones,
              which is the only workable way to stand eight of them up at
              once. A total rather than a delta, and the button is absent
              rather than inert when pressing it would add nothing. */}
          {mintAvailable(api) && (
            <div className="bw-scrape-row">
              <label className="bw-scrape-field">
                <span className="bw-scrape-field-label">Workers in total</span>
                <input
                  className="bw-menu-input bw-scrape-number"
                  value={mintTo}
                  inputMode="numeric"
                  spellCheck={false}
                  onChange={(event) => setMintTo(event.target.value)}
                />
              </label>
              {mintTotal !== null && (
                <button type="button" className="bw-primary" onClick={() => void mint(mintTotal)}>
                  Make {mintTotal - rows.length} more
                </button>
              )}
              <span className="bw-muted">{plan.line}</span>
            </div>
          )}

          {/* The pool's own ceiling, not a rounder-looking one. This read
              `max={64}` beside an engine that clamps to 16. */}
          <NumberField
            label="At once"
            hint="How many workers may be working at the same time."
            value={config?.fleet?.concurrency ?? null}
            min={1}
            max={MAX_WORKERS}
            onCommit={(next) => void patch({ fleet: { concurrency: next } })}
          />
          {/* Ten minutes was accepted here and thirty seconds was stored:
              the wait is awaited inside a tool call, so the pool caps it. */}
          <NumberField
            label="Between requests"
            hint="Milliseconds a worker waits before its next request."
            value={config?.fleet?.delayMs ?? null}
            min={0}
            max={MAX_PACE_MS}
            onCommit={(next) => void patch({ fleet: { delayMs: next } })}
          />
        </>
      )}

      {/* ---------------------------------------------------------- session -- */}

      <Head title="Session" scope="browser" profileName={profileName} />
      {/*
        The one section that is about a *window* rather than about this machine,
        and the reason it is drawn and empty on a settings pane.

        A lift takes the signed-in session off the page in front of the person.
        Settings has no page and cannot grow one, so the button there could only
        ever be disabled — and a control that is certain to refuse costs a click
        to discover the lie. Named absence, one sentence, no control.
      */}
      {/*
        The inbox, above everything else in this section — including the page
        gate. An agent that wants a session lifted gets to *ask*, and the ask
        lands here as a row with two answers — the whole of "surfaces as a
        request to the person, not as a completed action". It is outside the
        `canLift` branch on purpose: approving lifts from whatever page is open
        in the profile the ask NAMES (`handleLiftAnswer`), not from the page in
        front of the approver, so an ask is answerable from Settings → Scraping
        as well as from the browser's own panel — and an inbox hidden exactly
        where somebody reads settings would be a question they never see.
        Drawn only when there is an ask: an empty inbox drawn every time would
        train somebody to skip past it.
      */}
      {liftRequestsAvailable(api) && asks.length > 0 && (
        <ul className="bw-menu-list">
          {asks.map((ask) => (
            <li key={ask.id} className="bw-scrape-ask">
              <span className="bw-scrape-ask-line">
                {liftRequestLine(ask.askedBy, nameOf(ask.fromProfileId), ask.intoProfileIds.map(nameOf))}
              </span>
              <span className="bw-scrape-ask-when">{timeLabel(ask.at)}</span>
              {ask.reason !== '' && <span className="bw-muted">{ask.reason}</span>}
              {approving === ask.id ? (
                <span className="bw-scrape-row">
                  <button type="button" className="bw-danger" onClick={() => void answerAsk(ask, true)}>
                    {liftLine(nameOf(ask.fromProfileId), ask.intoProfileIds.map(nameOf))}
                  </button>
                  <button
                    type="button"
                    className="bw-text-button"
                    autoFocus
                    onClick={() => setApproving('')}
                  >
                    Cancel
                  </button>
                </span>
              ) : (
                <span className="bw-scrape-row">
                  <button type="button" className="bw-primary" onClick={() => setApproving(ask.id)}>
                    Approve this lift
                  </button>
                  <button
                    type="button"
                    className="bw-text-button"
                    onClick={() => void answerAsk(ask, false)}
                  >
                    Decline
                  </button>
                </span>
              )}
            </li>
          ))}
        </ul>
      )}

      {!canLift ? (
        <p className="bw-scrape-hint">
          A lift is taken off the page in front of you, and there is no page here. It is on the
          browser’s own Scraping panel — three dots, then Scraping — where there is one.
        </p>
      ) : (
        <>
          <p className="bw-scrape-hint">
            Lifting copies the signed-in session out of the page in front of you and into the workers
            you tick, so they are signed in too. It happens only when you press it here: no tool in
            this app can lift a session, and none is going to be added.
            {liftRequestsAvailable(api) &&
              ' Anything else that wants one has to ask, and the ask shows up in this section for you to answer.'}
          </p>

          {!liftAvailable(api) ? (
            <Unavailable what="nothing in this build can copy a session between profiles" />
          ) : (
            <>
              <div className="bw-scrape-row">
                <label className="bw-scrape-field">
                  <span className="bw-scrape-field-label">Signed in as</span>
                  <select
                    className="bw-menu-input"
                    value={liftFrom}
                    onChange={(event) => {
                      setLiftFrom(event.target.value)
                      setLiftArming(false)
                    }}
                  >
                    {profiles.map((profile) => (
                      <option key={profile.id} value={profile.id}>
                        {profile.name}
                      </option>
                    ))}
                  </select>
                </label>
              </div>

              {/* Which profile the session is expected to be, not which one it is
                  taken from. The engine takes it off the page in front — that is
                  what makes this a gesture on something you are looking at — and
                  the two can disagree. When they do, nothing is copied. */}
              <p className="bw-scrape-hint">
                The session is taken from the page in front of you. If that page is not signed in as
                the profile named here, nothing is copied and this says so.
              </p>

              {/* Named targets, ticked one at a time. There is deliberately no
                  "all workers": a lift is a named act between named profiles, and
                  a control that means "and whatever else is a worker next week" is
                  not something a person can be said to have agreed to. */}
              <div className="bw-scrape-targets" role="group" aria-label="Workers to inject the session into">
                {rows.length === 0 ? (
                  <p className="bw-muted">No workers yet, so there is nowhere to inject a session.</p>
                ) : (
                  rows.map((row) => (
                    <button
                      key={row.profileId}
                      type="button"
                      className="bw-scrape-target"
                      aria-pressed={liftInto.includes(row.profileId)}
                      data-on={liftInto.includes(row.profileId) || undefined}
                      disabled={row.profileId === liftFrom}
                      title={row.profileId === liftFrom ? 'This is the profile being lifted from' : undefined}
                      onClick={() => {
                        setLiftArming(false)
                        setLiftInto((prev) =>
                          prev.includes(row.profileId)
                            ? prev.filter((id) => id !== row.profileId)
                            : [...prev, row.profileId],
                        )
                      }}
                    >
                      {row.name}
                    </button>
                  ))
                )}
              </div>

              {liftRefusal !== '' ? (
                <p className="bw-muted">{liftRefusal}</p>
              ) : (
                <p className="bw-scrape-hint">{liftLine(nameOf(liftFrom), liftNames)}</p>
              )}

              {/*
                Armed, and the armed button names both ends.

                The same two-press shape the profile rows use for deletion, and for
                a harder reason: this one hands a live logged-in session to other
                profiles on disk. The confirm carries the names rather than a
                count, Cancel takes the focus, and nothing in this file can reach
                `lift()` except this button.
              */}
              {liftArming ? (
                <div className="bw-scrape-row">
                  <button type="button" className="bw-danger" onClick={() => void lift()}>
                    {liftLine(nameOf(liftFrom), liftNames)}
                  </button>
                  <button
                    type="button"
                    className="bw-text-button"
                    autoFocus
                    onClick={() => setLiftArming(false)}
                  >
                    Cancel
                  </button>
                </div>
              ) : (
                <button
                  type="button"
                  className="bw-primary"
                  disabled={liftRefusal !== ''}
                  onClick={() => setLiftArming(true)}
                >
                  Lift this session into the workers
                </button>
              )}
            </>
          )}
        </>
      )}

      {/* --------------------------------------------------------- requests -- */}

      <Head title="Requests" scope="profile" profileName={profileName} />
      {!canConfigure ? (
        <Unavailable what="no engine answers this browser's requests" />
      ) : requests === null ? (
        <Unavailable what="this build stores no request rules" />
      ) : (
        <>
          <p className="bw-scrape-hint">{FULFILL_NOTE}</p>
          <ul className="bw-menu-list">
            {RESOURCE_TYPES.map((type) => (
              <li key={type} className="bw-menu-row">
                <span className="bw-menu-label">{resourceLabel(type)}</span>
                <span className="bw-spacer" />
                <Choice<RequestRule>
                  label={`${resourceLabel(type)} rule`}
                  value={requests[type] ?? null}
                  options={REQUEST_RULES.map((rule) => ({ value: rule, label: ruleLabel(rule) }))}
                  onPick={(rule) => void patch({ requests: ruleChange(type, rule) })}
                />
              </li>
            ))}
          </ul>
        </>
      )}

      {/* ---------------------------------------------------------- capture -- */}

      <Head title="Capture" scope="profile" profileName={profileName} />
      {!canConfigure || capture === null ? (
        <Unavailable what="this build records no background responses" />
      ) : (
        <>
          <OnOff
            label="Record background responses"
            value={capture.on}
            onPick={(next) => void patch({ capture: { on: next } })}
          />
          <p className="bw-scrape-hint">
            Every XHR and fetch the page makes is written down as it answers, so a page that
            loads its data after it renders is caught without asking it twice.
          </p>
          {/* The path ellipsises in a label built for one; the sentence that
              stands in for a path the engine did not name must not, so it is a
              different element rather than the same one wearing the same
              truncation. */}
          {capture.directory === '' ? (
            <p className="bw-scrape-hint">This build did not say where captured responses go.</p>
          ) : (
            <div className="bw-menu-row">
              <span className="bw-menu-label" title={capture.directory}>
                {capture.directory}
              </span>
              <span className="bw-spacer" />
              {api.browserScrapingCaptureReveal && (
                <button
                  type="button"
                  className="bw-text-button"
                  onClick={() => void api.browserScrapingCaptureReveal?.(editing)}
                >
                  Show
                </button>
              )}
            </div>
          )}
          {/* And a terabyte was accepted here, against a capture store that
              keeps at most four gigabytes. */}
          <NumberField
            label="Keep at most"
            hint="Megabytes of captured responses. The oldest go when it is reached."
            value={capture.keepMB}
            min={1}
            max={MAX_KEEP_MB}
            onCommit={(next) => void patch({ capture: { keepMB: next } })}
          />
          {/* Measured, or said to be unmeasured. Never a zero standing in for
              a number nobody counted — see NOT_MEASURED. */}
          <p className="bw-scrape-facts">
            {countLine(status?.capture?.recorded ?? null, 'response', 'responses')} ·{' '}
            {bytesLine(status?.capture?.bytes ?? null, formatBytes)} · {droppedLine(status?.capture ?? null)}
            {!canMeasure && ` · this build reports nothing, so all of it is ${NOT_MEASURED}`}
          </p>
          {api.browserScrapingCaptureClear && (
            <button
              type="button"
              className="bw-text-button"
              onClick={() => void clearCapture()}
            >
              Clear what has been captured
            </button>
          )}
        </>
      )}

      {/* ----------------------------------------------------------- assets -- */}

      <Head title="Assets" scope="profile" profileName={profileName} />
      {!canConfigure || assets === null ? (
        <Unavailable what="this build downloads no assets of its own" />
      ) : (
        <>
          {/* A guarantee, stated as one. It is not a setting, so it is not
              drawn as a switch somebody could look for and fail to find. */}
          <p className="bw-scrape-hint">
            Files are written byte for byte as the server sent them. Nothing re-encodes, resizes
            or renames on the way to disk.
          </p>
          {downloads && (
            <p className="bw-scrape-facts">
              They land in {downloads.destination.folder === '' ? downloads.defaultFolder : downloads.destination.folder}
              {downloads.destination.machineName !== '' && ` on ${downloads.destination.machineName}`}.
            </p>
          )}

          <OnOff
            label="Upgrade asset URLs"
            value={assets.upgrade.on}
            onPick={(next) => void patch({ assets: { upgrade: { on: next } } })}
          />
          <div className="bw-scrape-row">
            <TextField
              label="Replace"
              value={assets.upgrade.from}
              placeholder="the part of the URL that names the small one"
              onCommit={(next) => void patch({ assets: { upgrade: { from: next } } })}
            />
            <TextField
              label="With"
              value={assets.upgrade.to}
              placeholder="the part that names the full one"
              onCommit={(next) => void patch({ assets: { upgrade: { to: next } } })}
            />
          </div>
          <p className="bw-scrape-hint">
            If the upgraded URL answers 404, the original is fetched instead — so an upgrade rule
            that is wrong about one file costs that file its resolution, never the file itself.
          </p>

          <OnOff
            label="Resume ledger"
            value={assets.ledger.on}
            onPick={(next) => void patch({ assets: { ledger: { on: next } } })}
          />
          <p className="bw-scrape-hint">
            Each asset is written down under its URL <em>and</em> the digest of what came back, so
            a re-run skips only files that are byte for byte the ones already on disk.
          </p>
          <OnOff
            label="Fetch again even where the ledger has it"
            value={assets.ledger.refetch}
            onPick={(next) => void patch({ assets: { ledger: { refetch: next } } })}
          />
          <p className="bw-scrape-hint">
            On, the ledger goes on being written but stops skipping — which is how a run is made
            to go and get everything again on purpose, rather than by emptying what it knows.
          </p>
          <p className="bw-scrape-facts">
            {countLine(status?.assets?.fetched ?? null, 'asset', 'assets')} fetched ·{' '}
            {countLine(status?.assets?.skipped ?? null, 'asset', 'assets')} skipped by the ledger ·{' '}
            {countLine(status?.assets?.upgraded ?? null, 'upgrade', 'upgrades')} ·{' '}
            {countLine(status?.assets?.fellBack ?? null, 'fallback', 'fallbacks')} ·{' '}
            {countLine(status?.assets?.ledgerEntries ?? null, 'row', 'rows')} in the ledger
          </p>
          {api.browserScrapingLedgerClear &&
            (ledgerArming ? (
              <div className="bw-scrape-row">
                <button
                  type="button"
                  className="bw-danger"
                  onClick={() => void clearLedger()}
                >
                  Forget every asset {profileName === '' ? 'this profile' : profileName} has fetched
                </button>
                <button
                  type="button"
                  className="bw-text-button"
                  autoFocus
                  onClick={() => setLedgerArming(false)}
                >
                  Cancel
                </button>
              </div>
            ) : (
              <button type="button" className="bw-text-button" onClick={() => setLedgerArming(true)}>
                Empty the ledger
              </button>
            ))}
        </>
      )}

      {/* ----------------------------------------------------------- checks -- */}

      <Head title="Checks" scope="profile" profileName={profileName} />
      {!canConfigure || checks === null ? (
        <Unavailable what="this build checks nothing it has taken" />
      ) : (
        <>
          <OnOff
            label="Check coverage against the page's own total"
            value={checks.coverage.on}
            onPick={(next) => void patch({ checks: { coverage: { on: next } } })}
          />
          <TextField
            label="Where the page states its total"
            value={checks.coverage.pattern}
            placeholder="a pattern with one number in it"
            onCommit={(next) => void patch({ checks: { coverage: { pattern: next } } })}
          />
          {/* The number a listing prints about itself is the only total that
              is not the scrape's own opinion of how it went. Configurable
              because every site writes that line differently. */}
          <p className="bw-scrape-hint">
            The number the page prints about itself — the total in a line like “1–24 of 16,498”.
            What came back is compared against it, and a run that is short says so.
          </p>
          <p className="bw-scrape-facts" data-tone={verdict.tone}>
            {verdict.line}
            {status?.lastCheck && ` — ${timeLabel(status.lastCheck.at)}`}
          </p>
        </>
      )}

      {/* The camera has its own availability because it has its own engine.
          Inside the coverage branch it would have gone dark on every build
          whose configuration store does not exist — which is all of them —
          while the photographing carried on underneath. */}
      {!blockCaptureAvailable(api) ? (
        <Unavailable what="this build cannot say whether it photographs the pages that refuse it" />
      ) : (
        <>
          <OnOff
            label="Screenshot the page when a request is blocked"
            value={camera}
            onPick={(next) => void setCameraOn(next)}
          />
          <p className="bw-scrape-hint">
            A 403, a 429, a challenge or a navigation that ended somewhere it was not sent is
            photographed as it happens — by then it is too late to ask for the picture. The image and
            the evidence beside it stay in this app’s own folder, under this profile, and no paired
            device can read them.
          </p>
        </>
      )}

      {/* ------------------------------------------------------------ store -- */}

      <Head title="Store" scope="browser" profileName={profileName} />
      {!storeAvailable(api) ? (
        <Unavailable what="this build has no store to fetch a tool from" />
      ) : tools.length === 0 ? (
        <p className="bw-muted">Nothing in the store yet.</p>
      ) : (
        <ul className="bw-menu-list">
          {tools.map((tool) => {
            const refusal = installBlockedReason(tool)
            return (
              <li key={tool.id} className="bw-scrape-tool">
                <span className="bw-scrape-row">
                  <span className="bw-menu-label">{tool.name}</span>
                  {tool.version !== '' && <span className="bw-badge">{tool.version}</span>}
                  <span className="bw-scrape-identity" data-identity={tool.identity}>
                    {tool.identity === 'verified' ? 'Verified' : 'Not verified'}
                  </span>
                  <span className="bw-spacer" />
                  {tool.installed ? (
                    <button type="button" className="bw-text-button" onClick={() => void remove(tool)}>
                      Remove
                    </button>
                  ) : (
                    /* Absent rather than disabled: an Install that cannot
                       install is a control that appears to work, and what is
                       underneath it is somebody else's code arriving on his
                       disk. The reason is on the row instead. */
                    canInstall(tool) && (
                      <button type="button" className="bw-primary" onClick={() => void install(tool)}>
                        Install
                      </button>
                    )
                  )}
                </span>
                {tool.publisher !== '' && <span className="bw-muted">{tool.publisher}</span>}
                {/* What it may reach, before it is on disk rather than after. */}
                <span className="bw-scrape-reach">{reachLine(tool)}</span>
                {refusal !== '' && <span className="bw-warn">{refusal}</span>}
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

/**
 * The same body, in the browser's own three-dot menu, inside a modal.
 *
 * A wrapper rather than a second panel. Until Settings grew a Scraping pane
 * this component *was* the body, and the split is deliberately the smallest one
 * that could exist: the modal owns the title bar and the close, and everything
 * a person reads or presses is {@link ScrapingBody}. Nothing was re-typed to be
 * moved, which is what makes *"exactly the same settings in both places"* a
 * property of the code rather than a promise about it — the failure mode the
 * settings window already names: *"when you reorganize you mostly miss the
 * things and you drop some stuff."*
 *
 * `canLift` is true here and only here: this surface has a page in front of it.
 */
export function ScrapingPanel({ open, onClose, ...rest }: Props) {
  return (
    <Modal open={open} title="Scraping" onClose={onClose} size="lg">
      <ScrapingBody live={open} canLift {...rest} />
    </Modal>
  )
}

/* ------------------------------------------------------------------ parts -- */

/**
 * A section's name, and whose settings are in it.
 *
 * The scope is on every head rather than once at the top because this panel
 * edits two kinds of setting on one screen: the fleet and the store belong to
 * the browser, and the rules, capture, assets and checks belong to the profile
 * named here. A per-profile setting whose screen does not say which profile is
 * how a scraping configuration gets set twice and lost once.
 */
function Head({
  title,
  scope,
  profileName,
}: {
  title: string
  scope: SettingScope
  profileName: string
}) {
  return (
    <h3 className="bw-history-heading">
      {title}
      <span className="bw-scrape-scope">{scopeLabel(scope, profileName)}</span>
    </h3>
  )
}

/**
 * A section whose seam this build does not have.
 *
 * Drawn, named and empty — never hidden, and never filled with disabled
 * controls. Hidden takes with it the knowledge that the capability exists at
 * all; disabled controls invite somebody to hunt for what would enable them.
 * One sentence saying what is missing is the honest middle.
 */
function Unavailable({ what }: { what: string }) {
  return <p className="bw-scrape-unwired">Not available here — {what}.</p>
}

/**
 * One value out of a few, drawn as pressed buttons.
 *
 * `null` is a fourth state and it shows as nothing pressed, which is the truth:
 * the engine did not say what this is set to. It is not drawn as the first
 * option being on, because that would be the panel deciding a setting on the
 * engine's behalf and then showing it back as fact.
 */
function Choice<T extends string>({
  label,
  value,
  options,
  onPick,
}: {
  label: string
  value: T | null
  options: readonly { value: T; label: string }[]
  onPick(next: T): void
}) {
  return (
    <span className="bw-scrape-choice" role="group" aria-label={label}>
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          className="bw-scrape-option"
          aria-pressed={value === option.value}
          data-on={value === option.value || undefined}
          onClick={() => onPick(option.value)}
        >
          {option.label}
        </button>
      ))}
    </span>
  )
}

/** A switch, as the same two-button choice, so "not set" can be shown at all. */
function OnOff({
  label,
  value,
  onPick,
}: {
  label: string
  value: boolean | null
  onPick(next: boolean): void
}) {
  return (
    <div className="bw-menu-row">
      <span className="bw-menu-label">{label}</span>
      <span className="bw-spacer" />
      {value === null && <span className="bw-badge">not set</span>}
      <Choice<'on' | 'off'>
        label={label}
        value={value === null ? null : value ? 'on' : 'off'}
        options={[
          { value: 'on', label: 'On' },
          { value: 'off', label: 'Off' },
        ]}
        onPick={(next) => onPick(next === 'on')}
      />
    </div>
  )
}

/**
 * A number held as text while it is being typed, committed when it is left.
 *
 * The same bargain `numberWhileTyping` makes in the settings controls, and for
 * the same reason: a field that writes on every keystroke and clamps on the way
 * in cannot be typed into — starting from 12 and typing 250 writes 2, which
 * clamps, which then eats the next digit.
 */
function NumberField({
  label,
  hint,
  value,
  min,
  max,
  onCommit,
}: {
  label: string
  hint: string
  value: number | null
  min: number
  max: number
  onCommit(next: number): void
}) {
  const [draft, setDraft] = useState('')

  // The stored value is the truth; the draft only exists between a keystroke and
  // leaving the field, so a value changed elsewhere still lands here.
  useEffect(() => {
    setDraft(value === null ? '' : String(value))
  }, [value])

  const commit = (): void => {
    const text = draft.trim()
    if (text === '') {
      setDraft(value === null ? '' : String(value))
      return
    }
    const next = Number(text)
    if (!Number.isFinite(next)) {
      setDraft(value === null ? '' : String(value))
      return
    }
    onCommit(Math.min(max, Math.max(min, Math.floor(next))))
  }

  return (
    <div className="bw-menu-row">
      <label className="bw-scrape-field">
        <span className="bw-scrape-field-label">{label}</span>
        <input
          className="bw-menu-input bw-scrape-number"
          type="number"
          min={min}
          max={max}
          value={draft}
          placeholder="not set"
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === 'Enter') commit()
          }}
        />
      </label>
      <span className="bw-muted">{hint}</span>
    </div>
  )
}

/** The same, for the two rewrite halves and the coverage pattern. */
function TextField({
  label,
  value,
  placeholder,
  onCommit,
}: {
  label: string
  value: string
  placeholder: string
  onCommit(next: string): void
}) {
  const [draft, setDraft] = useState(value)

  useEffect(() => {
    setDraft(value)
  }, [value])

  return (
    <label className="bw-scrape-field">
      <span className="bw-scrape-field-label">{label}</span>
      <input
        className="bw-menu-input"
        value={draft}
        spellCheck={false}
        placeholder={placeholder}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => {
          if (draft !== value) onCommit(draft)
        }}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && draft !== value) onCommit(draft)
        }}
      />
    </label>
  )
}
