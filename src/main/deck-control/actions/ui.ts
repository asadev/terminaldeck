/**
 * The actions that never reach the main process — and the tool that takes each.
 *
 * `sessions.ts` and its three siblings cover every channel the preload sends.
 * That table is blind to the other half of the app: what a person does by
 * clicking that only changes the window — a view, a split, which session is in
 * front, which Settings section is open. Those live in `App.tsx` and reach
 * nothing outside it, so the only honest way to claim an AI can do them is a
 * second table, kept against the source the same way the first one is.
 *
 * Two parts:
 *
 *  - {@link UI_COMMANDS} — every command id the window answers to: the palette's
 *    rows and `run()`'s aliases in `App.tsx`, the menu bar's items in
 *    `main/menu.ts`, and the chords in `renderer/keymap.ts`. `ui.test.ts` reads
 *    all three files and fails on an id that is missing here, listed twice, or no
 *    longer in any of them — so a new palette row without a decision is a red
 *    test.
 *  - {@link UI_GESTURES} — things done with the pointer that are not commands at
 *    all. No source lists them, so the test only checks each has a decision; the
 *    list is written from the sidebar, the tab strip and the session chrome.
 *
 * An entry is the same {@link Coverage} the channel tables use. `ui.do` is the
 * bridge in `ui-tools.ts`; several commands point elsewhere because a tool that
 * does the thing directly is better than a command that opens a dialog nobody
 * can answer — `ui-tools.ts` refuses those ids and says which tool to use, and
 * this table and that list are checked against each other.
 */

import type { CoverageMap } from './types'

export const UI_COMMANDS: CoverageMap = {
  // Opening views and panes — the bridge, exactly as the palette runs them.
  'view.browser': { tool: 'ui.do' },
  'view.copilot': { tool: 'ui.do' },
  'view.dashboard': { tool: 'ui.do' },
  'view.overview': { tool: 'ui.do' },
  'view.files': { tool: 'ui.do' },
  'view.artifacts': { tool: 'ui.do' },
  'view.git': { tool: 'ui.do' },
  'view.github': { tool: 'ui.do' },
  'view.alerts': { tool: 'ui.do' },
  'view.readiness': { tool: 'ui.do' },
  'view.store': { tool: 'ui.do' },
  'view.mcp': { tool: 'ui.do' },
  'view.hooks': { tool: 'ui.do' },
  'view.inspector': { tool: 'ui.do' },
  'app.inspector': { tool: 'ui.do' },
  'view.terminal': { tool: 'ui.do' },
  'view.sidebar': { tool: 'ui.do' },
  'view.swarm': { tool: 'ui.do' },
  'pane.split': { tool: 'ui.do' },
  'pane.close': { tool: 'ui.do' },
  'pane.focusLeft': { tool: 'ui.do' },
  'pane.focusRight': { tool: 'ui.do' },
  'session.next': { tool: 'ui.do' },
  'session.previous': { tool: 'ui.do' },
  'session.jump': { tool: 'ui.do' },
  'app.preferences': { tool: 'ui.do' },
  'app.about': { tool: 'ui.do' },
  'app.setup': { tool: 'ui.do' },
  'app.help': { tool: 'ui.do' },
  'app.shortcuts': { tool: 'ui.do' },
  // Installing a feature is a configuration change; `ui.do` raises it to alter.
  'features.install.*': { tool: 'ui.do' },

  // Commands that open a dialog or a native panel and then wait for typing or a
  // pick — refused by `ui.do` with the tool that does the job directly.
  'session.new': { tool: 'sessions.start' },
  'session.newDialog': { tool: 'sessions.start' },
  'session.resume': { tool: 'sessions.start' },
  'session.close': { tool: 'sessions.stop' },
  // A session's own window, and back — the palette rows and the File menu.
  'session.popOut': { tool: 'windows.pop_out' },
  'session.dock': { tool: 'windows.dock' },
  'project.open': { tool: ['projects.browse', 'projects.add'] },
  'palette.quickOpen': { tool: 'files.find' },
  'app.quickOpen': { tool: 'files.find' },
  'view.search': { tool: 'sessions.search' },
  'panel.search': { tool: 'sessions.search' },
  'palette.commands': { tool: 'ui.list' },
  'app.palette': { tool: 'ui.list' },
  'app.join': {
    skip: 'The Join dialog only collects a code for session sharing that is not built yet; it opens no connection, so there is nothing to do.',
  },

  // Chords handled by the terminal itself rather than by `run()`.
  'terminal.interrupt': { tool: 'sessions.keys' },
  'terminal.escape': { tool: 'sessions.keys' },
  'terminal.clear': { tool: 'sessions.keys' },
  'terminal.find': { tool: 'sessions.screen' },
  'terminal.copy': {
    skip: 'It copies the selected terminal text to this Mac’s clipboard; sessions.screen hands the same text straight back instead.',
  },

  // Keys inside a dialog. No tool opens a dialog and leaves it for a caller to drive.
  'modal.close': { skip: 'A key inside an open dialog; the tools act directly and never leave a dialog waiting on a caller.' },
  'modal.confirm': { skip: 'A key inside an open dialog; the tools act directly and never leave a dialog waiting on a caller.' },
  'modal.next': { skip: 'A key inside an open dialog; the tools act directly and never leave a dialog waiting on a caller.' },
  'modal.previous': { skip: 'A key inside an open dialog; the tools act directly and never leave a dialog waiting on a caller.' },
}

export const UI_GESTURES: CoverageMap = {
  'click a session row (bring it to the front)': { tool: 'ui.do' },
  'open a Settings section': { tool: 'ui.do' },
  'double-click a session to rename it': { tool: 'sessions.rename' },
  'the ✕ on a session row or tab': { tool: 'sessions.stop' },
  'row menu: Show at the top / Fold back': { tool: 'ui.do' },
  'row menu: Connect browser': { tool: 'browser.open' },
  'row menu: open the assistant turn that started it': {
    skip: 'It opens the Activity row a session came from; that record is fenced from the assistants it describes (confine/records.ts).',
  },
  'the account chip on a session': { tool: 'sessions.account' },
  'Try again / Forget on a session that did not start': { tool: 'sessions.held' },
  'drop a file on a session': { tool: ['sessions.attach', 'files.upload'] },
  'paste an image into a session': { tool: 'files.upload' },
  'click a file in the Files view': { tool: 'files.read' },
  'type into a terminal': { tool: ['sessions.send', 'sessions.keys'] },
  'read a terminal': { tool: 'sessions.screen' },
  'drag a session tab off the window (its own window)': { tool: 'windows.pop_out' },
  'row menu: Move to New Window / Show Its Window / Move Back': { tool: ['windows.pop_out', 'windows.dock'] },
  'the session window’s close button (back to the main window)': { tool: 'windows.dock' },
  'drag a tab or a split divider': {
    skip: 'Arranging the window by dragging is geometry with no effect beyond the pixels; the split and swarm commands are ui.do.',
  },
  'resize the sidebar': {
    skip: 'A width remembered for this window only; nothing else reads it, and showing or hiding the sidebar is ui.do.',
  },
}
