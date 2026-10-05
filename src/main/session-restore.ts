import { realpathSync, statSync } from 'node:fs'
import { access } from 'node:fs/promises'
import { join } from 'node:path'
import type { CreateSessionInput, ProviderId, SessionMeta } from '../shared/types'
import { isWithinRoot } from './fs-tree'
import { currentPlatform, isWindows, type Platform } from './platform/host'
import { newestConversation, projectPathSpellings, transcriptDir, transcriptDirs } from './transcript'
import { isLinuxPath } from './wsl'

/**
 * Recover the conversation and its tab after a restart. The CLI starts as a new
 * process, with the saved conversation id and account folder; it reconstructs
 * its own conversation UI. A killed process, unsaved input and in-flight work
 * cannot be resumed as execution state.
 *
 * Launch recovery requires an exact id. Missing history, an ambiguous legacy
 * record or a duplicate claim is kept for recovery, never replaced with a new
 * conversation. The older folder-latest planner remains for explicit account
 * switches; those callers opt out of exact launch recovery.
 *
 * This module never writes commands or replay text into a process.
 */

/* -------------------------------------------------------------------------- */
/* What is remembered                                                          */
/* -------------------------------------------------------------------------- */

/** A tab's durable identity and the inputs needed to recover its conversation. */
export interface SavedSession {
  /** Exact CLI conversation identity, retained independently of the new process id. */
  agentSessionId?: string
  /** A confirmed model selection for this tab, rather than the account's latest default. */
  model?: string
  cwd: string
  provider: ProviderId
  /** The isolated login this ran as, or null for the default. */
  profileId: string | null
  /**
   * The account whose folder it ran in, when that was not `profileId`'s own —
   * a session switched to another account in place keeps its folder, and so
   * its conversation. Absent for every other session. See
   * `SessionMeta.homeProfileId`.
   */
  homeProfileId?: string
  cols: number
  rows: number
  /**
   * Which tab this was — the one thing here that no amount of looking at the
   * session could work out.
   *
   * ## The pair
   *
   * Two tabs, same agent, same folder, same account, neither typed into. The
   * fields above are identical for both, by construction and in fact, and the
   * window still has to put them back where they were. It used to do that by
   * counting: the strip wrote "the third Claude in `/w`" and matched it against
   * the third Claude this launch happened to announce — so the pair could come
   * back the other way round, and closing the first one moved the second one's
   * number and left the arrangement holding a name for nobody.
   *
   * Position is the only thing derivable, so this stops deriving. `host-core.ts`
   * mints one the first time a session is written into `openSessions`, it is
   * stored here, `restoreOpenSessions` hands it straight back to the spawn, and
   * `SessionMeta.tabKey` carries it into the window — where
   * `renderer/browser/strip-arrangement.ts` uses it and nothing else. A tab's
   * name therefore does not change when its neighbour closes, when its account
   * changes, or when its own process is replaced.
   *
   * ## Why it is not a number, a path or a title
   *
   * Because every one of those moves. A count moves when a sibling closes; a
   * path moves when a folder is renamed; a title is the renderer's and is
   * recomputed from the session's own output on every run. The only name that
   * survives all three is one that means nothing on its own.
   *
   * ## Absent
   *
   * For a list written by a build older than this one, which is the only way it
   * happens: every session written from here on carries one. Such a session
   * still restores exactly as it always did — it is simply given a fresh key on
   * the way back, and is a named tab from that launch onwards. The cost is one
   * launch in which an arrangement saved under the old, counted names does not
   * resolve; nothing is lost but the drag that made it.
   */
  tabKey?: string
  /**
   * Epoch ms this session was last used. Breaks the tie when two tabs share a
   * conversation store — see `conversationScope`, which is narrower than sharing
   * a folder — and only one of them can continue.
   *
   * Approximate by construction, and honestly so: the main process is told when
   * a session is created and when something is typed into it, and never which
   * tab is on screen — that is renderer state and does not cross the bridge. So
   * two tabs a person opened and never typed into carry their start times, and
   * a restore then resets both to the moment they came back. Which of two
   * identical untouched tabs in the same folder inherits the conversation is
   * therefore arbitrary, and it is arbitrary in a way nobody can see: they are
   * the same agent, in the same folder, with nothing in either of them.
   */
  lastSeenAt: number
  /**
   * The device this session is held inside a folder for, when a device started
   * it — the one thing a restore needs to bring it back **as confined as it
   * was**.
   *
   * ## Why it is here and why it is only an id
   *
   * A session a paired device starts is spawned inside a sandbox held to its
   * granted folder. Everything that makes that sandbox — the folder, a home of
   * its own, its own git identity — is a function of this id and the install's
   * storage, so this id is the whole of what has to survive a restart:
   * `host-core.ts`'s `confineForDevice` rebuilds the rest from it. Absent for a
   * session started at the keyboard, which has no boundary and comes back as the
   * ordinary tab it already is.
   *
   * ## Why remembering it was the fix
   *
   * Without it a `SavedSession` was a folder and a provider and no device, so a
   * confined session could not be brought back held — and so it was not brought
   * back at all. That is the whole of *"2 of 6 survive, the rest come back
   * clean"*: the two that survived were started at the desktop, unconfined; the
   * four from his phone were confined and were never written down. With it,
   * `restoreOpenSessions` hands it to a spawn that re-applies the boundary, and
   * a confined session comes back inside the same folder — or, if the boundary
   * cannot be re-established on this machine, does not come back rather than come
   * back loose. It is never put on `CreateSessionInput`: that type crosses the
   * preload bridge, and which device a session belongs to is not something page
   * code may claim.
   */
  confineDeviceId?: string
}

/**
 * The remembered sessions, minus any that are not somebody's tab.
 *
 * ## Why a filter exists at all
 *
 * `openSessions` is a list of what a *person* had open, and for one class of
 * session that was not true. The copilot is a singleton: `ensureCopilot` starts
 * exactly one, in this app's own storage, with an instruction layer and a
 * `--mcp-config` composed at start time. It was also being written into
 * `openSessions` like any tab, because it goes through the same `startSession`.
 *
 * Restoring one of those is not restoring the copilot. A `SavedSession` carries
 * a folder, an agent and an account and nothing else, so what would come back is
 * a plain Claude Code session in `<userData>/copilot` — no layer, no
 * `deck-control` tools, no fence — hidden from the sidebar, because the window
 * filters that folder out, and *billing*. On `DESKTOP-DDGMNCV` there were two of
 * them in `state.json`, because the copilot had been restarted, so every launch
 * would have started two invisible agents alongside the real one.
 *
 * `host-core.ts` stops writing them (see the note about `appComposed` beside
 * `ledger.note`). This is the other half: the entries already on disk, on the
 * machines where it happened, which no amount of not-writing-them-again
 * removes. Filtered rather than migrated, because the ledger rewrites
 * `openSessions` wholesale on the next change — so a launch that skips them is a
 * launch after which they are gone.
 *
 * ## Why only the folder this app owns
 *
 * `folders` is `<userData>/copilot`, and deliberately *not* whichever folder the
 * copilot is currently pointed at. Since the copilot can be given a folder of
 * the person's own, treating "the copilot's folder" as disqualifying would throw
 * away their real sessions in a real workspace the moment they chose it — the
 * app deciding a tab was never theirs. Inside `<userData>` there is no such
 * ambiguity: nothing there is a project, nobody opens a session in it by hand,
 * and anything that ended up on this list from there was put there by this app.
 */
export function personalSessions(
  saved: readonly SavedSession[],
  folders: readonly string[],
): SavedSession[] {
  if (folders.length === 0) return [...saved]
  return saved.filter((session) => !folders.some((dir) => isWithinRoot(dir, session.cwd)))
}

/* -------------------------------------------------------------------------- */
/* Deciding                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Whether there is a conversation on disk to continue.
 *
 * Three-valued on purpose — see fact 3 above. Collapsing `unknown` into either
 * boolean loses the distinction between "checked and there is nothing" and
 * "this agent keeps its history somewhere this app does not read", and those
 * two want opposite behaviour.
 */
export type Conversation = 'found' | 'none' | 'unknown'

export type RestoreOutcome =
  /** Started with the provider's continue flag. */
  | 'resume'
  /** Started, but as a new conversation, because there was none to continue. */
  | 'fresh'
  /** Not started at all. */
  | 'skip'
  /** Meant to start and the spawn threw. */
  | 'failed'

export interface RestoreDecision {
  session: SavedSession
  outcome: RestoreOutcome
  /**
   * Why, in a sentence a person can read.
   *
   * This ends up in the app log, which the user can open from Settings, so it
   * is written for them and not for a stack trace. "ENOENT" is not a reason.
   */
  reason: string
  /**
   * The conversation store this decision was made against.
   *
   * Carried on the decision rather than recomputed by whoever needs it next,
   * and the reason is the whole point of `PlanProbes.configDir`: a profile
   * redirects `CLAUDE_CONFIG_DIR`, so "the transcripts for this folder" has a
   * different answer per login. The replay has to read the file the plan found,
   * because the plan is what decided the CLI would attach to it — and a second
   * resolution of the same question is how the two would end up describing
   * different logins with nothing on screen to say so.
   *
   * Absent when the question was never reached: a folder that is gone, or an
   * agent with no way to continue at all. That is not a missing value to
   * default, it is the honest answer that nothing was asked.
   */
  configDir?: string
  /**
   * What the disk actually said, when it was asked.
   *
   * The reason above is a sentence for a person and is meant to be reworded
   * whenever a better one turns up. This is the same finding as a value, for the
   * one caller that has to *branch* on it — `session-switch.ts`, which has to
   * tell "the other account has a conversation here" apart from "this agent
   * keeps its history somewhere this app cannot read" in order to say the right
   * thing on screen before anything is stopped.
   *
   * It exists because the alternative was matching on the reason string, and a
   * decision that hangs on prose breaks silently the next time somebody improves
   * the prose — in the direction of a confident wrong claim, which is the one
   * direction this file spends its whole length avoiding.
   *
   * Absent exactly when `probes.conversation` was never called: the folder is
   * gone, this agent cannot continue anything, or another tab already holds the
   * claim. Absent is therefore *not* "no conversation" — `'none'` is that — and
   * nothing may read it as such.
   */
  conversation?: Conversation
}

export interface PlanProbes {
  /** Launch recovery must never guess a conversation or silently start over. */
  requireExactConversation?: boolean
  /** Is the folder still there? A volume can be unmounted between runs. */
  folderExists(cwd: string): Promise<boolean>
  /** Does this provider have a way to continue at all? */
  canContinue(provider: ProviderId): boolean
  /**
   * Where this session's agent keeps its history.
   *
   * A probe rather than a constant because a profile moves it: `CLAUDE_CONFIG_DIR`
   * is how an isolated login is isolated, so a session that ran as a profile has
   * its transcripts under that profile's directory and not under `~/.claude`.
   * Answering from the *app's* own config directory — which is what calling
   * `conversationOnDisk` with no second argument does — reports "no conversation"
   * for a profile with years of them, and the tab comes back blank.
   */
  configDir(session: SavedSession): string
  /** Is there a conversation to continue? Only asked when `canContinue`. */
  conversation(session: SavedSession, configDir: string): Promise<Conversation>
}

/**
 * The identity of the conversation `--continue` would attach to.
 *
 * Two sessions may not both be continued exactly when this is equal for both,
 * and it is three things rather than one. Keying on the folder alone — which is
 * what this did first — is never too permissive, only too strict: it groups tabs
 * that share nothing but a directory, and every group it invents costs a real
 * conversation. Two ways that happened:
 *
 *  - **Different agents share a folder.** `codex resume --last` reads Codex's
 *    own store; `claude --continue` reads Claude's. A Codex tab and a Claude tab
 *    in one repo are two independent conversations that cannot collide, yet one
 *    of them was being forced to start clean because the other had the folder.
 *  - **Different profiles share a folder.** The whole point of a profile is a
 *    separate `CLAUDE_CONFIG_DIR`, so a work login and a personal login on the
 *    same repo keep separate transcripts. Same loss, same cause.
 *
 * The separator is a NUL because it cannot occur in a path or a provider id on
 * any platform this runs on, so no pair of different triples can collide by
 * joining into the same string. A plain `:` or `/` can: `provider` `a` with
 * folder `b/c` and provider `a/b` with folder `c` are different sessions.
 */
export function conversationScope(session: SavedSession, configDir: string): string {
  return `${session.provider}\u0000${conversationStore(configDir)}\u0000${session.cwd}`
}

/**
 * The conversation store a config directory actually reads, canonicalised.
 *
 * A config directory *names* a store; it is not the store. Accounts can now
 * share one — `shared-projects.ts`, Option C from `ACCOUNT-MODEL.md` — by each
 * having its `projects/` linked into `~/.claude/projects`, which is what lets a
 * conversation survive a change of account. Keyed on the directory instead, two
 * accounts sharing a history look like two stores, and the
 * one-tab-per-conversation rule in fact 1 above stops applying between them at
 * exactly the moment it matters most.
 *
 * What that costs is not an inconvenience, and it is measured rather than
 * feared. Two sessions continuing one conversation write two branches into one
 * file, under one session id, with every line parsing and no error anywhere:
 *
 *     user  parent=ffa46102  uuid=de3a640d   ONE says alpha
 *     user  parent=ffa46102  uuid=b9680b97   TWO says beta      ← same parent
 *     forked parents (same parent claimed by >1 message): 1
 *
 * Whichever branch `--continue` lands on next silently orphans the other, and
 * nothing downstream can detect that or repair it. It is also **not an account
 * problem**: two sessions of the same account fork a conversation the same way,
 * and did before any of this existed. So it has to be prevented at the point a
 * session is handed `--continue`, and preventing it starts with recognising
 * that two sessions are in one conversation at all. This function is that
 * recognition; `host-core.ts` is where the refusal happens.
 *
 * `realpathSync` and not `resolve`, because `resolve` does not follow a link
 * and following the link is the entire question. A failure falls back to the
 * literal path: a store that does not exist yet is a store nothing else can be
 * in, so a key that groups it with nothing is right rather than degraded.
 *
 * Memoised because this runs once per candidate in `planRestore`'s claim pass
 * and once per open tab in the switch handler's occupancy check — a `realpath`
 * per iteration, for an answer that changes only when somebody presses a button
 * in Settings.
 */
const storeCache = new Map<string, string>()

export function conversationStore(configDir: string): string {
  const cached = storeCache.get(configDir)
  if (cached !== undefined) return cached
  const projects = join(configDir, 'projects')
  let store = projects
  try {
    store = realpathSync.native(projects)
  } catch {
    // Not there yet, or unreadable. The literal path is the honest answer.
  }
  storeCache.set(configDir, store)
  return store
}

/** Drop the memo. Called when an account's history is relinked, and by tests. */
export function resetConversationStores(): void {
  storeCache.clear()
}

/**
 * Turn the remembered tabs into one decision each, in the order they were open.
 *
 * Order matters twice and the two orders are different, which is why this makes
 * two passes. Tabs must come back left to right as they were, so the *output*
 * keeps the input order. But only one tab per folder may be continued (fact 1),
 * and the one that earns it is the one the user touched last — a recency
 * question the input order does not answer. So recency picks the winner first,
 * and the result is then emitted in tab order.
 */
export async function planRestore(
  saved: readonly SavedSession[],
  probes: PlanProbes,
): Promise<RestoreDecision[]> {
  if (probes.requireExactConversation) {
    // Only Claude tabs record their conversation id (and Codex when a switch
    // carried one by id). Every other tab is planned as before: a shell, Gemini
    // or an added agent starts again in its folder, and Codex continues its own
    // latest. Holding them for an id this app never records would hold them forever.
    const loose = await planRestore(
      saved.filter((session) => session.provider !== 'claude' && !session.agentSessionId),
      { ...probes, requireExactConversation: false },
    )
    const looseFor = new Map(loose.map((decision) => [decision.session, decision]))
    const claimed = new Set<string>()
    const decisions: RestoreDecision[] = []
    for (const session of saved) {
      const planned = looseFor.get(session)
      if (planned) {
        decisions.push(planned)
        continue
      }
      if (!(await probes.folderExists(session.cwd))) {
        decisions.push({ session, outcome: 'skip', reason: 'the folder it ran in is no longer on this machine' })
        continue
      }
      if (!session.agentSessionId) {
        decisions.push({ session, outcome: 'skip', reason: 'kept: an older version did not save which conversation this was, so none was guessed. Open Claude in this folder and type /resume to pick it.' })
        continue
      }
      if (!probes.canContinue(session.provider) || (session.provider !== 'claude' && session.provider !== 'codex')) {
        decisions.push({ session, outcome: 'skip', reason: 'the exact conversation was not recorded; kept for recovery instead of starting a new one' })
        continue
      }
      const configDir = probes.configDir(session)
      const key = `${session.provider}\u0000${conversationStore(configDir)}\u0000${session.agentSessionId}`
      const conversation = await probes.conversation(session, configDir)
      if (conversation === 'none' || claimed.has(key)) {
        decisions.push({ session, outcome: 'skip', configDir, conversation,
          reason: conversation === 'none' ? 'the saved conversation is not available; kept for recovery' : 'another tab is already on this exact conversation; kept for recovery' })
        continue
      }
      claimed.add(key)
      decisions.push({ session, outcome: 'resume', configDir, conversation, reason: 'continuing the saved conversation by its exact id' })
    }
    return decisions
  }
  /*
   * The tab that gets to continue, per conversation store. `lastSeenAt`
   * descending, with the earlier tab winning a tie so the answer does not
   * depend on sort stability across engines — two tabs written in the same
   * millisecond is not hypothetical, `rememberOpenSessions` writes the whole
   * list in one pass.
   *
   * `canContinue` is filtered here and not only in the loop below, and that is
   * the fix for a bug rather than a tidy-up. A shell tab has no conversation and
   * no way to continue one, but it was still winning the claim for its folder on
   * recency — so a shell tab touched a minute ago would take the claim, be told
   * further down that it has nothing to continue anyway, and leave the Claude
   * tab beside it starting clean with a full transcript sitting on disk. The
   * conversation was lost to a tab that could never have used it.
   */
  const claim = new Map<string, SavedSession>()
  for (const session of saved) {
    if (!probes.canContinue(session.provider)) continue
    const key = conversationScope(session, probes.configDir(session))
    const held = claim.get(key)
    if (!held || session.lastSeenAt > held.lastSeenAt) claim.set(key, session)
  }

  const decisions: RestoreDecision[] = []
  for (const session of saved) {
    if (!(await probes.folderExists(session.cwd))) {
      decisions.push({
        session,
        outcome: 'skip',
        reason: 'the folder it ran in is no longer on this machine',
      })
      continue
    }

    if (!probes.canContinue(session.provider)) {
      decisions.push({
        session,
        outcome: 'fresh',
        reason: 'this agent has no way to continue a previous conversation',
      })
      continue
    }

    const configDir = probes.configDir(session)
    if (claim.get(conversationScope(session, configDir)) !== session) {
      decisions.push({
        session,
        outcome: 'fresh',
        reason:
          'another tab is already continuing the conversation this one shares, and there is only one to continue',
        configDir,
      })
      continue
    }

    const found = await probes.conversation(session, configDir)
    decisions.push(
      found === 'none'
        ? {
            session,
            outcome: 'fresh',
            reason: 'no earlier conversation was found on disk for this folder',
            configDir,
            conversation: found,
          }
        : {
            session,
            outcome: 'resume',
            conversation: found,
            reason:
              found === 'found'
                ? 'continuing the conversation on disk'
                : // Worded to cover both ways a store can be out of reach — an
                  // agent that keeps its history in a format this app does not
                  // read (Codex) and an agent that ran inside a WSL
                  // distribution, whose history is a Linux file under a home
                  // directory this process was never told. Naming only the
                  // first would put a sentence in the app log that is untrue of
                  // every session on a Windows machine.
                  'continuing — this conversation is kept where the app cannot read it, so the agent was taken at its word',
            configDir,
          },
    )
  }

  return decisions
}

/* -------------------------------------------------------------------------- */
/* The real probes                                                             */
/* -------------------------------------------------------------------------- */

/** Whether a path is still reachable. Any error means no; the reason is not useful here. */
export async function folderExists(cwd: string): Promise<boolean> {
  try {
    await access(cwd)
    return true
  } catch {
    return false
  }
}

/**
 * Is there a conversation on disk for this session?
 *
 * Only Claude Code can be answered honestly: its transcripts are files this app
 * already reads for cost and chat, so the same lookup answers this. A zero-byte
 * file is not a conversation — the CLI creates the file before it has written a
 * turn to it, so counting it would send `--continue` at nothing.
 *
 * `configDir` is a required parameter because a profile redirects
 * `CLAUDE_CONFIG_DIR`, and a session that ran as a profile keeps its transcripts
 * under that profile's directory rather than `~/.claude`. Looking in the wrong
 * one reports "no conversation" for a profile that has years of them, and the
 * tab comes back blank.
 *
 * It is required rather than defaulted because it *was* defaulted, and the
 * default is what shipped the bug: the caller in `index.ts` passed this function
 * by reference, the second argument silently became `undefined`, and every
 * profiled session fell back to the app's own config directory. A parameter with
 * a plausible default is a parameter callers forget, and this one fails quietly
 * — the restore still works, it just works against the wrong login. Making it
 * required moves that from a silent blank tab to a compile error.
 */
export async function conversationOnDisk(
  session: SavedSession,
  configDir: string,
  platform: Platform = currentPlatform(),
): Promise<Conversation> {
  if (session.provider !== 'claude') return 'unknown'
  if (ranInsideWsl(session, platform)) return 'unknown'
  if (session.agentSessionId) {
    // Never substitute a newer transcript when the named one is missing.
    if (!/^[a-zA-Z0-9_-]+$/.test(session.agentSessionId)) return 'none'
    return projectPathSpellings(session.cwd).flatMap((cwd) => transcriptDirs(cwd, { configDir })).some((dir) => {
      try { return statSync(join(dir, `${session.agentSessionId}.jsonl`)).size > 0 }
      catch { return false }
    }) ? 'found' : 'none'
  }
  // The same call the replay makes, on purpose: "is there a conversation" and
  // "which file is it" have to be one lookup, or the tab can be continued
  // against one transcript and painted from another.
  const found = await newestConversation(transcriptDir(session.cwd, configDir))
  return found === null ? 'none' : 'found'
}

/**
 * Did this session's agent run inside a WSL distribution rather than on Windows?
 *
 * A Linux folder on a Windows host is the whole test, and it is the same
 * one-character decision `wsl.ts` makes for routing — deliberately, because a
 * session whose working directory begins with `/` is a session `cmd.exe` cannot
 * open under any circumstance, so it went through `wsl.exe` and its agent ran
 * as a Linux process with a Linux `HOME`.
 *
 * ## Why this exists: "pick up where you left off" worked on the Mac and not on Windows
 *
 * Asad reported it, and it reproduced exactly, on his own PC. Two path faults
 * compose, and either one alone is enough to lose the conversation:
 *
 *  1. **`encodeProjectPath` resolves against the host.** It calls
 *     `path.resolve`, so on Windows `/home/asad/ClaudeKiwi` becomes
 *     `C:\home\asad\ClaudeKiwi` and encodes to `C--home-asad-ClaudeKiwi`. The
 *     agent that actually wrote the transcript was a Linux process and encoded
 *     the same folder as `-home-asad-ClaudeKiwi`.
 *  2. **The config directory is the host's.** `resolveProfile` answers
 *     `C:\Users\<user>\.claude`; the agent's own is `/home/asad/.claude`, inside
 *     the distribution, where Windows has no `.claude` at all.
 *
 * So the lookup asked a directory that cannot exist about a folder name that
 * was never written, got "nothing", and reported `none` — which is a confident
 * claim that there is no conversation to continue. `planRestore` then started
 * every tab clean. His app log says it in those words, twice, once per tab:
 *
 *     [restore] started clean: no earlier conversation was found on disk for
 *     this folder {"folder":"/home/asad/ClaudeKiwi","agent":"claude"}
 *
 * while `/home/asad/.claude/projects/-home-asad-ClaudeKiwi` sat inside the
 * distribution with that morning's conversation in it. On macOS neither fault
 * can fire — the folder is already a host path and the agent is a host process —
 * which is exactly why the feature looked fine on one platform and broken on
 * the other.
 *
 * ## Why the answer is `unknown` and not a corrected lookup
 *
 * `unknown` is not a shrug here, it is this module's third case and it already
 * has a precise meaning: *this agent keeps its history somewhere this app does
 * not read, so take it at its word and continue.* That is literally the
 * situation — the store is inside a Linux filesystem, under a home directory
 * this process has not been told, in a distribution whose name lives on the
 * `WslLink` that `session-restore.ts` has no handle on. Codex is treated the
 * same way for the same reason, and `claude --continue` running *inside* the
 * distribution finds its own transcript without help, because it is a Linux
 * process looking at Linux paths.
 *
 * Answering it properly — reading
 * `\\wsl.localhost\<distro>\home\<user>\.claude\projects\<posix-encoded>` over
 * the UNC path, which is reachable and which the folder check beside this
 * already uses — needs the distribution and its home directory, and both are
 * held by `WslLink` in `src/main/index.ts`. That is a wiring change in a file
 * this change may not touch; it is written up in the report as the follow-up,
 * and it would only add the ability to say "there is genuinely nothing here"
 * rather than change what happens in the case that was broken.
 */
export function ranInsideWsl(session: SavedSession, platform: Platform): boolean {
  return isWindows(platform) && isLinuxPath(session.cwd)
}

/* -------------------------------------------------------------------------- */
/* Doing it                                                                    */
/* -------------------------------------------------------------------------- */

export interface RestoreDeps {
  /** The tabs that were open, oldest tab first. */
  saved: () => readonly SavedSession[]
  /** The Settings switch. Read at launch rather than captured. */
  enabled: () => boolean
  plan: (saved: readonly SavedSession[]) => Promise<RestoreDecision[]>
  /**
   * The one session-start path — `restoreSpawn` in `host-core.ts`, nothing
   * else.
   *
   * `confineToDeviceId` is the second argument rather than a field on the input
   * because the input is `CreateSessionInput`, which crosses the preload bridge,
   * and which device a session belongs to is not something page code may claim.
   * Non-null for a session a device started: the spawn re-applies its folder
   * boundary, or refuses rather than start it unconfined. Null for a tab a
   * person opened here, which starts exactly as before.
   */
  spawn: (input: CreateSessionInput, confineToDeviceId: string | null) => Promise<SessionMeta>
  /** Tell the window a session it did not ask for now exists. */
  announce: (meta: SessionMeta) => void
  /** Where a session that could not come back gets said out loud. */
  report: (decisions: readonly RestoreDecision[]) => void
}

export interface RestoreResult {
  started: SessionMeta[]
  decisions: RestoreDecision[]
}

/**
 * Restore every remembered session, in order.
 *
 * Sequential, not `Promise.all`. Each start shells out twice before it spawns
 * anything — `loginPath` asks the login shell for its PATH and
 * `detectProviders` runs a lookup per CLI — and firing eight of those at once
 * at launch is a burst of subprocesses competing with the window's first paint.
 * In order also means tabs arrive in the window in the order they were in.
 *
 * A start that throws is contained: the remaining sessions still come back, and
 * the failure is turned into a decision so the report says which tab did not
 * make it rather than silently returning a shorter list.
 */
export async function restoreOpenSessions(deps: RestoreDeps): Promise<RestoreResult> {
  const empty: RestoreResult = { started: [], decisions: [] }
  if (!deps.enabled()) return empty

  const saved = deps.saved()
  if (saved.length === 0) return empty

  const planned = await deps.plan(saved)
  const decisions: RestoreDecision[] = []
  const started: SessionMeta[] = []

  for (const decision of planned) {
    if (decision.outcome === 'skip') {
      decisions.push(decision)
      continue
    }

    /*
     * Nothing is painted onto the screen here, and that is measured.
     *
     * This loop briefly seeded each restored session with its own transcript so
     * the terminal would not be blank. It worked and it was invisible: Claude
     * Code switches to the ALTERNATE SCREEN (`ESC[?1049h`, then `ESC[2J`) about
     * half a second after the spawn, so anything seeded into the normal buffer
     * is underneath it for the life of the session. No ordering fixes that —
     * the CLI owns the screen once it starts.
     *
     * It is also unnecessary. `--continue` re-reads the whole transcript and the
     * CLI repaints the conversation itself, which is what the user actually
     * sees; the restore above is what makes that happen. A plain shell has no
     * transcript to replay at all.
     */
    try {
      const meta = await deps.spawn(
        {
          cwd: decision.session.cwd,
          cols: decision.session.cols,
          rows: decision.session.rows,
          provider: decision.session.provider,
          profileId: decision.session.profileId,
          // In the folder it ran in, when that was not its login's own — where
          // the conversation `resume` is about to continue actually lives.
          ...(decision.session.homeProfileId !== undefined
            ? { homeProfileId: decision.session.homeProfileId }
            : {}),
          resume: decision.outcome === 'resume',
          ...(decision.session.agentSessionId ? { resumeConversationId: decision.session.agentSessionId } : {}),
          ...(decision.session.model ? { model: decision.session.model } : {}),
          /*
           * And come back as the *same tab*, not as another one like it.
           *
           * The whole of what `SavedSession.tabKey` is for is this line: without
           * it a restored session is a new tab that happens to hold the same
           * conversation, and the window has nothing to match its saved
           * arrangement against but the order these spawns happen to finish in.
           * Spread rather than passed, because an absent key means "mint one" and
           * `tabKey: undefined` would too — but only one of the two survives a
           * reader who checks for the property.
           */
          ...(decision.session.tabKey !== undefined ? { tabKey: decision.session.tabKey } : {}),
        },
        /*
         * And come back **as confined as it was**. For a session a device
         * started this names the device its folder boundary is rebuilt from;
         * the spawn re-applies it, or refuses rather than start it unconfined.
         * Null for a tab opened at this keyboard — nothing to re-confine.
         */
        decision.session.confineDeviceId ?? null,
      )
      started.push(meta)
      deps.announce(meta)
      decisions.push(decision)
    } catch (err) {
      decisions.push({
        session: decision.session,
        outcome: 'failed',
        reason: `it could not be started again: ${err instanceof Error ? err.message : String(err)}`,
      })
    }
  }

  deps.report(decisions)
  return { started, decisions }
}
