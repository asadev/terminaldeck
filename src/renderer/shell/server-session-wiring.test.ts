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

describe('the controls that cannot act on a shell are absent', () => {
  /*
   * The half of §5.5's argument that was right, kept.
   *
   * The reason is mechanical rather than a matter of taste, which matters here:
   * the tempting shortcut is "servers do not have agents", and that is an
   * assumption about somebody else's machine — the one thing this whole area is
   * arranged against. What is actually true is that every control in the cluster
   * is a conversation with a **local pty, by session id**: `useSessionControls`
   * reads `agent:controls:read` and writes `agent:controls:set`, both keyed on a
   * session this app spawned, and `agent-controls.ts` performs a change by
   * typing `/model` into that pty and waiting for the screen to echo it back. A
   * shell on a server has no such id.
   *
   * And it stays absent on a server that *does* have an agent installed on it.
   * Installed is not running — `agent-presence.ts` is explicit that for a shell
   * the question cannot be answered from the record and has to be read off the
   * screen through that same local channel, so for a server shell the answer is
   * permanently `null`, which is the state that file already says draws neither
   * control.
   */
  it('withdraws the model, effort and connector cluster', () => {
    const guard = /\{headingSession && !swarm &&[^?]*\?/.exec(APP)?.[0] ?? ''
    expect(guard, 'the SessionControls guard has changed shape').not.toBe('')
    expect(guard).toContain('openServerSession === null')
    // And the reason is written where the branch is, not only here.
    expect(APP).toContain('Installed is not running')
  })

  it('withdraws the chat and split switch with them', () => {
    // Chat is a view of a transcript file on this machine's disk and Split
    // arranges this window's own panes. A shell on a server has neither.
    const guard = /\{\(activeSession \|\| splitting\) &&[\s\S]*?\? \(/.exec(APP)?.[0] ?? ''
    expect(guard, 'the ModeSwitch guard has changed shape').not.toBe('')
    expect(guard).toContain('openServerSession === null')
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
