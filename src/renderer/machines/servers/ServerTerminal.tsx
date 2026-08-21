import { useEffect, useRef, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { terminalTheme, useTerminalFind } from '../../components/TerminalView'
import { subscribeTheme } from '../../theme'
import { attachRenderer } from '../../terminal-renderer'
import { asShellId, asShellOutput, type ServersBridge, type ShellOutput } from './types'

/**
 * A shell on a server, on this screen.
 *
 * ## Why it is here at all
 *
 * It is the honest floor under everything else in this area. The cards above it
 * are built by classifying what a machine happens to be running, and that
 * classification will be incomplete on somebody's server — a bare container, a
 * machine using an init system this app has never met, a stack nobody here has
 * seen. A page that can only offer named actions has nothing to say to those
 * people. This has everything to say to them, and it is what makes an empty
 * middle zone an honest answer rather than a dead end.
 *
 * ## Where it is drawn, and what changed
 *
 * It used to be drawn *inside* the server's page, behind the Advanced door, on
 * the argument that everything else on that page is a named action with a stated
 * consequence and a shell has none. The second half of that is still true and is
 * still why the *door* to one is behind Advanced. What was wrong was where the
 * terminal itself then lived: inside a panel, so it existed only while that
 * panel was the thing on screen, with no row in the rail, no pill, no ⌘W and no
 * way to look at anything else without losing it.
 *
 * Asad has now said the rule three times about machines that are not this one:
 * *"the shape of the application should not be changing for local and remote
 * devices. It should act like that same."* So this is mounted by the window, as
 * one of the panes it keeps, and the press behind the Advanced door opens a tab
 * rather than a rectangle on a page.
 *
 * ## Why this is not `RemoteTerminal`
 *
 * `RemoteTerminal` is bound to the *device* channels and carries two handles, a
 * machine and a session, because a device runs this app on the far end and keeps
 * its sessions whether or not anybody is attached — which is why detaching one
 * is a detach and not a close. A server keeps nothing: the shell exists because
 * this window is holding a connection to it, so this component's teardown ends
 * it rather than letting go of it.
 *
 * So the xterm *setup* is written out again. The *behaviour* used to be withheld
 * — this paragraph read *"no find bar, no clear, no copy chords"* — and that has
 * not survived the paragraph above it. A shell on a server is a tab in this
 * window now, with a row in the rail and its own ⌘W; a tab that will not answer
 * ⌘F because the bytes come from somewhere else is the app changing shape per
 * machine, which is the rule this file already quotes him on three times. Find,
 * clickable links and the three chords come from `useTerminalFind` in
 * `TerminalView`, which is the one place that owns them — the same arrangement,
 * for the same reason, as `terminalTheme()`.
 *
 * ## Columns first, then rows, in both directions
 *
 * The library underneath reverses that order between opening a shell and
 * resizing one, in the same library on the same channel. Getting it wrong
 * produces a terminal that is perfect until the window is resized and then wraps
 * every line at the wrong column, which reads as a rendering bug rather than as
 * two swapped arguments. The flip is absorbed in exactly one adapter on the
 * other side of the bridge; everything on this side says columns, then rows.
 */

/**
 * Output that arrives before this end learns which shell it belongs to.
 *
 * There is a real race here and it eats the most important bytes there are. The
 * far side attaches its output listener the moment the shell exists and starts
 * broadcasting immediately, while the id that names that shell is still
 * travelling back across the bridge — so the first frames, which are the login
 * banner and the prompt, arrive at a listener that does not yet know what to
 * compare them against. Dropping them leaves a black rectangle that only comes
 * to life once somebody types, which reads as a terminal that failed to open.
 *
 * So they are held, and once the id is known the ones that match are written in
 * order and the rest are discarded. The cap is what stops this becoming a leak
 * if the id never arrives at all: a shell that answers a quarter of a megabyte
 * before it answers its own name is one we have already lost.
 *
 * It is a small object rather than three variables in a closure because the
 * decision it makes is the whole of the fix, and a decision worth a paragraph is
 * worth a test.
 */
export const MOST_HELD_BYTES = 256 * 1024

export class ShellFrames {
  private held: ShellOutput[] | null = []
  private bytes = 0
  private id: string | null = null

  constructor(private readonly cap: number = MOST_HELD_BYTES) {}

  /** A frame arrived. Answers what to write now — empty while we are holding. */
  arrived(chunk: ShellOutput): string {
    if (this.id !== null) return chunk.shellId === this.id ? chunk.data : ''
    if (this.held !== null && this.bytes < this.cap) {
      this.held.push(chunk)
      this.bytes += chunk.data.length
    }
    return ''
  }

  /** The id came back. Answers everything held for it, in the order it arrived. */
  settled(shellId: string | null): string {
    const held = this.held ?? []
    this.held = null
    this.id = shellId
    if (shellId === null) return ''
    return held
      .filter((chunk) => chunk.shellId === shellId)
      .map((chunk) => chunk.data)
      .join('')
  }

  /** Nothing is coming. Let go of whatever is held. */
  give(): void {
    this.held = null
  }
}

interface Props {
  serverId: string
  /**
   * The folder the shell should open in, or null for wherever the account's own
   * sign-in lands — which is what every terminal this app opened before the
   * folder picker existed did.
   *
   * Read once, at the moment the shell is opened, and never again: it is not
   * where the shell *is*, it is where it was told to start. Nothing on this side
   * watches a server shell's working directory, so a prop that claimed to track
   * it would be a claim this window cannot make.
   *
   * Optional, so the component can still be rendered on its own — which is what
   * every test of it does.
   */
  startIn?: string | null
  bridge: ServersBridge
  fontSize?: number
  fontFamily?: string
  /**
   * Whether this pane is the one on screen.
   *
   * The element stays mounted either way — that is the whole reason a shell on a
   * server can be left and come back to — and this is what tells xterm to
   * measure itself again when it becomes visible. It cannot measure a hidden
   * element: a terminal fitted while `display: none` reports a column count from
   * a zero-width box, and the far end is then told to wrap at it.
   *
   * Defaults to true so the component can still be rendered on its own, which is
   * what every test of it does.
   */
  visible?: boolean
  /**
   * The far end has gone.
   *
   * Called once, when the shell this pane opened closes over there — somebody
   * typed `exit`, the connection dropped, the server rebooted. The window uses
   * it for the row's dot, so a session that has ended says so in the rail
   * instead of looking like one that is merely quiet.
   */
  onEnded?(): void
  /**
   * The far end's own id for the shell that was just opened.
   *
   * Called once, when `servers:shell:open` answers. The window needs it because
   * the *bar* over this pane does — the model, effort and fast-mode cluster
   * addresses a server terminal by exactly this id, and it is minted on the far
   * side of an IPC call that only this component makes. Until it existed the id
   * lived and died inside the effect below, so the one surface that could have
   * used it had no way to learn it.
   *
   * Not the same thing as `shellKey`, and the difference is why this is
   * necessary rather than convenient: the key is this window's handle, minted
   * before anything is opened so a tab can exist while the shell is still being
   * asked for. This is the handle the main process holds the channel under.
   */
  onOpened?(shellId: string): void
}

export const DEFAULT_SERVER_FONT_SIZE = 13

/** Reads a CSS custom property, so the terminal follows the app theme. */
function token(name: string, fallback: string): string {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

export function ServerTerminal({
  serverId,
  startIn = null,
  bridge,
  fontSize = DEFAULT_SERVER_FONT_SIZE,
  fontFamily = '',
  visible = true,
  onEnded,
  onOpened,
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  /**
   * Read inside the effect's own listeners, which are registered once for the
   * life of the shell. A captured callback would be whichever one was in hand
   * on the first render, and the window rebuilds its handlers whenever the tab
   * list changes — which is every time anything anywhere is opened or closed.
   */
  const endedRef = useRef(onEnded)
  endedRef.current = onEnded
  /** The same ref treatment, for the same reason. See {@link endedRef}. */
  const openedRef = useRef(onOpened)
  openedRef.current = onOpened
  /*
   * Destructured, because the hook returns a fresh object every render and only
   * `attach` is stable enough for a dependency list. Listing the object itself
   * would tear this pane down and open a **second shell on somebody's server**
   * every time the find field took a keystroke.
   */
  /**
   * The far end's id for this shell, once it has one.
   *
   * State as well as the local `shellId` inside the effect, because a *render*
   * has to see it: the link identity below is read at click time out of a ref
   * the hook rewrites every render, so a value that only ever lived inside the
   * effect could never reach it. Null until `servers:shell:open` answers, which
   * is a real window of a second or two — a link clicked in it carries no
   * session, and goes to the machine, which is what happened to every link in
   * this pane before today.
   */
  const [openedShellId, setOpenedShellId] = useState<string | null>(null)
  /*
   * Destructured, because the hook returns a fresh object every render and only
   * `attach` is stable enough for a dependency list. Listing the object itself
   * would tear this pane down and open a **second shell on somebody's server**
   * every time the find field took a keystroke.
   */
  /*
   * With this shell's identity, which it was called without.
   *
   * A shell on a server is a session everywhere else in this app — a tab, a row
   * in the rail, its own ⌘W — so a URL clicked in one belongs in that session's
   * own browser window. Called with nothing, the click reached main as a bare
   * address and `link:open` handed it to `shell.openExternal`, which is Chrome
   * on this Mac rather than anything to do with the server.
   *
   * The server's id stands in for the machine, which is the same thing the
   * binding menus and the window's own `hostMachineId` already do for a page
   * served by a server: one vocabulary, `<machineId>\0<sessionId>`, with a
   * server in the machine half.
   */
  const { attach: attachFind, bar: findBar } = useTerminalFind({
    ...(openedShellId === null ? {} : { sessionId: openedShellId }),
    machineId: serverId,
  })
  /**
   * Why the terminal is not here, when it is not.
   *
   * A build without the connection layer, or a server that refused the shell,
   * both end here — and both have to say so. An empty black rectangle is the
   * shape of a terminal that is about to work, and leaving one on screen is how
   * somebody waits for a prompt that is never coming.
   */
  const [refused, setRefused] = useState<string | null>(null)

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    const term = new Terminal({
      fontFamily: token('--font-mono', 'JetBrains Mono, Menlo, monospace'),
      fontSize: DEFAULT_SERVER_FONT_SIZE,
      lineHeight: 1.35,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 10_000,
      theme: terminalTheme(),
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(host)
    termRef.current = term
    fitRef.current = fit

    // Search, links and the three session chords — the same set a local session
    // gets, from the one hook that owns them.
    attachFind(term)

    // The GPU, or deliberately not it: `terminal-renderer.ts` carries the
    // measurements and the four rules. After `open`, because a renderer can only
    // replace a DOM that exists, and against `host` because that is the element
    // the window shows and hides when this tab is left and come back to.
    const detachRenderer = attachRenderer(term, host)

    // Fitted before the shell is asked for, so the first screen the far end
    // paints is already the shape of this pane. Opening first and resizing after
    // makes every shell start with one reflow of scrambled output.
    try {
      fit.fit()
    } catch {
      // A pane can be zero-sized on its first frame; the observer below fits it
      // the moment it is not.
    }

    /*
     * The shell's own id, which is not the server's.
     *
     * One server can only have one of these open from this page, but the far
     * side hands back an id per shell rather than keying on the server — so a
     * frame that arrives from a shell that has already been closed is
     * recognisable as such instead of being painted into its replacement.
     */
    let shellId: string | null = null
    let gone = false
    const frames = new ShellFrames()

    // Switching the app's theme has to reach a terminal that already exists —
    // resolved colours do not follow the sheet on their own. Without this, a
    // shell opened in one appearance stays in it while the window changes
    // around it.
    const offTheme = subscribeTheme(() => {
      term.options.theme = terminalTheme()
    })

    const offData = bridge.onServerShellOutput((raw) => {
      const chunk = asShellOutput(raw)
      if (chunk === null) return
      const data = frames.arrived(chunk)
      if (data !== '') term.write(data)
    })

    const offClosed = bridge.onServerShellClosed((raw) => {
      const chunk = asShellOutput(raw)
      if (chunk !== null && shellId !== null && chunk.shellId === shellId) {
        // Said in the terminal itself rather than as a notice beside it,
        // because that is where the person is looking and it is the last line
        // of that session's own output.
        term.write('\r\n\r\n[The connection to this server ended.]\r\n')
        shellId = null
        endedRef.current?.()
      }
    })

    const input = term.onData((data) => {
      if (shellId !== null) void bridge.writeToServerShell(shellId, data)
    })

    const observer = new ResizeObserver(() => {
      /*
       * A pane that has been hidden is a pane with no size, and it must not be
       * measured.
       *
       * This fires when the tab goes to the background, because hiding the pane
       * changes its box to nothing — and fitting against nothing produces a
       * column count of nothing, which would then be sent to the far end as the
       * width to wrap at. The shell would come back from the background having
       * reflowed its whole screen to a width no window has. Returning here
       * leaves the far end on the last size it was actually told, which is the
       * size it will be again the moment the pane is on screen.
       */
      if (host.clientWidth === 0 || host.clientHeight === 0) return
      try {
        fit.fit()
      } catch {
        // Mid-teardown, or a pane with no size. Neither is worth an error.
        return
      }
      if (shellId !== null) void bridge.resizeServerShell(shellId, term.cols, term.rows)
    })
    observer.observe(host)

    void bridge.openServerShell(serverId, term.cols, term.rows, startIn ?? undefined).then(
      (raw) => {
        const opened = asShellId(raw)
        if (gone) {
          // The pane went away while the far end was still opening. Close what
          // was opened rather than leaking a shell on somebody's machine.
          if (opened !== null) void bridge.closeServerShell(opened)
          return
        }
        if (opened === null) {
          frames.give()
          setRefused('This copy of the app could not open a terminal on that server.')
          return
        }
        shellId = opened
        // And into a render, so the link identity above can carry it. See
        // {@link openedShellId}.
        setOpenedShellId(opened)
        // Told before the backlog is drained, so the bar above this pane can
        // take its first reading of the screen as soon as there is a screen —
        // the main process has already attached its emulator to this id by the
        // time this promise resolved.
        openedRef.current?.(opened)
        // Everything that arrived while the id was in flight, in the order it
        // arrived, and nothing that belonged to a different shell.
        const missed = frames.settled(opened)
        if (missed !== '') term.write(missed)
      },
      () => {
        frames.give()
        if (!gone) setRefused('That server would not open a terminal.')
      },
    )

    return () => {
      gone = true
      observer.disconnect()
      input.dispose()
      offTheme()
      offData()
      offClosed()
      // Closed explicitly, and this matters more here than it does for a device.
      // Nothing on the far end is keeping this shell — there is no app there to
      // keep it — so a shell nobody closes is a stranded process on somebody
      // else's machine.
      if (shellId !== null) void bridge.closeServerShell(shellId)
      // Before `term.dispose()`: the pool has to give this seat up while the
      // terminal still exists, or the next tab to open is refused a context
      // that nothing is holding.
      detachRenderer()
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
    // `startIn` is deliberately absent from the dependencies. It is read once,
    // when the shell is opened, and a change to it must not tear down a live
    // terminal and dial a second one — which is what putting it here would do
    // if the window ever re-rendered this pane with a different folder.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverId, bridge, attachFind])

  useEffect(() => {
    const term = termRef.current
    if (!term) return
    term.options.fontSize = fontSize
    if (fontFamily !== '') term.options.fontFamily = fontFamily
    try {
      fitRef.current?.fit()
    } catch {
      // Same as above: a pane with no size yet.
    }
  }, [fontSize, fontFamily])

  /*
   * Measure again the moment this pane comes back, and take the keyboard.
   *
   * xterm cannot measure a hidden element, so a terminal that was fitted while
   * its tab was in the background is holding a column count from a zero-width
   * box — and the far end was told that count. Without this, switching away and
   * back leaves a shell wrapping every line at the wrong column, which reads as
   * a rendering fault rather than as a measurement taken with the lights off.
   *
   * On the next frame rather than in this one: the attribute that reveals the
   * pane is set by this same render, and a measurement taken before the browser
   * has laid it out reads the size it is leaving rather than the one it is
   * arriving at. This is the same arrangement `TerminalView` uses for a local
   * session, for the same reason.
   *
   * The resize is deliberately *not* sent from here. The observer below is
   * already watching this element and fires on the layout change the reveal
   * causes, so sending one here as well would put two window-change messages on
   * the channel for one event.
   */
  useEffect(() => {
    if (!visible) return
    const frame = requestAnimationFrame(() => {
      try {
        fitRef.current?.fit()
        termRef.current?.focus()
      } catch {
        // A pane with no size yet. The observer fits it when it has one.
      }
    })
    return () => cancelAnimationFrame(frame)
  }, [visible])

  /*
   * Arranged exactly as a local session is, for the two reasons `RemoteTerminal`
   * writes out at the same place: xterm is opened on an element with nothing
   * else in it — the rule `TerminalView` states — and the outer element is given
   * a position inline, because `.terminal-find` is `position: absolute` and
   * `.servers-terminal` has nothing to be absolute to. The stylesheets belong to
   * another lane this pass; `position` changes no part of this box.
   */
  return (
    <>
      {refused !== null && <p className="servers-card-why">{refused}</p>}
      <div className="servers-terminal" style={{ position: 'relative' }}>
        <div ref={hostRef} className="terminal-surface" />
        {findBar}
      </div>
    </>
  )
}
