import { describe, expect, it } from 'vitest'
import {
  argRows,
  nextQuestion,
  readConsentRequest,
  readConsentSettled,
  secondsLeft,
  settledSentence,
  timeoutSentence,
  toolHeading,
  type ConsentRequestView,
} from './consent-model'

/**
 * The four things a person needs in order to answer, and the rules that keep
 * them true.
 *
 * The one worth stating twice: **a question that cannot be fully read is not
 * shown.** The far side refuses an unanswered alter call either way, so the
 * choice is between a refusal and a dialog asking somebody to approve something
 * it cannot name — and only one of those is defensible.
 */

const request = {
  id: 'q1',
  tool: 'settings.write',
  tier: 'alter',
  summary: 'Change settings: appearance.theme to "dark"',
  args: { scope: 'settings', patch: { 'appearance.theme': 'dark' } },
  requestedAt: 1_000,
  expiresAt: 121_000,
}

describe('reading a request', () => {
  it('narrows a real one', () => {
    const view = readConsentRequest(request)
    expect(view?.tool).toBe('settings.write')
    expect(view?.tier).toBe('alter')
    expect(view?.summary).toContain('appearance.theme')
  })

  it('refuses to draw a dialog it cannot fully read', () => {
    const cases: Array<[string, unknown]> = [
      ['no id', { ...request, id: '' }],
      ['no tool', { ...request, tool: undefined }],
      ['a tier it does not know', { ...request, tier: 'nuclear' }],
      ['no sentence', { ...request, summary: '' }],
      ['no deadline', { ...request, expiresAt: 'soon' }],
      ['not an object', 'settings.write'],
      ['nothing', null],
    ]
    for (const [why, value] of cases) expect(readConsentRequest(value), why).toBeNull()
  })

  it('accepts a request with no arguments, because some tools take none', () => {
    const view = readConsentRequest({ ...request, args: undefined })
    expect(view?.args).toEqual({})
  })
})

describe('reading a settled push', () => {
  it('carries the reason so the window can say what happened', () => {
    expect(
      readConsentSettled({ id: 'q1', outcome: { granted: false, reason: 'timeout', by: null, at: 5 } }),
    ).toEqual({ id: 'q1', granted: false, reason: 'timeout', by: null })
  })

  /**
   * `by` is read, because this dialog is no longer the only surface that can
   * answer.
   *
   * A device with its own copilot connection can answer its own run's question,
   * and first answer wins — so this window can be closed by an answer nobody in
   * front of it gave. Without this field the dialog would simply vanish, which
   * teaches a person that the app does things behind their back.
   */
  it('carries the surface that answered it', () => {
    expect(
      readConsentSettled({
        id: 'q1',
        outcome: { granted: true, by: 'device:phone-1', at: 5 },
      }),
    ).toEqual({ id: 'q1', granted: true, reason: null, by: 'device:phone-1' })
  })

  it('says where a question was answered, allowed or refused', () => {
    expect(
      settledSentence({ id: 'q1', granted: true, reason: null, by: 'device:phone-1' }),
    ).toBe('Allowed on a connected device.')
    expect(
      settledSentence({ id: 'q1', granted: false, reason: 'declined', by: 'device:phone-1' }),
    ).toBe('Refused on a connected device.')
    // Answered here, by the person looking at it: repeating it back would be the
    // app narrating the button they just pressed.
    expect(settledSentence({ id: 'q1', granted: true, reason: null, by: 'window' })).toBeNull()
    expect(settledSentence({ id: 'q1', granted: false, reason: 'declined', by: 'window' })).toBeNull()
  })

  it('treats anything other than a literal true as not granted', () => {
    // The same rule the main process holds at `consent-respond`: a wiring
    // mistake that sent `undefined` must never read as approval.
    expect(readConsentSettled({ id: 'q1', outcome: { granted: 'yes' } })?.granted).toBe(false)
    expect(readConsentSettled({ id: 'q1', outcome: {} })?.granted).toBe(false)
  })
})

describe('the heading', () => {
  it('prefers the catalogue title', () => {
    expect(toolHeading('settings.write', { 'settings.write': 'Change a setting' })).toBe('Change a setting')
  })

  it('falls back to the tool id, which is poor and never wrong', () => {
    expect(toolHeading('settings.write', {})).toBe('settings.write')
  })
})

describe('the arguments', () => {
  it('shows every one, in the order the tool sent them', () => {
    expect(argRows(readConsentRequest(request)!.args)).toEqual([
      { name: 'scope', value: 'settings' },
      { name: 'patch', value: '{"appearance.theme":"dark"}' },
    ])
  })

  it('renders a string as itself rather than as quoted JSON', () => {
    expect(argRows({ text: 'run the tests' })[0].value).toBe('run the tests')
  })

  it('names an absent value instead of printing undefined', () => {
    expect(argRows({ submit: undefined })[0].value).toBe('not set')
  })
})

describe('what happens if you say nothing', () => {
  const view = readConsentRequest(request) as ConsentRequestView

  it('counts down in seconds', () => {
    expect(secondsLeft(view, 1_000)).toBe(120)
    expect(secondsLeft(view, 111_000)).toBe(10)
  })

  it('never goes negative when the clock passes the deadline', () => {
    expect(secondsLeft(view, 200_000)).toBe(0)
  })

  it('says that silence is a refusal, not a deferral', () => {
    expect(timeoutSentence(30)).toContain('Refused automatically in 30s')
    expect(timeoutSentence(0)).toContain('being refused')
  })
})

describe('what to say when a question closes on its own', () => {
  it('explains a timeout', () => {
    expect(settledSentence({ id: 'q1', granted: false, reason: 'timeout', by: null })).toContain('in time')
  })

  it('says nothing about a button the person has just pressed', () => {
    expect(settledSentence({ id: 'q1', granted: false, reason: 'declined', by: 'window' })).toBeNull()
    expect(settledSentence({ id: 'q1', granted: true, reason: null, by: 'window' })).toBeNull()
  })
})

describe('which question is in front of you', () => {
  const at = (id: string, requestedAt: number): ConsentRequestView =>
    readConsentRequest({ ...request, id, requestedAt }) as ConsentRequestView

  it('is always the oldest, so the one about to expire is the one on screen', () => {
    expect(nextQuestion([at('b', 20), at('a', 10), at('c', 30)])?.id).toBe('a')
  })

  it('is null when nothing is outstanding', () => {
    expect(nextQuestion([])).toBeNull()
  })
})
