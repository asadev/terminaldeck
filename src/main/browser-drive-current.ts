/**
 * Which `BrowserDrive` this process is driving, held apart from what built it.
 *
 * ## The edge this exists to cut
 *
 * `deck-control/index.ts` needs exactly one thing out of the drive's wiring —
 * *"is there a drivable page, and which"* — for `whereTool`'s `page()`. It got
 * it by importing `browserDrive` from `browser-drive-ipc.ts`, which is the
 * Electron half: `app`, `BrowserWindow`, `WebContentsView`, `nativeImage`, all
 * at module scope. So one accessor dragged Chromium into every closure that
 * reached `deck-control`, and `src/headless/host.ts` wrote its refusal to build
 * a tool endpoint around exactly that sentence:
 *
 * > `deck-control/index.ts` imports `browserDrive` from `../browser-drive-ipc`,
 * > which loads `browser-tab` and `browser-driver` … at module scope.
 *
 * A holder is the smallest thing that answers the question without the shell
 * that built the answer, and it is the same split `browser-downloads-store.ts`
 * made from `browser-downloads-electron.ts`: the *state* is plain, only the
 * *construction* is Electron's. `seam.test.ts` walks the headless entries and
 * refuses `browser-drive-ipc.ts` in that closure by name, which is what keeps
 * this module from quietly growing the import back.
 *
 * ## One holder, two builders
 *
 * The desktop's builder is `registerBrowserDriveIpc`, over Electron views. The
 * server's is `src/headless/host.ts`, over `HeadlessDriveHost` and a real
 * Chromium of its own. Both set this; nothing else may. A process has one drive
 * because it has one browser, and a second holder would be a second answer to
 * *"which page is the copilot looking at"*.
 *
 * Null is a real state and every reader treats it as one: the drive is built
 * during boot, and a catalogue assembled before it — or on a build that has no
 * browser at all — must answer "no page" rather than crash.
 */

import type { BrowserDrive } from './browser-driver'

let current: BrowserDrive | null = null

/**
 * Publish the drive this process is driving. Called once, by whichever shell
 * built it; `null` unsets it, which only a test has cause to do.
 */
export function setBrowserDrive(drive: BrowserDrive | null): void {
  current = drive
}

/** The live drive, for anything assembled after the shell built it. Null before it. */
export function browserDrive(): BrowserDrive | null {
  return current
}
