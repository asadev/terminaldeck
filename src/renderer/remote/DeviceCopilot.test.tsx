import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceCopilotView,
  grantsNothing,
  resolveDeviceCopilotBridge,
  summaryFor,
  toDeviceCopilot,
  type CopilotAccess,
  type DeviceCopilotViewProps,
} from './DeviceCopilot'
import { formatCode } from '../../shared/short-code'
import { copilotDevices } from './RemoteSection'
import type { RemoteDevice } from './RemoteSection'

/**
 * What this panel says, in each state it can be in.
 *
 * A permission screen has one job it must never get wrong: showing a permission
 * that is not the one on disk. Every failure mode of that is here — the state
 * before the first read lands, a device with no key, a write that failed, and
 * the difference between a device that is connected and one that is not.
 *
 * ## What changed, and what the assertions moved to
 *
 * This file used to pin a third checkbox that was **present and permanently
 * disabled**, so that the absence of the `alter` tier was something a person
 * could point at. The tier is grantable now — connecting the copilot became its
 * own authorisation, with its own code and its own credential, so the second
 * factor moved from *be at the desk* to *have been deliberately authorised*.
 *
 * So the assertion that replaced it is the one about a device that is **not
 * connected**: it gets no checkboxes at all, only a Connect button, because
 * ticking a box cannot give copilot access to a device that has not been through
 * the ceremony. That is the same property the old disabled row was defending —
 * a control must never suggest a permission the store would not grant — pointed
 * at the thing that is now true.
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * state as props. The component that reads it would otherwise be testable in
 * exactly one state, the empty one, and the states worth pinning are the others.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone", sealed: true },
  { id: 'dev-tablet', name: 'iPad', sealed: true },
]

const ALL: CopilotAccess = { read: true, act: true, alter: true }

/** Both devices connected, with whatever tiers are given. */
function connected(access: CopilotAccess = ALL): Map<string, CopilotAccess> {
  return new Map(DEVICES.map((device) => [device.id, access]))
}

function view(over: Partial<DeviceCopilotViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceCopilotView
      devices={DEVICES}
      links={connected()}
      wired={true}
      problem={null}
      busy={null}
      offer={null}
      onChange={() => {}}
      onConnect={() => {}}
      onDisconnect={() => {}}
      platform="mac"
      {...over}
    />,
  )
}

/** Markup without its tags, so an assertion reads the sentence a person reads. */
function text(markup: string): string {
  return markup
    .replace(/<[^>]*>/g, ' ')
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&rsquo;/g, '’')
    .replace(/\s+/g, ' ')
    .trim()
}

/** How many checkboxes are on screen, and how many of them cannot be ticked. */
function boxes(markup: string): { total: number; disabled: number } {
  const all = markup.match(/<input[^>]*type="checkbox"[^>]*>/g) ?? []
  return { total: all.length, disabled: all.filter((tag) => tag.includes('disabled')).length }
}

/** How many buttons, and how many are off. */
function buttons(markup: string): { total: number; disabled: number } {
  const all = markup.match(/<button[^>]*>/g) ?? []
  return { total: all.length, disabled: all.filter((tag) => tag.includes('disabled')).length }
}

/* ======================================================== what it claims -- */

describe('the sentence at the top', () => {
  it('says pairing gives no copilot access, before it says anything else', () => {
    const sentence = text(view())
    expect(sentence).toContain('not connected to any device')
    // The load-bearing sentence of the whole revision: a device paired for
    // terminals has no copilot reach at all, and somebody reading this screen
    // should learn that before they learn anything else about it.
    expect(sentence).toContain('Pairing a device for terminals gives it no copilot access')
    // And says what a connected device actually gets, because "a copilot of its
    // own" is the decision the whole design turns on and the thing a person
    // would otherwise assume wrongly.
    expect(sentence).toContain('copilot of its own')
    expect(sentence).toContain('its own conversation')
  })

  it('says a connected device is not typing into the copilot at the desk', () => {
    // The misconception this panel has to pre-empt. Somebody reading "let my
    // phone control my copilot" will picture one conversation, and the reason it
    // is not one is a security property rather than a design preference.
    expect(text(view())).toContain('never typing into the copilot you are talking to')
  })

  it('says nothing at all about tiers', () => {
    const sentence = text(view()).toLowerCase()
    // "read", "act" and "alter" are words from this codebase's permission model.
    // A person deciding whether to trust a device cannot act on them.
    expect(sentence).not.toContain('read tier')
    expect(sentence).not.toContain('act tier')
    expect(sentence).not.toContain('alter')
  })
})

/* ============================================== connecting, and not having -- */

describe('a device that is not connected', () => {
  const none = new Map<string, CopilotAccess>()

  /**
   * **No checkboxes at all.**
   *
   * This is the assertion that replaced the permanently-disabled third row, and
   * it defends the same property: a control must never suggest a permission the
   * store would not grant. `CopilotLinks.set` refuses to create a record for a
   * device with no connection, so a checkbox here would be a switch that changes
   * nothing — the exact defect this panel was warned about shipping.
   */
  it('offers a connect button and nothing tickable', () => {
    const markup = view({ links: none })
    expect(boxes(markup).total).toBe(0)
    expect(buttons(markup).total).toBe(DEVICES.length)
    expect(text(markup)).toContain('Connect the copilot')
  })

  it('says what connecting will hand over, before it is handed over', () => {
    const sentence = text(view({ links: none }))
    expect(sentence).toContain('Shows a code to type on')
    expect(sentence).toContain('confirm changes on the device itself')
    // And that it can be narrowed afterwards, so "all three" does not read as
    // an all-or-nothing decision somebody has to get right first time.
    expect(sentence).toContain('narrow that here afterwards')
  })

  it('shows the code, formatted, with what it is for and how long it lives', () => {
    const markup = view({
      links: none,
      offer: { deviceId: 'dev-phone', code: '481902', expiresAt: Date.now() + 60_000 },
    })
    const sentence = text(markup)
    /*
     * Through `formatCode`, whatever that decides.
     *
     * It is an identity function today and that is deliberate: it is the single
     * place that says a code has no grouping character, so the day somebody
     * decides `481 902` reads better on the desktop they change one line and
     * `normaliseCode` already undoes it. A space added here instead would
     * produce a code that is correct on this screen and refused by the machine
     * on the other.
     */
    expect(sentence).toContain(formatCode('481902'))
    expect(sentence).toContain('within a minute')
    expect(sentence).toContain('works once')
    // Only the device it was minted for. A code on screen beside the wrong name
    // is a code somebody types into the wrong phone.
    expect(sentence).toContain('Connect the copilot')
  })

  it('says it is not connected beside the name', () => {
    expect(text(view({ links: none }))).toContain('Not connected')
  })
})

/* ========================================================= the three boxes -- */

describe('the three things a connected device can be given', () => {
  it('labels them by outcome, and says which one spends money', () => {
    const sentence = text(view())
    expect(sentence).toContain('Watch the copilot')
    expect(sentence).toContain('Ask it to work')
    // The fact that changes the answer. A person weighing whether to let a phone
    // drive an agent needs to know it costs them, and it must not be discovered
    // on a bill.
    expect(sentence).toContain('This spends money')
  })

  it('says what watching does and does not get you', () => {
    const sentence = text(view())
    expect(sentence).toContain('See what it is doing, what it started, and what it was refused')
    // The half that makes the watching grant worth handing out: it carries no
    // new power.
    expect(sentence).toContain('cannot make it do anything')
  })

  /**
   * The third box says **where the confirmation appears**, which is the whole of
   * what ticking it changes.
   *
   * Not "grants alter" and not "full control": every change is still confirmed
   * one at a time, and the only thing that moves is the screen the question is
   * drawn on and the thumb that answers it. A person who does not understand
   * that has not been told what they are agreeing to.
   */
  it('says the third box moves the confirmation onto the device', () => {
    const sentence = text(view())
    expect(sentence).toContain('Change settings and stop your sessions')
    expect(sentence).toContain('confirmed one at a time')
    expect(sentence).toContain('the confirmation appears on')
    expect(sentence).toContain('whoever is holding it answers')
    // And how to keep them here, because a box whose only description is what it
    // enables leaves the person who wants the other thing with nothing to do.
    expect(sentence).toContain('Leave this off')
  })

  it('draws them ticked exactly as the store says, and not as they were asked for', () => {
    const links = new Map<string, CopilotAccess>([
      ['dev-phone', { read: true, act: false, alter: false }],
      ['dev-tablet', { read: true, act: true, alter: false }],
    ])
    const markup = view({ links })
    // Three ticks across two connected devices: one and two.
    expect((markup.match(/checked=""/g) ?? []).length).toBe(3)
  })

  it('gives a connected device three boxes, none of them disabled', () => {
    const counted = boxes(view())
    expect(counted.total).toBe(DEVICES.length * 3)
    expect(counted.disabled).toBe(0)
  })
})

/* ============================================================ disconnecting */

describe('taking copilot access away', () => {
  it('offers a disconnect that says what it does and what it leaves alone', () => {
    const sentence = text(view())
    expect(sentence).toContain('Disconnect the copilot')
    expect(sentence).toContain('immediately')
    expect(sentence).toContain('destroys its credential')
    // The other half of *revoking one does not revoke the other*, said where the
    // person doing it is looking.
    expect(sentence).toContain('keeps its terminals')
  })
})

/* ==================================================== states and honesty -- */

describe('what it says before it knows', () => {
  it('says it is reading rather than claiming a device has no access', () => {
    // A pane that says a device has nothing and then changes its mind has told
    // somebody something false about a permission.
    const sentence = text(view({ links: null }))
    expect(sentence).toContain('Reading…')
    expect(sentence).not.toContain('Not connected —')
  })

  it('stops the controls while it is reading, and while a write is in flight', () => {
    // Reading: nothing is known, so nothing is connected yet and every device
    // shows a Connect button — all of them off.
    const reading = view({ links: null })
    expect(buttons(reading).disabled).toBe(buttons(reading).total)

    const busy = view({ busy: 'dev-phone' })
    // The busy device's three boxes; the other device's are live.
    expect(boxes(busy).disabled).toBe(3)
  })

  it('says what is on screen may be stale after a failure', () => {
    const sentence = text(view({ problem: 'Could not save that.' }))
    expect(sentence).toContain('Could not save that.')
    expect(sentence).toContain('may be out of date')
  })

  it('says the feature is not there rather than drawing dead controls', () => {
    const markup = view({ wired: false })
    expect(text(markup)).toContain('not available in this build')
    // Nothing tickable and nothing pressable — a control that changes nothing is
    // worse than none, which is the warning this whole panel shipped after.
    expect(boxes(markup).total).toBe(0)
    expect(buttons(markup).total).toBe(0)
  })

  it('says there is nothing to connect when no device is approved', () => {
    expect(text(view({ devices: [] }))).toContain('nothing to connect')
  })
})

describe('a device with no key', () => {
  it('is drawn, and says why it cannot be connected', () => {
    const markup = view({ devices: [{ id: 'old', name: 'Old iPhone', sealed: false }] })
    const sentence = text(markup)
    expect(sentence).toContain('Cannot be connected')
    expect(sentence).toContain('paired before encrypted channels')
    // And says the remedy, because a row that only states a problem sends the
    // person looking through the rest of the window for the fix.
    expect(sentence).toContain('Pair it again')
    // No boxes and no button. A control with nothing behind it is the exact
    // defect the design warned about shipping.
    expect(boxes(markup).total).toBe(0)
    expect(buttons(markup).total).toBe(0)
  })
})

/* ============================================================= narrowing -- */

describe('reading what the main process sent', () => {
  it('takes only a literal true', () => {
    const links = toDeviceCopilot([
      { deviceId: 'a', tiers: { read: true, act: false, alter: false } },
      { deviceId: 'b', tiers: { read: 'true', act: 1, alter: 'yes' } },
    ])
    expect(links.get('a')).toEqual({ read: true, act: false, alter: false })
    // Guessing generously at a permission is how a permission gets widened by a
    // type coercion nobody wrote down.
    expect(links.get('b')).toEqual({ read: false, act: false, alter: false })
  })

  /**
   * `alter` is read now, and that is the change.
   *
   * This test used to assert the opposite — that an `alter` field in the answer
   * was dropped, so a panel could not draw a permission that did not exist. It
   * exists, because a copilot connection is its own authorisation, and a panel
   * that hid it would be concealing the most consequential thing a connected
   * device holds.
   */
  it('reads the alter tier, because it is a real one', () => {
    const links = toDeviceCopilot([{ deviceId: 'a', tiers: { read: true, act: true, alter: true } }])
    expect(links.get('a')).toEqual({ read: true, act: true, alter: true })
  })

  /**
   * A connection with nothing ticked is **not** the same as no connection.
   *
   * The panel this replaced collapsed them, correctly, because a grant of
   * nothing and no grant were the same fact. They are not any more: an all-false
   * row still holds a credential and can still open a copilot connection. Only
   * one of the two has something to revoke.
   */
  it('keeps a connection that has been left able to do nothing', () => {
    const links = toDeviceCopilot([{ deviceId: 'a', tiers: {} }])
    expect(links.has('a')).toBe(true)
    expect(grantsNothing(links.get('a') ?? { read: true, act: true, alter: true })).toBe(true)
  })

  it('drops anything unreadable rather than inventing a device', () => {
    expect(toDeviceCopilot(undefined).size).toBe(0)
    expect(toDeviceCopilot({ links: [] }).size).toBe(0)
    expect(toDeviceCopilot([null, 7, { deviceId: '' }]).size).toBe(0)
  })

  it('treats a missing device as no connection', () => {
    expect(toDeviceCopilot([]).get('never-connected')).toBeUndefined()
    expect(grantsNothing({ read: false, act: false, alter: false })).toBe(true)
    expect(grantsNothing({ read: false, act: false, alter: true })).toBe(false)
  })
})

describe('the summary beside a device name', () => {
  const sealed = { id: 'a', name: 'a', sealed: true }
  it('names the outcome rather than the tier', () => {
    expect(summaryFor(sealed, { read: false, act: false, alter: false }, false, false)).toBe(
      'Not connected',
    )
    expect(summaryFor(sealed, { read: false, act: false, alter: false }, false)).toBe(
      'Connected — allowed nothing',
    )
    expect(summaryFor(sealed, { read: true, act: false, alter: false }, false)).toBe(
      'Connected — can watch',
    )
    expect(summaryFor(sealed, { read: true, act: true, alter: false }, false)).toBe(
      'Connected — can watch and ask it to work',
    )
    expect(summaryFor(sealed, { read: true, act: true, alter: true }, false)).toBe(
      'Connected — can watch, work and confirm changes',
    )
  })

  it('says it is reading before the first answer lands', () => {
    expect(summaryFor(sealed, { read: false, act: false, alter: false }, true)).toBe('Reading…')
  })

  it('says a keyless device cannot be connected, whatever else is true', () => {
    const old = { id: 'a', name: 'a', sealed: false }
    expect(summaryFor(old, { read: true, act: true, alter: true }, false)).toBe('Cannot be connected')
  })
})

/* =============================================================== plumbing -- */

describe('which devices reach this panel', () => {
  function device(over: Partial<RemoteDevice> & { id: string }): RemoteDevice {
    return {
      name: over.id,
      state: 'approved',
      addedAt: 0,
      lastSeenAt: null,
      fingerprint: 'AAAA-BBBB',
      ...over,
    }
  }

  it('is approved devices only, keyed by whether they hold a key', () => {
    const rows = copilotDevices([
      device({ id: 'approved' }),
      device({ id: 'pending', state: 'pending' }),
      device({ id: 'revoked', state: 'revoked' }),
      device({ id: 'keyless', fingerprint: null }),
    ])
    expect(rows.map((r) => r.id)).toEqual(['approved', 'keyless'])
    // Carried, not filtered: a device missing from here while sitting in the
    // roster two headings above would read as a bug in the panel.
    expect(rows.find((r) => r.id === 'keyless')?.sealed).toBe(false)
  })
})

describe('the bridge', () => {
  it('is empty when the preload does not expose the channels', () => {
    expect(resolveDeviceCopilotBridge({})).toEqual({})
    expect(resolveDeviceCopilotBridge(null)).toEqual({})
  })

  it('calls through the host object rather than detaching the function', async () => {
    // A preload with methods on a prototype throws on `this` the first time
    // somebody presses Connect, and nothing above this line would notice.
    const host = {
      me: 'deck',
      listDeviceCopilot(this: { me: string }) {
        return Promise.resolve(this.me)
      },
      setDeviceCopilot: () => Promise.resolve([]),
      copilotConnectCode: () => Promise.resolve(null),
      disconnectDeviceCopilot: () => Promise.resolve([]),
      onDeviceCopilotChanged: () => () => {},
    }
    const bridge = resolveDeviceCopilotBridge(host)
    await expect(bridge.listDeviceCopilot?.()).resolves.toBe('deck')
  })

  it('passes the device and all three tiers through untouched', async () => {
    const seen: unknown[] = []
    const bridge = resolveDeviceCopilotBridge({
      listDeviceCopilot: () => Promise.resolve([]),
      setDeviceCopilot: (...args: unknown[]) => {
        seen.push(args)
        return Promise.resolve([])
      },
      copilotConnectCode: () => Promise.resolve(null),
      disconnectDeviceCopilot: () => Promise.resolve([]),
      onDeviceCopilotChanged: () => () => {},
    })
    await bridge.setDeviceCopilot?.('dev-phone', { read: true, act: false, alter: true })
    expect(seen).toEqual([['dev-phone', { read: true, act: false, alter: true }]])
  })

  it('exposes the channels that make, end and announce a connection', () => {
    const bridge = resolveDeviceCopilotBridge({
      listDeviceCopilot: () => Promise.resolve([]),
      setDeviceCopilot: () => Promise.resolve([]),
      copilotConnectCode: () => Promise.resolve(null),
      disconnectDeviceCopilot: () => Promise.resolve([]),
      onDeviceCopilotChanged: () => () => {},
    })
    // Named rather than counted: the first two *are* the separate authorisation,
    // and a panel wired without them would silently fall back to being a
    // checkbox. The third is the only way this screen learns that the code it is
    // showing has been used — without it the panel would keep showing a spent
    // code and then a Connect button for a device that is connected.
    expect(typeof bridge.copilotConnectCode).toBe('function')
    expect(typeof bridge.disconnectDeviceCopilot).toBe('function')
    expect(typeof bridge.onDeviceCopilotChanged).toBe('function')
  })
})
