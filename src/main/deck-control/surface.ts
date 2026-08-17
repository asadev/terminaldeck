/**
 * `deck-control` — the contract between the copilot's tools and this app.
 *
 * The copilot is a Claude CLI session with an MCP server attached. That server
 * is the app's own IPC surface, seen from outside the window: it is how the
 * copilot answers "how is that other session doing" and acts on "start a
 * session in this project".
 *
 * ## Why there is an interface here at all
 *
 * Because the alternative is a second backend, and this feature must not have
 * one. Every tool below resolves to a function the app already calls from an
 * `ipcMain.handle` — `store().getProjects()`, `readGitStatus()`,
 * `patchStoredSettings()`, `PtyManager.list()`. Re-implementing any of them so
 * the copilot could reach it would be two answers to the same question, and the
 * two would drift within a release.
 *
 * What the interface buys is that the tool layer has no idea Electron exists.
 * `live-surface.ts` is the only file that imports the app's own modules, so the
 * permission tiers, the confirmation gate and the action log are testable as
 * plain functions with no window, no app object and no spawned process. It is
 * the same seam `platform/paths.ts` argues for at length, for the same reason:
 * the piece that must be exercisable is the piece that decides whether a
 * dangerous call happens.
 *
 * ## The tiers, and why the middle one exists
 *
 * | Tier    | Examples                              | Behaviour                     |
 * |---------|---------------------------------------|-------------------------------|
 * | `read`  | list sessions, read a transcript      | always allowed                |
 * | `act`   | start a session, send to its own      | allowed, logged               |
 * | `alter` | write settings, stop somebody's work  | confirmed by a human, logged  |
 *
 * `act` is not "safe". Starting a session spends money and spawns a process
 * with the user's credentials. It is separated from `alter` because it is
 * *visible and undoable* — a new session appears in the sidebar and can be
 * killed — whereas an `alter` call changes state that nothing on screen would
 * announce. A gate that fires on everything is a gate nobody reads, and
 * confirmation fatigue is the failure mode that turns a permission prompt into
 * a rubber stamp.
 *
 * Every call at every tier is written to the action log. That is not a tier
 * behaviour, it is unconditional; see `action-log.ts`.
 */

import type { CreateSessionInput, ProviderId, SessionMeta, SessionStatus } from '../../shared/types'
import type { ContextUsage, TokenUsage } from '../cost'
import type { AttentionView } from './attention'
import type { TranscriptChoice } from './transcript-match'

/* ------------------------------------------------------------------ tiers -- */

export type Tier = 'read' | 'act' | 'alter'

export const TIERS: readonly Tier[] = ['read', 'act', 'alter']

/**
 * Ranking, so a tier can be compared rather than switched on.
 *
 * Used by the escalation rule on `sessions.send` and `sessions.stop`, which
 * raise a call from `act` to `alter` when the target is not the copilot's own
 * session. Comparing by rank means an escalation can only ever move *up*: a
 * spec that tried to escalate downwards would be refused by `control.ts` rather
 * than quietly weakening its own gate.
 */
export const TIER_RANK: Readonly<Record<Tier, number>> = { read: 0, act: 1, alter: 2 }

/* ------------------------------------------------------------ who is asking -- */

/**
 * Which tiers a caller is allowed to reach at all.
 *
 * Three booleans rather than one "may use the copilot", and the difference is
 * the whole of `COPILOT-CAPABILITIES.md` item 5. A single boolean makes "my
 * phone can ask the copilot how the build is going" and "my phone can rewrite my
 * settings and kill my sessions" the same decision, because the tool names are
 * the same on both surfaces — deliberately, so there is one model to understand
 * — and a grant that names the surface rather than the power hands over all of
 * it.
 *
 * That is not a hypothetical. OpenClaw shipped it: advisory
 * GHSA-943q-mwmv-hhvh (OC-02), where the HTTP gateway did not deny
 * session-orchestration tools by default, so anybody holding gateway auth could
 * call `sessions_spawn` and `sessions_send`. Same tool names, same shape of
 * surface, and the fix there was per-tool denial after the fact.
 *
 * Independent booleans, not a ladder, even though `act` without `read` is a
 * strange thing to grant. A ladder (`maxTier`) would mean the *order* of the
 * tiers is a security property, and the day somebody inserts a tier between two
 * others every existing grant silently widens. Three answers to three questions
 * cannot do that.
 */
export type TierGrant = Readonly<Record<Tier, boolean>>

/** Nothing. What every device has until a person says otherwise. */
export const NO_TIERS: TierGrant = Object.freeze({ read: false, act: false, alter: false })

/** Everything. The person at this keyboard, on this machine. */
export const ALL_TIERS: TierGrant = Object.freeze({ read: true, act: true, alter: true })

/**
 * Where a tool call came from.
 *
 * Carried through {@link DeckControl.call} rather than checked at the transport,
 * for the reason the dispatcher's own header gives: a rule enforced in one
 * transport is a rule the *next* transport does not have. The local copilot
 * passes nothing and gets {@link LOCAL_CALLER}; a relayed call must construct
 * one, and constructing one means answering the tier question.
 */
export interface Caller {
  /** `local` is the copilot session on this machine. `remote` came over the relay. */
  kind: 'local' | 'remote'
  /** The paired device, when the call came from one. Recorded in the action log. */
  deviceId?: string
  /** Which tiers this caller may reach. */
  tiers: TierGrant
}

/**
 * The default, and the only caller that exists today.
 *
 * The local copilot is not exempt from anything — every tier check, budget,
 * confirmation and log entry applies to it exactly as before. It simply has all
 * three tiers available to *ask for*, which is what the local permission model
 * has always assumed and what `alter` needing a human confirmation is for.
 */
export const LOCAL_CALLER: Caller = Object.freeze({ kind: 'local', tiers: ALL_TIERS })

/* -------------------------------------------------------------- refusals -- */

/**
 * Why a call did not happen, when the reason is a rule rather than a fault.
 *
 * Kept as a closed set because these strings land in the action log and in the
 * Activity pane, and "the copilot was refused" is a different row from "the
 * copilot tried something that broke". A free-text message would collapse the
 * two the first time somebody phrased an error as a refusal.
 */
export type RefusalReason =
  /** No window was registered to answer, so nobody could be asked. */
  | 'no-approver'
  /** The person was asked and said no. */
  | 'declined'
  /** The person was asked and did not answer in time. */
  | 'timeout'
  /** The window that was asked went away before it answered. */
  | 'approver-gone'
  /** The app is shutting down; every outstanding question is dropped unanswered. */
  | 'shutting-down'
  /**
   * The copilot hung up while the question was still on screen.
   *
   * This one exists to close a specific and nasty hole. An alter call blocks on
   * a human, and the client on the other end has a timeout of its own. If that
   * timeout fires first the client stops listening — and if the person then
   * clicked Allow, the change would land while the model had already been told
   * the call failed. So a dropped connection cancels the question instead. The
   * answer a person gives after the caller has gone changes nothing.
   */
  | 'caller-gone'
  /** Too many questions are already outstanding. See `consent.ts`. */
  | 'too-many-pending'
  /**
   * An alter-tier call from a run that nobody is watching.
   *
   * A routine firing at 03:00 runs through the copilot with no human anywhere
   * near it, and the alter tier is defined as *a real question put to a real
   * person*. Without this reason the call goes to `ConsentBroker` and waits: two
   * minutes if a window happens to be open and the person is asleep, then
   * `timeout` — a whole agent turn spent, one of the three pending slots held,
   * and a model told its call failed for a reason it cannot fix, which is an
   * invitation to try again.
   *
   * This is not a hypothesis. It is OpenClaw's recorded failure on this machine:
   * a heartbeat session tried to run a script, exec needed approval, a heartbeat
   * cannot get interactive approval, and the run died with `approval-timeout`,
   * then again, then `user-denied` — each failure spending a turn generating an
   * apology. The fix there was to delete the command.
   *
   * So an unattended run is refused at the boundary, immediately, with a
   * sentence that tells the model to *report what it would have done* rather
   * than retry. It is deliberately distinct from `no-approver`: that one means
   * "there is no window", which is a state that fixes itself when somebody opens
   * the app. This one means "this caller can never be approved", which does not.
   */
  | 'not-permitted-unattended'
  /** The copilot is calling faster than the budget allows. */
  | 'rate-limited'
  /** The tool exists but this argument is out of bounds for it. */
  | 'not-permitted'
  /**
   * The caller was never granted this tier.
   *
   * Distinct from `declined`, and the distinction is the point: `declined` is a
   * person saying no to this call, and this is a person having never said yes to
   * this *class* of call. Retrying is pointless, no dialog was drawn and none
   * will be — a grant is changed on the desktop, in Settings, by hand.
   */
  | 'not-granted'

export class Refused extends Error {
  constructor(
    readonly reason: RefusalReason,
    message: string,
  ) {
    super(message)
    this.name = 'Refused'
  }
}

/* -------------------------------------------------------- what tools see -- */

/**
 * A live session, as the copilot is allowed to see it.
 *
 * It carries both the raw {@link SessionStatus} and the derived
 * {@link AttentionView}, and it carries both on purpose. The derived fields are
 * the answer to the question the copilot is actually asked — *which of these
 * needs me* — and the raw status is what anything precise needs: `alerts.ts`
 * keys its blocked rule on `input` exactly, the renderer colours a dot from it,
 * and a tool result that had thrown it away would be forcing every later reader
 * to re-derive something this app already knew. See `attention.ts` for why the
 * two are not the same field under two names.
 */
export interface SessionView extends AttentionView {
  id: string
  cwd: string
  title: string
  provider: ProviderId
  status: SessionStatus
  /** When the session last entered `status`, or when it was created. */
  statusSince: number
  createdAt: number
  exitCode: number | null
  resumed: boolean
  /** The account it runs as, when one applies. Never a credential — a name. */
  profileName: string | null
  /**
   * True when the copilot started this session itself.
   *
   * The whole `sessions.send` / `sessions.stop` tier split hangs off this
   * field. It is tracked by `control.ts` from the ids `sessions.start`
   * returned, in memory, for this run only — not read off `SessionMeta`, which
   * has no such field yet. See `COPILOT-DESIGN.md`, phase 3.
   */
  startedByCopilot: boolean
}

/** Where the last-good copy of the settings was written, and when. */
export interface SettingsSnapshot {
  /** Absolute path of the file. Reported to the copilot so it can name it. */
  path: string
  /** Epoch ms. */
  at: number
}

/** One message of a conversation, trimmed for a tool result. */
export interface TranscriptMessage {
  role: 'you' | 'agent'
  at: number
  text: string
  /** True when `text` was cut to the per-message cap. */
  truncated: boolean
}

/* ------------------------------------------------- what a session has done -- */

/**
 * One tool call in a session's transcript, paired with its result.
 *
 * Name and outcome and nothing else, and that is the whole of what
 * `progress.ts` is allowed to see. The arguments are deliberately absent: one
 * `Write` call carries a megabyte of file content, and a shape that admitted
 * them would put an unbounded allocation on a read path the copilot calls
 * across the whole fleet. See that module's header for what is given up.
 */
export interface ToolEvent {
  /** Epoch ms of the call, or 0 when the line carried no usable timestamp. */
  at: number
  name: string
  /**
   * Did it fail? **Null means the result was not seen**, which is a third
   * answer and not a quiet "no": a call still running, and a call whose result
   * fell outside the window that was read, both land here. Collapsing null into
   * false would make a session that is failing everything look healthy for
   * exactly as long as the window was too short.
   */
  failed: boolean | null
}

/**
 * The tail of what a session has been doing, bounded and honest about it.
 *
 * Bounded the same way `sessions.transcript` is, and for the same measured
 * reason — a transcript on this machine reaches 154 MB — with the same rule
 * that the bound is *reported* rather than hidden. A caller that summarises a
 * window as if it were the session will describe behaviour that never happened.
 */
export interface ToolTrail {
  /** Chronological. At most what fitted in the window. */
  events: ToolEvent[]
  /** Compactions inside the window, oldest first. */
  compactions: Array<{ at: number; preTokens: number; postTokens: number; trigger: string }>
  fileBytes: number
  fromByte: number
  /** True when the window started after byte zero, so this is a tail. */
  partial: boolean
}

/**
 * What a whole session cost, read from its transcript.
 *
 * Deliberately not a price. This repository deleted its rate card — see
 * `transcript.ts`'s `rateKey` — so there is no honest way to say "$6.40", and a
 * number invented here would be a number Asad plans against. Tokens and context
 * occupancy are facts the file carries; dollars are not.
 */
export interface TranscriptTotals {
  requests: number
  usage: TokenUsage
  /** Real models seen, heaviest first. */
  models: string[]
  compactions: number
  /** Occupancy of the context window right now, or null before the first request. */
  context: ContextUsage | null
  startedAt: number
  lastActivityAt: number
}

/* ------------------------------------------------------------- git changes -- */

/** One file git reports as changed, flattened for a tool result. */
export interface ChangedFile {
  path: string
  group: 'staged' | 'unstaged' | 'untracked' | 'conflicted'
  /** `modified`, `added`, `deleted`, `renamed`, … as git classified it. */
  kind: string
  insertions: number | null
  deletions: number | null
  binary: boolean
}

/**
 * A folder's uncommitted state, as the copilot is allowed to see it.
 *
 * Flattened out of `GitStatusResult` rather than passed through, because that
 * type crosses the bridge as `unknown` — the app's own choice, so the two sides
 * cannot drift — and a tool that has to re-narrow an `unknown` before it can
 * count files is a tool doing the surface's job.
 */
export interface RepoChanges {
  repo: boolean
  root: string | null
  branch: string | null
  ahead: number
  behind: number
  files: ChangedFile[]
  /** Why there is nothing to report, when `repo` is false. Null otherwise. */
  reason: string | null
}

/**
 * The app operations the tools need, and deliberately no more.
 *
 * Every method here has exactly one implementation in `live-surface.ts`, and
 * every one of those is a call into a module that already existed. Adding a
 * method is therefore a claim that the app can already do the thing — house
 * rule three, "a tool that cannot do the thing must not exist", enforced at the
 * type level rather than by good intentions.
 */
export interface DeckSurface {
  /* --- sessions ---------------------------------------------------------- */
  listSessions(): SessionMeta[]
  /** Live status, or null when nothing has classified this session yet. */
  sessionStatus(id: string): { status: SessionStatus; at: number } | null
  /**
   * Start a session.
   *
   * `forDevice` is the one argument on this interface that is about *who asked*
   * rather than about what to start, and it exists because a tool's **effect**
   * can be wider for a remote caller than the frames that caller already has.
   *
   * The shape of that bug, stated plainly so nobody removes this argument as
   * redundant: a phone's own `create` frame is narrow by construction —
   * `session-create.ts` checks the folder against that device's grants,
   * `prepareGuestGit` strips this machine's git identity, and on macOS the
   * session is held inside the folder it was given. `sessions.start` did none of
   * that, correctly, because its caller had always been the person at the
   * keyboard. Grant a phone `act` with that unchanged and you have handed it a
   * strictly *larger* power than the New Session button it already has: any
   * folder the desktop happens to have open, with the owner's git credentials,
   * unconfined. That is the OC-02 shape (GHSA-943q-mwmv-hhvh) arriving through
   * the back door — the tool name was gated, the effect was not.
   *
   * So when it is set, the session is started down the *same* path that device's
   * own `create` frame takes: its folder grants, its guest git identity, its
   * confinement. The general rule, worth writing into any tool added later: **a
   * tool's effect for a remote caller may never exceed what that device's own
   * protocol frames already permit.**
   *
   * Optional on the implementation, not on the interface. A host with no remote
   * layer cannot honour it, and {@link DeckSurface.deviceFolders} being absent is
   * how the tool learns that and refuses — rather than answering optimistically,
   * which is the failure this argument exists to prevent.
   */
  startSession(input: CreateSessionInput, forDevice?: string): Promise<SessionMeta>
  /** Raw bytes into a session's pty. `control.ts` decides what may be written. */
  writeToSession(id: string, data: string): void
  killSession(id: string): void
  /** The settled screen of a session, for a provider that writes no transcript. */
  sessionScreen(id: string): Promise<string | null>

  /* --- projects ---------------------------------------------------------- */
  listProjects(): Array<{ path: string; provider?: ProviderId; lastOpenedAt: number }>
  /**
   * The folders one paired device may start a session in.
   *
   * The *same* call `create` is checked against and the same array that device
   * was sent in its `welcome` — `remoteSessionStart` hands both out of one
   * starter, deliberately, because a picker built from a second source is a
   * picker that eventually offers a folder the rule refuses.
   *
   * **Absent is a switch, and its absence must be read as a refusal rather than
   * as permission.** A host with no remote layer cannot answer "may this device
   * use this folder", and the correct behaviour for a host that cannot answer is
   * to refuse the call — not to fall back to {@link listProjects}, which is the
   * desktop's own list and is precisely the wider power a remote caller must not
   * gain. The `devserver` capability makes the same call for the same reason.
   */
  deviceFolders?(deviceId: string): string[]

  /* --- this app's own storage -------------------------------------------- */
  /**
   * `<userData>` — where this app keeps its settings, its state and every
   * session's transcript.
   *
   * Here for one job: refusing to start a session inside it.
   * `COPILOT-CAPABILITIES.md` §3.2 rule 2 makes that a rule rather than a
   * preference, and it is the general form of a recorded failure — an agent
   * pointed at another program's live state directory wrote into it, bypassed
   * that program's validation, corrupted it, and cost a whole recovery session.
   * The check has to happen where the session is started, so the fact has to be
   * reachable from there.
   */
  appStateRoot(): string
  /** `<copilot>` — the copilot's own folder, where briefs are written. */
  copilotRoot(): string

  /* --- git --------------------------------------------------------------- */
  gitStatus(cwd: string): Promise<unknown>

  /* --- alerts ------------------------------------------------------------ */
  alerts(projectPath: string): Promise<unknown>

  /* --- settings ---------------------------------------------------------- */
  readSettings(): { settings: Record<string, string | number | boolean>; preferences: Record<string, unknown> }
  writeSettings(patch: Record<string, unknown>): Record<string, string | number | boolean>
  writePreferences(patch: Record<string, unknown>): Record<string, unknown>
  /**
   * Write the last-good copy of both settings stores, and say where it went.
   *
   * Called before a copilot-originated write reaches the confirmation dialog,
   * never after. See `settings.write`'s precheck in `catalogue.ts` for the whole
   * argument; the short form is that the copilot changing settings is precisely
   * the case where a person needs a way back, and the way back has to exist
   * before the change does.
   *
   * Throws if the snapshot cannot be written. A caller must treat that as a
   * reason not to proceed rather than as a warning to log — a write with no
   * snapshot behind it is the state this exists to prevent.
   */
  snapshotSettings(): SettingsSnapshot

  /* --- transcripts ------------------------------------------------------- */
  /**
   * Every conversation in a folder, with when each began.
   *
   * Not "the newest one", which is what this used to be and what
   * `transcript-match.ts` exists to correct: several sessions share a folder,
   * and handing them all the same file made three of them report a fourth
   * session's work as their own. The choice is made per session, from this
   * list, by a function that says how it chose.
   */
  transcriptsIn(cwd: string): Promise<TranscriptChoice[]>
  /** Size in bytes, so a reader can start near the end instead of at zero. */
  transcriptBytes(path: string): Promise<number>
  /** Parse from a byte offset to the end. Never called with offset zero on a big file. */
  readTranscriptFrom(path: string, from: number): Promise<TranscriptMessage[]>
  /**
   * The tail of a session's tool use, for {@link ToolTrail}.
   *
   * Separate from {@link readTranscriptFrom} even though both read the same
   * file, because they keep opposite halves of it: that one keeps the prose and
   * throws the tool calls away, this one does the reverse. One reader returning
   * both would be a reader whose payload is the whole transcript.
   */
  readToolTrail(path: string, windowBytes: number): Promise<ToolTrail>
  /**
   * What the whole session cost, in tokens.
   *
   * A full-file read rather than a window, and that asymmetry is deliberate:
   * "how is it behaving" is a question about the last few minutes, and "what
   * has it spent" is a question about all of it. A windowed total would
   * under-report, silently, in the direction that makes an expensive session
   * look cheap.
   */
  transcriptTotals(path: string): Promise<TranscriptTotals | null>

  /* --- git --------------------------------------------------------------- */
  /** Uncommitted state of a folder, flattened. See {@link RepoChanges}. */
  gitChanges(cwd: string): Promise<RepoChanges>
  /** Unified diff for one file. '' when there is none or the path is refused. */
  fileDiff(cwd: string, path: string, options: { staged?: boolean; untracked?: boolean }): Promise<string>
  /**
   * When a file was last written, epoch ms, or null when it cannot be told.
   *
   * The whole of the attribution in `fleet-diff.ts` rests on this one number.
   * Null is a real answer and not an error: a deleted file has no mtime, and a
   * change that cannot be dated is reported as unattributed rather than
   * guessed at.
   */
  fileModifiedAt(path: string): Promise<number | null>
}
