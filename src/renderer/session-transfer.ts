/**
 * The one question every surface that hands a file to a session has to ask:
 * **does that session run on this machine, and if it does not, how do I put the
 * file somewhere it can see?**
 *
 * ## Why it is a module and not four answers
 *
 * `terminal-drop.ts` got this right on 2026-08-20 and wrote the rule down in its
 * own header: a local session is handed a path, a session on another machine is
 * handed the path *that machine* answered an upload with. It was then the only
 * place in the app that knew it. Everything else that produced a file for an
 * agent — the browser's screenshot, the marked-up frame, a paste — composed a
 * message around `shot.path`, a path under **this** computer's Pictures folder,
 * and sent it to whichever session the picker was set to. Asad, 2026-08-20:
 *
 *   > *"if I send those to the session which is in server but the browser was in
 *   > local, it will send the path of my current PC instead of the server where
 *   > actually session is running. So in that case session will not be able to
 *   > see the things that I have sent… it should not matter which device I am on
 *   > currently running the session and my browser can be on different… it will
 *   > automatically just upload and give the local path for the relevant session
 *   > device."*
 *
 * So the rule, stated once and applied everywhere:
 *
 *   > Whatever a session is handed must exist **on the machine that session runs
 *   > on**, and be named by **that machine's** path. Same machine → a path.
 *   > Different machine → upload first, then hand over the path the far machine
 *   > answered with. The user never sees the difference.
 *
 * A fourth entry point cannot answer it differently, because there is one
 * function and it is the one every entry point calls.
 *
 * ## What decides, and what deliberately does not
 *
 * The **session's** machine, and nothing else. Not which window the gesture
 * happened in, not which machine the browser is showing a page from, not the
 * device somebody is sitting at driving this app. Those are all the same
 * question dressed up, and each one that got its own answer is a way for the
 * behaviour to change between two situations that should look identical — which
 * is R5, and is the same rule this app already had to be rewritten for once:
 * *"the shape of the application should not be changing for local and remote
 * devices."*
 *
 * ## There is no second transfer here
 *
 * The cross-machine leg is `uploadToMachine`, which is `machines:upload`, which
 * is `main/remote/machines/upload-send.ts`, which is the same four `upload.*`
 * verbs the phone sends. Nothing in this file speaks to a socket. A second
 * protocol for the same act would be a second set of bugs and the host would
 * have had to grow a branch for it.
 *
 * ## The third leg, and why it is genuinely a third
 *
 * A terminal on a **server** is a session too, and until 2026-08-21 it was the
 * one kind this file could not answer for: a server row carries no `machineId`,
 * so it fell through {@link runsHere} and was handed a path on this laptop —
 * silently, which is the worst of the three possible wrongs. That is the exact
 * case in the quotation above, where he says *"the session which is in server"*.
 *
 * It is not `uploadToMachine` with a different id, because there is no relay and
 * no copy of this app over there: it is SFTP on the connection the servers area
 * is already holding (`servers:upload` → `servers/connection.ts`'s `putFile`).
 * What the two legs share is their **answer**, read by one {@link readHandover}
 * — so the two cannot drift into different behaviour for the same act.
 *
 * ## Bytes, and why they become a file before they go anywhere
 *
 * A drop hands over a path; a **paste** and a screenshot taken out of a web page
 * hand over bytes with no file behind them. Both legs of the rule need a file:
 * a local session has to be given a path to something that exists, and
 * `upload-send.ts` reads from a path by design — handing it an ArrayBuffer would
 * put a 200 MB video through two heaps on its way to a third computer. So bytes
 * are written once, here on this machine, into the same folder an upload from a
 * phone lands in, and then the ordinary rule runs over the path that produced.
 * A pasted screenshot going to a remote session therefore lands in
 * `<downloads>/Terminal Deck` on **both** machines, which is also the least
 * surprising thing that can happen to it.
 */

/**
 * Where a session runs, as far as a transfer is concerned.
 *
 * Mirrors the two fields `AgentSession` already carries, so the browser's picker
 * rows are `SessionPlace`s without conversion and a caller cannot accidentally
 * supply the machine the *window* is looking at instead of the machine the
 * session is on.
 */
export interface SessionPlace {
  /** The paired machine it runs on. **Empty means this computer.** */
  machineId: string
  /** What that machine is called here. Empty for this one. Never guessed. */
  machineName?: string
  /**
   * The server it is a terminal on. Absent or empty means it is not one.
   *
   * Never set at the same time as {@link machineId}: a session runs on this
   * computer, on a paired machine, or on a server, and the three are three
   * routes rather than three shades of one. Optional because most callers
   * predate servers having sessions at all and mean "not a server" by saying
   * nothing — which is what {@link runsHere} reads it as.
   */
  serverId?: string
}

/** A path on the machine the session runs on, or a sentence saying why not. */
export type Handover = { ok: true; path: string } | { ok: false; message: string }

/** A file that already exists on this machine. */
export interface FileSource {
  path: string
}

/** Bytes this window is holding, with the name they should land under. */
export interface BytesSource {
  name: string
  bytes: ArrayBuffer
}

/** Either of the two things a surface can have in its hand. */
export type TransferSource = FileSource | BytesSource

/** What this needs off the preload. Both halves are feature-detected. */
export interface TransferBridge {
  /**
   * Send a file on this machine to a paired one, and answer where it landed.
   *
   * The far machine names the file — see `upload-send.ts` — so the answer may
   * not be the name it left with. That is the point: a second `photo.jpg` lands
   * beside the first over there rather than on top of it.
   */
  uploadToMachine(machineId: string, filePath: string): Promise<unknown>
  /**
   * Write bytes to a file on **this** machine and answer its path.
   *
   * Optional because a preload older than this feature does not have it, and a
   * paste of an image into a session must then refuse with a sentence rather
   * than throw `undefined is not a function` into an event handler and leave the
   * gesture doing nothing at all — which is the failure this whole round exists
   * to remove.
   */
  stageForSession?(name: string, bytes: ArrayBuffer): Promise<unknown>
  /**
   * Send a file on this machine to a **server**, and answer where it landed.
   *
   * Optional for the same reason `stageForSession` is: a preload older than this
   * channel must refuse a transfer to a server with a sentence rather than throw
   * `undefined is not a function` into a click handler. The server names the
   * file, exactly as a paired machine does, so the answer may not be the name it
   * left with.
   */
  uploadToServer?(serverId: string, filePath: string): Promise<unknown>
}

/**
 * True when the session runs on the computer this window is running on.
 *
 * Both fields, because either one of them being set means it does not. Reading
 * `machineId` alone is what handed a terminal on a server a path under this
 * Mac's Pictures folder, with nothing on screen saying anything had gone wrong.
 */
export function runsHere(place: SessionPlace | null | undefined): boolean {
  return !place || (place.machineId === '' && (place.serverId ?? '') === '')
}

/** True when this source is bytes rather than a file already on disk. */
export function isBytes(source: TransferSource): source is BytesSource {
  return (source as BytesSource).bytes !== undefined
}

/**
 * Narrow what came back over IPC, and never answer "it worked" without a path.
 *
 * Both channels answer the same shape and are narrowed the same way, because the
 * one wrong answer either of them can give is an `ok` with an empty path: the
 * caller would type two quote marks at a prompt, or compose `[browser
 * screenshot: ]`, and the person would have no idea why.
 *
 * Moved here from `terminal-drop.ts`, which still re-exports it under its old
 * name so that nothing that already reads a drop's answer had to change to gain
 * a shared one.
 */
export function readHandover(response: unknown): Handover {
  if (!response || typeof response !== 'object') {
    return { ok: false, message: 'Sending files is not available in this build.' }
  }
  const body = response as { ok?: unknown; path?: unknown; message?: unknown }
  if (body.ok === true && typeof body.path === 'string' && body.path !== '') {
    return { ok: true, path: body.path }
  }
  return {
    ok: false,
    message: typeof body.message === 'string' && body.message !== '' ? body.message : 'That file did not send.',
  }
}

/**
 * The bridge, or null where this build does not carry it.
 *
 * Read defensively rather than assumed, the same way `resolveDropBridge` and
 * `resolveBridge` in `machines/types.ts` are. `uploadToMachine` is the method
 * that makes this bridge worth having; `stageForSession` is checked at the point
 * of use, so a build with only the first still hands paths across machines.
 */
export function resolveTransferBridge(injected?: TransferBridge | null): TransferBridge | null {
  if (injected) return injected
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<TransferBridge> }).deck
  return host && typeof host.uploadToMachine === 'function' ? (host as TransferBridge) : null
}

/**
 * Put a file where the chosen session can open it, and answer with **its** path.
 *
 * Resolves rather than throws on every failure, including the ones that never
 * leave this window, because every caller is a gesture somebody made and the
 * only wrong answer is silence.
 *
 * The order of the two steps is not interchangeable. Bytes are staged on this
 * machine **first** and the cross-machine leg then runs over the resulting path,
 * so there is exactly one implementation of "send a file to that computer" and
 * it is the one the phone uses. Staging second — uploading bytes directly —
 * would be the second transfer this file exists to not have.
 */
export async function pathForSession(
  place: SessionPlace | null | undefined,
  source: TransferSource,
  bridge?: TransferBridge | null,
): Promise<Handover> {
  const api = resolveTransferBridge(bridge)
  if (!api) return { ok: false, message: 'Sending files is not available in this build.' }

  let here: string
  if (isBytes(source)) {
    if (source.bytes.byteLength === 0) return { ok: false, message: 'There was nothing to send.' }
    if (typeof api.stageForSession !== 'function') {
      return { ok: false, message: 'Sending files is not available in this build.' }
    }
    const staged = readHandover(await api.stageForSession(source.name, source.bytes).catch(() => null))
    if (!staged.ok) return staged
    here = staged.path
  } else {
    if (source.path === '') return { ok: false, message: 'There was nothing to send.' }
    here = source.path
  }

  // Same machine: the file is already where the session can open it, and its
  // path is that machine's path. Nothing crosses anything.
  if (runsHere(place)) return { ok: true, path: here }

  // Somewhere else: the far end names the file and answers with its own path,
  // which is what gets handed over. `place` is non-null here — `runsHere` is
  // true for null — and TypeScript needs saying so.
  const there = place as SessionPlace
  if ((there.serverId ?? '') !== '') {
    if (typeof api.uploadToServer !== 'function') {
      return { ok: false, message: 'Sending files to a server is not available in this build.' }
    }
    return readHandover(await api.uploadToServer(there.serverId as string, here).catch(() => null))
  }
  return readHandover(
    await api.uploadToMachine(there.machineId, here).catch(() => null),
  )
}
