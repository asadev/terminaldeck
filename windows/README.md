# Terminal Deck for Windows

A native Windows app: C# on .NET 10, WinUI 3 for the shell, WebView2 for the
browser and the xterm.js terminal surface. It is the Windows counterpart of the
Mac app at the root of this repository and shares its features, layout and
wire protocol.

| Project | What it is |
|---|---|
| `src/TerminalDeck.Core` | Platform-independent logic: sessions, projects, agents, tasks, servers, the relay client and the sealed channel |
| `src/TerminalDeck.Platform.Windows` | Windows services: credentials, OpenSSH, process keeper, pipes |
| `src/TerminalDeck.Keeper` | The durable session keeper that outlives the window |
| `src/TerminalDeck.App` | The WinUI 3 application |
| `tests/TerminalDeck.Core.Tests` | xunit tests for the core |
| `tools/terminal-assets` | Builds the bundled xterm.js terminal (`src/TerminalDeck.App/Assets/terminal`) |
| `tools/team-import` | Imports a team definition into an app data folder |

## Build

Windows 11, the .NET SDK 10.0.400 or newer (`global.json`), the Windows App
SDK tooling restored from NuGet, and the WebView2 runtime at run time.

```powershell
dotnet build TerminalDeck.slnx -c Release
```

The core and its tests build and run on any OS:

```bash
dotnet build TerminalDeck.Core.slnf
dotnet test tests/TerminalDeck.Core.Tests/TerminalDeck.Core.Tests.csproj
```

Development launches take `--user-data-dir <absolute scratch path>` so a test
copy never shares data with an installed one.

Licence: MIT, see `../LICENSE`. Third-party code: `../THIRD-PARTY-NOTICES.md`.
