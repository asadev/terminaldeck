import { GUEST_PRELOAD_SOURCE } from './browser-preload'

/**
 * The guest preload, re-delivered to a real Chromium over CDP.
 *
 * ## Why this file exists
 *
 * On the desktop the guest page runs `browser-preload.ts`'s script because
 * Electron loads it *as a preload* — a file named in `webPreferences`, run in an
 * isolated world before any page script, with `require('electron').ipcRenderer`
 * wired up for it. Route B drives a real headless Chromium over a pipe, and CDP
 * has no preload mechanism and no `ipcRenderer`. So the same script has to be
 * delivered a different way and given the same two things it depends on: it must
 * run before the page's own scripts, in every document, in an isolated world;
 * and its `ipcRenderer.send` / `ipcRenderer.on` calls have to reach the host.
 *
 * Two CDP primitives do it, and this file is the shim that joins them to the
 * script that already exists:
 *
 *  - `Page.addScriptToEvaluateOnNewDocument { source, worldName }` runs a script
 *    before every document's own scripts, in a named isolated world — the exact
 *    per-view, run-first, isolated semantics an Electron preload has.
 *  - `Runtime.addBinding { name, executionContextName }` installs one function in
 *    that world that, when the page calls it, fires `Runtime.bindingCalled` back
 *    to the host with the string it was passed. That is the guest → main leg.
 *
 * ## What is reused verbatim, and what is added
 *
 * The script body is `GUEST_PRELOAD_SOURCE`, unchanged — the same ES5 string the
 * desktop writes to disk, so the picker, the login filler and the block-page
 * reader behave identically on the server. What is added is a small ES5 *shim*,
 * prepended into the same script, that defines `require('electron').ipcRenderer`
 * in terms of the binding:
 *
 *  - `ipcRenderer.send(channel, ...args)` → `__deckGuest(JSON.stringify({ ch,
 *    args }))`, which surfaces at the host as a `Runtime.bindingCalled` the host
 *    routes to the same handlers `wireGuestEvents` wires on the desktop.
 *  - `ipcRenderer.on(channel, cb)` → a dispatch table on the world's global.
 *    Main → guest channels (`GUEST_INSPECT`, `GUEST_LOGIN_FILL`) are delivered by
 *    the host with a `Runtime.evaluate` of {@link cdpGuestDispatchExpression} in
 *    this same world, which looks the channel up in the table and calls it.
 *
 * The shim and the body are one script on purpose: a single
 * `addScriptToEvaluateOnNewDocument` means the shim's top-level `require` is in
 * scope for the body's `require('electron')` through the ordinary closure the
 * two share, with no dependence on whether an isolated world's global is the
 * same object the page sees.
 */

/**
 * The binding name the guest calls to reach the host. Host-fixed — the page
 * never chooses it, which is the same construction guarantee `Runtime.evaluate`
 * has: the only strings that cross are ones this repository wrote.
 */
export const CDP_GUEST_BINDING = '__deckGuest'

/**
 * The isolated world the guest preload runs in.
 *
 * A name rather than a number because CDP identifies isolated worlds by
 * `worldName`, and it is the app's own so it cannot be confused with the page's
 * main world (which has no name) or a preload world Chromium creates itself.
 */
export const CDP_GUEST_WORLD = 'terminaldeck-guest'

/**
 * The global the shim hangs its main → guest dispatch table on, so the host's
 * {@link cdpGuestDispatchExpression} can find it.
 */
const DISPATCH_GLOBAL = '__deckGuestDispatch'

/**
 * The ES5 shim that stands in for Electron's `ipcRenderer`.
 *
 * No template literals and no arrow functions: it is prepended to the ES5 guest
 * body and shares its constraints, and it is delivered as a string to a browser
 * whose age is pinned but whose exact parser is not this process's to assume.
 * `JSON.stringify` is the one non-trivial dependency and every target in the
 * pinned Chromium family has it.
 */
function guestShim(): string {
  return `;(function () {
  var listeners = {}
  var ipc = {
    send: function (channel) {
      var args = []
      for (var i = 1; i < arguments.length; i++) args.push(arguments[i])
      // The one route out. The binding hands the host a single string; the host
      // parses { ch, args } and routes ch to the same handler wireGuestEvents
      // wires on the desktop. A failed stringify is dropped rather than thrown:
      // this runs inside the guest page and an exception here is the page's.
      try {
        ${CDP_GUEST_BINDING}(JSON.stringify({ ch: channel, args: args }))
      } catch (err) {}
    },
    on: function (channel, cb) {
      if (typeof cb !== 'function') return
      if (!listeners[channel]) listeners[channel] = []
      listeners[channel].push(cb)
    }
  }

  // Main -> guest. The host calls this by name with Runtime.evaluate in this
  // world; the first argument each callback gets is a stand-in for the Electron
  // event object the desktop passes, which the guest handlers ignore.
  Object.defineProperty(this, ${JSON.stringify(DISPATCH_GLOBAL)}, {
    value: function (channel, args) {
      var cbs = listeners[channel]
      if (!cbs) return
      var call = [{}]
      for (var i = 0; i < (args ? args.length : 0); i++) call.push(args[i])
      for (var j = 0; j < cbs.length; j++) {
        try {
          cbs[j].apply(null, call)
        } catch (err) {}
      }
    },
    configurable: true
  })

  // The one line the body depends on: require('electron').ipcRenderer. Nothing
  // else is provided, and a require for anything else throws exactly as it
  // would in a page that has no module loader.
  function require(mod) {
    if (mod === 'electron') return { ipcRenderer: ipc }
    throw new Error('module not available in the guest: ' + mod)
  }
  this.require = require
}).call(typeof globalThis !== 'undefined' ? globalThis : this)
`
}

/**
 * The full script installed on every new document: the shim, then the guest
 * body, as one script in one world.
 *
 * Exported so the delivery below and its test read the same string, and so a
 * reviewer can see that nothing rewrites the body — the desktop's guest script
 * and the server's are the same bytes with a preamble.
 */
export function cdpGuestPreloadSource(): string {
  return `${guestShim()}\n${GUEST_PRELOAD_SOURCE}`
}

/**
 * The expression the host evaluates in the guest world to deliver one main →
 * guest message. Arguments are JSON, the same discipline `withArgs` uses for the
 * drive scripts: there is no path from a value to executable text.
 */
export function cdpGuestDispatchExpression(channel: string, args: readonly unknown[]): string {
  return `${DISPATCH_GLOBAL}(${JSON.stringify(channel)},${JSON.stringify(args)})`
}

/** One guest → main message, parsed out of a `Runtime.bindingCalled` payload. */
export interface GuestMessage {
  ch: string
  args: unknown[]
}

/**
 * Read a `Runtime.bindingCalled` payload into a channel and its arguments, or
 * null when it is not one of ours.
 *
 * The payload is a string the *page's* isolated world produced, so it is checked
 * rather than trusted: it must be our binding, valid JSON, an object with a
 * string channel. Anything else is dropped — the same posture
 * `browser-cdp-pipe.ts` takes to a malformed frame.
 */
export function parseGuestBinding(name: unknown, payload: unknown): GuestMessage | null {
  if (name !== CDP_GUEST_BINDING || typeof payload !== 'string') return null
  let parsed: unknown
  try {
    parsed = JSON.parse(payload)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const record = parsed as Record<string, unknown>
  if (typeof record.ch !== 'string') return null
  const args = Array.isArray(record.args) ? record.args : []
  return { ch: record.ch, args }
}

/** The little of a CDP session {@link installCdpGuestPreload} needs. */
export interface GuestPreloadSession {
  send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>
}

/** What a delivered preload leaves behind: the world it runs in and the script's id. */
export interface InstalledGuestPreload {
  worldName: string
  /** The `identifier` from `Page.addScriptToEvaluateOnNewDocument`, to remove it later. */
  scriptId: string
}

/**
 * Install the guest preload on a target: register the binding, then add the
 * on-new-document script.
 *
 * The order is load-bearing. The binding is added first so that `__deckGuest`
 * already exists in the world by the time the script runs on the next document —
 * a script that ran before its binding was installed would throw on its first
 * `ipcRenderer.send`. `Page.enable` is the caller's to have sent (the driver
 * sends it on attach); this only adds the two things the preload itself needs.
 */
export async function installCdpGuestPreload(
  session: GuestPreloadSession,
  worldName: string = CDP_GUEST_WORLD,
): Promise<InstalledGuestPreload> {
  await session.send('Runtime.addBinding', {
    name: CDP_GUEST_BINDING,
    executionContextName: worldName,
  })
  const added = await session.send('Page.addScriptToEvaluateOnNewDocument', {
    source: cdpGuestPreloadSource(),
    worldName,
    runImmediately: true,
  })
  const scriptId = typeof added.identifier === 'string' ? added.identifier : ''
  return { worldName, scriptId }
}
