import { useCallback, useEffect, useRef, useState } from 'react'
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
  browseStart,
  bringInRefusal,
  bringInside,
  pasteAttachment,
  picksFromDrop,
  resolveOutsideBridge,
  sessionBoundary,
  splitByBoundary,
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
 * One box, tall enough to look like somewhere you write a paragraph, and one
 * row under the text holding three things: the plus, the microphone and send.
 * Nothing else. The plus carries a word ("Add" for an agent, "Path" for a
 * shell); the two glyphs that stay glyphs are the pair every chat app in the
 * world draws in that corner, and both say what they are on hover.
 *
 * ## What used to be on that row, and why removing it is not the old mistake
 *
 * Model, permission mode and an Options panel holding effort, fast mode and a
 * usage readout. They are gone from here, and this is the *third* time this row
 * has been re-cut, so the distinction matters:
 *
 *   > *"Options is showing the same options that we already have here… since we
 *   > have it on top we actually don't need them here. Let's keep them only on
 *   > top and let's not keep them here — remove them from the chat box side
 *   > completely, only keep the maybe add files or something."*
 *
 * The first two re-cuts *hid* controls — behind a button called "More", and by
 * deleting the attach menu from shell sessions — and both came back as "you
 * removed everything", because a control that is hidden is a control that is
 * gone. This one moves nothing and hides nothing: every one of them is drawn on
 * the window's own bar by `shell/SessionControls.tsx`, at the top of the same
 * pane, on *every* session — including the ones drawn as a terminal, which have
 * no composer on screen at all and therefore never had these controls. That is
 * why the composer's copies were the redundant pair rather than the only pair.
 *
 * Permission mode was the one exception: it had no chip in the bar, only here.
 * It was given one rather than dropped — `CHROME_CONTROLS` in
 * `shell/SessionControls.tsx` — and `chat/controls/one-home.test.ts` fails if
 * any control ends up with no home at all, which is the failure this paragraph
 * exists to prevent from happening quietly.
 *
 * The usage *readout* did not move to the bar, because the bar carries a
 * different reading (the account's five-hour and weekly limits). This session's
 * tokens, cost and context fill are in the session inspector, which is where the
 * rest of "what has this session done" already lives.
 */
export function ChatComposer({
  onSend,
  cwd,
  disabled = false,
  placeholder,
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
   * What a batch of picks becomes, from any of the three routes into this box.
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
   * The paths arrive absolute, from all three routes. They used to arrive
   * relative from the in-app project list and be joined onto the root here,
   * which was never possible for the other two: there is no relative form of
   * `/Users/apple/Desktop/shot.png` from a project in `~/Projects`, and
   * inventing one out of `../../..` would mean something different the moment
   * the session changed directory. With that list deleted, absolute is simply
   * the only form there is.
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
   * The same, for every route — all of which now reach outside the project.
   *
   * ## Why this stopped refusing a file a confined session cannot read
   *
   * Because refusing was a true answer to the wrong question. A session a phone
   * started, or the copilot's own, is held inside a folder by the OS, so a path
   * from `~/Pictures` really would fail at the agent — and this used to say so,
   * in a sentence, and stop. Which meant that dropping a photo on the mode he
   * actually works in did nothing, while dropping the same photo on the terminal
   * *two inches away* transferred it and typed the path. His ask was one
   * sentence: *"any kind of media dropping from your PC to any session should
   * smoothly work."*
   *
   * So a pick the session cannot read is now copied inside it and the copy is
   * attached — `bringInside`, and `main/attach-bring-in.ts` for what lands
   * where. Nothing is refused that can be moved, and the paragraph that used to
   * explain the refusal is gone with it.
   *
   * Order is preserved across the two halves: the picks the session can already
   * read are attached where they lie, the rest are attached at their new paths,
   * and both go in as one batch so three dropped photos make three chips.
   */
  const addPicks = useCallback(
    (picks: readonly OutsidePick[]) => {
      if (picks.length === 0) return
      const { allowed, refused } = splitByBoundary(boundary, picks)
      if (refused.length === 0) {
        add(allowed, 'anywhere')
        return
      }
      const bridge = resolveOutsideBridge(outsideBridge)
      // No session id is the harness and the stand-alone composer, where there
      // is no boundary to be inside of — `boundary.confined` is false there, so
      // this branch is unreachable in practice and is still written down.
      if (bridge === null || !sessionId) {
        if (allowed.length > 0) add(allowed, 'anywhere')
        setNotice(bringInRefusal(refused.length))
        return
      }
      void bringInside(bridge, sessionId, refused).then((brought) => {
        // One `add` for the whole batch. Two would make the second read
        // `attachmentsRef` a render behind the first — the bug this file's
        // `add` was rewritten for.
        add([...allowed, ...brought.picks], 'anywhere')
        // After `add`, which writes its own notice about what the CLI does with
        // an outside folder. A file that could not be moved at all outranks it.
        const line = bringInRefusal(brought.refused)
        if (line !== '') setNotice(line)
      })
    },
    [add, boundary, outsideBridge, sessionId],
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
            {/* The only control on this side of the row, and drawn for a shell
                as well as for an agent — the mode is what differs. See the
                `shell` prop for the regression that rule exists to close. */}
            <AttachMenu
              root={root}
              onAdd={addPicks}
              onNotice={setNotice}
              onClose={focusBox}
              // `root === ''` no longer disables it. The panel is the operating
              // system's, so it has somewhere to open even with no project —
              // and on a confined session that is exactly the case where the
              // folder it *can* read is not the project.
              disabled={off}
              mode={shell ? 'path' : 'mention'}
              // The project, unless this session cannot read the project.
              startIn={browseStart(boundary, root)}
              {...(outsideBridge ? { outsideBridge } : {})}
            />
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
            {/* And it draws nothing at all until a transcription key has been
                saved and proved — see `DictateButton`. `insert` is the same
                appender the attach menu uses, so dictated words land in a
                half-typed sentence the way pasted ones do. */}
            {voiceOffer === null && (
              <DictateButton onInsert={insert} onFocusComposer={focusBox} disabled={off} />
            )}
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
