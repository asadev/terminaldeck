import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The seam, asserted mechanically, because a seam nobody checks is a seam that
 * closes again.
 *
 * The headless build is not a fork. It is the same core with a different shell,
 * and the single thing that makes that true is that nothing the core imports
 * reaches for Electron at runtime. One `import { app } from 'electron'` added to
 * `store.ts` in six months would put the whole core back inside a process that
 * has Chromium in it — and it would do so silently, because `require('electron')`
 * under plain Node does not throw. It resolves to the npm package's shim, which
 * exports the *path to the Electron binary* as a string, so `app` would be
 * `undefined` and the first failure would be `app.getPath is not a function`
 * somewhere deep in a daemon on somebody's server.
 *
 * So this walks the real import graph from the two headless entry points and
 * refuses any runtime Electron import. Type-only imports are fine and are the
 * ordinary case — `type IpcMain` is erased before a byte is emitted.
 */

const ROOT = resolve(__dirname, '..', '..')

/**
 * Read a source file for inspection, with line endings normalised.
 *
 * Every assertion in this file searches the source text, and several search for
 * a string ending in a newline — which is how they pin that a call is on its own
 * line rather than mentioned in a comment. Git checks this repository out with
 * CRLF on Windows, so those searches find nothing and `indexOf` answers -1,
 * which reads as "the call is not there at all" and fails an ordering assertion
 * with a number nobody would connect to line endings. It cost two CI rounds:
 * the first because the cause was not obvious, the second because the fix was
 * applied to one of six reads and the failing one was a different read.
 *
 * So there is one door now, and it cannot be half-fixed.
 */
function readSource(relative: string): string {
  return readFileSync(join(ROOT, relative), 'utf8').replace(/\r\n/g, '\n')
}

const ENTRIES = ['src/headless/main.ts', 'src/headless/daemon.ts']

function resolveSpec(spec: string, from: string): string | null {
  let base: string
  if (spec.startsWith('@shared/')) base = join(ROOT, 'src/shared', spec.slice('@shared/'.length))
  else if (spec.startsWith('.')) base = resolve(dirname(from), spec)
  else return null
  for (const candidate of [`${base}.ts`, `${base}.tsx`, join(base, 'index.ts'), join(base, 'index.tsx')]) {
    if (existsSync(candidate)) return candidate
  }
  return null
}

/** Every source file the headless entries can reach, repo-relative, `/`-separated. */
function closure(): string[] {
  const seen = new Set<string>()
  const stack = ENTRIES.map((entry) => join(ROOT, entry))
  while (stack.length > 0) {
    const file = stack.pop() as string
    if (seen.has(file)) continue
    seen.add(file)
    const source = readFileSync(file, 'utf8')
    for (const match of source.matchAll(/(?:from\s*|import\s*\(\s*)['"]([^'"]+)['"]/g)) {
      const resolved = resolveSpec(match[1], file)
      if (resolved !== null) stack.push(resolved)
    }
  }
  return [...seen].map((file) => relative(ROOT, file).split(sep).join('/')).sort()
}

/**
 * Source with its comments removed.
 *
 * Not cosmetic. `platform/paths.ts` explains itself by quoting the very line
 * this test looks for — "`import { app } from 'electron'` in any of those files
 * is what stops the core running under plain Node" — and a scanner that cannot
 * tell prose from code reported the module that *fixed* the problem as the one
 * causing it. `reachable.test.ts` learnt the same lesson and strips the same way.
 */
const withoutComments = (source: string): string =>
  source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')

/**
 * A single import clause: a brace list, a default binding, or a namespace.
 *
 * Deliberately not `[\s\S]*?`. A lazy match starting at the first `import` in a
 * file happily swallows every import above the Electron one and reports the lot
 * as the offending clause — which it did, making a type-only import look like a
 * runtime one in four files at once.
 */
const IMPORT_CLAUSE = String.raw`(?:type\s+)?(?:\{[^{}]*\}|\*\s+as\s+[A-Za-z_$][\w$]*|[A-Za-z_$][\w$]*(?:\s*,\s*\{[^{}]*\})?)`

/**
 * Import statements naming `electron`, with the type-only ones dropped.
 *
 * Written against the statement rather than the file so that a mixed import —
 * `import { app, type IpcMain } from 'electron'` — is caught, which is the exact
 * form three of these files used before the split.
 */
function runtimeElectronImports(raw: string): string[] {
  const source = withoutComments(raw)
  const found: string[] = []
  const pattern = new RegExp(String.raw`import\s+(${IMPORT_CLAUSE})\s+from\s+['"]electron['"]`, 'g')
  for (const match of source.matchAll(pattern)) {
    const clause = match[1].trim()
    if (clause.startsWith('type ')) continue
    // A brace list whose every member is `type X` is type-only in effect, even
    // though the statement does not say so.
    const braces = /^\{([\s\S]*)\}$/.exec(clause)
    if (braces) {
      const members = braces[1]
        .split(',')
        .map((member) => member.trim())
        .filter((member) => member !== '')
      if (members.length > 0 && members.every((member) => member.startsWith('type '))) continue
    }
    found.push(clause.replace(/\s+/g, ' '))
  }
  // `require('electron')` would slip past the above, and a bundler would happily
  // keep it.
  for (const match of source.matchAll(/require\(\s*['"]electron['"]\s*\)/g)) found.push(match[0])
  return found
}

describe('the detector itself', () => {
  /*
   * A scanner that finds nothing is indistinguishable from a clean codebase
   * until the day it matters, and this one has already been wrong in both
   * directions — it reported four innocent files and it read a comment as code.
   * So it is exercised on literals before it is trusted on the tree.
   */
  it('catches every shape of runtime import', () => {
    expect(runtimeElectronImports("import { app } from 'electron'")).toHaveLength(1)
    expect(runtimeElectronImports("import { app, type IpcMain } from 'electron'")).toHaveLength(1)
    expect(runtimeElectronImports("import electron from 'electron'")).toHaveLength(1)
    expect(runtimeElectronImports("import * as electron from 'electron'")).toHaveLength(1)
    expect(runtimeElectronImports("const { app } = require('electron')")).toHaveLength(1)
  })

  it('lets a type-only import through, in both spellings', () => {
    expect(runtimeElectronImports("import type { IpcMain } from 'electron'")).toEqual([])
    expect(runtimeElectronImports("import { type IpcMain, type WebContents } from 'electron'")).toEqual([])
  })

  it('is not fooled by the import above it', () => {
    const source = "import { join } from 'node:path'\nimport type { IpcMain } from 'electron'\n"
    expect(runtimeElectronImports(source)).toEqual([])
  })

  it('reads a comment as prose', () => {
    expect(runtimeElectronImports("/* import { app } from 'electron' is the bug */")).toEqual([])
    expect(runtimeElectronImports("// import { app } from 'electron'")).toEqual([])
  })
})

describe('the headless build never reaches Electron', () => {
  const files = closure()

  it('walks a real graph rather than an empty one', () => {
    // A resolver that quietly matched nothing would make every assertion below
    // pass while checking no code at all.
    expect(files.length).toBeGreaterThan(30)
    expect(files).toContain('src/main/host-core.ts')
    expect(files).toContain('src/main/remote/server.ts')
    expect(files).toContain('src/main/pty-manager.ts')
    expect(files).toContain('src/shared/sealed.ts')
  })

  it('imports nothing from electron at runtime', () => {
    const offenders: string[] = []
    for (const file of files) {
      for (const clause of runtimeElectronImports(readSource(file))) {
        offenders.push(`${file}: ${clause}`)
      }
    }
    expect(
      offenders,
      'These are reachable from the headless entry points and pull in Electron, which is not ' +
        'there. Move the Electron half behind the seam — platform/paths.ts for a directory, ' +
        'ipc-seam.ts for a registration — or keep the module out of the core.',
    ).toEqual([])
  })

  it('keeps the crypto on the one implementation both runtimes share', () => {
    // `sealed.ts` deliberately has no "native when available" path: Electron's
    // BoringSSL ships no ChaCha, and a fallback would mean the tests exercise
    // one implementation while users run the other. Plain Node runs the
    // identical code, and that is what makes the headless build's channel the
    // same channel.
    const sealed = readSource('src/shared/sealed.ts')
    expect(sealed).toContain('@noble/ciphers')
    expect(sealed).not.toContain("require('node:crypto')")
    expect(files).toContain('src/shared/sealed.ts')
  })
})

describe('both shells say where the files are, at boot', () => {
  /*
   * `platform/paths.ts` has no default and throws when nothing installed one —
   * see its header for why a default would be worse. That makes the install a
   * line each shell must not lose, and losing it is invisible until the first
   * thing that reads a directory. So it is asserted from the source of the entry
   * points, the same way `reachable.test.ts` asserts everything else it cannot
   * mount.
   */
  it('the Electron main process installs the Electron paths', () => {
    // `.replace(/\r\n/g, '\n')` because git checks this repository out with CRLF
    // on Windows, so every search below for a string ending in `\n` misses and
    // `indexOf` answers -1 — which reads as "the call is not there at all".
    // That is exactly how this assertion failed on the Windows CI runner.
    const source = readSource('src/main/index.ts')
    expect(source).toContain('installPaths(electronPaths(app))')
  })

  it('installs, pins, and only then builds the machine', () => {
    /*
     * Three lines whose order is the whole of it.
     *
     * `pinUserData` moves the directory, and `electronPaths` forwards on every
     * call rather than capturing, so installing first is what makes the pin
     * apply to everything downstream. And `createHostCore` is constructed at
     * module scope with a `FolderGrants` that reads its file in its constructor
     * — so a pin that happened after it would load the grants from the unpinned
     * directory, which is `user-data.ts`'s "renaming the app silently moved
     * everyone's data" failure arriving through a different door.
     */
    const source = readSource('src/main/index.ts')
    const install = source.indexOf('installPaths(electronPaths(app))')
    const pin = source.indexOf('pinUserData(app)\n')
    const build = source.indexOf('const core = createHostCore(')
    expect(install).toBeGreaterThan(-1)
    expect(pin).toBeGreaterThan(install)
    expect(build).toBeGreaterThan(pin)
  })

  it('the daemon installs the plain-Node paths as its first instruction', () => {
    const source = readSource('src/headless/daemon.ts')
    expect(source).toContain('installPaths(nodePaths(')
  })

  it('the CLI installs them too, because it has to find the state directory', () => {
    const source = readSource('src/headless/main.ts')
    expect(source).toContain('installPaths(nodePaths(')
  })
})

describe('the demo host actually approves the visitor it decided to approve', () => {
  /*
   * The seam that was open, and it was open all the way to a live server.
   *
   * `public-host.ts` is a decision object: it is handed `approve` and `grant`
   * and it calls them when a device redeems a code. Its own tests pass, and one
   * of them drives a real `RemoteAuth`, a real `PairingDesk` and the real
   * `authenticatorFor` — but it builds that wiring itself, with
   * `authenticatorFor(auth, desk, (device) => policy.paired(device))`. So the
   * only caller of `PublicHost.paired` in the whole repository was the test
   * file, and nobody noticed, because everything that could be tested about the
   * policy was green.
   *
   * What that cost, measured on 2026-08-16 against the live demo box: a fresh
   * simulator running the 0.1.8 TestFlight build followed App Review
   * Information word for word, redeemed a real code from the real page, and
   * then sat on "Waiting for approval — approve it in the desktop app, then
   * reconnect" forever. The container's log said `a device redeemed a pairing
   * code` and never said `a visitor paired and was let in`; `status` on the box
   * said `Devices (1) — pending, never seen`. The reviewer's dead end, which is
   * the entire thing the demo exists to remove, had simply moved one screen
   * later.
   *
   * A source assertion rather than a live one, and the limit is worth stating:
   * this proves the call is written, not that it fires. Proving that it fires
   * needs a device on the far end of a Noise handshake, which is
   * `ios/Harness/live-transfer.sh`'s job and not a unit test's. Written is the
   * property that was missing, and it is the one that can be lost again by an
   * ordinary edit.
   */
  it('wires the policy to the event that a device redeemed a code', () => {
    const source = readSource('src/headless/host.ts')
    expect(source).toContain('publicHost?.paired(device)')
  })

  it('approves before it wakes whoever is waiting to hear about the pairing', () => {
    /*
     * `terminaldeck pair` waits on this event and prints that the device is in.
     * Telling a person so before the trust store has been written is a race
     * that reads as a lie on the day it loses.
     */
    const source = readSource('src/headless/host.ts')
    const approve = source.indexOf('publicHost?.paired(device)')
    const wake = source.indexOf('for (const wake of [...waiting])')
    expect(approve).toBeGreaterThan(-1)
    expect(wake).toBeGreaterThan(approve)
  })
})

describe('the headless build can drive a browser without Electron', () => {
  /*
   * Wave-2 gives the headless server a real browser of its own and drives it
   * over CDP. The first step (this lane) extracted a `DrivenPage` seam so the
   * engine — the driver and the PNG masking it finishes a screenshot with — no
   * longer reaches for Electron. The Electron half moved to
   * `browser-driven-electron.ts`, which is reached only from
   * `browser-drive-ipc.ts` and never from a headless entry.
   *
   * These two files become reachable from the server once the host wiring lands
   * (a later lane adds them to the closure contains-list above). They must be
   * clean before they can be, so this asserts the property directly on the
   * source — the same detector the closure walk uses, pointed at the files by
   * name rather than reached through the graph.
   */
  it('keeps the driver and its PNG masking free of runtime Electron imports', () => {
    for (const file of ['src/main/browser-driver.ts', 'src/main/browser-png.ts']) {
      expect(runtimeElectronImports(readSource(file)), file).toEqual([])
    }
  })
})
