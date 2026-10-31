# Windows adapters — W3 handoff

29 October 2026. Tested on a Windows 11 x64 PC, .NET 10.0.403. Latest tested source `e07ed65`. No production install, account sign-in, Mac app or Mac data was used.

The PC checks passed: **20 distinct tests, zero unresolved failures, zero skips**. Four new Core tests also passed on the Mac. This is focused evidence, not a full-suite claim. See `docs/WIN-PROGRESS.md` for every TRX and the historical failed attempts.

## Lifetime and connection

`TerminalDeck.Keeper.exe --user-data-dir C:\TD\<scratch>` runs the supervisor. Its private worker mode also requires `--worker <creation-key>`; it obtains bootstrap authentication from root-scoped Credential Manager, never command arguments. Worker launch plans are DPAPI-protected and replaced atomically. A per-worker exclusive file lock prevents duplicate terminals after interrupted creation.

Each worker owns ConPTY, its job, output decoding, bounded replay and its authenticated current-user-only pipe. Killing an app or the supervisor does not close those handles. Reattachment takes a worker snapshot and then ordered events. Core emits `reset` when replacing replay; use `SessionReplay`, not unconditional append. A job completion port reports tree exit; idle observations count every live descendant. An ended worker retains replay until explicitly stopped; restart imports its final frame before clients are served. A worker crash or Windows reboot cannot preserve a live pseudoconsole.

`KeeperConnection.AttachAsync(root, keeperExe)` starts or reuses the supervisor and returns a v2 `KeeperClient`. `AttachAsync`/disposing a view never stops a session. Stop is explicit. The launch path first requests job breakaway. When a restrictive launcher job refuses it, the current user's desktop becomes the explicit lifetime parent, after SID/session checks. It neither injects code nor changes Explorer. Mixed-elevation launches were not tested; use the ordinary signed-in desktop for the proof.

`KeeperSessionTools.Register(existingPermissionDoor, client)` supplies seven real session tools: list/get/screen/rename/send/keys/stop. It creates no caller or automatic approval. Session creation remains Core's full `DeckCoreTools.RegisterSessions` contract with account/brief/resume validation; the UI composition must provide that planner. Unsupported actions remain unadvertised.

## Browser

`Browser/TerminalDeck.Windows.Browser.csproj` owns the optional HWND-based .NET WebView2 host. Keeper has no WebView2 dependency. Supply an `INativeBrowserHost`, a complete `INativeBrowserActions`, a navigation predicate and a metadata callback on the UI thread. Present/background/reparent operations retain controllers and never navigate. BrowserModel/Core BrowserTools remain the common backend and MCP handlers. Unexpected permissions, popups and downloads are refused.

Do not mix this assembly's .NET WebView2 binding with WinUI's WebView2 projection DLLs in one output. The UI lane has its own WinUI host and can retain it. The scratch `Proof/TerminalDeck.AdapterProof.csproj` uses the optional HWND adapter to prove BrowserModel's lifetime rules; it is not a replacement for the product UI or its terminal renderer. `Proof/run.ps1` kills only its own app/supervisor and explicitly closes its scratch session. The PC proof passed once and both PNGs were inspected.

## CLI installation and homes

Installed locally to `C:\TD\tools\ai` with npm; cache and npm configuration were kept under `C:\TD\tools`. Nothing was added to the user's global PATH. The installed package lock remains at `C:\TD\tools\ai\package-lock.json`. All three versions were captured through ConPTY; no interactive login or authenticated model call was attempted.

Let `H = <data-root>\accounts\<opaque HomeId>\<provider>`. Core can merge an account row while changing its HomeId, so the planner uses that HomeId rather than assuming the account row's Id. It rejects external path strings and removes inherited provider-specific environment variables before setting the selected home.

| CLI/version | Direct launch under the tools folder | Default Windows configuration | App child environment |
|---|---|---|---|
| Claude Code 2.1.312 | `node_modules\@anthropic-ai\claude-code-win32-x64\claude.exe` (or the package's installed `bin\claude.exe`) | `%USERPROFILE%\.claude\settings.json`; global metadata also uses `.claude.json` | `CLAUDE_CONFIG_DIR=H`; home files move under this explicit directory |
| Codex 0.165.0 | `node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe` | `%USERPROFILE%\.codex\config.toml`; authentication is `auth.json` or the selected OS credential backend | `CODEX_HOME=H`; verify the chosen credential-store mode before account sign-in |
| Gemini 0.66.0 | `C:\Program Files\nodejs\node.exe` with `node_modules\@google\gemini-cli\bundle\gemini.js` as an argv entry | `%USERPROFILE%\.gemini\settings.json` | `GEMINI_CLI_HOME=H`; Gemini creates `H\.gemini`, not settings directly in H |

The resolver uses actual native executables or Node plus a script argument. It does not interpolate provider arguments into `.cmd` wrappers. `cmd.exe` is limited to known unquoted `/d /q` switches and receives commands through terminal input. Explicit null standard handles prevent a redirected launcher's stdout bypassing ConPTY. Close drains the final display frame.

These are tested home mappings and documented vendor configuration rules. Two authenticated accounts were not tested and no vendor auth files were read. Dynamic account/model/conversation drivers remain later work.

Official API/configuration facts consulted (implementations written here): [ConPTY lifecycle](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session), [job events](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects), [process-parent attribute](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute), [Microsoft's redirected-standard-handle explanation](https://github.com/microsoft/terminal/discussions/15814), [WebView2 controller creation](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2environment.createcorewebview2controllerasync), [Claude settings](https://code.claude.com/docs/en/settings), [Codex home variables](https://learn.chatgpt.com/docs/config-file/environment-variables), [Codex authentication storage](https://learn.chatgpt.com/docs/auth), [Gemini home configuration](https://geminicli.com/docs/reference/configuration/).
