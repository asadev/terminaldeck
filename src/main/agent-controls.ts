/**
 * Model, effort and permission-mode controls for a running Claude Code session.
 *
 * ## The rule this module exists to obey
 *
 * There is no API client in this app. The only channel to the agent is the PTY,
 * so a control here is honest exactly when a person could sit at that terminal
 * and type the same thing. Every command below was driven against the real CLI
 * on this machine (`claude 2.1.228`, ~/.local/bin/claude) inside a pty and the
 * replies were read back off a headless terminal. What was verified:
 *
 * | typed              | the CLI answered                                                |
 * |--------------------|-----------------------------------------------------------------|
 * | `/model sonnet`    | `Set model to Sonnet 5 and saved as your default for new sessions` |
 * | `/model default`   | `Set model to Opus 5 (1M context) (default) and saved as …`      |
 * | `/model nosuchmodel` | `Model 'nosuchmodel' not found`                               |
 * | `/effort xhigh`    | `Set effort level to xhigh (saved as your default …): Deeper …` |
 * | `/effort nosuch`   | `Invalid argument: nosuch. Valid options are: low, medium, high, xhigh, max, ultracode, auto` |
 * | `/fast on`         | `Fast mode unavailable: Fast mode requires usage credits · …`    |
 * | `/plan`            | `Enabled plan mode`                                              |
 * | shift+tab          | footer moves auto → manual → accept edits → plan → bypass → auto |
 *
 * A later pass checked the same claims a second way, against the strings and
 * branches inside the shipped binary (`claude 2.1.228`), because one observed
 * run only shows the branch that happened to be taken. That pass found three
 * things a single run could not:
 *
 *   - `/effort auto` answers `Effort level set to auto`, not `Set effort level
 *     to auto`. The words are in the other order, so the Auto option was never
 *     confirmed and reported failure on a change that had been made.
 *   - the "saved as your default" clause is one arm of a branch — the other is
 *     `for this session only`, and `/effort ultracode` always takes it. Scope
 *     is now quoted from the reply instead of asserted.
 *   - a model can be refused four ways, only one of which is `not found`.
 *
 * It also confirmed what was already here: the mode ring really is
 * manual → accept edits → plan → bypass → auto → manual (with stops dropping
 * out when unavailable), nothing in it ever returns `dontAsk`, `\x1b[Z` is what
 * the CLI's key parser reads as shift+tab, and `\r` is what it reads as return.
 *
 * A third pass — the one that wrote the *writing* half of this file — drove the
 * same binary again and found that the first row of that table is only true of
 * a session that has not said anything yet. In a session with even one exchange
 * behind it, `/model sonnet` prints nothing at all and raises a modal
 * `Switch model?` dialog instead, which has to be answered before the model
 * moves. Every session anybody would reach for the picker in is in the second
 * state, so that dialog is the ordinary case rather than the exception, and
 * {@link readModelSwitchDialog} is where it is dealt with. `/effort` was
 * checked in the same session and has no such dialog: it applies immediately
 * and prints its confirmation, exactly as the table says.
 *
 * A fourth pass ran the whole of it on **Windows**, on `DESKTOP-DDGMNCV`, with
 * `claude 2.1.233` spawned the way `providers.ts` spawns it there —
 * `%COMSPEC% /c <cli>` — through `node-pty`'s ConPTY backend and into the same
 * headless emulator. Three things came out of it, and only the first was a bug
 * in this file:
 *
 *   - **The pointer is `❯` or `>`, and which one is a variable rather than a
 *     platform.** Every reading here was written against the Unicode glyph. On
 *     Windows the CLI draws the ASCII one unless `TERM=xterm-256color` is in
 *     the environment — which `pty-manager.ts` does set, so an ordinary session
 *     is fine, and any spawn path that forgets it produces screens on which
 *     every control refuses with "there is nowhere to type that could be
 *     checked first". {@link POINTER} carries both captures, the cause, and why
 *     accepting both is safe.
 *   - **ConPTY echoes the way the protocol needs.** The command written without
 *     a return appeared on the command line as `> /model`, `\r` submitted it,
 *     and `\x15` cleared the line and produced the CLI's own
 *     `Ctrl+Y to paste deleted text` hint — the exact behaviour
 *     {@link CLEAR_COMPOSER} relies on for the rollback. Nothing about the
 *     write path needed a platform branch, and there is none.
 *   - **The permission footer says `⏵⏵ don't ask on (shift+tab to cycle)`**,
 *     which is not one of the five phrases in {@link PERMISSION_MODES}, so
 *     `readPermissionMode` answers null and the mode reads as unknown. That is
 *     a CLI *version* difference rather than a platform one — the same binary
 *     runs on both — so it is recorded here and left for whoever owns that
 *     list, rather than "fixed" from a machine that cannot see the mode it
 *     would be renaming.
 *
 * That last row of the table is the important one. `/permissions` does **not** set the mode —
 * driving it opens a rules browser with Allow/Ask/Deny/Workspace tabs, and the
 * command's own description is "Manage allow and deny tool permission rules".
 * The only in-session way to change the mode is the shift+tab cycle, so this
 * module cycles — but never blind. It presses once, re-reads the footer, and
 * repeats. If it cannot read the mode to begin with it refuses to press at all,
 * because pressing without knowing where you started is guessing.
 *
 * ## Where a "current value" is allowed to come from
 *
 * Only from something real, and the reading always says which:
 *
 *   - `screen`   — the session's own terminal, read through the headless
 *                  terminal `session-activity.ts` already keeps per session.
 *   - `transcript` — `message.model` on the newest assistant line, i.e. the
 *                  model that actually served the last reply.
 *   - `settings` — `settings.json`, which is where the CLI itself persists
 *                  `effortLevel`, `ultracode` and `fastMode`. In *this
 *                  session's* configuration directory, not this app's — see
 *                  {@link SessionAccess.configDir}, which is the whole of what
 *                  keeps the cluster describing the account in front of you.
 *   - `env`      — `CLAUDE_CODE_EFFORT_LEVEL`, which the CLI says overrides
 *                  effort for the session.
 *
 * When none of them answer, the value is `null` and the UI says "unknown".
 * There is no default in this file for anything the user can see.
 */

import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { normalizeModelId, SYNTHETIC_MODEL } from './cost'
import {
  foldDefaultRow,
  isTypeableModelValue,
  readModelPicker,
  FALLBACK_MODELS,
  type ModelRow,
} from '../shared/model-catalog'
import { stripAnsi } from './session-activity'
import { claudeConfigDir, listTranscripts, transcriptDirs } from './transcript'

/* -------------------------------------------------------------------------- */
/* Types                                                                       */
/* -------------------------------------------------------------------------- */

export type ControlId = 'model' | 'effort' | 'fast' | 'permission'

/** Where a displayed value came from. `null` value + `null` source means unknown. */
export type ValueSource = 'screen' | 'transcript' | 'settings' | 'env'

export interface ControlReading {
  /** The machine value, or null when nothing real could be read. */
  value: string | null
  /** What to show. Null when unknown — the UI must not invent one. */
  label: string | null
  source: ValueSource | null
  /** Set when the CLI told us this control is not usable on this account. */
  unavailableReason?: string
}

/**
 * Whether an agent CLI is drawing this session's screen right now.
 *
 * ## Why this is not "did we spawn one"
 *
 * A session started as a plain shell can have an agent running in it — the user
 * types `claude`, or presses Run Claude, and now the pty is a shell with Claude
 * Code in the foreground. And it can stop having one: `/exit` returns the shell,
 * and the session is still alive. `SessionMeta.provider` answers "what did this
 * app launch", which is a different question and stops being the same answer the
 * first time somebody quits the CLI.
 *
 * ## What is actually read, and what it is worth
 *
 * The session's own screen, through the headless terminal `session-activity.ts`
 * keeps per session — the same buffer the permission footer is read off. The
 * markers below were transcribed from a real pty on this machine
 * (`claude 2.1.233`, spawned into `/bin/zsh -l`, screen dumped through the same
 * emulator this app uses), not from documentation:
 *
 *   `╭─── Claude Code v2.1.233 ───…`            the banner, on start
 *   `⏵⏵ bypass permissions on (shift+tab to cycle)`  the footer, while idle
 *   `esc to interrupt`                          the footer, while working
 *
 * The same run established the two things that decide how far this can be
 * trusted. On a clean `/exit` Claude Code **clears the screen** — the dump
 * straight afterwards held nothing but the shell prompt — so a session that has
 * left the CLI stops matching. A CLI that dies without clearing (killed, or
 * aborted at the trust prompt before it has drawn any of this) can leave text
 * behind. Aborting at the trust prompt was checked and is harmless: none of
 * these markers have been drawn at that point.
 *
 * Whether it clears by using the alternate screen buffer depends on the user's
 * own configuration, and an earlier draft of this comment stated flatly that it
 * does not. With `"tui": "fullscreen"` in `settings.json` — which is what this
 * machine has set — the capture shows `\x1b[?1049h` on start and the whole
 * screen reverting on exit. Nothing here depends on which it is, because the
 * emulator these readings come from follows the buffer switch either way, but
 * the claim was wrong and a wrong claim in a comment outlives the code it was
 * written beside.
 *
 * So: a match is strong evidence, and the absence of one is weak. The reading
 * says which, and the caller is expected to treat "no evidence" as "not known"
 * rather than as "no agent".
 *
 * ## The signal this would rather have been
 *
 * The pty's foreground process. `node-pty`'s `IPty.process` answers `zsh` for a
 * plain shell and `2.1.233` while Claude Code is in front of it — Claude Code
 * sets its process title to its version — and it flips back to `zsh` on exit.
 * Driven and confirmed on this machine. That is a fact about the operating
 * system rather than about pixels, and it cannot be faked by leftover text. It
 * needs one accessor on `PtyManager`, which is not this module's file; until
 * that exists, `evidence` is `screen` and never `process`, and nothing here
 * pretends otherwise.
 */
export type AgentEvidence = 'screen' | 'process'

export interface AgentPresence {
  /** True only when something was actually read that says an agent is there. */
  running: boolean
  /** What said so, or null when nothing did. Null is "not known", not "no". */
  evidence: AgentEvidence | null
  /** The line that settled it, verbatim, so a caller can show its working. */
  saw: string | null
}

export const NO_AGENT: AgentPresence = { running: false, evidence: null, saw: null }

/**
 * Whether a command could be typed at this session *right now*, and why not.
 *
 * ## Why the refusal had to become part of the reading
 *
 * {@link refuseToType} has always existed and has always been right, but it was
 * only ever consulted at the moment of the write — so the sequence a person saw
 * was: press the control, wait, read a paragraph explaining that nothing
 * happened. That is acceptable in a panel you opened on purpose. It is not
 * acceptable in the window's own chrome, where the same pickers now sit beside
 * the session's name: a control on a toolbar that looks live, is pressed, and
 * answers "this session is mid-turn" is the dead control this repository keeps
 * being audited for, with an apology attached.
 *
 * So the gate is read where every other value here is read — off the session's
 * own screen, on the same settle-and-re-read the rest of the panel already runs
 * — and the renderer can draw the control as unavailable *before* it is pressed,
 * quoting this sentence. There is exactly one place these words are written
 * (`refuseToType`), so the pre-click reason and the post-click refusal cannot
 * drift into two different explanations of one situation.
 *
 * `canType` is deliberately not the same question as "is an agent running".
 * A session can hold Claude Code and still be un-typeable — mid-turn, or with a
 * dialog up, or with a draft in the composer — and all three are temporary. The
 * renderer is expected to treat this as a *state*, re-read on the next flush of
 * output, and not as a capability.
 *
 * `shift+tab` is the one thing this does not describe: `applyPermission` writes
 * a chord rather than characters, which was measured not to disturb a draft, so
 * a permission control may act while `canType` is false for the reason
 * `typing`. Nothing in the chrome offers permission today; a caller that adds
 * one must read {@link refuseToType}'s own gate rather than this flag.
 */
export interface ControlGate {
  /** True when the composer is empty and unowned, so a command may be typed. */
  canType: boolean
  /** {@link refuseToType}'s own sentence, or null when nothing is in the way. */
  reason: string | null
}

export interface ControlsReading {
  model: ControlReading
  effort: ControlReading
  fast: ControlReading
  permission: ControlReading
  /** False when no live session was addressable, so nothing could be applied. */
  live: boolean
  /** Whether an agent CLI is in the foreground of this session. */
  agent: AgentPresence
  /** Whether a command could be typed at it this instant. See {@link ControlGate}. */
  gate: ControlGate
}

export interface ApplyRequest {
  sessionId: string
  cwd?: string
  control: ControlId
  value: string
  /**
   * What this app launched into the session, when it knows.
   *
   * Absent for a shell somebody started an agent inside — see
   * {@link refuseByProvider}, which is where the absence is resolved. Typed as
   * a plain string rather than as `ProviderId` because it arrives across the
   * IPC bridge from a renderer, and a value that has crossed that bridge is
   * whatever the sender put in it however the type says otherwise.
   */
  provider?: string
  /**
   * Whether this session is on this computer. See {@link ControlScope}.
   *
   * It matters here for the *failure* readings only — the value reported when a
   * change could not be confirmed — but it matters just as much there: an effort
   * change that timed out on a server shell would otherwise come back reporting
   * this laptop's `settings.json`, which is a wrong answer wearing the shape of
   * a right one.
   */
  scope?: ControlScope
}

export interface ApplyResult {
  ok: boolean
  /** What the CLI printed, verbatim, or an explanation of why we did not act. */
  message: string
  /** The reading taken after the change settled. */
  reading: ControlReading
}

/** What this module needs from the session layer. Kept tiny so it is trivially faked. */
export interface SessionAccess {
  /** Type into the session's terminal, exactly as a person would. */
  write(id: string, data: string): void
  /**
   * The session's visible screen once everything written to it has been
   * parsed, or null when there is no such session. Asynchronous because the
   * emulator parses in the background: an unflushed read returns the screen as
   * it was before the last chunk, which reads as "unknown" at exactly the
   * moment the answer has just arrived.
   */
  screen(id: string): Promise<string | null>
  /**
   * Which Claude configuration directory *this session's* agent is reading, or
   * null when nothing has established one.
   *
   * ## The fifth surface
   *
   * Everything in this file that is not read off the screen is read off a file,
   * and until this existed every one of those files was found through
   * `claudeConfigDir()` — the **app process's** `CLAUDE_CONFIG_DIR`, or
   * `~/.claude`. So `settings.json` (effort, fast mode, the model floor),
   * `permissions.defaultMode` and this project's transcripts all answered for
   * one account no matter which account the session in front of you was running
   * as. A person on two logins read the wrong one's model and the wrong one's
   * effort off a cluster describing the session they were looking at, which is
   * the disagreement Asad reported across the account chip, the usage bar and
   * the limit notice — this is the same fault, one control along:
   *
   *   > *"sometimes we are logged in with different account, on top bar it's
   *   > showing something else … all of them are not about one logged in
   *   > account, they should be all aligned."*
   *
   * ## Why it arrives here rather than being looked up
   *
   * Because this module has no session layer of its own and must not grow one.
   * The answer lives in `main/session-account.ts`, which establishes it from
   * this app's own spawn record or from the running agent's environment, and
   * that module reaches Electron, `profiles.json` and the process table — none
   * of which mean anything to the two callers that hand this module a session
   * on *another* computer (`servers/ipc.ts` over SSH) or a faked one (its
   * tests). Optional for exactly those callers: a `SessionAccess` that does not
   * answer leaves every fallback below on `claudeConfigDir()`, unchanged.
   *
   * Null and absent are deliberately the same thing, and both mean "nothing was
   * established". They must never become a *different* store: an account this
   * app cannot name is an unknown account, and turning an unknown account into
   * a wrong one is the bug, not the fix.
   */
  configDir?(id: string): string | null
}

/* -------------------------------------------------------------------------- */
/* Verified option tables                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Permission modes, in the order shift+tab visits them.
 *
 * Order and footer text are transcribed from a real cycle, not from the flag
 * documentation: pressing shift+tab five times from `bypass` produced auto,
 * manual, accept edits, plan, bypass in that order, and the footer strings are
 * copied character-for-character from the rendered screen.
 *
 * `manual` is the odd one out — its footer ends `· ? for shortcuts` rather than
 * `(shift+tab to cycle)`, so matching on the trailing hint would have missed it.
 *
 * `dontAsk` is deliberately absent. `claude --permission-mode` accepts it, but
 * it never appeared in the cycle on this machine, so there is no way to reach it
 * from a running session and offering it would be a control that does nothing.
 */
export const PERMISSION_MODES = [
  { id: 'auto', label: 'Auto', screen: /auto mode on/i },
  { id: 'manual', label: 'Manual', screen: /manual mode on/i },
  { id: 'acceptEdits', label: 'Accept edits', screen: /accept edits on/i },
  { id: 'plan', label: 'Plan', screen: /plan mode on/i },
  { id: 'bypass', label: 'Bypass', screen: /bypass permissions on/i },
] as const

export type PermissionModeId = (typeof PERMISSION_MODES)[number]['id']

/**
 * Effort levels, quoted from the CLI's own rejection of a bad value:
 * `Invalid argument: nosuchlevel. Valid options are: low, medium, high, xhigh,
 * max, ultracode, auto`. Asking the tool what it accepts beats reading docs.
 */
export const EFFORT_LEVELS = [
  { id: 'low', label: 'Low' },
  { id: 'medium', label: 'Medium' },
  { id: 'high', label: 'High' },
  { id: 'xhigh', label: 'Extra high' },
  { id: 'max', label: 'Max' },
  { id: 'ultracode', label: 'Ultracode' },
  { id: 'auto', label: 'Auto' },
] as const

/*
 * `MODEL_ALIASES` used to be here: five hand-written names — default, opus,
 * fable, sonnet, haiku — that `applyControl` compared against before it would
 * type anything. It is deleted rather than left unused, because a stale table
 * nobody reads is how the next person comes to trust it.
 *
 * What replaced it is two things. The *list a user picks from* is read out of
 * the session's own `/model` picker (see {@link discoverModels} and
 * `shared/model-catalog.ts`), so it cannot go stale. The *guard before typing*
 * is `isTypeableModelValue`, which checks the shape rather than the name — a
 * value has to be a single argument with no whitespace and no return in it, and
 * everything past that is the CLI's to refuse in its own words.
 */

/* -------------------------------------------------------------------------- */
/* Screen reading                                                              */
/* -------------------------------------------------------------------------- */

/** Non-empty lines of a screen, oldest first. */
function lines(screen: string): string[] {
  return stripAnsi(screen)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')
}

/**
 * Which permission mode the footer is currently announcing.
 *
 * Only the bottom of the screen is considered. The CLI prints a paragraph
 * explaining auto mode when you enter it, and that paragraph sits in the middle
 * of the screen for the rest of the session — scanning the whole viewport would
 * pin the reading to whatever was last explained rather than what is in force.
 */
export function readPermissionMode(screen: string): PermissionModeId | null {
  const tail = lines(screen).slice(-5)
  for (let i = tail.length - 1; i >= 0; i--) {
    for (const mode of PERMISSION_MODES) {
      if (mode.screen.test(tail[i])) return mode.id
    }
  }
  return null
}

/**
 * Lines only Claude Code draws.
 *
 * Every one is copied from a screen this app's own emulator produced while the
 * CLI was running in a pty — see {@link AgentPresence} for the capture and for
 * what a match is and is not worth.
 *
 * Deliberately narrow. A pattern loose enough to also match, say, the word
 * "claude" in a shell prompt or in a file being `cat`-ed would turn a plain
 * terminal into one wearing an agent's controls, which is the exact complaint
 * this is being written for, inverted.
 */
const AGENT_ON_SCREEN: readonly RegExp[] = [
  // The banner, drawn once on start. Version-agnostic: the box's title is
  // `Claude Code v2.1.233` here and the number will move.
  /╭─+\s*Claude Code v\d/,
  // The footer while it is working. Same string `session-activity.ts` classifies
  // "working" from, for the same reason: it is the CLI's, not the shell's.
  /esc to interrupt/i,
]

/**
 * The hint the CLI prints beside the mode in its idle footer.
 *
 * The mode phrase on its own is not enough to identify Claude Code — `plan mode
 * on` is three ordinary words, and `PERMISSION_MODES` matches it deliberately
 * loosely because by the time *that* is read the screen is already known to be
 * the CLI's. Requiring the hint as well makes the pair a sentence only this CLI
 * writes. Both arms are real: `manual` ends `· ? for shortcuts` while every
 * other mode ends `(shift+tab to cycle)`, which is already recorded above
 * `PERMISSION_MODES` and is why this is two alternatives rather than one.
 */
const FOOTER_HINT = /\(shift\+tab to cycle\)|\? for shortcuts/i

/**
 * The line that says an agent is in front of this session, or null.
 *
 * Only the visible viewport is considered, because that is all the caller
 * passes and all that "right now" can mean — scrollback would keep answering
 * yes for a CLI that exited ten minutes ago.
 *
 * The mode phrases come from `PERMISSION_MODES` rather than being written out
 * again. They are the same strings, read off the same footer, and a second copy
 * here is one that would not be updated the next time the CLI reworded one.
 */
export function readAgentFromScreen(screen: string): string | null {
  for (const line of lines(screen)) {
    for (const pattern of AGENT_ON_SCREEN) {
      if (pattern.test(line)) return line
    }
    if (FOOTER_HINT.test(line) && PERMISSION_MODES.some((mode) => mode.screen.test(line))) {
      return line
    }
  }
  return null
}

/* -------------------------------------------------------------------------- */
/* What owns the keyboard right now                                            */
/* -------------------------------------------------------------------------- */

/**
 * Who the next keystroke would go to, read off the session's own screen.
 *
 * ## Why this had to exist before anything could be typed
 *
 * Everything below writes into a terminal a person is sitting at, and a pty has
 * no notion of "send this to the command line, not to whatever dialog is up".
 * Bytes go to the foreground process and it does with them whatever it is
 * currently doing. So before this app types anything it has to be able to say
 * which of five situations the session is in, and the only witness is the
 * screen.
 *
 * Every state below was produced by driving the real `claude 2.1.233` in a pty
 * on this machine and dumping the same headless emulator `session-activity.ts`
 * keeps per session. Two of them are why the write path used to be unsafe:
 *
 *   `ready`     the pointer on its own between the two rules at the bottom.
 *   `typing`    `❯ remind me to buy milk` — a draft the user has not sent.
 *               Writing `/model sonnet` here does not replace it, it appends:
 *               the composer becomes `remind me to buy milk/model sonnet`.
 *   `choosing`  `❯ 1. Yes, switch to Sonnet 5` over `  2. No, go back`.
 *               A numbered dialog owns the keyboard, and a lone `\r` **answers
 *               it**. That is not hypothetical: while establishing this, a
 *               `/model default\r` sent at a session showing that exact dialog
 *               did not run `/model default` at all — the `\r` picked option 1
 *               and switched the model to Sonnet.
 *   `working`   a turn is in flight.
 *   `unknown`   no prompt found, so there is nowhere safe to aim.
 *
 * Written on a Mac and then driven again on a Windows machine, where the CLI
 * can draw `>` rather than `❯` for the composer and for a dialog's cursor —
 * decided by one environment variable rather than by the platform.
 * {@link POINTER} has both captures and the cause.
 *
 * ## The glyph, and why this is not the shared classifier
 *
 * `classify` in `session-activity.ts` answers a different question — how to
 * colour a tab — and it is deliberately generous, matching shell prompts and
 * several agents' prompt styles. Two of its answers are wrong for this purpose.
 * It calls an empty `❯` composer `waiting` even while a turn is running, which
 * is exactly what a session doing a long tool call looks like once its output
 * settles: caught in that state on this machine, with a `sleep 25` in flight, it
 * reported `waiting`. And it has no state at all for "a dialog is up", which is
 * the single most dangerous one to type into. So the gate is read here, against
 * Claude Code's own screen, and only ever after `readAgentFromScreen` has
 * established that the screen is Claude Code's.
 *
 * `esc to interrupt` is kept as a working marker because it is real — it is
 * what the CLI draws in its default TUI, and the capture that first documented
 * it is quoted above `AGENT_ON_SCREEN`. It is not the only one: with
 * `"tui": "fullscreen"` set, which is what this machine runs, the in-flight
 * line is instead a spinner with a live counter, `✶ Dilly-dallying… (5s · ↓ 90
 * tokens)`, and no `esc to interrupt` appears anywhere on the screen. The
 * counter in parentheses is what separates that from the *finished* line the
 * CLI leaves behind, `✻ Cooked for 1s`, which has no parentheses and must not
 * read as "still working".
 *
 * ## Which way it fails
 *
 * Closed, everywhere. A false `choosing` — an echoed user message that happens
 * to begin `1. ` — refuses a change that would have been safe. A false `ready`
 * would type into somebody's half-written sentence. Only the first of those is
 * recoverable by trying again, so every ambiguity is resolved towards refusing.
 */
export type ComposerState =
  | { kind: 'ready' }
  | { kind: 'typing'; text: string }
  | { kind: 'choosing'; asking: string }
  | { kind: 'working'; saw: string }
  | { kind: 'unknown' }

/**
 * A turn in flight. Every arm is transcribed from a real screen.
 *
 *   `esc to interrupt`                                the default TUI's footer
 *   `✶ Dilly-dallying… (5s · ↓ 90 tokens)`            fullscreen, a few seconds in
 *   `✶ Galloping… `                                   fullscreen, the first frames
 *
 * The third is why the second is not enough on its own: the counter does not
 * appear until several seconds into a turn, and the frames before it carry only
 * the word and the ellipsis.
 *
 * What all three have to be told apart from is the line the CLI leaves behind
 * once it has *finished* — `✻ Baked for 6s`, `✻ Cogitated for 11s` — which wears
 * the same rotating glyph, stays on screen for the rest of the session, and
 * would jam these controls shut permanently if it read as "still working". The
 * ellipsis is the whole difference, and it is required to sit on the first word
 * so that an ordinary `⏺ Started sleep 20 in the background…` bullet does not
 * qualify.
 *
 * ## What this does not catch, said plainly
 *
 * The fullscreen TUI has frames with no marker on them at all. Caught live: a
 * session running a backgrounded shell drew `✻ Baked for 6s · 1 shell still
 * running` over an empty composer, and a model change fired at that moment went
 * through. So this is best effort, and it is deliberately not the thing the
 * safety rests on — see {@link typeCommand}, where the load-bearing guarantee
 * is that the return is not sent until the composer has been seen to hold the
 * command and nothing else. A command that slips through a missed "working"
 * frame is still a command typed on an empty line, which is the same thing a
 * person reaching over and typing it would do.
 */
const WORKING_ON_SCREEN: readonly RegExp[] = [
  /esc to interrupt/i,
  /\(\s*\d+s\s*·\s*[↑↓][^)]*\)/,
  // `>` sits in the exclusion set beside `❯` for the reason `POINTER` gives:
  // they are the same glyph. Without it a draft reading `> Refactoring…` on a
  // Windows session would be classified as a turn in flight.
  /^(?![⏺⎿❯>│╭╰])\S\s+[A-Za-z][A-Za-z-]*…/,
]

/**
 * The cursor glyph the CLI draws, which is two glyphs.
 *
 * ## Measured, on his Windows machine, through the app's own spawn line
 *
 * Every reading in this file was written against `❯`. On Windows the same CLI
 * can draw `>` instead. Captured on `DESKTOP-DDGMNCV` with `claude 2.1.233`
 * spawned exactly the way `providers.ts` spawns it there — `%COMSPEC% /c <cli>`
 * — through `node-pty`'s ConPTY backend, into the same `@xterm/headless`
 * terminal `session-activity.ts` keeps per session, read with the same
 * `translateToString(true)`. Twice, from one spawn line, with `TERM` as the
 * only difference between the runs:
 *
 *     with TERM=xterm-256color        with TERM unset
 *     ──────────────────────────      ──────────────────────────
 *     ❯ /model                        > /model
 *     ──────────────────────────      ──────────────────────────
 *       ⏵⏵ don't ask on (shift+tab to cycle) · ← for agents
 *
 * and, with the model picker up:
 *
 *     ❯ 1. Default (recommended) ✔    > 1. Default (recommended) √
 *       2. Opus (1M context)            2. Opus (1M context)
 *
 * `agent-controls.conpty.json` holds both sets in full, and
 * `agent-controls-conpty.test.ts` runs these readers over every screen in both.
 *
 * ## Why it is not ConPTY, not a font, and not the platform either
 *
 * It is the CLI choosing an ASCII glyph set, and the switch is one environment
 * variable. The `√` beside the selected model is the giveaway: that is
 * `U+221A`, the `figures` package's Windows fallback for `tick`, where a Mac
 * shows `✔`. The shipped binary carries both tables — the Unicode one with
 * `pointer: "❯"` and the fallback beside it — and picks the fallback when the
 * terminal does not advertise Unicode support, which on Windows means no
 * `WT_SESSION`, no `TERM_PROGRAM`, and no `TERM=xterm-256color`.
 *
 * **`pty-manager.ts` sets `TERM=xterm-256color` on every session this app
 * starts, so a Terminal Deck session on Windows draws `❯` and these readers
 * were never dead there.** That is stated flatly because the first capture of
 * this was taken by a probe that did not set `TERM`, and it looked exactly like
 * a platform bug. The two runs were then taken from the same spawn line with
 * that one variable as the only difference, and the glyph followed it; the
 * pty's `name` was `xterm-256color` in both and moved nothing.
 *
 * ## So why accept both, if the app always sets `TERM`
 *
 * Because "the app always sets `TERM`" is a fact about one line in one other
 * file, and this file's readings fail *silently* when it stops being true:
 * `readComposer` finds no composer, answers `unknown`, and `refuseToType` says
 * *"This session's prompt is not on screen, so there is nowhere to type that
 * could be checked first"* — to every model, effort and fast-mode change, with
 * no hint that a variable is missing. Nothing unsafe happens, because the
 * return is not sent until the composer has been *seen* to hold the command.
 * The control simply stops working and explains itself badly.
 *
 * A spawn path that does not go through `pty-manager.ts` is not hypothetical —
 * the sign-in probes, the headless host and anything future that opens its own
 * pty are all one forgotten variable away from that state. Two characters here
 * make the reading independent of it.
 *
 * ## Why accepting both is safe rather than merely convenient
 *
 * `>` is a common first character — a markdown blockquote in an answer is the
 * obvious collision — and the answer is that every direction it can be wrong in
 * is already closed:
 *
 *  - The composer is read **from the bottom**, and the composer is the CLI's
 *    own bottom band. A blockquote in an answer is above it, so it is never the
 *    line this picks.
 *  - A blockquote that somehow *were* picked reads as `typing`, which refuses.
 *  - A `> 1. …` in an answer reads as `choosing`, which refuses. That is the
 *    same trade the `❯` version already made and documented: a false `choosing`
 *    costs a retry, a false `ready` costs somebody's sentence.
 *
 * Not written as a single "any pointer" class, because these are the two the
 * `figures` table can produce and a third would be a fact somebody has to go
 * and measure rather than guess.
 */
const POINTER = '[❯>]'

/**
 * A numbered dialog with the cursor sitting on one of its rows.
 *
 * The pointer is load-bearing. Claude Code prints numbered lists in its
 * *answers* all the time, and a pattern without the cursor marker would read
 * every one of them as a dialog and refuse to change the model for the rest of
 * the session. With it, the match is the selection cursor, which only a dialog
 * draws.
 */
const CHOICE_LINE = new RegExp(`^${POINTER}\\s*\\d+\\.\\s+\\S`)

/** The composer's own line: the pointer, then whatever is being typed at it. */
const COMPOSER_LINE = new RegExp(`^${POINTER}(.*)$`)

export function readComposer(screen: string): ComposerState {
  const all = lines(screen)

  // Checked before the composer, because a dialog's own selected row starts
  // with the same pointer the composer does and would otherwise be mistaken for
  // a prompt holding the text "1. Yes, switch to Sonnet 5".
  for (const line of all) {
    if (CHOICE_LINE.test(line)) return { kind: 'choosing', asking: line }
  }

  for (const line of all) {
    for (const pattern of WORKING_ON_SCREEN) {
      if (pattern.test(line)) return { kind: 'working', saw: line }
    }
  }

  // From the bottom. Every message the user has already sent is echoed into the
  // scroll area behind its own pointer, so the first one found from the top is
  // the oldest thing they typed rather than the line they are typing on now.
  for (let i = all.length - 1; i >= 0; i--) {
    const match = COMPOSER_LINE.exec(all[i])
    if (!match) continue
    const text = match[1].trim()
    return text === '' ? { kind: 'ready' } : { kind: 'typing', text }
  }

  return { kind: 'unknown' }
}

/**
 * The confirmation the CLI raises before it will change the model — or the
 * effort level — of a conversation that already has history.
 *
 * This is the discovery that made the old write path a defect rather than
 * merely a rough edge. `/model sonnet` typed at a *fresh* session applies
 * straight away and prints `Set model to Sonnet 5 …`, which is what the table
 * at the top of this file records. Typed at a session that has exchanged even
 * one message — which is every session by the time somebody reaches for the
 * picker — it prints nothing and puts up this instead:
 *
 *     Switch model?
 *     Your next response will be slower and use more tokens
 *
 *     This conversation is cached for the current model. Switching to Sonnet 5
 *     means the full history gets re-read on your next message.
 *
 *     ❯ 1. Yes, switch to Sonnet 5
 *       2. No, go back
 *
 * So the old code waited six seconds for a line that was never coming, reported
 * "the CLI has not answered yet — it may be mid-turn", and left that dialog
 * sitting on the user's terminal for the next keystroke to answer.
 *
 * ## Effort raises the same thing, and that was found the same way
 *
 * A first pass here handled only the model, on the assumption that `/effort`
 * was the simple case because one run of it had applied immediately. Driven
 * against a live session it produced, verbatim:
 *
 *     Change effort level?
 *     Your next response will be slower and use more tokens
 *
 *     This conversation is cached for the current effort level. Switching to
 *     xhigh means the full history gets re-read on your next message.
 *
 *     ❯ 1. Yes, switch to xhigh
 *       2. No, go back
 *
 * Same shape, different heading, and it is the prompt cache rather than the
 * setting that decides whether it appears — so whether a given `/effort` gets
 * one is not a property of the level, and cannot be predicted from the request.
 *
 * Note what that reply is called: the command typed was `/effort ultracode` and
 * the dialog names `xhigh`, because ultracode *is* xhigh plus workflows. That
 * is why the target read here is reported rather than checked against the
 * request — a mismatch is the CLI being more precise than the alias, not a sign
 * that the wrong dialog is on screen.
 *
 * ## What has to be true before return is pressed at one
 *
 * Both halves must match. A heading alone would also match the paragraph
 * explaining it; the `Yes` row alone is a shape other dialogs share, including
 * every permission prompt. Requiring the heading **and** the cursor already
 * resting on a row that reads "Yes, switch to …" is what makes pressing return
 * a confirmation of the thing the user clicked rather than a guess at somebody
 * else's question. If the cursor is on "No" instead, this answers null and the
 * caller refuses: moving a selection this app can only partly see would be
 * guessing twice.
 */
export type SwitchDialogKind = 'model' | 'effort'

const SWITCH_HEADINGS: ReadonlyArray<{ kind: SwitchDialogKind; heading: RegExp }> = [
  { kind: 'model', heading: /^Switch model\?$/i },
  { kind: 'effort', heading: /^Change effort level\?$/i },
]

export function readSwitchDialog(screen: string): { kind: SwitchDialogKind; target: string; asking: string } | null {
  const all = lines(screen)
  const heading = SWITCH_HEADINGS.find((entry) => all.some((line) => entry.heading.test(line)))
  if (!heading) return null
  for (const line of all) {
    const match = /^❯\s*1\.\s*Yes,\s*switch to\s+(.+?)$/i.exec(line)
    if (match) return { kind: heading.kind, target: match[1].trim(), asking: line }
  }
  return null
}

/**
 * How many times a confirmation for this control is on screen.
 *
 * The reason is a bug that only shows up when a control is used the way a
 * person actually uses one: pick Low, then pick Low again. The screen already
 * holds `Set effort level to low …` from the first time, so a check of the form
 * "is the level now low?" is satisfied by the *old* line before the second
 * command has even been parsed, and the panel reports a success that nothing
 * caused. The same hole let the model picker report failure in the mirror case
 * — asking for the model it was already on produced an identical confirmation
 * line, "the value did not change", and a six-second timeout.
 *
 * Counting settles both. A new confirmation is a new line, whatever it says.
 */
function countMatches(screen: string, pattern: RegExp): number {
  return lines(screen).join('\n').match(pattern)?.length ?? 0
}

const MODEL_CONFIRMATION = /(?:Set model to|Kept model as)\s+\S/gi
const EFFORT_CONFIRMATION = /(?:Set effort level to|Effort level set to)\s+\S/gi
const FAST_ANNOUNCEMENT = /Fast mode (?:ON|OFF|unavailable|is not available)/gi

export function countModelConfirmations(screen: string): number {
  return countMatches(screen, MODEL_CONFIRMATION)
}

export function countEffortConfirmations(screen: string): number {
  return countMatches(screen, EFFORT_CONFIRMATION)
}

export function countFastAnnouncements(screen: string): number {
  return countMatches(screen, FAST_ANNOUNCEMENT)
}

/* -------------------------------------------------------------------------- */
/* Which CLIs this can speak to at all                                         */
/* -------------------------------------------------------------------------- */

/**
 * Why these controls cannot act on this session, or null when they can.
 *
 * ## This module speaks one CLI
 *
 * Everything in this file is Claude Code's: `/model` and `/effort` and the
 * aliases they take, the exact wording of the confirmations that are matched to
 * decide whether a change landed, the shift+tab ring, the `Switch model?`
 * dialog, `~/.claude/settings.json` and the `permissions.defaultMode` written
 * in it. None of that is a general fact about agent CLIs; it is a transcript of
 * one binary's behaviour on this machine.
 *
 * Codex and Gemini were looked at rather than assumed about, and neither could
 * be driven here: the Codex install on this machine is broken (its vendored
 * binary is missing — `spawn …/codex-darwin-arm64/vendor/…/codex ENOENT`) and
 * the Gemini CLI stops on an unanswered "How would you like to authenticate"
 * picker. So this app has **no** verified account of how either changes a model
 * at runtime, and the honest consequence is not to guess: typing Claude's
 * commands at them would at best do nothing and at worst submit `/model sonnet`
 * to another model as a prompt. The controls are withdrawn with this sentence
 * instead, which says what is true — that the mechanism has not been
 * established for them — rather than claiming they have no mechanism.
 *
 * ## The undefined case is not a hole
 *
 * `provider` is absent for a session this app launched as a shell that somebody
 * has since started an agent inside — `ChatView` deliberately passes `undefined`
 * there, because the app never saw which CLI was typed. That is answered by the
 * screen rather than by the record, and the screen is decisive in exactly the
 * direction needed: the markers `readAgentFromScreen` matches are Claude Code's
 * banner and Claude Code's footer, so a match *is* the identification. No
 * match, no writing.
 */
export function refuseByProvider(provider: string | undefined, agent: AgentPresence): string | null {
  if (provider === 'claude') return null
  if (provider === 'shell') {
    return 'This session is a shell, not an agent CLI, so there is nothing in it to set a model on.'
  }
  if (provider === undefined) {
    return agent.running
      ? null
      : 'Nothing on this session’s screen says Claude Code is running in it, and these controls are Claude Code’s commands.'
  }
  const named = provider === 'codex' ? 'Codex' : provider === 'gemini' ? 'Gemini' : provider
  return `These type Claude Code’s own commands into the session. How ${named} changes this at runtime has not been established, so nothing is sent rather than something being guessed at.`
}

/**
 * How far the CLI said a change reaches. It prints this itself, in the same
 * line as the confirmation, and it is a branch rather than a constant:
 *
 *   `Set model to X` + (` and saved as your default for new sessions` | ` for this session only`)
 *   `Set effort level to X` + (` (saved as your default for new sessions)` | ` (this session only)`)
 *
 * Both alternatives are in the shipped binary. So the scope is read, never
 * assumed — the UI has no business claiming "saved as your default" when the
 * CLI just said "for this session only".
 */
export type ConfirmationScope = 'default' | 'session'

function scopeOf(tail: string): ConfirmationScope | null {
  // Model says "and saved as your default …"; effort says "(saved as your
  // default …)". Matching the model's leading "and" silently lost every effort
  // confirmation, so only the shared part is matched.
  //
  // And only the *distinctive* part of it: these lines wrap in an 80-column
  // terminal, and the real capture routinely ends "…and saved as your default
  // for" with "new sessions" on the row below. Requiring the full phrase read
  // the wrapped case as "no scope stated", which is safe but silent. Anything
  // shorter than this still cannot collide — the alternative arm shares no
  // words with it.
  if (/saved as your default/i.test(tail)) return 'default'
  if (/\bthis session\b/i.test(tail)) return 'session'
  return null
}

export const SCOPE_TEXT: Record<ConfirmationScope, string> = {
  default: 'saved as your default for new sessions',
  session: 'this session only',
}

/**
 * The model named by the CLI's own confirmation line, and how far it reaches.
 *
 * Both wordings appear: `Set model to X and saved as …` after a change, and
 * `Kept model as X` after cancelling the picker. The name stops at whichever
 * scope clause follows it — `and saved …` or `for this session only`. Stopping
 * only at `and saved` (an earlier draft) swallowed the second clause and put
 * "Sonnet 5 for this session only" on the button as if that were a model name.
 *
 * The name itself keeps its parentheses and spaces, because
 * `Opus 5 (1M context) (default)` is a real answer and a tighter pattern loses
 * the part that distinguishes Default from Opus.
 */
export function readModelConfirmation(screen: string): { name: string; scope: ConfirmationScope | null } | null {
  const text = lines(screen).join('\n')
  const matches = [
    ...text.matchAll(/(?:Set model to|Kept model as)\s+(.+?)(?:\s+and saved\b|\s+for this session only\b|$)([^\n]*)/gim),
  ]
  const last = matches[matches.length - 1]
  if (!last) return null
  const name = last[1].trim()
  if (name === '') return null
  return { name, scope: scopeOf(`${last[0]}`) }
}

export function readModelFromScreen(screen: string): string | null {
  return readModelConfirmation(screen)?.name ?? null
}

/**
 * The effort level named by the CLI's confirmation line, and how far it reaches.
 *
 * Two wordings, both taken from the binary rather than from one observed run:
 *
 *   `Set effort level to xhigh (saved as your default for new sessions): Deeper…`
 *   `Set effort level to ultracode (this session only): xhigh + dynamic workflow…`
 *   `Effort level set to auto (this session only)`
 *
 * That third one is the reason this function exists in this shape. `/effort auto`
 * does **not** answer "Set effort level to auto" — the words are in the other
 * order — so a pattern built only from the first wording never confirms Auto,
 * and the Auto option sat there timing out and reporting failure on a change
 * that had in fact been made.
 */
export function readEffortConfirmation(screen: string): { level: string; scope: ConfirmationScope | null } | null {
  const text = lines(screen).join('\n')
  const matches = [...text.matchAll(/(?:Set effort level to\s+([a-z]+)|Effort level set to\s+(auto))([^\n]*)/gi)]
  const last = matches[matches.length - 1]
  if (!last) return null
  const level = (last[1] ?? last[2]).toLowerCase()
  return { level, scope: scopeOf(last[0]) }
}

export function readEffortFromScreen(screen: string): string | null {
  return readEffortConfirmation(screen)?.level ?? null
}

/**
 * The lightning bolt Claude Code draws in its status rule while fast mode is on.
 *
 * ## The measurement this replaced a written-down assumption with
 *
 * This file used to say that fast mode could not be read at all — that the CLI
 * "announces fast mode only when it changes", so a session nobody had toggled it
 * in had nothing on screen to report and the control said `Not reported` for the
 * whole of its life. That was the state Asad found it in:
 *
 *   > *"Fast mode is here, but I can see if the fast mode is available in app,
 *   > why is it not available in CLI in this terminal? Just look at this — if it
 *   > is available then let's bring it here, otherwise remove it completely."*
 *
 * So it was driven, on `claude 2.1.234`, and the assumption was wrong. `/fast
 * on` answers `⎿  ↯ Fast mode ON · $10/$50 per Mtok` **and leaves the `↯` in the
 * rule directly above the command line**, where it stays for as long as fast
 * mode is on. `/fast off` answers `⎿  Fast mode OFF` and the glyph goes. Then a
 * brand-new `claude` process, started with fast mode left on, booted with the
 * `↯` already drawn and no command typed at all — which settles the other half:
 * the setting outlives the session, and it is legible at any moment rather than
 * only at the instant it changes.
 *
 * Both screens are in `cli-screens.capture.json`, and `agent-controls.test.ts`
 * reads the state back out of them, so the day the CLI stops drawing this the
 * test says so instead of the app quietly reporting "off" for ever.
 */
const FAST_GLYPH = '↯'

/**
 * The rule the CLI draws between its transcript and the command line.
 *
 * A run of box-drawing dashes that may have a sentence set into it — the update
 * notice lives there, and so does the `↯`. Matched from the start and the end so
 * that a line of dashes inside somebody's *answer* (a markdown horizontal rule,
 * which the CLI renders exactly this way) cannot be mistaken for it: those are
 * not the line immediately above the composer, which is the only place this is
 * ever looked for.
 */
const STATUS_RULE = /^─{10,}.*─$/

/**
 * Whether fast mode is on right now, read from the rule above the command line.
 *
 * Returns null rather than guessing when the rule cannot be found — an older
 * CLI that does not draw it, a screen caught mid-repaint, a session that is not
 * Claude Code at all. That distinction is the whole safety of this: `↯` present
 * means on, `↯` absent **from a rule that was actually located** means off, and
 * "no rule" means nothing is claimed. Treating the third case as "off" would
 * turn every unreadable screen into a confident and wrong reading, which is the
 * failure this module is arranged against.
 *
 * Only the three lines above the composer are searched. The CLI draws a second
 * rule *below* the command line which never carries the glyph, so a search from
 * the bottom of the screen would find that one and report "off" always; and the
 * hint row (`✦ ultracode · xhigh effort …`) can sit between the rule and the
 * composer, which is why it is three rather than one.
 */
export function readFastIndicator(screen: string): 'on' | 'off' | null {
  const all = lines(screen)
  let composer = -1
  for (let i = all.length - 1; i >= 0; i--) {
    if (COMPOSER_LINE.test(all[i])) {
      composer = i
      break
    }
  }
  if (composer < 1) return null

  for (let i = composer - 1; i >= 0 && i >= composer - 3; i--) {
    if (STATUS_RULE.test(all[i])) return all[i].includes(FAST_GLYPH) ? 'on' : 'off'
  }
  return null
}

/**
 * Fast mode as the CLI last reported it: on, off, or refused.
 *
 * The refusal is a real answer and is kept, because a control that reports
 * "Fast mode requires usage credits" is useful and a control that silently
 * stays off is a lie.
 */
export function readFastFromScreen(screen: string): ControlReading | null {
  const text = lines(screen).join('\n')
  const refused = /Fast mode (?:unavailable|is not available)[:.]?\s*(.*)$/im.exec(text)
  if (refused) {
    return {
      value: 'off',
      label: 'Off',
      source: 'screen',
      unavailableReason: refused[1].trim() || 'Fast mode is not available on this account',
    }
  }
  const toggled = [...text.matchAll(/Fast mode (ON|OFF)\b/g)]
  const last = toggled[toggled.length - 1]
  if (!last) return null
  const on = last[1] === 'ON'
  return { value: on ? 'on' : 'off', label: on ? 'On' : 'Off', source: 'screen' }
}

/**
 * Everything the screen knows about fast mode, in one answer.
 *
 * Two readings, and they answer different questions. {@link readFastIndicator}
 * says what is true **now**; {@link readFastFromScreen} says what the CLI last
 * *said*, which is where a refusal like "Fast mode requires usage credits"
 * lives. The state has to come from the first, because an announcement scrolls
 * up the screen and eventually off it while the glyph stays; the reason has to
 * come from the second, because the glyph carries no reason.
 *
 * A refusal on screen with no glyph beside it is fast mode off *and* the account
 * being told why it cannot be on, and both halves are kept. A refusal on screen
 * with the glyph present is stale — it belongs to an earlier attempt that has
 * since succeeded — so the reason is dropped rather than shown over a control
 * that is plainly working. That is not hypothetical tidiness: a session
 * accumulates its refusals, and this module has already shipped one bug where an
 * old "Fast mode requires usage credits" made a change made minutes later report
 * failure.
 */
export function readFast(screen: string): ControlReading | null {
  const announced = readFastFromScreen(screen)
  const now = readFastIndicator(screen)
  if (now === null) return announced

  const reading: ControlReading = {
    value: now,
    label: now === 'on' ? 'On' : 'Off',
    source: 'screen',
  }
  if (now === 'off' && announced?.unavailableReason) reading.unavailableReason = announced.unavailableReason
  return reading
}

/**
 * The CLI's reply to a slash command we just typed, if it has landed yet.
 *
 * Every pattern is a string the shipped binary can actually print. The list is
 * longer than the obvious one because a refusal this app does not recognise is
 * not harmless: `applyControl` then waits out its whole timeout and reports
 * "the CLI has not answered yet", which is a worse lie than the refusal itself.
 * `Model 'x' not found` is only one of four ways a model can be turned down.
 */
const COMMAND_ERRORS: readonly RegExp[] = [
  /Model '[^']*' not found[^\n]*/gi,
  /Model '[^']*' is not in the list of available models/gi,
  /Model '[^']*' is restricted by your organization's settings[^\n]*/gi,
  // Caught by driving the real binary rather than by reading anything:
  // `/model claude-mythos-5` answered `Mythos 5 isn't available for your
  // account yet. Run /model to pick another model.` — a refusal in a shape
  // none of the patterns above matches, so before this line the picker waited
  // out its whole timeout and reported "the CLI has not answered yet" over a
  // perfectly clear explanation the CLI had already given.
  //
  // The lookbehind is the difference between this and its neighbours, and it is
  // here because this one is an ordinary English sentence: a reply *discussing*
  // model availability contains it word for word, and the others at least
  // require quoted model names. So it only counts at the start of a line or
  // immediately after the CLI's own `⎿` result gutter, which is where the CLI
  // puts a command's answer and where a paragraph of prose never begins.
  /(?<=^|⎿ {1,3})[A-Z][A-Za-z0-9 .+-]{0,40} isn't available for your account yet\.[^\n]*/gim,
  /Failed to validate model:[^\n]*/gi,
  /Invalid argument:[^\n]*/gi,
  /Unknown model '[^']*'/gi,
  /Fast mode unavailable:[^\n]*/gi,
  /Failed to set effort level:[^\n]*/gi,
  /Effort '[^']*' exceeds your organization's limit[^\n]*/gi,
  /Ultracode [^\n]*Valid options are:[^\n]*/gi,
  // Both of these say the change was accepted and then overridden, so they
  // are failures from the user's point of view even though they read calmly.
  /(?:Cleared effort from settings|Effort set to auto for this session), but CLAUDE_CODE_EFFORT_LEVEL=[^\n]*/gi,
  /Not applied:[^\n]*/gi,
]

/**
 * The **last** refusal on the screen, not the first one in the pattern list.
 *
 * The order used to be the order of the array above, which meant a session that
 * had been refused once kept answering with that refusal for the rest of its
 * life — the newest line on the screen lost to whichever pattern happened to be
 * written earlier in this file. Reading the last one is the only ordering that
 * corresponds to anything: it is the most recent thing the CLI said no to.
 */
export function readCommandError(screen: string): string | null {
  const text = lines(screen).join('\n')
  let best: { at: number; text: string } | null = null
  for (const pattern of COMMAND_ERRORS) {
    for (const hit of text.matchAll(pattern)) {
      const at = hit.index ?? 0
      if (best === null || at >= best.at) best = { at, text: hit[0].trim() }
    }
  }
  return best === null ? null : best.text
}

/**
 * How many refusals are on the screen.
 *
 * The counterpart of {@link countModelConfirmations}, and it exists for the
 * same reason one step along — the reason is worth restating because the first
 * version of this file solved it for the *success* case and left the failure
 * case wide open, and the hole was only visible once these controls were put
 * somewhere people would use them in sequence.
 *
 * Caught on screen: `/fast on` was refused with "Fast mode requires usage
 * credits", which is correct and stays on the session's screen for the rest of
 * the session. The very next thing pressed was Effort → Ultracode, and it
 * reported *"Fast mode unavailable: Fast mode requires usage credits"* — the
 * old line, matched by a check that asks "is there an error on this screen"
 * rather than "did this command produce one". The effort change had in fact
 * gone through.
 *
 * So the caller counts first and only reads an error when the count has grown.
 */
export function countCommandErrors(screen: string): number {
  const text = lines(screen).join('\n')
  let total = 0
  for (const pattern of COMMAND_ERRORS) total += text.match(pattern)?.length ?? 0
  return total
}

/* -------------------------------------------------------------------------- */
/* Settings and transcript reading                                             */
/* -------------------------------------------------------------------------- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** `~/.claude/settings.json`, or an empty object when it is missing or broken. */
export async function readClaudeSettings(configDir = claudeConfigDir()): Promise<Record<string, unknown>> {
  return readSettingsFile(join(configDir, 'settings.json'))
}

async function readSettingsFile(path: string): Promise<Record<string, unknown>> {
  try {
    const raw = await readFile(path, 'utf8')
    const parsed: unknown = JSON.parse(raw)
    return isRecord(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

/**
 * Claude's own names for the permission modes, as the CLI itself lists them.
 *
 * Not from documentation — from asking the shipped binary. `claude --help` on
 * v2.1.233 prints, for `--permission-mode`:
 *
 *     (choices: "acceptEdits", "auto", "bypassPermissions", "manual",
 *      "dontAsk", "plan")
 *
 * and `permissions.defaultMode` in `settings.json` is written in the same
 * vocabulary — the value on this machine is `bypassPermissions`, which is one
 * of those six exactly.
 *
 * Five of them map onto {@link PERMISSION_MODES}. `dontAsk` does not, because
 * shift+tab never visits it (see the comment there), so it is mapped to `null`:
 * a mode the app can *read* but cannot *reach* would put a value on a control
 * whose menu has no entry to match it, and a picker that cannot express what it
 * is showing is worse than one that says it does not know.
 */
const SETTINGS_PERMISSION_MODES: Readonly<Record<string, PermissionModeId | null>> = {
  acceptEdits: 'acceptEdits',
  auto: 'auto',
  bypassPermissions: 'bypass',
  manual: 'manual',
  plan: 'plan',
  dontAsk: null,
}

/**
 * The permission mode a session in this folder starts in, from the settings
 * files Claude Code itself reads — and the reason the composer stopped saying
 * "Unknown" forever.
 *
 * ## Why the screen was never going to answer
 *
 * Every other control here resolves eventually: the model is painted in the
 * footer and also recoverable from the transcript, effort and fast mode are
 * persisted in `settings.json`. Permission had exactly one source, the footer,
 * and the footer only announces a mode **once it has been changed** — the lines
 * `readPermissionMode` matches are the confirmations the CLI prints on entering
 * a mode. A session that has never been cycled therefore has nothing on screen
 * to read, so the control said `Unknown` at launch and stayed there for the
 * whole session. Asad: model "eventually resolves; permission never does". It
 * was not slow. There was no second source.
 *
 * This is the second source, and it is the honest one: it is the very file the
 * CLI consults to decide the mode the session starts in.
 *
 * ## Precedence
 *
 * Claude reads local over project over user, so this does too, and stops at the
 * first file that names a mode rather than merging — a project that sets
 * `plan` is not partially overridden by a user default of `bypassPermissions`,
 * it replaces it.
 */
export async function readPermissionDefault(
  cwd: string | undefined,
  configDir = claudeConfigDir(),
): Promise<ControlReading> {
  const files = [
    ...(cwd ? [join(cwd, '.claude', 'settings.local.json'), join(cwd, '.claude', 'settings.json')] : []),
    // The *session's* user-level file, not this app process's. The project
    // files above it are a property of the folder and are the same for every
    // account; this last one is a property of the login. See
    // {@link SessionAccess.configDir}.
    join(configDir, 'settings.json'),
  ]

  for (const file of files) {
    const settings = await readSettingsFile(file)
    const permissions = settings.permissions
    if (!isRecord(permissions)) continue
    const named = permissions.defaultMode
    if (typeof named !== 'string') continue
    // A name this build does not know is not guessed at. A wrong permission
    // mode on screen is the single most dangerous thing this panel could say.
    if (!Object.prototype.hasOwnProperty.call(SETTINGS_PERMISSION_MODES, named)) return UNKNOWN
    const id = SETTINGS_PERMISSION_MODES[named]
    if (id === null) return UNKNOWN
    const entry = PERMISSION_MODES.find((mode) => mode.id === id)
    return { value: id, label: entry ? entry.label : id, source: 'settings' }
  }

  return UNKNOWN
}

/**
 * Effort as persisted by the CLI.
 *
 * `ultracode: true` is a separate flag alongside `effortLevel`, so a settings
 * file reading `{ effortLevel: 'xhigh', ultracode: true }` — which is what this
 * machine actually has — means ultracode, not xhigh.
 */
export function effortFromSettings(settings: Record<string, unknown>): ControlReading {
  if (settings.ultracode === true) return { value: 'ultracode', label: 'Ultracode', source: 'settings' }
  const level = typeof settings.effortLevel === 'string' ? settings.effortLevel.toLowerCase() : ''
  const known = EFFORT_LEVELS.find((entry) => entry.id === level)
  if (!known) return { value: null, label: null, source: null }
  return { value: known.id, label: known.label, source: 'settings' }
}

/**
 * Fast mode, only if `settings.json` actually says.
 *
 * An earlier version treated a missing key as "off" and still stamped the
 * reading `source: 'settings'`, so the row said "Fast · Off — from Claude
 * settings" on a machine whose settings file has no `fastMode` key at all, and
 * said the same thing when the file was missing or unparseable, since
 * `readClaudeSettings` turns every failure into `{}`. That is the exact failure
 * this feature is supposed to prevent: a confident value nothing was read for.
 *
 * It matters here more than it looks. Checked against the shipped CLI, the only
 * write it makes to `fastMode` in user settings is a *clear* (`fastMode: void 0`)
 * when an organisation turns the feature off; the enabled state lives in its own
 * store. So the honest answer, absent the key, is that we do not know — and the
 * screen is what settles it, the moment the session says "Fast mode ON/OFF".
 */
export function fastFromSettings(settings: Record<string, unknown>): ControlReading {
  if (typeof settings.fastMode !== 'boolean') return { value: null, label: null, source: null }
  const on = settings.fastMode === true
  return { value: on ? 'on' : 'off', label: on ? 'On' : 'Off', source: 'settings' }
}

/**
 * The model id on the newest assistant line of the project's live transcript.
 *
 * This is the strongest statement available about the current model, because it
 * is not a setting or an intention — it is the model that served the last reply.
 * Tails the file rather than parsing all of it; transcripts here run to tens of
 * megabytes and the answer is always near the end.
 *
 * ## `<synthetic>` is not a model, and it was reaching the bar
 *
 * Claude Code writes assistant lines of its own — interrupts, API errors, the
 * notices it emits around a resume — and stamps them `"model": "<synthetic>"`.
 * `cost.ts` has known this since it was written; this function did not, so it
 * returned the placeholder verbatim whenever one of those lines happened to be
 * the newest. Found in the audit, after an account switch resumed a
 * conversation: the toolbar's Model chip read the placeholder itself, where the same
 * session had read *Opus 5 · 1M* a moment earlier.
 *
 * So those lines are stepped over and the walk continues to the newest line a
 * model actually served. A transcript with nothing but synthetic lines answers
 * null, which is not a failure — it hands the question to the welcome panel and
 * then to `settings.json`, the two sources below this one in `readControls`,
 * both of which name a real model.
 */
export async function readModelFromTranscript(cwd: string, configDir?: string): Promise<string | null> {
  // Every store, because a session started from a paired device runs with a home
  // of its own and writes its transcript there. Reading only the profile's store
  // answered "no model" for a session that was answering, which reads on screen
  // as a control that does not know what it is controlling.
  //
  // `configDir` replaces the *primary* store in that list — this session's own,
  // rather than this app process's — and leaves the paired devices' stores
  // exactly where they were. Two accounts open on one project each keep their
  // own conversation under their own store, so without it the newest file
  // across both wins and the chip names the model of the login you are not on.
  const found = await Promise.all(
    transcriptDirs(cwd, configDir === undefined ? {} : { configDir }).map((dir) => listTranscripts(dir)),
  )
  let file: { path: string; modifiedAt: number } | null = null
  for (const candidate of found.flat()) {
    if (file === null || candidate.modifiedAt > file.modifiedAt) file = candidate
  }
  if (!file) return null
  let raw: string
  try {
    raw = await readFile(file.path, 'utf8')
  } catch {
    return null
  }
  const all = raw.split('\n')
  for (let i = all.length - 1; i >= 0 && i >= all.length - 4000; i--) {
    const line = all[i].trim()
    if (line === '' || !line.includes('"model"')) continue
    try {
      const parsed: unknown = JSON.parse(line)
      if (!isRecord(parsed) || parsed.type !== 'assistant') continue
      const message = parsed.message
      if (!isRecord(message)) continue
      const model = message.model
      if (typeof model !== 'string') continue
      const trimmed = model.trim()
      if (trimmed === '' || trimmed === SYNTHETIC_MODEL) continue
      return trimmed
    } catch {
      // A partially flushed final line — keep walking back.
    }
  }
  return null
}

/**
 * Turn a raw transcript model id into something a person recognises.
 *
 * Deliberately conservative: it maps the family and says the version it saw
 * rather than pretending to know marketing names. `claude-opus-5[1m]` becomes
 * "Opus 5 · 1M" because `normalizeModelId` strips the `[1m]` tag that Claude
 * Code appends for the long-context beta, and losing that would show the same
 * label for two genuinely different context windows.
 */
export function labelModelId(raw: string): string {
  const long = /\[1m\]$/i.test(raw.trim())
  const id = normalizeModelId(raw)
  const match = /^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)?)/.exec(id)
  if (!match) return raw.trim()
  const family = match[1][0].toUpperCase() + match[1].slice(1)
  const version = match[2].replace(/-/g, '.')
  return `${family} ${version}${long ? ' · 1M' : ''}`
}

/**
 * The model named in the CLI's own welcome panel, which every session draws
 * before it has said anything.
 *
 * ## Why a third model source was needed
 *
 * Because of what the second one produced on screen. Asad, reading the bar:
 *
 *   > *"Unknown should not be there, it should be already selected."*
 *
 * He is right that `Unknown` is never the honest answer for a *model* — unlike
 * fast mode or the permission mode, a session always has one. It was showing
 * because the two sources this file had could both be silent at once: the
 * `Set model to …` confirmation only exists in a session somebody has changed
 * the model in, and the transcript only exists once the agent has replied. A
 * session opened thirty seconds ago and not yet spoken to has neither, and that
 * is exactly the session anybody would look at the bar of.
 *
 * The welcome panel is the missing one. It is the first thing the CLI paints and
 * it says the model outright:
 *
 *     │      Opus 5 with xhigh effort · Claude Max ·       │
 *     │      Opus 5 (1M context) with xhig… · Claude Max · │   (narrower window)
 *
 * The second line is from the Windows capture and is the reason this stops at
 * the effort word rather than reading to the separator: at a narrow width the
 * CLI truncates the *effort* with an ellipsis, and a reader that took everything
 * up to the `·` would report a model of `Opus 5 (1M context) with xhig…`.
 *
 * It is the weakest of the three sources and is consulted last, because the
 * panel scrolls away and cannot reflect a change made after it was drawn. That
 * ordering is what keeps it a floor under `Unknown` rather than a source of
 * stale confidence.
 */
export function readModelFromWelcome(screen: string): string | null {
  for (const line of lines(screen)) {
    // `effort` is optional because the narrow capture proves it can be the word
    // that gets truncated: `with xhig… ·`. What is never optional is the panel
    // border, the word `with`, and the `·` that ends the clause — three anchors
    // a sentence in a chat reply does not line up with by accident.
    const match = /│\s*(\S.*?)\s+with\s+\S+(?:\s+effort)?\s*·/.exec(line)
    if (match) return match[1].trim()
  }
  return null
}

/**
 * The model Claude Code's own settings file names, as a last resort.
 *
 * `settings.json` holds whatever `/model` last saved — an alias like `opus` or
 * `opusplan`, or a full id like `claude-sonnet-4-6` — because the CLI writes it
 * there itself every time a pick is made with the default scope. It is a real
 * reading and it is labelled `settings`, so the caption under the value says
 * "from Claude settings" and nobody mistakes it for something read off this
 * session.
 *
 * The alias is turned into the name it resolves to where that is known from the
 * picker capture, and left as-is where it is not: printing `opusplan` is worse
 * than printing `Opus Plan` but far better than printing a name for it that was
 * never verified.
 */
export function modelFromSettings(settings: Record<string, unknown>): ControlReading {
  const raw = settings.model
  if (typeof raw !== 'string' || raw.trim() === '') return { value: null, label: null, source: null }
  const alias = raw.trim()
  const row = foldDefaultRow([...FALLBACK_MODELS]).find((entry) => entry.alias === alias)
  const label = row ? row.model : /^claude-/.test(alias) ? labelModelId(alias) : alias
  return { value: alias, label, source: 'settings' }
}

/* -------------------------------------------------------------------------- */
/* Reading everything                                                          */
/* -------------------------------------------------------------------------- */

const UNKNOWN: ControlReading = { value: null, label: null, source: null }

/**
 * Whether this computer's own files and environment describe this session.
 *
 * ## The lie this exists to stop
 *
 * Four of the sources this module reads are **local disk and local
 * environment**: `~/.claude/settings.json` for effort and fast mode,
 * `permissions.defaultMode` in the same file, the Claude transcripts under this
 * machine's config directory, and `CLAUDE_CODE_EFFORT_LEVEL` in this process.
 * Every one of them is correct for a pty this app spawned and every one of them
 * is a fabrication for a shell running on a server somebody signed into over
 * SSH — that machine has its own `~/.claude`, its own transcripts and its own
 * environment, and none of them are here.
 *
 * A screen is the one source that travels, because the bytes are the same bytes
 * whatever produced them. So a session that is not on this computer is read from
 * its screen and from nothing else, and what the screen cannot answer comes back
 * `null`, which the bar draws as "Unknown" — the true answer, rather than this
 * machine's answer to a question about another one.
 *
 * The remote-machine case does **not** use this and must not: a session on a
 * paired desktop is read by *that* desktop's copy of this module, against its
 * own disk, which is exactly right. See `CAPABILITY.controls`.
 */
export interface ControlScope {
  /**
   * False when the session is running somewhere else — an SSH shell on a server.
   * Absent means this machine, which is what every existing caller means.
   */
  onThisMachine?: boolean
}

/** True unless a caller has said the session is on another computer. */
function local(scope: ControlScope | undefined): boolean {
  return scope?.onThisMachine !== false
}

export async function readControls(
  access: SessionAccess,
  sessionId: string | undefined,
  cwd: string | undefined,
  provider?: string,
  scope?: ControlScope,
): Promise<ControlsReading> {
  // Read once into a local so that every fallback below asks the same question
  // — the three of them are the whole of what this flag turns off, and a fourth
  // added later that forgets to ask is the bug it exists to prevent. See
  // {@link ControlScope}.
  const onThisMachine = local(scope)
  /*
   * Which login's files this reading is allowed to consult, read once for the
   * same reason `onThisMachine` is: three fallbacks below open a file, and
   * three separate lookups is three chances for one of them to answer about a
   * different account than the other two — which is precisely the fault being
   * closed. Null keeps every one of them on `claudeConfigDir()`, exactly as
   * they were. See {@link SessionAccess.configDir}.
   */
  const store = (onThisMachine && sessionId ? access.configDir?.(sessionId) : null) ?? undefined
  const screen = sessionId ? await access.screen(sessionId) : null

  const saw = screen === null ? null : readAgentFromScreen(screen)
  const agent: AgentPresence = saw === null ? NO_AGENT : { running: true, evidence: 'screen', saw }

  /*
   * Whether a command could be typed at this session this instant.
   *
   * The same two functions `typeCommand` consults before it writes a byte, run
   * here so the answer reaches the renderer *before* the click rather than as
   * an apology after it — see {@link ControlGate}. A session with no screen at
   * all is not "busy", it is gone, and `live` already says so; the sentence
   * here matches the one `applyControl` opens with so the two cannot disagree.
   */
  const gate: ControlGate =
    screen === null
      ? { canType: false, reason: 'That session is no longer running.' }
      : ((): ControlGate => {
          const refusal = refuseToType(readComposer(screen))
          return { canType: refusal === null, reason: refusal }
        })()

  /*
   * A session this module cannot speak to reports nothing, and says why.
   *
   * Read before anything is read, because the three fallbacks below are all
   * Claude Code's own files: `~/.claude/settings.json` for effort and fast
   * mode, `permissions.defaultMode` for the permission mode, and this project's
   * Claude transcripts for the model. Every one of them answers confidently for
   * a session that has nothing to do with Claude, which is how a `/bin/zsh -l`
   * once came to report a model of "Opus 5" — the same failure, one provider
   * along. The reason travels on the readings so the panel can print it instead
   * of the four "Unknown"s it would otherwise show, which say nothing about why.
   */
  const foreign = refuseByProvider(provider, agent)
  if (foreign !== null) {
    const blocked: ControlReading = { value: null, label: null, source: null, unavailableReason: foreign }
    return { model: blocked, effort: blocked, fast: blocked, permission: blocked, live: screen !== null, agent, gate }
  }

  const permission = await (async (): Promise<ControlReading> => {
    // The screen first, always: it is the only source that reflects a mode the
    // session was cycled into after it started.
    const mode = screen === null ? null : readPermissionMode(screen)
    if (mode) {
      const entry = PERMISSION_MODES.find((m) => m.id === mode)
      return { value: mode, label: entry ? entry.label : mode, source: 'screen' }
    }
    // And then the settings the CLI itself started the session from. Without
    // this the control was `Unknown` for the whole life of any session nobody
    // had pressed shift+tab in — see `readPermissionDefault`. Skipped entirely
    // for a session on another computer: that file is this machine's.
    return onThisMachine ? readPermissionDefault(cwd, store) : UNKNOWN
  })()

  // Empty rather than read for a session that is not on this computer, so every
  // `…FromSettings` fallback below answers "nothing was read" instead of
  // answering with this machine's configuration.
  const settings = onThisMachine ? await readClaudeSettings(store) : {}

  /*
   * Four sources, newest evidence first, and the fourth is what ends `Unknown`.
   *
   * A confirmation on the screen beats everything: it is this session, and it is
   * a change somebody made. The transcript is next — the model that actually
   * served the last reply. The welcome panel is third: it is only correct until
   * the model is changed, so it must never outrank the two that see a change,
   * but it is drawn by every session before it has said a word, which is exactly
   * the gap the first two leave. `settings.json` is the floor, and it always
   * answers on a machine that has ever picked a model.
   *
   * Between them a Claude Code session has no state in which nothing can be
   * read, which is what "a model is always selected" has to mean if it is going
   * to be true rather than merely displayed.
   */
  const model = await (async (): Promise<ControlReading> => {
    const confirmed = screen === null ? null : readModelFromScreen(screen)
    if (confirmed) return { value: confirmed, label: confirmed, source: 'screen' }
    const raw = cwd && onThisMachine ? await readModelFromTranscript(cwd, store) : null
    if (raw) return { value: raw, label: labelModelId(raw), source: 'transcript' }
    const welcomed = screen === null ? null : readModelFromWelcome(screen)
    if (welcomed) return { value: welcomed, label: welcomed, source: 'screen' }
    return modelFromSettings(settings)
  })()

  const effort = ((): ControlReading => {
    // This process's environment, which is this machine's. A session on a server
    // inherited whatever *that* login exported and nothing here can see it.
    const override = onThisMachine ? process.env.CLAUDE_CODE_EFFORT_LEVEL?.trim().toLowerCase() : undefined
    if (override) {
      const known = EFFORT_LEVELS.find((entry) => entry.id === override)
      return { value: override, label: known ? known.label : override, source: 'env' }
    }
    const confirmed = screen === null ? null : readEffortFromScreen(screen)
    if (confirmed) {
      const known = EFFORT_LEVELS.find((entry) => entry.id === confirmed)
      return { value: confirmed, label: known ? known.label : confirmed, source: 'screen' }
    }
    return effortFromSettings(settings)
  })()

  /*
   * The screen first, and the screen now means the `↯` in the status rule
   * rather than an announcement that may have scrolled away — see
   * {@link readFastIndicator} for the drive that established it. The settings
   * fallback is kept underneath because the CLI *can* write `fastMode` there,
   * and a machine where it has is one more session this reads rather than
   * shrugs at.
   */
  const fast = ((): ControlReading => {
    const confirmed = screen === null ? null : readFast(screen)
    if (confirmed) return confirmed
    return fastFromSettings(settings)
  })()

  return { model, effort, fast, permission, live: screen !== null, agent, gate }
}

/* -------------------------------------------------------------------------- */
/* Applying                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * How long each wait is allowed to take, and how often to look.
 *
 * A parameter rather than four constants because the interesting paths here are
 * the ones that *give up* — the CLI said nothing, the echo never arrived, the
 * footer would not move — and a test of those has to sit out the whole deadline
 * in real time. At the shipped six seconds that is longer than the default test
 * timeout, so the tests covering the give-up branches would either be padded
 * with a longer limit and spend twenty seconds of the suite asleep, or be left
 * unwritten. Neither is a good trade for a number that is pure policy.
 *
 * `applyControl` defaults to {@link SHIPPED_TIMINGS} and the IPC handler never
 * passes anything else, so this is not a knob the app has grown — it is the
 * same arrangement `drain`'s `timeoutMs` already uses one file over.
 */
export interface ApplyTimings {
  /** Gap between screen reads while waiting. */
  poll: number
  /** How long a typed command has to appear on the command line. */
  echo: number
  /** How long the CLI has to answer a submitted command. */
  command: number
  /** How long the footer has to move after one shift+tab. */
  cycleStep: number
}

export const SHIPPED_TIMINGS: ApplyTimings = { poll: 120, echo: 2500, command: 6000, cycleStep: 2500 }

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Poll the session's screen until `done` accepts it, or the deadline passes. */
async function waitForScreen<T>(
  access: SessionAccess,
  sessionId: string,
  timeoutMs: number,
  pollMs: number,
  done: (screen: string) => T | null,
): Promise<T | null> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    await sleep(pollMs)
    const screen = await access.screen(sessionId)
    if (screen === null) return null
    const answer = done(screen)
    if (answer !== null) return answer
  }
  return null
}

/**
 * What the CLI's own line editor uses to clear the line, and to put it back.
 *
 * Both were driven against the real binary. `\x15` (ctrl+u) empties the
 * composer and the CLI itself then offers `Ctrl+Y to paste deleted text` in the
 * hint row above it, so the kill is recoverable *by the person at the
 * keyboard*. That is why the rollback below is allowed to use it, and also why
 * it is only ever used to take back this app's **own** keystrokes: relying on a
 * kill ring to restore somebody else's sentence would be betting their work on
 * an undocumented buffer surviving a command submission in between.
 */
const CLEAR_COMPOSER = '\x15'

/** Why a command must not be typed into this session right now, or null. */
export function refuseToType(state: ComposerState): string | null {
  if (state.kind === 'ready') return null
  if (state.kind === 'working') {
    return 'This session is mid-turn. A command typed now would land in whatever it asks next rather than on the command line, so nothing was sent — try again once it has finished.'
  }
  if (state.kind === 'choosing') {
    return `This session is waiting on a choice (“${state.asking}”). Pressing return now would answer it instead of running a command, so nothing was sent.`
  }
  if (state.kind === 'typing') {
    return `There is unsent text at this session’s prompt (“${state.text}”). A command typed now would run into the middle of it, so nothing was sent — clear the prompt and pick again.`
  }
  return 'This session’s prompt is not on screen, so there is nowhere to type that could be checked first.'
}

/**
 * Type a slash command into the session and press return — but only once it can
 * be seen that the command, and nothing else, is what is on the command line.
 *
 * ## The protocol, and why it is three steps rather than one
 *
 * The old version was one line: write `${command}\r`. It is worth being exact
 * about what that did wrong, because two of the three failures are silent.
 *
 *  1. **It could not see a draft.** A pty write appends. With
 *     `remind me to buy milk` sitting unsent in the composer, `/model sonnet\r`
 *     submits `remind me to buy milk/model sonnet` — the user's sentence, sent
 *     to the agent, mangled, by a button they pressed somewhere else entirely.
 *  2. **It could not see a dialog.** A `\r` arriving while a numbered dialog is
 *     up answers the dialog. Established the hard way here: a `/model default\r`
 *     sent at a session showing `Switch model?` never ran `/model default` at
 *     all — the return picked "Yes, switch to Sonnet 5".
 *  3. **It could not see a turn in flight.**
 *
 * So: read the screen, refuse unless the composer is empty and unowned, write
 * the command **without** the return, wait until the composer reads back as
 * exactly that command, and only then send the return. The separation is the
 * whole point — the return is the byte that commits, and it is not sent until
 * the screen has confirmed where it will land.
 *
 * ## The rollback
 *
 * If the echo never arrives, the keystrokes went somewhere unexpected and this
 * clears the line before giving up. That is safe precisely because step one
 * established the composer was empty: everything ctrl+u removes is this app's
 * own typing. It is not attempted in the states this refuses outright, because
 * in those the app has not typed anything to take back.
 */
async function typeCommand(
  access: SessionAccess,
  sessionId: string,
  command: string,
  timings: ApplyTimings,
): Promise<{ ok: true } | { ok: false; message: string }> {
  const screen = await access.screen(sessionId)
  if (screen === null) return { ok: false, message: 'That session is no longer running.' }

  const refusal = refuseToType(readComposer(screen))
  if (refusal !== null) return { ok: false, message: refusal }

  access.write(sessionId, command)

  const landed = await waitForScreen(access, sessionId, timings.echo, timings.poll, (later) => {
    const now = readComposer(later)
    return now.kind === 'typing' && now.text === command ? true : null
  })
  if (landed === null) {
    access.write(sessionId, CLEAR_COMPOSER)
    return {
      ok: false,
      message: `Typed “${command}” but it did not appear on this session’s command line, so the return was not sent and the line was cleared again. Nothing was run.`,
    }
  }

  access.write(sessionId, '\r')
  return { ok: true }
}

/**
 * Type a command, answer the CLI's confirmation dialog if it raises one, and
 * come back with whatever it finally said.
 *
 * ## Why answering a dialog is allowed here
 *
 * This is the one place in this file that presses a key at something other than
 * an empty command line, so the conditions are worth stating in full. The
 * dialog was raised by the command this app just typed and watched land; its
 * heading is one of the two the CLI uses for exactly this question; its kind
 * matches the control being changed; and the selection cursor is already
 * resting on a row reading "Yes, switch to …". Under those four, return is the
 * second half of one action the user took, not a decision made on their behalf.
 *
 * Everything else is left alone. A permission prompt that happened to appear
 * has the wrong heading, so `readSwitchDialog` answers null, the wait times out
 * and this reports that the session is asking something — rather than pressing
 * return at a question nobody read.
 *
 * `settled` is the caller's answer to "has the CLI said anything conclusive
 * yet?", and returning `null` from it means "not yet, keep looking". It is a
 * parameter because the model and effort branches read different lines but need
 * identical handling of everything around them, and the earlier version of this
 * file had that handling written out once — for the model only, which is how
 * effort's own dialog went unnoticed until it was driven.
 */
async function runCommand<T>(
  access: SessionAccess,
  sessionId: string,
  command: string,
  kind: SwitchDialogKind,
  timings: ApplyTimings,
  settled: (screen: string) => T | null,
): Promise<{ ok: true; answer: T } | { ok: false; message: string }> {
  const typed = await typeCommand(access, sessionId, command, timings)
  if (!typed.ok) return { ok: false, message: typed.message }

  type Step = { done: T } | { dialog: string }
  const step = await waitForScreen<Step>(access, sessionId, timings.command, timings.poll, (screen) => {
    const done = settled(screen)
    if (done !== null) return { done }
    const dialog = readSwitchDialog(screen)
    return dialog !== null && dialog.kind === kind ? { dialog: dialog.target } : null
  })

  const stuck = async (): Promise<string> => {
    const still = readSwitchDialog((await access.screen(sessionId)) ?? '')
    return still !== null
      ? `The session is asking whether to switch to ${still.target} and has not moved on. Nothing was changed.`
      : `Typed ${command} but the CLI has not answered yet.`
  }

  if (step === null) return { ok: false, message: await stuck() }
  if (!('dialog' in step)) return { ok: true, answer: step.done }

  access.write(sessionId, '\r')
  const after = await waitForScreen<T>(access, sessionId, timings.command, timings.poll, settled)
  if (after === null) return { ok: false, message: await stuck() }
  return { ok: true, answer: after }
}

/**
 * Step the permission cycle exactly one place and report where it landed.
 *
 * shift+tab is CSI Z (back-tab) — the byte sequence a terminal sends for that
 * chord, confirmed by driving the real CLI with it and watching the footer move.
 */
async function cycleOnce(
  access: SessionAccess,
  sessionId: string,
  from: PermissionModeId,
  timings: ApplyTimings,
): Promise<PermissionModeId | null> {
  access.write(sessionId, '\x1b[Z')
  return waitForScreen(access, sessionId, timings.cycleStep, timings.poll, (screen) => {
    const now = readPermissionMode(screen)
    return now !== null && now !== from ? now : null
  })
}

/**
 * Move to a permission mode by cycling, checking the footer after every press.
 *
 * The cycle is the only in-session mechanism the CLI offers, but it does not
 * have to be used blind. Refusing to start when the current mode is unreadable,
 * and confirming after each press, means this either lands on the requested
 * mode or says plainly that it could not.
 *
 * The ring is also not fixed: bypass can be disabled by policy and auto can be
 * unavailable, in which case those stops simply do not appear. So the loop is
 * bounded by "we have come back to where we started" rather than by a count.
 *
 * ## Why this one gate is looser than the others
 *
 * Everything that types text refuses outright when there is a draft in the
 * composer. shift+tab does not, and the difference is a measured one rather
 * than a convenience: driven at the real CLI with `a draft the user is still
 * writing` sitting unsent in the composer, one shift+tab moved the footer from
 * bypass to auto and left the draft on screen character for character. A chord
 * is not a character; it does not go into the line editor at all. Refusing here
 * would withdraw a working control for a hazard that was checked and does not
 * exist.
 *
 * A dialog and a turn in flight are a different matter — those own the keyboard
 * — so both are still refused, through the same {@link refuseToType} the typed
 * commands use.
 */
async function applyPermission(
  access: SessionAccess,
  sessionId: string,
  target: string,
  timings: ApplyTimings,
): Promise<{ ok: boolean; message: string; mode: PermissionModeId | null }> {
  const wanted = PERMISSION_MODES.find((mode) => mode.id === target)
  if (!wanted) return { ok: false, message: `${target} is not a permission mode this build can reach.`, mode: null }

  const screen = await access.screen(sessionId)
  if (screen === null) return { ok: false, message: 'That session is no longer running.', mode: null }

  const composer = readComposer(screen)
  if (composer.kind !== 'ready' && composer.kind !== 'typing') {
    return { ok: false, message: refuseToType(composer) ?? '', mode: null }
  }

  const startedAt = readPermissionMode(screen)
  if (startedAt !== null && startedAt === wanted.id) {
    return { ok: true, message: `Already in ${wanted.label} mode.`, mode: startedAt }
  }

  // `/plan` is the one mode with a direct command — the CLI answers "Enabled
  // plan mode" — so it skips the cycle. It is tried before the unknown-mode
  // check on purpose: a command that names its destination does not care where
  // it started, so plan stays reachable even when the footer cannot be read.
  //
  // It is the one branch here that types, so unlike the cycle below it goes
  // through `typeCommand` and inherits its refusals — including the one for a
  // draft in the composer, which shift+tab is exempt from and a typed `/plan`
  // is not.
  if (wanted.id === 'plan') {
    const typed = await typeCommand(access, sessionId, '/plan', timings)
    if (!typed.ok) return { ok: false, message: typed.message, mode: null }
    const landed = await waitForScreen(access, sessionId, timings.command, timings.poll, (later) => {
      const mode = readPermissionMode(later)
      return mode === 'plan' ? mode : null
    })
    if (landed) return { ok: true, message: 'Enabled plan mode.', mode: landed }
    return { ok: false, message: 'Typed /plan but the footer did not change.', mode: readPermissionMode((await access.screen(sessionId)) ?? '') }
  }

  if (startedAt === null) {
    return {
      ok: false,
      message:
        'The permission footer is not on screen, so the current mode is unknown — cycling from an unknown start would be a guess.',
      mode: null,
    }
  }

  let current: PermissionModeId = startedAt
  const start = startedAt
  const seen: PermissionModeId[] = [current]
  for (let press = 0; press < PERMISSION_MODES.length + 1; press++) {
    const next = await cycleOnce(access, sessionId, current, timings)
    if (next === null) {
      return { ok: false, message: `Pressed shift+tab but the footer stayed on ${current}.`, mode: current }
    }
    current = next
    if (current === wanted.id) return { ok: true, message: `Switched to ${wanted.label} mode.`, mode: current }
    if (current === start) {
      return {
        ok: false,
        message: `This session's cycle only offers ${seen.join(', ')} — ${wanted.label} is not available in it.`,
        mode: current,
      }
    }
    seen.push(current)
  }
  return { ok: false, message: `Gave up cycling; the footer is on ${current}.`, mode: current }
}

/**
 * Apply one control and report what the CLI said about it.
 *
 * Success is never assumed from the fact that bytes were written. Each branch
 * waits for the CLI's own line and, failing that, says the change was typed but
 * not confirmed — which is the truth when the agent is mid-turn and the command
 * is sitting in its input queue.
 *
 * The reading that comes back is always re-read from the session afterwards,
 * never echoed from the request. A picker that shows what it *asked for* rather
 * than what *is* is the failure this whole module is arranged against, and it
 * would be one line of laziness away at every one of these returns.
 */
export async function applyControl(
  access: SessionAccess,
  request: ApplyRequest,
  timings: ApplyTimings = SHIPPED_TIMINGS,
): Promise<ApplyResult> {
  const { sessionId, cwd, control, value, provider, scope } = request
  // The same read-once as in `readControls`, and for the same reason: every
  // fallback below has to be asking one question rather than three.
  const onThisMachine = local(scope)
  // And the same store, for the *failure* readings. A change that could not be
  // confirmed falls back to a file, and falling back to another account's file
  // answers a question about this session with a fact about a different one.
  const store = (onThisMachine ? access.configDir?.(sessionId) : null) ?? undefined

  const opening = await access.screen(sessionId)
  if (opening === null) {
    return { ok: false, message: 'That session is no longer running.', reading: UNKNOWN }
  }

  /*
   * Checked here as well as in the renderer, and not because the renderer is
   * suspected of lying.
   *
   * The renderer withdraws these pickers for a provider it cannot speak to, so
   * in the running app this branch is unreachable. It is here because the
   * channel is not: `agent:controls:apply` is an IPC handler, and an IPC
   * handler that trusts its caller to have done the checking is one refactor
   * away from typing `/model sonnet` into somebody's shell. The gate belongs
   * next to the thing it is guarding, which is `access.write`.
   */
  const saw = readAgentFromScreen(opening)
  const foreign = refuseByProvider(
    provider,
    saw === null ? NO_AGENT : { running: true, evidence: 'screen', saw },
  )
  if (foreign !== null) return { ok: false, message: foreign, reading: UNKNOWN }

  if (control === 'permission') {
    const outcome = await applyPermission(access, sessionId, value, timings)
    const entry = PERMISSION_MODES.find((mode) => mode.id === outcome.mode)
    return {
      ok: outcome.ok,
      message: outcome.message,
      reading: outcome.mode
        ? { value: outcome.mode, label: entry ? entry.label : outcome.mode, source: 'screen' }
        : UNKNOWN,
    }
  }

  if (control === 'model') {
    /*
     * A shape check, not a list.
     *
     * This used to compare against five hand-written aliases, which meant this
     * app refused a model before the CLI ever saw it — with a message blaming
     * the model rather than the list — every time a new one shipped. The list
     * is now read out of the CLI's own picker (`model-catalog.ts`), and the
     * picker can legitimately offer a row nobody here has heard of; the *only*
     * thing that still has to be enforced locally is that the value cannot
     * become a second argument or a submitted line, because it is about to be
     * typed into somebody's terminal. Anything past that is the CLI's to
     * refuse, and it does so in words worth showing: `Model 'x' not found`.
     */
    if (!isTypeableModelValue(value)) {
      return { ok: false, message: `${value} is not a model name that can be typed at a command line.`, reading: UNKNOWN }
    }

    // Counted, not compared. Asking for the model the session is already on
    // produces a confirmation identical to the one already on screen, and a
    // check of the form "has the name changed?" reads that as "nothing
    // happened" and times out on a change that was made. See `countMatches`.
    const before = countModelConfirmations(opening)
    // And the refusals are counted for exactly the same reason — see
    // `countCommandErrors`. Without this, one earlier "Fast mode requires usage
    // credits" makes every model change for the rest of the session report a
    // failure that belongs to a command nobody just pressed.
    const errorsBefore = countCommandErrors(opening)

    const outcome = await runCommand(access, sessionId, `/model ${value}`, 'model', timings, (screen) => {
      const failure = countCommandErrors(screen) > errorsBefore ? readCommandError(screen) : null
      if (failure) return { ok: false as const, text: failure, scope: null as ConfirmationScope | null }
      if (countModelConfirmations(screen) <= before) return null
      const now = readModelConfirmation(screen)
      return now ? { ok: true as const, text: now.name, scope: now.scope } : null
    })
    if (!outcome.ok) {
      return {
        ok: false,
        message: outcome.message,
        reading: await currentModel(access, sessionId, onThisMachine ? cwd : undefined, store),
      }
    }
    const answer = outcome.answer
    if (!answer.ok) {
      return {
        ok: false,
        message: answer.text,
        reading: await currentModel(access, sessionId, onThisMachine ? cwd : undefined, store),
      }
    }
    return {
      ok: true,
      // The scope is quoted from the CLI, not asserted: it decides per call
      // between "saved as your default for new sessions" and "for this session
      // only", and saying the wrong one is a lie about the user's config.
      message: `Model is now ${answer.text}${answer.scope ? ` — ${SCOPE_TEXT[answer.scope]}.` : '.'}`,
      reading: { value: answer.text, label: answer.text, source: 'screen' },
    }
  }

  if (control === 'effort') {
    if (!EFFORT_LEVELS.some((level) => level.id === value)) {
      return { ok: false, message: `${value} is not one of the levels the CLI accepts.`, reading: UNKNOWN }
    }
    const known = EFFORT_LEVELS.find((level) => level.id === value)
    // Counted for the mirror of the model's problem: picking Low twice, where
    // the first confirmation is still on screen and satisfies "is it low now?"
    // before the second command has been parsed.
    const before = countEffortConfirmations(opening)
    // The refusal this caught in the app, verbatim: pick Fast mode → On, be told
    // "Fast mode requires usage credits", then pick Effort → Ultracode and be
    // told "Fast mode unavailable" by the effort control. See
    // `countCommandErrors`.
    const errorsBefore = countCommandErrors(opening)

    const outcome = await runCommand(access, sessionId, `/effort ${value}`, 'effort', timings, (screen) => {
      const failure = countCommandErrors(screen) > errorsBefore ? readCommandError(screen) : null
      if (failure) return { ok: false as const, text: failure, scope: null as ConfirmationScope | null }
      if (countEffortConfirmations(screen) <= before) return null
      const now = readEffortConfirmation(screen)
      return now && now.level === value ? { ok: true as const, text: now.level, scope: now.scope } : null
    })
    if (!outcome.ok) {
      return { ok: false, message: outcome.message, reading: effortFromSettings(onThisMachine ? await readClaudeSettings(store) : {}) }
    }
    const answer = outcome.answer
    if (!answer.ok) return { ok: false, message: answer.text, reading: effortFromSettings(onThisMachine ? await readClaudeSettings(store) : {}) }
    return {
      ok: true,
      // Not "and saved as your default" — the CLI prints one of two scopes and
      // ultracode is always the session-only one. Quote it or say nothing.
      message: `Effort is now ${known ? known.label : value}${answer.scope ? ` — ${SCOPE_TEXT[answer.scope]}.` : '.'}`,
      reading: { value, label: known ? known.label : value, source: 'screen' },
    }
  }

  if (control === 'fast') {
    if (value !== 'on' && value !== 'off') {
      return { ok: false, message: 'Fast mode is on or off.', reading: UNKNOWN }
    }
    const before = countFastAnnouncements(opening)

    const typed = await typeCommand(access, sessionId, `/fast ${value}`, timings)
    if (!typed.ok) {
      return { ok: false, message: typed.message, reading: fastFromSettings(onThisMachine ? await readClaudeSettings(store) : {}) }
    }

    /*
     * Two ways to be finished, because the CLI has two ways of being finished.
     *
     * A *change* prints `↯ Fast mode ON · $10/$50 per Mtok` or `Fast mode OFF`,
     * which the announcement count catches. A *no-op* — `/fast on` at a session
     * that is already on — prints nothing at all, and the old code sat there
     * until its six-second timeout and then apologised for a state that was
     * already exactly what had been asked for. The `↯` in the status rule
     * settles that case without waiting: it is on screen the whole time fast
     * mode is on, so agreeing with the request *is* the confirmation.
     */
    const answer = await waitForScreen(access, sessionId, timings.command, timings.poll, (screen) => {
      if (countFastAnnouncements(screen) > before) return readFast(screen)
      return readFastIndicator(screen) === value ? readFast(screen) : null
    })
    if (!answer) {
      return {
        ok: false,
        message: `Typed /fast ${value} but the session has not shown it taking effect — it is most likely mid-turn, so the command is sitting in its input queue.`,
        reading: fastFromSettings(onThisMachine ? await readClaudeSettings(store) : {}),
      }
    }
    if (answer.unavailableReason) return { ok: false, message: answer.unavailableReason, reading: answer }
    return { ok: answer.value === value, message: `Fast mode ${answer.label}.`, reading: answer }
  }

  return { ok: false, message: `Unknown control ${String(control)}.`, reading: UNKNOWN }
}

/* -------------------------------------------------------------------------- */
/* Asking the CLI what models it has                                           */
/* -------------------------------------------------------------------------- */

export interface ModelCatalogResult {
  /** The rows the CLI offered, `Default` already folded into what it points at. */
  models: ModelRow[]
  /** Why the list could not be read, or null when it was. */
  message: string | null
}

/**
 * Open the session's own `/model` picker, read what is in it, and cancel out.
 *
 * ## Why this types at a live session instead of probing somewhere quiet
 *
 * Because the answer is a property of *this* session and this account, not of
 * the binary. An organisation that restricts models restricts this picker, and
 * a list gathered from a throwaway process in a temp directory would confidently
 * offer models the session in front of the user cannot have. Everything else in
 * this module already works this way, for the same reason, under the same rule:
 * a control here is honest exactly when a person could sit at that terminal and
 * do the same thing. A person opens `/model`, looks, and presses Esc.
 *
 * ## Why cancelling is safe
 *
 * Esc is the picker's own documented way out — its last line reads
 * `Enter to set as default · s to use this session only · Esc to cancel` — and
 * driving it confirms what it does: the session prints `⎿  Kept model as Opus 5`
 * and nothing changes. That line is a bonus rather than a cost, because
 * `readModelFromScreen` recognises `Kept model as …` too, so merely opening the
 * list also settles what the current model is on a session that had never said.
 *
 * ## What happens when the session is busy
 *
 * Nothing, and it says so. `typeCommand` refuses to write into a session that is
 * mid-turn, has a draft in the composer, or is waiting on a dialog, and that
 * refusal is passed straight back for the UI to print. The list then falls back
 * to the captured one — see `FALLBACK_MODELS` — which is the same picker from a
 * real CLI, one version old at worst.
 */
export async function discoverModels(
  access: SessionAccess,
  sessionId: string,
  provider: string | undefined,
  timings: ApplyTimings = SHIPPED_TIMINGS,
): Promise<ModelCatalogResult> {
  const opening = await access.screen(sessionId)
  if (opening === null) return { models: [], message: 'That session is no longer running.' }

  const saw = readAgentFromScreen(opening)
  const foreign = refuseByProvider(provider, saw === null ? NO_AGENT : { running: true, evidence: 'screen', saw })
  if (foreign !== null) return { models: [], message: foreign }

  const typed = await typeCommand(access, sessionId, '/model', timings)
  if (!typed.ok) return { models: [], message: typed.message }

  const rows = await waitForScreen(access, sessionId, timings.command, timings.poll, readModelPicker)

  /*
   * Esc goes out whether or not the picker was read, and that is deliberate.
   *
   * If it opened and was parsed, this is the cancel. If it opened and could not
   * be parsed — a shape this build has not seen — this still closes it, which
   * matters far more than the reading did: leaving somebody's session sitting in
   * a modal dialog because an app opened one and walked away is the worst thing
   * in this file it is possible to do.
   */
  access.write(sessionId, '\x1b')

  if (rows === null) {
    return { models: [], message: 'Opened the model list but could not read it, so it was cancelled and nothing changed.' }
  }
  return { models: foldDefaultRow(rows), message: null }
}

async function currentModel(
  access: SessionAccess,
  sessionId: string,
  cwd: string | undefined,
  configDir?: string,
): Promise<ControlReading> {
  const screen = await access.screen(sessionId)
  const confirmed = screen === null ? null : readModelFromScreen(screen)
  if (confirmed) return { value: confirmed, label: confirmed, source: 'screen' }
  if (!cwd) return UNKNOWN
  const raw = await readModelFromTranscript(cwd, configDir)
  return raw ? { value: raw, label: labelModelId(raw), source: 'transcript' } : UNKNOWN
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

export interface ReadRequest {
  sessionId?: string
  cwd?: string
  /** See {@link ApplyRequest.provider}. Absent readers get the old behaviour. */
  provider?: string
  /** See {@link ControlScope}. Absent means a session on this computer. */
  scope?: ControlScope
}

export function registerAgentControlsIpc(ipcMain: IpcMain, access: SessionAccess): void {
  ipcMain.handle('agent:controls:read', (_event, request: ReadRequest) =>
    readControls(access, request?.sessionId, request?.cwd, request?.provider, request?.scope),
  )
  ipcMain.handle('agent:controls:apply', (_event, request: ApplyRequest) => applyControl(access, request))
  /*
   * Its own channel rather than a flag on the read, because the two are
   * different in the one way that matters: reading is passive and happens every
   * time the session prints anything, while this **types into the session**.
   * Folding it into `agent:controls:read` would put a keystroke on a code path
   * that fires on a timer, which is how an app comes to open a dialog in
   * somebody's terminal while they are working in it.
   */
  ipcMain.handle('agent:controls:models', (_event, request: ReadRequest) =>
    request?.sessionId
      ? discoverModels(access, request.sessionId, request.provider)
      : Promise.resolve<ModelCatalogResult>({ models: [], message: 'No session to ask.' }),
  )
}
