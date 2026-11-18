# Windows browser Part B — 18 November 2026

Branch: `fix/windows-ui-browser-20261118`, based on public `b9770bf` (accounts PR 41 retained). This is a source handoff. No build, test run, PC login, install, push, merge or release was performed in this lane. `git diff --check` is clean. The parent owns the one Windows compile, focused checks and real Windows screenshots.

## Requested scope

13 requested points are written; runtime verification remains pending for all 13.

| Point | Written behavior | Evidence state |
|---|---|---|
| 1 | Tabs divide the whole available header, selected minimum 120, others minimum 36, maximum 220; then scroll | Source; new sizing tests not run |
| 2 | Terminal-new icon removed from the header | Source |
| 3 | One small plus pinned at the right; terminal-new stays in its context menu | Source |
| 4 | Profile avatar/card, other profiles, create, actual per-profile passwords/history | Source |
| 5 | Bookmark star, filled saved state, bar, overflow, More list, remove/copy/new-tab, per-profile persistence | Source; new bookmark tests not run |
| 6 | Navigation/address/three page tools/Connect/Downloads/Profile/More; active tool pills | Source |
| 7 | One Connect capsule with its own disconnect x; connected session name and B-slot | Source |
| 8 | Shared solid DeckMenu cards and menus | Requires shell A's shared menu file and public CompactRows |
| 35 | Same WebView parked in an offscreen, non-activating, switcher-hidden window for hidden/minimised read/click/type/capture; popups retain opener protocol; questions/permissions/files/auth queue per tab for Review, with explicit unsupported cases | Native proof written, not run |
| 37 | Capsule tabs, quiet rest fill, selected rim, fading title | Source |
| 38 | Annotate/Screenshot/Record beside address; other actions in More; compact panes move tools into More | Source |
| 42 | Repeated new-tab action stays reachable; old 12-tab cap raised to a bounded 64 | Source |
| Finding 30 | Local listener ownership/name, dev-runtime ranking, service exclusion, own-app ports collapsed | Source; new local-port test not run |

## Integration: required before claiming complete

1. Integrate shell A's `DeckMenu.cs`. Browser uses `CreateFor(FrameworkElement)`, `Apply(Flyout, ElementTheme)`, `Pill(Button)`, and **public** `CompactRows(IEnumerable<MenuFlyoutItemBase>)`. A told the parent that CompactRows needs its visibility changed after A's frozen commit.
2. Wire `browser.OpenStore = () => Model.Page = ShellPage.Store` with the existing browser callbacks.
3. Wire `browser.ToggleSplitView` and `browser.SplitViewIsOn` to the existing workspace state. The argument is the Core browser tab id, which is also the workspace tab id. Toggle one pane / empty pane beside, calling `LeaveSwarm()` as existing manual split does. Read the actual tab's owner and host (detached windows included), not a global main-window owner. The existing `ui.workspace` tools already own these actions and approvals.
4. Keep the shell A folder-label delegate. WorkspaceSurface now displays its full value, with a folder icon when it has no project identity.
5. Compile/test on the PC once, inspect the generated full frames, 380px panes and menu crops, then judge runtime behavior. This lane has made no runtime claim.

A suitable split wiring is:

```csharp
browser.ToggleSplitView = id =>
{
  var tab = windowState.Get(id);
  LeaveSwarm();
  if (windowState.Layout(tab.Owner, tab.Host).Root?.Tab is null)
    windowState.One(id, tab.Owner, tab.Host);
  else windowState.EmptySplit(id, owner: tab.Owner, host: tab.Host);
};
browser.SplitViewIsOn = id =>
{
  var tab = windowState.Get(id);
  return windowState.Layout(tab.Owner, tab.Host).Root?.Tab is null;
};
```

## Focused checks for the parent

- `windows/tests/TerminalDeck.Core.Tests/TerminalDeck.Core.Tests.csproj`: `BrowserBookmarksTests`, `BrowserLocalPortsTests`, `BrowserTests`, `BrowserWorkspaceTests`, `W13IntegrationTests` (namespace `TerminalDeck.Core.Tests.Browser`). Includes a real gate-reentrancy regression: a page action may synchronously create its popup without deadlocking. Includes shared private-popup lifetime and no premature store deletion.
- `windows/src/TerminalDeck.App/Views/Windows/Tests/TerminalDeck.Shell.Tests.csproj`: `WorkspaceTabSizingTests`. Keep its artifacts outside the WinUI source tree, as its README requires.
- App proof: set `TD_BROWSER_PARITY_PROOF=1` and create `.browser-parity-proof` **inside the explicit scratch user-data directory** before launching the scratch app. Do not set the old `TD_W12_BROWSER_PROOF` simultaneously. The probe closes its own app afterwards. Outputs are `<scratch>/proof/browser-parity/result.json`, stage.txt, hidden/minimised PNGs, full light/dark frames, profile/More/Connect menu crops, and 380px light/dark panes. Inspect both `errors` and every `checks[].passed`; the file existing alone is not a pass.
- The native probe covers actual hidden read/click/type, document identity retention, pixel variance in hidden and minimised captures, minimised window staying minimised, window.opener protocol, unsupported-popup refusal, retained hidden confirm, bounded waiting result, explicit cancellation of the original confirm via the workspace owner, same-WebView restoration, bookmarks, and narrow toolbar bounds.
- Parent must run the existing Umer ancestry/line-preservation checks after integration. This lane has not run them or changed external data.

## MCP ownership

Bookmarks use the existing `browser.workspace.read/change` tools and their existing resource grants. Read `command: bookmarks` returns granted-profile/granted-origin rows plus `alwaysShow`. Alter commands: `bookmarkAdd` (`profile`, `url`, `title`), `bookmarkRemove` (`profile`, `id`), `bookmarksBar` (`profile`, `visible`). They keep `McpTier.Alter`; reads remain free. New read commands `pageRequests` and `localPorts`, and Alter commands `questionReview` / `questionCancel`, use the existing workspace browser/profile/window/session/origin checks. Existing `browser.windows` owns bind/unbind; `browser.profiles` owns profile creation/activation; `browser.privacy` owns the password actions; existing browser page/workspace and ui.workspace tools own the remaining UI actions. No additional approval door or privileged caller was added.

Bookmarks and bar preferences are persisted as additions to the existing `browser-core` state, with defaults for older files. Isolated tabs deliberately use their profile's bookmarks. A native popup keeps its opener's exact WebView environment and private store, and starts un-navigated; the shared private store is deleted only after its final page closes. The workspace gate is released before page interactions so a popup callback can acquire it.

## Missing Mac handover and equivalent evidence

`code/td-mac-browser-bg/RESULT.md` and its directory are absent. Equivalent merged implementation is present in `code/td-ship-0230` and the public source history at `cbfd180`:

- `macos/TerminalDeckNative/Sources/TerminalDeckNative/NativeBrowserBackgroundHost.swift`
- `NativeBrowserPageRequests.swift`, `NativeBrowserRequestBridge.swift`, `NativeBrowserPageRequestBar.swift`
- `macos/TerminalDeckNative/Tests/TerminalDeckNativeUITests/MacBrowserBackgroundTests.swift`
- `notes/review-20261118/after-merged/browser-background/` has four offscreen-rendered light/dark 380/900 pictures.
- `code/td-ship-0230/RESULT.md` section `## mac-browser-bg` (line 369 onward) retains the complete missing lane receipt, popup matrix and Windows handoff. It records 19/19 focused tests in 69.936 seconds on the earlier Mac lane. `notes/overnight-20261118/MAC-0230-RESULT.md` is the release-era consolidated result and also records the merged 19/19 pass. Mac evidence is not Windows runtime evidence.

All requested before frames (`browser-header*.jpg`, `connect-popover.jpg`, `sheets/f1_01..05.jpg`) and representative merged browser/header/card/menu pictures were viewed before editing.

## Limits to report accurately

Windows native behavior and appearance are pending the parent's run. Passkeys use Windows/WebView2's real credential request when a person is in the tab; hidden requests and runtime failures give a plain reason and external-browser next step. A person's actual Windows Hello/passkey success has not been tested. Client-certificate selection is explicitly refused with an external-browser next step. Hidden script questions, permissions, basic authentication and file choosers retain their original request in a per-tab queue with a quiet attention dot and Review/Cancel strip. Browser calls return a bounded waiting reason without repeating or auto-answering the action. Review opens the actual dialog/picker on the requesting tab; navigation/close cancels its pending requests. Unsupported passkey, protocol and certificate cases retain plain explanations. Real visible requests get their actual dialog/picker. No fake passkey or authentication result is produced.

The runtime refuses a uniform/empty capture rather than returning a blank PNG. Dedicated parking is offscreen, shown without activation and absent from Alt-Tab/taskbar; it still needs real-PC proof that this runtime keeps drawing after reparenting. The app's old generic HWND/standalone adapter is not the product UI host and was not changed.
