# Terminal Deck for Mac and Windows

Terminal Deck is a desktop workspace for AI coding agents. Run many Claude Code,
Codex CLI and Gemini CLI sessions side by side in one window, see which are
working and which are waiting on you, give your agents a browser, projects,
tasks and servers to work with, and keep the whole deck running from your
phone. Free, MIT-licensed, no account, no telemetry.

Website and downloads: <https://terminaldeck.dev>
Releases: <https://github.com/asadev/terminaldeck/releases>

Phone companion apps are available on the App Store and Google Play.

## What is in this repository

| Folder | What it is |
|---|---|
| `macos/TerminalDeckNative/` | The Mac app: a Swift package (SwiftUI, AppKit, WebKit) with the app, its helpers and its tests |
| `macos/` | The Mac build scripts, `Info.plist`, entitlements, bundled licences, the memory-search model and the built-in skills |
| `src/`, `pwa/` | The TypeScript the Mac app's web pages and the browser client are built from (React, Vite) |
| `scripts/`, `build/`, `vendor/` | Build helpers, app artwork and a vendored dependency |
| `windows/` | The Windows app: C# / .NET 10, WinUI 3, WebView2 (see `windows/README.md`) |

## Building the Mac app

You need macOS 26 or newer, Xcode 26 or newer (Swift 6.2 tools) and Node 22 or
newer.

```bash
npm ci
npm run build && npm run build:native-web && npm run build:pwa && npm run dist:headless
bash macos/build-standalone.sh
```

The first line installs the JavaScript dependencies. The second builds the web
pages the app serves. The third compiles the Swift package in release mode and
assembles `macos/build/Terminal Deck.app`, signed ad hoc with the hardened
runtime, so a local build behaves like the release. To compile the Swift package
on its own:

```bash
swift build --package-path macos/TerminalDeckNative
```

## Building the Windows app

You need Windows 11, the .NET SDK 10.0.400 or newer and the Windows App SDK
tooling (restored from NuGet). Then:

```powershell
cd windows
dotnet build TerminalDeck.slnx -c Release
```

The platform-independent core and its tests also build on macOS and Linux:

```bash
cd windows
dotnet build TerminalDeck.Core.slnf
dotnet test tests/TerminalDeck.Core.Tests/TerminalDeck.Core.Tests.csproj
```

## Licence

MIT, see [LICENSE](LICENSE). Third-party code bundled with the apps is listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Security

Please report vulnerabilities as described in [SECURITY.md](SECURITY.md).
