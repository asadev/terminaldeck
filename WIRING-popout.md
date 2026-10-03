# Wiring — lane 0163-popout (sessions in windows of their own)

The feature cannot run without touching four of the shared files, so the
wiring is **applied on this branch** rather than left as snippets. Every edit is
small and additive; this is the list, so a conflicting merge can be redone by
hand.

## `src/main/index.ts`

1. Imports: `sessionWindowTools` from `./deck-control/session-window-tools`,
   `wirePopouts`, `PopoutRegistry`, `PopoutView` from `./popout-windows`.
2. `let popouts: PopoutRegistry | null = null` beside `copilotRuntimeDeps`.
3. `send()`: `if (!quitting) popouts?.forward(channel, args)` right after
   `machineArea.tap.pushed(...)`, before the main-window checks.
4. Two helpers above `syncNativeAppearance`: `popoutSessions()` and
   `showMainWindow(command?)`.
5. `onSessionRemoved`: `popouts?.sessionEnded(id)` after the `replaced` return.
6. `hydrateRenderer`: `popouts?.restore(popoutSessions())` after the
   `SESSION_CREATED_CHANNEL` loop.
7. `goBackground`: `popouts?.suspend()` before closing every window.
8. `before-quit`: `popouts?.suspend()` right after `leaveBackground()` on the
   stopping path.
9. `registerIpc`: `popouts = wirePopouts({...})` after
   `registerSessionRowMenuIpc(...)`.
10. `extraTools`: `...sessionWindowTools({...})` first in the list.
11. `buildMenu(() => mainWindow, undefined, (command) => popouts?.routeMenu(command) ?? false)`.
12. `activate`: `if (mainWindow === null || mainWindow.isDestroyed()) createWindow()`
    (was "no windows at all" — a session window keeps the count above zero).

## `src/preload/index.ts`

Eight methods after `onSessionCreated` (`popOutSession`, `dockSession`,
`focusSessionWindow`, `sessionWindows`, `followSessionSwitch`,
`labelSessionWindows`, `showMainWindow`, `onSessionWindows`) and
`window?: 'main' | 'own'` on `showSessionRowMenu`'s request.

## `src/shared/types.ts`

`window?: 'main' | 'own'` on `DeckApi.showSessionRowMenu`'s request. The new
methods are typed in `renderer/popout/session-windows.ts`, not here.

## `src/renderer/App.tsx`

The `useSessionWindows` hook and the two targets after `focusedSession`; the
card in place of the terminal in the single view, the swarm cell and the split
pane; two palette rows and two `run()` aliases; `windowMoves` on the Sidebar and
the strip; the toolbar's "Move to new window" button; `SessionControls` withheld
over a session that is out.

## Headless host

Nothing. A headless host has no windows; `sessionWindowTools` is only added in
`index.ts`.
