import { useEffect, useMemo, useRef, useState } from 'react'
// Relative, not `@shared/brand`: vitest resolves no aliases, and a component a
// test can import is worth more than a shorter path — same form as AddAgentForm.
import { BRAND } from '../../shared/brand'
import './HooksOffer.css'

/**
 * The first-run offer: one strip, one obvious click, asked once per machine.
 *
 * Before this existed, a fresh install had working hooks only if somebody found
 * a pane inside Settings and pressed Install there — so on any machine that was
 * not a developer's, the boot context and every session-status verb reached no
 * session at all, forever, silently. The other pole is worse in a different
 * way: writing into `~/.claude/settings.json` at boot without asking is a
 * surprise in a dotfile the person owns. `src/main/hooks.ts` states the line
 * between the two above `readHookOffer`; this component is the asking half.
 *
 * Its promises, all kept by the main process rather than by renderer state:
 *
 *  - It only appears on a machine that is genuinely fresh — never beside an
 *    existing install, never for another copy of this app's hooks.
 *  - One press covers every installed assistant at once. The renderer never
 *    names a provider; main owns the list.
 *  - Either answer is remembered forever, "Not now" included. The Session
 *    updates page in the sidebar is where minds get changed later.
 *
 * Mounted in the sidebar's announcement slot beside `UpdateBanner`, and shaped
 * like it for the same reason: the app talking about itself must never block
 * the work, so this is a strip with two buttons, not a dialog with a focus
 * trap.
 */

/* ------------------------------------------------------------- the bridge -- */

/**
 * The slice of `window.deck` this strip needs. Names are the preload's own —
 * `contract.test.ts` checks every `*Bridge*` interface against what the preload
 * exposes, which is what keeps a near-miss from becoming a strip that draws and
 * does nothing.
 */
export interface HooksOfferBridge {
  hooksOffer(): Promise<unknown>
  hooksOfferAccept(): Promise<unknown>
  hooksOfferDecline(): Promise<unknown>
}

const BRIDGE_METHODS = ['hooksOffer', 'hooksOfferAccept', 'hooksOfferDecline'] as const

/**
 * All three methods or nothing. A bridge with `hooksOffer` but no
 * `hooksOfferAccept` would draw a "Turn it on" whose press goes nowhere —
 * the exact control-that-looks-like-it-works this app's rules name — so a
 * partial bridge draws no strip at all. Methods are called through their host
 * for the reason `settings-bridge.ts` gives: a preload with methods on a
 * prototype throws on `this` at the first press, and only in a packaged build.
 */
export function resolveOfferBridge(host?: unknown): HooksOfferBridge | null {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return null
  const record = source as Record<string, unknown>
  if (BRIDGE_METHODS.some((name) => typeof record[name] !== 'function')) return null
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as unknown as HooksOfferBridge
}

/* ---------------------------------------------------------- what comes back -- */

/** The slice of a `HookProviderStatus` this strip actually shows. */
export interface OfferProvider {
  id: string
  label: string
  file: string
}

/** What the strip needs from `hooks:offer`: who to cover, and what a yes cannot do. */
export interface Offer {
  providers: OfferProvider[]
  /**
   * Steps that stay the person's own after an accept — Codex's trust review is
   * the standing example. Kept so a clean accept can end by saying so rather
   * than hiding and claiming "on" for a CLI that will sit on untrusted hooks.
   */
  followUps: string[]
}

const NO_OFFER: Offer = { providers: [], followUps: [] }

/**
 * Narrow `hooks:offer` into the providers to draw, or none.
 *
 * Anything unreadable becomes an empty offer, which draws nothing. That is the
 * cheap failure direction: guessing wrong towards silence costs asking on a
 * later launch, guessing wrong the other way puts a button that writes into
 * somebody's dotfiles over an answer nobody could read.
 */
export function toOffer(raw: unknown): Offer {
  if (typeof raw !== 'object' || raw === null) return NO_OFFER
  const record = raw as { show?: unknown; eligible?: unknown; followUps?: unknown }
  if (record.show !== true || !Array.isArray(record.eligible)) return NO_OFFER
  const providers: OfferProvider[] = []
  for (const entry of record.eligible) {
    if (typeof entry !== 'object' || entry === null) continue
    const { id, label, file } = entry as { id?: unknown; label?: unknown; file?: unknown }
    if (typeof id !== 'string' || id === '') continue
    if (typeof label !== 'string' || label === '') continue
    if (typeof file !== 'string' || file === '') continue
    providers.push({ id, label, file })
  }
  const followUps = Array.isArray(record.followUps)
    ? record.followUps.filter((step): step is string => typeof step === 'string' && step !== '')
    : []
  return { providers, followUps }
}

/**
 * What a press of "Turn it on" left undone, as sentences, or none.
 *
 * An answer that cannot be read is reported as a failure rather than swallowed:
 * the installs may or may not have landed, and hiding the strip would claim
 * they did. The sentence points at the page that knows.
 */
export function toAcceptFailures(raw: unknown): string[] {
  if (!Array.isArray(raw)) {
    return [
      'The answer could not be read — the Session updates page in the sidebar shows what actually happened.',
    ]
  }
  const out: string[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const { ok, message } = entry as { ok?: unknown; message?: unknown }
    if (ok === true) continue
    out.push(
      typeof message === 'string' && message.trim() !== ''
        ? message.trim()
        : 'One install did not go through — the Session updates page in the sidebar has the state.',
    )
  }
  return out
}

/* ------------------------------------------------------------------- words -- */

/** The one line at the top. Singular when there is one assistant to cover. */
export function offerHeadline(count: number): string {
  return count === 1
    ? 'Let tabs say what your assistant is doing'
    : 'Let tabs say what your assistants are doing'
}

/**
 * The one sentence the strip is entitled to: what it wants to add, and why.
 * No provider is named — the button's hover carries the actual files, which is
 * the moment a path is worth reading.
 */
export function offerDetail(count: number): string {
  const where =
    count === 1
      ? "your assistant's own settings file"
      : "each installed assistant's own settings file"
  const files = count === 1 ? 'the file' : 'those files'
  return `One press adds ${BRAND.name}'s session hooks to ${where}, so a tab can show working, waiting for you, or done — nothing else in ${files} is touched.`
}

/** The hover on the button that writes: which files, exactly. */
export function writesTitle(providers: readonly OfferProvider[]): string {
  return `Writes ${providers.map((provider) => provider.file).join(' and ')}`
}

/** The promise "Not now" makes, spelled out where the press happens. */
export const NOT_NOW_TITLE =
  'Never asks again. The Session updates page in the sidebar can turn this on later.'

/**
 * The headline after a clean accept that still has a step only the person can
 * take. "On" would be a small lie — the hooks are written, and one CLI will not
 * run them until its own review is answered.
 */
export const FOLLOW_UP_TITLE = 'Turned on — one step is still yours'

/* -------------------------------------------------------------- the actions -- */

export type OfferBusy = 'accept' | 'decline' | null

export interface HooksOfferActions {
  /** Install into every eligible assistant at once. The whole of the offer. */
  accept(): void
  /** Record "no", forever. */
  decline(): void
  /** Drawn only after a failed accept: clears the strip for this run. */
  dismiss(): void
}

export interface OfferActionDeps {
  bridge: HooksOfferBridge
  /** The steps a clean accept still leaves to the person, from the offer. */
  followUps: readonly string[]
  setBusy(busy: OfferBusy): void
  setFailures(failures: string[]): void
  /** Swap the ask for the steps only the person can take. */
  showFollowUps(): void
  /** Take the strip off screen for good (this run). */
  hide(): void
  /** Is the component still mounted? Replies can outlive the shell. */
  alive(): boolean
}

/**
 * The three presses, as a plain function of their dependencies — pulled out of
 * the component because no effect or click ever runs in this repo's test
 * environment, and two of these write into a person's dotfiles.
 *
 * What is pinned: accept hides the strip only when every install reported ok
 * *and* nothing is left for the person to do — a clean accept that covered a
 * CLI with its own trust step ends by saying so, and failures are reported
 * rather than swallowed. Decline hides the strip even if recording the answer
 * failed, because the worst of that is the strip returning next launch with a
 * working button — a "Not now" that visibly did nothing would be worse.
 */
export function offerActions(deps: OfferActionDeps): HooksOfferActions {
  const { bridge, followUps, setBusy, setFailures, showFollowUps, hide, alive } = deps
  return {
    accept: () => {
      setBusy('accept')
      void bridge
        .hooksOfferAccept()
        .then((raw) => {
          if (!alive()) return
          const failures = toAcceptFailures(raw)
          if (failures.length > 0) setFailures(failures)
          else if (followUps.length > 0) showFollowUps()
          else hide()
        })
        .catch((cause: unknown) => {
          if (!alive()) return
          setFailures([cause instanceof Error ? cause.message : String(cause)])
        })
        .finally(() => {
          if (alive()) setBusy(null)
        })
    },
    decline: () => {
      setBusy('decline')
      void bridge
        .hooksOfferDecline()
        .catch(() => {
          // Recorded or not, the person said no: the strip goes. If the marker
          // write failed, main logged it and the strip returns next launch.
        })
        .finally(() => {
          if (alive()) {
            setBusy(null)
            hide()
          }
        })
    },
    dismiss: () => hide(),
  }
}

/* --------------------------------------------------------------- the view -- */

export interface HooksOfferViewProps {
  providers: readonly OfferProvider[]
  busy: OfferBusy
  /** Sentences from a press that did not fully land; empty before any press. */
  failures: readonly string[]
  /**
   * Non-empty only after a clean accept that left steps to the person; the
   * view then draws those instead of the ask. Passed by the container, which
   * holds them back until that moment — this stays a pure function of props.
   */
  followUps?: readonly string[]
  actions: HooksOfferActions
}

export function HooksOfferView({
  providers,
  busy,
  failures,
  followUps = [],
  actions,
}: HooksOfferViewProps) {
  if (providers.length === 0) return null

  if (followUps.length > 0) {
    // The installs landed; what is left is the part only the person can do,
    // in the main process's own words. Verbatim for the reason UpdateBanner
    // keeps the updater's sentences verbatim: the module that knows keeps the
    // sentence, and a paraphrase here goes stale the day it changes.
    return (
      <aside className="hoffer" aria-label="Session updates">
        <div className="hoffer-text" role="status">
          <span className="hoffer-title">{FOLLOW_UP_TITLE}</span>
          {followUps.map((step) => (
            <span key={step} className="hoffer-detail">
              {step}
            </span>
          ))}
        </div>
        <div className="hoffer-actions">
          <button type="button" className="hoffer-quiet" onClick={actions.dismiss}>
            Dismiss
          </button>
        </div>
      </aside>
    )
  }

  return (
    <aside className="hoffer" aria-label="Session updates">
      {/* The live region is the text alone, as on UpdateBanner: a region
          around the buttons would announce their labels over whatever the
          person is reading every time one changes to its busy form. */}
      <div className="hoffer-text" role="status">
        <span className="hoffer-title">{offerHeadline(providers.length)}</span>
        <span className="hoffer-detail">{offerDetail(providers.length)}</span>
        {failures.map((failure) => (
          <span key={failure} className="hoffer-failure">
            {failure}
          </span>
        ))}
      </div>

      <div className="hoffer-actions">
        {failures.length === 0 ? (
          <>
            <button
              type="button"
              className="hoffer-btn"
              data-tone="primary"
              disabled={busy !== null}
              // The paths, at the moment they matter: this press writes into
              // the person's own configuration, and the hover says exactly
              // which files — same move as the install button on HooksPanel.
              title={writesTitle(providers)}
              onClick={actions.accept}
            >
              {busy === 'accept' ? 'Turning on…' : 'Turn it on'}
            </button>
            <button
              type="button"
              className="hoffer-quiet"
              disabled={busy !== null}
              title={NOT_NOW_TITLE}
              onClick={actions.decline}
            >
              Not now
            </button>
          </>
        ) : (
          // After a failed accept there is nothing left for this strip to do
          // that the Session updates page does not do better; the answer is
          // already recorded, so this clears the screen rather than re-offering
          // a press that just failed.
          <button type="button" className="hoffer-quiet" onClick={actions.dismiss}>
            Dismiss
          </button>
        )}
      </div>
    </aside>
  )
}

/* ---------------------------------------------------------- the component -- */

interface Props {
  /** Defaults to `window.deck`. Passed by tests, and by nothing else. */
  bridge?: HooksOfferBridge | null
}

export function HooksOffer({ bridge: provided }: Props) {
  const bridge = useMemo(
    () => (provided === undefined ? resolveOfferBridge() : provided),
    [provided],
  )

  const [offer, setOffer] = useState<Offer>(NO_OFFER)
  const [busy, setBusy] = useState<OfferBusy>(null)
  const [failures, setFailures] = useState<string[]>([])
  /** The offer's follow-ups, released to the view only by a clean accept. */
  const [followUps, setFollowUps] = useState<string[]>([])
  const [hidden, setHidden] = useState(false)

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  /*
   * One read, on mount, and no poll. The verdict can only change through this
   * strip's own two buttons or through the Session updates page — and a person
   * on that page has already found the consent surface this strip exists to
   * put in front of them, so racing them for it buys nothing.
   */
  useEffect(() => {
    if (bridge === null) return
    let live = true
    void bridge
      .hooksOffer()
      .then((raw) => {
        if (live && alive.current) setOffer(toOffer(raw))
      })
      .catch(() => {
        // Silence. A strip whose whole purpose is a favor must not open with a
        // complaint about its own plumbing; the Session updates page reports
        // hook state with room to explain itself.
      })
    return () => {
      live = false
    }
  }, [bridge])

  if (bridge === null || hidden) return null

  const actions = offerActions({
    bridge,
    followUps: offer.followUps,
    setBusy,
    setFailures,
    showFollowUps: () => setFollowUps(offer.followUps),
    hide: () => setHidden(true),
    alive: () => alive.current,
  })

  return (
    <HooksOfferView
      providers={offer.providers}
      busy={busy}
      failures={failures}
      followUps={followUps}
      actions={actions}
    />
  )
}
