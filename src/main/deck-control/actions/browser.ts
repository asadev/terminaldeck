/**
 * The browser, its profiles, extensions, downloads and the Store: every action a person can take, and the tool that takes it.
 *
 * See `./types.ts` for what an entry means. `null` is "not decided yet" and
 * fails `actions.test.ts` on purpose.
 *
 * ## How the browser's hundred-odd buttons became a dozen tools
 *
 * One tool per panel, named for the panel, with the button as an `action` —
 * `browser-area-kit.ts` has the argument. Every tool named below is real, and
 * `browser-coverage.test.ts` fails if one of them is not.
 *
 * ## The skips, and the four kinds of reason they have
 *
 *  - **Plumbing.** The window reporting a pane's rectangle, that it opened or
 *    closed one, that it claimed a view, or answering one of the drive's own
 *    requests. Nobody chooses any of them; each names the tool that makes the
 *    choice behind it.
 *  - **A native menu pop-up.** The two attach menus. What they offer is
 *    `browser.windows` with `attach`.
 *  - **A secret in the clear.** Copying a saved password puts it on the
 *    clipboard. Filling it into its page is offered instead.
 *  - **The person's answer to an agent's own question.** Approving a request to
 *    copy a sign-in, and "Done, carry on" on a handover. A tool that answered
 *    either would let the agent that asked answer itself.
 *
 * And two drawing-mode channels whose input is a picture the person drew with
 * the pen; a caller has no pen.
 */

import type { CoverageMap } from './types'

export const browserCoverage: CoverageMap = {
  'browser-download:cancel': { tool: 'browser.downloads' },
  'browser-download:clear': { tool: 'browser.downloads' },
  'browser-download:destination': { tool: 'browser.downloads' },
  'browser-download:folder': { tool: 'browser.downloads' },
  'browser-download:list': { tool: 'browser.downloads' },
  'browser-download:open': { tool: 'browser.downloads' },
  'browser-download:reveal': { tool: 'browser.downloads' },
  'browser-extension:add-crx': { tool: 'browser.extensions' },
  'browser-extension:add-folder': { tool: 'browser.extensions' },
  'browser-extension:enable': { tool: 'browser.extensions' },
  'browser-extension:install': { tool: 'browser.extensions' },
  'browser-extension:list': { tool: 'browser.extensions' },
  'browser-extension:options': { tool: 'browser.extensions' },
  'browser-extension:popup': { tool: 'browser.extensions' },
  'browser-extension:reload': { tool: 'browser.extensions' },
  'browser-extension:remove': { tool: 'browser.extensions' },
  'browser-extension:rename': { tool: 'browser.extensions' },
  'browser-history:clear': { tool: 'browser.history' },
  'browser-history:forget': { tool: 'browser.history' },
  'browser-history:list': { tool: 'browser.history' },
  'browser-history:suggest': { tool: 'browser.history' },
  'browser-isolation:count': { tool: 'browser.windows' },
  'browser-isolation:dispose': {
    skip:
      'Plumbing the window sends as it closes an Isolated tab, to throw away that tab’s in-memory partition; nobody chooses it, and closing the window with browser.windows does it.',
  },
  'browser-isolation:key': { tool: 'browser.open' },
  'browser-password:answer': { tool: 'browser.passwords' },
  'browser-password:available': { tool: 'browser.passwords' },
  'browser-password:copy': {
    skip:
      'It puts a saved password on the clipboard, which hands the secret itself to whatever reads the clipboard next; browser.passwords fills the login into its page instead, so the password never leaves the app.',
  },
  'browser-password:fill': { tool: 'browser.passwords' },
  'browser-password:forget': { tool: 'browser.passwords' },
  'browser-password:forget-all': { tool: 'browser.passwords' },
  'browser-password:list': { tool: 'browser.passwords' },
  'browser-password:show-file': { tool: 'browser.passwords' },
  'browser-password:state': { tool: 'browser.passwords' },
  'browser-profile:activate': { tool: 'browser.profiles' },
  'browser-profile:avatar': { tool: 'browser.profiles' },
  'browser-profile:create': { tool: 'browser.profiles' },
  'browser-profile:delete': { tool: 'browser.profiles' },
  'browser-profile:list': { tool: 'browser.profiles' },
  'browser-profile:rename': { tool: 'browser.profiles' },
  'browser-scraping:capture-clear': { tool: 'browser.scraping' },
  'browser-scraping:capture-reveal': { tool: 'browser.scraping' },
  'browser-scraping:config': { tool: 'browser.scraping' },
  'browser-scraping:config-set': { tool: 'browser.scraping' },
  'browser-scraping:ledger-clear': { tool: 'browser.scraping' },
  'browser-scraping:status': { tool: 'browser.scraping' },
  'browser-session:clear-cache': { tool: 'browser.data' },
  'browser-session:clear-cookies': { tool: 'browser.data' },
  'browser-session:clear-storage': { tool: 'browser.data' },
  'browser-session:cookies': { tool: 'browser.data' },
  'browser-session:info': { tool: 'browser.data' },
  'browser-signin:agents': { tool: 'browser.signin' },
  'browser-signin:diagnose': { tool: 'browser.signin' },
  'browser-signin:handover': { tool: 'browser.signin' },
  'browser-store:install': { tool: 'browser.store' },
  'browser-store:list': { tool: 'browser.store' },
  'browser-store:remove': { tool: 'browser.store' },
  'browser-view:claim': {
    skip:
      'Plumbing: the window claims a page’s view so its own toolbar can reach it, and releases it when the pane unmounts; nobody chooses it, and browser.page reaches every claimed page.',
  },
  'browser-view:devtools': { tool: 'browser.page' },
  'browser-view:find': { tool: 'browser.page' },
  'browser-view:find-stop': { tool: 'browser.page' },
  'browser-view:frame': {
    skip:
      'Draw mode’s own snapshot, taken and thrown away as the person starts drawing over the page; browser.page with action "screenshot" is the picture a caller wants.',
  },
  'browser-view:print': { tool: 'browser.page' },
  'browser-view:record': { tool: 'browser.page' },
  'browser-view:record-clear': { tool: 'browser.page' },
  'browser-view:release': {
    skip:
      'Plumbing: the window lets go of a page’s view when the pane unmounts; it is the other half of claim, and nobody chooses it.',
  },
  'browser-view:reveal': { tool: 'browser.page' },
  'browser-view:screenshot': { tool: 'browser.page' },
  'browser-view:screenshot-marked': {
    skip:
      'It saves the picture the person drew over the page with draw mode’s pen; a caller has no pen, and an image it made itself would be filed as if the person had marked it.',
  },
  'browser-view:user-agent': { tool: 'browser.page' },
  'browser-view:zoom': { tool: 'browser.page' },
  'browser-worker:ensure': { tool: 'browser.scraping' },
  'browser-worker:forget-lift': { tool: 'browser.scraping' },
  'browser-worker:inject': { tool: 'browser.lift_request' },
  'browser-worker:lift': { tool: 'browser.lift_request' },
  'browser-worker:lift-answer': {
    skip:
      'Approving or declining a request to copy a signed-in session is the person’s answer to an agent’s ask; a tool that gave it would let the agent that asked approve itself, so browser.lift_request files the ask and the person answers it.',
  },
  'browser-worker:lift-requests': { tool: 'browser.scraping' },
  'browser-worker:list': { tool: 'browser.workers' },
  'browser-worker:pace': { tool: 'browser.scraping' },
  'browser-worker:register': { tool: 'browser.scraping' },
  'browser-worker:unregister': { tool: 'browser.scraping' },
  'browser:back': { tool: 'browser.page' },
  'browser:bind': { tool: 'browser.windows' },
  'browser:bind-menu': {
    skip:
      'A native menu pop-up the window shows over a session row; the choice it offers is attaching a window, which browser.windows does with action "attach".',
  },
  'browser:bindings': { tool: 'browser.windows' },
  'browser:block-capture': { tool: 'browser.scraping' },
  'browser:block-capture-set': { tool: 'browser.scraping' },
  'browser:bounds': {
    skip:
      'Plumbing: the window reports where a page’s rectangle is as its layout moves; nobody chooses it.',
  },
  'browser:close': { tool: 'browser.windows' },
  'browser:connect-menu': {
    skip:
      'A native menu pop-up the window shows over a browser window; the choice it offers is attaching it to a session, which browser.windows does with action "attach".',
  },
  'browser:create': { tool: 'browser.windows' },
  'browser:drive-closed': {
    skip:
      'Plumbing: the window answers the drive’s request to close a window with whether it did; nobody chooses it.',
  },
  'browser:drive-opened': {
    skip:
      'Plumbing: the window answers the drive’s request for a tab with the tab it made; nobody chooses it.',
  },
  'browser:drive-resume': {
    skip:
      'The person’s own answer to a handover — Done, carry on — on the page an agent handed them; a tool that gave it would let the agent that asked take the page back from them mid-sign-in.',
  },
  'browser:drive-shown': {
    skip:
      'Plumbing: the window answers the drive’s request to bring a window forward with whether it did; nobody chooses it.',
  },
  'browser:drive-status': { tool: 'browser.windows' },
  'browser:forward': { tool: 'browser.page' },
  'browser:inspect': { tool: 'browser.page' },
  'browser:navigate': { tool: 'browser.page' },
  'browser:reach:hold': { tool: 'browser.windows' },
  'browser:reach:list': { tool: 'browser.windows' },
  'browser:reach:release': { tool: 'browser.windows' },
  'browser:reload': { tool: 'browser.page' },
  'browser:state': { tool: 'browser.page' },
  'browser:stop': { tool: 'browser.page' },
  'browser:unbind': { tool: 'browser.windows' },
  'browser:visible': {
    skip:
      'Plumbing: the window reports whether a page’s pane is on screen; nobody chooses it.',
  },
  'browser:window-closed': {
    skip:
      'Plumbing: the window reports a pane that has gone; browser.windows with action "close" is the choice behind it.',
  },
  'browser:window-opened': {
    skip:
      'Plumbing: the window reports a pane it has just made, so the main process can number it; browser.windows with action "open" is the choice behind it.',
  },
  'chrome-import:browsers': { tool: 'browser.import' },
  'chrome-import:scan': { tool: 'browser.import' },
  'community:install': { tool: 'store.community' },
  'community:list': { tool: 'store.community' },
  'community:remove': { tool: 'store.community' },
  'cookie-import:clear': { tool: 'browser.import' },
  'cookie-import:run': { tool: 'browser.import' },
  'cookie-import:sources': { tool: 'browser.import' },
  'cookie-import:status': { tool: 'browser.import' },
}
