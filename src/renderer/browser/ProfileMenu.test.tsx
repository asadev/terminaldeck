import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * What is inside a profile — E7, pinned where it kept coming undone.
 *
 * Asad, with the menu open on his own machine:
 *
 *   > *"Profile also, if I click on profile, there is nothing inside the
 *   > profile, just the name, not like Chrome. So if we don't have those
 *   > features, then even profile doesn't make any sense if there is nothing
 *   > that we can see in each profile."*
 *
 * The fork was real and it was taken the other way: profiles stay, because he
 * asked for the icon that opens this menu in the same minute (*"we can have
 * these profiles over here as icon"*) and because a profile here is a real
 * Chromium partition rather than a label. What was missing was any way to see
 * into one, and the reason was mechanical — nothing under this menu could
 * answer a question about a profile that was not the one switched on.
 *
 * Held as source, because this component reads its state in an effect and this
 * suite has no DOM to run one in. It was checked where it renders instead, in
 * the real app against the real main process, with two profiles and a cookie in
 * each: `review-2026-08-20/shots/browser-chrome/e7-live-02-both-rows.png` and
 * `e7-profile-one-crop.png` for the state he opens it in.
 */
const source = readFileSync(join(__dirname, 'ProfileMenu.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('every row says what its profile holds', () => {
  it('asks for each profile by id, not for whichever one is on', () => {
    // `countSites` took no argument, so the site count could only ever be true
    // of the active row. This is the wire that made every row answerable.
    expect(onScreen).toContain('countSites?: (profileId: string) => Promise<number>')
    expect(onScreen).toContain('countSites(profile.id)')
  })

  it('does not gate what a row shows on that row being the active one', () => {
    // The old row read `{on && sites !== null && sites > 0 && ...}`. One row
    // could report; the rest were a name and a tick.
    expect(onScreen).not.toContain('on && sites')
  })

  it('gives every row both doors, whether or not it holds anything', () => {
    expect(onScreen).toContain('`Sites in ${profile.name}`')
    expect(onScreen).toContain('`Logins in ${profile.name}`')
  })

  it('never prints a zero to stop a row looking empty', () => {
    // *"don't put any single statement in anywhere"* has a numeric form: a count
    // that exists to fill a slot. An empty profile gets the plain word, which is
    // a door rather than a caption.
    expect(onScreen).toContain("stored > 0 ?")
    expect(onScreen).toContain("saved > 0 ?")
    expect(onScreen).toContain("'Sites'")
    expect(onScreen).toContain("'Logins'")
  })

  it('does not keep one profile’s site data reachable two ways', () => {
    // A standing `Cookies and site data` row at the foot opened the active
    // profile's jar — which is the door that is now on the active profile's own
    // row. *"It doesn't make any sense to keep in both side the same thing."*
    expect(onScreen).not.toContain('Cookies and site data')
  })

  it('carries no headings over any of it', () => {
    expect(onScreen).not.toContain('In this profile')
  })
})
