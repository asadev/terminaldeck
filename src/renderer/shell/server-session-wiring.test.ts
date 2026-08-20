import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The window treats a terminal on a server as a session, and withdraws from it
 * the controls that cannot act on one.
 *
 * ## Why these are source assertions
 *
 * Every claim here is about a **branch in `App.tsx`** rather than about the
 * output of a component. Each of the pieces involved is correct on its own — the
 * rail draws what it is handed, the strip draws what it is handed, the pane
 * mounts what it is given — and the thing that can regress is which of them is
 * reached, and where the pane is mounted. That is exactly the class of defect
 * `workspace-strip.test.ts` and `wiring.test.ts` already guard this file for,
 * and it is invisible to a render test that hands the components their props
 * directly.
 *
 * ## The two halves this is holding apart
 *
 * `SERVERS-DESIGN.md` §5.5 refused a pill for a server terminal, and gave two
 * reasons. One was practical and is gone — it was about which files agents could
 * touch in parallel. The other was real: *"a server terminal … has no
 * transcript, no account, no model, no cost, and none of the control cluster
 * that makes the strip's chrome meaningful; a pill carrying six controls that
 * all do nothing is the exact defect `panels.ts` records the copilot page having
 * had, in reverse."*
 *
 * So the answer is not to pick a side. The **pill** is there, because Asad asked
 * for the same shape for every machine three nights running. The **cluster** is
 * absent, because a control that cannot act must be. Undo either half and one of
 * the tests below fails.
 */

const APP = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

/** One `useCallback` or arrow-bound const, sliced out by name. */
function block(name: string, end: string): string {
  const found = new RegExp(`const ${name} = useCallback\\(([\\s\\S]*?)\\n {4}${end}`).exec(APP)
  expect(found, `${name} has changed shape`).not.toBeNull()
  return found?.[0] ?? ''
}

describe('a terminal on a server is one of the things the window has open', () => {
  it('is in the array the strip and the rail both read', () => {
    /*
     * One array for the two surfaces whose job is to answer *what do I have
     * open*, so they cannot disagree about it. A server tab folded into `tabs`
     * instead would have to be excluded again at every place that treats that
     * array as this window's own ptys — `killSession`, the launch fallback, the
     * swarm grid — which is a shape of bug per site.
     */
    expect(APP).toContain(
      'const openTabs: WorkspaceTab[] = [...tabs, ...machineTabs, ...serverSessionTabs]',
    )
  })

  it('is routed by every road into "show me this", above the local one', () => {
    // The rail, the pill, ⌘1–9 and the palette all arrive at `selectTab`. The
    // routing has to be above `showTab` or there is a second road that will
    // drift from this one.
    const select = block('selectTab', '\\[')
    expect(select).toContain('readServerTabId(id)')
    expect(select.indexOf('readServerTabId(id)')).toBeLessThan(select.indexOf('showTab(id)'))
  })

  it('is put away by choosing anything local, the way a remote session is', () => {
    // Otherwise clicking a local row would highlight it and leave the server's
    // terminal on screen, which is the window disagreeing with itself about what
    // is selected.
    const select = block('selectTab', '\\[')
    expect(select).toContain('setOpenServerSession(null)')
  })

  it('is closed rather than hidden when its ✕ is pressed', () => {
    /*
     * A local pill's ✕ takes the tab off the bar and leaves the session running,
     * and that reading works because the rail still holds the row. Asad settled
     * the other case for machines that are not this one: the ✕ ends the thing.
     * A ✕ that meant "hide" on one row and "end" on the row above it — both of
     * them sessions somewhere else — is the same glyph doing opposite things.
     */
    const close = block('closeTab', '\\[')
    expect(close).toContain('readServerTabId(id)')
    expect(close).toContain('closeServerSession(id)')
  })

  it('is what ⌘W closes while it is the thing on screen', () => {
    /*
     * `activeTab` is the local answer, and while a server terminal fills the
     * pane it names a tab you are not looking at — so the chord would end a
     * session on this computer while somebody else's shell was in front of you.
     */
    const chord = /case 'session\.close':[\s\S]*?return true/.exec(APP)?.[0] ?? ''
    expect(chord, 'the ⌘W case has changed shape').not.toBe('')
    expect(chord).toContain('closeTab(openServerSession)')
    expect(chord.indexOf('closeTab(openServerSession)')).toBeLessThan(
      chord.indexOf('closeTab(activeTab.id)'),
    )
  })
})

describe('the pane is mounted for as long as its tab exists', () => {
  it('is drawn beside `mainView` rather than inside it', () => {
    /*
     * This is the difference between a session and a rectangle, and it is the
     * one claim here that a reader is most likely to "tidy up".
     *
     * `mainView` returns one thing. Open Settings, look at a session on a paired
     * machine, split the window — whatever it was drawing is unmounted. Every
     * other pane survives that because something else holds its state: the main
     * process's scrollback, the page in the main process, the far machine's
     * replay. A shell on a server has nothing holding it but the terminal it is
     * written into, so unmounting would either lose every line it printed or,
     * if the shell were left open to avoid that, strand a live one on somebody's
     * machine with no way back to it.
     */
    const panes = /<div className="panes">([\s\S]*?)\n {8}<\/div>/.exec(APP)?.[0] ?? ''
    expect(panes, 'the panes block has changed shape').not.toBe('')
    expect(panes).toContain('<ServerSessionPane')
    expect(panes.indexOf('</ErrorBoundary>')).toBeLessThan(panes.indexOf('<ServerSessionPane'))
  })

  it('mounts one per open terminal and hides all but the one in front', () => {
    const panes = /<div className="panes">([\s\S]*?)\n {8}<\/div>/.exec(APP)?.[0] ?? ''
    expect(panes).toContain('serverSessions.map(')
    expect(panes).toContain('visible={openServerSession === entry.tabId}')
    // Keyed on the tab id, so a second terminal on the same server is a
    // genuinely different pane rather than the same one re-rendered.
    expect(panes).toContain('key={entry.tabId}')
  })

  it('draws nothing at all from `mainView` while one is on screen', () => {
    /*
     * Without the early return, the branch below would mount every local
     * terminal and show whichever one `activeTab` fell back to — underneath an
     * opaque pane. A terminal nobody can see, with the keyboard, taking
     * keystrokes meant for the server.
     */
    const main = /const mainView = \(\) => \{[\s\S]*?\n {4}if \(openMachineSession/.exec(APP)?.[0] ?? ''
    expect(main, 'mainView has changed shape').not.toBe('')
    expect(main).toContain('if (openServerSession !== null) return null')
  })
})

describe('the controls a shell can reach, and the ones it cannot', () => {
  /*
   * §5.5 used to withdraw the whole cluster here, and the argument for it was
   * mechanically true rather than a matter of taste: every control is a
   * conversation with a pty **by session id**, `agent-controls.ts` performs a
   * change by typing `/model` into that pty and reading the screen, and a shell
   * on a server had no such id in this app.
   *
   * What it did not check is that a server shell *is* a pty — `connection.ts`
   * opens it with `client.shell({ term: 'xterm-256color' })` and its bytes
   * arrive in this main process — which is the only thing the mechanism ever
   * needed. `servers/ipc.ts` attaches the same shadow terminal a local session
   * keeps, and the same two functions drive it. Asad asked for exactly this
   * three times: *"I don't see it in server sessions and in the remote sessions
   * both."*
   *
   * The caution the old note carried is kept, because it is the thing that
   * would actually hurt: typing `/model` at a plain `sh` submits the word to
   * whatever is in front of it. That is refused twice on the far side of the IPC
   * — `refuseByProvider` finds no Claude Code markers on the screen, and
   * `refuseToType` finds no composer — and this file's job is the wiring, so
   * what it pins is that the window asks the *server* channel rather than the
   * local one, and that the two modes which genuinely cannot act say why.
   */
  it('reaches the cluster through the server channel, not the local one', () => {
    const table = /const barControls: \{[\s\S]*?\n {12}: null\n/.exec(APP)?.[0] ?? ''
    expect(table, 'barControls has changed shape').not.toBe('')
    // The far end's own id for the shell, which is the only handle the main
    // process holds the SSH channel under — not `shellKey`, which is this
    // window's and names nothing over there.
    expect(table).toContain('serverShellIds[openServerRow.tabId]')
    expect(table).toContain("target: { kind: 'server' }")
    /*
     * And no `cwd` and no `provider`. Both would be facts about *this* machine:
     * a path here resolves this machine's connectors and transcripts, and a
     * provider is a record of a spawn this app never made. `undefined` is what
     * makes `refuseByProvider` consult the screen instead of the record, which
     * is the only witness there is to what is running in that terminal.
     */
    const branch = /serverShellIds\[openServerRow\.tabId\][\s\S]*?\n {12}\}/.exec(table)?.[0] ?? ''
    expect(branch, 'the server branch has changed shape').not.toBe('')
    expect(branch).toContain('cwd: null')
    expect(branch).toContain('provider: undefined')
  })

  it('gives chat and split a reason rather than taking the switch away', () => {
    /*
     * Terminal is exactly what a server terminal is already showing, so
     * withdrawing the whole switch took a working segment with it and left an
     * empty stretch of toolbar — which cannot tell "not built" from "not
     * possible". Chat reads the agent's own transcript file, which is on that
     * server's disk; Split arranges this window's own panes, and these are
     * mounted outside them so their scrollback survives being switched away
     * from. Both sentences are on the control, on the segment, where somebody
     * presses.
     */
    const table = /const modesBlocked:[\s\S]*?\n {8}: undefined\n/.exec(APP)?.[0] ?? ''
    expect(table, 'modesBlocked has changed shape').not.toBe('')
    expect(table).toContain('openServerSession !== null')
    expect(table).toMatch(/chat:\s*'Chat reads the agent[^']*server/)
    expect(table).toMatch(/split:\s*'Split arranges this window[^']*server/)
    // And the switch is drawn for one, or the sentences reach nobody.
    const guard = /\{\(activeSession \|\| splitting[\s\S]*?\? \(/.exec(APP)?.[0] ?? ''
    expect(guard, 'the ModeSwitch guard has changed shape').not.toBe('')
    expect(guard).toContain('openServerSession !== null')
  })

  it('gives the window bar a name and the server, and no folder or account chip', () => {
    /*
     * A shell starts wherever that sign-in lands and this app has not asked
     * where that is, so there is nothing true to put on a chip that opens a path
     * on *this* computer — the same reason a remote session's heading hands
     * `FolderChip` a null.
     */
    const heading = /const heading = openServerTab\n {4}\? \{[\s\S]*?\n {6}\}/.exec(APP)?.[0] ?? ''
    expect(heading, 'the server heading has changed shape').not.toBe('')
    expect(heading).toContain('folder: null')
    expect(heading).toContain('account: null')
    expect(heading).toContain('tabLabel(openServerTab, openTabs)')
  })
})

describe('closing asks first, and the dialog names the right thing', () => {
  it('routes both server closes through the confirmation every other close uses', () => {
    expect(APP).toContain("kind: 'server-session'")
    expect(APP).toContain("kind: 'server'")
    expect(APP).toContain("else if (closing.kind === 'server') closeServerNow(closing.serverId)")
    expect(APP).toContain(
      "else if (closing.kind === 'server-session') closeServerSessionNow(closing.tabId)",
    )
  })

  it('tells the dialog it is talking about a server, not a project', () => {
    // Calling a live machine a project is how a confirmation stops being read.
    expect(APP).toContain("? 'server'")
  })
})
