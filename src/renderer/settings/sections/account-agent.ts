import type { ProviderId } from '@shared/types'
import type { AccountProviderRow } from '../../components/ProviderPicker'

/**
 * The three questions the Accounts screens ask about an agent, in one place.
 *
 * They were written inside `AccountsSection.tsx` and moved here when the
 * Add-account dialog became a separate file, for the dullest and most important
 * reason: the dialog needs all three, the pane needs two, and a dialog importing
 * from the pane while the pane imports the dialog is a cycle. Two answers to
 * "can this agent start" is exactly the drift these helpers exist to prevent.
 *
 * Nothing here decides anything. Which agents can hold a second login, and
 * whether each one actually runs on this machine, are both measured in the main
 * process — `main/provider-accounts.ts` and `detectProviders` — and arrive as
 * rows. These are the three readings of a row that the screens need.
 */

/**
 * Can a session actually be opened on this account's agent, right now?
 *
 * The question the app never asked, and the reason the recording of 2026-08-16
 * contains a Node stack trace. `detectProviders` — which is what fills
 * `providerRows.available` — runs each agent once to prove it starts rather than
 * only looking it up, so an unavailable row here means "pressing Sign in would
 * open a terminal that dies". Nothing is created and no session is started in
 * that case.
 *
 * Unknown agent means allowed: an account whose provider the main process did
 * not name is one this screen has no grounds to block.
 */
export function agentCanStart(
  rows: readonly AccountProviderRow[],
  provider: ProviderId | null,
): boolean {
  if (provider === null) return true
  const row = rows.find((entry) => entry.id === provider)
  return row === undefined || row.available
}

/**
 * What to say instead of offering Sign in.
 *
 * One sentence and a command, which is the whole of the brief for this screen:
 * *"it's very inconvenient and not understandable for me as not a technical
 * actual coder, because I am building this mostly for normal level coders or
 * vibe coders."*
 */
export function agentProblem(
  rows: readonly AccountProviderRow[],
  provider: ProviderId | null,
): { text: string; install: string | null } | null {
  if (provider === null) return null
  const row = rows.find((entry) => entry.id === provider)
  if (!row || row.available) return null
  return {
    text: `${row.label} will not start on this machine, so signing in cannot open a session yet.`,
    install: row.install,
  }
}

/**
 * Can this agent hold more than one login?
 *
 * Separate from {@link agentCanStart} because they answer different questions
 * and the screen needs both: whether to offer *this* account an action, and
 * whether a second account of the same agent is a thing that can exist. Gemini
 * answers no here and yes to `agentCanStart`, which is the pairing the whole
 * Gemini fix turns on — it can be signed in; there is only ever one of it.
 */
export function canHaveMore(
  rows: readonly AccountProviderRow[],
  provider: ProviderId | null,
): boolean {
  if (provider === null) return true
  const row = rows.find((entry) => entry.id === provider)
  return row === undefined || row.canAdd
}
