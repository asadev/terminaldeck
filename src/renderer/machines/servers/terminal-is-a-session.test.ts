import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The control on the server's page opens a **session**, and the pane behind it
 * behaves like one.
 *
 * ## It is no longer a door
 *
 * The control lived behind `ServerAdvanced`'s collapsed *Advanced* disclosure,
 * which is where these assertions used to read it from. It is the primary action
 * under the server's name now. Asad, having connected a server and looked at its
 * page: *"i cant open a session in connected server i connected it now see there
 * is no way for this."* The claims below did not change — only the file they are
 * read from, and the new one insisting there is exactly one copy of it.
 *
 * ## What this replaced
 *
 * A rectangle. `ServerAdvanced` used to hold a `ServerTerminal` inline, mounted
 * on a `useState` flag, which meant the shell existed only while that page was
 * the thing on screen: looking at anything else closed it, and there was no row,
 * no pill and no ⌘W for it anywhere. Asad, three nights running about machines
 * that are not this one: *"the shape of the application should not be changing
 * for local and remote devices. It should act like that same."*
 *
 * ## Why these are source assertions
 *
 * The three claims are about **teardown, measurement and mounting** — a
 * component's cleanup function, an effect's guard, and where in the tree a node
 * lives. None of them is visible in the markup of a single render, and the
 * failure of each is silent: a shell left running on somebody's machine, a
 * terminal wrapping at a column measured while it was hidden, a scrollback that
 * disappears when you glance at Settings. This repository has shipped the third
 * shape of that bug twice.
 */

const HERE = __dirname
const ADVANCED = readFileSync(join(HERE, 'ServerAdvanced.tsx'), 'utf8')
const PAGE = readFileSync(join(HERE, 'ServerPage.tsx'), 'utf8')
const TERMINAL = readFileSync(join(HERE, 'ServerTerminal.tsx'), 'utf8')
const PANE = readFileSync(join(HERE, 'ServerSessionPane.tsx'), 'utf8')

describe('the page opens a session rather than a rectangle', () => {
  it('no longer mounts a terminal inside itself', () => {
    // The whole of the original change. A terminal drawn on this page is a
    // terminal that stops existing when the page does.
    expect(ADVANCED).not.toContain('<ServerTerminal')
    expect(ADVANCED).not.toContain("from './ServerTerminal'")
    expect(PAGE).not.toContain('<ServerTerminal')
    expect(PAGE).not.toContain("from './ServerTerminal'")
  })

  it('asks the window to open one, by name as well as by id', () => {
    /*
     * The name travels with the id because the window has no route to the
     * servers list — the list lives inside this panel, which is usually not the
     * thing on screen — and the rail heading, the pill's tooltip, the window bar
     * and the close confirmation all print it.
     *
     * Read from `ServerPage.tsx` rather than from `ServerAdvanced.tsx` since the
     * control moved out from behind the door: it is the primary action under the
     * server's name now, because behind a disclosure labelled *Advanced* it was
     * a door people correctly believed was not for them.
     */
    /*
     * Three arguments since 2026-08-19: the folder on the server joined them
     * when `ServerFolderPicker` did. It is matched here rather than left off
     * the string, because the point of this assertion is that the *page* is
     * what makes the call — and a looser match would keep passing if somebody
     * dropped the folder and quietly went back to opening every terminal in
     * whichever directory SSH happened to land in.
     */
    expect(PAGE).toContain('opener.open(server.id, server.name, folder)')
  })

  it('offers it in one place rather than two', () => {
    /*
     * Not tidiness. Two controls doing one thing are two sets of conditions to
     * keep in step — this build cannot, this window cannot, this connection
     * failed — and the copy further from the reader is the copy that goes stale
     * without anybody noticing it has.
     */
    expect(ADVANCED).not.toContain('opener.open(')
  })

  it('says where the terminal will appear, before the press', () => {
    // Somebody who has only ever seen the old behaviour needs one sentence to
    // know their work has not been put somewhere they cannot find it.
    expect(PAGE).toContain('a row in the list on the left')
  })

  it('draws no button at all when there is no window to hold one', () => {
    /*
     * A control that cannot act is absent. The harness and a unit test render
     * this page with no window around it, and a button there could only ever
     * swallow the press — which is exactly the shape of defect this pass is
     * removing everywhere else.
     */
    expect(PAGE).toContain('opener === null')
    expect(PAGE.indexOf('opener === null')).toBeLessThan(
      PAGE.indexOf('opener.open(server.id, server.name, folder)'),
    )
  })
})

describe('the pane is hidden rather than unmounted', () => {
  it('takes a visibility flag instead of being mounted conditionally', () => {
    /*
     * A local session survives an unmount because the main process hands back
     * its scrollback; a session on a paired desktop survives because the far end
     * replays it. A shell on a server has neither — nothing over there is
     * keeping it, and nothing here is recording it — so the terminal it is
     * written into is the only thing holding what it printed.
     */
    expect(PANE).toContain('data-visible={visible}')
    expect(PANE).toContain('visible={visible}')
  })

  it('is keyed on the shell rather than on the server', () => {
    // Two terminals on one server are two panes. Keying on the server would
    // give one terminal that flickers between two shells.
    expect(PANE).toContain('shellKey')
  })
})

describe('the terminal', () => {
  it('closes the shell when it goes away, so nothing is stranded', () => {
    /*
     * The teardown *is* the close, and that is what makes taking the tab off the
     * list a genuine close rather than a hide. Nothing on the far end is keeping
     * this shell — there is no app there to keep it — so one that nobody closes
     * is a live shell on somebody else's machine with no way back to it.
     */
    const teardown = /return \(\) => \{[\s\S]*?term\.dispose\(\)/.exec(TERMINAL)?.[0] ?? ''
    expect(teardown, 'the terminal teardown has changed shape').not.toBe('')
    expect(teardown).toContain('bridge.closeServerShell(shellId)')
  })

  it('refuses to measure itself while it is hidden', () => {
    /*
     * Hiding the pane changes its box to nothing, which fires the observer —
     * and fitting against nothing produces a column count of nothing, which
     * would then be sent to the far end as the width to wrap at. The shell would
     * come back from the background having reflowed its whole screen to a width
     * no window has.
     */
    expect(TERMINAL).toContain('if (host.clientWidth === 0 || host.clientHeight === 0) return')
  })

  it('measures again the moment it is back, on the next frame', () => {
    /*
     * xterm cannot measure a hidden element, so a terminal fitted in the
     * background is holding a column count from a zero-width box — and the far
     * end was told that count. On the next frame rather than in this one,
     * because the attribute that reveals the pane is set by the same render.
     */
    const effect = /useEffect\(\(\) => \{\n {4}if \(!visible\) return[\s\S]*?\}, \[visible\]\)/.exec(
      TERMINAL,
    )?.[0]
    expect(effect, 'the visibility effect has changed shape').toBeTruthy()
    expect(effect).toContain('requestAnimationFrame')
    expect(effect).toContain('fit()')
  })

  it('tells the window when the far end has gone, without removing the row', () => {
    /*
     * The row stays and its dot goes to `exited`, which is what a local session
     * does when its process ends. Taking it away here would remove the last
     * thing the shell printed at the exact moment somebody wants to read it.
     */
    expect(TERMINAL).toContain('endedRef.current?.()')
    // Through a ref, because the window rebuilds its handlers whenever anything
    // anywhere is opened or closed, and the listener is registered once for the
    // life of the shell.
    expect(TERMINAL).toContain('endedRef.current = onEnded')
  })
})
