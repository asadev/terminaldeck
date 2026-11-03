import { useEffect, useState } from 'react'
import { Button } from '../settings/controls'
import { endedNotice, type EndActionId, type SessionEnd } from './session-end'
import './SessionEnded.css'

/**
 * What is drawn over a session's last frame once that frame is a photograph.
 *
 * ## Where it sits, and why there
 *
 * At the **bottom** of the pane, over the composer. That placement is the whole
 * point rather than a layout preference: the four things the recording caught
 * still claiming a running agent — the composer box, its `Try "fix typecheck
 * errors"` placeholder, the `xhigh · /effort` chip at its right and the
 * `⏵⏵ bypass permissions on (shift+tab to cycle) · ⌥ for agents` footer under
 * it — are one block of the CLI's own drawing, in one place, at the bottom of
 * its output. A card there covers the invitation and stands where the person's
 * eye and cursor already are.
 *
 * It does not cover the transcript. Everything the session printed stays
 * readable and selectable above the card, which is the reason
 * `serverShellEnded` gives for leaving the tab open in the first place:
 * *"Removing it here instead would take the last thing the shell printed off
 * the screen at the exact moment somebody wants to read it."*
 *
 * ## Why the frame behind it is dimmed as well
 *
 * Because the CLI's footer is taller than any card should be, and a composer is
 * not the only thing on that screen that reads as live — a spinner mid-frame, a
 * half-drawn tool call, a `esc to interrupt` line all say *this is happening*.
 * Dimming the surface says *this is history* about every part of it at once,
 * including the parts this app cannot name. The pane sets `data-ended`; the
 * fade is one rule in `SessionEnded.css` against `.terminal-surface`.
 *
 * ## Why it is a card and not a `disabled` state
 *
 *   > *"What replaces it should say what happened and what the person can do
 *   > (reconnect? reopen? it is gone?), rather than simply disabling controls
 *   > with no explanation."*
 *
 * So every notice carries three things and the third is the one that is usually
 * missing: what happened, whether the work is still alive somewhere, and the
 * one press that does something about it. `session-end.ts` holds all three,
 * per end, which is what stops this component and the bar above it inventing
 * two different accounts of one event.
 */
export function SessionEnded({
  end,
  onAct,
}: {
  end: SessionEnd
  /**
   * The press, or null when this pane has nowhere to send it.
   *
   * Null draws the card **without** the button rather than with a dead one —
   * the rule the account chip states next door: a control that cannot act is
   * removed, not shown inert. The sentence is the substance and it stays.
   */
  onAct: ((action: EndActionId) => void) | null
}) {
  const notice = endedNotice(end)
  const countdown = useCountdown(notice.retryAt)
  /*
   * Narrowed once, here, rather than asserted at the press.
   *
   * `notice.action` and `onAct` are two independent nullables and the button
   * needs both — the notice has something to offer *and* this pane has
   * somewhere to send it. Pulling them apart in the JSX below meant a non-null
   * assertion inside the click handler, which is the one place a wrong
   * assumption would surface as a crash rather than as a missing button.
   */
  const press = notice.action !== null && onAct !== null ? { ...notice.action, act: onAct } : null
  return (
    <div className="session-ended" role="status" aria-live="polite">
      <div className="session-ended-card" data-alive={notice.alive || undefined}>
        <div className="session-ended-said">
          <p className="session-ended-title">{notice.title}</p>
          <p className="session-ended-detail">
            {notice.detail}
            {countdown !== null ? ` Next try ${countdown}.` : ''}
          </p>
        </div>
        {press !== null ? (
          <div className="session-ended-do">
            <Button tone="primary" onClick={() => press.act(press.id)}>
              {press.label}
            </Button>
          </div>
        ) : null}
      </div>
    </div>
  )
}

/**
 * "in 4s", refreshed while it counts, or null when nothing is scheduled.
 *
 * ## Why this is the one timer in the file
 *
 * The standing rule here is events, not polling, and this does not break it:
 * nothing is being *asked* of anything: the retry time already arrived, once,
 * on the link's own state push. This turns one number into a sentence that
 * keeps being true, which is the difference between a countdown and a poll.
 *
 * It stops the moment the deadline passes, so a card that has been on screen
 * for an hour is not holding an interval. `retryAt` changing — every drop
 * publishes a new one — starts a fresh one.
 */
function useCountdown(retryAt: number | null): string | null {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (retryAt === null) return
    setNow(Date.now())
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [retryAt])
  if (retryAt === null) return null
  const left = Math.round((retryAt - now) / 1000)
  if (left <= 0) return 'now'
  return `in ${left}s`
}
