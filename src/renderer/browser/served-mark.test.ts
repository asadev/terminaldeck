import { describe, expect, it } from 'vitest'
import { barServed, servedMark, servedTitle, type ServedBy } from './served-mark'

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
    // truth"*: picker says Office PC, this Mac fetched the page. It is named, as
    // every other machine on this bar is — see `hereName`.
    const here: ServedBy = {
      name: 'Asads-MacBook-Pro',
      port: null,
      localPort: 0,
      sameNumber: true,
      agrees: false,
    }
    expect(servedMark(here)).toBe('Asads-MacBook-Pro')
    expect(servedTitle(here)).toBe('Asads-MacBook-Pro')
  })

  it('draws nothing at all when there is no machine behind the page', () => {
    expect(servedMark(null)).toBe('')
    expect(servedTitle(undefined)).toBe('')
  })
})

/**
 * *"Why it is saying this machine? Since I click on Office PC, it is showing
 * this machine still."*
 *
 * The bar carried two machine labels a centimetre apart, and the second one was
 * about a page that had never been fetched: a new tab, the picker on Office PC,
 * the start page listing Office PC's twelve ports. Every case below is one line
 * of the same rule, and the last two are the ones that were missing.
 */
describe('what the field is told, given a page or the absence of one', () => {
  const page = {
    machineId: 'mach-1',
    machineName: 'Office PC',
    port: 3000,
    localPort: 53412,
    sameNumber: false,
  }

  it('passes a tunnelled page through, and says whether the picker agrees', () => {
    expect(barServed({ page, picked: 'mach-1', blank: false, here: 'Asads-MacBook-Pro' })).toEqual({
      name: 'Office PC',
      port: 3000,
      localPort: 53412,
      sameNumber: false,
      agrees: true,
    })
    expect(barServed({ page, picked: '', blank: false, here: 'Asads-MacBook-Pro' })?.agrees).toBe(false)
  })

  it('names this computer when the picker claims another and a real page came from here', () => {
    // The regression guard on the fix below: this disagreement is the one case
    // worth naming, and it is still named.
    expect(barServed({ page: null, picked: 'mach-1', blank: false, here: 'Asads-MacBook-Pro' })).toEqual({
      name: 'Asads-MacBook-Pro',
      port: null,
      localPort: 0,
      sameNumber: true,
      agrees: false,
    })
  })

  it('says nothing about a page that does not exist, whatever the picker says', () => {
    /*
     * The bug, in one line. A tab that has been nowhere and a tab whose load
     * failed are both `blank`, and neither was served by anybody — so the chip
     * that used to appear beside the picker was asserting a fact about a page
     * nobody had fetched.
     */
    expect(barServed({ page: null, picked: 'mach-1', blank: true, here: 'Asads-MacBook-Pro' })).toBeNull()
  })

  it('says nothing when the picker is on this computer either way', () => {
    // Nothing to disagree with: the field is only the link, which is what he
    // asked for when the word `local` used to live in it.
    expect(barServed({ page: null, picked: '', blank: false, here: 'Asads-MacBook-Pro' })).toBeNull()
    expect(barServed({ page: null, picked: '', blank: true, here: 'Asads-MacBook-Pro' })).toBeNull()
  })
})
