# Third-party notices

Terminal Deck for Mac and Windows bundles the following third-party code. Each
item names where its licence text lives in this repository or where it is read
from at build time.

## Mac app

- **SwiftTerm 1.20.0** (MIT) — the native terminal view.
  <https://github.com/migueldeicaza/SwiftTerm>. Pinned in
  `macos/TerminalDeckNative/Package.resolved`; its `LICENSE` is copied into the
  app bundle by `macos/build-app.sh`.
- **swift-argument-parser 1.8.2** (Apache-2.0) — pulled in by SwiftTerm.
  <https://github.com/apple/swift-argument-parser>
- **gte-small** (MIT) — the text-embedding model behind search by meaning,
  converted to Core ML. Notice and licence text:
  `macos/models/deck-memory-embedding/NOTICE.md`.
- **Stays Fixed 0.15.0** (MIT) — `vendor/staysfixed-0.15.0-neutral.tgz`;
  provenance in `vendor/STAYSFIXED.md`.
- **Coolify templates and Railpack** (MIT / Apache-2.0) — server-control
  templates; record in `macos/licenses/server-control/THIRD-PARTY.md` and
  `macos/licenses/server-control/Coolify-LICENSE.txt`.
- **npm packages** bundled into the app's web pages (React, xterm.js, the Model
  Context Protocol SDK and others) — every package and its licence is listed in
  `THIRD-PARTY-LICENSES.md`.

## Windows app

- **Microsoft.WindowsAppSDK 1.8**, **Microsoft.Web.WebView2 1.0.3719** —
  Microsoft Software License Terms, restored from NuGet at build time.
- **BouncyCastle.Cryptography 2.6.2** (MIT) — <https://www.bouncycastle.org/csharp/>
- **xterm.js 5.5.0** and its fit, search, web-links and WebGL addons (MIT) —
  bundled as `windows/src/TerminalDeck.App/Assets/terminal/terminal.js` from
  `windows/tools/terminal-assets`.
- **Cascadia Mono** and **Inter** (SIL Open Font License 1.1) —
  `windows/src/TerminalDeck.App/Assets/Fonts`.
- **xunit 2.9.3**, **xunit.runner.visualstudio 3.1.5**, **Microsoft.NET.Test.Sdk
  17.14.1** (Apache-2.0 / MIT) — tests only.

Terminal Deck itself is MIT-licensed; see `LICENSE`.
