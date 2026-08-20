/**
 * One conversation, one session — the guard on `--continue`.
 *
 * ## The data loss this prevents
 *
 * `--continue` does not name a conversation. It means *the most recent
 * conversation in this folder*, and the CLI resolves that itself, at spawn, off
 * the transcripts on disk. So two sessions started in one folder both resolve to
 * the same file, and `ACCOUNT-MODEL.md` measured what happens next — two
 * accounts continuing one conversation concurrently:
 *
 *     user  parent=ffa46102  uuid=de3a640d   ONE says alpha
 *     asst  parent=d858cb82  uuid=86ddf7a7   SINK-REPLY-14
 *     user  parent=86ddf7a7  uuid=e4d1a461   ONE says gamma
 *     user  parent=ffa46102  uuid=b9680b97   TWO says beta      ← same parent
 *
 *     forked parents (same parent claimed by >1 message): 1
 *
 * Its own summary: *"The conversation forked. Two divergent branches, one
 * session id, one file, no error anywhere. Whichever branch `--continue` lands
 * on next, the other is orphaned. Neither account ever saw the other's turns."*
 *
 * **It is not an account problem.** That file found it while testing two
 * accounts, which is why it is written up there, but nothing in the mechanism
 * involves an account: two sessions of the *same* login, in one folder, do the
 * identical thing. The account work merely made it easy to hit on purpose.
 *
 * ## The rule, and whose it is
 *
 * Asad settled it directly rather than asking for a warning or a merge:
 *
 * > *"why would somebody continue same conversation I think it should not be
 * > even possible to continue same conversation in two different sessions so let
 * > someone open new session but new conversation from same account and but
 * > session different"*
 *
 * So a second session in a folder that already has one **starts a fresh
 * conversation** instead of resuming. Not a prompt, not a warning: there is
 * nothing for a person to weigh up, because the branch that loses is invisible
 * until long after the choice was made.
 *
 * ## Why the test is "another live session in this folder" and not something exact
 *
 * The exact question — *is any live session holding the particular transcript
 * this spawn would resolve to* — cannot be asked. The app does not learn a
 * session's transcript id: it spawns `claude` and `claude --continue` with no
 * `--session-id` (`src/shared/agent-catalog.ts`), so the CLI picks and the app is
 * never told. `context-window.ts` has the same problem from the other end and
 * says so — it infers the transcript from the folder and marks every reading it
 * produces `inferred` for exactly this reason.
 *
 * What is knowable is which folders have a session alive in them right now, and
 * that is a **sound** proxy for this purpose even though it is not exact:
 *
 *  - It never forks. If it says a folder is held, refusing to resume is always
 *    safe — the worst case is a new conversation where a resume would have been
 *    fine, which costs one `--continue` typed by hand and loses nothing.
 *  - It errs in the harmless direction only. The dangerous error would be
 *    permitting a resume that forks, and this cannot produce one: a fork needs
 *    two live sessions in one folder, which is precisely what it detects.
 *
 * Being deliberately conservative is the whole design. A guard that guessed
 * more precisely, and was sometimes wrong, would reintroduce the silent case.
 *
 * ## Provider matters, and dead sessions do not
 *
 * Two different agents in one folder cannot fork each other — they keep
 * transcripts in different places and in different formats, and neither one's
 * `--continue` can see the other's. So the check is per provider.
 *
 * A session whose process has exited holds nothing: its `exitCode` is set, the
 * CLI has written its last line, and resuming it is the ordinary, wanted case —
 * closing a tab and opening a new one in the same folder must still continue
 * where it left off, which is the behaviour this app has always had and must
 * not lose to a guard aimed at something else.
 */

/**
 * ## The one live session that is not a second session
 *
 * An account switch replaces the process inside a tab: `performSwitch` starts
 * the replacement *first* and stops the outgoing one a moment later, so that a
 * spawn which cannot start leaves a working session alone. For those few
 * hundred milliseconds there are two live sessions in one folder on one
 * provider — and this guard, reading nothing but that, refused the replacement
 * its `--continue` on every switch that has ever been made.
 *
 * Asad, of exactly that:
 *
 *   > *"See, it is not going to keep it… It's not keeping the conversation
 *   > history… It should at least keep the conversation there, history there,
 *   > memory there when I switch between the accounts."*
 *
 * The guard was not wrong about what it saw; it was answering a question it was
 * not asked. Its subject is *two conversations diverging*, and a replacement is
 * not a second writer — it is the same tab, and the session it is measured
 * against is being killed by the same function that started it. So the switch
 * names the session it is replacing and this ignores it. Nothing else may:
 * `ignore` is a session id, handed down from the one call site that is entitled
 * to say "that one is on its way out", and every other spawn passes nothing and
 * gets the old behaviour unchanged.
 */

/** The fields of a live session this guard reads. A subset of `SessionMeta`. */
export interface SessionInFolder {
  id: string
  cwd: string
  provider: string
  /** `null` while the process is alive; a number once it has exited. */
  exitCode: number | null
}

/**
 * Trailing separators only.
 *
 * Deliberately not `realpath`, and deliberately not a case fold. Both would be
 * a syscall or a platform assumption inside a decision made on the spawn path,
 * and both would change behaviour for paths that are *different strings for the
 * same folder* — a case this guard does not need to win, because getting it
 * wrong there produces the harmless error (a fresh conversation) rather than
 * the dangerous one. `cwd` reaches both sides of this comparison from the same
 * places — the folder picker, a stored project, `ptys.create` — so they match
 * as strings in the ordinary case.
 */
function sameFolder(a: string, b: string): boolean {
  const trim = (path: string): string => path.replace(/[/\\]+$/, '')
  return trim(a) === trim(b)
}

/**
 * Is a conversation in this folder already being written by a live session?
 *
 * `true` means a spawn must not pass `--continue`.
 */
export function conversationIsHeld(
  live: readonly SessionInFolder[],
  cwd: string,
  provider: string,
  /** The session this spawn replaces, when it replaces one. See the note above. */
  ignore?: string | null,
): boolean {
  return live.some(
    (session) =>
      session.exitCode === null &&
      session.provider === provider &&
      sameFolder(session.cwd, cwd) &&
      // A falsy `ignore` can never match an id, so this is the ordinary case
      // spelled the same way as the exemption rather than branched around it.
      session.id !== ignore,
  )
}

/**
 * The spawn arguments, with the guard applied.
 *
 * Written as one function rather than as a condition at the call site so the
 * rule has somewhere to be tested and somewhere to be read. The three inputs
 * are exactly what `host-core.ts` already has in hand at that line.
 */
export function argsForSpawn(input: {
  resume: boolean
  resumeArgs: readonly string[]
  args: readonly string[]
  live: readonly SessionInFolder[]
  cwd: string
  provider: string
  /** The session being replaced, when this spawn is a replacement. */
  replaces?: string | null
}): readonly string[] {
  if (!input.resume || input.resumeArgs.length === 0) return input.args
  if (conversationIsHeld(input.live, input.cwd, input.provider, input.replaces)) return input.args
  return input.resumeArgs
}
