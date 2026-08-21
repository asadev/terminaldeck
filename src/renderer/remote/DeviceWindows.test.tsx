import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceWindowsView,
  resolveDeviceWindowsBridge,
  toWindowGrants,
  type DeviceWindowsViewProps,
} from './DeviceWindows'

/**
 * The fourth grant axis on screen: which devices may act on the browser windows
 * in this app.
 *
 * Two states, not four. The three panels above it narrow a *set* and need an
 * All/Selected row to say so; there is no set here — the subject is the browser
 * on this screen, holding this person's signed-in mail, bank and source control
 * — and the only two answers are yes and no.
 *
 * The one thing worth pinning hardest is which way it fails. Unread, unreadable
 * and never-chosen all draw the same unticked box, because they all mean the
 * same thing, and a panel that guessed otherwise would be a permission somebody
 * believes they gave.
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * grants as a prop.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone" },
  { id: 'dev-pc', name: 'Office PC' },
]

function view(over: Partial<DeviceWindowsViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceWindowsView
      devices={DEVICES}
      allowed={new Set()}
      wired={true}
      problem={null}
      busy={null}
      onToggle={() => {}}
      {...over}
    />,
  )
}

describe('the two states', () => {
  it('draws every device unticked until somebody says otherwise', () => {
    const html = view()
    // Escaped by the renderer, so the name is matched the way it lands.
    expect(html).toContain('Asad&#x27;s iPhone')
    expect(html).toContain('Office PC')
    expect(html).not.toContain('checked')
  })

  it('ticks only the device that was allowed', () => {
    const html = view({ allowed: new Set(['dev-pc']) })
    // One box, and the ticked one is the second device's.
    expect(html.match(/checked/g) ?? []).toHaveLength(1)
    expect(html.indexOf('checked')).toBeGreaterThan(html.indexOf('Asad&#x27;s iPhone'))
  })

  it('draws an unread store exactly like an empty one, because they mean the same thing', () => {
    /*
     * `null` is "the first read has not landed". On the three axes above it that
     * matters, because absence there means *everything*; here absence means
     * **no**, so there is nothing to wait for and nothing to flicker.
     */
    expect(view({ allowed: null })).toBe(view({ allowed: new Set() }))
  })
})

describe('what it refuses to draw', () => {
  it('draws nothing at all in a build without the channels', () => {
    // Not a sentence about a build that cannot do this. The same silence the
    // three panels above keep.
    expect(view({ wired: false })).toBe('')
  })

  it('draws nothing when no device is approved', () => {
    expect(view({ devices: [] })).toBe('')
  })

  it('stops every box while a write is in flight, not only the one pressed', () => {
    /*
     * The answer replaces the whole list, so a second press landing mid-write
     * would be resolved against a list that is about to be thrown away.
     */
    const html = view({ allowed: new Set(['dev-pc']), busy: 'dev-pc' })
    expect(html.match(/disabled/g) ?? []).toHaveLength(DEVICES.length)
  })

  it('says when the last read or write failed, because the ticks may be stale', () => {
    const html = view({ problem: 'Could not save that. Nothing changed.' })
    expect(html).toContain('Could not save that.')
    expect(html).toContain('role="alert"')
  })
})

describe('reading what the main process sent', () => {
  it('keeps the ids it can use and drops the rest', () => {
    expect([...toWindowGrants(['dev-a', 7, '', null, 'dev-b'])]).toEqual(['dev-a', 'dev-b'])
  })

  it('reads anything that is not a list as nobody', () => {
    // Fail-closed on this axis, the same direction the store reads its own file.
    expect(toWindowGrants(undefined).size).toBe(0)
    expect(toWindowGrants({ devices: ['dev-a'] }).size).toBe(0)
  })
})

describe('the bridge', () => {
  it('reports itself unwired when either channel is missing', () => {
    expect(resolveDeviceWindowsBridge({})).toEqual({})
    const half = resolveDeviceWindowsBridge({ listWindowGrants: () => Promise.resolve([]) })
    expect(typeof half.listWindowGrants).toBe('function')
    expect(half.setWindowGrant).toBeUndefined()
  })

  it('calls through the host object rather than detached', async () => {
    /*
     * A preload with its methods on a prototype throws on `this` the first time
     * a button is pressed. The three panels beside this one learned that once
     * each; this is the same guard.
     */
    const host = {
      mine: ['dev-a'],
      listWindowGrants(this: { mine: string[] }): Promise<unknown> {
        return Promise.resolve(this.mine)
      },
      setWindowGrant(): Promise<unknown> {
        return Promise.resolve([])
      },
    }
    const bridge = resolveDeviceWindowsBridge(host)
    await expect(bridge.listWindowGrants?.()).resolves.toEqual(['dev-a'])
  })
})
