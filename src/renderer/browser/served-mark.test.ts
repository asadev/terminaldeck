import { describe, expect, it } from 'vitest'
import { servedMark, servedTitle, type ServedBy } from './served-mark'

const tunnel: ServedBy = {
  name: 'Office PC',
  port: 5199,
  localPort: 5199,
  sameNumber: true,
  agrees: true,
}

describe('the mark inside the address field', () => {
  it('says nothing when the picker beside it already says all of it', () => {
    // His sentence, about the identical shape: *"It doesn't make any sense to
    // keep in both side the same thing."* The picker reads Office PC and the
    // address reads :5199 — there is no third fact.
    expect(servedMark(tunnel)).toBe('')
    expect(servedTitle(tunnel)).toBe('')
  })

  it('says the origin port when the address is showing a different one', () => {
    const moved = { ...tunnel, localPort: 53412, sameNumber: false }
    expect(servedMark(moved)).toBe(':5199')
    expect(servedTitle(moved)).toBe('Office PC:5199 → :53412')
  })

  it('names the machine when it is not the one the picker names', () => {
    const elsewhere = { ...tunnel, agrees: false }
    expect(servedMark(elsewhere)).toBe('Office PC:5199')
    expect(servedTitle(elsewhere)).toBe('Office PC:5199')
  })

  it('names this computer when the picker claims another and the page came from here', () => {
    // The state that was silent in 0.7.0 and is the whole of *"we always need a
    // truth"*: picker says Office PC, this Mac fetched the page.
    const here: ServedBy = {
      name: 'This machine',
      port: null,
      localPort: 0,
      sameNumber: true,
      agrees: false,
    }
    expect(servedMark(here)).toBe('This machine')
    expect(servedTitle(here)).toBe('This machine')
  })

  it('draws nothing at all when there is no machine behind the page', () => {
    expect(servedMark(null)).toBe('')
    expect(servedTitle(undefined)).toBe('')
  })
})
