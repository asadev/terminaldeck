import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import { ControlPicker } from './ControlPicker'
import { ControlSection } from './ControlSection'
import {
  controlName,
  MENU_CONTROLS,
  optionsFor,
  PRIMARY_CONTROLS,
  reachOf,
  unsupportedProviderNote,
  type ControlId,
  type ControlsReading,
} from './catalog'
import type { ProviderId } from '@shared/types'
import './AgentControls.css'

/**
 * The agent's controls, living inside the composer.
 *
 * Everything here goes to the agent the same way a typed message does — as
 * keystrokes into the session's PTY. There is no second channel, so a control
 * exists only where a person sitting at that terminal could have done the same
 * thing:
 *
 *   Model       `/model <alias>`
 *   Effort      `/effort <level>`
 *   Fast mode   `/fast on|off`
 *   Permission  shift+tab, one press at a time, footer re-read after each
 *
 * The values are read back from the session's own screen, its transcript or the
 * CLI's settings file — never assumed. When nothing could be read the control
 * says so rather than guessing: a row of confident defaults that were never
 * verified would be worse than no row at all.
 *
 * Three of the four resolve on any machine. Fast mode structurally cannot until
 * the session mentions it — see `unreadLabel` in `catalog.ts` for why — so it
 * says "Not reported" and its panel explains the difference, instead of showing
 * the same "Unknown" that everywhere else here means "something failed".
 *
 * ## Where each of them is, and why each is in exactly one place
 *
 * This was a strip of four pickers and two lines of prose under the chat box,
 * and it read as clutter rather than as control — the complaint that started
 * the redesign was, exactly, "a lot of options under the chat box". The pass
 * that answered it moved two pickers onto the box and put the other two behind
 * a button labelled "More", and the report that came back was the opposite
 * complaint: *"all the options you have actually removed"*. The pass after
 * *that* made the panel a complete inventory of all four, and drew the third
 * report, watching the app: *"options is having all of the things that we
 * already have here and there. So let's keep everything separate rather than
 * having everything on one page like on options."*
 *
 * So: one home per control. `PRIMARY_CONTROLS` are chips on the row and are not
 * repeated in the panel; `MENU_CONTROLS` are the ones with no chip, and the
 * panel is where they live. `catalog.ts` carries the full account of the three
 * reports and of why this cannot slide back into the "More" failure — the short
 * version is that the button's hover label is built out of `MENU_CONTROLS`, so
 * the panel's contents are named on screen, which is the one thing "More" never
 * did.
 *
 * The two lists are drawn under the *same* condition (`usable`), which is what
 * makes "one home" safe rather than merely tidy: there is no state of this
 * component in which the chips are withheld and the panel is not, so a control
 * cannot lose its only home to a branch.
 *
 * The panel is also where the descriptions finally have room to be sentences,
 * which is the half a chip cannot do at any width.
 */

export interface AgentControlsBridge {
  readAgentControls(request: { sessionId?: string; cwd?: string; provider?: string }): Promise<unknown>
  applyAgentControl(request: {
    sessionId: string
    cwd?: string
    control: ControlId
    value: string
    /**
     * What is running in the session, so the main process can refuse a CLI it
     * has no verified way of driving instead of typing Claude's commands at it.
     * `undefined` is a real answer — see `refuseByProvider` in
     * `src/main/agent-controls.ts` — and is resolved there from the screen.
     */
    provider?: string
  }): Promise<unknown>
}

interface Props {
  /** Absent until a session is focused; the controls then explain themselves. */
  sessionId?: string
  cwd?: string | null
  /**
   * What is running in the session. `shell` withdraws every picker.
   *
   * Model, effort, fast mode and permission mode are an agent CLI's vocabulary.
   * A `/bin/zsh -l` has none of them — but the reader behind these values falls
   * back to the CLI's settings file when it cannot read the session's screen,
   * so a plain shell was confidently reporting `Model  Opus 5` and a permission
   * mode of `Unknown`, neither of which is a fact about the terminal on screen.
   * The provider is the one thing that settles it, and the session record has
   * carried it since the day it was created.
   */
  provider?: ProviderId
  /**
   * A read-only block to show at the foot of the panel. `ChatView` passes the
   * usage strip, which used to be a third row under the composer.
   *
   * It lives here rather than in `ChatComposer` so the box has one fold and not
   * two: "what this session may do" and "what it has cost" are the same kind of
   * thing to a reader — reference, wanted occasionally, never while typing.
   */
  extra?: ReactNode
}

interface ApplyResult {
  ok: boolean
  message: string
  reading: ControlsReading['model']
}

/**
 * How long the session has to stop printing before the controls re-read.
 *
 * Not a poll — a quiet-period after an event. Every value here is scraped off
 * the session's own screen, so it cannot change without the pty producing
 * output, and `session:data` says exactly when that happens. What it does *not*
 * say is when the CLI has finished repainting: reading in the middle of a
 * streaming reply gets a half-drawn footer. So the read waits out a pause,
 * which during a long answer means one read when it ends rather than one every
 * four seconds all the way through it.
 */
const SETTLE_MS = 400

/**
 * How long a successful change stays on screen.
 *
 * A confirmation is worth showing and not worth keeping: the tick in the menu
 * and the value on the button both say the same thing permanently, so leaving
 * "Set model to Sonnet 5" under the text box adds a line to the very surface
 * this redesign exists to quieten. Failures do *not* expire — an error that
 * cleans up after itself is an error nobody read.
 */
const CONFIRM_MS = 4000

/**
 * The pty output channel, read off `window.deck` as loosely as the rest.
 *
 * Optional: a build without it falls back to the read this does on mount,
 * which is still the truth, just not a live one.
 */
interface SessionDataEvents {
  onSessionData?: (cb: (id: string, data: string) => void) => () => void
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asReading(value: unknown): ControlsReading['model'] {
  if (!isRecord(value)) return { value: null, label: null, source: null }
  return {
    value: typeof value.value === 'string' ? value.value : null,
    label: typeof value.label === 'string' ? value.label : null,
    source:
      value.source === 'screen' || value.source === 'transcript' || value.source === 'settings' || value.source === 'env'
        ? value.source
        : null,
    unavailableReason: typeof value.unavailableReason === 'string' ? value.unavailableReason : undefined,
  }
}

function asReadings(value: unknown): ControlsReading | null {
  if (!isRecord(value)) return null
  return {
    model: asReading(value.model),
    effort: asReading(value.effort),
    fast: asReading(value.fast),
    permission: asReading(value.permission),
    live: value.live === true,
  }
}

function asApplyResult(value: unknown): ApplyResult {
  if (!isRecord(value)) return { ok: false, message: 'No answer from the session.', reading: asReading(null) }
  return {
    ok: value.ok === true,
    message: typeof value.message === 'string' ? value.message : '',
    reading: asReading(value.reading),
  }
}

/**
 * The preload bridge, if there is one.
 *
 * `globalThis` rather than `window` because `ChatView` is rendered to a string
 * in its own tests, where there is no `window` at all — reading it during
 * render threw and took the whole view down with it.
 */
function deckBridge(): Partial<AgentControlsBridge> | undefined {
  return (globalThis as unknown as { deck?: Partial<AgentControlsBridge> }).deck
}

export function AgentControls({ sessionId, cwd, provider, extra }: Props) {
  const shell = provider === 'shell'
  /**
   * An agent CLI this app has no established way of driving.
   *
   * Everything these pickers do is one Claude Code command or another, and the
   * values they show are read back out of Claude Code's own screen and Claude
   * Code's own settings file. Neither half generalises. Offering the same five
   * model aliases on a Codex or Gemini session would be a row of buttons that
   * type `/model sonnet` at a CLI nobody has checked understands it — the exact
   * dead control this composer keeps being audited for, dressed up as support.
   *
   * `undefined` is deliberately not in this set. It means an agent is running
   * inside a session this app launched as a shell, and the app never saw which
   * one — a question the *screen* answers, in the main process, because the
   * markers it matches are Claude Code's. `refuseByProvider` in
   * `src/main/agent-controls.ts` is where that is decided and is the
   * authoritative refusal; this is the same judgement made early enough to
   * withdraw the buttons rather than let them be pressed into an error.
   */
  const foreignNote = unsupportedProviderNote(provider)
  const foreign = foreignNote !== null
  const [readings, setReadings] = useState<ControlsReading | null>(null)
  const [busy, setBusy] = useState<ControlId | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const [open, setOpen] = useState(false)
  const alive = useRef(true)
  const rootRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const bridge = deckBridge()
  // Derived, not state: an effect that flips this would render one frame of
  // working controls before admitting the bridge is missing, and would never run
  // at all when the view is rendered to a string.
  const wired = typeof bridge?.readAgentControls === 'function' && !shell && !foreign
  const usable = wired && sessionId !== undefined

  const refresh = useCallback(async (): Promise<void> => {
    if (!sessionId || typeof bridge?.readAgentControls !== 'function') return
    try {
      const answer = await bridge.readAgentControls({ sessionId, cwd: cwd ?? undefined, provider })
      if (!alive.current) return
      const parsed = asReadings(answer)
      if (parsed) setReadings(parsed)
    } catch {
      // A read that fails leaves the previous values alone; they are still the
      // last thing that was genuinely read, and blanking them would be a
      // regression in honesty, not an improvement.
    }
  }, [bridge, sessionId, cwd, provider])

  useEffect(() => {
    if (!wired) return
    void refresh()
  }, [wired, refresh])

  /**
   * Re-read when the session prints something, not on a clock.
   *
   * The permission footer changes when the user presses shift+tab in the
   * terminal view, and the model changes when they type `/model` there. Chat
   * mode is a different view of the same session, so this cannot trust what it
   * last set — but neither of those can happen without the pty echoing it, and
   * `session:data` carries that. The old 4-second re-read asked 21,600 times a
   * day for a value that changes a handful of times; this asks once per pause in
   * the output, and none at all while the session is idle.
   */
  useEffect(() => {
    if (!wired || !sessionId) return
    const deck = (globalThis as unknown as { deck?: SessionDataEvents }).deck
    if (typeof deck?.onSessionData !== 'function') return

    let settle: ReturnType<typeof setTimeout> | null = null
    const off = deck.onSessionData((id) => {
      if (id !== sessionId) return
      if (settle !== null) clearTimeout(settle)
      settle = setTimeout(() => {
        settle = null
        void refresh()
      }, SETTLE_MS)
    })

    return () => {
      if (settle !== null) clearTimeout(settle)
      off()
    }
  }, [wired, sessionId, refresh])

  // A confirmation expires; a failure does not. See CONFIRM_MS.
  useEffect(() => {
    if (notice === null || !notice.ok) return
    const timer = setTimeout(() => setNotice(null), CONFIRM_MS)
    return () => clearTimeout(timer)
  }, [notice])

  /*
   * The window's one-menu-at-a-time rule — see `one-menu.ts`.
   *
   * This panel is the reason the rule exists. Its outside-click test below is
   * measured against `rootRef`, which is `.agent-controls` — and the Model and
   * Permission chips are inside that element, one row above the panel. So
   * pressing a chip while the panel was open was a click *inside* the panel's
   * own root, the panel stayed put, and the chip's menu opened across it. No
   * amount of care in the listener fixes that, because the listener is
   * answering the right question about the wrong boundary.
   */
  const shut = useCallback(() => setOpen(false), [])
  useOneMenu(open, shut)

  // Escape closes the panel from anywhere inside it, and a click outside
  // dismisses. Both are needed: a panel that only closes on Escape traps the
  // pointer, and one that only closes on click ignores the keyboard. Registered
  // only while it is open, so a shut panel costs the composer nothing.
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        setOpen(false)
      }
    }
    const onDown = (event: MouseEvent): void => {
      const host = rootRef.current
      if (host && event.target instanceof Node && !host.contains(event.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open])

  const pick = useCallback(
    async (control: ControlId, value: string): Promise<void> => {
      if (!sessionId || typeof bridge?.applyAgentControl !== 'function') return
      setBusy(control)
      setNotice(null)
      try {
        const answer = asApplyResult(
          await bridge.applyAgentControl({ sessionId, cwd: cwd ?? undefined, control, value, provider }),
        )
        if (!alive.current) return
        setNotice({ ok: answer.ok, text: answer.message })
        /*
         * The reading comes from the answer, and the answer's reading is one
         * the main process re-read off the session after the change settled —
         * never the value that was clicked. That distinction is the whole
         * feature: a picker that ticks the row you pressed is showing your
         * intention, and this app already had that bug once. The `refresh` in
         * the `finally` then asks again from scratch, so even a wrong optimistic
         * value would survive only until the next screen read.
         */
        setReadings((was) => (was ? { ...was, [control]: answer.reading } : was))
      } catch (error) {
        if (alive.current) setNotice({ ok: false, text: error instanceof Error ? error.message : 'The change failed.' })
      } finally {
        if (alive.current) setBusy(null)
        void refresh()
      }
    },
    [bridge, sessionId, cwd, provider, refresh],
  )

  /**
   * Why nothing can be changed, or null when it can.
   *
   * The second sentence is deliberately not "open a session": the caller
   * resolves the session by project folder, so that state is reached both with
   * none open and with two open in the same folder — and telling someone
   * staring at a running session to open one is its own small lie.
   */
  const unusable =
    shell
      ? 'This session is a shell, not an agent. Model, effort, fast mode and permission modes belong to an agent CLI — there is nothing here to set them on.'
      : foreignNote !== null
        ? // Named rather than lumped in with the shell, because the reason is a
          // different one and the difference is the honest part: a shell has no
          // model to set, whereas this session certainly has one and this app
          // has simply not established how to change it from the outside. The
          // sentence lives in `catalog.ts` so it can be pinned without a DOM —
          // this panel is shut in a static render, which is the only kind this
          // project's tests can produce.
          foreignNote
        : wired
          ? sessionId === undefined
            ? 'These type into a running session, and there is no single live session for this folder to type into.'
            : null
          : 'Model, effort and permission controls are not wired into this build.'

  // Fast mode is the one control an account can be barred from, and the CLI is
  // the only thing that knows. Once it has said so, the reason is shown in place
  // of the options rather than leaving a button that argues with the CLI every
  // time it is pressed.
  const blockedReason = (control: ControlId): string | null =>
    control === 'fast' ? (readings?.fast.unavailableReason ?? null) : null

  /**
   * The hover label on the Options button, written out of the panel's own
   * contents.
   *
   * Hand-typing it is how a tooltip comes to advertise a control that was
   * removed six months earlier — and this composer has already lost controls
   * once. Building the sentence from `MENU_CONTROLS` means the two cannot
   * disagree: delete a control and its name leaves the sentence with it.
   *
   * It carries more weight now than when it was written. The panel no longer
   * repeats the chips beside it, so this sentence is the *only* place on screen
   * that names what is behind the button — which is exactly what a button
   * labelled "More" did not have, and exactly why "More" read as a deletion.
   * Replacing this with a fixed string would recreate that failure with no
   * other change.
   *
   * Sentence case, so it reads as prose rather than as a row of proper nouns:
   * only the first name keeps its capital.
   */
  const optionsLabel = ((): string => {
    const parts = usable ? MENU_CONTROLS.map(controlName) : []
    const named =
      parts.length === 0
        ? ''
        : parts
            .map((name, index) => (index === 0 ? name : name.toLowerCase()))
            .reduce((sentence, name, index) =>
              index === parts.length - 1 ? `${sentence} and ${name}` : `${sentence}, ${name}`,
            )
    if (named === '') return 'What this session has used so far'
    return extra ? `${named}, and what this session has used` : named
  })()

  return (
    <div className="agent-controls" ref={rootRef}>
      {notice ? (
        <p className={notice.ok ? 'ac-notice' : 'ac-notice ac-notice-bad'} role="status">
          {notice.text}
        </p>
      ) : usable && readings && !readings.live ? (
        <p className="ac-notice ac-notice-bad" role="status">
          This session is not running, so nothing can be changed in it.
        </p>
      ) : null}

      <div className="ac-row">
        {usable
          ? PRIMARY_CONTROLS.map((id) => (
              <ControlPicker
                key={id}
                control={id}
                name={controlName(id)}
                reading={readings?.[id]}
                options={optionsFor(id)}
                reach={reachOf(id)}
                busy={busy === id}
                disabled={busy !== null && busy !== id}
                blocked={blockedReason(id)}
                onPick={(value) => void pick(id, value)}
              />
            ))
          : null}

        {/* One affordance for the whole list, and it names the list rather than
            making a word like "More" carry it. The hover label is built from
            the control names themselves, so a control that is renamed is
            renamed here too and one that is deleted takes its own name out of
            the sentence — the tooltip cannot go on advertising something the
            panel no longer holds.

            Not drawn when there is nothing behind it. On a plain shell every
            picker is withdrawn and the usage strip is withheld, so the panel
            could only ever open onto a paragraph explaining its own emptiness —
            "Model, effort, fast mode and permission modes belong to an agent
            CLI, there is nothing here to set them on" — which is the dead
            control the brief forbids, and a near-copy of the empty state
            already on screen in the middle of the same pane. A control earns
            its place by having something behind it. */}
        {(usable || extra) && (
        <button
          type="button"
          className="cc-chip ac-open"
          aria-haspopup="dialog"
          aria-expanded={open}
          title={optionsLabel}
          onClick={() => setOpen((was) => !was)}
        >
          Options
          <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
            <path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
        </button>
        )}
      </div>

      {open ? (
        <div className="ac-sheet scroll-fade" role="dialog" aria-label="Session options">
          {unusable ? (
            <p className="ac-sheet-note">{unusable}</p>
          ) : (
            MENU_CONTROLS.map((id) => (
              <ControlSection
                key={id}
                control={id}
                reading={readings?.[id]}
                options={optionsFor(id)}
                reach={reachOf(id)}
                busy={busy === id}
                disabled={busy !== null && busy !== id}
                blocked={blockedReason(id)}
                onPick={(value) => void pick(id, value)}
              />
            ))
          )}

          {extra ? (
            <section className="ac-section">
              <h4 className="ac-section-name">This session</h4>
              <p className="ac-section-desc">How many tokens it has used, and how full the context window is.</p>
              {extra}
            </section>
          ) : null}

          {unusable ? null : (
            <p className="ac-sheet-foot">Every change here is typed into the session, exactly as you would type it.</p>
          )}
        </div>
      ) : null}
    </div>
  )
}
