import { accessSync, constants, existsSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Where the device engine's programs are, and whether this Mac can run them.
 *
 * ## What ships
 *
 * `@toolingtools/simview` (Apache-2.0, recorded in `THIRD-PARTY-LICENSES.md`)
 * is a dependency, and its `bin/` folder is what this app runs:
 *
 *  - `simview-core` — the native engine. Captures the screen, injects input,
 *    reads the accessibility tree. Spoken to over a socket by `core-client.ts`.
 *  - `simview` — the engine's own command line. Used for one thing only: the
 *    React Native component tree, which its TypeScript layer reads out of a
 *    running Metro server and the native core cannot. See `session.ts`.
 *  - `simview-android-agent.jar` — pushed to an Android device for the length
 *    of a session and removed afterwards by the engine.
 *  - `xctest-provider/` — a test runner the engine starts inside an iOS
 *    Simulator for a fuller tree of third-party apps. Its files are checked
 *    against a manifest of hashes, which is why the packaged app must not
 *    re-sign them (see `WIRING-annotate.md`).
 *  - `libSimViewProbe.dylib` — the engine's optional UIKit probe.
 *
 * ## Dev and packaged
 *
 * In development it is plain `node_modules`. In a packaged app electron-builder
 * puts `node_modules` inside `app.asar`, and an executable inside an archive is
 * not something `spawn` can start — so the package is unpacked
 * (`asarUnpack`) and read from `app.asar.unpacked`. Both are tried, packaged
 * first, the same shape `native-speech.ts` uses for its helper.
 *
 * ## Who can use it
 *
 * Apple silicon Macs only: every program in that folder is arm64, and the
 * engine refuses anything else. This app's Mac build is arm64-only too, so the
 * check below is about a stranger running it some other way, and it answers in
 * a sentence the page can show rather than a spawn error.
 */

export interface Engine {
  ok: true
  bin: string
  core: string
  cli: string
  /** Extra environment for the engine, naming its own files explicitly. */
  env: Record<string, string>
}

export interface NoEngine {
  ok: false
  /** One plain sentence for the page. */
  reason: string
}

const PACKAGE = ['node_modules', '@toolingtools', 'simview', 'bin']

function executable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

/** Every folder the engine might be in, best first. */
export function engineCandidates(resourcesPath: string | null, appPath: string, cwd: string): string[] {
  const out: string[] = []
  const override = process.env.TD_DEVICE_ENGINE_BIN
  if (override) out.push(override)
  if (resourcesPath) out.push(join(resourcesPath, 'app.asar.unpacked', ...PACKAGE))
  out.push(join(appPath.replace(/app\.asar$/, 'app.asar.unpacked'), ...PACKAGE))
  out.push(join(appPath, ...PACKAGE))
  out.push(join(cwd, ...PACKAGE))
  return [...new Set(out)]
}

export function locateEngine(
  options: { resourcesPath: string | null; appPath: string; cwd?: string; platform?: string; arch?: string },
): Engine | NoEngine {
  const platform = options.platform ?? process.platform
  const arch = options.arch ?? process.arch
  if (platform !== 'darwin') {
    return { ok: false, reason: 'Simulators open on a Mac. This computer is not one.' }
  }
  if (arch !== 'arm64') {
    return { ok: false, reason: 'Simulators need a Mac with Apple silicon.' }
  }
  for (const bin of engineCandidates(options.resourcesPath, options.appPath, options.cwd ?? process.cwd())) {
    const core = join(bin, 'simview-core')
    if (!existsSync(core) || !executable(core)) continue
    const env: Record<string, string> = {}
    const agent = join(bin, 'simview-android-agent.jar')
    if (existsSync(agent)) env.SIMVIEW_ANDROID_AGENT_PATH = agent
    const probe = join(bin, 'libSimViewProbe.dylib')
    if (existsSync(probe)) env.SIMVIEW_PROBE_DYLIB = probe
    const xctestrun = join(bin, 'xctest-provider', 'SimViewXCTestProvider.xctestrun')
    if (existsSync(xctestrun)) env.SIMVIEW_XCTEST_PROVIDER_XCTESTRUN = xctestrun
    return { ok: true, bin, core, cli: join(bin, 'simview'), env }
  }
  return {
    ok: false,
    reason: 'This copy of the app is missing its simulator engine. Reinstall the app to get it back.',
  }
}
