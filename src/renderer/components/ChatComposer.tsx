import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { AttachChips } from '../chat/attach/AttachChips'
import { AttachMenu } from '../chat/attach/AttachMenu'
import {
  addAttachments,
  composeMessage,
  removeAttachment,
  shellQuote,
  terminalPayload,
  type Attachment,
  type AttachScope,
} from '../chat/attach/mentions'
import {
  confinedRefusal,
  pasteAttachment,
  picksFromDrop,
  resolveOutsideBridge,
  sessionBoundary,
  UNCONFINED,
  type AttachBoundary,
  type AttachOutsideBridge,
  type OutsidePick,
} from '../chat/attach/outside'
import { appendSpoken } from '../chat/voice/dictation'
import { DictateButton } from '../chat/voice/DictateButton'
import { useControlOffer } from '../features/offer'
import './ChatComposer.css'

interface Props {
  /** Absent while no session is focused; the box then explains itself. */
  onSend?: (text: string) => void
  /** Project root. Attachments are resolved and confined to it. */
  cwd?: string | null
  disabled?: boolean
  placeholder?: string
  /**
   * The agent's controls, rendered on the box's own bottom row beside the plus.
   *
   * A slot rather than an import, because `wiring.test.ts` pins `AgentControls`
   * and `UsageStrip` to `ChatView.tsx` — that table is the record of them
   * having shipped mounted nowhere, and the fix for a messy composer is not to
   * move the seam it guards. So the owner stays the same and only the place
   * they are drawn changes.
   */
  controls?: ReactNode
  /**
   * Whether this session is a plain shell rather than an agent CLI.
   *
   * It decides what the menu behind the plus *offers*, not whether there is
   * one. That distinction is the bug this prop was born with. Every entry
   * behind the plus used to add an `@"path"` mention, which an agent expands on
   * submit and a shell types verbatim at its prompt — so the menu was withdrawn
   * from a shell entirely, and that composer was left with a microphone, a send
   * button and nothing else. Reported back in one sentence: *"you actually
   * removed everything rather than making it simple"*.
   *
   * Picking a file out of the project is not an agent feature; only the form of
   * the result was. So a shell keeps the menu and gets the form its prompt can
   * read — a quoted absolute path typed into the command line — and loses only
   * the two rows that genuinely need an agent on the other end: an image, which
   * is a separate kind of thing only because an agent *sees* it, and
   * connectors, which are its tools.
   */
  shell?: boolean
  /**
   * The live session this box is writing into, when there is one.
   *
   * Used for exactly one question, and it is a question only the main process
   * can answer: is this session held inside a folder by the operating system? A
   * session started from a paired device or by the copilot is, and it appears in
   * this window as an ordinary tab with nothing on `SessionMeta` saying so. On
   * one of those, a file from outside the folder cannot be read at all —
   * measured, `main/confine/escapes.test.ts` — so offering to attach one would
   * be a chip, a mention, and an agent reporting that it cannot open the file.
   *
   * Absent is a real answer and means "no live session", which is also the
   * harness and every test that does not care. See `main/session-boundary.ts`.
   */
  sessionId?: string | null
  /** Test seam for browse, drop and paste. Absent means the real bridge. */
  outsideBridge?: AttachOutsideBridge
}

const MAX_ROWS = 12
/** How long a refusal stays on screen before the chips row gets quiet again. */
const NOTICE_MS = 4000

/**
 * Typing into chat mode.
 *
 * The message is written to the session's terminal exactly as if it had been
 * typed there, because that IS where the agent is listening — chat mode is a
 * different view of the same session, not a different channel. So there is no
 * second transport to keep in sync, and a reply sent here shows up in the
 * terminal view too.
 *
 * That one channel is also why attachments are text: an attachment is an
 * `@"…"` mention the CLI expands on submit, not an upload. `chat/attach/
 * mentions.ts` holds the exact forms and the measurements behind them —
 * including the reason a message carrying one is sent with a trailing space.
 *
 * `onSend` is handed the message *without* its carriage return, and the caller
 * must not simply append one: measured through a pty, a single write of 64
 * bytes or more is read as pasted text and its Enter does not submit, so
 * `writeToSession(id, text + '\r')` silently does nothing for every message
 * carrying an attachment. `terminalWrites` in `mentions.ts` is the sequence
 * that works — two writes, `SUBMIT_GAP_MS` apart.
 *
 * ## The shape
 *
 * One box, tall enough to look like somewhere you write a paragraph, with every
 * control inside its frame: attachments above the text, and a single row under
 * it holding the plus, the agent's controls, the microphone and send. Before
 * this, the plus and the microphone squeezed a single-line field between them
 * and three further rows of controls and readouts hung underneath — which is
 * the thing that got reported, in these words: "it's very messy with a lot of
 * options under the chat box".
 *
 * Nothing on that row is a bare icon on its own: the plus carries a word ("Add"
 * for an agent, "Path" for a shell), the controls carry their names and their
 * values, the panel behind them is called Options and names its whole contents
 * on hover, and the two glyphs that stay glyphs — the microphone and send — are
 * the pair every chat app in the world draws in that corner, and both say what
 * they are on hover.
 *
 * ## Folding is not deleting
 *
 * Said here because it is the mistake this composer has already made once. The
 * first pass at "one box with the options folded inside it" folded two controls
 * onto the row, two behind a button labelled "More", and — on a shell — the plus
 * into nothing at all, which came back as *"all the options you have actually
 * removed"*. Nothing on this row may be dropped to make the row shorter. If a
 * control does not fit, it goes in the Options panel, which lists every one of
 * them; if it does not belong on this kind of session, it changes form rather
 * than disappearing. `wiring.test.ts` pins the list.
 */
export function ChatComposer({
  onSend,
  cwd,
  disabled = false,
  placeholder,
  controls,
  shell = false,
  sessionId,
  outsideBridge,
}: Props) {
  const [text, setText] = useState('')
  const [attachments, setAttachments] = useState<Attachment[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  /**
   * Whether a drag is currently over the box.
   *
   * A counter rather than a boolean, because `dragleave` fires every time the
   * pointer crosses into a *child* — the chips, the textarea, a button on the
   * control row — and a boolean flickers off under a drag that never left. The
   * enter/leave pair balances, so the depth is the honest signal.
   */
  const [dragDepth, setDragDepth] = useState(0)
  const [boundary, setBoundary] = useState<AttachBoundary>(UNCONFINED)
  const boxRef = useRef<HTMLTextAreaElement>(null)
  /**
   * The attachment list as it is right now, for the handlers that finish late.
   *
   * A drop and a paste both add their files in a `then`, after a round trip to
   * the main process, and by then the `attachments` a callback captured can be a
   * render out of date. Reading through a ref means the fold in `add` always
   * starts from what is on screen. See `add` for the bug that made this
   * necessary and the one it now prevents.
   */
  const attachmentsRef = useRef<readonly Attachment[]>(attachments)
  attachmentsRef.current = attachments
  /**
   * What the microphone's place says when voice dictation is not installed.
   *
   * Null while it is on, and then the real button is drawn. Uninstalling used
   * to leave nothing at all here — half the store's features disappearing
   * without a trace is the failure FEATURE-STORE.md is most worried about, and
   * a corner of a chat box is exactly where somebody looks for a microphone and
   * concludes the app has none.
   */
  const voiceOffer = useControlOffer('chat.dictate')

  const root = cwd ?? ''

  // Grow with the content up to a ceiling, then scroll. Measured from
  // scrollHeight rather than counting newlines, which ignores wrapped lines.
  // The floor is CSS's, not this function's: `min-height` on `.cc-input` clamps
  // whatever is written here, so an empty box still stands three lines tall.
  useEffect(() => {
    const box = boxRef.current
    if (!box) return
    box.style.height = 'auto'
    const line = parseFloat(getComputedStyle(box).lineHeight) || 18
    box.style.height = `${Math.min(box.scrollHeight, line * MAX_ROWS)}px`
  }, [text])

  // A refusal is transient information, so it clears itself rather than
  // needing a dismiss button next to the thing it is complaining about.
  useEffect(() => {
    if (notice === null) return
    const timer = setTimeout(() => setNotice(null), NOTICE_MS)
    return () => clearTimeout(timer)
  }, [notice])

  // Attachments belong to the message being written, not to the session: when
  // the project changes underneath, the paths they point at no longer apply.
  useEffect(() => {
    setAttachments([])
    setNotice(null)
  }, [root])

  /*
   * Ask, once per session, what this one is allowed to read.
   *
   * Once, because a boundary is decided before the process starts and cannot be
   * widened afterwards — asking again per attachment would be the same answer at
   * a higher price. Reset to unconfined first so that switching from a phone's
   * session to one of your own does not carry the refusal across for as long as
   * the round trip takes; the wrong direction for that gap is a Browse button
   * that is disabled on a session where it works.
   */
  useEffect(() => {
    setBoundary(UNCONFINED)
    const bridge = resolveOutsideBridge(outsideBridge)
    if (bridge === null || !sessionId) return
    let live = true
    void sessionBoundary(bridge, sessionId).then((answer) => {
      if (live) setBoundary(answer)
    })
    return () => {
      live = false
    }
  }, [sessionId, outsideBridge])

  const focusBox = useCallback(() => boxRef.current?.focus(), [])

  const send = useCallback(() => {
    const message = composeMessage(attachments, text)
    if (message === '' || disabled || !onSend) return
    onSend(terminalPayload(message))
    setText('')
    setAttachments([])
  }, [attachments, text, disabled, onSend])

  const onKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    // Enter sends, Shift+Enter is a newline — the convention every chat app
    // uses, and the opposite would make multi-line prompts painful.
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      send()
    }
  }

  const insert = useCallback((snippet: string) => {
    setText((current) => appendSpoken(current, snippet))
  }, [])

  /**
   * Why a file from outside the project is refused on this session, or null.
   *
   * Null on every session started in this window, which is all of them until a
   * phone or the copilot starts one. See the `sessionId` prop.
   */
  const outsideRefusal = boundary.confined
    ? confinedRefusal(boundary.folder, boundary.projects)
    : null

  /**
   * What a batch of picks becomes, from any of the four routes into this box.
   *
   * Two answers, because there are two things on the other end. An agent gets
   * attachments, which are `@"path"` mentions the CLI expands on submit and
   * chips above the text in the meantime. A shell gets the paths themselves,
   * quoted, appended to the command line it is already writing — there is
   * nothing to attach to a `/bin/zsh`, and `shellQuote` is what keeps a folder
   * called "My Project" from arriving as two arguments.
   *
   * ## Why this takes a list, and why it reads a ref
   *
   * Both because of the same bug, which was written here, shipped into a running
   * app and caught by dropping two files on it and looking: only one chip
   * appeared. This called `addAttachment` once per pick, and every call in that
   * loop read the same `attachments` out of the same closure, so each result
   * threw away the one before it. `addAttachments` folds the batch instead.
   *
   * The ref closes the other half. A drop and a paste both finish in a `then`,
   * by which point the `attachments` captured when the handler was created may
   * be a render behind — and dropping a file *while a paste is resolving* is not
   * exotic, it is two ordinary gestures a second apart. The ref is always the
   * list that is actually on screen.
   *
   * The paths arrive absolute. They used to arrive relative and be joined here,
   * which stopped being possible when three of the four routes started producing
   * paths that have no relative form — see `AttachPicker`'s `onPick`.
   */
  const add = useCallback(
    (picks: readonly OutsidePick[], scope: AttachScope) => {
      if (picks.length === 0) return
      if (shell) {
        for (const pick of picks) insert(shellQuote(pick.path))
        return
      }
      const result = addAttachments(attachmentsRef.current, root, picks, scope)
      setAttachments(result.attachments)
      /*
       * `notice` carries the one caution as well as any refusal, and the caution
       * is the interesting half. A file from anywhere expands fine — measured,
       * and the whole reason this escape hatch is honest. A *folder* from outside
       * the project is the case the CLI mishandles: the listing it injects reads
       * to the model as an injection attempt and gets refused. Said here, rather
       * than left for the agent to say something stranger about a minute later.
       */
      setNotice(result.notice)
    },
    [root, shell, insert],
  )

  /**
   * The same, for the three routes that reach outside the project.
   *
   * `outsideRefusal` is checked once for the batch rather than per pick: the
   * boundary is a property of the session, so the answer cannot differ between
   * two files dropped together, and repeating the sentence four times would be
   * four copies of the same refusal.
   */
  const addPicks = useCallback(
    (picks: readonly OutsidePick[]) => {
      if (picks.length === 0) return
      if (outsideRefusal !== null) {
        setNotice(outsideRefusal)
        return
      }
      add(picks, 'anywhere')
    },
    [add, outsideRefusal],
  )

  /**
   * A file dragged from the file manager onto the box.
   *
   * The path has to be fetched through the preload — `File.path` was Electron's
   * own extension to the web `File` and it was removed in Electron 32, so a
   * handler reading it here would attach nothing and say nothing. See
   * `pathForDroppedFile`.
   */
  const onDrop = useCallback(
    (event: React.DragEvent<HTMLDivElement>): void => {
      setDragDepth(0)
      const files = Array.from(event.dataTransfer?.files ?? [])
      if (files.length === 0) return
      // Only once there is a file to take. A drag of selected *text* over a text
      // box should still drop as text, which is what the browser does by
      // default and what someone dragging a paragraph is asking for.
      event.preventDefault()
      const bridge = resolveOutsideBridge(outsideBridge)
      if (bridge === null) {
        setNotice('Dropping a file is not wired into this build.')
        return
      }
      void picksFromDrop(bridge, files).then((picks) => {
        if (picks.length === 0) {
          setNotice('That could not be read as a file on this machine.')
          return
        }
        addPicks(picks)
      })
    },
    [outsideBridge, addPicks],
  )

  /**
   * ⌘V, when what is on the clipboard is not text.
   *
   * Two sources, tried in this order, and the order is the same measured trap
   * the main process guards: a *file* copied in Finder also puts a rendered
   * preview of itself on the pasteboard, so anything that checks for an image
   * first would write a second copy of a file the user already has and attach
   * the copy.
   *
   *  1. `clipboardData.files` — what Chromium already parsed. A file copied in
   *     Finder arrives here with a real path behind it.
   *  2. `attach:paste` — the main process reading the pasteboard itself. This is
   *     the one that catches a screenshot taken to the clipboard, which has no
   *     file anywhere until it is written out.
   *
   * Plain text falls through both and pastes normally, because `preventDefault`
   * is only called once there is something to attach.
   */
  const onPaste = useCallback(
    (event: React.ClipboardEvent<HTMLTextAreaElement>): void => {
      const files = Array.from(event.clipboardData?.files ?? [])
      const items = Array.from(event.clipboardData?.items ?? [])
      const hasFile = files.length > 0 || items.some((item) => item.kind === 'file')
      if (!hasFile) return
      event.preventDefault()
      const bridge = resolveOutsideBridge(outsideBridge)
      if (bridge === null) {
        setNotice('Pasting a file is not wired into this build.')
        return
      }
      void picksFromDrop(bridge, files).then(async (dropped) => {
        if (dropped.length > 0) {
          addPicks(dropped)
          return
        }
        const outcome = await pasteAttachment(bridge)
        if (outcome.kind === 'failed') setNotice(outcome.message)
        else if (outcome.kind === 'picked') addPicks(outcome.picks)
      })
    },
    [outsideBridge, addPicks],
  )

  /**
   * The padding is part of the field.
   *
   * A big box with a small textarea inside it is a trap: click in the margin
   * above the controls and nothing happens, which reads as a dead surface. Only
   * a press that landed on the box itself counts — a press that started on a
   * button, a chip or the text is that thing's own — and the default is
   * prevented so focus does not move away again on mouse-up.
   */
  const focusFromFrame = (event: React.MouseEvent<HTMLDivElement>): void => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    focusBox()
  }

  const idle = !onSend
  const off = disabled || idle
  const empty = composeMessage(attachments, text) === ''

  const dragging = dragDepth > 0 && !off

  return (
    <div className="chat-composer">
      <div
        className={`${off ? 'cc-box cc-box-off' : 'cc-box'}${dragging ? ' cc-box-drop' : ''}`}
        onMouseDown={focusFromFrame}
        /*
         * A drop target has to say yes twice.
         *
         * `dragover` with `preventDefault` on every frame is what tells the
         * browser this element accepts the drag; without it the drop never
         * fires and the file opens in the window instead, replacing the whole
         * app with a picture. `dropEffect` is what changes the cursor to a copy
         * badge, which is the only thing on screen saying "let go here" before
         * the border lights up.
         */
        onDragOver={(event) => {
          if (off || event.dataTransfer === null) return
          event.preventDefault()
          event.dataTransfer.dropEffect = 'copy'
        }}
        onDragEnter={() => setDragDepth((depth) => depth + 1)}
        onDragLeave={() => setDragDepth((depth) => Math.max(depth - 1, 0))}
        onDrop={onDrop}
      >
        <AttachChips
          attachments={attachments}
          notice={notice}
          onRemove={(path) => setAttachments((current) => removeAttachment(current, path))}
        />

        <textarea
          ref={boxRef}
          className="cc-input"
          rows={1}
          value={text}
          disabled={off}
          spellCheck
          placeholder={idle ? 'Open a session to write to it' : (placeholder ?? 'Message the agent…')}
          // The label follows the placeholder rather than being fixed: a screen
          // reader on a plain shell was being told it had focused a box for
          // messaging an agent that is not in the session. The ellipsis is a
          // typographic invitation and belongs only to the visible hint.
          aria-label={(placeholder ?? 'Message the agent').replace(/…$/, '')}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
        />

        <div className="cc-foot">
          <div className="cc-foot-left">
            {/* Drawn for a shell as well as for an agent, and the mode is what
                differs — see the `shell` prop for the regression that rule
                exists to close. */}
            <AttachMenu
              root={root}
              attachments={attachments}
              onAdd={add}
              onInsert={insert}
              onNotice={setNotice}
              onClose={focusBox}
              disabled={off || root === ''}
              mode={shell ? 'path' : 'mention'}
              // Null on every session started at this keyboard. Non-null only
              // for one held inside a folder by the OS, where Browse is drawn
              // disabled with this sentence on it rather than quietly missing.
              browseRefusal={outsideRefusal}
              {...(outsideBridge ? { outsideBridge } : {})}
            />
            {controls}
          </div>
          <div className="cc-foot-right">
            {/*
              The microphone belongs to voice dictation, and voice dictation is
              off until somebody turns it on in Settings → Tools.

              There used to be a ghost microphone here when it was off — a
              button reading "not installed, press to install it", because the
              feature store's rule was *where a feature would have been, offer
              it*, and a control that simply vanishes teaches the reader that
              the app cannot do the thing. Both halves of that reasoning have
              changed. There is no store to install from, so the offer had
              nowhere to send anyone; and the reason the switch exists at all is
              that this app cannot transcribe, so a microphone-shaped button is
              the one thing that must not be in the corner of the box:

                > "we also might don't need this mic button until we don't have
                > a proper feature for transcription… otherwise it will not come
                > here."

              Off therefore means gone. `useControlOffer` still answers the
              question — this reads its answer rather than the feature id, so
              the microphone cannot fall out of step with whatever else the
              registry gates.
            */}
            {voiceOffer === null && <DictateButton onFocusComposer={focusBox} disabled={off} />}
            <button
              type="button"
              className="cc-send"
              onClick={send}
              disabled={off || empty}
              aria-label="Send"
              title="Send — Enter sends, Shift+Enter starts a new line"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
                <path d="M4 12h15M13 6l6 6-6 6" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
