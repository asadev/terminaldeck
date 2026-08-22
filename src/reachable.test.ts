import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { describe, expect, it } from 'vitest'
import { KEYMAP, chordFor } from './renderer/keymap'
import { PANELS } from './renderer/shell/panels'
import { SETTINGS } from './renderer/settings/settings-schema'
import { TERMINAL_COMMANDS } from './renderer/components/TerminalView'

/**
 * Nothing in this app may be advertised without a way to get to it.
 *
 * This file started as one check — "every module is imported from an entry
 * point" — written after the project shipped five features as Done on a public
 * roadmap that had no way in: split panes, unread indicators, notifications on
 * completion, task-derived session titles and restore-on-launch. All five had
 * real code, real tests and no path a user could take. Two agents then read
 * that roadmap and wrote it onto the marketing site as fact.
 *
 * That check was too weak, and the weakness had a shape. `notifications.ts`
 * passed it for months: the settings pane imports `canNotify` out of the module
 * to draw a permission warning, so the file was "reachable" while
 * `SessionNotifier` — the entire notification engine — was never constructed
 * and no banner was ever shown. Five settings pointed at it. `session-title.ts`
 * passed it the same way, `@xterm/addon-search` was a dependency nobody loaded,
 * and Settings offered a font size that never reached a terminal.
 *
 * So the question here is no longer "is this module imported". It is "does this
 * thing have a way in", asked five ways, each of them mechanical:
 *
 *   1. every module is reachable from an entry point;
 *   2. every setting in the schema has something that reads it;
 *   3. every chord in the keymap has code that answers it;
 *   4. every command the menu sends is dispatched, and every shortcut the
 *      palette prints is the one the keymap actually binds;
 *   5. every view the sidebar offers renders something.
 *
 * Anything that genuinely cannot be checked mechanically is listed below with
 * the reason it is not a lie. Adding to a list is allowed; doing it silently is
 * not.
 */

const ROOT = resolve(__dirname, '..')
/**
 * Every way into this codebase.
 *
 * Five, not three, since the headless build: it is a second shell around the
 * same core, with two bins of its own — `src/headless/main.ts` is the four
 * commands a person types and `src/headless/daemon.ts` is the process a service
 * manager starts. Neither is reachable from the Electron entry and neither
 * reaches the other, which is the point: they are separate programs that happen
 * to ship in one package.
 */
const ENTRIES = [
  'src/main/index.ts',
  'src/preload/index.ts',
  'src/renderer/main.tsx',
  'src/headless/main.ts',
  'src/headless/daemon.ts',
  /*
   * The third program in the headless bundle, and the reason it is listed here
   * rather than allowed as an orphan.
   *
   * `src/headless/demo.ts` is a real entry point — `vite.headless.config.ts`
   * builds it, and `demo/Dockerfile` runs it as the process inside a visitor's
   * container. What it is *not* is a command anybody installs: it is kept out of
   * the npm package's `bin` and `files` because it is the only assembly that can
   * turn on public-host mode, which approves any device that redeems a code it
   * just minted. `src/headless/public-host.test.ts` is what keeps that line, by
   * asserting that nothing else in the tree enters the mode.
   */
  'src/headless/demo.ts',
]

const SOURCE = /\.tsx?$/
const isTest = (p: string): boolean => /\.(test|spec)\.tsx?$/.test(p)

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (SOURCE.test(name) && !isTest(name)) out.push(full)
  }
  return out
}

/**
 * Every non-test source file, as a path relative to the repo root and always
 * `/`-separated.
 *
 * The separator is not cosmetic. `relative` answers in the host's, so on
 * Windows every module came back as `src\renderer\unread.ts` — which matches no
 * key in any of the allowlists below, and reported all nine allowed modules as
 * new orphans (observed on Windows 11). Every list in this file is written the
 * way the repository writes a path everywhere else, so this is where the two
 * spellings are reconciled, once.
 */
const SOURCES = walk(join(ROOT, 'src')).map((f) => relative(ROOT, f).split(sep).join('/'))

const read = (rel: string): string => readFileSync(join(ROOT, rel), 'utf8')

/**
 * Source with its comments removed.
 *
 * Several checks below read source as text and ask what it puts on screen, and
 * a comment is the one part of a file that never reaches a screen. Explaining
 * that the palette used to say `shortcut: '⌘T'` must not read as the palette
 * saying it. Only whole-line `//` comments are stripped, so a `wss://` in the
 * middle of a line survives.
 */
const withoutComments = (source: string): string =>
  source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')

/** Text of every source file except the ones named, joined. */
function corpus(except: readonly string[] = []): string {
  return SOURCES.filter((f) => !except.includes(f))
    .map((f) => read(f))
    .join('\n')
}

/* ============================================================== 1. modules -- */

/** Unreachable on purpose, each with the reason it is not a lie. */
const KNOWN_UNREACHABLE: Record<string, string> = {
  'src/main/browser-chromium-launch.ts':
    'unreachable until wave-2 Lane B lands: it spawns chrome-for-testing over --remote-debugging-pipe and hands back fds 3/4, but the CDP codec that consumes those fds (`browser-cdp-pipe.ts`) is not built yet. It lives in src/ so tsc checks the launch flags and the fd stdio shape against the pipe adapter it will feed. REMOVE THIS ENTRY when Lane B wires it — a stale allowlist entry is its own lie.',
  'src/main/browser-extension-zip.fixture.ts':
    'unreachable on purpose: it builds the zip archives `browser-extension-unzip.test.ts` reads, ' +
    'including the malformed ones — path traversal, symlinks, a lying size, zip64 — that no real ' +
    'extension release would contain and that the reader has to refuse. It lives in src/ so tsc ' +
    'checks it against the reader it feeds, the same reason `servers/test-fixtures.ts` does.',
  'src/main/remote/sealed.electron-probe.ts':
    'unreachable from the app on purpose: it is the body of the Electron-runtime crypto check, ' +
    'bundled and run under ELECTRON_RUN_AS_NODE by scripts/check-electron-crypto.mjs during ' +
    '`npm test`. It lives in src/ so that tsc typechecks it against the modules it exercises.',
  // `src/main/confine/appcontainer.ts` was listed here and is not any more: it
  // is imported by `confine/index.ts`, and `confinementKind('win32')` now
  // answers 'appcontainer' whenever `windowsConfinementReady()` is true. The
  // entry described a build where it was not wired, and leaving it would have
  // been documentation asserting the opposite of the code.
  // `src/main/remote/copilot-grants.ts` and `copilot-runs.ts` were both listed
  // here and neither is any more, because the thing they were waiting for
  // landed. The entries said, correctly at the time, that the store was right
  // and nothing dispatched through it, and that the run manager was built and
  // not assembled — and both warned in the same words that the wrong fix would
  // be to reach them early from the UI, because "a switch in the devices panel
  // granting a phone read or act would be a permission control that changes
  // nothing a phone can do".
  //
  // What makes them reachable now is not a switch. `src/main/index.ts`
  // constructs one `CopilotAccess` — `copilot-grants.ts` became `copilot-link.ts`
  // when copilot access was a separate connection with its own code, and became
  // this when a device's *kind* replaced that connection on 2026-08-19 — and one
  // `CopilotRuns` over it, and hands the run
  // manager to `registerRemoteIpc`, which is what makes `server.ts` advertise
  // the `copilot` capability at all; the `copilot.*` frames reach real handlers;
  // `remoteCopilotCaller` is the caller function on every run's token, so
  // `DeckControl.call` checks each tool call against that device's grant as it
  // is dispatched. The panel came last, in the order §6 of COPILOT-REMOTE.md
  // insists on: it changes something before it exists.
  //
  // Deleted rather than reworded, per the note about `confine/appcontainer.ts`
  // above: an entry that outlives its reason is documentation asserting the
  // opposite of the code.
  'src/main/servers/servers.electron-probe.ts':
    'the same category as `remote/sealed.electron-probe.ts` at the top of this list, and for the ' +
    'identical reason: it is the body of the server transport check, bundled and run under ' +
    'ELECTRON_RUN_AS_NODE by scripts/check-servers-transport.mjs, which `npm test` runs after ' +
    'vitest. It has to live in src/ so that tsc typechecks it against `connection.ts` — the ' +
    'module whose behaviour under BoringSSL is the entire reason the check exists.',
  'src/main/servers/ssh2.d.ts':
    'an ambient declaration, not a module: it describes the slice of `ssh2` this app calls and ' +
    'emits nothing. It is hand-written rather than `@types/ssh2` so that `hostVerifier` can be ' +
    'declared REQUIRED where the library leaves it optional, which makes a connection path that ' +
    'skips the host key check fail to compile. Nothing imports it by path because nothing can; ' +
    'tsc picks it up from the tsconfig include, and `host-key-checked.test.ts` is the alarm on ' +
    'the fence in case somebody widens it.',
  'src/main/servers/ssh2-server.d.ts':
    'the same, for the half of `ssh2` the app never calls. `reach.ssh.test.ts` puts a real SSH ' +
    'server at the far end of a real socket so that a server\u2019s own localhost is proved through ' +
    'the real library rather than through a stand-in that agrees with the client; this declares ' +
    'the four calls that test makes. It is separate from `ssh2.d.ts` because that file is ' +
    'deliberately narrower than the library and mixing the two would leave the next reader unable ' +
    'to tell which declarations are load bearing. Nothing in the app may import it, and ' +
    '`host-key-checked.test.ts` enforces that structurally.',
  'src/main/servers/test-fixtures.ts':
    'test data, and deliberately shared rather than copied. Four test files in that folder ' +
    'describe the same server through it — facts, cards and a room measured off ' +
    '`terminaldeck-server` rather than invented — because four slightly different hand-written ' +
    'shapes is how a suite ends up green against a server the feature never produces. The walk ' +
    'excludes tests as importers on purpose, so a module only tests use looks like an orphan; ' +
    'this one is not a feature claiming to work, it is the description the features are checked ' +
    'against.',
  'src/renderer/driving/dim-budget.ts':
    'a checker rather than a feature, in the same category as ' +
    '`remote/sealed.electron-probe.ts` at the top of this list: it is the colour arithmetic — ' +
    'sRGB luminance, alpha compositing, contrast — behind the one number driving mode\'s scrim ' +
    'is allowed to be. Nothing imports it at runtime because the number does not live in ' +
    'TypeScript: `--drive-dim: rgba(0, 0, 0, 0.26)` is declared in `styles/tokens.css` for both ' +
    'themes, which is where every other colour in this app lives, and `FocusOverlay.css` reads ' +
    'the token. `dim-budget.test.ts` parses those very declarations out of `tokens.css` and ' +
    'fails if either end of the budget is broken — too light to read as dimmed at all, or dark ' +
    'enough to take the quietest text in the window below 3:1. So the module is reached by the ' +
    'thing that has to keep being true, and wiring it into the renderer would move a build-time ' +
    'proof into runtime arithmetic that computes a constant.',
  'src/shared/pairing-link.ts':
    'reachable, but not from the desktop app: `pwa/src/endpoint.ts` and `pwa/src/rendezvous.ts` ' +
    'import it, and this walk starts at the Electron entry points. What is left in the file is ' +
    '`isHostId` + `isRelayUrl` — the browser-safe restatement of the relay address alphabet — ' +
    'after the pairing LINK it was named for was deleted along with the QR code. The filename ' +
    'is now a leftover and is kept deliberately: `/.vercelignore` allowlists it by path and ' +
    '`pwa/tests/upload.test.ts` asserts that exact path, and a stale allowlist is a red Vercel ' +
    'deploy rather than a failing test here. Renaming it is a three-file change to make on a ' +
    'day when nothing is shipping.',
  // The five pacing modules — `estimate.ts`, `pacer.ts`, `interruption.ts`,
  // `usePacer.ts` and `PaceControls.tsx` — were listed here and are not any
  // more, because the thing they pace exists now. The entry said, correctly at
  // the time, that they were "built ahead of the feature they pace and honestly
  // unwired rather than pretending otherwise", and it warned in those words that
  // the wrong fix would be to reach them from the UI early: "a transport bar
  // wired into the sidebar with no tour behind it would be a control that
  // visibly does nothing".
  //
  // What reaches them now is not a bar. `main.tsx` renders `DriveHost`, which
  // listens on `deck-control:tour` for a plan the main process has already
  // validated; `tour-player.ts` constructs `browserPaceEngine` and
  // `attachInterruption` when one arrives, dispatches `arrive` the moment the
  // overlay reports a box drawn, and `DrivePanel.tsx` renders `PaceTransport`
  // in the rail's own column. The tool that produces a plan is `tour.play`,
  // contributed to the catalogue through `extraTools` — so the path from a
  // person asking a question to these modules ticking is a real one, end to end.
  //
  // Deleted rather than reworded, per the note about `confine/appcontainer.ts`
  // above: an entry that outlives its reason is documentation asserting the
  // opposite of the code.
}

/** Mirrors the tsconfig path aliases; anything bare is a package, not ours. */
function resolveSpec(spec: string, from: string): string | null {
  let base: string
  if (spec.startsWith('@shared/')) base = join(ROOT, 'src/shared', spec.slice('@shared/'.length))
  else if (spec.startsWith('@renderer/'))
    base = join(ROOT, 'src/renderer', spec.slice('@renderer/'.length))
  else if (spec.startsWith('.')) base = resolve(dirname(from), spec)
  else return null

  // The directory candidates go through `join` rather than string concatenation.
  // `base + '/index.ts'` is a path `existsSync` happily accepts on Windows and
  // that `walk` can never produce, because `walk` builds with `join` and gets a
  // backslash — so a module reached only through its `index` was in `seen` under
  // one spelling and looked for under another, and reported itself an orphan.
  // `src/renderer/chat/usage/index.ts` did exactly that.
  for (const candidate of [`${base}.ts`, `${base}.tsx`, join(base, 'index.ts'), join(base, 'index.tsx'), base]) {
    if (candidate && existsSync(candidate) && SOURCE.test(candidate)) return candidate
  }
  return null
}

function importsOf(file: string): string[] {
  const src = readFileSync(file, 'utf8')
  const specs: string[] = []
  const re = /(?:from\s*|import\s*\(\s*)['"]([^'"]+)['"]/g
  let m: RegExpExecArray | null
  while ((m = re.exec(src)) !== null) {
    const resolved = resolveSpec(m[1], file)
    if (resolved) specs.push(resolved)
  }
  return specs
}

describe('every module is reachable from an entry point', () => {
  /*
   * Tests are excluded as importers on purpose. A module imported only by its
   * own test is exactly the shape of the bug — `SplitView.tsx` looked imported
   * for that reason alone, for its whole life, and came within one commit of
   * being deleted over it. It is rendered from `App.tsx` now, through
   * `layout/panes.ts`, so it passes this check the way every other module does:
   * because something a user can reach actually uses it.
   */
  it('has no unlisted orphans', () => {
    const seen = new Set<string>()
    const stack = ENTRIES.map((e) => join(ROOT, e))
    while (stack.length > 0) {
      const file = stack.pop() as string
      if (seen.has(file)) continue
      seen.add(file)
      stack.push(...importsOf(file))
    }

    const orphans = SOURCES.filter((f) => !seen.has(join(ROOT, f)))
      .filter((f) => !(f in KNOWN_UNREACHABLE))
      .sort()

    expect(
      orphans,
      'These modules cannot be reached from the running app. Wire them, delete ' +
        'them, or add them to KNOWN_UNREACHABLE with the reason — but do not ' +
        'describe them as features that work.',
    ).toEqual([])
  })

  it('does not keep stale entries in the allowlist', () => {
    // An allowlist that outlives its reason is its own kind of lie.
    const missing = Object.keys(KNOWN_UNREACHABLE).filter((f) => !existsSync(join(ROOT, f)))
    expect(missing, 'listed as unreachable but no longer present').toEqual([])
  })
})

/* ============================================================= 2. settings -- */

/**
 * Settings whose only reader is the settings window itself, and why that is
 * honest rather than a switch over nothing.
 */
const SETTINGS_WITHOUT_READERS: Record<string, string> = {
  /*
   * Empty, and worth leaving as a record of why.
   *
   * There was exactly one entry — `general.language` — excused on the grounds
   * that a setting with a single value has nothing to read, and that it would
   * become a real setting the day a second language did. It has been removed
   * from the schema instead:
   *
   *   > "It will be always English and it is English, so there is no selection.
   *   > The option should not be there."
   *
   * Which is the better answer to the same observation, and it means this table
   * is now what it should always have been: the place a control that cannot act
   * is *argued for*, rather than the place one is parked.
   */
}

/** Files that only ever *declare* or *render* settings, so cannot count as readers. */
const SETTINGS_UI = [
  'src/renderer/settings/settings-schema.ts',
  'src/renderer/settings/controls.tsx',
]

describe('every setting has something that reads it', () => {
  /*
   * The failure this catches, four times over in one audit: "Restore sessions
   * on launch" restored nothing, "Record session history" recorded nothing,
   * "Show insight alerts" filtered nothing, and "Terminal font size" reached no
   * terminal. Every one of them stored a value perfectly.
   *
   * A reader is any source file outside the schema and the generic control
   * renderer that names the setting's id, or — for the four settings backed by
   * `store.ts` — names the preferences key the main process reads it by. That
   * is a low bar deliberately: it cannot prove the value is *obeyed*, only that
   * something, somewhere, asks for it. A switch nobody even asks about is the
   * bug this has actually shipped.
   */
  const haystack = corpus(SETTINGS_UI)

  for (const setting of SETTINGS) {
    const excuse = SETTINGS_WITHOUT_READERS[setting.id]
    it(`${setting.id} is read by something${excuse ? ' — or is honestly excused' : ''}`, () => {
      const byId = haystack.includes(`'${setting.id}'`)
      const byPrefsKey =
        setting.store === 'prefs' &&
        setting.prefsKey !== undefined &&
        new RegExp(`\\b${setting.prefsKey}\\b`).test(haystack)
      const read = byId || byPrefsKey

      if (excuse) {
        expect(
          read,
          `${setting.id} is listed in SETTINGS_WITHOUT_READERS but something now reads it — ` +
            'delete the excuse.',
        ).toBe(false)
        return
      }

      expect(
        read,
        `Nothing outside the settings window mentions ${setting.id}. It is a control the user ` +
          'can change that changes nothing. Wire it up, delete the row, or add it to ' +
          'SETTINGS_WITHOUT_READERS with the reason.',
      ).toBe(true)
    })
  }

  it('keeps no excuse for a setting that no longer exists', () => {
    const ids = new Set(SETTINGS.map((s) => s.id))
    expect(Object.keys(SETTINGS_WITHOUT_READERS).filter((id) => !ids.has(id))).toEqual([])
  })
})

/* ============================================================== 3. keymap -- */

const APP = 'src/renderer/App.tsx'

/**
 * Command ids `App.tsx` dispatches: the palette's table plus the switch that
 * catches everything else. Read out of the source because there is no DOM here
 * to mount the app in — the same reason `wiring.test.ts` is static.
 */
function appCommandIds(): Set<string> {
  const source = read(APP)
  const ids = new Set<string>()
  for (const m of source.matchAll(/\bid:\s*'([a-z][\w.]*)'/g)) ids.add(m[1])
  for (const m of source.matchAll(/\bcase\s+'([a-z][\w.]*)':/g)) ids.add(m[1])
  // ⌘1–9 is a range, so the digit is read off the event rather than dispatched.
  for (const m of source.matchAll(/id === '([a-z][\w.]*)'/g)) ids.add(m[1])
  return ids
}

/**
 * Bindings answered somewhere other than the app-wide dispatcher, and where.
 *
 * The named file has to mention the id, so this is a pointer rather than a
 * promise: move the handler and the test says so.
 */
const HANDLED_ELSEWHERE: Record<string, string> = {
  'terminal.find': 'src/renderer/components/TerminalView.tsx',
  'terminal.clear': 'src/renderer/components/TerminalView.tsx',
  'terminal.copy': 'src/renderer/components/TerminalView.tsx',
}

/**
 * Bindings that describe what a dialog already does, rather than naming a
 * command anything dispatches.
 *
 * These four are in the keymap so the shortcuts sheet can print them — a sheet
 * that cannot say "Escape closes this" is missing the key people look for
 * first. `Modal.tsx` binds Escape and `CommandPalette.tsx` binds the arrows and
 * Enter directly, because a dialog's own keyboard cannot go through a global
 * dispatcher: while a modal is open, `bindingsInScope` deliberately excludes
 * every global binding, which is what stops ⌘W closing a session behind it.
 */
const DOCUMENTED_ONLY: Record<string, string> = {
  'modal.close': 'src/renderer/components/Modal.tsx',
  'modal.confirm': 'src/renderer/components/CommandPalette.tsx',
  'modal.next': 'src/renderer/components/CommandPalette.tsx',
  'modal.previous': 'src/renderer/components/CommandPalette.tsx',
}

describe('every chord in the keymap has code that answers it', () => {
  const dispatched = appCommandIds()

  for (const binding of KEYMAP) {
    if (binding.passthrough) continue
    it(`${binding.id} (${binding.keys[0]}) is handled`, () => {
      if (binding.id in HANDLED_ELSEWHERE) {
        const file = HANDLED_ELSEWHERE[binding.id]
        expect(read(file), `${file} no longer mentions ${binding.id}`).toContain(binding.id)
        return
      }
      if (binding.id in DOCUMENTED_ONLY) {
        expect(existsSync(join(ROOT, DOCUMENTED_ONLY[binding.id]))).toBe(true)
        return
      }
      expect(
        dispatched.has(binding.id),
        `The shortcuts sheet prints ${binding.keys[0]} for "${binding.label}" and nothing in ` +
          `${APP} dispatches ${binding.id}. Implement it, or take the binding out of KEYMAP.`,
      ).toBe(true)
    })
  }

  it('claims no handler for a binding that is gone', () => {
    const ids = new Set(KEYMAP.map((b) => b.id))
    const stale = [...Object.keys(HANDLED_ELSEWHERE), ...Object.keys(DOCUMENTED_ONLY)].filter(
      (id) => !ids.has(id),
    )
    expect(stale, 'listed as handled but no longer in the keymap').toEqual([])
  })

  it('every command TerminalView claims is a real binding', () => {
    const ids = new Set(KEYMAP.map((b) => b.id))
    expect(TERMINAL_COMMANDS.filter((id) => !ids.has(id))).toEqual([])
  })
})

/* =========================================== 4. the menu and the palette -- */

describe('the menu and the palette agree with the app', () => {
  it('dispatches every command the application menu sends', () => {
    // The menu is in the main process and speaks an older dialect — `app.palette`
    // for what the keymap calls `palette.commands`. Aliases are fine; a menu item
    // that reaches a dispatcher with no case for it is a dead menu item.
    const menu = read('src/main/menu.ts')
    const sent = [...menu.matchAll(/send\('([a-z][\w.]*)'\)/g)].map((m) => m[1])
    expect(sent.length, 'no menu commands found — has menu.ts changed shape?').toBeGreaterThan(10)

    const dispatched = appCommandIds()
    expect(sent.filter((id) => !dispatched.has(id))).toEqual([])
  })

  it('writes down no chord of its own', () => {
    /*
     * The palette used to carry its chords as literal strings — `shortcut:
     * '⌘⇧R'` — and this test compared each of them with `chordFor(id, true)`.
     * That check caught drift from the keymap and could not, even in principle,
     * catch the bug that was actually shipping: `true` is hard-coded, so it
     * asserted the *macOS* rendering, and a Windows user was reading ⌘ glyphs
     * for a key their keyboard does not have.
     *
     * A literal cannot be made platform-correct, so there are no literals any
     * more; the palette maps its rows through `chordFor`, which renders for
     * whichever platform the window is on. What is left to guard is that nobody
     * puts one back.
     */
    const source = withoutComments(read(APP))
    const literals = [...source.matchAll(/shortcut:\s*'([^']+)'/g)].map((m) => m[1])
    expect(
      literals,
      'a chord typed into the palette is a copy of keymap.ts taken on one platform, ' +
        'and it is wrong on the other. Let `chordFor` render it.',
    ).toEqual([])
  })

  it('still prints a chord for every palette row the keymap binds', () => {
    // The literals are gone, so the check moves up a level: each row names a
    // command id, and a row whose id the keymap binds must be able to render
    // one. This is what stops the rows being renamed out of the keymap's reach
    // and quietly losing their shortcuts.
    const source = withoutComments(read(APP))
    const ids = [...source.matchAll(/\{\s*id:\s*'([a-z][\w.]*)',\s*title:/g)].map((m) => m[1])
    expect(ids.length, 'no palette rows found — has App.tsx changed shape?').toBeGreaterThan(15)

    const bound = new Set(KEYMAP.filter((b) => !b.passthrough).map((b) => b.id))
    const silent = ids.filter((id) => bound.has(id) && chordFor(id, true) === null)
    expect(silent, 'the keymap binds these, and the palette would print nothing').toEqual([])
  })
})

/* ================================================== 4b. platform-correct -- */

/**
 * No Apple-only glyph is typed into anything a person reads.
 *
 * Terminal Deck runs on Windows now. ⌘ is not a key a Windows keyboard has, so
 * a ⌘ in a label, a tooltip, an empty state or a hint is not a shortcut —
 * it is a character the reader cannot press, printed next to the command it
 * claims to run. This had happened in four places: seventeen literals in the
 * command palette, the first-run empty state, the screenshot hint in the image
 * picker, and the find bar's ⇧↩ / ↩.
 *
 * Two files are allowed to hold the glyphs, because they are the two that
 * choose between them: `keymap.ts` renders a chord per platform and
 * `platform.ts` answers "how does this reader take a screenshot". Everything
 * else asks one of them.
 *
 * Comments are stripped first. Explaining a chord in prose is not printing one.
 */
describe('nothing prints a key that only exists on a Mac', () => {
  const ALLOWED = new Set(['src/renderer/keymap.ts', 'src/renderer/platform.ts'])
  const GLYPHS = /[⌘⌥⌃⇧↩⌫⌦⇥⇞⇟↖↘]/

  // `SOURCES` is already every non-test source, spelled with forward slashes.
  const offenders: string[] = []
  for (const file of SOURCES.filter((f) => f.startsWith('src/renderer/'))) {
    if (ALLOWED.has(file)) continue
    withoutComments(read(file))
      .split('\n')
      .forEach((line, index) => {
        if (GLYPHS.test(line)) offenders.push(`${file}:${index + 1} ${line.trim()}`)
      })
  }

  it('has no hand-typed Mac glyph outside keymap.ts and platform.ts', () => {
    expect(
      offenders,
      'Ask `formatChord`/`chordFor` for the chord, or `screenshotShortcut` for the ' +
        'screenshot key. A glyph written here is wrong on Windows.',
    ).toEqual([])
  })
})

/* =============================================================== 5. views -- */

describe('every view the sidebar offers renders something', () => {
  const panelView = read('src/renderer/shell/PanelView.tsx')

  for (const panel of PANELS) {
    it(`${panel.id} has a case in PanelView`, () => {
      expect(
        panelView.includes(`case '${panel.id}':`),
        `The sidebar lists "${panel.label}" and PanelView has no case for it, so clicking the ` +
          'row shows an empty page.',
      ).toBe(true)
    })

    it(`${panel.id} names a keymap binding it can honour`, () => {
      // `command` is what the row's tooltip prints a chord from. Naming one the
      // keymap does not have puts a shortcut on screen that does nothing.
      if (!panel.command) return
      expect(
        KEYMAP.some((binding) => binding.id === panel.command),
        `${panel.id} claims the command ${panel.command}, which is not in the keymap.`,
      ).toBe(true)
    })
  }
})
