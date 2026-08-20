import type { Copilot } from './useCopilot'
import './copilot.css'

/**
 * The one control the copilot's toolbar has that a session's does not.
 *
 * ## It said Stop, and nobody could tell what Stop was for
 *
 * Asad, 2026-08-20, looking at this bar:
 *
 *   > *"Why do we even have the stop button? Instead it should say reset, or it
 *   > should not be there. Restart session or restart only. But I don't
 *   > understand what is the purpose of stop button."*
 *
 * The complaint is exact, and the button was worse than unclear — it was
 * *self-erasing*. Stopping ended the copilot's pty; the copilot's tab is derived
 * from that pty; so the entire observable result of pressing Stop was the window
 * you pressed it in vanishing. Getting it back meant already knowing that the
 * pinned row in the rail starts another one, which is a thing the button never
 * said and no amount of hover text was going to teach at the moment somebody
 * needed it.
 *
 * There was a defence for it, and it does not survive the question he asked. It
 * ran: every ordinary session can be ended from its row in the rail, the copilot
 * is a singleton with no such row, so without this it would be the one session
 * that cannot be switched off anywhere you can see it. True, and irrelevant —
 * *switching the copilot off* is not something anybody stands in this bar
 * wanting to do. It is a settings act, it is offered in Settings → Copilot with
 * a screen around it saying what it costs, and that is where it belongs.
 *
 * ## What somebody actually wants from a control in this place
 *
 * A clean slate. The conversation has gone in circles, the CLI is wedged on a
 * prompt, the account was signed in somewhere else — start again. That is
 * **Restart**, it is `stop` followed by `ensure`, and it is the one reading of
 * this button that needs no explanation at all: the window stays, the same
 * copilot comes back, the transcript is new.
 *
 * It is also the honest name for what the machinery does. `useCopilot.restart`
 * carries why the two calls are sequential rather than concurrent.
 *
 * ## What is lost, said plainly
 *
 * One conversation, which is exactly what is lost when any session is closed and
 * what the copilot's design already treats as expected — it starts fresh rather
 * than `--continue`, because its continuity is `memory/` on disk, not a
 * transcript. Its folder, its `CLAUDE.md` and its memory are untouched.
 *
 * ## Absent rather than disabled while it is not running
 *
 * There is nothing to restart, and a greyed control teaches that the app *could*
 * do it if only something were different. In that state the window is barely
 * reachable anyway — the copilot's tab is derived from its running session — so
 * this is the honest rendering of the frame between a Restart and the new
 * session appearing.
 */
export function CopilotRestart({ copilot }: { copilot: Copilot }) {
  if (copilot.state?.status !== 'running') return null
  return (
    <button
      type="button"
      className="cp-btn"
      onClick={copilot.restart}
      // The condition, then the whole of what pressing it does. One sentence,
      // because a hover label is read once: what goes, what stays, and that the
      // window does not disappear underneath the press — which is the specific
      // thing the control this replaced did without warning.
      title={`${stateLine(copilot)} — restarting ends this conversation and starts a fresh one. Its folder and memory are untouched.`}
    >
      Restart
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
 * Nothing *prints* this on screen — the status dot on the pill and the account
 * chip in the bar carry both halves, in the places every other session carries
 * them, which is the whole point of the copilot getting real chrome. It survives
 * as the hover label above, where there is room for a sentence and a dot alone
 * would be a colour with no words.
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
