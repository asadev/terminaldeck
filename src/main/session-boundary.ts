import type { Platform } from './platform/host'
import { currentPlatform } from './platform/host'
import { within, type ConfinementPlan } from './confine/plan'

/**
 * Which sessions are held inside a folder, so that the composer can stop
 * offering them a file they will never be allowed to open.
 *
 * ## The question this answers, and why nothing could answer it before
 *
 * `confine/` builds a plan, proves it against the real sandbox and spawns
 * through it — and then throws the plan away. That was fine while the only
 * consumer of the boundary was the boundary itself. It stopped being fine the
 * moment a message could carry a path from outside the project, because two
 * facts collide:
 *
 *  1. A session started from a paired device, or by the copilot, is confined.
 *     Measured on this machine, in `confine/escapes.test.ts` — *"cannot read a
 *     file elsewhere by absolute path"* — the OS refuses the read outright.
 *  2. A confined session still appears as an ordinary tab in this window.
 *     `onSessionCreated` puts a phone's session in the tab list on purpose, and
 *     the copilot's sessions are deliberately ordinary sessions. So the chat
 *     composer can be pointed at one, and `SessionMeta` carries nothing that
 *     says so.
 *
 * Put those together and "Browse…" on a confined session would open a panel over
 * the whole disk, accept a pick, draw a chip, send an `@"/Users/…"` mention, and
 * the agent would answer that it cannot read the file. Every part of that
 * sequence looks like it worked except the last one, which is the definition of
 * a fake feature. So the plan is written down here at the spawn and read back
 * when the composer needs to know.
 *
 * ## What is *not* here
 *
 * A permission. Nothing in this module grants or denies anything — the OS does
 * that, and it would go on doing it whether or not this file existed. This is
 * only the app finding out in advance what the answer will be, so it can say so
 * before the user chooses rather than after the agent fails. If this registry is
 * empty or wrong, the boundary still holds; the UI just becomes less helpful,
 * which is the correct direction for this kind of mistake to fail in.
 *
 * ## Why a module-level map
 *
 * The same reason `plan-limit.ts` and `usage-ipc.ts` keep theirs: the writer is
 * the spawn path in `host-core.ts` and the reader is an IPC handler registered
 * in `index.ts`, and threading a value between those two would mean adding a
 * field to `HostCore` that the headless build has no use for. The entries are
 * keyed by a `randomUUID` session id and dropped when the session exits, so the
 * map is the size of the number of confined sessions running right now.
 */

/**
 * What one confined session may reach.
 *
 * A flattened copy of `ConfinementPlan` rather than the plan itself, because the
 * plan is the sandbox's business and grows fields for the sandbox's reasons —
 * `readableFiles`, `accountHome`, the device's own home. What a *reader* needs
 * is one list of roots and the folder to name in a sentence.
 */
export interface SessionBoundary {
  /** The granted folder, resolved. The one to name when explaining a refusal. */
  folder: string
  /**
   * Every directory the session can read, the granted folder included.
   *
   * Writable and readable together, because a file this app is deciding whether
   * to attach only needs to be *readable* and the distinction between the two
   * lists does not survive that question. It includes the operating system's own
   * directories and the tool roots, which is correct and occasionally surprising:
   * a confined session genuinely can read `/usr/share/dict/words`, and saying it
   * cannot would be a different lie from the one this module exists to prevent.
   */
  readable: readonly string[]
  /** Individual files reachable without their directory being reachable. */
  readableFiles: readonly string[]
  /**
   * The person's own project folders this session may read, which is a thing
   * only the copilot has.
   *
   * Held apart from {@link readable} because it is the half a *sentence* can be
   * built from. "This session can read /usr/lib" is true and useless; "this
   * session can read its own folder and the projects you have open" is what the
   * copilot actually is, and saying only the first half of that would be an
   * explanation that is wrong about a whole feature. Empty for every other kind
   * of confined session — an ordinary grant is one folder.
   */
  readableProjects: readonly string[]
  /** Which parser to compare paths with. A WSL session's plan is POSIX. */
  platform: Platform
}

const boundaries = new Map<string, SessionBoundary>()

/**
 * Remember what a session was confined to, at the moment it was confined.
 *
 * Called from the one place that builds a plan for a real spawn. A session that
 * is not confined is never noted, and {@link boundaryFor} answering null is what
 * "this session can read anything the account can" means — which is the truth
 * for every session started at this keyboard.
 */
export function noteBoundary(
  sessionId: string,
  plan: ConfinementPlan,
  platform: Platform = currentPlatform(),
): void {
  boundaries.set(sessionId, {
    folder: plan.folder,
    readable: [...plan.writable, ...plan.readable],
    readableFiles: plan.readableFiles,
    readableProjects: plan.readableProjects,
    platform,
  })
}

/** Forget a session. Wired to the pty's exit, beside the ledger's own forget. */
export function forgetBoundary(sessionId: string): void {
  boundaries.delete(sessionId)
}

/** What this session is held inside, or null when it is held inside nothing. */
export function boundaryFor(sessionId: string): SessionBoundary | null {
  return boundaries.get(sessionId) ?? null
}

/** Test seam. Nothing in the app calls this. */
export function resetBoundaries(): void {
  boundaries.clear()
}

/**
 * Could this session open this path?
 *
 * Deliberately conservative in one direction only. A path under any root in the
 * plan is reachable; anything else is reported unreachable even though a
 * determined reading of the sandbox profile might find an exception. Being wrong
 * this way costs a user one extra sentence explaining why a file was refused;
 * being wrong the other way costs them a message that looked sent and was not.
 */
export function boundaryAllows(boundary: SessionBoundary, path: string): boolean {
  if (boundary.readableFiles.some((file) => file === path)) return true
  return boundary.readable.some((root) => within(path, root, boundary.platform))
}
