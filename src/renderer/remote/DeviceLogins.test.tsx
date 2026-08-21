import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceLoginsView,
  choiceFor,
  resolveDeviceLoginsBridge,
  toAccountChoices,
  type DeviceLoginsViewProps,
} from './DeviceLogins'

/**
 * What the per-login panel puts on screen, in each state it can be in.
 *
 * The states are the design and there are four: *All*, *Selected with ticks*,
 * *Selected with none*, and a device nobody has narrowed. The last is drawn as
 * *All* because that is what it behaves as — an absent record means every login
 * on this machine, which is what every device paired before the choice existed
 * has — and the assertion below is the reason this panel may never grow a third
 * visible state: the only way to explain one would be a sentence.
 *
 * The names are the other half. Two of the three rows on every machine are
 * called `Default` and `Default (Codex CLI)` — keys `profiles.ts` mints,
 * identical on every install — and a person cannot choose between two rows with
 * the same word on them:
 *
 *   > *"It is saying default, so never default. Whatever is actual account
 *   > should be visible here, never default."*
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * choices and its logins as props.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone" },
  { id: 'dev-pc', name: 'Office PC' },
]

const LOGINS = [
  { id: 'system', label: 'imzapremium@gmail.com' },
  { id: 'p-work', label: 'work@example.com' },
]

function view(over: Partial<DeviceLoginsViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceLoginsView
      devices={DEVICES}
      choices={new Map()}
      logins={LOGINS}
      wired={true}
      problem={null}
      busy={null}
      onMode={() => {}}
      onToggle={() => {}}
      {...over}
    />,
  )
}

describe('the four states', () => {
  it('draws a device nobody has narrowed as All, because that is what it behaves as', () => {
    const html = view({ choices: new Map() })
    expect(html).toContain('aria-pressed="true"')
    // No ticks under All: All means all, and a list under it would be a set of
    // boxes that decide nothing.
    expect(html).not.toContain('work@example.com')
  })

  it('lists the logins by their addresses under Selected, never by the profile key', () => {
    const html = view({
      choices: new Map([['dev-phone', { mode: 'selected' as const, accounts: ['p-work'] }]]),
    })
    expect(html).toContain('work@example.com')
    expect(html).toContain('imzapremium@gmail.com')
    expect(html).not.toContain('Default')
  })

  it('ticks exactly the logins that were given', () => {
    const html = view({
      choices: new Map([['dev-phone', { mode: 'selected' as const, accounts: ['p-work'] }]]),
    })
    // One box checked, and it is the one in the record.
    expect(html.match(/checked=""/g) ?? []).toHaveLength(1)
  })

  it('draws Selected-with-nothing as a real state rather than as All', () => {
    const html = view({
      choices: new Map([['dev-phone', { mode: 'selected' as const, accounts: [] }]]),
    })
    // The list is there and nothing in it is ticked. That is *none*, which is
    // the answer a tick list alone cannot express, and on the other machine it
    // produces no account chip at all.
    expect(html).toContain('work@example.com')
    expect(html).not.toContain('checked=""')
  })
})

describe('what the panel does not say', () => {
  it('keeps no explanatory sentence anywhere in it', () => {
    /*
     * His governing rule for this round: *"don't put any single statement in
     * anywhere. Everywhere you are putting a lot of statements… We want
     * simplicity."* A heading, a name, two buttons, a tick per login — and a
     * full stop is what a well-meant explanation arrives with.
     */
    let text = view({
      choices: new Map([['dev-phone', { mode: 'selected' as const, accounts: [] }]]),
    }).replace(/<[^>]+>/g, ' ')
    // The logins' own labels are taken out first: they are email addresses, and
    // the dots in them belong to the person's account rather than to this
    // panel's prose. What is left is every word the panel wrote itself.
    for (const login of LOGINS) text = text.split(login.label).join(' ')
    expect(text).not.toContain('.')
  })

  it('draws nothing at all when there are no guests, or no channels', () => {
    expect(view({ devices: [] })).toBe('')
    expect(view({ wired: false })).toBe('')
  })
})

describe('reading what the main process sent', () => {
  it('reads a device with no row as All', () => {
    expect(choiceFor(new Map(), 'dev-phone')).toEqual({ mode: 'all', accounts: [] })
    expect(choiceFor(null, 'dev-phone')).toEqual({ mode: 'all', accounts: [] })
  })

  it('narrows a row it cannot understand rather than widening it', () => {
    const choices = toAccountChoices([
      { deviceId: 'dev-phone', mode: 'everything', accounts: ['p-work', 7] },
      { deviceId: '', mode: 'all', accounts: [] },
      'not a row',
    ])
    // Anything that is not exactly `all` is `selected`, which shares only what
    // parsed — the same direction the store reads a malformed row in. A record
    // this side cannot understand must never come out wider than it went in.
    expect(choices.get('dev-phone')).toEqual({ mode: 'selected', accounts: ['p-work'] })
    expect(choices.size).toBe(1)
  })

  it('takes the bridge only when both channels are there', () => {
    expect(resolveDeviceLoginsBridge({})).toEqual({})
    const bridge = resolveDeviceLoginsBridge({
      listAccountGrants: () => Promise.resolve([]),
      setAccountGrants: () => Promise.resolve([]),
    })
    expect(typeof bridge.listAccountGrants).toBe('function')
    expect(typeof bridge.setAccountGrants).toBe('function')
  })
})
