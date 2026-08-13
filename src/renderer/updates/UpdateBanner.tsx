import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { renderMarkdown } from '../components/ChatView'
import { errorText } from '../settings/settings-bridge'
import './UpdateBanner.css'

/**
 * The in-app update prompt — a strip in the app shell, not a dialog.
 *
 * What is on the other side of the last button is a **restart**. A session here
 * is a live pty with a real turn possibly running in it, and quitting the app
 * kills every one of them. So the shape of this component is set by that fact
 * rather than by how visible an update ought to be:
 *
 *   - It never blocks. It is a bar in the flow of the shell, above the body, so
 *     it pushes the workspace down by its own height and covers nothing. There
 *     is no overlay, no focus trap and no Escape handler — an update must never
 *     be the reason a keystroke did not reach a terminal.
 *   - Nothing installs itself. `updater.ts` sets `autoDownload = false`, and
 *     every state past "an update exists" is something the user pressed here.
 *     The press that ends the app says "Restart", not "Update", because that is
 *     the part that costs them something.
 *   - It can be dismissed, and the dismissal lasts exactly one run of the app.
 *     "Always there when we ship an update" and "gets out of my way while I
 *     work" are both true this way: it goes when you say so, and it is back the
 *     next time the app starts as long as the update is still pending.
 *   - It claims nothing a call returned. Everything drawn here comes from a
 *     state the main process reported.
 *
 * ## Why the dismissal is keyed rather than a boolean
 *
 * A single "hidden" flag would swallow the next thing the updater had to say.
 * Dismissing the offer for 0.2.0 has to keep the bar shut for 0.2.0's download
 * — that progress bar is the same news twice — and has to let "Restart to
 * finish" through, because a downloaded update is a different sentence and the
 * only one that ever asks for the restart. So what is stored is *which* state
 * was dismissed (`dismissKey`), and the bar returns by itself the moment the
 * updater moves on to something else. Nothing has to remember to clear a flag.
 *
 * ## Why the rendering is split from the fetching
 *
 * `UpdateBannerView` takes everything it draws. `renderToStaticMarkup` never
 * runs an effect, so a component that read its own status would be testable in
 * exactly one state — the empty one — and the five that matter here are the
 * others. Same arrangement as `RemoteSection`, for the same reason.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Everything this banner needs from `window.deck`.
 *
 * The names are the preload's, not this file's preference: `contract.test.ts`
 * matches these strings against what the preload exposes, and a near miss draws
 * nothing at all rather than failing loudly. The four calls map to the four
 * `update:*` channels `registerUpdateIpc` registers, and every one of those is
 * `ipcMain.handle` — so every one is `invoke`, and a press that used `send`
 * would be routed nowhere in silence.
 *
 * `onUpdateState` carries `update:state`, which the main process pushes on
 * every transition it makes. That is the source, not a hint to re-read: a
 * progress tick answered by a second round trip would arrive after the download
 * had moved on. `updateStatus` exists for the one moment the push cannot cover
 * — this component mounting after the state was set.
 *
 * `appAbout` is already exposed and is only read to find the releases page for
 * a build that cannot update itself. See `releasesUrlFor`.
 */
export interface UpdateBridge {
  updateStatus(): Promise<unknown>
  checkForUpdate(): Promise<unknown>
  downloadUpdate(): Promise<unknown>
  installUpdate(): Promise<unknown>
  onUpdateState(callback: (state: unknown) => void): () => void
  appAbout(): Promise<unknown>
}

const BRIDGE_METHODS: ReadonlyArray<keyof UpdateBridge> = [
  'updateStatus',
  'checkForUpdate',
  'downloadUpdate',
  'installUpdate',
  'onUpdateState',
  'appAbout',
]

/**
 * The channels this build does not have.
 *
 * `updateStatus` alone is enough to draw the whole bar, and every button whose
 * channel is missing would then report a cheerful success for a call that was
 * never made — an "Update" press that downloads nothing, a "Restart" that never
 * arrives. So the gaps are named on the bar itself, and the actions below reject
 * rather than resolve.
 */
export function missingUpdateMethods(bridge: Partial<UpdateBridge>): Array<keyof UpdateBridge> {
  return BRIDGE_METHODS.filter((name) => typeof bridge[name] !== 'function')
}

/**
 * The bridge as it actually exists, with each method called through its host.
 *
 * `globalThis` rather than `window` because this file is rendered to a string in
 * its own tests, where there is no `window` to read. Methods are wrapped rather
 * than copied for the reason `settings-bridge.ts` gives: a preload that puts its
 * functions on a prototype throws on `this` the first time a button is pressed,
 * and that failure only ever shows up in a packaged build.
 */
export function resolveUpdateBridge(host?: unknown): Partial<UpdateBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<UpdateBridge>
}

/* -------------------------------------------------------------------------- */
/* What comes back                                                             */
/* -------------------------------------------------------------------------- */

/**
 * Mirrors `UpdateState` in `src/main/updates/updater.ts`.
 *
 * Duplicated rather than imported because the renderer tsconfig does not include
 * `src/main` — the arrangement `SessionInspector`, `GitPanel` and `ChatView`
 * already use.
 *
 * Two fields are *wider* here than in the original, and deliberately so. Over
 * there `version` is a `string` and `percent` a `number`, and both are true of
 * the values that module constructs. On this side they have crossed an IPC
 * boundary carrying figures a network feed supplied, and this file's job is to
 * prove them rather than assume them. `settings-bridge.ts` makes the same move
 * with `AboutInfo.updates`, which is non-null in the main process and nullable
 * in its mirror.
 *
 * `unsupported` is a phase and not an error. A build that cannot update itself
 * — unsigned, or packaged with no feed — has nothing wrong with it; it has a
 * manual path instead of a button, and calling that a failure would send people
 * looking for something to fix.
 */
export type UpdateState =
  | { phase: 'idle'; checkedAt: number | null }
  | { phase: 'checking' }
  | { phase: 'available'; version: string | null; notes: string | null; sizeBytes: number | null }
  | { phase: 'downloading'; version: string | null; percent: number | null; bytesPerSecond: number | null }
  | { phase: 'ready'; version: string | null }
  | { phase: 'error'; message: string }
  | { phase: 'unsupported'; reason: string }

/** Nothing to say. Also what an unreadable answer becomes. */
export const NO_UPDATE: UpdateState = { phase: 'idle', checkedAt: null }

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function asText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * Narrow `update:get` and every pushed state into the union above.
 *
 * A phase this build does not recognise becomes `idle`, which draws nothing, and
 * so does an `error` or `unsupported` that arrived with no sentence in it — both
 * of those phases are *entirely* their sentence, and a red strip saying nothing
 * is worse than no strip.
 *
 * The asymmetry is deliberate. Guessing wrong towards silence costs a user an
 * update they will be offered again at the next check; guessing wrong the other
 * way puts a Restart button — which kills every running session — over an answer
 * nobody could read.
 */
export function toUpdateState(raw: unknown): UpdateState {
  const record = asRecord(raw)
  if (!record) return NO_UPDATE
  switch (record.phase) {
    case 'checking':
      return { phase: 'checking' }
    case 'available':
      return {
        phase: 'available',
        version: asText(record.version),
        notes: asText(record.notes),
        sizeBytes: asNumber(record.sizeBytes),
      }
    case 'downloading':
      return {
        phase: 'downloading',
        version: asText(record.version),
        percent: asNumber(record.percent),
        bytesPerSecond: asNumber(record.bytesPerSecond),
      }
    case 'ready':
      return { phase: 'ready', version: asText(record.version) }
    case 'error': {
      const message = asText(record.message)
      return message === null ? NO_UPDATE : { phase: 'error', message }
    }
    case 'unsupported': {
      const reason = asText(record.reason)
      return reason === null ? NO_UPDATE : { phase: 'unsupported', reason }
    }
    default:
      return { phase: 'idle', checkedAt: asNumber(record.checkedAt) }
  }
}

/* -------------------------------------------------------------------------- */
/* Numbers that are shown to people                                            */
/* -------------------------------------------------------------------------- */

/**
 * How far along the download is, or null when nothing readable says.
 *
 * Three ways this has produced `NaN%` and `104%` on screen, all guarded here:
 * the feed sends no percent at all and the arithmetic is `NaN`; it sends one
 * slightly over 100 on the last tick, because the bytes it counted include some
 * the stated total never did; or it sends a negative on the first.
 *
 * A download, unlike the context meter in `UsageStrip`, cannot honestly exceed
 * its own size, so the *label* is clamped here as well as the bar. 104% is not
 * a fact about the download; it is a fact about the feed.
 *
 * The finiteness check is not a duplicate of `toUpdateState`'s. The type here is
 * `number | null`, and `NaN` is a number — TypeScript cannot say "finite", so
 * every arithmetic path that reaches a screen has to. `Math.max(0, NaN)` is
 * `NaN`, which is how `NaN%` gets printed by code that looks like it clamps.
 */
export function percentOf(percent: number | null): number | null {
  if (percent === null || !Number.isFinite(percent)) return null
  return Math.min(100, Math.max(0, percent))
}

/**
 * The percentage as text. Floored, not rounded: 99.6% rounds to "100%", and a
 * bar reading 100% while it is still downloading is the one number on this strip
 * somebody might act on, by waiting for something that already happened.
 */
export function percentText(percent: number | null): string | null {
  const clamped = percentOf(percent)
  return clamped === null ? null : `${Math.floor(clamped)}%`
}

const UNITS = ['B', 'KB', 'MB', 'GB'] as const

/** Bytes for humans, or null when the number was not one. Negatives included. */
export function formatBytes(value: number | null): string | null {
  if (value === null || !Number.isFinite(value) || value < 0) return null
  let size = value
  let unit = 0
  while (size >= 1024 && unit < UNITS.length - 1) {
    size /= 1024
    unit += 1
  }
  // One decimal only where it distinguishes anything: "1.4 MB" is useful,
  // "1.4 B" is noise and "1408.0 KB" is a number nobody reads.
  return `${unit > 0 && size < 10 ? size.toFixed(1) : Math.round(size)} ${UNITS[unit]}`
}

/**
 * The download rate, or null.
 *
 * Zero is dropped rather than printed. `updater.ts` opens the `downloading`
 * state with `bytesPerSecond: 0` before the first progress event lands, and
 * "0 B/s" beside a moving bar reads as a stalled download rather than as one
 * that has not been measured yet.
 */
export function formatRate(bytesPerSecond: number | null): string | null {
  if (bytesPerSecond === null || bytesPerSecond <= 0) return null
  const size = formatBytes(bytesPerSecond)
  return size === null ? null : `${size}/s`
}

/* -------------------------------------------------------------------------- */
/* The manual path                                                             */
/* -------------------------------------------------------------------------- */

function repositoryOf(about: unknown): string | null {
  return asText(asRecord(about)?.repository)
}

/**
 * Where to download a build by hand, derived from the repository this app
 * records for itself.
 *
 * The main process does not send a URL — `updateSupport`'s sentences say
 * "Download the new version from Releases" and stop there — so it is built here
 * from `appAbout().repository`, which `settings-extra.ts` has already normalised
 * out of whatever shorthand `package.json` used.
 *
 * GitHub only, on purpose. `/releases` is GitHub's path; GitLab's is
 * `/-/releases` and a self-hosted remote has whatever its owner chose. A link
 * that 404s is worse than no link, and the sentence above it already says where
 * to go — so anything else resolves to null and the strip simply has no link.
 *
 * `AboutSection.tsx` has a private twin of this reaching the same verdict by the
 * same reasoning. Two copies of one derivation is one too many, and the reason
 * this is not the fix is scope: the shared home for it is neither of these
 * files, and About's own header still has to be corrected in the same pass —
 * see the handoff.
 *
 * The two are not identical, and where they differ is worth writing down rather
 * than rounding off. Both were run against the same inputs:
 *
 *   - `https://www.github.com/o/r` — the twin returns null, this returns a link.
 *   - `https://github.com/o/r//`   — the twin keeps one of the slashes
 *     (`…/r//releases`), this strips them all.
 *
 * Neither input can reach either function today: both are fed
 * `repositoryUrl()`, which normalises this package.json's
 * `https://github.com/asadev/terminaldeck.git` to a bare `github.com` URL with
 * no trailing slash. So the About panel and this strip cannot disagree on any
 * value that actually occurs — but they are two derivations, not one, and the
 * day a repository field carries a `www.` they will say different things.
 */
export function releasesUrlFor(repository: string | null): string | null {
  if (repository === null) return null
  let host: string
  try {
    const parsed = new URL(repository)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    host = parsed.hostname.toLowerCase()
  } catch {
    return null
  }
  if (host !== 'github.com' && host !== 'www.github.com') return null
  return `${repository.replace(/\/+$/, '')}/releases`
}

/* -------------------------------------------------------------------------- */
/* Dismissal                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * What dismissing *this* state hides.
 *
 * `available` and `downloading` share a key on purpose. Pressing Update and then
 * clearing the strip out of the way must not have the progress bar slide back in
 * a second later saying the same thing.
 *
 * `ready` gets its own key, because it is the only state that asks for the
 * restart. An error is keyed by its own sentence, so a *different* failure gets
 * through — dismissing "could not reach the feed" must not also silence "the
 * signature did not match".
 *
 * Null for the states that draw nothing: there is no dismissing a strip that is
 * not on screen, and storing a key for one would silence whatever came next.
 */
export function dismissKey(state: UpdateState): string | null {
  switch (state.phase) {
    case 'available':
    case 'downloading':
      return `offer:${state.version ?? 'unknown'}`
    case 'ready':
      return `ready:${state.version ?? 'unknown'}`
    case 'error':
      return `error:${state.message}`
    case 'unsupported':
      // No version and no reason: why this build cannot update itself is a
      // property of the build, and it is the same answer for every release
      // behind it. Dismissing it once should hold for the run.
      return 'unsupported'
    case 'idle':
    case 'checking':
      return null
  }
}

/** Whether what is on screen right now is the thing that was dismissed. */
export function isDismissed(state: UpdateState, dismissed: string | null): boolean {
  if (dismissed === null) return false
  const key = dismissKey(state)
  return key !== null && key === dismissed
}

/**
 * Where a dismissal is remembered.
 *
 * Deliberately `sessionStorage` and deliberately not a preference: the promise
 * the Dismiss button makes is "until the app is next started", and that is
 * exactly the lifetime of this store. A preference would outlive the launch and
 * quietly turn one dismissal into a permanent opt-out of updates; component
 * state alone would lose it if the shell remounted, and the strip would spring
 * back while the user watched.
 */
export interface DismissStore {
  read(): string | null
  write(key: string | null): void
}

export const DISMISS_STORAGE_KEY = 'terminaldeck.updates.dismissed'

/**
 * Remembering a dismissal: the component's state and the store, in that order.
 *
 * Pulled out of the component for the same reason `updateActions` is. A
 * `useCallback` body never runs in this repo's test environment — there is no
 * DOM, so no effect and no press — and the line that matters here is the one
 * that outlives a remount. Deleting `store.write` from inside the component left
 * every test in this file green while dismissals silently stopped surviving a
 * reload of the window; as a function it is pinned by a test that calls it.
 *
 * The store is optional and its absence is not a failure: a renderer whose
 * storage is blocked still gets a dismissal that holds for this render, and a
 * banner that forgot one comes back next launch, which is what it does anyway.
 */
export function rememberDismissal(
  setDismissed: (key: string | null) => void,
  store: DismissStore | null,
): (key: string | null) => void {
  return (key) => {
    setDismissed(key)
    store?.write(key)
  }
}

/**
 * The session store, or null where there is not one.
 *
 * Both failure modes are real and neither throws out of here: this file is
 * rendered to a string in its own tests, where there is no DOM at all, and a
 * renderer whose storage has been blocked by policy throws on the *access*
 * rather than returning null. A banner that could not remember a dismissal is a
 * banner that comes back next launch, which is what it does anyway.
 */
export function sessionDismissStore(): DismissStore | null {
  try {
    if (typeof globalThis.sessionStorage === 'undefined') return null
    const host = globalThis.sessionStorage
    return {
      read: () => {
        try {
          return host.getItem(DISMISS_STORAGE_KEY)
        } catch {
          return null
        }
      },
      write: (key) => {
        try {
          if (key === null) host.removeItem(DISMISS_STORAGE_KEY)
          else host.setItem(DISMISS_STORAGE_KEY, key)
        } catch {
          // A dismissal that could not be written still holds through component
          // state for this run. Nothing here is worth an exception.
        }
      },
    }
  } catch {
    return null
  }
}

/* -------------------------------------------------------------------------- */
/* Words                                                                       */
/* -------------------------------------------------------------------------- */

/**
 * The one line at the top of the strip.
 *
 * Never invents a version number. An update whose version did not survive the
 * trip gets "A new version is available", because a made-up number on this
 * strip is the kind of thing that ends up in a bug report.
 */
export function headline(state: UpdateState): string {
  switch (state.phase) {
    case 'available':
      return state.version ? `Version ${state.version} is available` : 'A new version is available'
    case 'downloading':
      return state.version ? `Downloading version ${state.version}` : 'Downloading the update'
    case 'ready':
      return state.version ? `Version ${state.version} is downloaded` : 'The update is downloaded'
    case 'error':
      return 'That update did not go through'
    case 'unsupported':
      return 'This build cannot update itself'
    case 'idle':
    case 'checking':
      return ''
  }
}

/** The second line: what else is known about this state, or null. */
export function detail(state: UpdateState): string | null {
  switch (state.phase) {
    case 'available': {
      const size = formatBytes(state.sizeBytes)
      return size === null ? null : `${size} download`
    }
    case 'downloading': {
      const parts = [percentText(state.percent), formatRate(state.bytesPerSecond)].filter(
        (part): part is string => part !== null,
      )
      // Reachable: a feed reporting neither a percent nor a rate. The bar goes
      // indeterminate and this says why, rather than showing "0%" for a
      // download that is moving.
      return parts.length > 0 ? parts.join(' · ') : 'Started — the feed is not reporting progress.'
    }
    case 'ready':
      return 'Restart to finish. Every session running in this window is closed when it does.'
    // Verbatim, both of them. The main process is the only thing that knows
    // which of these it is looking at, and `updater.ts` keeps those sentences in
    // one place precisely so each says what to do — a paraphrase written here
    // would go stale the first time one of them changed.
    case 'error':
      return state.message
    case 'unsupported':
      return state.reason
    case 'idle':
    case 'checking':
      return null
  }
}

/* -------------------------------------------------------------------------- */
/* Release notes                                                               */
/* -------------------------------------------------------------------------- */

/**
 * What the feed says changed, collapsed until asked for.
 *
 * These notes are **remote content** — the body of a GitHub release, which
 * `readNotes` in `updater.ts` hands over as text with its own comment saying the
 * renderer must not turn it into markup. This is an Electron renderer, so they
 * go down the single audited path this app has for text it did not write:
 * `renderMarkdown` in `ChatView`, which parses with the renderer that strips
 * `href` off links and refuses to emit `img`, then hands the result to DOMPurify
 * with an allow-list.
 *
 * Imported rather than copied. A second sanitiser is a second thing to keep
 * correct, and the specific failure it invites is silent: `renderMarkdown`
 * returns null when DOMPurify is not initialised, and a copy that read that as
 * "nothing to clean" would put raw feed HTML through `dangerouslySetInnerHTML`.
 * Null here means exactly what it means there — fall back to plain text.
 */
function Notes({ notes }: { notes: string }) {
  const html = useMemo(() => renderMarkdown(notes), [notes])
  return (
    <details className="upd-notes">
      <summary>What changed</summary>
      {html === null ? (
        <div className="upd-notes-body upd-notes-plain">{notes}</div>
      ) : (
        <div className="upd-notes-body" dangerouslySetInnerHTML={{ __html: html }} />
      )}
    </details>
  )
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/** Which press is in flight, so only that button goes busy. */
export type UpdateBusy = 'update' | 'restart' | 'retry' | null

export interface UpdateActions {
  /** Start the download. Never called by anything but a press. */
  update(): void
  /** Quit and install. This ends every session running in this window. */
  restart(): void
  retry(): void
  dismiss(): void
}

export interface UpdateBannerViewProps {
  state: UpdateState
  /**
   * Where to get a build by hand, for a build that cannot update itself. Null
   * until it is known, and null forever when the repository is not one whose
   * releases URL can be derived.
   */
  releasesUrl?: string | null
  /**
   * Channels this build is missing while still exposing enough to draw the
   * strip. Named on screen, because a button whose channel is absent must not
   * look like a button that works.
   */
  missing?: ReadonlyArray<keyof UpdateBridge>
  busy: UpdateBusy
  /** Why the last press did not go through. */
  notice: string | null
  actions: UpdateActions
}

export function UpdateBannerView({
  state,
  releasesUrl = null,
  missing = [],
  busy,
  notice,
  actions,
}: UpdateBannerViewProps) {
  // Nothing to say. Not an empty bar and not a "checking for updates…" strip:
  // this sits above the workspace on every launch, and a line that appears for
  // two seconds and pushes the terminal down is worse than silence.
  if (state.phase === 'idle' || state.phase === 'checking') return null

  const percent = state.phase === 'downloading' ? percentOf(state.percent) : null
  const line = detail(state)

  return (
    // The live region is the two lines of text, not the whole strip. A
    // `role="status"` on the container puts the buttons, the release notes and
    // the progress bar inside it too, and the main process pushes one state per
    // whole percent — so a download would re-announce "Downloading version
    // 0.2.0 42% · 3.2 MB/s Update Dismiss" a hundred times over a session
    // somebody is trying to read.
    <aside className="upd-banner" data-phase={state.phase} aria-label="Update">
      <div className="upd-row">
        <div className="upd-text" role="status">
          <span className="upd-title">{headline(state)}</span>
          {line && (
            <span
              className="upd-detail"
              // Opted out of the region above for the one phase that changes on
              // a timer. The figure is not lost: the progress bar below carries
              // it as `aria-valuenow`, which assistive technology reports when
              // it is asked rather than announcing it over everything else.
              aria-live={state.phase === 'downloading' ? 'off' : undefined}
            >
              {line}
            </span>
          )}

          {state.phase === 'unsupported' && releasesUrl && (
            <span className="upd-detail">
              {/* The manual path, and the only one this build has. The main
                  process turns window.open into the real browser. */}
              <a className="upd-link" href={releasesUrl} target="_blank" rel="noreferrer">
                Download it from the releases page
              </a>
            </span>
          )}
        </div>

        <div className="upd-actions">
          {state.phase === 'available' && (
            <button
              type="button"
              className="upd-btn"
              data-tone="primary"
              disabled={busy !== null}
              onClick={actions.update}
            >
              {busy === 'update' ? 'Starting…' : 'Update'}
            </button>
          )}

          {state.phase === 'ready' && (
            <button
              type="button"
              className="upd-btn"
              data-tone="primary"
              disabled={busy !== null}
              onClick={actions.restart}
            >
              {busy === 'restart' ? 'Restarting…' : 'Restart to finish'}
            </button>
          )}

          {state.phase === 'error' && (
            <button
              type="button"
              className="upd-btn"
              disabled={busy !== null}
              onClick={actions.retry}
            >
              {busy === 'retry' ? 'Trying again…' : 'Try again'}
            </button>
          )}

          <button
            type="button"
            className="upd-dismiss"
            // The promise the button makes, spelled out: this is not "never
            // show me this again", and nothing here turns updates off.
            title="Hides this until the app is started again."
            onClick={actions.dismiss}
          >
            Dismiss
          </button>
        </div>
      </div>

      {state.phase === 'downloading' && (
        <div
          className="upd-progress"
          role="progressbar"
          aria-label="Update download"
          aria-valuemin={0}
          aria-valuemax={100}
          // Omitted, not zeroed, when the feed reports nothing readable: a
          // screen reader announcing "0 percent" over a moving download is a
          // worse answer than one announcing "busy".
          aria-valuenow={percent === null ? undefined : Math.floor(percent)}
        >
          <div
            className="upd-progress-fill"
            data-indeterminate={percent === null ? 'true' : undefined}
            style={percent === null ? undefined : { width: `${percent}%` }}
          />
        </div>
      )}

      {state.phase === 'available' && state.notes && <Notes notes={state.notes} />}

      {missing.length > 0 && (
        // Half-wired is worse than unwired, because it looks like it works.
        <p className="upd-note upd-note-bad">
          This build is missing {missing.length} of the update channels ({missing.join(', ')}).
          Anything that needs one will say so rather than appear to have worked.
        </p>
      )}

      {notice && <p className="upd-note upd-note-bad">{notice}</p>}
    </aside>
  )
}

/* -------------------------------------------------------------------------- */
/* Calling the main process                                                    */
/* -------------------------------------------------------------------------- */

function missingChannel(name: string): Error {
  return new Error(
    `This build has no ${name} channel, so nothing happened. Updates are only half wired into it.`,
  )
}

/**
 * Call a bridge method, or reject.
 *
 * The obvious shorthand — `bridge.installUpdate?.() ?? Promise.resolve()` —
 * turns a channel that does not exist into a resolved promise, and the strip
 * then sits there having "restarted" an app that is still running. A missing
 * channel is a broken build, and it has to arrive as a failure.
 */
function invoke(method: (() => Promise<unknown>) | undefined, name: string): Promise<unknown> {
  return typeof method === 'function' ? method() : Promise.reject(missingChannel(name))
}

/* -------------------------------------------------------------------------- */
/* The actions                                                                 */
/* -------------------------------------------------------------------------- */

export interface UpdateActionDeps {
  bridge: Partial<UpdateBridge>
  /** The state the buttons are being pressed against. */
  state: UpdateState
  /** Remembers which state was dismissed. Null clears it. */
  setDismissed(key: string | null): void
  /** Runs the work and reports a failure in the main process's words. */
  run(key: Exclude<UpdateBusy, null>, work: () => Promise<unknown>): void
}

/**
 * The four buttons, as a plain function of their dependencies.
 *
 * Split out of the component on purpose. There is no DOM in this repo's test
 * environment, so anything left inside a `useState` closure is reachable by
 * nothing but a person pressing it in a packaged build — and one of these four
 * quits the app out from under every running session. Pulled out here, the
 * dangerous parts are pinned: that Update downloads and does not install, that
 * only Restart calls the channel that ends the process, and that a call which
 * never happened is never reported as one that did.
 */
export function updateActions(deps: UpdateActionDeps): UpdateActions {
  const { bridge, state, setDismissed, run } = deps
  return {
    // Download only. Installing from here would restart the app on a press
    // whose label said "Update", which is not what that word promises.
    update: () => run('update', () => invoke(bridge.downloadUpdate, 'download update')),
    restart: () => run('restart', () => invoke(bridge.installUpdate, 'install update')),
    // A re-check, whatever failed. `updater.ts` reports an error as a sentence
    // and nothing else — there is no field saying which call it came from — so
    // retrying the download of an update that may never have been found would
    // be a guess. A check is the honest superset: it lands back on `available`
    // if the release is still there, one press from the download.
    retry: () => run('retry', () => invoke(bridge.checkForUpdate, 'check for updates')),
    dismiss: () => setDismissed(dismissKey(state)),
  }
}

/* -------------------------------------------------------------------------- */
/* The banner                                                                  */
/* -------------------------------------------------------------------------- */

interface Props {
  /** Defaults to `window.deck`. Passed in by tests, and by nothing else. */
  bridge?: Partial<UpdateBridge>
  /** Defaults to the session store. Passed in by tests, and by nothing else. */
  store?: DismissStore | null
}

export function UpdateBanner({ bridge: provided, store: providedStore }: Props) {
  // Resolved once. `resolveUpdateBridge` builds a new object every call, and an
  // unstable bridge would tear down and re-establish the push subscription on
  // every render of the shell.
  const bridge = useMemo(() => provided ?? resolveUpdateBridge(), [provided])
  const wired = typeof bridge.updateStatus === 'function'
  const missing = useMemo(() => (wired ? missingUpdateMethods(bridge) : []), [bridge, wired])

  const [state, setState] = useState<UpdateState>(NO_UPDATE)
  const [dismissed, setDismissed] = useState<string | null>(null)
  const [busy, setBusy] = useState<UpdateBusy>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [releasesUrl, setReleasesUrl] = useState<string | null>(null)

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  // Resolved here rather than at module scope: reading `sessionStorage` is a
  // side effect in a sandboxed renderer, and this component is rendered to a
  // string in its own tests where the global does not exist at all.
  const store = useMemo(
    () => (providedStore === undefined ? sessionDismissStore() : providedStore),
    [providedStore],
  )

  useEffect(() => {
    const remembered = store?.read() ?? null
    if (remembered !== null) setDismissed(remembered)
  }, [store])

  /**
   * One read, on mount.
   *
   * There is no poll and no backstop timer. Every transition this component can
   * draw is one the main process makes, and it pushes each of them — so a poll
   * would only ask a question it has already been answered. This read exists for
   * the one moment the push cannot cover: the shell mounting after a state was
   * set, which is every launch, since the first check fires 20 seconds in.
   */
  useEffect(() => {
    if (typeof bridge.updateStatus !== 'function') return
    let live = true
    void bridge
      .updateStatus()
      .then((answer) => {
        if (live && alive.current) setState(toUpdateState(answer))
      })
      .catch(() => {
        // Silence is the right failure here. The whole feature is optional, and
        // a red strip across the top of the window because a status call
        // rejected would be the app complaining about its own plumbing. The
        // About screen is where that question gets an answer.
      })
    return () => {
      live = false
    }
  }, [bridge])

  useEffect(() => {
    if (typeof bridge.onUpdateState !== 'function') return
    return bridge.onUpdateState((pushed) => {
      if (alive.current) setState(toUpdateState(pushed))
    })
  }, [bridge])

  // Only for the one phase that needs it, and only once. Every other state has
  // a button; this is the one whose only next step is a web page.
  useEffect(() => {
    if (state.phase !== 'unsupported' || releasesUrl !== null) return
    if (typeof bridge.appAbout !== 'function') return
    let live = true
    void bridge
      .appAbout()
      .then((about) => {
        const url = releasesUrlFor(repositoryOf(about))
        if (live && alive.current && url !== null) setReleasesUrl(url)
      })
      .catch(() => {
        // No link, and the sentence above it already says where to go.
      })
    return () => {
      live = false
    }
  }, [bridge, state.phase, releasesUrl])

  const run = useCallback((key: Exclude<UpdateBusy, null>, work: () => Promise<unknown>): void => {
    setBusy(key)
    setNotice(null)
    void work()
      .then(() => {
        // Deliberately no success notice. What happened next is a state the main
        // process pushes — downloading, ready, error — and "Started the
        // download." beside a progress bar is the same fact twice.
        if (alive.current) setBusy(null)
      })
      .catch((error: unknown) => {
        if (!alive.current) return
        setBusy(null)
        setNotice(errorText(error, 'That did not go through.'))
      })
  }, [])

  const remember = useMemo(() => rememberDismissal(setDismissed, store), [store])

  const actions = updateActions({ bridge, state, setDismissed: remember, run })

  // Nothing at all when the preload has no update channels. Unlike a settings
  // panel somebody navigated to, this strip is unasked-for chrome — a permanent
  // line saying "updates are not wired into this build" would be a bug report
  // addressed to a user who cannot act on it, on every launch. The About screen
  // is where that question gets an answer.
  if (!wired) return null
  if (isDismissed(state, dismissed)) return null

  return (
    <UpdateBannerView
      state={state}
      releasesUrl={releasesUrl}
      missing={missing}
      busy={busy}
      notice={notice}
      actions={actions}
    />
  )
}
