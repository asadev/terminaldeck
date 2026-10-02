/**
 * Stays Fixed — settings for Terminal Deck.
 *
 * Started from `staysfixed init`, which read this repository and worked out most of
 * what is below on its own. What it could not work out was filled in by hand and
 * every one of those is marked WRITTEN BY HAND with the reason.
 *
 * WHAT THIS REPOSITORY MAKES. Five things out of one tree:
 *   1. the desktop app          Electron, for Mac and for Windows
 *   2. the headless host        a command-line program that runs sessions with no window
 *   3. the phone client         a web app in pwa/, which is also what the phone opens
 *   4. the iPhone app           ios/TerminalDeck.xcodeproj
 *   5. the Android app          android/
 * A change in shared code can break any of them, which is the whole reason this file
 * covers more than one.
 *
 * THE ONE THING TO KNOW BEFORE RUNNING THIS. Two of the adapters — `process` and
 * `web` — copy the whole project into a scratch folder before they run it, so that a
 * run can write anywhere it likes without touching your working copy. This working
 * copy is 12 GB (ios/ is 9 GB of Xcode build output, release/ is 1.3 GB of installers,
 * node_modules is 594 MB) and this Mac has 12 GB free. So those two are switched OFF
 * at this path and switched on in a worktree, which holds only the 2,398 tracked files
 * and 49 MB:
 *
 *     git worktree add /tmp/td-check HEAD
 *     cp staysfixed.config.mjs /tmp/td-check/
 *     cd /tmp/td-check && npx staysfixed check
 *
 * `source` and `electron` do not copy anything and run here, at full size, as they are.
 */

export default {
  // The name this record is kept under. Each product keeps its own record of what
  // "working" means, so the name is how two of them are told apart.
  product: 'terminaldeck',

  // ───────────────────────────────────────────────────────────────────────
  // Reading the code. Free, exact, runs nothing, cannot break anything, and it
  // is the only channel that sees a door nobody has ever opened.
  //
  // Last read here: 452 private channels between the app's two halves, 5,111
  // exported names, 213 commands, 29 settings it reads, 0 HTTP routes.
  // ───────────────────────────────────────────────────────────────────────
  source: {
    // WRITTEN BY HAND. The default list is src, lib, app, bin, server, pages, api,
    // electron, main, packages — which reads the desktop app and misses three whole
    // products. These four folders are added because each one is a product of its own:
    //   pwa/src    the phone client
    //   relay      the server both ends meet on
    //   scripts    the release machinery, and it is what breaks a release when it breaks
    //   native     the speech and confinement helpers
    folders: ['src', 'packages', 'pwa/src', 'relay', 'scripts', 'native'],
  },

  // ───────────────────────────────────────────────────────────────────────
  // The headless host — the command-line half of this product, the one that runs
  // on a server with no window. Every command runs in a throwaway copy of this
  // project with the clock stopped, a scratch home folder, and every outbound
  // connection recorded and then refused.
  //
  // WRITTEN BY HAND, all of it: `staysfixed init` proposed nothing here, because
  // the host is built into out/headless/ which is not committed, so nothing in
  // package.json names it. Build it with `npm run build:headless` first.
  //
  // ONLY READ-ONLY COMMANDS ARE LISTED. `pair`, `revoke`, `folders add|remove`
  // and `stop` all change something, and `stop` would stop a host that is running
  // for real. They are named here so it is visible that they were left out on
  // purpose rather than missed.
  // ───────────────────────────────────────────────────────────────────────
  process: {
    commands: [
      { name: 'the help text', run: 'node out/headless/cli.mjs --help', describe: 'the whole command list a person sees first' },
      { name: 'the version', run: 'node out/headless/cli.mjs --version', describe: 'what version the host says it is' },
      { name: 'status with no host running', run: 'node out/headless/cli.mjs status', describe: 'what it says when nothing is running — the first thing anybody sees when it will not start' },
      { name: 'devices with nothing paired', run: 'node out/headless/cli.mjs devices', describe: 'the empty device list, on a scratch home folder' },
      { name: 'folders with nothing allowed', run: 'node out/headless/cli.mjs folders', describe: 'which folders a device may use before any have been added' },
      { name: 'an unknown command', run: 'node out/headless/cli.mjs no-such-command', describe: 'what it says and what it exits with when a command is wrong' },
    ],
    // What the package hands other code. Compared as a list of exported names, so a
    // rename or a deletion in the shared brand module shows up without running the app.
    imports: [
      { name: 'the brand module', module: './src/shared/brand.ts', describe: 'the one place the product name lives' },
    ],
  },

  // ───────────────────────────────────────────────────────────────────────
  // The phone client in pwa/. Opened in a throwaway browser with the clock
  // stopped, motion killed, randomness seeded and the internet cut off. What is
  // compared is what the screen MEANS — the roles, names and states a screen
  // reader would read — never the markup, so a restyle reports nothing at all.
  //
  // `start` rather than `url` on purpose: one address can only serve one build,
  // so with an address alone both halves of the comparison read the same running
  // copy and prove nothing.
  // ───────────────────────────────────────────────────────────────────────
  web: {
    start: 'npm --prefix pwa run build && npx --yes serve -s pwa/dist -l $PORT',
    // WRITTEN BY HAND. init found the one index.html and proposed only "/". The phone
    // client is a single page that switches on a hash, so these are the real screens.
    screens: [
      { name: 'the front page', url: '/' },
      { name: 'pairing a phone', url: '/#pair' },
      { name: 'the session list', url: '/#sessions' },
      { name: 'settings', url: '/#settings' },
    ],
    // Nothing off this machine. The phone client dials a relay; a check must never.
    allowHosts: ['127.0.0.1', 'localhost'],
  },

  // ───────────────────────────────────────────────────────────────────────
  // The desktop app. Opened on its own — own settings folder, own ports, own
  // debug port — and read on both sides: the window, and the private channels
  // behind it. Nothing it starts is left running, and nothing it did not start
  // is ever closed.
  // ───────────────────────────────────────────────────────────────────────
  electron: {
    binary: 'release/mac-arm64/Terminal Deck.app',
    appId: 'dev.terminaldeck.app',

    // NO identityEnv, and this is an answer rather than an omission. `staysfixed init`
    // asked for the setting that carries this app's device id, because two runs claiming
    // one id fight over the same slot — which is exactly the bug diagnosed on this
    // product on 2026-08-28. Every environment variable the main process reads was
    // checked (there are 29) and not one of them carries a device or machine id: the
    // identity is generated into the settings folder, and the adapter already gives
    // every run a settings folder of its own. So there is nothing to pass through.

    // Private channels asked to answer, each one its own journey — so a channel that
    // stops ANSWERING is caught, not only one that stops existing. Every one of these
    // was checked in src/main to confirm it takes no arguments and writes nothing.
    // Left out on purpose: settings:set, settings:reset, settings:clear-browser-data
    // (they write), settings:open-path (it opens a Finder window), browser-password:*
    // (secrets), tailnet:status and update:get (they reach off this machine).
    exercise: [
      'brand:get',
      'settings:get',
      'settings:about',
      'settings:paths',
      'prefs:get',
      'session:list',
      'projects:list',
      'machines:list',
      'servers:list',
      'setup:status',
      'copilot:state',
      'voice:status',
      'hooks:status',
      'log:status',
      'deck-control:status',
    ],
  },

  // There is no "ios" or "android" section yet. Both apps are in this repository and
  // both are read by the contract channel above, so a door disappearing out of their
  // shared code is caught. Neither is OPENED: the iPhone app wants a simulator build
  // and the Android app wants an emulator, and neither has been proven on this machine.
  // That is a hole, it is named here, and `staysfixed check` names it again on every run.
};
