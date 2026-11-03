import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  detail,
  dismissKey,
  formatBytes,
  formatRate,
  headline,
  isDismissed,
  missingUpdateMethods,
  NO_UPDATE,
  percentOf,
  percentText,
  releasesUrlFor,
  rememberDismissal,
  resolveUpdateBridge,
  toUpdateState,
  UpdateBanner,
  UpdateBannerView,
  updateActions,
  type DismissStore,
  type UpdateActions,
  type UpdateBannerViewProps,
  type UpdateBridge,
  type UpdateState,
} from './UpdateBanner'

/**
 * What the strip says in each state it can be in, and what pressing it does.
 *
 * Two things are pinned here that the type checker cannot see. The first is the
 * words: this is the only surface in the app that ever asks for a restart, and
 * every one of its states has to be a sentence rather than a spinner — an
 * update exists, it is coming down, it is waiting, it failed and here is why,
 * this build cannot do it and here is the manual path.
 *
 * The second is arithmetic. Every number on this strip comes off a network feed
 * and goes straight onto the screen, and `NaN%` and `104%` are each one missing
 * field away. They have their own section below.
 *
 * `renderToStaticMarkup` never runs an effect, which is why `UpdateBannerView`
 * takes its state as props — a component that fetched its own status would only
 * ever be testable in the empty state.
 *
 * ## What these tests do not reach, and what that costs
 *
 * The same fact — no DOM, so no effect ever runs — leaves three seams inside
 * `UpdateBanner` itself unreachable from here, and they were confirmed
 * unreachable by deleting each one and watching this file stay green:
 *
 *   - the read on mount (`updateStatus`), without which the strip never appears
 *     for a window that opened after the state was set;
 *   - the subscription to `update:state`, without which it appears once and then
 *     never moves again;
 *   - the `isDismissed` gate in the container, without which Dismiss stores a key
 *     that hides nothing.
 *
 * Everything they *call* is pinned below as a function — `toUpdateState`,
 * `isDismissed`, `rememberDismissal`, `updateActions` — which is why those
 * exist as functions at all. The three call sites are not covered by anything
 * in this repository, and a click-through of a packaged build is the only thing
 * that has ever exercised them. Nobody should read "63 tests" as "this feature
 * was tested end to end".
 */

const NOTHING: UpdateActions = {
  update: () => {},
  restart: () => {},
  retry: () => {},
  dismiss: () => {},
}

/* The union's arms, built by hand — a spread of a partial cannot produce a
   discriminated union, and pretending otherwise is what a cast would be for. */
const AVAILABLE: UpdateState = {
  phase: 'available',
  version: '0.2.0',
  notes: null,
  sizeBytes: null,
}
const DOWNLOADING: UpdateState = {
  phase: 'downloading',
  version: '0.2.0',
  percent: 42.7,
  bytesPerSecond: 3_355_443,
}
const READY: UpdateState = { phase: 'ready', version: '0.2.0' }
const FAILED: UpdateState = {
  phase: 'error',
  message: 'The update could not be verified: the signature did not match the feed.',
}
const UNSIGNED: UpdateState = {
  phase: 'unsupported',
  reason:
    'This build is not code-signed, so it cannot install its own updates. Download the new version from Releases.',
}

/** Every state that puts something on screen, for the sweeps. */
const DRAWN: readonly UpdateState[] = [AVAILABLE, DOWNLOADING, READY, FAILED, UNSIGNED]

function downloading(patch: Partial<Omit<Extract<UpdateState, { phase: 'downloading' }>, 'phase'>>): UpdateState {
  return { phase: 'downloading', version: '0.2.0', percent: null, bytesPerSecond: null, ...patch }
}

function render(props: Partial<UpdateBannerViewProps> = {}): string {
  return renderToStaticMarkup(
    <UpdateBannerView state={NO_UPDATE} busy={null} notice={null} actions={NOTHING} {...props} />,
  )
}

/* ------------------------------------------------------------- the states -- */

describe('nothing to say', () => {
  it('draws no strip at all while idle or checking', () => {
    // It sits above the workspace on every launch. A line that appears for two
    // seconds and pushes the terminal down is worse than silence.
    expect(render({ state: NO_UPDATE })).toBe('')
    expect(render({ state: { phase: 'checking' } })).toBe('')
  })
})

describe('an update is available', () => {
  const html = render({ state: AVAILABLE })

  it('names the version and offers one press', () => {
    expect(html).toContain('Version 0.2.0 is available')
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Update<\/button>/)
  })

  it('does not offer the press that ends every running session', () => {
    expect(html).not.toContain('Restart')
  })

  it('says how big it is when the feed said', () => {
    expect(render({ state: { ...AVAILABLE, sizeBytes: 50_331_648 } })).toContain('48 MB download')
  })

  it('never invents a version number it was not given', () => {
    const unnamed = render({ state: { ...AVAILABLE, version: null } })
    expect(unnamed).toContain('A new version is available')
    expect(unnamed).not.toMatch(/Version\s+(?:null|undefined|NaN)/)
  })

  it('is a strip in the flow of the shell, not an overlay over a running session', () => {
    // An agent session may be mid-turn underneath. Nothing here may cover it,
    // trap focus, or listen for Escape.
    expect(html).toContain('<aside class="upd-banner"')
    expect(html).not.toContain('role="dialog"')
    expect(html).not.toContain('aria-modal')
  })
})

describe('downloading', () => {
  const html = render({ state: DOWNLOADING })

  it('says how far along and how fast', () => {
    expect(html).toContain('Downloading version 0.2.0')
    expect(html).toContain('42%')
    expect(html).toContain('3.2 MB/s')
  })

  it('draws a real bar, reported to assistive technology as well as to the eye', () => {
    expect(html).toContain('role="progressbar"')
    expect(html).toContain('aria-valuenow="42"')
    expect(html).toContain('style="width:42.7%"')
  })

  it('drops the rate on the first tick rather than printing 0 B/s', () => {
    // `updater.ts` opens this state with `bytesPerSecond: 0` before the first
    // progress event lands, and "0 B/s" beside a moving bar reads as a stall.
    const opening = render({ state: downloading({ percent: 0, bytesPerSecond: 0 }) })
    expect(opening).toContain('0%')
    expect(opening).not.toContain('B/s')
  })

  it('announces the phase once and leaves the ticking figure to the progress bar', () => {
    // The main process pushes one state per whole percent. With a live region
    // around the whole strip, a download re-announces the headline, the
    // percentage, the rate and both button labels a hundred times over a session
    // somebody is trying to read — so the region is the text, and the one line
    // that changes on a timer opts out of it.
    expect(html).not.toMatch(/<aside[^>]*role="status"/)
    expect(html).toContain('<div class="upd-text" role="status">')
    expect(html).toMatch(/<span class="upd-detail" aria-live="off">/)
    // The figure itself is still exposed, on the thing built to carry it.
    expect(html).toContain('aria-valuenow="42"')
  })

  it('goes indeterminate rather than claiming a figure the feed never sent', () => {
    const blind = render({ state: downloading({}) })
    expect(blind).toContain('data-indeterminate="true"')
    expect(blind).not.toContain('aria-valuenow')
    expect(blind).toContain('not reporting progress')
    expect(blind).not.toContain('0%')
  })
})

describe('downloaded and waiting', () => {
  const html = render({ state: READY })

  it('asks for the restart in the button, not in a sentence to be found later', () => {
    expect(html).toContain('Version 0.2.0 is downloaded')
    expect(html).toContain('>Restart to finish</button>')
  })

  it('says what the restart costs before it is pressed', () => {
    // The press quits the app. Every pty in this window dies with it, and that
    // belongs next to the button rather than being learned afterwards.
    expect(html).toContain('Every session running in this window is closed')
  })
})

describe('it failed', () => {
  const html = render({ state: FAILED })

  it('prints the main process’s sentence verbatim', () => {
    // `updater.ts` keeps those sentences in one place precisely so each says
    // what to do; a paraphrase here would go stale the first time one changed.
    expect(html).toContain(FAILED.phase === 'error' ? FAILED.message : '')
    expect(html).toContain('That update did not go through')
  })

  it('offers the retry', () => {
    expect(html).toMatch(/<button(?![^>]*disabled)[^>]*>Try again<\/button>/)
  })

  it('is announced, unlike the download percentage', () => {
    // The opt-out above is for the one line that changes on a timer. A failure
    // is the opposite case: it happens once and it is the whole message.
    expect(html).not.toContain('aria-live="off"')
    expect(html).toContain('<div class="upd-text" role="status">')
  })
})

describe('a build that cannot update itself', () => {
  const html = render({
    state: UNSIGNED,
    releasesUrl: 'https://github.com/asadev/terminaldeck/releases',
  })

  it('quotes the reason and hands over the manual path', () => {
    expect(html).toContain('This build is not code-signed')
    expect(html).toContain('href="https://github.com/asadev/terminaldeck/releases"')
    expect(html).toContain('Download it from the releases page')
  })

  it('offers no button that would pretend to fix it', () => {
    expect(html).not.toContain('>Update</button>')
    expect(html).not.toContain('Try again')
  })

  it('shows no link when the releases page could not be worked out', () => {
    // Inventing a URL is worse than showing none, and the sentence above it
    // already says where to go.
    const homeless = render({ state: UNSIGNED })
    expect(homeless).toContain('This build is not code-signed')
    expect(homeless).not.toMatch(/<a\s/)
    expect(homeless).not.toContain('releases page')
  })
})

describe('releasesUrlFor', () => {
  it('builds the GitHub path from the repository the app records for itself', () => {
    expect(releasesUrlFor('https://github.com/asadev/terminaldeck')).toBe(
      'https://github.com/asadev/terminaldeck/releases',
    )
    expect(releasesUrlFor('https://github.com/asadev/terminaldeck/')).toBe(
      'https://github.com/asadev/terminaldeck/releases',
    )
  })

  it('declines every host whose releases path it does not actually know', () => {
    // GitLab's is `/-/releases` and a self-hosted remote has whatever its owner
    // chose. A link that 404s is worse than no link at all.
    expect(releasesUrlFor('https://gitlab.com/asadev/terminaldeck')).toBeNull()
    expect(releasesUrlFor('git@github.com:asadev/terminaldeck.git')).toBeNull()
    expect(releasesUrlFor('javascript:alert(1)')).toBeNull()
    expect(releasesUrlFor('not a url')).toBeNull()
    expect(releasesUrlFor(null)).toBeNull()
  })
})

/* -------------------------------------------------------------- the notes -- */

describe('release notes', () => {
  const notes = '## 0.2.0\n\n- Fixed the thing\n- Broke a different thing'
  const html = render({ state: { ...AVAILABLE, notes } })

  it('is there but collapsed, so the strip stays one line high', () => {
    expect(html).toContain('<details class="upd-notes">')
    expect(html).toContain('What changed')
    expect(html).not.toMatch(/<details[^>]*\sopen/)
  })

  it('renders remote notes as text when there is no sanitiser to clean them', () => {
    // There is no DOM in this environment, so DOMPurify is an uninitialised
    // factory and `renderMarkdown` returns null. That null is the whole guard:
    // the fallback is escaped text, never the feed's own markup.
    expect(html).toContain('upd-notes-plain')
    expect(html).toContain('Fixed the thing')
  })

  it('escapes markup in the notes rather than emitting it', () => {
    const hostile = render({
      state: {
        ...AVAILABLE,
        notes: '<img src=x onerror="alert(1)"> and <a href="https://evil.test">a link</a>',
      },
    })
    // The words survive as text — "onerror" is still in the markup, spelled
    // `onerror=&quot;`, which is a word on screen and not a handler. What must
    // not survive is a tag or an attribute a browser would act on.
    expect(hostile).not.toContain('<img')
    expect(hostile).not.toMatch(/<[a-z]+[^>]*\son[a-z]+=/i)
    expect(hostile).not.toContain('href="https://evil.test"')
    expect(hostile).toContain('&lt;img')
  })

  it('says nothing about changes when the feed shipped no notes', () => {
    expect(render({ state: AVAILABLE })).not.toContain('What changed')
  })
})

/* ------------------------------------------------------------ the numbers -- */

describe('a percentage is never NaN and never over 100', () => {
  /** Every number followed by a % sign anywhere in the rendered strip. */
  const percentagesIn = (html: string): number[] =>
    [...html.matchAll(/(-?[\d.]+)%/g)].map((match) => Number(match[1]))

  it('drops a percent that is not a number', () => {
    // NaN does not survive JSON, but this arrives over structured clone, which
    // carries it perfectly.
    expect(percentOf(Number.NaN)).toBeNull()
    expect(percentOf(Number.POSITIVE_INFINITY)).toBeNull()
    expect(percentOf(null)).toBeNull()
    const html = render({ state: downloading({ percent: Number.NaN }) })
    expect(html).not.toContain('NaN')
    expect(html).toContain('data-indeterminate="true"')
  })

  it('clamps a feed that overshoots its own size', () => {
    // The last tick routinely counts bytes the stated total never did. 104% is
    // a fact about the feed, not about the download.
    expect(percentOf(104)).toBe(100)
    const html = render({ state: downloading({ percent: 104 }) })
    expect(html).toContain('100%')
    expect(html).toContain('aria-valuenow="100"')
    expect(html).toContain('style="width:100%"')
  })

  it('clamps a negative one to zero rather than drawing a bar backwards', () => {
    expect(percentOf(-3)).toBe(0)
    expect(render({ state: downloading({ percent: -3 }) })).toContain('0%')
  })

  it('puts no unreadable or out-of-range number anywhere on the strip', () => {
    for (const percent of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, 1e9, -50, 104, 99.6, 0]) {
      const html = render({ state: downloading({ percent, bytesPerSecond: 1024 }) })
      expect(html, String(percent)).not.toContain('NaN')
      expect(html, String(percent)).not.toContain('Infinity')
      for (const value of percentagesIn(html)) {
        expect(value, String(percent)).toBeGreaterThanOrEqual(0)
        expect(value, String(percent)).toBeLessThanOrEqual(100)
      }
    }
  })

  it('floors rather than rounds, so it never says 100% before it is done', () => {
    expect(percentText(99.6)).toBe('99%')
    expect(percentText(0.4)).toBe('0%')
    expect(percentText(100)).toBe('100%')
    expect(percentText(null)).toBeNull()
  })
})

describe('bytes for humans', () => {
  it('picks a unit and only decimalises where it means something', () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(1024)).toBe('1.0 KB')
    expect(formatBytes(1_468_006)).toBe('1.4 MB')
    expect(formatBytes(50_331_648)).toBe('48 MB')
  })

  it('is null for anything that is not a size', () => {
    expect(formatBytes(null)).toBeNull()
    expect(formatBytes(Number.NaN)).toBeNull()
    expect(formatBytes(Number.POSITIVE_INFINITY)).toBeNull()
    expect(formatBytes(-1)).toBeNull()
  })
})

describe('formatRate', () => {
  it('drops a rate nothing has measured yet', () => {
    expect(formatRate(0)).toBeNull()
    expect(formatRate(null)).toBeNull()
    expect(formatRate(Number.NaN)).toBeNull()
    expect(formatRate(-1)).toBeNull()
    expect(formatRate(1_048_576)).toBe('1.0 MB/s')
  })
})

/* ------------------------------------------------------------- narrowing -- */

describe('narrowing what the main process sends', () => {
  it('is silent for an answer that is not an object at all', () => {
    expect(toUpdateState(null).phase).toBe('idle')
    expect(toUpdateState('yes').phase).toBe('idle')
    expect(toUpdateState([]).phase).toBe('idle')
  })

  it('treats a phase it does not recognise as nothing to say', () => {
    // The asymmetry is the point: a missed update is offered again at the next
    // check, while a Restart button over an unreadable answer kills every
    // running session for no reason.
    expect(toUpdateState({ phase: 'obsoleting' }).phase).toBe('idle')
    expect(toUpdateState({ phase: 'ready', version: '0.2.0' })).toEqual(READY)
  })

  it('drops an error or an unsupported build that arrived with no sentence', () => {
    // Both of those phases are entirely their sentence. A red strip saying
    // nothing is worse than no strip.
    expect(toUpdateState({ phase: 'error' }).phase).toBe('idle')
    expect(toUpdateState({ phase: 'error', message: '   ' }).phase).toBe('idle')
    expect(toUpdateState({ phase: 'unsupported', reason: null }).phase).toBe('idle')
  })

  it('keeps only strings that say something', () => {
    const parsed = toUpdateState({ phase: 'available', version: '  ', notes: '', sizeBytes: 12 })
    expect(parsed).toEqual({ phase: 'available', version: null, notes: null, sizeBytes: 12 })
  })

  it('keeps only numbers that are numbers', () => {
    expect(toUpdateState({ phase: 'downloading', version: '0.2.0', percent: 'half', bytesPerSecond: Number.NaN })).toEqual(
      { phase: 'downloading', version: '0.2.0', percent: null, bytesPerSecond: null },
    )
  })

  it('carries the whole of every arm the main process can send', () => {
    expect(
      toUpdateState({ phase: 'available', version: '0.2.0', notes: '# hi', sizeBytes: 4096 }),
    ).toEqual({ phase: 'available', version: '0.2.0', notes: '# hi', sizeBytes: 4096 })
    expect(toUpdateState({ phase: 'checking' })).toEqual({ phase: 'checking' })
    expect(toUpdateState({ phase: 'idle', checkedAt: 1_700_000 })).toEqual({
      phase: 'idle',
      checkedAt: 1_700_000,
    })
  })
})

describe('the words', () => {
  it('has a headline for every phase that draws a strip', () => {
    for (const state of DRAWN) expect(headline(state), state.phase).not.toBe('')
  })

  it('has a second line wherever the state is more than its headline', () => {
    // `available` is the exception and stays one line: the headline already
    // carries the version, and the size is only added when the feed sent one.
    for (const state of [DOWNLOADING, READY, FAILED, UNSIGNED]) {
      expect(detail(state), state.phase).not.toBeNull()
    }
    expect(detail(AVAILABLE)).toBeNull()
    expect(detail({ ...AVAILABLE, sizeBytes: 4096 })).toBe('4.0 KB download')
  })

  it('has neither for the phases that draw nothing', () => {
    expect(headline(NO_UPDATE)).toBe('')
    expect(detail({ phase: 'checking' })).toBeNull()
  })
})

/* --------------------------------------------------------------- dismiss -- */

describe('dismissing', () => {
  it('hides exactly the thing that was dismissed', () => {
    expect(isDismissed(AVAILABLE, dismissKey(AVAILABLE))).toBe(true)
    expect(isDismissed(AVAILABLE, null)).toBe(false)
  })

  it('keeps the progress bar shut after the offer was dismissed', () => {
    // Pressing Update and then clearing the strip must not have the same news
    // slide back in a second later under a different phase.
    expect(isDismissed(DOWNLOADING, dismissKey(AVAILABLE))).toBe(true)
  })

  it('lets the restart through, because it is the only state that asks for one', () => {
    expect(isDismissed(READY, dismissKey(AVAILABLE))).toBe(false)
  })

  it('lets a failure through, rather than swallowing it with the offer', () => {
    expect(isDismissed(FAILED, dismissKey(AVAILABLE))).toBe(false)
  })

  it('lets a different failure through after one was dismissed', () => {
    const other: UpdateState = { phase: 'error', message: 'The feed could not be reached.' }
    expect(isDismissed(other, dismissKey(FAILED))).toBe(false)
    expect(isDismissed(FAILED, dismissKey(FAILED))).toBe(true)
  })

  it('comes back for the next version', () => {
    expect(isDismissed({ ...AVAILABLE, version: '0.3.0' }, dismissKey(AVAILABLE))).toBe(false)
  })

  it('stores nothing for a state that is not on screen', () => {
    // A key stored while nothing is showing would silence whatever came next.
    expect(dismissKey(NO_UPDATE)).toBeNull()
    expect(dismissKey({ phase: 'checking' })).toBeNull()
  })

  it('is offered on every state that draws a strip', () => {
    for (const state of DRAWN) {
      expect(render({ state }), state.phase).toContain('>Dismiss</button>')
      expect(dismissKey(state), state.phase).not.toBeNull()
    }
  })

  it('says on the button that it is only for this run of the app', () => {
    expect(render({ state: AVAILABLE })).toContain('Hides this until the app is started again.')
  })

  it('writes the key to the session store, and nowhere more permanent', () => {
    // sessionStorage dies with the window, which is exactly the promise the
    // button makes. A preference would quietly become an opt-out of updates.
    //
    // The write goes through `rememberDismissal` — the component's own callback,
    // not a replica of it in this file. That distinction is the whole test: with
    // the harness doing its own writing, deleting the store write from the
    // component left this assertion passing and dismissals silently stopped
    // surviving a reload of the window.
    const written: Array<string | null> = []
    const store: DismissStore = { read: () => null, write: (key) => void written.push(key) }
    const h = harness(fakeBridge().bridge, AVAILABLE, store)
    h.actions.dismiss()
    expect(written).toEqual(['offer:0.2.0'])
    expect(h.dismissed).toBe('offer:0.2.0')
  })

  it('still holds for this run when there is no store to write to', () => {
    // Storage blocked by policy, or no DOM at all. Neither is a failure worth an
    // exception: the dismissal holds through component state and the strip is
    // back next launch, which is what it does anyway.
    const held: Array<string | null> = []
    const remember = rememberDismissal((key) => void held.push(key), null)
    expect(() => remember('ready:0.2.0')).not.toThrow()
    expect(held).toEqual(['ready:0.2.0'])
  })
})

/* --------------------------------------------------------------- pressing -- */

/**
 * The four buttons, exercised directly.
 *
 * Everything above renders markup, and markup cannot tell you what a press
 * *does*. That gap is not academic here: with only the rendering tests, wiring
 * Update to `installUpdate` — which quits the app and takes every running
 * session with it — leaves the whole suite green.
 */

interface Harness {
  actions: UpdateActions
  failures: string[]
  dismissed: string | null
  settled(): Promise<void>
}

function fakeBridge(only?: ReadonlyArray<keyof UpdateBridge>): {
  bridge: Partial<UpdateBridge>
  calls: string[]
} {
  const calls: string[] = []
  const names: ReadonlyArray<keyof UpdateBridge> = only ?? [
    'updateStatus',
    'checkForUpdate',
    'downloadUpdate',
    'installUpdate',
    'appAbout',
  ]
  const bridge: Record<string, unknown> = {}
  for (const name of names) {
    bridge[name] = (): Promise<unknown> => {
      calls.push(`${name}()`)
      return Promise.resolve(null)
    }
  }
  return { bridge: bridge as Partial<UpdateBridge>, calls }
}

function harness(bridge: Partial<UpdateBridge>, current: UpdateState, store?: DismissStore): Harness {
  const failures: string[] = []
  const pending: Array<Promise<void>> = []
  const held = { dismissed: null as string | null }
  const actions = updateActions({
    bridge,
    state: current,
    // The component's own remembering, not a second copy of it here.
    setDismissed: rememberDismissal((key) => {
      held.dismissed = key
    }, store ?? null),
    run: (_key, work) => {
      pending.push(
        work().then(
          () => {},
          (error: unknown) => {
            failures.push(error instanceof Error ? error.message : String(error))
          },
        ),
      )
    },
  })
  return {
    actions,
    failures,
    get dismissed() {
      return held.dismissed
    },
    settled: async () => {
      await Promise.all(pending)
    },
  }
}

describe('the buttons', () => {
  it('downloads on Update, and does not install', async () => {
    const { bridge, calls } = fakeBridge()
    const h = harness(bridge, AVAILABLE)
    h.actions.update()
    await h.settled()
    expect(calls).toEqual(['downloadUpdate()'])
    // If this ever passes with `installUpdate()` in `calls`, a press labelled
    // "Update" is quitting the app out from under a running agent.
    expect(calls.join()).not.toContain('install')
  })

  it('installs only on the press that says it will restart', async () => {
    const { bridge, calls } = fakeBridge()
    const h = harness(bridge, READY)
    h.actions.restart()
    await h.settled()
    expect(calls).toEqual(['installUpdate()'])
  })

  it('re-checks on Try again, rather than guessing which call failed', async () => {
    // `updater.ts` reports an error as a sentence and nothing else — there is
    // no field saying which call it came from — and a check is the honest
    // superset: it lands back on `available` if the release is still there.
    const { bridge, calls } = fakeBridge()
    const h = harness(bridge, FAILED)
    h.actions.retry()
    await h.settled()
    expect(calls).toEqual(['checkForUpdate()'])
  })
})

describe('a channel this build does not have', () => {
  it('fails loudly rather than reporting a call that never happened', async () => {
    // `bridge.installUpdate?.() ?? Promise.resolve()` is the shape this guards:
    // it resolves, so the strip would sit there having "restarted" an app that
    // is still running.
    const h = harness({}, FAILED)
    h.actions.update()
    h.actions.restart()
    h.actions.retry()
    await h.settled()
    expect(h.failures).toHaveLength(3)
    for (const failure of h.failures) expect(failure).toContain('half wired')
  })

  it('names the gaps on the strip instead of drawing buttons that cannot work', () => {
    const { bridge } = fakeBridge(['updateStatus'])
    expect(missingUpdateMethods(bridge)).toEqual([
      'checkForUpdate',
      'downloadUpdate',
      'installUpdate',
      'onUpdateState',
      'appAbout',
    ])
    const html = render({ state: AVAILABLE, missing: ['installUpdate', 'onUpdateState'] })
    expect(html).toContain('missing 2 of the update channels')
    expect(html).toContain('installUpdate')
  })

  it('reports nothing missing when every channel is there', () => {
    const { bridge } = fakeBridge()
    expect(missingUpdateMethods({ ...bridge, onUpdateState: () => () => {} })).toEqual([])
  })
})

describe('while a press is in flight', () => {
  it('disables the button and says what it is doing', () => {
    const html = render({ state: READY, busy: 'restart' })
    expect(html).toMatch(/<button[^>]*disabled[^>]*>Restarting…<\/button>/)
  })

  it('shows why a press did not go through', () => {
    const html = render({ state: READY, notice: 'The updater is not running in this build.' })
    expect(html).toContain('The updater is not running in this build.')
  })
})

/* ----------------------------------------------------------------- bridge -- */

describe('the bridge', () => {
  it('calls through the host object rather than detaching its methods', () => {
    // A preload whose functions live on a prototype throws on `this` the first
    // time a button is pressed, and only in a packaged build.
    const host = {
      secret: 'kept',
      updateStatus(): Promise<unknown> {
        return Promise.resolve({
          phase: 'ready',
          version: (this as { secret: string }).secret === 'kept' ? '0.2.0' : null,
        })
      },
    }
    const bridge = resolveUpdateBridge(host)
    expect(typeof bridge.updateStatus).toBe('function')
    return bridge.updateStatus?.().then((answer) => {
      expect(toUpdateState(answer)).toEqual(READY)
    })
  })

  it('picks up only the methods that exist', () => {
    const bridge = resolveUpdateBridge({ updateStatus: () => Promise.resolve({}) })
    expect(Object.keys(bridge)).toEqual(['updateStatus'])
  })
})

describe('when the build has no update channels', () => {
  it('draws nothing rather than a permanent line nobody can act on', () => {
    // Unlike a settings panel somebody navigated to, this strip is unasked-for
    // chrome. "Updates are not wired into this build" across the top of the
    // window on every launch is a bug report addressed to the wrong person; the
    // About screen is where that question gets an answer.
    expect(renderToStaticMarkup(<UpdateBanner bridge={{}} store={null} />)).toBe('')
  })

  it('reaches that state through the real bridge resolution, not a special case', () => {
    // No `deck` on the global in this process, so this is the packaged app's
    // "the preload did not expose it" path, exercised end to end.
    expect(resolveUpdateBridge()).toEqual({})
    expect(renderToStaticMarkup(<UpdateBanner store={null} />)).toBe('')
  })

  it('draws nothing before the first status has landed', () => {
    // An effect never runs under renderToStaticMarkup, so this is the first
    // paint of a wired build: silence, not a placeholder that shifts the
    // workspace down and then back up a moment later.
    const { bridge } = fakeBridge()
    expect(renderToStaticMarkup(<UpdateBanner bridge={bridge} store={null} />)).toBe('')
  })
})
