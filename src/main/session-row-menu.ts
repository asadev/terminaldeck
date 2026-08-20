/**
 * The ⋯ menu on a row in the sidebar.
 *
 * ## Why the row's buttons became a menu
 *
 * The row carried up to three hover buttons — promote, "why does this exist",
 * and the ✕ — on a rail 264px wide, and Asad watched a long session name run
 * straight under them: *"even the cross button is getting hidden because of
 * this button."* Three controls competing with the one thing the row exists to
 * carry is a layout that can only be lost, so he asked for the trade directly:
 * *"instead of these two buttons, give … one three-dot button. So from
 * three-dot button we can also have a drop-down to connect the session or
 * something."*
 *
 * One 22px button is the whole cost now, whatever the row can do, and every verb
 * arrives with a sentence rather than a glyph a person has to recognise — which
 * matters most for the ✕, the one control in this window that destroys something.
 *
 * ## Why it is a native menu
 *
 * The same reason `link-open.ts` and `browser-binding-ipc.ts` give, and here it
 * is not theoretical: this menu's headline entry is **Connect browser**, so the
 * situation it is most often opened in is one with a browser page on screen. A
 * `WebContentsView` composites above the entire renderer — the subject of
 * `overlay-watch.ts` — so an HTML menu would be drawn behind the very page the
 * person is trying to attach.
 *
 * ## Why the labels arrive from the renderer
 *
 * Because they are already written there, in the row's own tooltips, in the
 * words this app's decisions were recorded in: what closing a session on a
 * paired machine costs, what the ✕ leaves alone, why the strip is refusing a
 * fourth tab. Main has ids and no idea what any of them are called. Re-deriving
 * the sentences here would be a second copy of every one of them, and the copy
 * is the one that keeps the old wording after a decision changes.
 */

import { Menu, type IpcMain, type MenuItemConstructorOptions } from 'electron'
import { bindMenuItems, type BindingIpcDeps } from './browser-binding-ipc'

/** What the person chose, or null when they dismissed the menu. */
export type SessionRowChoice = 'promote' | 'close' | 'copilot'

export interface SessionRowMenuRequest {
  /** The session, or the browser tab id for a page row. */
  sessionId: string
  /** Empty for anything running on this computer. */
  machineId?: string
  /** What the row is called. Every sentence below is about this name. */
  name: string
  /** Whether this row's window is already up in the top strip. */
  promoted: boolean
  /**
   * Why it cannot be promoted, or null when it can.
   *
   * A sentence rather than a boolean, because the only reason that exists — the
   * strip is full — is a fact the person needs in order to know what to do about
   * it, and a greyed row with no explanation is the thing this menu is replacing.
   */
  promoteBlocked?: string | null
  /**
   * Whether this row can be deleted at all.
   *
   * It used to be the *sentence* the row's ✕ carried in its tooltip, and that
   * sentence was the defect. `Close Session 1 — ends the session` says the same
   * thing twice in one label, which is exactly what Asad read off the screen:
   * *"Close session one and end session, both are the same thing, two times. So
   * only give the delete button here. It should call only delete."*
   *
   * So the caller decides **whether**, because only the row knows that, and the
   * word is settled here — one word, in one place, matching the word the
   * confirmation uses.
   *
   * A boolean, and it used to be `string | null` "so the renderer did not have
   * to change with this". The renderer duly did not change, and went on
   * composing three sentences per row for a field nothing reads — which is
   * exactly the dead prose this round is removing. The type is the boolean it
   * has always been read as, so the next reader cannot mistake it for a label.
   */
  close?: boolean
  /** Whether the copilot started this session and its turn can still be opened. */
  copilotTurn?: boolean
  /**
   * A browser page rather than a session.
   *
   * It gets the placement and the close, and no **Connect browser**: a page
   * cannot have pages attached to it, and offering the entry anyway would be
   * the dead control this pass exists to remove.
   */
  browser?: boolean
}

/**
 * Pop the menu and answer with what was chosen.
 *
 * The three verbs come back to the renderer rather than acting here, because
 * all three are its own state: the promoted order lives in `useSidebar`, the
 * close runs through the confirmation `App.tsx` owns, and the copilot's turn is
 * a panel this process has never heard of. **Connect browser** is the exception
 * and acts in place — the binding map is main's, so its items are already the
 * real thing rather than a request for one.
 */
export function showSessionRowMenu(
  deps: BindingIpcDeps,
  request: SessionRowMenuRequest,
): Promise<SessionRowChoice | null> {
  const window = deps.window()
  if (!window || window.isDestroyed()) return Promise.resolve(null)

  return new Promise<SessionRowChoice | null>((settle) => {
    let done = false
    const finish = (choice: SessionRowChoice | null): void => {
      if (done) return
      done = true
      settle(choice)
    }

    const items: MenuItemConstructorOptions[] = [
      {
        label: request.promoted ? 'Fold back into the sidebar' : 'Show at the top',
        enabled: request.promoted || !request.promoteBlocked,
        // The strip's own limit, said where the press would have failed. See
        // `MAX_PROMOTED` in the renderer, which is where the number lives.
        sublabel: request.promoted ? undefined : request.promoteBlocked || undefined,
        click: () => finish('promote'),
      },
    ]

    if (request.copilotTurn) {
      items.push({
        label: 'Started by the copilot — open that turn',
        click: () => finish('copilot'),
      })
    }

    if (!request.browser) {
      items.push({ type: 'separator' })
      items.push({
        label: 'Connect browser',
        /*
         * The list he could not find, where he said to put it.
         *
         * Built by `bindMenuItems` rather than here, so the rail's submenu and
         * the pane bar's button are the same menu — same slot names, same
         * colours, same "No browser windows are open." when there is nothing to
         * list, and the same offer of a new window underneath it.
         */
        submenu: bindMenuItems(deps, {
          sessionId: request.sessionId,
          machineId: request.machineId ?? '',
        }),
      })
    }

    if (request.close) {
      items.push({ type: 'separator' })
      items.push({
        /*
         * One word, and the same word the confirmation uses.
         *
         * The old label spelled out the consequence — `Close Session 1 — ends
         * the session` — on the argument that there are two ✕s in this window
         * and only one of them destroys anything. That argument was answered
         * from a better direction: the *other* ✕ is going away from sessions
         * altogether, and a menu entry reading `Delete` followed by a
         * confirmation that also says delete cannot be mistaken for taking a
         * pill off a bar.
         *
         * The red is not here and cannot be: a native macOS menu item has no
         * colour of its own. It is on the confirmation's button, which is the
         * control he was actually describing — *"instead of this blue"* is the
         * dialog's accent — and that one is HTML.
         */
        label: 'Delete',
        click: () => finish('close'),
      })
    }

    Menu.buildFromTemplate(items).popup({
      window,
      /*
       * Dismissal is an answer too, and it is the common one.
       *
       * `setImmediate` rather than resolving straight away because Electron does
       * not promise that a chosen item's `click` runs before the menu reports
       * itself closed. Resolving `null` here without the hop would race the
       * choice and, on the losing side of that race, silently drop a close the
       * person had already confirmed.
       */
      callback: () => setImmediate(() => finish(null)),
    })
  })
}

/* ------------------------------------------------------------------- ipc -- */

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/**
 * Register the one channel this menu needs. Call once from `registerIpc()`.
 *
 * The narrowing is here rather than in `index.ts` because the shape is this
 * file's: everything crossing the bridge is `unknown`, and a request missing its
 * session id answers `null` — a menu that was never popped and a menu that was
 * dismissed are the same answer to the caller, which is what stops the renderer
 * needing a second code path for a case it cannot cause.
 */
export function registerSessionRowMenuIpc(ipcMain: IpcMain, deps: BindingIpcDeps): void {
  ipcMain.removeHandler('session:row-menu')
  ipcMain.handle('session:row-menu', (_event, raw: unknown) => {
    const input = (raw ?? {}) as Record<string, unknown>
    const sessionId = str(input.sessionId)
    if (!sessionId) return null
    return showSessionRowMenu(deps, {
      sessionId,
      machineId: str(input.machineId),
      name: str(input.name),
      promoted: input.promoted === true,
      promoteBlocked: str(input.promoteBlocked) || null,
      close: input.close === true,
      copilotTurn: input.copilotTurn === true,
      browser: input.browser === true,
    })
  })
}
