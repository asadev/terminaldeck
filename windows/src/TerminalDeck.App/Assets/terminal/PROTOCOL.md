# Terminal page bridge

WebView2 sends JSON objects with `chrome.webview.postMessage` / `WebMessageReceived`. The page accepts objects or JSON strings from the host. Messages are ordered; the host should wait for `ready` before sending output. Text is UTF-8 and terminal output may contain ANSI escapes. The prompt is output from the session, not part of this page.

Host to page:

- `{ "type": "data", "data": "..." }` writes terminal output.
- `{ "type": "replay", "data": "..." }` resets the terminal and writes a full recorded replay (attach or keeper reset). When written, the page answers `repaint`.
- `{ "type": "resize" }` asks the page to fit its current container. The host sizes the WebView itself; the page reports the resulting cell dimensions.
- `{ "type": "theme", "theme": "light" | "dark" }` changes the ANSI palette. Optional `background` and `foreground` fields accept six-digit hex colours from the host theme tokens; these override the surface colours without changing ANSI data colours.
- `{ "type": "font", "family": "...", "size": 13 }` changes either or both settings; size is clamped to 9–24 pixels. Omit a field to leave it unchanged.
- `{ "type": "clear" }` clears the viewport and scrollback as supported by xterm's clear operation; it does not send a shell command.
- `{ "type": "find", "query": "...", "direction": "next" | "previous" }` searches; empty query clears search highlights.

Page to host:

- `{ "type": "ready" }` means the bridge listener is installed.
- `{ "type": "input", "data": "..." }` carries keyboard or pasted input to the session.
- `{ "type": "resize", "cols": 80, "rows": 24 }` reports fitted cell dimensions. A resize can arrive before or after `ready`.
- `{ "type": "repaint", "cols": 80, "rows": 24 }` follows a replay. The host briefly changes the session size and restores it so the console and program redraw the screen with absolute positions; a replay alone can leave the cursor a cell away from where typing lands.
- `{ "type": "title", "title": "..." }` reports a terminal title escape.
- `{ "type": "bell" }` reports a terminal bell.
- `{ "type": "link", "uri": "https://..." }` requests opening a detected link. The host decides whether and where to open it; the page never navigates to it.

The page fits rows/cols to `#screen`, the unpadded content box inside the padded `#terminal` card, refits on resize and on display-scale change, and reattaches WebGL after a lost GPU context. Text uses bundled Cascadia Mono (variable, OFL) at weight 500, bold 700.

Selection uses the usual mouse gestures. Ctrl+Shift+C copies selected text; ordinary Ctrl+C remains terminal input. Clipboard permission is controlled by the host.

W12 explicit view actions:

- Host `paste` with `text` uses xterm paste semantics and adds no Return.
- Host `copy` requests the actual selection; host `focus` returns terminal focus.
- Host `copyOnSelect` with `enabled` affects user pointer selection only.
- Page `copy` with `text` is sent after Copy or opted-in pointer selection.
- Page `pasteRequest`, `findRequest`, `findNext` (`previous` boolean), and `contextMenu` ask the owning native view to act.
- Page `findResult` carries the real search `index` and `count`.

Native paste handles files and images only for local sessions. Server sessions show a transfer refusal rather than inserting a PC-only path. Clipboard contents are read only after the user's Paste action.
