import { describe, expect, it } from 'vitest'
import { centreOf, elementAt, findNodes, flatten, nodeName, plainRole, type DeviceNode } from './device-tree'

/**
 * The Settings screen of a real iOS 27 simulator, as the engine described it
 * on this Mac (trimmed to the rows these tests need): an application covering
 * the screen, an unlabelled group covering it again, and buttons inside.
 */
const SETTINGS: DeviceNode = {
  ref: 'ax:0',
  role: 'AXApplication',
  label: 'Settings',
  frame: { normalized: { x: 0, y: 0, width: 1, height: 1 } },
  children: [
    { ref: 'ax:1', role: 'AXHeading', label: 'Settings', frame: { normalized: { x: 0.04, y: 0.137, width: 0.331, height: 0.049 } } },
    {
      ref: 'ax:2',
      role: 'AXGroup',
      identifier: 'com.apple.settings.sidebar.collectionView',
      frame: { normalized: { x: 0, y: 0, width: 1, height: 1 } },
      children: [
        {
          ref: 'ax:5',
          role: 'AXButton',
          label: 'General',
          identifier: 'com.apple.settings.general',
          frame: { normalized: { x: 0.04, y: 0.444, width: 0.92, height: 0.062 } },
          children: [
            // An unlabelled image inside the button: still the button to anyone looking.
            { ref: 'ax:5a', role: 'AXImage', frame: { normalized: { x: 0.06, y: 0.455, width: 0.06, height: 0.03 } } },
          ],
        },
        {
          ref: 'ax:6',
          role: 'AXButton',
          label: 'Accessibility',
          identifier: 'com.apple.settings.accessibility',
          frame: { normalized: { x: 0.04, y: 0.506, width: 0.92, height: 0.062 } },
        },
        {
          ref: 'ax:7',
          role: 'AXButton',
          label: 'Hidden one',
          hidden: true,
          frame: { normalized: { x: 0.04, y: 0.6, width: 0.92, height: 0.062 } },
        },
      ],
    },
  ],
}

describe('the element under a point', () => {
  it('is the smallest named element there, not the screen it is on', () => {
    expect(elementAt(SETTINGS, 0.5, 0.475)?.label).toBe('General')
  })

  it('is the button, not the unlabelled picture inside it', () => {
    expect(elementAt(SETTINGS, 0.08, 0.47)?.label).toBe('General')
  })

  it('falls back to the smallest of whatever holds the point when nothing named does', () => {
    // Blank space between the heading and the rows: only the scaffolding
    // covers it, and the answer still says where rather than nothing.
    expect(elementAt(SETTINGS, 0.9, 0.3)?.ref).toBeDefined()
  })

  it('never picks a hidden element', () => {
    expect(elementAt(SETTINGS, 0.5, 0.63)?.label).not.toBe('Hidden one')
  })

  it('reads a tree that is not a tree without hanging', () => {
    const loop: DeviceNode = { ref: 'x', children: [] }
    let node = loop
    for (let i = 0; i < 400; i++) {
      const child: DeviceNode = { ref: `x${i}` }
      node.children = [child]
      node = child
    }
    expect(flatten(loop).length).toBeLessThanOrEqual(202)
  })
})

describe('finding by name', () => {
  it('matches the whole name, case-insensitively', () => {
    expect(findNodes(SETTINGS, { name: 'general' }).map((n) => n.ref)).toEqual(['ax:5'])
    expect(findNodes(SETTINGS, { name: 'Gen' })).toHaveLength(0)
  })

  it('matches part of a name only when asked to', () => {
    expect(findNodes(SETTINGS, { name: 'Gen', partial: true }).map((n) => n.ref)).toEqual(['ax:5'])
  })

  it('takes a role in either spelling', () => {
    expect(findNodes(SETTINGS, { role: 'button' }).length).toBe(3)
    expect(findNodes(SETTINGS, { role: 'AXButton', name: 'Accessibility' }).map((n) => n.ref)).toEqual(['ax:6'])
  })

  it('finds by identifier', () => {
    expect(findNodes(SETTINGS, { identifier: 'com.apple.settings.general' })[0].label).toBe('General')
  })

  it('finds nothing for an empty query rather than everything', () => {
    expect(findNodes(SETTINGS, {})).toEqual([])
  })
})

describe('words and centres', () => {
  it('says roles the way a person would', () => {
    expect(plainRole('AXButton')).toBe('button')
    expect(plainRole('AXTextField')).toBe('text field')
    expect(plainRole('android.widget.TextView')).toBe('text view')
    expect(plainRole(undefined)).toBe('')
  })

  it('names a node by its label first', () => {
    expect(nodeName({ ref: 'a', label: 'Pay', identifier: 'pay-button' })).toBe('Pay')
    expect(nodeName({ ref: 'a', identifier: 'pay-button' })).toBe('pay-button')
  })

  it('taps the middle of an element', () => {
    expect(centreOf(SETTINGS.children![1].children![0])).toEqual({ x: 0.5, y: 0.475 })
    expect(centreOf({ ref: 'none' })).toBeNull()
  })
})
