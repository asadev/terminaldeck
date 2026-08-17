import type { Copilot } from './useCopilot'
import './copilot.css'

/**
 * The one control the copilot's toolbar has that a session's does not.
 *
 * ## Why it exists at all, when the ask was "nothing should be less than that"
 *
 * Nothing here is less; this is the one thing that would otherwise be *missing*.
 * Every ordinary session can be ended from its row in the rail, with the ✕ that
 * asks first when there is work to lose. The copilot has no such row: it is a
 * **singleton**, so the rail gives it a pinned entry with no ＋ that starts a
 * second and no ✕ that ends this one — a second ✕ glyph a few pixels from the
 * session rows, meaning something else, is precisely the confusion `Sidebar.tsx`
 * carries a paragraph about avoiding. And the ✕ on its pill takes the pill off
 * the strip like every other pill's does, which is a placement and not an
 * ending.
 *
 * So without this, the copilot would be the one session in the window that
 * cannot be switched off from anywhere you can see it. It had a Stop on the page
 * it used to have; losing that in the move to a window would be exactly the kind
 * of quiet subtraction this change was asked not to make.
 *
 * ## Why stopping is safe to offer here
 *
 * Because it is reversible, which is the standard the brief set: *"its ✕ must
 * not be able to end it in a way that cannot be restarted."* Stopping ends a
 * pty. The pinned row starts a new one — `ensureCopilot` is idempotent by
 * contract — its folder, its `CLAUDE.md` and its `memory/` are untouched on
 * disk, and Settings → Copilot offers the same pair with the same effect. What
 * is lost is one conversation, which is the same thing that is lost when any
 * session is closed, and which the design already treats as expected: the
 * copilot starts fresh rather than `--continue`, because continuity is `memory/`.
 *
 * Absent rather than disabled while it is not running: there is no process to
 * stop, and a greyed control teaches that the app *could* stop something if
 * only something were different. In practice the window is barely reachable in
 * that state anyway — the copilot's tab is derived from its running session — so
 * this is the honest rendering of the frame between a Stop and the tab going.
 */
export function CopilotStop({ copilot }: { copilot: Copilot }) {
  if (copilot.state?.status !== 'running') return null
  return (
    <button
      type="button"
      className="cp-btn"
      onClick={copilot.stop}
      // The condition, and then the thing a person is entitled to know before
      // pressing a button whose obvious reading is "destroy": that it comes
      // back. Both in one sentence, because a hover label is read once.
      title={`${stateLine(copilot)} — stopping ends its session. The Copilot row starts it again.`}
    >
      Stop
    </button>
  )
}

/**
 * The copilot's condition, in one line.
 *
 * It names the account when the CLI named one, because "signed in" without a
 * login is the kind of half-fact this app keeps having to take back out. Every
 * other branch says what is true and nothing more.
 *
 * Nothing *prints* this on screen any more — the status dot on the pill and the
 * account chip in the bar carry both halves, in the places every other session
 * carries them, which is the whole point of the copilot getting real chrome. It
 * survives as the hover label above, where there is room for a sentence and a
 * dot alone would be a colour with no words.
 */
export function stateLine(copilot: Copilot): string {
  const { state, signIn, stage } = copilot
  switch (stage) {
    case 'starting':
      return 'Starting…'
    case 'stopped':
      return copilot.loading ? 'Checking…' : 'Not running'
    case 'checking':
      return 'Running · checking sign-in'
    case 'first-run':
      return 'Running · signed out'
    case 'unverified':
      return 'Running · sign-in unknown'
    case 'ready':
      return signIn?.account
        ? `Running · ${signIn.account}`
        : state?.recordsHeld
          ? 'Running · signed in, its log held'
          : 'Running · signed in'
  }
}
