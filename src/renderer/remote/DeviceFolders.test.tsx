import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceFoldersView,
  folderName,
  resolveDeviceFoldersBridge,
  summaryFor,
  toDeviceFolders,
  type DeviceFoldersViewProps,
} from './DeviceFolders'
import { grantableDevices } from './RemoteSection'
import type { RemoteDevice } from './RemoteSection'

/**
 * What this panel says, in each state it can be in.
 *
 * The states are the whole feature. This screen is the answer to "why does my
 * phone only offer one folder", so the one thing it may never do is describe a
 * device inaccurately — and its three states look alike enough that flattening
 * two of them is an easy edit to make and an impossible one to notice:
 *
 *   - **not chosen** — nobody has picked, so the device gets whatever the
 *     desktop has open. Every phone paired before this feature is here.
 *   - **a list** — those folders and no others.
 *   - **empty** — somebody removed the last one, so it can start nothing.
 *
 * "Not chosen" and "empty" are the pair that matters. Draw one as the other and
 * the panel tells someone a working phone is dead, or that a phone they
 * deliberately cut off is fine.
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * grants as a prop — the component that reads them would otherwise be testable
 * in exactly one state, the empty one, and the states worth pinning are the
 * other three.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone" },
  { id: 'dev-tablet', name: 'iPad' },
]

function view(over: Partial<DeviceFoldersViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceFoldersView
      devices={DEVICES}
      grants={new Map()}
      wired={true}
      problem={null}
      busy={null}
      onAdd={() => {}}
      onRemove={() => {}}
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

/* ========================================================== what it claims -- */

describe('the sentence at the top', () => {
  /*
   * Pinned to the words, not to the existence of a paragraph. Someone who reads
   * this screen as a lock will hand a device to another person on the strength
   * of it — so "this is not confinement" has to survive every future edit, and
   * a test that only checked a <p> was present would let it be softened away.
   */
  it('says plainly that this is not a sandbox', () => {
    const said = text(view())
    expect(said).toContain('Pick where each device can start a session')
    expect(said).toContain('That is all this does')
    // The mechanism, in words a non-engineer can act on: it moves.
    expect(said).toContain('it can move to any other folder')
    expect(said).toContain('not for keeping anyone out')
  })

  it('never claims the device is confined to what it was given', () => {
    const said = text(view()).toLowerCase()
    for (const lie of ['sandbox', 'restricted to', 'confined', 'cannot leave', 'only access']) {
      expect(said).not.toContain(lie)
    }
  })

  it('calls the machine what the reader would call it', () => {
    expect(text(view({ platform: 'windows' }))).toContain('this PC')
    expect(text(view({ platform: 'mac' }))).toContain('this Mac')
  })
})

/* ============================================================ three states -- */

describe('a device nobody has chosen for', () => {
  /*
   * The state every already-paired phone is in. It is written as a sentence
   * rather than drawn as an empty list because those two are the states this
   * panel most easily confuses, and this is the one where the device works.
   */
  it('says so, and says what it gets instead', () => {
    const said = text(view({ grants: new Map() }))
    expect(said).toContain('Not chosen')
    expect(said).toContain('whichever project is open on this Mac')
  })

  it('is not described as having no folders', () => {
    expect(text(view({ grants: new Map() }))).not.toContain('cannot start a session')
  })
})

describe('a device whose folders were all removed', () => {
  it('is told apart from one nobody has chosen for', () => {
    const said = text(view({ grants: new Map([['dev-phone', []]]) }))
    expect(said).toContain('No folders. This device cannot start a session.')
    // And the *other* device, which has no row at all, still reads as untouched.
    expect(said).toContain('Not chosen')
  })
})

describe('a device with a list', () => {
  const grants = new Map([['dev-phone', ['/Users/asad/Projects/terminaldeck', '/Users/asad/site']]])

  it('shows every folder, with the full path under the name', () => {
    const said = text(view({ grants }))
    expect(said).toContain('terminaldeck')
    expect(said).toContain('/Users/asad/Projects/terminaldeck')
    expect(said).toContain('site')
    expect(said).toContain('2 folders')
  })

  /*
   * The path line ellipsises, and a browser does not add a tooltip to text it
   * clipped — an assumption that is widely held and has never been true. Without
   * the attribute the tail of a deep path is unreachable rather than hidden, on
   * the one screen whose job is telling two similar folders apart.
   */
  it('keeps the whole path reachable once the line is clipped', () => {
    expect(view({ grants })).toContain('title="/Users/asad/Projects/terminaldeck"')
  })

  it('offers a Remove on each one and an Add on the device', () => {
    const markup = view({ grants })
    expect(markup.match(/Remove/g)).toHaveLength(2)
    expect(markup).toContain('Add a folder…')
  })

  /*
   * Rule 1.1: a hover state is a promise. Every button drawn here does
   * something, so the only honest way to show a write in flight is to stop
   * them — a Remove that stayed live during a save would queue a second write
   * against a list the panel is about to replace.
   */
  it('stops every button while one device is being written', () => {
    const markup = view({ grants, busy: 'dev-phone' })
    expect(markup).toContain('Saving…')
    expect(markup.match(/disabled/g)?.length).toBeGreaterThanOrEqual(3)
  })
})

describe('before the first read lands', () => {
  it('says it is reading rather than claiming nobody has chosen', () => {
    const said = text(view({ grants: null }))
    expect(said).toContain('Reading…')
    expect(said).not.toContain('Not chosen')
  })
})

/* ================================================================ nothing -- */

describe('when there is nothing to choose for', () => {
  it('explains the empty screen instead of drawing an empty list', () => {
    expect(text(view({ devices: [] }))).toContain('No device has been approved yet')
  })

  /*
   * The `browserViewClaim`/`browserClaim` failure, one panel over: a component
   * whose preload method is missing renders a fallback that looks like an
   * unimplemented feature. Saying so is the difference between "this build
   * cannot do it" and a screen that appears broken.
   */
  it('says the build cannot do it, rather than showing dead controls', () => {
    const markup = view({ wired: false })
    expect(text(markup)).toContain('not available in this build')
    expect(markup).not.toContain('Add a folder…')
  })
})

describe('when a read or a write failed', () => {
  it('warns that what is on screen may be stale, and still shows it', () => {
    const markup = view({
      grants: new Map([['dev-phone', ['/Users/asad/site']]]),
      problem: 'Could not save that.',
    })
    expect(text(markup)).toContain('Could not save that. What is below may be out of date.')
    // The list stays. Blanking it would replace a stale answer with no answer,
    // which is worse: the user loses the only record of what they had chosen.
    expect(text(markup)).toContain('/Users/asad/site')
  })
})

/* =========================================================== the narrowing -- */

describe('reading what the main process sent', () => {
  it('keeps a device with an empty list, because empty is a decision', () => {
    const grants = toDeviceFolders([{ deviceId: 'dev-phone', folders: [] }])
    expect(grants.get('dev-phone')).toEqual([])
    // Present-and-empty, not absent. `has` and `get` disagree for exactly the
    // two states this panel must not merge.
    expect(grants.has('dev-phone')).toBe(true)
  })

  it('drops entries it cannot read rather than inventing a state for them', () => {
    const grants = toDeviceFolders([
      { deviceId: 'ok', folders: ['/a'] },
      { deviceId: '', folders: ['/b'] },
      { deviceId: 'no-list' },
      null,
      'nonsense',
    ])
    expect([...grants.keys()]).toEqual(['ok'])
  })

  it('survives an answer that is not a list at all', () => {
    expect(toDeviceFolders(undefined).size).toBe(0)
    expect(toDeviceFolders({ devices: [] }).size).toBe(0)
  })

  it('drops a folder that is not a string, keeping the rest of the device', () => {
    const grants = toDeviceFolders([{ deviceId: 'ok', folders: ['/a', 7, '', '/b'] }])
    expect(grants.get('ok')).toEqual(['/a', '/b'])
  })
})

describe('the name shown for a folder', () => {
  it('is the last segment, on either separator', () => {
    expect(folderName('/Users/asad/Projects/terminaldeck')).toBe('terminaldeck')
    expect(folderName('C:\\Users\\Asad\\proj')).toBe('proj')
  })

  it('survives a trailing separator rather than going blank', () => {
    expect(folderName('/Users/asad/site/')).toBe('site')
  })

  it('falls back to the path when there is no segment to show', () => {
    expect(folderName('/')).toBe('/')
  })
})

describe('the line under a device name', () => {
  it('counts in words a person reads, singular and plural', () => {
    expect(summaryFor(['/a'], true)).toBe('1 folder')
    expect(summaryFor(['/a', '/b'], true)).toBe('2 folders')
  })

  it('never says "not chosen" before anything has been read', () => {
    expect(summaryFor(null, false)).toBe('Reading…')
  })

  /*
   * It used to return the whole explanation — "Not chosen — this device can
   * start a session in whichever project is open on this Mac." — which three
   * devices in the ordinary state printed verbatim three times down one column.
   * The state is a label; what it means belongs above the list, once.
   */
  it('labels the state without explaining it on every card', () => {
    const line = summaryFor(null, true)
    expect(line).toBe('Not chosen')
    expect(line).not.toMatch(/session/)
  })
})

/* ================================================================ the bridge */

describe('resolving the preload', () => {
  it('reports nothing wired when the host has no methods', () => {
    expect(resolveDeviceFoldersBridge({})).toEqual({})
    expect(resolveDeviceFoldersBridge(null)).toEqual({})
  })

  /*
   * Called through the host object, never torn off it. A preload that exposed
   * methods on a prototype would throw on `this` the first time a button was
   * pressed — which is a runtime failure in a panel that tested fine, because
   * the detached function still exists and still has the right name.
   */
  it('keeps the host as the receiver', async () => {
    const host = {
      me: 'deck',
      listDeviceFolders(this: { me: string }) {
        return Promise.resolve(this.me)
      },
    }
    const bridge = resolveDeviceFoldersBridge(host)
    await expect(bridge.listDeviceFolders?.()).resolves.toBe('deck')
  })

  it('passes the arguments a write needs, in order', async () => {
    const seen: unknown[] = []
    const bridge = resolveDeviceFoldersBridge({
      setDeviceFolders: (...args: unknown[]) => {
        seen.push(...args)
        return Promise.resolve([])
      },
    })
    await bridge.setDeviceFolders?.('dev-phone', ['/a'])
    expect(seen).toEqual(['dev-phone', ['/a']])
  })
})

/* ====================================================== who gets a row at all */

describe('which devices this panel is drawn for', () => {
  const roster: RemoteDevice[] = [
    { id: 'ok', name: 'Phone', state: 'approved', addedAt: null, lastSeenAt: null, fingerprint: null },
    { id: 'wait', name: 'Unknown', state: 'pending', addedAt: null, lastSeenAt: null, fingerprint: null },
    { id: 'gone', name: 'Old phone', state: 'revoked', addedAt: null, lastSeenAt: null, fingerprint: null },
  ]

  /*
   * Approved only. A pending device cannot open anything, so choosing folders
   * for it is a decision about a device before the decision that matters; and a
   * revoked one is gone for good — the trust store never un-revokes, so its
   * grants have already been forgotten in the main process and a row here would
   * offer an edit to a record that no longer exists.
   */
  it('is the approved ones, and only those', () => {
    expect(grantableDevices(roster)).toEqual([{ id: 'ok', name: 'Phone' }])
  })

  it('carries the name the user gave the device, not its id', () => {
    expect(grantableDevices(roster)[0]?.name).toBe('Phone')
  })
})
