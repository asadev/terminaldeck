/**
 * Running a session as a different login, and opening a terminal to sign one in
 * — the operations themselves, owned by neither shell.
 *
 * ## Why this file exists
 *
 * Asad, inside a session on a headless server: *"when I am inside the server, I
 * cannot even change the accounts."* He was right four different ways at once —
 * the chip, the switch, the sign-in and the capability were all desktop-only —
 * and the reason was structural rather than a missing wire: `performSwitch` and
 * `signInAccount` lived in `src/main/index.ts`, a file the headless build can
 * never load, even though neither function touches a window, a dialog or
 * anything else Electron owns. They use `core.startSession`, the ledger and the
 * pty list — all of which the headless host holds through the same `HostCore`.
 *
 * So the operations moved here, behind the same seam `host-core.ts` sits
 * behind, and **both shells** now hand them to `createHostCore` as
 * `switchAccount` and `signInAccount`. That is the whole mechanism by which a
 * headless host advertises `CAPABILITY.account` and `CAPABILITY.logins`: the
 * fanout offers the account seam exactly when the shell supplied the verb, and
 * the PWA and the iOS client already send the frames.
 *
 * ## What deliberately did not move
 *
 * The IPC registrations, the deferred switch (`switch-later.ts` is about
 * carrying a half-typed line across a restart, which only a window has), and
 * every announcement. A shell that opens a sign-in terminal decides for itself
 * who to tell — the desktop broadcasts `session:created` at its renderer, the
 * headless host pushes the session list at every attached device — so the
 * telling is a hook (`onSessionOpened`) rather than a hardwired call.
 *
 * ## The security shape, restated because it is load-bearing
 *
 * Nothing here fans anything out. What a *device* may see of the account list
 * is decided per connection in `remote/server.ts` (`accountShared(deviceId,…)`,
 * `anyAccountFor`, `ownDevice`), and these functions never learn which device —
 * if any — asked. They act as the machine's own hands, exactly as they did when
 * they lived in the desktop shell.
 */

import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { ProviderId, SessionMeta } from '../shared/types'
import { logger } from './app-log'
import type { HostCore } from './host-core'
import { findProfile, getState as profilesState, resolveProfile } from './profiles'
import {
  conversationOnDisk,
  conversationScope,
  conversationStore,
  folderExists,
  planRestore,
  type RestoreDecision,
  type SavedSession,
} from './session-restore'
import {
  conversationToCarry,
  planSwitch,
  startFailed,
  survivedStart,
  switchRefusal,
  type SwitchPlan,
} from './session-switch'
import { canJoinSharedHistory, joinSharedHistory } from './shared-projects'
// `transcriptDir` and `projectPathSpellings`: where a named conversation is
// filed under one account's store, in both spellings of a folder reached
// through a symlink. Read by the switch, to check that the conversation it is
// about to name is one the other login can actually see.
import { projectPathSpellings, transcriptDir } from './transcript'

/**
 * The slice of the core the switch needs — a `Pick` rather than the whole
 * interface so a test can stand a fake core up out of five members, and so the
 * dependency is legible: nothing here reaches grants, devices or the fanout.
 */
export type SwitchCore = Pick<
  HostCore,
  'ptys' | 'ledger' | 'startSession' | 'statablePath' | 'canContinue'
>

/** What `switchSubject` gathers, once, for the plan and the switch alike. */
export interface SwitchSubject {
  plan: SwitchPlan
  saved: SavedSession | null
  resume: boolean
  /** The conversation to name on the replacement, or null for the folder's newest. */
  conversationId: string | null
}

/** The verb shape the wire and both shells share. See `HostCoreOptions.switchAccount`. */
export interface AccountVerbAnswer {
  ok: boolean
  message: string
  session: string | null
}

export interface SessionSwitch {
  /** Everything a switch would do, before one is made. Feeds the plan sheet. */
  subject(sessionId: unknown, profileId: unknown): Promise<SwitchSubject>
  /** Run the session as that login: start, prove alive, then stop the old one. */
  perform(sessionId: unknown, profileId: unknown): Promise<SessionMeta>
  /** `perform`, answered as a sentence instead of a rejection — the wire's shape. */
  switchAccount(sessionId: string, accountId: string): Promise<AccountVerbAnswer>
  /** Open a terminal under that login's configuration for a person to finish a sign-in in. */
  signInAccount(accountId: string): Promise<AccountVerbAnswer>
}

export interface SessionSwitchHooks {
  /**
   * A session this module started outside anybody's request for a *tab* — the
   * sign-in terminal. The desktop broadcasts it at its window; the headless
   * host pushes its session list at every attached device. Not called for the
   * switch's replacement session: that one is answered to the caller, who is
   * attached to the old id and follows it by the answer.
   */
  onSessionOpened?(meta: SessionMeta): void
}

/**
 * How a remembered session is turned into a decision, asked with the same
 * questions in the same order as the launch restore asks them.
 *
 * Exported so the desktop shell's own `planSaved` — the launch restore and the
 * held-session retry — is this exact composition rather than a second copy that
 * can drift from it. The headless host's restore builds the same object inline;
 * see `src/headless/host.ts`.
 */
export function savedPlanner(
  core: Pick<HostCore, 'statablePath' | 'canContinue'>,
): (sessions: readonly SavedSession[]) => Promise<RestoreDecision[]> {
  return (sessions) =>
    planRestore(sessions, {
      // Asked about the folder as Windows can see it. Without the translation
      // every session that was running inside a distro is planned as "its folder
      // is gone" and dropped, which is the app losing a day's tabs and explaining
      // it with a sentence that is not true.
      folderExists: (cwd) => folderExists(core.statablePath(cwd)),
      // `core.canContinue`, not `PROVIDERS[provider].resumeArgs`: the table has
      // only the agents this build ships, so a restored session on an agent the
      // person added threw a `TypeError` here and took the whole restore — every
      // other tab included — down with it.
      canContinue: core.canContinue,
      /*
       * Resolved exactly the way `startSession` resolves it, and that is the
       * point: the directory searched for a conversation has to be the directory
       * the restored session will then write to, or the answer is about a
       * different login than the one coming back.
       */
      configDir: (session) =>
        resolveProfile(profilesState(), {
          sessionProfileId: session.profileId ?? undefined,
          projectPath: session.cwd,
        }).configDir,
      conversation: conversationOnDisk,
    })
}

/**
 * The switch and the sign-in, assembled over one core.
 *
 * Both shells call this once, right after `createHostCore`, and hand the two
 * verb-shaped members back to the core's options — late-bound there, because
 * the core has to exist before this can be built from it, and the options are
 * read per call rather than at construction.
 */
export function createSessionSwitch(core: SwitchCore, hooks: SessionSwitchHooks = {}): SessionSwitch {
  const planSaved = savedPlanner(core)

  const subject = async (
    sessionId: unknown,
    profileId: unknown,
  ): Promise<{
    plan: SwitchPlan
    saved: SavedSession | null
    resume: boolean
    /** The conversation to name on the replacement, or null for the folder's newest. */
    conversationId: string | null
  }> => {
    const id = typeof sessionId === 'string' ? sessionId : ''
    const wanted = typeof profileId === 'string' ? profileId : ''
    const meta = core.ptys.list().find((session) => session.id === id) ?? null
    const saved = core.ledger.get(id)
    const target = wanted === '' ? null : findProfile(profilesState(), wanted)

    /*
     * The decision is only asked for once the cheap refusals have passed, and
     * that ordering is deliberate rather than an optimisation. `planSaved` stats
     * a folder and reads a directory; asking it about a session that is a plain
     * shell, or about an account of the wrong agent, would be doing work to
     * answer a question that has already been answered — and, on a WSL machine,
     * doing it across a filesystem boundary.
     */
    const refused = switchRefusal({ meta, saved, target })
    if (refused !== null || saved === null || target === null) {
      /*
       * `switchRefusal` and not `planSwitch` for the question itself, and that
       * distinction cost a live driving run to find. `planSwitch` treats a
       * *missing* decision as a refusal in its own right — deliberately, because
       * "nothing was decided" is not "start it fresh" — so asking it with
       * `decision: null` answers "cannot be started again" about every switch
       * that was going to work perfectly well. The refusals that can be reached
       * without touching a disk are their own function precisely so this pass
       * can ask only them.
       */
      return {
        plan: planSwitch({
          sessionId: id,
          meta,
          saved,
          target,
          decision: null,
          occupied: false,
          // Nothing was decided, so nothing is being said about a conversation.
          sharedStore: false,
        }),
        saved,
        resume: false,
        conversationId: null,
      }
    }

    /*
     * The two accounts are put on one conversation history before anything is
     * asked about it, and that ordering is the whole of the D1 fix.
     *
     *   > *"It's not keeping the conversation history… It should at least keep
     *   > the conversation there, history there, memory there when I switch
     *   > between the accounts."*
     *
     * `adoptSharedHistory` runs at boot and covers every account that exists
     * then; this covers the one added since, and it costs an `lstat` per side
     * when there is nothing to do. It is deliberately *before* `planSaved`,
     * because `planSaved` reads the target account's conversation store to
     * decide whether there is anything to continue — and the answer to that
     * question is different on either side of the link. Asking first and
     * linking afterwards is how the sheet would say "starts a new one" about a
     * switch that then continued the conversation on screen, which is the same
     * failure as the original one with the sign reversed.
     *
     * A write on the path a *plan* takes, and that is intended: the plan is the
     * only route to the switch, both sides are refused unless the link is
     * additive, and the alternative is describing a state the app is about to
     * leave. An account the app must not restructure — another agent's, or a
     * directory somebody pointed at themselves — is left alone and the sheet
     * goes on saying what really happens to it.
     */
    const source = resolveProfile(profilesState(), {
      sessionProfileId: saved.profileId ?? undefined,
      projectPath: saved.cwd,
    })
    if (canJoinSharedHistory(source) && canJoinSharedHistory(target)) {
      try {
        joinSharedHistory(source)
        joinSharedHistory(target)
      } catch (cause) {
        /*
         * A link that could not be made is not a switch that cannot happen.
         * Everything below reads the disk for itself, so failing here leaves
         * the plan describing two separate stores — which is the truth, and is
         * the case the sheet still carries a warning for. Throwing instead
         * would turn "your conversation stays behind" into "the account could
         * not be switched", which is a worse answer to a working switch.
         */
        logger.warn('accounts', 'could not join the shared conversation history', {
          from: source.id,
          to: target.id,
          reason: cause instanceof Error ? cause.message : String(cause),
        })
      }
    }

    const switched: SavedSession = { ...saved, profileId: target.id }
    const [decision] = await planSaved([switched])

    /*
     * Is another tab already on the conversation this one would continue?
     *
     * `conversationScope` is the shared answer to "which transcript would
     * `--continue` attach to" — provider, config directory and folder, which is
     * narrower than a folder and was made narrower because keying on the folder
     * alone silently threw conversations away. Reused rather than re-derived, so
     * the switch and the launch cannot come to disagree about what counts as the
     * same conversation.
     *
     * `planRestore` cannot answer this for a switch: it reasons about a list of
     * *remembered* sessions being started together, and this one is about the
     * tabs open on screen right now. Hence the one extra fact, computed here
     * where the live list is, and applied by `planSwitch`.
     */
    const configDir = decision?.configDir ?? null
    const mine = configDir === null ? null : conversationScope(switched, configDir)
    const occupied =
      mine !== null &&
      core.ledger
        .entries()
        .filter((entry) => entry.id !== id)
        .some(
          (entry) =>
            conversationScope(
              entry.saved,
              resolveProfile(profilesState(), {
                sessionProfileId: entry.saved.profileId ?? undefined,
                projectPath: entry.saved.cwd,
              }).configDir,
            ) === mine,
        )

    /*
     * Do the two accounts read one conversation history?
     *
     * `conversationStore` is the same realpath-and-memo the occupancy check
     * above rests on, asked of both sides rather than of one: an account whose
     * `projects/` has been linked into the shared location by
     * `shared-projects.ts` resolves to the same store as the account it was
     * linked to, and two that have not resolve to two. It decides nothing about
     * what the switch *does* — the continue flag is handed over either way — and
     * everything about what the sheet is allowed to claim, because with one
     * store the conversation the replacement picks up is the conversation on
     * screen, and with two it is a different one that lives in the same folder.
     */
    const sharedStore =
      configDir !== null && conversationStore(configDir) === conversationStore(source.configDir)

    const plan = planSwitch({
      sessionId: id,
      meta,
      saved,
      target,
      decision: decision ?? null,
      occupied,
      sharedStore,
    })

    /*
     * Which conversation the replacement is told to continue.
     *
     * `--continue` means "the folder's newest in the target's store", and the
     * sheet has just promised something narrower than that — the conversation
     * *on screen*. This app knows its id, because it put it on the outgoing
     * process's own command line, so the replacement can name it instead of
     * describing it. The check is the honest half: the transcript has to be
     * readable from the store the replacement will run against, or `--resume`
     * is a process that prints an error and exits. `conversationToCarry` holds
     * the three conditions and is tested on its own.
     *
     * Both spellings of the folder, because on this platform everything under
     * `/tmp` is reached through a symlink and the CLI files a transcript under
     * whichever spelling it was handed.
     */
    const named = meta?.agentSessionId
    const carried =
      configDir === null || typeof named !== 'string'
        ? null
        : conversationToCarry({
            plan,
            agentSessionId: named,
            readableInTarget: projectPathSpellings(saved.cwd).some((spelling) =>
              existsSync(join(transcriptDir(spelling, configDir), `${named}.jsonl`)),
            ),
          })

    return { plan, saved, resume: plan.resume, conversationId: carried }
  }

  /**
   * Run this session as another account: same tab, same folder, new process.
   *
   * ## The order is start, then stop, and that is the point
   *
   * The obvious order is the wrong one. Stopping first and spawning afterwards
   * means a spawn that fails has already destroyed a working session — and
   * `AgentUnavailableError` is thrown *by* the spawn, after probing, so "could
   * this even start?" cannot be answered fully in advance. That is the exact
   * fault that was just fixed on the restore path in the other direction, and
   * the fix there was to keep the request rather than let it evaporate.
   *
   * Here it can be avoided outright, because the two processes cannot collide.
   * They are different accounts, so they are different config directories, so
   * they are different transcript stores — the measurement at the top of
   * `session-switch.ts` is exactly that — and the old session is stopped within
   * a moment of the new one existing. So a switch that cannot start leaves the
   * session it was asked about running, untouched, and the window says why.
   *
   * ## Which is why nothing is held
   *
   * `session:create` holds a request that failed, because there the alternative
   * is a tab that vanished with nothing to show for it. Here the session is
   * still there. A held row saying *"this could not be started"* beside a
   * session that is still running would be the app inventing a loss it did not
   * suffer, and the Try again beside it would start a *second* session rather
   * than retrying anything. The reuse that matters is the sentence:
   * `AgentUnavailableError`'s own message is what the window prints, unchanged,
   * because it is already written for the person who is reading it.
   */
  const perform = async (sessionId: unknown, profileId: unknown): Promise<SessionMeta> => {
    const { plan, saved, conversationId } = await subject(sessionId, profileId)
    if (plan.refusal !== null || saved === null || plan.to === null) {
      throw new Error(plan.refusal ?? 'This session cannot be switched.')
    }

    const meta = await core.startSession({
      cwd: saved.cwd,
      cols: saved.cols,
      rows: saved.rows,
      provider: saved.provider,
      profileId: plan.to.id,
      resume: plan.resume,
      /*
       * The two facts that make the sheet's promise come true, and neither of
       * them existed while this feature was reported broken twice.
       *
       * `replaces` exempts the outgoing session from the one-conversation
       * guard. The order below is start-then-stop, so at this instant there is
       * a live session of the same provider in the same folder, and
       * `one-conversation.ts` — which cannot otherwise tell a replacement from
       * a second tab — dropped `--continue` on every switch ever made. That is
       * the whole of *"it's not keeping the conversation history"*.
       *
       * `resumeConversationId` then makes the resume mean the conversation on
       * screen rather than the folder's newest. Null whenever that could not be
       * established, which falls back to exactly the behaviour above it.
       */
      replaces: plan.sessionId,
      ...(conversationId === null ? {} : { resumeConversationId: conversationId }),
    })

    /*
     * A spawn that succeeded is not yet a session that started.
     *
     * `startSession` resolves the moment the pty exists, and the agent can still
     * refuse a second later — `--continue` against a transcript the CLI declines
     * to continue is a real, reproduced case, and `survivedStart` carries it.
     * Stopping the old session before knowing would leave a dead tab where a
     * working agent was, which is the one outcome this feature must not produce.
     *
     * The replacement is cleaned up rather than left as a corpse: it never
     * became anybody's tab — this handler is the only thing that knows it exists
     * — so leaving it in the ledger would put a phantom session in `openSessions`
     * for the next launch to restore.
     */
    const started = await survivedStart(meta.id, {
      wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      alive: (id) => core.ptys.list().some((session) => session.id === id),
      screen: (id) => core.ptys.scrollback(id),
    })
    if (!started.alive) {
      core.ledger.forget(meta.id)
      core.ptys.kill(meta.id)
      const why = startFailed(plan.to.name, started.said)
      logger.warn('session', `account switch did not take: ${why}`, {
        folder: saved.cwd,
        agent: saved.provider,
        to: plan.to.id,
      })
      throw new Error(why)
    }

    /*
     * Only now. `ledger.forget` as well as the kill, for the reason
     * `session:kill` gives: `onExit` arrives later, and a session that has been
     * deliberately replaced must not sit in the remembered list in the meantime,
     * where a crash inside that gap would bring it back beside its replacement.
     */
    core.ledger.forget(plan.sessionId)
    // `replaced`, not `stopped`: the tab is not going anywhere, only the process
    // inside it. Announcing a removal for the outgoing half would race the
    // window's own swap, which finds the old row by id and leaves the list alone
    // when it cannot — so the losing side of that race is a tab that vanishes in
    // the middle of a switch. See `RemovalReason`.
    core.ptys.kill(plan.sessionId, 'replaced')
    logger.info('session', 'switched account', {
      folder: saved.cwd,
      agent: saved.provider,
      from: plan.from?.id ?? null,
      to: plan.to.id,
      /*
       * What the process got, not what the plan asked for.
       *
       * This read `plan.resume`, and for as long as the guard above was
       * dropping the flag it logged `continued: true` over a replacement that
       * had started a brand-new conversation — the one line anybody
       * investigating would have trusted, agreeing with the sheet and with
       * nothing else. `SessionMeta.resumed` is read off the argument list that
       * was actually spawned.
       */
      continued: meta.resumed === true,
      conversation: conversationId,
    })
    return meta
  }

  /*
   * The verb the wire speaks, wrapped here so both shells hand the same
   * sentences over. The refusal travels as it was written — `perform` throws
   * `plan.refusal` and the CLI's own start failure, and those are already
   * written for the person reading them. `session` on a failure is the id the
   * session still has, because a switch that did not happen left it running.
   */
  const switchAccount = async (sessionId: string, accountId: string): Promise<AccountVerbAnswer> => {
    try {
      const meta = await perform(sessionId, accountId)
      return { ok: true, message: '', session: meta.id }
    } catch (error) {
      const message = error instanceof Error ? error.message : 'That account could not be used.'
      return { ok: false, message, session: sessionId }
    }
  }

  /*
   * Signing one of this machine's logins in, from a pane on another machine.
   *
   * ## Why this opens a terminal instead of running a command
   *
   * Because that is what signing in *is* for every agent this app ships with.
   * `agent-catalog.ts` carries `signInArgs` and `provider-accounts.ts` only ever
   * turns it into a sentence to print, because the flow is interactive: the CLI
   * writes a URL, waits, and finishes when a person has been to it. So the
   * honest act is the one the desktop's own Accounts pane performs — start a
   * session under that account's configuration directory and let the login
   * happen in it — and the id of that session travels back so the window that
   * asked can open it and read the URL, rather than being told to walk to the
   * other machine. On a headless server that is the *only* possible shape: a
   * phone attaches to the answered session and types.
   *
   * ## Why it is not confined, and why that is safe to say
   *
   * A session a *guest* asks for is held inside its granted folder with a home
   * of its own, which is exactly wrong here: a login writes into `~/.claude` or
   * the account's own directory, so a confined one would complete and leave
   * nothing behind. It does not widen anything, because this verb is served to
   * one of the owner's own devices and to nobody else — `CAPABILITY.logins` is
   * stripped for a guest before the frame is ever read (`capabilitiesFor` in
   * `remote/server.ts`), and refused again at the door. *"My device — full
   * access. It's you at another keyboard."*
   */
  const signInAccount = async (accountId: string): Promise<AccountVerbAnswer> => {
    const profile = findProfile(profilesState(), accountId)
    if (profile === null) {
      // The far pane listed this machine's logins a moment ago, so a miss is an
      // account deleted in between — said as what it is rather than as a failure
      // of the sign-in.
      return { ok: false, message: 'There is no such login on this computer any more.', session: null }
    }
    try {
      const meta = await core.startSession({
        // The person's own home directory, which is where a login belongs: it
        // touches the agent's configuration and nothing in any project, and a
        // folder chosen from over there would be this machine opening a terminal
        // somewhere the person did not ask for.
        cwd: homedir(),
        cols: 80,
        rows: 24,
        provider: profile.provider as ProviderId,
        profileId: profile.id,
      })
      hooks.onSessionOpened?.(meta)
      return {
        ok: true,
        // What actually happened, and what to do next. Never "signed in": nobody
        // has typed anything yet, and whether the login succeeds is a question
        // for the next read of this machine's own probe.
        message: `A terminal is open on this computer for ${profile.name}. Finish the login in it.`,
        session: meta.id,
      }
    } catch (error) {
      const message = error instanceof Error && error.message ? error.message : 'That login could not be started.'
      return { ok: false, message, session: null }
    }
  }

  return { subject, perform, switchAccount, signInAccount }
}
