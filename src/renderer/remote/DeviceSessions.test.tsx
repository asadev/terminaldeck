import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceSessionsView,
  choiceFor,
  resolveDeviceSessionsBridge,
  toRunningSessions,
  toSessionChoices,
  type DeviceSessionsViewProps,
} from './DeviceSessions'
import { sessionDevices } from './RemoteSection'
import type { RemoteDevice } from './RemoteSection'

/**
 * What the per-session panel puts on screen, in each state it can be in.
 *
 * Two things are being pinned and they pull in opposite directions.
 *
 * The first is the states: *All*, *Selected with ticks*, *Selected with none*,
 * and a device nobody has narrowed at all. The last of those is drawn as *All*
 * because that is what it behaves as, and the assertion below is the reason the
 * component may never grow a third visible state — the only way to explain one
 * would be a sentence.
 *
 * The second is the sentence. His governing rule for this round: *"don't put any
 * single statement in anywhere… We want simplicity. Let the smart people use
 * it."* So this file asserts an **absence** — no full stop anywhere in the
 * panel's own text — which is a strange thing to test and the only thing that
 * catches the next well-meant explanatory line.
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * choices as a prop: the component that reads them would otherwise be testable
 * in exactly one state.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone" },
  { id: 'dev-pc', name: 'Office PC' },
]

const RUNNING = [
  { id: 'sess-1', title: 'terminaldeck', cwd: '/Users/apple/Projects/terminaldeck' },
  { id: 'sess-2', title: 'pwa', cwd: '/Users/apple/Projects/terminaldeck/pwa' },
]

function view(over: Partial<DeviceSessionsViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceSessionsView
      devices={DEVICES}
      choices={new Map()}
      running={RUNNING}
      wired={true}
      problem={null}
      busy={null}
      onMode={() => {}}
      onToggle={() => {}}
      {...over}
    />,
  )
}

/** The panel's own words, tags and attributes stripped. */
function words(html: string): string {
  return html
    .replace(/<[^>]*>/g, ' ')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/\s+/g, ' ')
    .trim()
}

describe('the two words, and nothing else', () => {
  it('offers All and Selected for every approved device', () => {
    const html = view()
    expect(html).toMatch(/aria-pressed="true"[^>]*>All</)
    expect(html).toContain('Selected')
    expect(html).toContain("Asad&#x27;s iPhone")
    expect(html).toContain('Office PC')
  })

  it('writes no sentence anywhere on the panel', () => {
    // The whole visible text of every state, concatenated. A full stop is the
    // cheapest proxy for the thing being kept out, and it is the one that would
    // have caught each of the paragraphs he asked to have removed.
    const everything = [
      view(),
      view({ choices: new Map([['dev-phone', { mode: 'selected' as const, sessions: ['sess-1'] }]]) }),
      view({ choices: new Map([['dev-phone', { mode: 'selected' as const, sessions: [] }]]) }),
      view({ running: [] }),
    ]
      .map(words)
      .join(' ')
      // The folder paths are data, not prose, and they are full of dots.
      .replace(/\/[^\s]*/g, '')
    expect(everything).not.toMatch(/\.\s|\.$/)
  })
})

describe('the states', () => {
  it('draws a device nobody has narrowed as All, because that is what it does', () => {
    const html = view({ choices: new Map() })
    expect(html).toMatch(/aria-pressed="true"[^>]*>All</)
    // And no ticks: All has nothing to tick.
    expect(html).not.toContain('type="checkbox"')
  })

  it('ticks exactly what was chosen under Selected', () => {
    const html = view({
      choices: new Map([['dev-phone', { mode: 'selected', sessions: ['sess-2'] }]]),
    })
    expect(html).toMatch(/aria-pressed="true"[^>]*>Selected</)
    // Two boxes, one of them checked, and it is the second.
    const boxes = html.match(/<input[^>]*type="checkbox"[^>]*>/g) ?? []
    expect(boxes).toHaveLength(2)
    expect(boxes[0]).not.toContain('checked')
    expect(boxes[1]).toContain('checked')
  })

  it('shows every box unticked, and says nothing, when Selected holds none', () => {
    const html = view({ choices: new Map([['dev-phone', { mode: 'selected', sessions: [] }]]) })
    const boxes = html.match(/<input[^>]*type="checkbox"[^>]*>/g) ?? []
    expect(boxes).toHaveLength(2)
    expect(boxes.some((box) => box.includes('checked'))).toBe(false)
  })

  it('draws nothing at all rather than an explanation when nothing is running', () => {
    const html = view({
      running: [],
      choices: new Map([['dev-phone', { mode: 'selected', sessions: [] }]]),
    })
    expect(html).not.toContain('type="checkbox"')
    expect(words(html)).toBe("Sessions a device may open Asad's iPhone All Selected Office PC All Selected")
  })

  it('draws nothing at all on a build whose preload does not have the channels', () => {
    expect(view({ wired: false })).toBe('')
  })

  it('draws nothing at all when no device has been approved', () => {
    expect(view({ devices: [] })).toBe('')
  })

  it('stops the controls while a write is in flight', () => {
    const html = view({ busy: 'dev-phone' })
    expect((html.match(/disabled/g) ?? []).length).toBeGreaterThan(0)
  })
})

describe('narrowing what the main process sent', () => {
  it('reads a row it does not understand as Selected rather than All', () => {
    const choices = toSessionChoices([{ deviceId: 'dev-1', mode: 'everything', sessions: ['sess-1'] }])
    expect(choices.get('dev-1')).toEqual({ mode: 'selected', sessions: ['sess-1'] })
  })

  it('keeps no tick list against an All row', () => {
    const choices = toSessionChoices([{ deviceId: 'dev-1', mode: 'all', sessions: ['sess-1'] }])
    expect(choices.get('dev-1')).toEqual({ mode: 'all', sessions: [] })
  })

  it('drops rows with no device id, rather than inventing one', () => {
    expect(toSessionChoices([{ mode: 'all' }, null, 7]).size).toBe(0)
    expect(toSessionChoices('nonsense').size).toBe(0)
  })

  it('drops a session that has already exited', () => {
    const rows = toRunningSessions([
      { id: 'sess-1', title: 'a', cwd: '/tmp', exitCode: null },
      { id: 'sess-2', title: 'b', cwd: '/tmp', exitCode: 0 },
    ])
    // A tick beside a dead session is a control that changes nothing.
    expect(rows.map((row) => row.id)).toEqual(['sess-1'])
  })

  it('falls back to the id when a session has no title', () => {
    expect(toRunningSessions([{ id: 'sess-1', cwd: '/tmp', exitCode: null }])[0].title).toBe('sess-1')
  })

  it('answers All for a device with no row, without inventing a third state', () => {
    expect(choiceFor(new Map(), 'dev-1')).toEqual({ mode: 'all', sessions: [] })
    expect(choiceFor(null, 'dev-1')).toEqual({ mode: 'all', sessions: [] })
  })
})

describe('which devices are listed', () => {
  const devices = [
    { id: 'a', name: 'Approved', state: 'approved' },
    { id: 'b', name: 'Pending', state: 'pending' },
    { id: 'c', name: 'Revoked', state: 'revoked' },
  ] as unknown as RemoteDevice[]

  it('lists approved devices of both kinds, which is the point', () => {
    // Wider than `grantableDevices`, deliberately: his phone is paired as one of
    // his own, and the folder panel drops those.
    expect(sessionDevices(devices).map((d) => d.id)).toEqual(['a'])
  })
})

describe('the bridge', () => {
  it('reports itself unwired when the preload has none of the methods', () => {
    expect(resolveDeviceSessionsBridge({})).toEqual({})
  })

  it('calls through the host object rather than a detached function', () => {
    const host = {
      seen: null as unknown,
      listSessionGrants(this: unknown) {
        return Promise.resolve(this)
      },
    }
    const bridge = resolveDeviceSessionsBridge(host)
    return expect(bridge.listSessionGrants?.()).resolves.toBe(host)
  })
})
