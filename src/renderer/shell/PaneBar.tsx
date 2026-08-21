import type { ReactNode } from 'react'
import type { ProviderId, SessionStatus } from '@shared/types'
import { StatusDot } from '../components/StatusDot'
import { useSessionBinding } from '../browser/binding-view'
import { AccountChip } from './AccountChip'
import type { ChromeSession } from './agent-presence'
import { FolderTitle } from './FolderChip'
import { SessionTitle } from './SessionTitle'

/**
 * A **guest** pane's own chrome, above that pane's own content.
 *
 * ## The bug this exists for
 *
 * The window had a single bar describing a single session, and the window can
 * show two. Asad, 2026-08-17:
 *
 *   > *"In a split view, it can be from two different projects, two different
 *   > folders, two different accounts. That's why the accounts and other things
 *   > related to it should not be always above — above the view, not inside the
 *   > view. So they can be different, and it can still be showing something for
 *   > one of them or maybe the other one. So it can be a problem, it can be a
 *   > confusion — which one it is showing right now."*
 *
 * That is a correctness complaint and not a preference. The account chip states
 * a fact about **a session** — which config directory the agent process was
 * handed at spawn — and it was drawn once, for a **window**, spanning both
 * halves of a split. Whatever it said was wrong for at least one pane, and
 * there was nothing on screen to say which one it was right for. The same is
 * true of the folder, which is the pty's `cwd` and is fixed for that one
 * process, and of the session's name.
 *
 * ## Which panes get one, and why it is not all of them
 *
 * For a day it was all of them: every pane grew this bar, the window's toolbar
 * was emptied of any heading, and the secondary panes were boxed. Asad, on
 * seeing that:
 *
 *   > *"The reason why we kept the main section in its place, like on surface,
 *   > is because we did not want to move its drop-downs, its name and
 *   > everything — we wanted to keep it in the top bar, under the pills of
 *   > windows, so it feels like a main session and the other ones like
 *   > secondary sessions. If we make both exactly the same placement — if the
 *   > name and the account come down — then there is no reason to keep one of
 *   > them in a box, because all the sizes, everything, is the same."*
 *
 * He is right, and the argument is sharper than the one it corrects. The
 * per-session reasoning above holds for a **guest**: a pane opened beside the
 * one you were working in has no other place on screen to state its cwd and its
 * login, so it states them here. It does not hold for the **host**, because the
 * window's toolbar is not ambiguous about which pane it means — the host is the
 * pane the window is about, it is the one drawn flush with no box, and the bar
 * sits directly on top of it. Bringing its identity down here would make the
 * two panes the same shape, at the same size, saying the same things in the
 * same place, and at that point the box around one of them is decoration.
 *
 * So `App.tsx` renders this for `!primary` only, and the host's name, folder
 * and account stay exactly where they sat before anybody split anything. See
 * `WindowToolbar`.
 *
 * ## Not the same bar twice
 *
 * With one pane on screen there is no guest and this component is not used:
 * `App.tsx` renders the ordinary toolbar exactly as before. Rendering both for
 * one session would put its name, folder and account on screen twice, forty
 * pixels apart.
 *
 * ## What is deliberately not here
 *
 * The Terminal/Chat/Split switch. Two of its three segments are per session and
 * the third is per window, but the control is one control, and the one thing it
 * has to be able to do while a window is split is get you *out* of the split —
 * which is a window-level act. A copy in every pane would be three controls
 * offering the same window-level segment, and a Chat segment in a pane would be
 * promising a conversation view the split renderer does not draw.
 *
 * The account chip is given no `session`, and that is on purpose rather than an
 * omission: with one, `chipMode` draws Run Claude at a plain shell and draws
 * *nothing at all* for the few hundred milliseconds before the agent's presence
 * has been read. A bar whose entire job is to say which account this pane is
 * running as must not begin life by saying nothing. The window's bar has always
 * passed no session for the same reason; this is that behaviour relocated, not
 * a new one.
 */

/** What a pane is showing, as much of it as its bar has to state. */
export type PaneSubject =
  | {
      kind: 'session'
      /** The pty, and what the heading renames. */
      id: string
      title: string
      status: SessionStatus
      /** The folder the pty was spawned in. Null for a session with no project. */
      folder: string | null
      /** The account it is actually running as, when the main process named one. */
      account: { id: string; name: string; provider?: ProviderId } | null
      /** The agent a session started from this pane's chip would run. */
      provider?: ProviderId
      onPickAccount(accountId: string, runAs?: ProviderId): void
      /**
       * Run *this* pane's session as another account, in this pane.
       *
       * The guest half of the fix reported against the window's own chip:
       * *"when I change account from the dropdown it starts a new session with
       * that account, instead of changing it in the same session."* A pane is
       * where two sessions on two accounts are most likely to be side by side,
       * so it is the one place the old behaviour would have been hardest to
       * notice going wrong — a third session appearing in the rail while the
       * pane you pressed in carried on unchanged.
       *
       * Optional, like every other switch entry point, and for the same reason:
       * a caller that has not built the other half must get the old behaviour
       * rather than a row that calls nothing.
       */
      onSwitchAccount?(sessionId: string, accountId: string): void
      /**
       * What is actually running in this pane, for the chip's own questions.
       *
       * Only "is there an agent in it" and "has it ended" — see `ChromeSession`.
       * It is a separate field from `id` and `status` above because those two are
       * about the *heading*, and a status of `idle` says nothing about whether a
       * CLI is at the prompt or a bare shell is.
       */
      chrome?: ChromeSession | null
      onManageAccounts(): void
    }
  /**
   * A session that is not on this computer — one on a paired machine, or a
   * terminal on a server.
   *
   *   > *"I want exactly same identical view of every type of session inside,
   *   > including remote session, including local session"*
   *
   * The same status dot, the same name, the same controls slot beside it. Two
   * differences, and each is a fact rather than a withholding:
   *
   *  - **`where`** is printed, because which computer a pane is running on is
   *    the one thing about it that a reader cannot work out from anything else
   *    on screen, and a pane is exactly where two machines end up side by side.
   *  - **No account chip, no folder chip and no browser binding.** Each of those
   *    three is a *control* that acts on this Mac: the account menu switches a
   *    local pty's login, the folder tooltip names a path in this filesystem,
   *    and the bind menu attaches a window in this app to a local session. Drawn
   *    over a session on somebody's server they would be three controls that do
   *    the wrong thing quietly, which is the one outcome this pass is removing.
   *    The window's own bar carries the account for the session it names.
   *
   * The heading is not renameable either, and that is the same fact: the name
   * belongs to the far machine, which is where it is edited.
   */
  | { kind: 'elsewhere'; title: string; where: string; status: SessionStatus }
  /**
   * A browser page.
   *
   * It has no account, no model and no effort — there is no agent and no config
   * directory — so its bar says the one true thing there is to say about it,
   * which is what the page is called. Borrowing the session bar and leaving the
   * chips blank would read as a session whose account failed to load.
   */
  | { kind: 'page'; title: string }
  /** A pane the user made and has not filled. */
  | { kind: 'empty' }

interface Props {
  paneId: string
  subject: PaneSubject
  /** The pane the sidebar fills and the keyboard reaches. */
  focused: boolean
  /**
   * The slot the running session's controls will be composed into: model,
   * effort, and the usage window.
   *
   * Empty today, and deliberately empty rather than filled with a picker that
   * does not change anything — two other passes are building the mechanisms
   * (a pty write path so choosing a model reaches the running agent, and the
   * usage state over IPC), and this is the place they land. It is rendered even
   * while nothing is in it so that the follow-up is composition rather than
   * another layout pass through every one of these files.
   *
   * Only a session gets one. A page has nothing to put in it.
   */
  controls?: ReactNode
  onClose(paneId: string): void
}

const PANE_CLOSE = 'M6.5 6.5l11 11M17.5 6.5l-11 11'

/** The disclosure mark, in the same 24×24 grid as everything else here. */
const CHEVRON = 'M8 10l4 4 4-4'

/**
 * Attach a browser window to this pane's session, or detach one.
 *
 * ## Why the control is here and not on the chip
 *
 * `BindChip` states a fact and is two characters wide; a 20px chip is not a
 * control surface, and putting the gesture on it would mean the only way to
 * *attach* a first window is to press something that is not drawn until one is
 * already attached. This bar is per-session chrome with room, which is the same
 * reason the account chip and the folder live here.
 *
 * ## Why the menu is native
 *
 * A `WebContentsView` composites above the entire renderer — the whole subject
 * of `overlay-watch.ts`, and the reason `SendToAgent` uses a plain `<select>`.
 * An HTML menu would therefore be invisible in exactly the situation this
 * feature exists for: a browser page on screen, being attached to a session. So
 * the menu is built in the main process, the same way `link-open.ts`'s
 * right-click menu is, and this button's whole job is to ask for it.
 *
 * ## It is never a dead control
 *
 * With nothing attached it reads `Attach browser` and still opens a menu, which
 * offers `New window, attached` and says `No browser windows are open.` when
 * there are none. There is no state in which pressing it does nothing.
 */
function AttachBrowser({ sessionId }: { sessionId: string }) {
  const binding = useSessionBinding(sessionId)
  const slots = binding?.windows.map((window) => `B${window.n}`) ?? []
  // What the button says is what is true right now, and the tooltip says what
  // pressing it does — two different sentences, because a label reading
  // "B1 B2" would otherwise be a control that never explains itself.
  const label = slots.length > 0 ? slots.join(' ') : 'Attach browser'
  const tooltip =
    slots.length > 0
      ? `${slots.join(', ')} attached to this session. Attach or detach a browser window.`
      : 'No browser window attached. Attach one, or open a new one attached to this session.'

  return (
    <button
      type="button"
      className="bind-button"
      data-attached={slots.length > 0 || undefined}
      data-bind={binding ? (binding.colour % 4) + 1 : undefined}
      title={tooltip}
      aria-label={tooltip}
      onClick={() => {
        // Not awaited: the answer is only whether a menu was popped, and the
        // menu itself is what the person is waiting for.
        void window.deck.showBrowserBindMenu({ sessionId })
      }}
    >
      <span className="bind-button-label">{label}</span>
      <svg
        width="11"
        height="11"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        <path d={CHEVRON} />
      </svg>
    </button>
  )
}

/** A page, in the same 24×24 grid everything else in this window is drawn on. */
const GLOBE =
  'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm0 0c-2.5 2.3-3.8 5.3-3.8 9s1.3 6.7 3.8 9m0-18c2.5 2.3 3.8 5.3 3.8 9s-1.3 6.7-3.8 9M3.4 9h17.2M3.4 15h17.2'

export function PaneBar({ paneId, subject, focused, controls, onClose }: Props) {
  return (
    <header
      className="pane-cell-head"
      data-empty={subject.kind === 'empty' || undefined}
      /*
       * Which pane the keyboard and the sidebar are pointed at.
       *
       * Read here as well as on the pane itself, because dimming a pane's
       * *identity* is the one focus mark every pane can wear — the guest boxes
       * also ring their own border, and the host, which is flush with the
       * window by design, has no border to ring and dims its heading in the
       * window's toolbar instead. So an unfocused bar is drawn back and a
       * focused one is at full strength, and the toolbar does the same thing at
       * the same weight; see `.toolbar-heading[data-focused]` in `shell.css`.
       */
      data-focused={focused}
    >
      {subject.kind === 'session' && (
        <>
          <StatusDot status={subject.status} />
          {/* The same renameable heading the window's bar carries, at the
              pane's scale. Double-click and F2 both still open it — see
              `SessionTitle`, and note that this one never had to give up a
              drag region for the gesture, because a pane is not the window's
              title bar. */}
          <SessionTitle title={subject.title} sessionId={subject.id} scale="pane" />
          {subject.folder && (
            /* Where, and who — the same pair, in the same order, with the same
               separator the window's bar uses, because they are the same two
               statements about the same session. `.toolbar-chips` is shared
               rather than copied: two spellings of one row is how the two
               would come to disagree about spacing. */
            <div className="toolbar-chips">
              <FolderTitle path={subject.folder} />
              <span className="toolbar-chip-sep" aria-hidden="true" />
              <AccountChip
                current={subject.account}
                projectPath={subject.folder}
                provider={subject.provider}
                session={subject.chrome ?? null}
                onPick={subject.onPickAccount}
                onSwitchAccount={subject.onSwitchAccount}
                onManage={subject.onManageAccounts}
              />
            </div>
          )}
          {/*
            Outside `toolbar-chips` on purpose: that row is the pair "where, and
            who", both of which are facts about the pty and both of which are
            absent for a session with no project. Where this session's links open
            is a third thing, it is true of a session with no folder as well, and
            it is a control rather than a caption.
          */}
          <AttachBrowser sessionId={subject.id} />
        </>
      )}

      {subject.kind === 'elsewhere' && (
        <>
          <StatusDot status={subject.status} />
          {/* A plain span rather than `SessionTitle`: that component's whole
              point is that double-click and F2 open a rename, and a rename here
              would edit nothing — the name is the far machine's. Same class, so
              it is the same text at the same weight in the same place. */}
          <span className="pane-cell-title">{subject.title}</span>
          <span className="pane-cell-where">{subject.where}</span>
        </>
      )}

      {subject.kind === 'page' && (
        <>
          <svg
            className="pane-cell-kind"
            width="13"
            height="13"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d={GLOBE} />
          </svg>
          <span className="pane-cell-title">{subject.title}</span>
        </>
      )}

      {subject.kind === 'empty' && (
        <span className="pane-cell-title pane-cell-waiting">Empty pane</span>
      )}

      {/* Pushes the close button to the far edge whatever is on the left, and
          holds the session's controls when there are any. A page and an empty
          pane get the spacer without the slot: there is nothing about either of
          them that a model or an effort could describe. */}
      {subject.kind === 'session' || subject.kind === 'elsewhere' ? (
        <div className="pane-cell-slot" data-slot="session-controls">
          {controls}
        </div>
      ) : (
        <div className="pane-cell-slot" aria-hidden="true" />
      )}

      <button
        type="button"
        className="pane-cell-close"
        aria-label="Close this pane"
        // Closing the second-to-last pane puts the window back to a single
        // session rather than leaving a "split view" with one pane in it, which
        // is the ordinary view wearing a divider.
        title="Close this pane"
        onClick={() => onClose(paneId)}
      >
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <path d={PANE_CLOSE} />
        </svg>
      </button>
    </header>
  )
}
