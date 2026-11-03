/**
 * Dropping something onto a terminal.
 *
 * ## What happened before this existed
 *
 * Nothing — and *nothing* is the generous reading. No terminal in this app had a
 * drop handler: not `TerminalView`, not `RemoteTerminal`, not `ServerTerminal`.
 * A file dragged from Finder onto a session therefore reached the window's
 * default handling, which in Chromium is to **navigate to it**. Dropping a photo
 * on your agent replaced the application with a picture of the photo. That is
 * the shape of the defect: not a feature that was missing, a gesture that did
 * something wrong.
 *
 * Asad, 2026-08-20:
 *
 *   > *"photo dropping, the way we did with the phone — also any kind of media
 *   > dropping from your PC to any session should smoothly work."*
 *
 * ## What a drop does now, and why it is typing
 *
 * It types the path at the prompt, shell-quoted, followed by a space — which is
 * exactly what `HostLink.sendPath` on the phone does with the path a Mac answers
 * an upload with, and what every terminal emulator on this platform does with a
 * dropped file. It is *his* gesture, so typing on the back of it is his text and
 * not an announcement; nothing else is written, and in particular no Return is
 * sent. What to do with the path is the person's decision and the prompt is
 * where they make it.
 *
 * For a session on **another machine** the path has to exist over there first,
 * so the file is sent — the same `upload.*` verbs the phone uses, see
 * `main/remote/machines/upload-send.ts` — and what gets typed is the path the
 * far machine answers with, which may not be the name the file left with. A
 * second `photo.jpg` lands beside the first rather than over it.
 *
 * That decision is **no longer made here**. It was, for a day, and it was the
 * only place in the app that made it — so the browser's screenshot went on
 * sending a path under this Mac's Pictures folder to a session on a PC, which
 * could not open it. `session-transfer.ts` owns the question now and this file
 * is one of its callers; what is left below is the part that is genuinely about
 * a *drop*: what a drag is carrying, what a path looks like at a prompt, and
 * what one line about a transfer in flight may say.
 *
 * ## Why the paths are asked for one at a time
 *
 * A multi-file drop onto a remote session becomes one transfer after another,
 * because the host serves one upload per connection. They are typed as they
 * land, so a drop of four files fills the prompt as it goes rather than after
 * the last one — and a failure part way through leaves the ones that did land on
 * the line, which is true and useful, rather than discarding them to keep the
 * gesture atomic.
 */

import { shellQuote } from './chat/attach/mentions'
import type { Handover } from './session-transfer'

/**
 * Whether this drag is carrying files, as opposed to text or nothing.
 *
 * Read off `types` rather than off `items`, because during `dragover` the
 * browser deliberately hides the *contents* of a drag — `items[i].getAsFile()`
 * answers null until the drop — while still saying what kinds are on offer. A
 * handler that tried to count files on `dragover` would decide every drag was
 * empty and refuse to show a target.
 */
export function draggingFiles(transfer: Pick<DataTransfer, 'types'> | null): boolean {
  if (!transfer) return false
  for (const kind of transfer.types) {
    if (kind === 'Files') return true
  }
  return false
}

/** What this bridge has to be able to do for a drop to resolve real paths. */
export interface DropBridge {
  /** The real path behind a dropped `File`, or '' when there is not one. */
  pathForDroppedFile(file: File): string
}

/**
 * The real paths behind a drop, in the order they were dropped.
 *
 * Anything with no path behind it is left out rather than reported: dragging
 * *selected text* produces a `File`-shaped item with nothing on disk under it,
 * and that is a normal thing for somebody to do over a terminal. The text branch
 * below is what answers that drag.
 */
export function droppedPaths(files: readonly File[], bridge: DropBridge): string[] {
  const paths: string[] = []
  for (const file of files) {
    const path = bridge.pathForDroppedFile(file)
    if (path !== '') paths.push(path)
  }
  return paths
}

/**
 * A path as it should appear at a prompt: quoted, with one trailing space.
 *
 * The space is not cosmetic. Without it a second dropped file abuts the first
 * and the shell reads one word; with it, dropping four files produces four
 * arguments. `shellQuote` picks its quoting from the shape of the path rather
 * than from this machine, which is what makes it right for a Windows path
 * arriving over a link — see its own note.
 */
export function promptWord(path: string): string {
  return `${shellQuote(path)} `
}

/**
 * Text dropped on a terminal, ready to go in, or '' if there is none.
 *
 * `\r\n` and lone `\r` both become `\n`, because a carriage return arriving at a
 * pty *is* a Return: a two-line snippet dropped on a shell would run its first
 * line before the second had been read. What makes even the newlines safe is
 * where this text goes — `Terminal.paste`, not a raw write — so a session in
 * bracketed-paste mode receives it wrapped in `ESC[200~ … ESC[201~` and the
 * shell inserts it rather than executing it. That is the same treatment a real
 * ⌘V gets in the same terminal, which is the point: a drop should not be more
 * dangerous than a paste of the same text.
 */
export function droppedText(raw: string): string {
  if (raw === '') return ''
  return raw.replace(/\r\n?/g, '\n')
}

/**
 * The bridge, or null where this build does not carry it.
 *
 * Read defensively rather than assumed, the same way `resolveBridge` in
 * `machines/types.ts` and `resolveOutsideBridge` in `chat/attach/outside.ts` are:
 * an app whose preload is older than this handler should say so once rather than
 * throw inside a drop and leave the gesture doing nothing at all.
 */
export function resolveDropBridge(injected?: DropBridge): DropBridge | null {
  if (injected) return injected
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Partial<DropBridge> }).deck
  return host && typeof host.pathForDroppedFile === 'function' ? (host as DropBridge) : null
}

/**
 * What the far machine said about a file this window sent it.
 *
 * The type and the reader both live in `session-transfer.ts` now, which owns the
 * whole question of *which* machine a session's file has to exist on. They are
 * re-exported under the names this file gave them so that nothing which already
 * reads a drop's answer had to change in order to gain a shared one — and so
 * that the next surface to need it finds it in the module that owns the rule
 * rather than in the drop handler that happened to implement it first.
 */
export type UploadOutcome = Handover

export { readHandover as readUploadOutcome } from './session-transfer'

/**
 * One short line about a transfer, or '' when there is nothing to say.
 *
 * A line, not a panel, and it is deliberately not a sentence about what is
 * happening: *"Sending holiday photo.jpg — 42%"* would be prose on a terminal,
 * which is the standing rule this round. The name and the number are the two
 * things a person cannot see for themselves.
 *
 * Nothing is said once it has landed. The success signal is the path appearing
 * at the prompt, which is the thing they asked for; a line saying it worked
 * would be narrating something already on screen.
 */
export function transferLine(progress: {
  name: string
  size: number
  sent: number
  phase: string
  message: string
}): string {
  if (progress.phase === 'failed') return progress.message
  if (progress.phase === 'landed') return ''
  if (progress.phase === 'finishing') return `${progress.name} — finishing`
  if (progress.size <= 0) return progress.name
  const percent = Math.min(100, Math.floor((progress.sent / progress.size) * 100))
  return `${progress.name} — ${percent}%`
}
