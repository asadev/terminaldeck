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
import { copilotDevices } from './RemoteSection'
import type { RemoteDevice } from './RemoteSection'

/**
 * What this panel says, in each state it can be in.
 *
 * A permission screen has one job it must never get wrong: showing a permission
 * that is not the one on disk. Every failure mode of that is here — the state
 * before the first read lands, a device with no key, a write that failed, and
 * the tier that exists and cannot be granted.
 *
 * The one assertion in this file that is about *absence* is the most important:
 * the third row is present, disabled, and readable. `copilot-grants.ts` keeps
 * the `alter` field in its type for the same reason — a refusal that can be
 * pointed at is checkable, an absence is not — and a person who cannot see that
 * the tier exists will assume the two boxes are everything there is.
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * grants as a prop. The component that reads them would otherwise be testable in
 * exactly one state, the empty one, and the states worth pinning are the others.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone", sealed: true },
  { id: 'dev-tablet', name: 'iPad', sealed: true },
]

function view(over: Partial<DeviceCopilotViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceCopilotView
      devices={DEVICES}
      grants={new Map()}
      wired={true}
      problem={null}
      busy={null}
      onChange={() => {}}
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
    .replace(/\s+/g, ' ')
    .trim()
}

/** How many checkboxes are on screen, and how many of them cannot be ticked. */
function boxes(markup: string): { total: number; disabled: number } {
  const all = markup.match(/<input[^>]*type="checkbox"[^>]*>/g) ?? []
  return { total: all.length, disabled: all.filter((tag) => tag.includes('disabled')).length }
}

/* ======================================================== what it claims -- */

describe('the sentence at the top', () => {
  it('says the default is off, before it says anything else', () => {
    const sentence = text(view())
    expect(sentence).toContain('off for every device')
    // And says what a granted device actually gets, because "a copilot of its
    // own" is the decision the whole design turns on and the thing a person
    // would otherwise assume wrongly.
    expect(sentence).toContain('copilot of its own')
    expect(sentence).toContain('its own conversation')
  })

  it('says a granted device is not typing into the copilot at the desk', () => {
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

/* ========================================================== the two boxes -- */

describe('the two things that can be granted', () => {
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
    // The half that makes `read` worth handing out: it carries no new power.
    expect(sentence).toContain('cannot make it do anything')
  })

  it('draws them ticked exactly as the store says, and not as they were asked for', () => {
    const grants = new Map<string, CopilotAccess>([['dev-phone', { read: true, act: false }]])
    const markup = view({ grants })
    // Two devices: one with read, one with nothing. Three boxes each, so two
    // ticks would mean the panel had invented one.
    expect((markup.match(/checked=""/g) ?? []).length).toBe(1)
  })
})

/* ================================================= the row that cannot be -- */

describe('the tier that exists and cannot be granted', () => {
  it('draws a third row, present and disabled, on every device', () => {
    const markup = view()
    const counted = boxes(markup)
    // Three per device, and one of the three is off.
    expect(counted.total).toBe(DEVICES.length * 3)
    expect(counted.disabled).toBe(DEVICES.length)
  })

  it('names what it would allow and where it can be answered', () => {
    const sentence = text(view())
    expect(sentence).toContain('Change settings and stop your sessions')
    expect(sentence).toContain('Only at this Mac')
    // And the reason, in one clause, because "only at this Mac" without it reads
    // as an unfinished feature rather than as the design.
    expect(sentence).toContain('cannot be the one who confirms it')
  })

  it('never says it is coming', () => {
    const sentence = text(view()).toLowerCase()
    // A disabled control that promises itself is a different control from one
    // that explains itself, and this one is deliberately the second.
    expect(sentence).not.toContain('coming soon')
    expect(sentence).not.toContain('not yet supported')
  })

  it('stays disabled for a device holding everything the panel can give', () => {
    const grants = new Map<string, CopilotAccess>([
      ['dev-phone', { read: true, act: true }],
      ['dev-tablet', { read: true, act: true }],
    ])
    expect(boxes(view({ grants })).disabled).toBe(DEVICES.length)
  })
})

/* ==================================================== states and honesty -- */

describe('what it says before it knows', () => {
  it('says it is reading rather than claiming a device has no access', () => {
    // A pane that says a device has nothing and then changes its mind has told
    // somebody something false about a permission.
    const sentence = text(view({ grants: null }))
    expect(sentence).toContain('Reading…')
    expect(sentence).not.toContain('No access')
  })

  it('stops the boxes while it is reading, and while a write is in flight', () => {
    expect(boxes(view({ grants: null })).disabled).toBe(DEVICES.length * 3)
    const busy = view({ busy: 'dev-phone' })
    // The busy device's three, plus the disabled row on the other one.
    expect(boxes(busy).disabled).toBe(4)
  })

  it('says what is on screen may be stale after a failure', () => {
    const sentence = text(view({ problem: 'Could not save that.' }))
    expect(sentence).toContain('Could not save that.')
    expect(sentence).toContain('may be out of date')
  })

  it('says the feature is not there rather than drawing dead boxes', () => {
    const markup = view({ wired: false })
    expect(text(markup)).toContain('not available in this build')
    // Nothing tickable at all — a control that changes nothing is worse than
    // none, which is the warning this whole panel shipped after.
    expect(boxes(markup).total).toBe(0)
  })

  it('says there is nothing to allow when no device is approved', () => {
    expect(text(view({ devices: [] }))).toContain('nothing to allow')
  })
})

describe('a device with no key', () => {
  it('is drawn, and says why it cannot be given access', () => {
    const markup = view({ devices: [{ id: 'old', name: 'Old iPhone', sealed: false }] })
    const sentence = text(markup)
    expect(sentence).toContain('Cannot be given access')
    expect(sentence).toContain('paired before encrypted channels')
    // And says the remedy, because a row that only states a problem sends the
    // person looking through the rest of the window for the fix.
    expect(sentence).toContain('Pair it again')
    // No boxes at all. A switch with nothing behind it is the exact defect the
    // design warned about shipping.
    expect(boxes(markup).total).toBe(0)
  })
})

/* ============================================================= narrowing -- */

describe('reading what the main process sent', () => {
  it('takes only a literal true', () => {
    const grants = toDeviceCopilot([
      { deviceId: 'a', tiers: { read: true, act: false } },
      { deviceId: 'b', tiers: { read: 'true', act: 1 } },
    ])
    expect(grants.get('a')).toEqual({ read: true, act: false })
    // Guessing generously at a permission is how a permission gets widened by a
    // type coercion nobody wrote down.
    expect(grants.get('b')).toEqual({ read: false, act: false })
  })

  it('never reads an alter tier, even when one is in the answer', () => {
    const grants = toDeviceCopilot([{ deviceId: 'a', tiers: { read: true, act: true, alter: true } }])
    expect(grants.get('a')).toEqual({ read: true, act: true })
    // The field is not merely false — it is not there. A panel holding an
    // `alter` key would eventually draw it, and a permission drawn is a
    // permission somebody believes they have.
    expect(Object.keys(grants.get('a') ?? {}).sort()).toEqual(['act', 'read'])
  })

  it('drops anything unreadable rather than inventing a device', () => {
    expect(toDeviceCopilot(undefined).size).toBe(0)
    expect(toDeviceCopilot({ devices: [] }).size).toBe(0)
    expect(toDeviceCopilot([null, 7, { deviceId: '' }, { tiers: {} }]).size).toBe(0)
  })

  it('treats a missing device as no access', () => {
    const grants = toDeviceCopilot([])
    expect(grants.get('never-granted')).toBeUndefined()
    expect(grantsNothing({ read: false, act: false })).toBe(true)
    expect(grantsNothing({ read: true, act: false })).toBe(false)
  })
})

describe('the summary beside a device name', () => {
  const sealed = { id: 'a', name: 'a', sealed: true }
  it('names the outcome rather than the tier', () => {
    expect(summaryFor(sealed, { read: false, act: false }, false)).toBe('No access')
    expect(summaryFor(sealed, { read: true, act: false }, false)).toBe('Can watch')
    expect(summaryFor(sealed, { read: true, act: true }, false)).toBe('Can watch and ask it to work')
  })

  it('says it is reading before the first answer lands', () => {
    expect(summaryFor(sealed, { read: false, act: false }, true)).toBe('Reading…')
  })

  it('says a keyless device cannot be given access, whatever else is true', () => {
    const old = { id: 'a', name: 'a', sealed: false }
    expect(summaryFor(old, { read: true, act: true }, false)).toBe('Cannot be given access')
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
    // somebody ticks a box, and nothing above this line would notice.
    const host = {
      me: 'deck',
      listDeviceCopilot(this: { me: string }) {
        return Promise.resolve(this.me)
      },
      setDeviceCopilot: () => Promise.resolve([]),
    }
    const bridge = resolveDeviceCopilotBridge(host)
    await expect(bridge.listDeviceCopilot?.()).resolves.toBe('deck')
  })

  it('passes the device and both tiers through untouched', async () => {
    const seen: unknown[] = []
    const bridge = resolveDeviceCopilotBridge({
      listDeviceCopilot: () => Promise.resolve([]),
      setDeviceCopilot: (...args: unknown[]) => {
        seen.push(args)
        return Promise.resolve([])
      },
    })
    await bridge.setDeviceCopilot?.('dev-phone', { read: true, act: false })
    expect(seen).toEqual([['dev-phone', { read: true, act: false }]])
  })
})
