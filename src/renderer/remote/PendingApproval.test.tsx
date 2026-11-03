/**
 * Approving a device from somewhere other than the settings pane.
 *
 * The flow itself is `DeviceApproval` and is pinned by its own file. What is
 * pinned here is the part that is specific to being opened from an alert: that a
 * decision which has already been made is not asked again, and that the answer
 * is believed only when the roster says so.
 *
 * Both of those exist because this surface is reached from a *notification*,
 * which is by definition slightly out of date. The settings pane is looking at a
 * list somebody is reading; an alert is a sentence that appeared up to a minute
 * ago and may have been answered in another window since.
 */

import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { PendingApproval, approvalOutcome, goneBecause } from './PendingApproval'
import type { RemoteDevice } from './RemoteSection'

function device(overrides: Partial<RemoteDevice> & { id: string }): RemoteDevice {
  return {
    name: 'iPhone',
    state: 'pending',
    addedAt: Date.parse('2026-08-18T07:00:00.000Z'),
    lastSeenAt: null,
    fingerprint: 'ab12 cd34 ef56 7890 abcd ef12',
    ...overrides,
  }
}

describe('a device that is no longer waiting', () => {
  it('has nothing to ask about one that is', () => {
    expect(goneBecause(device({ id: 'a' }))).toBeNull()
  })

  it('says so when it has already been let in', () => {
    // Not an error, and not three questions about a decision that was made. The
    // last screen would otherwise fail on a kind that is already claimed, which
    // reads as a broken app rather than as a question nobody needed to answer.
    expect(goneBecause(device({ id: 'a', state: 'approved' }))).toMatch(/already been let in/)
  })

  it('says so, and says it is final, when it was refused', () => {
    const because = goneBecause(device({ id: 'a', state: 'revoked' }))
    expect(because).toMatch(/refused/)
    // Revocation is permanent — a returning phone pairs again and is issued a new
    // id — so a sentence that left room for "approve it now" would be wrong.
    expect(because).toMatch(/cannot be let in later/)
  })

  it('distinguishes a device that has gone from one that was answered', () => {
    expect(goneBecause(undefined)).toMatch(/not in the list any more/)
  })
})

describe('the answer is what the roster says, not what the call returned', () => {
  const phone = device({ id: 'phone-1' })

  it('accepts an approval the roster confirms', () => {
    expect(approvalOutcome([{ id: 'phone-1', name: 'iPhone', status: 'approved' }], phone)).toEqual({
      ok: true,
    })
  })

  it('refuses to close on a device that is still waiting', () => {
    // The shape of a quiet refusal: the handler answers with the roster whether
    // or not it did anything, so a kind already claimed by another window's
    // approval comes back looking exactly like success.
    const outcome = approvalOutcome([{ id: 'phone-1', name: 'iPhone', status: 'pending' }], phone)
    expect(outcome.ok).toBe(false)
    expect(outcome.ok === false && outcome.because).toMatch(/still waiting/)
  })

  it('says the right thing when the device turns out to be revoked', () => {
    const outcome = approvalOutcome([{ id: 'phone-1', name: 'iPhone', status: 'revoked' }], phone)
    expect(outcome.ok === false && outcome.because).toMatch(/refused/)
  })

  it('treats an unreadable answer as success', () => {
    // Not evidence of failure, and a flow that refused to close on it would
    // leave somebody pressing a button that had already worked.
    expect(approvalOutcome(null, phone)).toEqual({ ok: true })
    expect(approvalOutcome([], phone)).toEqual({ ok: true })
  })
})

describe('before the roster has been read', () => {
  it('says it is reading rather than drawing an empty flow', () => {
    // Static markup runs no effects, so this is the first frame exactly as the
    // sheet paints it. A flow drawn before the device is known would show a
    // fingerprint panel with nothing in it, at the moment somebody is deciding
    // whether to hand over a shell.
    const html = renderToStaticMarkup(
      <PendingApproval deviceId="phone-1" bridge={null} onDone={() => {}} platform="mac" />,
    )
    expect(html).toContain('Reading the device list…')
  })
})
