/**
 * What a paired device is allowed to ask about the copilot's own files.
 *
 * ## Why this is an interface and not the implementation
 *
 * The same seam `CopilotRemote` is, for the same two reasons. `server.ts` speaks
 * WebSocket frames and knows which device a socket belongs to; the thing behind
 * this interface reads `<userData>/copilot-layer/`, stats a folder somebody
 * chose, and parses front matter out of an agent's memory. Neither has any
 * business importing the other — the endpoint is exercised over a plain loopback
 * socket with no Electron in the room, and this interface's real implementation
 * lives in `src/main/copilot-files.ts`, which reaches `copilot-inspect.ts` and
 * so reaches `electron` at module scope. A `remote/` module that imported it
 * would take the headless bundle down at import time rather than at call time,
 * which is the trap `staleAgents` records in `headless/host.ts`.
 *
 * It also decides the shape of the negotiation, and here that matters more than
 * usual. **Absent is the switch**: a host constructed without one of these does
 * not advertise `copilot.files`, so a phone talking to it draws no Files card
 * and sends no frame that would be refused. The headless daemon is exactly that
 * host and deliberately stays that way — it runs no copilot, so its
 * `copilot-layer/` was never written, and a card listing four files that do not
 * exist is worse than the absence rather than better. That is the same trade the
 * daemon already states about the copilot itself.
 *
 * ## The rule every string that comes back has to keep
 *
 * **Nothing here composes a path from anything a client sent, and nothing here
 * puts a path into a sentence.** The first half is `protocol.ts`'s — see
 * `copilotFileTarget`, which is the only thing that turns a wire id into
 * anything, and which knows nothing about where the copilot lives. The second
 * half is this file's: every `error` on this interface is a sentence composed on
 * this machine for a person to read on a phone, and an implementation that
 * passed `ENOENT: no such file or directory, open '/Users/…'` through would be
 * putting the owner's account name onto a relay to save itself a line.
 *
 * The rows are the same rule in the other direction: `StartupFile` and
 * `MemoryFact` both carry `path` and {@link CopilotFileRow} deliberately does
 * not. A phone cannot open an absolute path, and a path on a row is a path a
 * client is tempted to send back.
 *
 * ## What it deliberately cannot do
 *
 * Create. There is no `create` verb and there is not going to be one. The three
 * writers behind this all refuse to write a file that is not already there —
 * `writeMemoryFact` states the argument at length and it is the right one: a
 * remote surface that could plant a fact in `memory/` would be a second author
 * of the directory that is read into the model's context at every start, with no
 * conversation behind it and nothing in the transcript explaining where the fact
 * came from. `copilot.file.write` on the folder's own `CLAUDE.md` is the one
 * exception and it is the desktop's exception, not this wire's: that file
 * genuinely may not exist yet, and `writeFolderInstructions` is what decides.
 */

import type { CopilotFileRow, CopilotFileTarget } from './protocol'

/** What a write, a reset or a delete did, in the only two shapes a phone needs. */
export interface CopilotFileWrite {
  ok: boolean
  /**
   * Why nothing was saved, or null.
   *
   * A sentence, always — never a code and never an `errno`. Most of them are
   * `copilot-home.ts`'s own wording, which was written for the box on the
   * settings pane and reads correctly on a phone because it names the *file's*
   * problem rather than the app's: *"Instructions cannot be empty — a copilot
   * with no instructions still has its tools and its boundary, and nothing
   * telling it what it is for."*
   */
  error: string | null
}

/** One file's contents, or the sentence saying why there are none. */
export interface CopilotFileText {
  /** The file, whole. Empty whenever {@link error} is set — never a partial read. */
  text: string
  error: string | null
}

export interface CopilotFiles {
  /**
   * Every file, described without being opened.
   *
   * Read off the disk on every call rather than remembered, for the reason
   * `copilotStartupFiles` gives about itself: the interesting case is the one
   * where somebody has just edited a file — here, at the machine, or in their
   * own editor — and wants to see that it landed.
   */
  list(): CopilotFileRow[]

  /**
   * One file, whole, or a sentence.
   *
   * Never truncated. Every box on the surface this feeds has a Save button under
   * it, and `readCopilotInstructions` says why that settles it: an editor
   * showing a truncated file is a delete waiting for somebody to press the
   * button. A file too large for the wire comes back as an error naming its size
   * and pointing at the machine.
   */
  read(target: CopilotFileTarget): CopilotFileText

  /**
   * Save one file, on a person's press and never otherwise.
   *
   * Refused for the two generated files — there is no `write-contract` channel
   * at the desk either, and for the same reason: a hand-edited copy of a
   * generated description drifts from the thing it describes. Refused for a file
   * already too large to have been read whole. Refused by the desktop's own
   * three checks after that, which are not restated over here.
   *
   * Whatever lands is recorded in the action log as **a paired device's** doing,
   * not as *from Settings*. An audit log is worth what its rows can be trusted
   * to mean, and a row that could be read as somebody at the keyboard is a row
   * that lies about the one edit hardest to explain afterwards.
   */
  write(target: CopilotFileTarget, text: string): CopilotFileWrite

  /**
   * Put this build's instructions back, keeping what was there.
   *
   * Takes nothing, because there is exactly one file this build ships a default
   * of. A seam that took a target would imply there are others and would push
   * the deciding onto whoever wires it next; `server.ts` refuses every other id
   * with a sentence before it gets here.
   */
  reset(): CopilotFileWrite

  /**
   * Forget one memory.
   *
   * The only verb on this interface that unlinks anything, and the name has
   * already been through `isCopilotMemoryName` on the wire. It goes through
   * `isMemoryName` again inside `deleteMemoryFact` before `rmSync` sees it —
   * two checks, and the one that counts lives in the module that owns the rule.
   */
  forget(name: string): CopilotFileWrite
}
