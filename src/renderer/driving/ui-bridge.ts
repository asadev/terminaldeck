/**
 * The things a person does in this window by clicking — published so the main
 * process can do them too, for an AI that is not sitting in front of it.
 *
 * ## Why this exists
 *
 * Every action that reaches the main process already has a tool, or a reason it
 * does not (`main/deck-control/actions/`). What that table cannot see is the
 * half of the app that never crosses the bridge at all: opening a view,
 * bringing a session to the front, opening a Settings section, splitting the
 * window. Those are renderer state — `App.tsx` holds them — so an AI driving
 * this app from another computer could start sessions and read their answers and
 * still never put the right one on the screen for the person who walks up to it.
 *
 * ## The shape, and why it is this one
 *
 * The same shape `where.ts` already uses for `app.where`: a function left on the
 * window for the main process to call with `executeJavaScript`, in the page's
 * main world, at the moment it is wanted. No new IPC channel — the preload is a
 * file a parallel lane may not touch, and a pull at the instant of asking cannot
 * be stale the way a pushed copy can.
 *
 * It does not invent a second way to do anything. A command runs through
 * `App.tsx`'s own `run(id)` — the one dispatcher the palette, the menu bar and
 * every chord already share — so a command an AI runs is exactly the command a
 * person's ⌘-key runs, including the redirect to the store when its feature is
 * not installed. Focusing a session calls the same function a click on its
 * sidebar row calls.
 *
 * ## What it refuses, and where that is decided
 *
 * Nothing here decides what an AI may do. The main side (`ui-tools.ts`) refuses
 * the commands that would open a dialog nobody can answer, and tiers the ones
 * that change configuration; this side only refuses what is not there — an id
 * this window has no command, session or section for — so the answer is always
 * about the window as it is drawn right now.
 */

/** Where the bridge is left. `ui-tools.ts` names the same global. */
export const UI_GLOBAL = '__terminaldeckUi'

/** One command as the palette lists it. */
export interface UiCommand {
  id: string
  title: string
  group?: string
  /** False when the feature that owns it is not installed; running it opens the store. */
  enabled?: boolean
}

/** What `App.tsx` hands over. Every member is a function so the answer is read when asked. */
export interface UiHandlers {
  /** The palette's rows right now. `commands` in `App.tsx`. */
  commands(): readonly UiCommand[]
  /** `run(id)` in `App.tsx` — true when something answered to that id. */
  run(id: string): boolean
  /** The sessions this window has a row for. */
  sessions(): ReadonlyArray<{ id: string; title: string }>
  /** What a click on a session's sidebar row does. */
  focusSession(id: string): void
  /** Settings sections, by id. `SECTION_IDS`. */
  sections(): readonly string[]
  openSettings(section: string): void
  /** Put a project on the rail, as opening one does. */
  addProject(path: string): void
}

export interface UiListing {
  commands: UiCommand[]
  sessions: Array<{ id: string; title: string }>
  sections: string[]
}

export type UiAnswer = { ok: true; did: string } | { ok: false; why: string }

/**
 * The two calls the main process makes, over whatever `App.tsx` handed over.
 *
 * Takes a getter rather than the handlers, so `App.tsx` can keep one ref current
 * on every render and publish once: the commands list is rebuilt whenever a
 * feature is installed or the copilot is renamed, and a bridge holding the
 * first render's list would offer a command that has since gone.
 */
export function uiBridge(current: () => UiHandlers | null): {
  list(): UiListing | null
  do(request: unknown): UiAnswer
} {
  return {
    list() {
      const handlers = current()
      if (handlers === null) return null
      return {
        /*
         * Field by field, never a spread. The palette's rows carry their own
         * `run` function, and `executeJavaScript` hands its answer back by
         * structured clone — one function anywhere in it and the whole answer
         * is refused as uncloneable, which arrives as "there is no window".
         */
        commands: handlers.commands().map((command) => ({
          id: command.id,
          title: command.title,
          ...(command.group === undefined ? {} : { group: command.group }),
          ...(command.enabled === undefined ? {} : { enabled: command.enabled }),
        })),
        sessions: handlers.sessions().map((session) => ({ id: session.id, title: session.title })),
        sections: [...handlers.sections()],
      }
    },

    do(request) {
      const handlers = current()
      if (handlers === null) return { ok: false, why: 'The window has not finished starting.' }
      if (typeof request !== 'object' || request === null) return { ok: false, why: 'No request.' }
      const { kind, target } = request as { kind?: unknown; target?: unknown }
      if (typeof target !== 'string' || target === '') return { ok: false, why: 'No target.' }
      switch (kind) {
        case 'run': {
          // Ran or not — `run` answers false for an id nothing in this window
          // handles, which is the honest "there is no such command" rather than
          // a silent success.
          return handlers.run(target)
            ? { ok: true, did: `ran ${target}` }
            : { ok: false, why: `This window has no command called ${target}.` }
        }
        case 'focus': {
          const session = handlers.sessions().find((one) => one.id === target)
          if (session === undefined) return { ok: false, why: `This window has no session ${target}.` }
          handlers.focusSession(target)
          return { ok: true, did: `brought ${session.title} to the front` }
        }
        case 'settings': {
          if (!handlers.sections().includes(target)) {
            return { ok: false, why: `Settings has no section called ${target}.` }
          }
          handlers.openSettings(target)
          return { ok: true, did: `opened Settings at ${target}` }
        }
        case 'project': {
          handlers.addProject(target)
          return { ok: true, did: `put ${target} on the sidebar` }
        }
        default:
          return { ok: false, why: 'Unknown kind of request.' }
      }
    },
  }
}

/**
 * Leave the bridge on the window, and take it away again.
 *
 * Returns the cleanup, so `useEffect(() => publishUi(get), [])` is the whole of
 * the wiring.
 */
export function publishUi(current: () => UiHandlers | null): () => void {
  const host = globalThis as Record<string, unknown>
  host[UI_GLOBAL] = uiBridge(current)
  return () => {
    delete host[UI_GLOBAL]
  }
}
