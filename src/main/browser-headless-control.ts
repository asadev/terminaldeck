/**
 * The dispatcher that lets a device drive the server's browser — the real
 * `DeckControl`, holding only the browser verbs, over the headless drive.
 *
 * ## Why a DeckControl and not a thinner shim
 *
 * `remote/machines/window-serve.ts` is emphatic that the tier check, the
 * confirmation gate, the budgets and the action log are `deck-control`'s and
 * *"none of that is re-implemented here and none of it may be — a second
 * dispatcher is how one of them comes to allow what the other refuses."* So a
 * server that serves `window.call` must reach the same class the desktop does.
 * The desktop's assembly (`deck-control/index.ts`) cannot come to a headless
 * bundle — it builds an Electron approver window, a live surface over
 * `settings-extra`, and imports `browserDrive` from the Electron
 * `browser-drive-ipc`. This does not: `control.ts`, `browser-tools.ts`,
 * `action-log.ts` and `consent.ts` are all Electron-free (checked by
 * `seam.test.ts` walking this into the closure), so the exact machinery is
 * reused with none of the renderer under it.
 *
 * ## What it is, and what it deliberately is not
 *
 * It advertises the whole catalogue — `buildCatalogue()` always runs — but the
 * only handlers wired to anything live are the browser verbs, contributed as
 * `extraTools` over the drive. Nothing lists or calls the rest: `window-serve.ts`
 * gates every forwarded call on `ELSEWHERE_TOOLS` (the browser family) before it
 * reaches here, and there is no MCP endpoint on this host that would `tools/list`
 * them. So the {@link headlessSurface} the built-ins would read is never touched;
 * it throws if it ever is, which is the honest state rather than a stub that
 * pretends to answer.
 *
 * ## Confirmations
 *
 * The caller passes `attended` per call (`window-serve.ts` reads it from the
 * host), and on a server with no person at the keyboard it is false — so every
 * `alter`-tier step is refused with `not-permitted-unattended` rather than put to
 * a broker that cannot reach anyone. That is a real limit, not a bug: reading and
 * navigating the server's browser work across the wire; typing into a public site
 * waits on routing the confirmation to the connected owner's device, which is the
 * follow-up the consent broker here is shaped for but not yet wired to. The
 * broker's `ask` returns false (nobody to ask) and is never reached while
 * `attended` is false, so nothing auto-approves.
 */

import { ActionLog } from './deck-control/action-log'
import { browserTools } from './deck-control/browser-tools'
import { ConsentBroker } from './deck-control/consent'
import { DeckControl } from './deck-control/control'
import type { DeckSurface } from './deck-control/surface'
import type { BrowserDrive } from './browser-driver'

/**
 * A surface that answers nothing, because on this host nothing asks it.
 *
 * The browser verbs read the drive they close over, never the surface, and
 * `window-serve.ts` never forwards a non-browser verb here — so the only way a
 * property of this is read is a bug, and a throw naming the bug beats a stub that
 * returns a plausible empty answer for a session list that is really elsewhere.
 */
function headlessSurface(): DeckSurface {
  const unavailable = (): never => {
    throw new Error(
      'this headless browser control serves only browser verbs; it has no session, file or settings surface',
    )
  }
  return new Proxy({} as DeckSurface, { get: () => unavailable })
}

export interface HeadlessBrowserControlDeps {
  drive: BrowserDrive
  /** The action-log directory. Every browser verb a device drives lands here. */
  logDir: string
  /** Epoch ms. Injected so a test can freeze it. */
  now?: () => number
}

/**
 * Build the server's browser-verb `DeckControl`.
 *
 * Handed to `window-serve.ts` as its `control()`, so a forwarded `window.call`
 * is dispatched with the real tier/consent/budget/log machinery around the
 * headless drive.
 */
export function createHeadlessBrowserControl(deps: HeadlessBrowserControlDeps): DeckControl {
  return new DeckControl({
    surface: headlessSurface(),
    log: new ActionLog({ dir: deps.logDir }),
    // Nobody to ask on a server; never reached while callers are unattended.
    consent: new ConsentBroker({ ask: () => false, settled: () => {} }),
    extraTools: browserTools(deps.drive),
    ...(deps.now === undefined ? {} : { now: deps.now }),
  })
}
