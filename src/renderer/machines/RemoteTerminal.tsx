import { useCallback, useEffect, useRef, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { terminalTheme } from '../components/TerminalView'
// A second statement from the same module rather than one line with two names,
// deliberately: `wiring.test.ts` matches the import above *verbatim* to pin this
// terminal's palette to the one function that resolves it, and folding these
// together would break that pin for the sake of a shorter line.
import { useTerminalFind } from '../components/TerminalView'
import { holdUntilFilled, QUIET_MS } from '../components/terminal-backfill'
import { subscribeTheme } from '../theme'
import { attachRenderer } from '../terminal-renderer'
import { PASTE_TOO_BIG, attachClipboardOsc } from '../terminal-clipboard'
import { overPasteCap } from '../../shared/paste-cap'
import {
  draggingFiles,
  droppedPaths,
  droppedText,
  promptWord,
  readUploadOutcome,
  resolveDropBridge,
  transferLine,
} from '../terminal-drop'
import type { MachinesBridge } from './types'

/**
 * A session on another machine, on this screen.
 *
 * ## Why this is not `TerminalView`
 *
 * `TerminalView` is the app's terminal and it is bound to `window.deck`'s
 * session channels by name — `writeToSession`, `onSessionData`, `getScrollback`
 * — with the session id as its only handle. A session on another machine has
 * two handles, the machine and the session, and its bytes arrive on a different
 * channel. Threading a transport through `TerminalView` would put a branch in
 * the one component every local session already depends on, for the sake of a
 * feature that is one screen away.
 *
 * So the *xterm setup* is duplicated here. The *behaviour* used to be
 * deliberately withheld, and this is what that paragraph said:
 *
 *   > no find bar, no clear, no copy chords, because those are keymap bindings
 *   > that belong to a focused session in the main window and this is a pane
 *   > inside a panel.
 *
 * That was wrong, and it is the fourth time the same rule has had to be said:
 * *"the shape of the application should not be changing for local and remote
 * devices. It should act like that same."* Somebody typing into a session on
 * their office machine is not doing something lesser than typing into one here,
 * and a terminal that will not answer ⌘F because of where its bytes come from is
 * the app changing shape per machine. The links were the plainer half of it —
 * a URL printed by a build on this machine was clickable and the same URL from
 * the same build on another machine was not.
 *
 * So find, clickable links and the three session chords now come from
 * `useTerminalFind`, in `TerminalView`, which is the one place that owns them —
 * the same arrangement, and for the same reason, as `terminalTheme()`. What
 * remains genuinely different is what has to be: the transport, and the fact
 * that leaving this pane detaches rather than ends.
 *
 * The advice this comment used to end with turned out to be right, and taking
 * it is what the paragraph above describes: *"if a third caller ever needs a
 * terminal, the right move is to lift the setup into a hook."*
 *
 * ## Scrollback comes from the far machine, not from here
 *
 * There is no `getScrollback` equivalent: the protocol replays what the session
 * has already printed as `output` frames marked `replay` the moment this end
 * attaches.
 *
 * This file used to say the flag was of no interest here — *"replayed bytes and
 * live bytes are both just bytes to a terminal"* — and that sentence is the
 * defect he filmed. They are the same bytes and they are not the same event:
 * one is a screen being restored and the other is a session speaking. Written
 * without the distinction, opening a session on another machine scrolled its
 * whole afternoon past, a screen at a time, before settling at the bottom, and
 * leaving the pane and coming back did it again.
 *
 * So the flag is read now, and it is what tells the terminal its history has
 * finished arriving. `terminal-backfill.ts` holds the screen until then and
 * carries the whole argument, including why writing the replay in one call does
 * not help.
 */

/** Reads a CSS custom property, so the terminal follows the app theme. */
function token(name: string, fallback: string): string {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

/**
 * How many terminals in this window are showing each remote session.
 *
 * ## Why one attach for however many panes
 *
 * A session on another machine can be drawn twice at once: the window keeps a
 * pane for every remote session it has opened (see `machineSessionPanes` in
 * `App.tsx`), and the Machines panel can open the same session in place. Both
 * used to be impossible together — the panel replaced the pane — and with the
 * panes now outliving a trip to another page, both are mounted at once.
 *
 * Attaching is not idempotent on the far side. `server.ts` keeps **one handle
 * per connection per session**, and a second `attach` for the same id detaches
 * the first before taking its place. So the second pane's arrival was harmless,
 * and its *departure* was not: one `detach` frame took the only handle away and
 * the pane still on screen went deaf — permanently, because nothing re-attaches
 * a terminal that is already built.
 *
 * The count is what makes the pair of frames match the pair of terminals: the
 * first pane attaches, the last one to leave detaches, and everything in
 * between shares the one subscription. It can live in a module-level map
 * precisely because the panes live here too — both are renderer state in one
 * window, so a reload takes the map and the terminals together and they cannot
 * be left disagreeing.
 *
 * What a second pane gives up is its history: the replay comes with the attach,
 * and there is only one attach. It fills with whatever the session says next.
 * That is the honest trade — the alternative is the first pane going silent,
 * and a terminal with no scrollback is a smaller loss than a terminal with no
 * session.
 */
const watchers = new Map<string, number>()

/** Both handles as one key. The NUL cannot occur in either. */
function watchKey(machineId: string, sessionId: string): string {
  return `${machineId}\u0000${sessionId}`
}

/** Whether this terminal is the one that has to ask the far machine. */
function firstWatcher(machineId: string, sessionId: string): boolean {
  const key = watchKey(machineId, sessionId)
  const before = watchers.get(key) ?? 0
  watchers.set(key, before + 1)
  return before === 0
}

/** Whether this terminal was the last one, and the session should be let go. */
function lastWatcher(machineId: string, sessionId: string): boolean {
  const key = watchKey(machineId, sessionId)
  const left = (watchers.get(key) ?? 1) - 1
  if (left > 0) {
    watchers.set(key, left)
    return false
  }
  watchers.delete(key)
  return true
}

interface Props {
  machineId: string
  sessionId: string
  bridge: MachinesBridge
  /**
   * Subscribe to this session's bytes.
   *
   * Passed in rather than resolved here because the panel is already holding
   * one subscription to `onMachineOutput` for every session on screen, and a
   * second one per terminal would deliver the same chunk twice to whichever
   * pane happened to be mounted first.
   *
   * `replay` is the frame's own flag: true for the scrollback the far machine
   * sends when this end attaches, false for the session speaking now. It is
   * carried through rather than dropped at the panel because the difference is
   * what stops the history being watched — see the note at the top of this file.
   */
  subscribe(handler: (data: string, replay: boolean) => void): () => void
  fontSize?: number
  fontFamily?: string
}

/** How long a refusal stays on screen. Long enough to read twice. */
const NOTE_MS = 6000

export const DEFAULT_REMOTE_FONT_SIZE = 13

export function RemoteTerminal({
  machineId,
  sessionId,
  bridge,
  subscribe,
  fontSize = DEFAULT_REMOTE_FONT_SIZE,
  fontFamily = '',
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  /*
   * The one line this pane may draw over the terminal, and the timer that takes
   * it away again.
   *
   * It exists because of the rule this whole pass is under: **a silent failure
   * is the worst outcome**. A paste that is refused, a clipboard this window
   * cannot reach, a file that did not send — every one of those used to be
   * nothing at all happening, which is indistinguishable from the feature not
   * existing. It is one line and never a paragraph; his standing rule this round
   * is that there is no explanatory prose on screen.
   *
   * Nothing is ever *typed* here. A note is drawn over the pane, so a session's
   * transcript still contains only what the person and the agent put in it.
   */
  const [note, setNote] = useState('')
  const noteTimer = useRef<number | null>(null)
  const say = useCallback((line: string, sticky = false) => {
    setNote(line)
    if (noteTimer.current !== null) window.clearTimeout(noteTimer.current)
    // A progress line is replaced by the next one and cleared when the transfer
    // ends, so it holds; a refusal is read once and should not sit on somebody's
    // terminal for the rest of the session.
    noteTimer.current =
      line === '' || sticky ? null : window.setTimeout(() => setNote(''), NOTE_MS)
  }, [])
  useEffect(() => () => {
    if (noteTimer.current !== null) window.clearTimeout(noteTimer.current)
  }, [])
  /*
   * Destructured, because the hook hands back a fresh object every render and
   * `attach` is the only half that may go in a dependency list. Holding the
   * object and listing it below would detach and re-attach this session — a
   * round trip to another machine — on every keystroke into the find field.
   */
  const { attach: attachFind, bar: findBar } = useTerminalFind()

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    const term = new Terminal({
      fontFamily: token('--font-mono', 'JetBrains Mono, Menlo, monospace'),
      fontSize: DEFAULT_REMOTE_FONT_SIZE,
      lineHeight: 1.35,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 10_000,
      // The local terminal's own colours, from the one function that resolves
      // them — a remote session that did not match a local one would be the
      // first thing anybody noticed about this pane. It is applied again below
      // whenever the theme changes, for the reason written out there.
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

    /*
     * A program on the *other* machine putting something on the clipboard of
     * this one.
     *
     * The other half of his sentence — *"if I copy from there I cannot paste
     * here"*. Selecting with the mouse and pressing ⌘C already worked, because
     * that selection lives in this xterm on this Mac; what never worked is a
     * `tmux`, a `vim` or an agent over there running the copy itself, which a
     * terminal program does with OSC 52 and which xterm.js does not implement.
     * `terminal-clipboard.ts` carries the whole of it, including why the *read*
     * form of the same sequence is refused and never answered.
     */
    const detachClipboard = attachClipboardOsc(term, (line) => say(line))

    /*
     * A paste bigger than this wire will carry, refused where it can be seen.
     *
     * In the capture phase and on the host element, so this runs before xterm's
     * own handler on the textarea inside it. `MachineLink.input` refuses the
     * same paste as a backstop and can only answer a boolean — which is the
     * silent failure again, one layer down.
     */
    const onPaste = (event: ClipboardEvent): void => {
      const text = event.clipboardData?.getData('text') ?? ''
      if (text === '' || !overPasteCap(text)) return
      event.preventDefault()
      event.stopPropagation()
      say(PASTE_TOO_BIG)
    }
    host.addEventListener('paste', onPaste, true)

    // The GPU, or deliberately not it: `terminal-renderer.ts` carries the
    // measurements and the four rules. After `open`, because a renderer can
    // only replace a DOM that exists, and against `host` because that is the
    // element the panel shows and hides.
    const detachRenderer = attachRenderer(term, host)

    /*
     * The replay goes in with the screen held, and the screen appears once,
     * already at the bottom.
     *
     * Two things end the hold and the first one wins. A frame that is *not*
     * replay is the far machine having finished its scrollback and gone back to
     * speaking, which is the answer for a session that is busy. `QUIET_MS` is
     * the answer for the ordinary one — an agent waiting for input sends
     * nothing after its replay, so there is no such frame to wait for, and the
     * run of replay frames simply stops. Both are in `terminal-backfill.ts`,
     * along with the ceiling that makes this only ever a delay.
     */
    const backfill = holdUntilFilled(term, host, { quiet: QUIET_MS })
    const offData = subscribe((data, replay) => {
      backfill.push(data)
      if (!replay) backfill.release()
    })

    // Fitted before the attach, so the first screen the far machine paints is
    // already the shape of this pane. Attaching first and resizing after makes
    // every session open with one reflow of scrambled output.
    try {
      fit.fit()
    } catch {
      // The pane can be zero-sized on the first frame — a panel that has not
      // been laid out yet — and the observer below fits it the moment it is not.
    }
    /*
     * And the attach itself — once for the session, however many panes are
     * showing it. `watchers` above carries why.
     *
     * A pane that is not the first gets no replay, so there is nothing for the
     * hold to wait for: released here rather than left to time out, which would
     * be a blank terminal for two seconds and then the same empty screen.
     *
     * Subscribed before this rather than after, which is the other half of the
     * ordering the comment above is about: the attach is what makes the far
     * machine start sending, and a subscription registered afterwards is a
     * subscription with a gap in front of it.
     */
    if (firstWatcher(machineId, sessionId)) {
      void bridge.attachMachineSession(machineId, sessionId, term.cols, term.rows)
    } else {
      backfill.release()
    }

    // Switching the app's theme has to reach a terminal that already exists.
    // Resolved colours do not follow the sheet on their own, so without this a
    // remote session stays in the palette it was opened in — see the note in
    // `TerminalView`, where the same omission left every session a black slab
    // on a white app.
    const offTheme = subscribeTheme(() => {
      term.options.theme = terminalTheme()
    })

    const input = term.onData((data) => {
      void bridge.writeToMachineSession(machineId, sessionId, data)
    })

    const observer = new ResizeObserver(() => {
      try {
        fit.fit()
      } catch {
        // Mid-teardown, or a pane with no size. Neither is worth an error.
        return
      }
      void bridge.resizeMachineSession(machineId, sessionId, term.cols, term.rows)
    })
    observer.observe(host)

    return () => {
      observer.disconnect()
      input.dispose()
      offTheme()
      offData()
      backfill.stop()
      // Detached explicitly, and only by the last pane showing this session.
      // The far machine keeps the session running — that is the point of a
      // session — but it stops sending output to a terminal that no longer
      // exists, and a link that is still up would otherwise carry the bytes of
      // every pane anybody had ever opened. `watchers` above carries why this is
      // counted rather than unconditional.
      if (lastWatcher(machineId, sessionId)) {
        void bridge.detachMachineSession(machineId, sessionId)
      }
      // Before `term.dispose()`: the pool has to give this seat up while the
      // terminal still exists, or the next pane to open is refused a context
      // that nothing is holding.
      host.removeEventListener('paste', onPaste, true)
      detachClipboard()
      detachRenderer()
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
  }, [machineId, sessionId, bridge, subscribe, attachFind, say])

  /*
   * The file in flight, as one line.
   *
   * Subscribed here rather than inside the terminal's own effect so that a
   * transfer survives a re-render of the pane, and filtered on `machineId`
   * because one window can be sending to one machine while showing a session on
   * another — the same reason the frame carries the id at all.
   */
  useEffect(
    () =>
      bridge.onMachineUpload((raw) => {
        if (!raw || typeof raw !== 'object') return
        const frame = raw as { machineId?: unknown; progress?: unknown }
        if (frame.machineId !== machineId) return
        const progress = frame.progress
        if (!progress || typeof progress !== 'object') return
        const shape = progress as { name?: unknown; size?: unknown; sent?: unknown; phase?: unknown; message?: unknown }
        const line = transferLine({
          name: typeof shape.name === 'string' ? shape.name : 'That file',
          size: typeof shape.size === 'number' ? shape.size : 0,
          sent: typeof shape.sent === 'number' ? shape.sent : 0,
          phase: typeof shape.phase === 'string' ? shape.phase : '',
          message: typeof shape.message === 'string' ? shape.message : '',
        })
        // Progress holds until the next frame replaces it; a failure is a
        // refusal and expires like every other one.
        say(line, shape.phase !== 'failed')
      }),
    [bridge, machineId, say],
  )

  /**
   * Something dropped on a session that is running on another computer.
   *
   * Files are **sent** first — the same `upload.*` verbs the phone uses — and
   * only the path the far machine answers with is typed, quoted, at the prompt.
   * Typing the local path instead would be the plausible wrong answer: it names
   * a file that does not exist on the machine the agent is running on.
   *
   * One at a time, because the host serves one upload per connection, and each
   * is typed as it lands rather than all of them at the end: a drop of four
   * files fills the prompt as it goes, and a failure part way through leaves the
   * ones that did land on the line, which is true.
   *
   * Everything goes in through `term.paste` rather than a raw write, so a
   * session in bracketed-paste mode receives it wrapped exactly as it would
   * receive a ⌘V — a drop must not be more dangerous than a paste of the same
   * text.
   */
  const onDrop = useCallback(
    async (event: React.DragEvent<HTMLDivElement>): Promise<void> => {
      // Before anything else and on every path: without it Chromium's default
      // for a dropped file is to *navigate to it*, which replaced the whole
      // application with a picture of the photo somebody dropped.
      event.preventDefault()
      const term = termRef.current
      if (!term) return

      const files = Array.from(event.dataTransfer?.files ?? [])
      const bridgeForPaths = files.length === 0 ? null : resolveDropBridge()
      const paths = bridgeForPaths ? droppedPaths(files, bridgeForPaths) : []
      if (paths.length === 0) {
        /*
         * Nothing on this disk was dropped — dragged text, or an image out of a
         * web page, both of which produce `File`-shaped items with no path
         * behind them. The text the same drag carries is typed instead, and only
         * a drop with neither gets a line: a gesture that does nothing and says
         * nothing is the failure this pass exists to remove.
         */
        const text = droppedText(event.dataTransfer?.getData('text/plain') ?? '')
        if (text !== '') term.paste(text)
        else if (files.length > 0) say('Nothing in that drop is a file on this machine.')
        return
      }

      for (const path of paths) {
        const outcome = readUploadOutcome(await bridge.uploadToMachine(machineId, path))
        // Re-read rather than reused: a transfer takes as long as it takes, and
        // the pane can be closed or the session left while it is running. The
        // terminal captured before the await would be a disposed one, and
        // `paste` on it throws inside a promise nobody is watching.
        const live = termRef.current
        if (!live) return
        if (!outcome.ok) {
          say(outcome.message)
          return
        }
        // Cleared here rather than by the `landed` frame alone, so the line goes
        // at the moment the path appears — which is the only success signal this
        // needs, and the reason there is no "sent" message.
        say('')
        live.paste(promptWord(outcome.path))
      }
    },
    [bridge, machineId, say],
  )

  // Applied to the live terminal rather than only at construction, so a change
  // in Appearance reaches a pane that is already open. Settings has shipped a
  // font size that never reached a terminal once already.
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
   * Two elements now, arranged exactly as a local session is, and both halves
   * of that are deliberate.
   *
   * **xterm gets an element with nothing else in it.** `TerminalView` already
   * wrote the rule down — *"xterm measures the element it was opened on, so it
   * gets one of its own with nothing else in it — the find bar floats over the
   * host instead"* — and the same class is reused rather than copied, which also
   * brings the right-edge clip that stops a right-aligned status line being cut
   * off by the pane. Putting the bar in the same element xterm owns would also
   * leave React inserting a node into a parent whose other child is a DOM tree
   * React knows nothing about.
   *
   * **The outer element is positioned inline.** `.terminal-find` is
   * `position: absolute` and needs something to be absolute *to*; the local
   * session gets that from `.terminal-host`, and `.machines-terminal` has no
   * position of its own. It is set here rather than in `machines.css` because
   * the stylesheets belong to another lane this pass, and it changes nothing
   * about the box — not `display`, not `flex`, not a size. Worth moving into the
   * sheet the next time that file is open for another reason.
   */
  return (
    <div
      className="machines-terminal"
      style={{ position: 'relative' }}
      /*
       * `dragOver` has to preventDefault or `drop` never fires at all — that is
       * how the HTML drag-and-drop model works, and it is the single most common
       * way a drop handler ships doing nothing. `copy` is what makes the cursor
       * show a plus rather than the "no entry" sign, which is the only feedback
       * there is that this pane will take the file.
       */
      onDragOver={(event) => {
        if (!draggingFiles(event.dataTransfer) && !event.dataTransfer?.types.includes('text/plain')) return
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
      }}
      onDrop={(event) => void onDrop(event)}
    >
      <div ref={hostRef} className="terminal-surface" />
      {findBar}
      <TransferNote line={note} />
    </div>
  )
}

/**
 * One line over the bottom of the terminal, or nothing.
 *
 * Inline styles rather than a class in `machines.css`, following the decision
 * the wrapper above already made and for the same reason: the stylesheets belong
 * to another lane this pass. It reads its colours from the app's own tokens, so
 * it follows the theme like everything else, and it is `pointer-events: none` so
 * a line that is still fading cannot swallow a click meant for the session
 * underneath it.
 *
 * `aria-live` because this is the only announcement of a refusal: somebody using
 * a screen reader pressed ⌘V and has even less to go on than somebody watching
 * the pane.
 */
function TransferNote({ line }: { line: string }) {
  if (line === '') return null
  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        position: 'absolute',
        left: 8,
        right: 8,
        bottom: 8,
        padding: '4px 8px',
        borderRadius: 6,
        background: 'var(--chrome-solid, rgba(0,0,0,0.72))',
        color: 'var(--text, #e6e6e6)',
        border: '1px solid var(--border, rgba(255,255,255,0.12))',
        font: '12px/1.4 var(--font-ui, system-ui, sans-serif)',
        whiteSpace: 'nowrap',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        pointerEvents: 'none',
      }}
    >
      {line}
    </div>
  )
}
