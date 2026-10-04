import type { ProviderId, SessionMeta } from '../shared/types'
import { AGENT_CATALOG, loginsNote } from '../shared/agent-catalog'
import { supportsProfiles, type Profile } from './profiles'
import type { RestoreDecision, SavedSession } from './session-restore'
import { classify, stripAnsi } from './session-activity'
import { BRAND } from '../shared/brand'

/**
 * Running the session you already have as a different account.
 *
 * ## Since 0.16.1: in place, for Claude Code
 *
 * Asad, on 0.16.0: *"Session should not be changed. Session should not be
 * touched. Only account should be changing."* For every Claude Code session
 * this app starts, it now is: the login is handed out by the vault per session
 * (a *seat*), the switch retargets the seat and nudges the CLI to read its
 * login again, and the next request goes out as the other account — same
 * process, same terminal, same conversation (`account-vault/switch-in-place.ts`
 * has the measurements). Such a plan is `mode: 'in-place'`, and nothing below
 * this paragraph applies to it.
 *
 * Everything below is the **restart**, which is still the answer where in place
 * is impossible: Codex, which reads its login once at start and ignores another
 * account's file by design (`codex-carry.ts` — its conversation is now carried
 * across), and any session started before seats existed. The argument that a
 * running agent cannot change its environment still holds; what changed is
 * that Claude Code's login stopped being part of its environment.
 *
 * ## The complaint
 *
 * Asad, 2026-08-17:
 *
 *   > *"when I change account from the dropdown it starts a new session with
 *   > that account, instead of changing it in the same session."*
 *
 * He is right that it was wrong, and the reason it was built that way is also
 * right, which is why it survived a rewrite of the chip and two of its comments.
 * An account is a `CLAUDE_CONFIG_DIR` handed to a CLI at spawn — `profiles.ts`
 * records that setting it chooses the credential *store* and not merely a
 * directory — and a process's environment cannot be rewritten after it starts.
 * So a running agent genuinely cannot change account. Something has to restart.
 *
 * What was wrong was *which* thing restarted. The chip answered "you cannot
 * change this one" by opening a second one somewhere else, which is a different
 * session, in a different tab, that the person then has to find, arrange and
 * close the old one beside. This module is the other answer: the same tab, the
 * same folder, the same place in the strip, with the process underneath it
 * stopped and replaced by one running as the other account.
 *
 * ## What happens to the conversation, established rather than assumed
 *
 * It does not come with you, and that is a fact about Claude Code rather than a
 * limitation of this app. A transcript is written to
 * `<config dir>/projects/<encoded cwd>/<id>.jsonl`, and the config directory is
 * precisely what an account changes. Measured on this machine on 2026-08-17,
 * in `/private/tmp/td-switch-evidence`, with two real signed-in accounts:
 *
 *     $ claude -p 'Reply with exactly one word: ALPHA'
 *     ALPHA
 *     $ claude --continue -p 'What single word did you reply with a moment ago?'
 *     ALPHA
 *     $ CLAUDE_CONFIG_DIR=…/profiles/examplemail-gmail-com \
 *         claude --continue -p 'What single word did you reply with a moment ago?'
 *     I don't have any earlier reply in this conversation — this is your first
 *     message to me, so there's nothing I said "a moment ago."
 *
 * and afterwards the two stores held two different files for the same folder:
 * `~/.claude/projects/-private-tmp-td-switch-evidence/0d1a070e….jsonl` and
 * `…/profiles/examplemail-gmail-com/projects/-private-tmp-td-switch-evidence/532c2a5f….jsonl`.
 * Same binary, same folder, same flag; two conversations that cannot see each
 * other.
 *
 * So the conversation on screen stays with the account it is on. It is not lost
 * — it is on disk, in that account's store, and switching *back* finds it again
 * — but it is not carried across, and there is no honest way to make it appear
 * to be. Copying the file into the other account's store was considered and
 * rejected twice over: this app cannot prove which transcript a terminal is
 * driving in the first place (`renderer/session-transcript.ts` is four
 * paragraphs on exactly that, and ends in `ambiguous` rather than a guess), and
 * writing one person's conversation into another login's private store is the
 * opposite of what somebody keeping two logins apart asked for.
 *
 * **Therefore the UI says so before the switch, not after.** That is the whole
 * of the requirement this module exists to satisfy, and it is why the plan below
 * is a separate question the window asks *first* rather than a result it is
 * handed afterwards. A restart nobody expected is the original complaint; a
 * restart that was described, on screen, in the sentence a person reads before
 * pressing the button, is a choice they made.
 *
 * ## Why the target account's own conversation is continued
 *
 * `--continue` re-reads the most recent conversation in the folder *of the store
 * it is pointed at*. Under the new account that is the new account's own
 * conversation here, which is a different conversation from the one on screen —
 * so continuing it is only defensible because the plan says which one it will
 * be, in words, before anything is stopped.
 *
 * It is worth it for the case that makes a switch survivable: switching to the
 * other account and back. Without it, a round trip destroys the conversation you
 * left, and a control whose only safe use is one-way is a control people learn
 * to fear. With it, the decision is exactly the decision the launch path already
 * makes for a restored tab — same probes, same one-tab-per-store rule, same
 * words — so there is one answer to "when is `--continue` honest?" in this app
 * and not two. See `planRestore`, which is what produces the `RestoreDecision`
 * this module reads.
 *
 * ## What cannot be switched, and why the ledger is the test
 *
 * Only a session that is somebody's tab. `OpenSessionLedger` already holds
 * exactly that set and no more: `host-core.ts` deliberately declines to write
 * down a session it composed for itself (the copilot, which is spawned with an
 * instruction layer and `--mcp-config`) or one held inside a device's folder
 * grant, because a `SavedSession` carries a folder, an agent and an account and
 * nothing else — so restarting from one produces something that is *not* the
 * session that was written down.
 *
 * That reasoning is this module's reasoning word for word. Restarting the
 * copilot from here would produce, in the copilot's tab, a plain Claude Code
 * session in the copilot's folder with no layer, no `deck-control` tools and no
 * fence — the exact thing `startCopilot` refuses to do — and restarting a
 * device's confined session would drop the boundary it is held inside. So the
 * question this module asks is "is it in the ledger?", and a session that is not
 * is refused with a sentence rather than quietly turned into something else.
 *
 * ## And a shell has no account at all
 *
 * `renderer/finish.test.ts` pins that a shell is never described as an agent,
 * and the refusal below is that same rule at the other end of the wire: an
 * account is a config directory handed to an agent, so a session with no agent
 * in it has nothing for one to be about. The sentence it is refused with is the
 * agent's own from `shared/agent-catalog.ts` rather than a new one written here,
 * for the reason `loginsNote` exists — a reason that does not match the agent
 * leaves a person unable to tell whether the app looked or gave up.
 */

/* --------------------------------------------------------------- channels -- */

/**
 * What would happen, asked before anything is stopped.
 *
 * A channel of its own rather than a field on the switch, because the answer has
 * to be on screen *before* the decision is made and the switch is the decision.
 * It is also the only part that touches the disk — the target account's
 * transcript store — so keeping it separate is what lets the window put a
 * sentence in front of somebody without having committed to anything.
 */
export const SESSION_SWITCH_PLAN_CHANNEL = 'session:switch-plan'

/** Do it: stop the agent in this session and run the same tab as another account. */
export const SESSION_SWITCH_CHANNEL = 'session:switch-account'

/* ------------------------------------------------------------------ shape -- */

/**
 * What becomes of the conversation, in the five shapes it can actually take.
 *
 * Five rather than a boolean, because the sentence a person needs is different
 * in each and three of them are indistinguishable from "it starts fresh" unless
 * they are named. The renderer turns these into words — see
 * `renderer/session-switch.ts` — for the same reason the account's *name* is
 * decided there: this process knows what is on disk, and the window owns every
 * decision about what to call an account.
 *
 *  - `follows`    the two accounts share one conversation history, so the
 *                 conversation on screen is the conversation the replacement
 *                 continues. Option C, and the whole point of it.
 *  - `stays`      the other account has no conversation in this folder, so it
 *                 starts a new one. The conversation on screen stays where it is.
 *  - `theirs`     the other account has its own conversation here, and the
 *                 switch continues *that* one. Not the one on screen.
 *  - `taken`      it has one, but another tab open right now is already
 *                 continuing it, and two terminals on one transcript is the
 *                 thing `planRestore` exists to prevent. So this starts fresh.
 *  - `unreadable` this app cannot read this agent's history — Codex keeps its
 *                 own, and a session inside WSL keeps it under a Linux home this
 *                 process was never told — so the CLI is asked to continue and
 *                 answers for itself, in its own words, in the terminal.
 *  - `none`       this agent has no way to continue anything. Nothing is lost
 *                 that was ever recoverable.
 *  - `separate`   this agent keeps every account's conversations inside that
 *                 account's own folder (Codex: `$CODEX_HOME/sessions`), so the
 *                 account being switched to cannot see this conversation at all
 *                 — and its own "continue the last one" would quietly attach to
 *                 some other conversation of its own. So it starts fresh, and
 *                 the sheet says so before anything happens.
 *  - `same`       nothing restarts: the session is switched in place, so the
 *                 process, the terminal and the conversation are the ones on
 *                 screen, and only the login it is handed changes.
 *  - `carried`    an agent that reads its login once (Codex) is restarted, and
 *                 the conversation on screen is copied into the other account's
 *                 own history and continued there by id (`codex-carry.ts`).
 */
export type SwitchConversation =
  | 'same'
  | 'carried'
  | 'follows'
  | 'stays'
  | 'theirs'
  | 'taken'
  | 'unreadable'
  | 'none'
  | 'separate'

/**
 * Agents whose conversations live inside the account's own folder with no
 * shared history this app can arrange — so a conversation can never follow a
 * switch, by id or otherwise. Codex can resume a session by id (`codex resume
 * <id>`), but only from the `CODEX_HOME` that holds it, and another account is
 * another `CODEX_HOME`.
 */
const SEPARATE_HISTORIES: ReadonlySet<ProviderId> = new Set(['codex'])

/** An account, as much of one as the window needs to name it. */
export interface SwitchAccount {
  id: string
  /** The stored name. The window draws the address ladder over the top of it. */
  name: string
  provider: ProviderId
}

export interface SwitchPlan {
  sessionId: string
  /**
   * Why this cannot happen, in a sentence written for a person, or null when it
   * can.
   *
   * A sentence rather than a code for the same reason `AgentUnavailableError`
   * carries one: it is the only thing most people will ever see of this
   * decision, and the window has nothing to add to it that would not be a
   * second, differently-worded account of the same fact.
   */
  refusal: string | null
  /** The account the session is running as now, when it has one. */
  from: SwitchAccount | null
  /** The account it would run as. Null when the id names nothing on this machine. */
  to: SwitchAccount | null
  conversation: SwitchConversation
  /** Whether the replacement process is handed the agent's continue flag. */
  resume: boolean
  /**
   * How the switch happens.
   *
   *  - `in-place`  the session keeps running and only its login changes — the
   *                answer for every Claude Code session this app started with a
   *                seat at the vault. Nothing to confirm: nothing is stopped.
   *  - `restart`   the agent is stopped and started again as the other account
   *                — the only way for an agent that reads its login once
   *                (Codex), and for a session started before seats existed.
   */
  mode: SwitchMode
}

export type SwitchMode = 'in-place' | 'restart'

/* ---------------------------------------------- did the replacement live? -- */

/**
 * How long a replacement is watched before the session it replaces is stopped.
 *
 * Long enough to catch the failure below and short enough that nobody wonders
 * whether the button worked: Claude Code prints its refusal and exits inside a
 * second, and the sheet says "Switching…" for the whole of this.
 *
 * The cost of the wait is two agents alive in one folder for a moment, which is
 * already true of the start-then-stop order and is a thing people do by hand
 * with two terminals. The cost of *not* waiting is the whole session.
 */
export const SWITCH_GRACE_MS = 1500

export interface SurvivalProbe {
  /** Wait, injected rather than imported, so a test never actually sleeps. */
  wait(ms: number): Promise<void>
  /** Is that session still running? */
  alive(id: string): boolean
  /** What it printed, so a failure can be reported in the agent's own words. */
  screen(id: string): string
}

/**
 * Whether the replacement is still there a moment after it started — and, if
 * not, what it said on the way out.
 *
 * ## Why this exists
 *
 * A switch can hand the new process the agent's continue flag, and there is a
 * real case where the transcript this app can see is *not* one the CLI will
 * continue. Reproduced on this machine on 2026-08-17: a conversation created by
 * `claude -p` writes a perfectly good `.jsonl` under
 * `projects/<encoded cwd>/`, and interactive `claude --continue` in that same
 * folder answers **"No conversation found to continue"** and exits immediately.
 * So `conversationOnDisk` says `found`, the plan says `resume`, and the
 * replacement dies a second after it starts.
 *
 * Without this check the switch would already have killed the session being
 * replaced, and the person would be left with a dead tab where a working agent
 * used to be — which is precisely the fault this whole feature was written not
 * to have. The restore path can afford the same risk because nothing was running
 * there to lose; here there is.
 *
 * ## Why a grace period rather than an exit subscription
 *
 * The shell's exit handler is one function shared by every session and by four
 * unrelated features. Threading a per-session promise through it, for a
 * condition that resolves either way inside a second, would put a new
 * cross-cutting concern into the busiest callback in the app. This asks the one
 * question that matters — *is it still there?* — at the one moment that matters,
 * from the same session list everything else reads.
 *
 * It is deliberately not a guarantee that the session will keep running. It is
 * the answer to "did it start", and a session that dies ten minutes later is an
 * ordinary session dying, which the app already handles.
 */
export async function survivedStart(
  id: string,
  probe: SurvivalProbe,
  grace = SWITCH_GRACE_MS,
): Promise<{ alive: boolean; said: string | null }> {
  await probe.wait(grace)
  if (probe.alive(id)) return { alive: true, said: null }
  return { alive: false, said: lastLine(probe.screen(id)) }
}

/**
 * The last thing a process said, or null when it said nothing worth repeating.
 *
 * The agent's own sentence beats anything this app could compose about it —
 * *"No conversation found to continue"* is the whole diagnosis, and a message
 * saying "the replacement did not start" instead would be strictly less useful
 * than the line already sitting in the buffer.
 *
 * Capped, because a pty buffer can end in a wrapped paragraph and a dialog is
 * not a log viewer. Cut on a character count rather than at a word boundary: a
 * truncated line with an ellipsis reads as truncated, whereas one tidied to the
 * last whole word reads as the complete message and can leave off the clause
 * that mattered.
 */
export function lastLine(screen: string, limit = 160): string | null {
  const lines = screen
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== '')
  const line = lines[lines.length - 1]
  if (line === undefined) return null
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line
}

/**
 * What to tell somebody whose replacement did not stay up.
 *
 * The session they were switching is still running — the order this handler
 * works in is what makes that true — and saying so is not padding: they have
 * just read a failure, and without this line the next thing they do is go
 * looking for what they lost.
 */
export function startFailed(account: string, said: string | null): string {
  const quoted = said === null ? '' : ` It said: “${said}”.`
  return (
    `${account} started and stopped straight away, so nothing was switched.${quoted}` +
    ` This session is still running as it was.`
  )
}

/* ---------------------------------------------- is the replacement ready? -- */

/**
 * The longest a switch waits for the replacement to show it is ready.
 *
 * A ceiling, not a guess at how long a start takes: the switch moves on the
 * moment the agent draws its prompt (or a question for the person), which is
 * usually within a second or two. Fifteen seconds covers a cold start of the
 * CLI resuming a long conversation; past it a replacement that is still alive
 * and still drawing is taken as started, exactly as the fixed wait used to take
 * every replacement — the difference is that it is now the last resort.
 */
export const SWITCH_READY_CEILING_MS = 15_000

/** How often the replacement's screen is looked at while waiting. */
export const SWITCH_READY_POLL_MS = 150

/**
 * What a signed-out agent draws instead of its prompt.
 *
 * The case the old fixed wait could not see: an agent with no login does not
 * exit, it sits alive at its own sign-in screen, so "still alive after 1.5s"
 * passed and the working session was stopped with a login prompt left in its
 * place. These are the CLIs' own words, matched on the visible screen.
 */
const SIGNED_OUT = [
  /not logged in/i,
  /please run \/login/i,
  /select login method/i,
  /invalid api key/i,
  /oauth (?:session|token) (?:has )?expired/i,
  /could not be refreshed/i,
]

export interface ReadinessProbe {
  /** Wait, injected so a test never actually sleeps. */
  wait(ms: number): Promise<void>
  /** Is that session still running? */
  alive(id: string): boolean
  /** What it is showing right now, as a person would see it. Null when unknown. */
  screen(id: string): Promise<string | null>
  /** What it printed, for quoting a failure in the agent's own words. */
  scrollback(id: string): string
}

/**
 * How a replacement turned out.
 *
 *  - `ready`       it drew its prompt, or a question for the person (a trust
 *                  dialog in a folder this account has not opened before), and
 *                  is still alive — the moment the old session can go.
 *  - `started`     alive at the ceiling without a conclusive screen. Taken as
 *                  started, which is the last resort rather than the rule.
 *  - `died`        it exited. `said` is its last line.
 *  - `signed-out`  it is alive at a sign-in screen. Not a switch: the session it
 *                  would replace is left running.
 */
export interface Readiness {
  outcome: 'ready' | 'started' | 'died' | 'signed-out'
  said: string | null
  waitedMs: number
}

/**
 * Wait for the replacement to be *ready*, rather than for a fixed time to pass.
 *
 * The signal is the one the rest of the app already reads a session's state
 * from: its visible screen, through the same classifier the sidebar's status
 * uses (`session-activity.ts`). Ready is seen twice in a row before it counts,
 * because an agent can draw a frame and exit in the same breath — `--resume`
 * against a conversation it will not continue does exactly that.
 */
export async function awaitReplacement(
  id: string,
  probe: ReadinessProbe,
  options: { ceilingMs?: number; pollMs?: number } = {},
): Promise<Readiness> {
  const ceiling = options.ceilingMs ?? SWITCH_READY_CEILING_MS
  const poll = options.pollMs ?? SWITCH_READY_POLL_MS
  let waited = 0
  let readyStreak = 0
  for (;;) {
    if (!probe.alive(id)) {
      return { outcome: 'died', said: lastLine(probe.scrollback(id)), waitedMs: waited }
    }
    const screen = await probe.screen(id)
    /*
     * No screen to read — a core with no shadow terminal. There is then no
     * readiness signal to wait for, and waiting out the ceiling would only make
     * every switch fifteen seconds slow, so the old rule applies: alive after
     * the grace period counts as started.
     */
    if (screen === null && waited >= SWITCH_GRACE_MS) {
      return { outcome: 'started', said: null, waitedMs: waited }
    }
    if (screen !== null) {
      const visible = stripAnsi(screen)
      if (SIGNED_OUT.some((pattern) => pattern.test(visible))) {
        return { outcome: 'signed-out', said: lastLine(visible), waitedMs: waited }
      }
      const status = classify(screen, false)
      readyStreak = status === 'waiting' || status === 'input' ? readyStreak + 1 : 0
      if (readyStreak >= 2) return { outcome: 'ready', said: null, waitedMs: waited }
    }
    if (waited >= ceiling) return { outcome: 'started', said: null, waitedMs: waited }
    await probe.wait(poll)
    waited += poll
  }
}

/** What to tell somebody whose replacement came up at a sign-in screen. */
export function startSignedOut(account: string): string {
  return (
    `${account} is not signed in, so nothing was switched. This session is still running as it was. ` +
    `Sign in to ${account} first, then switch.`
  )
}

/* ------------------------------------------- carrying the conversation -- */

/**
 * The conversation the replacement is told to continue, by id — or null to let
 * `--continue` mean what it has always meant.
 *
 * ## Why an id rather than the flag
 *
 * `--continue` names no conversation. It means *the most recent one in this
 * folder*, resolved by the CLI at spawn, and on a switch that is a guess which
 * is right almost always: the session being replaced was written to a moment
 * ago, so it is the folder's newest. Almost always is not what the sheet says
 * though. `follows` is a promise about **the conversation on screen**, and this
 * app knows which one that is — it put the id on the outgoing process's own
 * command line, and `SessionMeta.agentSessionId` is that id.
 *
 * ## Three conditions, and each one is a way of not lying
 *
 *  - The plan has to say `follows`. `theirs` is the deliberate case where the
 *    two accounts keep separate stores and the replacement picks up the *other*
 *    account's conversation in the same folder; naming this one there would
 *    reach into a store the plan has just told somebody it would not.
 *  - There has to be an id. A session this app did not start, or one that
 *    resumed rather than being named, has none — the honest answer then is the
 *    folder's newest, which is what it would have got anyway.
 *  - The transcript has to be readable from the account being switched *to*.
 *    `--resume` against an id the target's store cannot see is a replacement
 *    that prints an error and exits, and the switch turns into "nothing
 *    happened" for the sake of a precision nobody asked for. Falling back
 *    leaves the behaviour exactly as it was.
 */
export function conversationToCarry(input: {
  plan: SwitchPlan
  /** The id this app put on the outgoing process, when it put one there. */
  agentSessionId: string | null | undefined
  /** Is that transcript readable from the store the replacement will run against? */
  readableInTarget: boolean
}): string | null {
  if (!input.plan.resume || input.plan.conversation !== 'follows') return null
  const id = input.agentSessionId
  if (typeof id !== 'string' || id === '') return null
  return input.readableInTarget ? id : null
}

/* --------------------------------------------------------------- deciding -- */

/** What this app calls an agent when explaining something about it. */
function agentLabel(provider: ProviderId): string {
  return AGENT_CATALOG[provider]?.label ?? provider
}

/**
 * Everything that can be refused without looking at a disk.
 *
 * Separate from the plan below so that each answer is one line and every one of
 * them can be driven directly by a test. They are in the order a person would
 * hit them, which is also the order of increasing specificity: is there a
 * session, is it *your* session, is there an agent in it, does that agent have
 * accounts at all, is the account you picked one of its.
 */
export function switchRefusal(input: {
  /** The live session, or null when nothing is running under that id. */
  meta: SessionMeta | null
  /** Its ledger record — present for a tab a person opened, absent otherwise. */
  saved: SavedSession | null
  /** The account being asked for, or null when the id names nothing. */
  target: Profile | null
  /**
   * Whether the account being asked for holds a login, when that is known for
   * certain — `false` only for an account whose login this app keeps and whose
   * vault holds nothing. `null`/absent when it cannot be known without asking
   * the agent, which is every account the agent keeps itself.
   */
  targetSignedIn?: boolean | null
  /**
   * The sentence for an account whose login this app keeps and cannot reach in
   * this process (`keptUnavailable`), or null. A replacement started on it would
   * read a stale keychain login or none, so the switch never stops anything.
   */
  targetUnavailable?: string | null
}): string | null {
  const { meta, saved, target } = input

  if (meta === null) {
    return 'That session is not running any more, so there is nothing to switch.'
  }
  if (meta.exitCode !== null) {
    return 'This session has already ended. There is no agent in it to run as anybody.'
  }
  /*
   * Not a tab. See the module note: the ledger holds exactly the sessions a
   * person opened, and the two kinds it leaves out are the two kinds that would
   * come back as something other than themselves — the copilot without its
   * instruction layer and its tools, and a device's session without the folder
   * boundary it is held inside.
   */
  if (saved === null) {
    return (
      'Only a session you opened here can be switched. This one was started for a paired ' +
      `device or by ${BRAND.assistant}, and those keep the account they were given.`
    )
  }
  /*
   * A session with no account is a session with nothing for an account to be
   * about — a plain shell, or an agent whose config directory this app cannot
   * redirect. The agent's own sentence, never a generic one.
   */
  /*
   * A plain terminal. If an agent is running in it, somebody typed its name at
   * a shell prompt, so this app never launched it, never chose its folder or
   * login, and has no way to restart it as anybody else. Said as that, because
   * "a shell has no account" reads as the app not having looked, to somebody
   * who can see Claude running in the tab.
   */
  if (meta.provider === 'shell') {
    return (
      'This tab is a plain terminal. An agent typed into it was not started by this app, so its ' +
      'account cannot be switched from here — open a new session on the account you want instead.'
    )
  }
  if (!supportsProfiles(meta.provider)) {
    return loginsNote(meta.provider)
  }
  if (target === null) {
    return 'That account is not on this machine any more.'
  }
  /*
   * An account is a login of one specific CLI. Handing a Codex config directory
   * to a Claude session is the failure `resolveProfileId` already declines —
   * quietly, by falling back to the machine's own install — and the quiet
   * version of it is what made picking a Codex account from this menu look like
   * the app ignoring the click.
   */
  if (target.provider !== meta.provider) {
    return (
      `${target.name} is a ${agentLabel(target.provider)} login and this session is running ` +
      `${agentLabel(meta.provider)}. An account only means anything to the agent it is a login of.`
    )
  }
  if (target.id === meta.profileId) {
    return 'This session is already running as that account.'
  }
  /*
   * An account with no login, refused before anything is stopped.
   *
   * The switch proves the replacement is *alive* before it stops the session
   * it replaces — and an agent with no login is alive: it sits at its own
   * sign-in screen, waiting. So a switch to a signed-out account passed every
   * check, stopped a working session mid-conversation and left a login prompt
   * in its tab. Where the app keeps the login it knows the answer without
   * asking anybody, and the answer comes first.
   */
  if (input.targetUnavailable) return input.targetUnavailable
  if (input.targetSignedIn === false) {
    return (
      `${target.name} is not signed in yet, so this session was left as it is. ` +
      'Sign in to it first, then switch.'
    )
  }
  return null
}

/**
 * The whole answer: what is refused, what would happen to the conversation, and
 * whether the replacement is handed the continue flag.
 *
 * `decision` is `planRestore`'s answer for this session *under the target
 * account*, and taking it rather than re-deriving one is the point. "When is
 * `--continue` honest?" is a question this app has already answered carefully,
 * with three facts and a whole file of reasoning behind it; a second answer
 * written here would be a second answer that only ever runs on the path nobody
 * exercises. `occupied` is the one thing that decision cannot know, because it
 * is about the sessions running *right now* rather than the ones being restored.
 */
export function planSwitch(input: {
  sessionId: string
  meta: SessionMeta | null
  saved: SavedSession | null
  target: Profile | null
  /** `planRestore`'s decision for this session under `target`. */
  decision: RestoreDecision | null
  /** Is another live tab already continuing the conversation this would? */
  occupied: boolean
  /** See `switchRefusal`. */
  targetSignedIn?: boolean | null
  /** See `switchRefusal`. */
  targetUnavailable?: string | null
  /**
   * Do the two accounts read the same conversation history?
   *
   * True when `shared-projects.ts` has linked both accounts' `projects/` into
   * one location, which is Option C from `ACCOUNT-MODEL.md`. It was off until
   * somebody turned it on per account, and that is exactly why the feature was
   * reported broken a second time: the accounts anybody already had were not
   * sharing, so every switch really did leave the conversation behind and the
   * fix sat unused in the same build. `adoptSharedHistory` now runs on the way
   * up and the switch itself asks again, so on a Claude account this app
   * created the answer here is ordinarily yes. It changes nothing about what
   * happens —
   * the replacement `--continue`s whatever the target store holds either way —
   * and it changes everything about what may honestly be *said* about it. With
   * separate stores the conversation the new account picks up is a different
   * conversation that merely lives in the same folder; with one store it is
   * this conversation, the one on screen, which is the thing the whole feature
   * was built to buy:
   *
   *     user: remember the word PLATYPUS | sid dbebd1aa      ← ACCOUNT-ONE
   *     user: what word                  | sid dbebd1aa      ← ACCOUNT-TWO
   *
   * Without this the sheet tells somebody who has turned sharing on that the
   * conversation on screen stays behind and another one takes its place, which
   * is exactly false and is the sentence they would be deciding on.
   */
  sharedStore: boolean
  /**
   * For an agent that keeps each account's conversations apart (Codex): the
   * conversation on screen has been found on disk and will be put where the
   * other account can continue it (`codex-carry.ts`). Without it, such a
   * switch starts fresh.
   */
  carried?: boolean
}): SwitchPlan {
  const { sessionId, meta, saved, target, decision, occupied, sharedStore } = input

  const from: SwitchAccount | null =
    meta?.profileId !== undefined && meta.profileName !== undefined
      ? { id: meta.profileId, name: meta.profileName, provider: meta.provider }
      : null
  const to: SwitchAccount | null =
    target === null ? null : { id: target.id, name: target.name, provider: target.provider }

  const refusal = switchRefusal({
    meta,
    saved,
    target,
    targetSignedIn: input.targetSignedIn ?? null,
    targetUnavailable: input.targetUnavailable ?? null,
  })
  if (refusal !== null) {
    return { sessionId, refusal, from, to, conversation: 'stays', resume: false, mode: 'restart' }
  }

  /*
   * An agent whose conversations live inside each account's own folder: the
   * account being switched to cannot see this one, and its own "continue"
   * would attach to some other conversation it happens to have. Fresh, and
   * said so — before anything is stopped.
   */
  if (meta !== null && SEPARATE_HISTORIES.has(meta.provider)) {
    if (decision !== null && decision.outcome === 'skip') {
      return {
        sessionId,
        refusal: `This session cannot be started again: ${decision.reason}.`,
        from,
        to,
        conversation: 'stays',
        resume: false,
        mode: 'restart',
      }
    }
    // Found on disk and carried across: it follows, by id.
    if (input.carried === true) {
      return { sessionId, refusal: null, from, to, conversation: 'carried', resume: true, mode: 'restart' }
    }
    return { sessionId, refusal: null, from, to, conversation: 'separate', resume: false, mode: 'restart' }
  }

  /*
   * A decision the plan could not reach at all. `skip` is only ever "the folder
   * is gone", and a folder that is gone is a session that cannot be started in
   * it — so it is a refusal rather than a conversation outcome, and it is
   * refused in the plan's own words. Absent is the same situation arriving by a
   * different route and gets the same treatment rather than a default, because
   * the honest reading of "nothing was decided" is not "start it fresh".
   */
  if (decision === null || decision.outcome === 'skip') {
    return {
      sessionId,
      refusal: `This session cannot be started again: ${decision?.reason ?? 'nothing could be decided about it'}.`,
      from,
      to,
      conversation: 'stays',
      resume: false,
      mode: 'restart',
    }
  }

  if (decision.outcome !== 'resume') {
    /*
     * Started clean, and there are two quite different reasons for it.
     *
     * `conversation` is set by `planRestore` exactly when it got as far as
     * *asking* the disk, so its absence here is the one case that never reaches
     * the disk at all: an agent with no way to continue anything. Everything
     * else that lands on a clean start has asked and been told the target store
     * holds nothing for this folder — the ordinary case, and the reassuring one,
     * because it also means the other account has never worked here and nothing
     * of theirs is being disturbed.
     *
     * Read off that field and never off the reason string. The reasons are
     * written for a person and are meant to be improved; a decision hanging on
     * one of them breaks the next time somebody rewords it, silently, in the
     * direction of a wrong claim on screen.
     */
    return {
      sessionId,
      refusal: null,
      from,
      to,
      conversation: decision.conversation === undefined ? 'none' : 'stays',
      resume: false,
      mode: 'restart',
    }
  }

  /*
   * There is something to continue in the target store — but only one terminal
   * may be on a transcript at a time, and `planRestore` cannot see the tabs that
   * are open right now. A switch into a conversation another tab is already
   * showing would put the same conversation on screen twice and let two
   * terminals write to one file.
   */
  if (occupied) {
    return { sessionId, refusal: null, from, to, conversation: 'taken', resume: false, mode: 'restart' }
  }

  return {
    sessionId,
    refusal: null,
    from,
    to,
    /*
     * `follows` outranks `theirs`, and only one of the two can be true. They
     * describe the same mechanical act — the replacement is handed the continue
     * flag and attaches to whatever the target store holds for this folder — and
     * differ entirely in what that store *is*. Shared, it is this conversation;
     * separate, it is one belonging to the other account that happens to be in
     * the same directory. `unreadable` still wins over both, because it means
     * the app could not see the store at all and has no business claiming
     * anything about what is in it.
     */
    conversation:
      decision.conversation === 'unknown' ? 'unreadable' : sharedStore ? 'follows' : 'theirs',
    resume: true,
    mode: 'restart',
  }
}

/**
 * The plan for a session that can be switched in place: the same refusals a
 * restart would meet — a session that has ended, an account of another agent,
 * one that is not signed in, the account it is already on — and otherwise
 * nothing at all to warn about, because nothing is stopped. The conversation on
 * screen is the conversation that carries on.
 */
export function planInPlace(input: {
  sessionId: string
  meta: SessionMeta | null
  saved: SavedSession | null
  target: Profile | null
  targetSignedIn?: boolean | null
  targetUnavailable?: string | null
}): SwitchPlan {
  const { sessionId, meta, saved, target } = input
  const from: SwitchAccount | null =
    meta?.profileId !== undefined && meta.profileName !== undefined
      ? { id: meta.profileId, name: meta.profileName, provider: meta.provider }
      : null
  const to: SwitchAccount | null =
    target === null ? null : { id: target.id, name: target.name, provider: target.provider }
  const refusal = switchRefusal({
    meta,
    saved,
    target,
    targetSignedIn: input.targetSignedIn ?? null,
    targetUnavailable: input.targetUnavailable ?? null,
  })
  return {
    sessionId,
    refusal,
    from,
    to,
    conversation: refusal === null ? 'same' : 'stays',
    resume: false,
    mode: refusal === null ? 'in-place' : 'restart',
  }
}
