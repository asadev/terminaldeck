import { describe, expect, it } from 'vitest'
import {
  addAnnotation,
  composeHandoff,
  describeElement,
  describeWhere,
  flat,
  removeAnnotation,
  roundForTools,
  type AnnotationRound,
} from './annotate'

const BOX = { x: 0.04, y: 0.444, width: 0.92, height: 0.062 }

function round(note = 'Make #1 bold and put #3 below it.\u001b[2J'): AnnotationRound {
  let list = addAnnotation([], {
    id: 'a',
    rect: BOX,
    element: { role: 'button', name: 'General', identifier: 'com.apple.settings.general' },
  })
  list = addAnnotation(list, { id: 'b', rect: { x: 0.5, y: 0.9, width: 0.04, height: 0.04 }, element: null })
  list = addAnnotation(list, {
    id: 'c',
    rect: { x: 0.04, y: 0.137, width: 0.33, height: 0.05 },
    element: { role: 'heading', name: 'Settings', component: 'Title', source: { file: 'src/screens/Home.tsx', line: 42, column: 7 } },
  })
  return {
    id: 'r1',
    createdAt: Date.UTC(2026, 9, 3, 10, 0, 0),
    where: { kind: 'device', place: 'iOS Simulator', name: 'iPhone 17 Pro', deviceId: 'ios:X', app: 'com.example.Shop', screen: 'Checkout' },
    frame: { width: 1206, height: 2622 },
    annotations: list,
    note,
  }
}

describe('editing a round', () => {
  it('numbers markers in the order they were added', () => {
    expect(round().annotations.map((a) => a.n)).toEqual([1, 2, 3])
  })

  it('closes the gap when one is deleted, so the numbers match the markers drawn', () => {
    expect(removeAnnotation(round().annotations, 'a').map((a) => [a.id, a.n])).toEqual([
      ['b', 1],
      ['c', 2],
    ])
  })

  it('has one note for the round and none on the markers', () => {
    for (const marker of round().annotations) expect('note' in marker).toBe(false)
  })
})

describe('the message a session receives', () => {
  const message = composeHandoff(round(), '/Users/me/Pictures/App/iPhone-annotated.png')

  it('is one line with no control characters, because a newline submits it', () => {
    expect(message).not.toMatch(/[\u0000-\u001f\u007f]/)
    expect(flat('a\nb\r\tc\u001b')).toBe('a b c')
  })

  it('says where, then the picture', () => {
    expect(
      message.startsWith(
        '[Annotate: 3 marked elements on the iOS Simulator "iPhone 17 Pro", app com.example.Shop, screen Checkout;',
      ),
    ).toBe(true)
    expect(message).toContain('picture with the numbered markers: /Users/me/Pictures/App/iPhone-annotated.png (1206 x 2622)]')
  })

  it('lists every numbered element, then the one note, so the note can say "#3"', () => {
    const marked =
      '#1 button "General" (id com.apple.settings.general) at 4% across, 44% down, 92% x 6%; ' +
      '#2 blank space at 50% across, 90% down, 4% x 4%; ' +
      '#3 heading "Settings" (component Title, source src/screens/Home.tsx:42:7) at 4% across, 14% down, 33% x 5%.'
    expect(message).toContain(marked)
    expect(message.endsWith('What should change: Make #1 bold and put #3 below it. [2J')).toBe(true)
    expect(message.indexOf('#3 heading')).toBeLessThan(message.indexOf('What should change'))
  })

  it('says so when the picture could not be saved, instead of naming no file', () => {
    expect(composeHandoff(round(), '')).toContain('the picture could not be saved')
  })

  it('counts one element as one', () => {
    const single = { ...round('Bold.'), annotations: round().annotations.slice(0, 1) }
    expect(composeHandoff(single, '/p.png')).toContain('[Annotate: 1 marked element on ')
  })

  it('names a browser page by its address', () => {
    expect(describeWhere({ kind: 'browser', place: 'browser page', name: 'Shop', url: 'http://localhost:3000/' })).toBe(
      'the page http://localhost:3000/ titled "Shop"',
    )
  })
})

describe('elements in words', () => {
  it('says blank space for a point on nothing', () => {
    expect(describeElement(null)).toBe('blank space')
  })

  it('names a page element with its selector', () => {
    expect(describeElement({ role: '<button>', name: 'Order now', identifier: 'order', selector: '#order' })).toBe(
      '<button> "Order now" (id order, selector #order)',
    )
  })

  it('cuts a very long name rather than sending a paragraph', () => {
    expect(describeElement({ name: 'x'.repeat(500) }).length).toBeLessThan(140)
  })
})

describe('the round for a tool', () => {
  it('is fields, not a sentence: the one note, then each marker by number', () => {
    const value = roundForTools({ ...round(), sentTo: { sessionId: 's1', label: 'shop · Session 1', at: Date.UTC(2026, 9, 3, 10, 1) } })
    expect(value.sentTo).toEqual({ session: 'shop · Session 1', at: '2026-10-03T10:01:00.000Z' })
    expect(value.note).toBe('Make #1 bold and put #3 below it. [2J')
    const markers = value.markers as Array<{ n: number; described: string; note?: string }>
    expect(markers.map((m) => m.n)).toEqual([1, 2, 3])
    expect(markers[1].described).toBe('blank space')
    for (const marker of markers) expect(marker.note).toBeUndefined()
  })
})
