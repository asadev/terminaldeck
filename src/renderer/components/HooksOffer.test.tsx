import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BRAND } from '../../shared/brand'
import {
  FOLLOW_UP_TITLE,
  HooksOffer,
  HooksOfferView,
  NOT_NOW_TITLE,
  offerActions,
  offerDetail,
  offerHeadline,
  resolveOfferBridge,
  toAcceptFailures,
  toOffer,
  writesTitle,
  type HooksOfferActions,
  type HooksOfferBridge,
  type OfferBusy,
  type OfferProvider,
} from './HooksOffer'

/**
 * The consent strip a fresh install sees, pinned in the states it can be in.
 *
 * The words matter more than usual here: this is one sentence asking to write
 * into somebody's dotfiles, and the whole design argument — ask once, plainly,
 * cover everything with one press, remember either answer — lives in what the
 * strip says and offers. `renderToStaticMarkup` runs no effects, which is why
 * the view takes everything as props and the presses are a plain function;
 * same arrangement, and same reasoning, as `UpdateBanner`.
 *
 * What these tests cannot reach: the container's read-on-mount, which no test
 * in this repository exercises for the same no-DOM reason. What it *calls* —
 * `toOfferProviders`, `resolveOfferBridge` — is pinned below instead.
 */

const NOTHING: HooksOfferActions = {
  accept: () => {},
  decline: () => {},
  dismiss: () => {},
}

const CLAUDE: OfferProvider = {
  id: 'claude',
  label: 'Claude Code',
  file: '/home/x/.claude/settings.json',
}

const CODEX: OfferProvider = { id: 'codex', label: 'Codex CLI', file: '/home/x/.codex/hooks.json' }

function view(
  providers: readonly OfferProvider[],
  busy: OfferBusy = null,
  failures: readonly string[] = [],
): string {
  return renderToStaticMarkup(
    <HooksOfferView providers={providers} busy={busy} failures={failures} actions={NOTHING} />,
  )
}

/* ---------------------------------------------------------------- the view -- */

describe('what the strip offers', () => {
  it('one sentence saying what it wants to add and why, and two answers', () => {
    const html = view([CLAUDE, CODEX])

    expect(html).toContain(offerHeadline(2))
    expect(html).toContain('nothing else in those files is touched')
    expect(html).toContain('Turn it on')
    expect(html).toContain('Not now')
  })

  it('the button that writes says which files, on hover', () => {
    // The same move as the install button on the Session updates page: the
    // path appears at the moment a press is about to write it.
    expect(view([CLAUDE, CODEX])).toContain(writesTitle([CLAUDE, CODEX]))
    expect(writesTitle([CLAUDE, CODEX])).toBe(
      'Writes /home/x/.claude/settings.json and /home/x/.codex/hooks.json',
    )
  })

  it('"Not now" states its own permanence and the way back', () => {
    // A button recorded forever must say so where it is pressed — and name the
    // page that can undo it, or "never asks again" is a trap with good manners.
    expect(view([CLAUDE])).toContain(NOT_NOW_TITLE)
    expect(NOT_NOW_TITLE).toContain('Never asks again')
    expect(NOT_NOW_TITLE).toContain('Session updates')
  })

  it('draws nothing with nothing to offer', () => {
    expect(view([])).toBe('')
  })

  it('a failed press shows the failure and stops re-offering the press', () => {
    const html = view([CLAUDE], null, ['Install failed: the disk said no'])

    expect(html).toContain('Install failed: the disk said no')
    expect(html).toContain('Dismiss')
    // The press that just failed is not offered again by the same strip; the
    // Session updates page has the working button and the room to explain.
    expect(html).not.toContain('Turn it on')
  })

  it('a press in flight says so and blocks both buttons', () => {
    const html = view([CLAUDE], 'accept')

    expect(html).toContain('Turning on…')
    expect((html.match(/disabled/g) ?? []).length).toBe(2)
  })

  it('after a clean accept, a remaining step replaces the ask, verbatim', () => {
    const step = 'Codex needs `hooks = true` — then Trust all once when it asks.'
    const html = renderToStaticMarkup(
      <HooksOfferView
        providers={[CLAUDE, CODEX]}
        busy={null}
        failures={[]}
        followUps={[step]}
        actions={NOTHING}
      />,
    )

    expect(html).toContain(FOLLOW_UP_TITLE)
    // Escaped by React on the way out; what matters is the sentence survives.
    expect(html).toContain('Trust all once when it asks')
    // The ask is over — recorded, done — so its buttons must be gone with it.
    expect(html).not.toContain('Turn it on')
    expect(html).not.toContain('Not now')
    expect(html).toContain('Dismiss')
  })
})

describe('the words', () => {
  it('speaks in the singular to a machine with one assistant', () => {
    expect(offerHeadline(1)).toContain('assistant is doing')
    expect(offerDetail(1)).toContain("your assistant's own settings file")
  })

  it('names this app and no specific assistant', () => {
    // "you should not mention in any settings or any pop-up a specific tool or
    // LLM" — the files on the button hover are discovered facts, the sentence
    // itself stays generic.
    for (const text of [offerDetail(1), offerDetail(2), offerHeadline(1), offerHeadline(2)]) {
      expect(text).not.toMatch(/claude|codex|gemini/i)
    }
    expect(offerDetail(2)).toContain(BRAND.name)
  })
})

/* ---------------------------------------------------------- what comes back -- */

describe('toOffer', () => {
  it('reads a verdict with providers and their follow-up steps', () => {
    expect(
      toOffer({ show: true, answered: null, eligible: [CLAUDE, CODEX], followUps: ['trust it'] }),
    ).toEqual({ providers: [CLAUDE, CODEX], followUps: ['trust it'] })
  })

  it('show false is nothing to draw, whatever the list says', () => {
    expect(toOffer({ show: false, eligible: [CLAUDE] }).providers).toEqual([])
  })

  it('anything unreadable draws nothing rather than guessing', () => {
    // Guessing wrong towards silence costs asking on a later launch; the other
    // direction puts a dotfile-writing button over an unreadable answer.
    for (const raw of [null, undefined, 'yes', 42, [], { show: true }, { eligible: [CLAUDE] }]) {
      expect(toOffer(raw).providers).toEqual([])
    }
  })

  it('drops a malformed row without dropping the readable ones', () => {
    expect(
      toOffer({ show: true, eligible: [{ id: 'claude', label: '', file: 'x' }, CODEX] }).providers,
    ).toEqual([CODEX])
  })

  it('an offer from before follow-ups reads as having none', () => {
    expect(toOffer({ show: true, eligible: [CLAUDE] }).followUps).toEqual([])
  })
})

describe('toAcceptFailures', () => {
  it('all ok is no failures', () => {
    expect(toAcceptFailures([{ ok: true }, { ok: true, message: 'done' }])).toEqual([])
  })

  it('keeps the main process sentence for each refusal', () => {
    expect(toAcceptFailures([{ ok: true }, { ok: false, message: 'file said no' }])).toEqual([
      'file said no',
    ])
  })

  it('an unreadable answer is a failure, not a success', () => {
    // The installs may or may not have landed; hiding the strip would claim
    // they did. The sentence points at the page that knows.
    const failures = toAcceptFailures('what')
    expect(failures).toHaveLength(1)
    expect(failures[0]).toContain('Session updates')
  })
})

/* -------------------------------------------------------------- the presses -- */

interface Recorded {
  busy: OfferBusy[]
  failures: string[][]
  followUpsShown: number
  hidden: number
}

function record(
  bridge: HooksOfferBridge,
  followUps: readonly string[] = [],
): { actions: HooksOfferActions; log: Recorded } {
  const log: Recorded = { busy: [], failures: [], followUpsShown: 0, hidden: 0 }
  const actions = offerActions({
    bridge,
    followUps,
    setBusy: (busy) => log.busy.push(busy),
    setFailures: (failures) => log.failures.push(failures),
    showFollowUps: () => {
      log.followUpsShown += 1
    },
    hide: () => {
      log.hidden += 1
    },
    alive: () => true,
  })
  return { actions, log }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('offerActions', () => {
  it('a clean accept hides the strip and calls nothing else', async () => {
    let accepted = 0
    const { actions, log } = record({
      hooksOffer: () => Promise.resolve(null),
      hooksOfferAccept: () => {
        accepted += 1
        return Promise.resolve([{ ok: true }])
      },
      hooksOfferDecline: () => Promise.reject(new Error('never')),
    })

    actions.accept()
    await settle()

    expect(accepted).toBe(1)
    expect(log.hidden).toBe(1)
    expect(log.failures).toEqual([])
    expect(log.busy).toEqual(['accept', null])
  })

  it('a clean accept with a step left shows the step instead of hiding', async () => {
    // The Codex case: the hooks are written, and its CLI will not run them
    // until its own trust review is answered. Hiding here would claim "on"
    // for an assistant that stays silent.
    const { actions, log } = record(
      {
        hooksOffer: () => Promise.resolve(null),
        hooksOfferAccept: () => Promise.resolve([{ ok: true }]),
        hooksOfferDecline: () => Promise.reject(new Error('never')),
      },
      ['Codex needs hooks = true, then Trust all once when it asks.'],
    )

    actions.accept()
    await settle()

    expect(log.hidden).toBe(0)
    expect(log.followUpsShown).toBe(1)
  })

  it('a partial accept reports the refusals instead of hiding', async () => {
    const { actions, log } = record({
      hooksOffer: () => Promise.resolve(null),
      hooksOfferAccept: () => Promise.resolve([{ ok: true }, { ok: false, message: 'no' }]),
      hooksOfferDecline: () => Promise.reject(new Error('never')),
    })

    actions.accept()
    await settle()

    expect(log.hidden).toBe(0)
    expect(log.failures).toEqual([['no']])
  })

  it('a rejected accept arrives as its own sentence', async () => {
    const { actions, log } = record({
      hooksOffer: () => Promise.resolve(null),
      hooksOfferAccept: () => Promise.reject(new Error('gone')),
      hooksOfferDecline: () => Promise.reject(new Error('never')),
    })

    actions.accept()
    await settle()

    expect(log.hidden).toBe(0)
    expect(log.failures).toEqual([['gone']])
  })

  it('decline hides even when recording the answer failed', async () => {
    // The person said no; a "Not now" that visibly did nothing would be worse
    // than a strip that returns next launch because the marker was unwritable.
    const { actions, log } = record({
      hooksOffer: () => Promise.resolve(null),
      hooksOfferAccept: () => Promise.reject(new Error('never')),
      hooksOfferDecline: () => Promise.reject(new Error('disk full')),
    })

    actions.decline()
    await settle()

    expect(log.hidden).toBe(1)
    expect(log.failures).toEqual([])
  })
})

/* --------------------------------------------------------------- the bridge -- */

describe('resolveOfferBridge', () => {
  const methods = {
    hooksOffer: () => Promise.resolve(null),
    hooksOfferAccept: () => Promise.resolve(null),
    hooksOfferDecline: () => Promise.resolve(null),
  }

  it('takes a host with all three methods', () => {
    expect(resolveOfferBridge(methods)).not.toBeNull()
  })

  it('refuses a partial bridge outright', () => {
    // Two methods out of three is a strip whose primary button goes nowhere —
    // the control-that-looks-like-it-works. All or nothing.
    const { hooksOfferAccept: _dropped, ...partial } = methods
    expect(resolveOfferBridge(partial)).toBeNull()
    expect(resolveOfferBridge({})).toBeNull()
    expect(resolveOfferBridge(null)).toBeNull()
  })

  it('the container draws nothing without a bridge', () => {
    expect(renderToStaticMarkup(<HooksOffer bridge={null} />)).toBe('')
  })

  it('the container draws nothing before the offer answers', () => {
    // Every launch on an answered machine renders exactly this: bridge
    // present, verdict pending, nothing on screen. The strip appears only when
    // main says to ask.
    expect(renderToStaticMarkup(<HooksOffer bridge={resolveOfferBridge(methods)} />)).toBe('')
  })
})
