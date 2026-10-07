import Foundation

/// Exact JavaScript courtesy scripts run in the bundled external Stays Fixed process.
public enum BackendStaysFixedScripts {
    public static let preload = #"""
import fsp from 'node:fs/promises'
import { copyFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { basename, join } from 'node:path'
if (process.env.TD_SF_EXEC_PATH) process.execPath = process.env.TD_SF_EXEC_PATH
const keep = process.env.TD_SF_KEEP
if (keep) {
  const rm = fsp.rm
  fsp.rm = async function (target, ...rest) {
    try {
      const where = String(target)
      const evidence = join(where, 'evidence')
      if (basename(where).startsWith('staysfixed-check-') && existsSync(evidence)) {
        mkdirSync(keep, { recursive: true })
        for (const name of readdirSync(evidence)) if (name.endsWith('.png')) copyFileSync(join(evidence, name), join(keep, name))
      }
    } catch {}
    return rm.call(this, target, ...rest)
  }
}
"""#

    public static let check = #"""
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
const [pkg, root, paired] = process.argv.slice(1)
const at = (rel) => pathToFileURL(join(pkg, rel)).href
const out = (value) => process.stdout.write(JSON.stringify(value) + "\n")
const say = (event) => process.stderr.write("\u001eSF " + JSON.stringify(event) + "\n")
let engine
try {
  const log = await import(at('src/core/log.js'))
  log.setLogLevel({ quiet: true, verbose: false })
  const check = await import(at('src/v2/check.js'))
  const run = await import(at('src/v2/run.js'))
  if (typeof check.check !== 'function' || typeof run.makeCheckEvents !== 'function') throw new Error('moved')
  engine = { check: check.check, notChecked: check.whatWasNotChecked, events: run.makeCheckEvents }
} catch (e) {
  out({ unsupported: String(e && e.message || e) })
  process.exit(0)
}
try {
  process.chdir(root)
  const events = engine.events()
  events.on((e) => { if (e && e.type !== 'check:done') say({ type: String(e.type), message: String(e.message ?? ''), journey: e.journey ?? null, count: typeof e.count === 'number' ? e.count : null, at: typeof e.at === 'number' ? e.at : 0 }) })
  const verdict = await engine.check({ cwd: root, configFile: undefined, against: undefined, paired: paired === 'paired', journeys: undefined, surface: undefined, at: undefined, only: [], watch: { enabled: false }, events })
  const coverage = verdict.coverage ?? null
  const notChecked = typeof engine.notChecked === 'function' ? engine.notChecked(coverage) : null
  out({ ...verdict, notChecked, doorsNeverOpened: Math.max(0, (coverage?.doorsKnown ?? 0) - (coverage?.doorsWalked ?? 0)) })
} catch (e) {
  out({ error: { message: String(e && e.message || e), hint: e && typeof e.hint === "string" ? e.hint : null } })
  process.exitCode = 2
}
"""#

    public static let describe = #"""
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
const [pkg, root] = process.argv.slice(1)
const at = (rel) => pathToFileURL(join(pkg, rel)).href
const result = { product: null, guards: [], guardProblem: null, reference: null }
try {
  const log = await import(at('src/core/log.js'))
  log.setLogLevel({ quiet: true, verbose: false })
} catch {}
try {
  const { loadGuards } = await import(at('src/guard/load.js'))
  const guards = await loadGuards({ paths: { guards: join(root, '.staysfixed', 'guards') } })
  result.guards = guards.map((g) => ({ name: String(g.name ?? ''), because: typeof g.because === 'string' ? g.because : '', file: String(g.file ?? '') }))
} catch (e) {
  result.guardProblem = [String(e && e.message || e), e && typeof e.hint === 'string' ? e.hint : ''].filter(Boolean).join(' ')
}
try {
  const store = await import(at('src/v2/store.js'))
  const reference = await import(at('src/v2/reference.js'))
  const named = await store.productNameFor(root)
  result.product = named.name
  const current = await reference.currentReference(store.openStore({ root }), named.name)
  if (current && current.pointer) {
    let build = null
    try { const record = JSON.parse(readFileSync(join(root, '.staysfixed', 'v2', 'builds', current.pointer.buildId, 'build.json'), 'utf8')); build = record && record.fingerprint ? record.fingerprint : record } catch {}
    result.reference = { buildId: String(current.pointer.buildId), setAt: String(current.pointer.setAt ?? ''), setBy: String(current.pointer.setBy ?? ''), version: build && typeof build.version === 'string' ? build.version : null, gitSha: build && typeof build.gitSha === 'string' ? build.gitSha : null, forced: Boolean(current.cut && current.cut.forced) }
  }
} catch {}
process.stdout.write(JSON.stringify(result) + "\n")
"""#

    public static var preloadURL: String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return "data:text/javascript," + (preload.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
    }
}
