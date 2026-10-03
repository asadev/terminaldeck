# Wiring — lane 0164 (Hoot in the macOS menu bar)

The first cut of this lane was a pill at the top centre of the screen. The owner
asked for the menu bar instead ("i need it in menu bar not here"); every file of
the pill was deleted and nothing of it remains.

Like the pop-out lane, the feature needs the shared files, so the wiring is
**applied on this branch**. Every edit is small and listed here.

## `src/main/index.ts`

1. Imports: `ensureCopilot` (added to the `copilot-session` import),
   `wireHootMenuBar` / `HootMenuBar` from `./hoot-menubar`, `uiDoCall` from
   `./deck-control/ui-tools`.
2. `let hootMenuBar: HootMenuBar | null = null` beside `popouts`.
3. `send()`: `if (!quitting) hootMenuBar?.forward(channel, args)` after the
   popouts line.
4. `hydrateRenderer`: `hootMenuBar?.apply()` after `popouts?.restore(...)`.
5. `whenReady`: `hootMenuBar = wireMenuBar()` after `buildMenu(...)`.
6. `wireMenuBar()` above `syncNativeAppearance`: the real dependencies (desk
   Hoot's state and start, `typeAndSubmit`, `watchRunChat`, `ui.do` focus and
   settings).

## `src/preload/index.ts`

`reportSessionLabels` and the `hootPanel*` / `hootMenuBar*` methods after
`onSessionWindows`.

## `src/renderer/App.tsx`

An effect that reports every session's name (`session:labels`), and two palette
rows: `hoot.ask` (open the panel from the keyboard) and `view.menubar` (show or
hide the owl).

## `src/renderer/main.tsx`

`?hootpanel=1` renders `HootPanel` and nothing else.

## Moved, not changed

`decide()` and the notifying statuses moved from `renderer/notifications.ts` to
`shared/notify-rule.ts` so the main process runs the same rule for the menu
bar's moments. `notifications.ts` re-exports them; no importer changed.

## Headless host

Nothing. A server has no menu bar.

## Known overlap, not changed

`resident.ts` still shows its own tray icon when the app goes to the background.
With Hoot in the menu bar that is two icons for one app while in the
background. Folding the background menu into Hoot's right-click menu is the
obvious next step; not done here.
