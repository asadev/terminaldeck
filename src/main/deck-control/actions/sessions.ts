/**
 * Sessions, projects, files, git, the copilot and the window itself: every action a person can take, and the tool that takes it.
 *
 * See `./types.ts` for what an entry means. `null` is "not decided yet" and
 * fails `actions.test.ts` on purpose.
 */

import type { CoverageMap } from './types'
import { BRAND } from '../../../shared/brand'

/*
 * The skips that more than one channel shares, written once so the reason is
 * the same sentence wherever it applies.
 */

/** A watch the window holds open so it is pushed changes; a tool reads on demand instead. */
const SKIP_SUBSCRIPTION =
  'A subscription the window keeps open to be pushed changes; the matching read tool answers on demand instead.'

/** Stopping a search the window started; a tool call is answered whole, so there is nothing in flight to stop. */
const SKIP_CANCEL =
  'Cancels a search the window has in flight; a tool call is answered whole, so there is never one to cancel.'

/** Dropping a cached reader the window was holding for a conversation it has closed. */
const SKIP_READER_RELEASE =
  'Tells the main process the window closed a conversation, so its cached reader can go; plumbing, not a choice.'

/** `confine/records.ts`: the record of what the assistants did is fenced from them. */
const SKIP_ACTION_LOG =
  'The action log is the record of what the assistants did, fenced from them on purpose (confine/records.ts); the person reads it in Activity.'

/** `copilot.home` is under the `copilot.` prefix every tool is refused (`catalogue.ts`). */
const SKIP_COPILOT_FOLDER =
  `Which folder ${BRAND.assistant} runs in is a \`copilot.\` setting, refused to every tool however a person answers; reading it is hoot.state.`

/** The clipboard can hold a password the person just copied. */
const SKIP_CLIPBOARD =
  'It reads this Mac’s clipboard, which can hold a password the person just copied; files.upload sends a file in directly instead.'

export const sessionsCoverage: CoverageMap = {
  'alerts:project': { tool: 'alerts.list' },
  'artifacts:changes': { tool: 'artifacts.list' },
  'artifacts:list': { tool: 'artifacts.list' },
  'attach:boundary': { tool: 'sessions.attach' },
  'attach:bring-in': { tool: 'sessions.attach' },
  'attach:browse': { tool: ['projects.browse', 'sessions.attach'] },
  'attach:inspect': { tool: 'sessions.attach' },
  'attach:paste': { skip: SKIP_CLIPBOARD },
  'chat:close': { skip: SKIP_READER_RELEASE },
  'chat:load': { tool: ['sessions.transcript', 'chats.read'] },
  'chat:tail': { tool: ['sessions.transcript', 'chats.read'] },
  'copilot:actions': { skip: SKIP_ACTION_LOG },
  'copilot:ensure': { tool: 'hoot.run' },
  'copilot:files': { tool: 'hoot.state' },
  'copilot:folder': { tool: 'hoot.state' },
  'copilot:folder:clear': { skip: SKIP_COPILOT_FOLDER },
  'copilot:folder:pick': { skip: SKIP_COPILOT_FOLDER },
  'copilot:memory': { tool: 'hoot.memory' },
  'copilot:memory-delete': { tool: 'hoot.memory' },
  'copilot:memory-read': { tool: 'hoot.memory' },
  'copilot:memory-write': { tool: 'hoot.memory' },
  'copilot:read-composed': { tool: 'hoot.instructions' },
  'copilot:read-contract': { tool: 'hoot.instructions' },
  'copilot:read-folder-instructions': { tool: 'hoot.instructions' },
  'copilot:read-instructions': { tool: 'hoot.instructions' },
  'copilot:reset-instructions': { tool: 'hoot.instructions' },
  'copilot:reveal': { tool: 'hoot.run' },
  'copilot:scaffold': { tool: 'hoot.run' },
  'copilot:signin': { tool: 'hoot.state' },
  'copilot:state': { tool: 'hoot.state' },
  'copilot:stop': { tool: 'hoot.run' },
  'copilot:write-folder-instructions': { tool: 'hoot.instructions' },
  'copilot:write-instructions': { tool: 'hoot.instructions' },
  'dashboard:clear': { tool: 'dashboard.layout' },
  'dashboard:load': { tool: 'dashboard.layout' },
  'dashboard:save': { tool: 'dashboard.layout' },
  'deck-control:activity': { skip: SKIP_ACTION_LOG },
  'deck-control:consent-attach': { skip: 'The window registering itself as the one place confirmations are shown; plumbing, with nothing a person chooses.' },
  'deck-control:consent-respond': { skip: 'Answering a confirmation is the person’s answer; a tool that could give it would let the caller approve its own request.' },
  'deck-control:status': { tool: 'tools.status' },
  'deck-control:tour-report': { skip: 'The window reporting how far a tour has played; it records what a person was shown, and only the playing window can say that.' },
  'deck-control:tours': { skip: 'Past tours are kept with the action log, the record fenced from the assistants it describes (confine/records.ts).' },
  'deckignore:explain': { tool: 'files.ignored' },
  'deckignore:filter': { tool: 'files.ignored' },
  'deckignore:invalidate': { tool: 'files.ignored' },
  'deckignore:overview': { tool: 'files.ignored' },
  'dev:ports': { tool: 'dev.servers' },
  'dev:server:list': { tool: 'dev.servers' },
  'dev:server:start': { tool: 'dev.servers' },
  'fs:list': { tool: 'files.list' },
  'fs:read': { tool: 'files.read' },
  'git:diff': { tool: 'git.diff' },
  'git:init': { tool: 'git.init' },
  'git:status': { tool: 'git.status' },
  'git:unwatch': { skip: SKIP_SUBSCRIPTION },
  'git:watch': { skip: SKIP_SUBSCRIPTION },
  'insights:latest': { tool: 'chats.insights' },
  'insights:list': { tool: 'chats.list' },
  'insights:session': { tool: 'chats.insights' },
  'link:menu': { skip: 'Pops a native menu at the pointer over a link; its two choices are browser.open (in the app) and links.open (the Mac’s browser).' },
  'link:open': { tool: 'browser.open' },
  'link:opened': { skip: 'The window answering which tab it opened for a link the main process routed; a reply, not something a person chooses.' },
  'link:system': { tool: 'links.open' },
  'menu:hidden-commands': { skip: 'The window telling the menu bar which items to hide for uninstalled features; plumbing between the two halves of the app.' },
  'notifications:delivery': { tool: 'notifications.status' },
  'notifications:open-settings': { tool: 'notifications.status' },
  'notifications:support': { tool: 'notifications.status' },
  'plan:unwatch': { skip: SKIP_SUBSCRIPTION },
  'plan:watch': { tool: 'sessions.account' },
  'project:home': { tool: 'projects.browse' },
  'project:pick': { tool: ['projects.browse', 'projects.add'] },
  'projects:add': { tool: 'projects.add' },
  'projects:list': { tool: 'projects.list' },
  'projects:remove': { tool: 'projects.remove' },
  'search:cancel': { skip: SKIP_CANCEL },
  'search:files': { tool: 'files.find' },
  'search:invalidate': { tool: 'files.find' },
  'session-search:cancel': { skip: SKIP_CANCEL },
  'session-search:run': { tool: 'sessions.search' },
  'session:account': { tool: 'sessions.account' },
  'session:create': { tool: 'sessions.start' },
  'session:held-forget': { tool: 'sessions.held' },
  'session:held-retry': { tool: 'sessions.held' },
  'session:kill': { tool: 'sessions.stop' },
  'session:list': { tool: 'sessions.list' },
  'session:rename': { tool: 'sessions.rename' },
  'session:resize': { skip: 'The window telling a session the size of the box it is drawn in; a session started by a tool is sized when someone opens it.' },
  'session:row-menu': { skip: 'Pops the native ⋯ menu on a sidebar row; its items are sessions.stop, ui.do (show at the top), windows.pop_out / windows.dock and browser.open (connect a browser).' },
  'session:scrollback': { tool: ['sessions.screen', 'sessions.transcript'] },
  'session:switch-account': { tool: 'sessions.account' },
  'session:switch-armed': { tool: 'sessions.account' },
  'session:switch-cancel': { tool: 'sessions.account' },
  'session:switch-later': { tool: 'sessions.account' },
  'session:switch-plan': { tool: 'sessions.account' },
  'session:write': { tool: ['sessions.send', 'sessions.keys'] },
  'sessions:held': { tool: 'sessions.held' },
  'transfer:stage': { tool: 'files.upload' },
  // A session in a window of its own, and back — `main/popout-windows.ts`.
  'popout:open': { tool: 'windows.pop_out' },
  'popout:dock': { tool: 'windows.dock' },
  // Bringing a session's own window to the front is what pop_out does for a session that is already out.
  'popout:focus': { tool: 'windows.pop_out' },
  'popout:list': { tool: 'windows.list' },
  'popout:rekey': { skip: 'A session window following its own session through an account switch; sessions.account makes the switch and the window follows by itself.' },
  'popout:labels': { skip: 'The main window telling the session windows the names it already shows; plumbing so both say the same thing, nothing a person chooses.' },
  'popout:show-main': { tool: 'ui.do' },
  // Hoot in the menu bar — `main/hoot-menubar.ts`. Talking to Hoot from it is talking to Hoot.
  // Hoot is a session: a message to it is sessions.send to the id hoot.state names.
  'hoot-panel:say': { tool: 'sessions.send' },
  'hoot-panel:start-hoot': { tool: 'hoot.run' },
  'hoot-panel:snapshot': { tool: ['sessions.list', 'hoot.state'] },
  'hoot-panel:show-session': { tool: 'ui.do' },
  'hoot-menubar:config': { tool: 'ui.list' },
  'hoot-menubar:configure': { tool: 'ui.do' },
  'hoot-menubar:open': { tool: 'ui.do' },
  'hoot-panel:pointer': { skip: 'The menu bar panel telling the main process the pointer is over it, so it stays open; plumbing, not a choice.' },
  'hoot-panel:held': { skip: 'The menu bar panel saying its box has text or the keyboard, so it stays open; plumbing, not a choice.' },
  'hoot-panel:focus': { skip: 'The menu bar panel asking for the keyboard after a click in its box; plumbing for a person typing, not an action.' },
  'hoot-panel:close': { skip: 'Escape in the menu bar panel; the panel is a view of things tools already read and do, so closing it changes nothing.' },
  'hoot-panel:size': { skip: 'The menu bar panel telling its window how tall its content is; layout, nothing a person chooses.' },
  'session:labels': { skip: 'The main window telling the menu bar the names it already shows for its sessions; plumbing so both say the same thing.' },
  'window:dimmed': { skip: 'The window reporting that a sheet has dimmed it; plumbing so the native chrome dims with it, nothing a person chooses.' },
}
