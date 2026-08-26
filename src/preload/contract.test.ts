import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Guards the renderer↔main contract.
 *
 * Three separate shipping bugs came from this seam, and none of them were type
 * errors, so neither tsc nor any component test saw them:
 *
 *  1. The preload exposed `browserViewClaim` while the component called
 *     `browserClaim`. The panel rendered its "not wired into this build"
 *     fallback and looked like an unimplemented feature.
 *  2. `browser:bounds` and `browser:visible` are registered with `ipcMain.on`,
 *     but the preload called them with `ipcRenderer.invoke`. invoke only routes
 *     to `handle`, so every call rejected — the browser view was created and
 *     loaded pages that were never positioned or shown.
 *  3. `DeckApi` kept declaring methods the preload had stopped exposing.
 *
 * These are string-matching problems across three files, which is exactly what
 * a test can check and a compiler cannot.
 */

const ROOT = join(__dirname, '..')

function read(path: string): string {
  return readFileSync(join(ROOT, path), 'utf8')
}

/**
 * Every main-process source, subdirectories included.
 *
 * The recursion is not tidiness. This used to read only the top level of
 * `src/main`, so a feature that grew into a folder — `src/main/remote/` is the
 * first — registered its handlers somewhere this test could not see. The
 * preload would call `remote:start`, the channel would be found nowhere, and
 * the failure would read "no handler at all" for a handler that was right
 * there. A guard whose blind spot is the thing being added is worse than no
 * guard, because it fails in the direction of blaming correct code.
 */
function mainSources(dir = 'main', acc: string[] = []): string {
  for (const entry of readdirSync(join(ROOT, dir), { withFileTypes: true })) {
    const rel = join(dir, entry.name)
    if (entry.isDirectory()) mainSources(rel, acc)
    else if (entry.name.endsWith('.ts') && !entry.name.includes('.test.')) acc.push(read(rel))
  }
  return acc.join('\n')
}

function rendererFiles(dir: string, acc: string[] = []): string[] {
  for (const entry of readdirSync(join(ROOT, dir), { withFileTypes: true })) {
    const rel = join(dir, entry.name)
    if (entry.isDirectory()) rendererFiles(rel, acc)
    else if (/\.tsx?$/.test(entry.name) && !entry.name.includes('.test.')) acc.push(rel)
  }
  return acc
}

const preload = read('preload/index.ts')
const main = mainSources()

/** Channels main answers with `handle` (for invoke) or `on` (for send). */
const handled = new Set([...main.matchAll(/ipcMain\.handle\(\s*'([^']+)'/g)].map((m) => m[1]))
const listened = new Set([...main.matchAll(/ipcMain\.on\(\s*'([^']+)'/g)].map((m) => m[1]))

/** Channels registered through a constant, resolved to their literal value. */
for (const [, name, value] of main.matchAll(/export const (\w+) = '([^']+)'/g)) {
  if (new RegExp(`ipcMain\\.handle\\(\\s*${name}\\b`).test(main)) handled.add(value)
  if (new RegExp(`ipcMain\\.on\\(\\s*${name}\\b`).test(main)) listened.add(value)
}

describe('preload → main transport', () => {
  it('every invoke() targets a channel registered with ipcMain.handle', () => {
    const wrong: string[] = []
    for (const [, channel] of preload.matchAll(/ipcRenderer\.invoke\(\s*'([^']+)'/g)) {
      if (!handled.has(channel)) {
        wrong.push(`${channel} (${listened.has(channel) ? 'registered with .on — use send()' : 'no handler at all'})`)
      }
    }
    expect(wrong).toEqual([])
  })

  it('registers each channel exactly once', () => {
    /*
     * `ipcMain.handle` throws on a second handler for a channel it already has,
     * and it throws at *registration* — so a collision is not a misbehaving
     * feature, it is a desktop that does not start.
     *
     * It is easy to walk into, because the names are grouped by subject rather
     * than by verb. `machines:rename` renames the **computer** in this app's own
     * list; a session on that computer got its own rename on 2026-08-27, and the
     * obvious channel for it was the one already taken. The only reason that was
     * caught before it shipped was somebody grepping the file by hand.
     *
     * The ellipsis is the placeholder two files use when they *describe* this
     * scan in a comment, and it is not a channel.
     */
    const counts = new Map<string, number>()
    for (const [, channel] of main.matchAll(/ipcMain\.handle\(\s*'([^']+)'/g)) {
      if (channel === '…') continue
      counts.set(channel, (counts.get(channel) ?? 0) + 1)
    }
    expect([...counts].filter(([, n]) => n > 1).map(([channel]) => channel)).toEqual([])
  })

  it('every send() targets a channel registered with ipcMain.on', () => {
    const wrong: string[] = []
    for (const [, channel] of preload.matchAll(/ipcRenderer\.send\(\s*'([^']+)'/g)) {
      if (!listened.has(channel)) {
        wrong.push(`${channel} (${handled.has(channel) ? 'registered with .handle — use invoke()' : 'no listener at all'})`)
      }
    }
    expect(wrong).toEqual([])
  })
})

/**
 * Arguments a preload method declares and then does not send.
 *
 * A fourth kind of failure at this seam, and the only one that type-checks
 * clean on both sides: the parameter is in the signature, so callers pass it
 * and TypeScript is satisfied, and the `invoke` below simply leaves it out. The
 * handler then runs its no-argument default and everything looks like it worked.
 *
 * Both entries here are that bug, shipped. `deleteProfile` dropped its options
 * and "delete this profile's files too" removed the profile and left the
 * directory. `createProfile` dropped its options and `profiles:create` fell
 * back to Claude for every account ever added on the Accounts screen, whichever
 * agent had been chosen — reported as "if I add any new account it just
 * redirects me to claude only".
 */
const FORWARDED: ReadonlyArray<{ method: string; channel: string; argument: string }> = [
  { method: 'createProfile', channel: 'profiles:create', argument: 'options' },
  { method: 'deleteProfile', channel: 'profiles:delete', argument: 'options' },
]

describe('preload arguments reach the channel', () => {
  for (const { method, channel, argument } of FORWARDED) {
    it(`${method} sends its ${argument} to ${channel}`, () => {
      // The method's own body, taken as everything up to its `invoke` — the
      // comments above these are long, so the window has to be generous.
      const call = new RegExp(
        `\\b${method}:[\\s\\S]{0,800}?ipcRenderer\\.invoke\\(\\s*'${channel}'([^)]*)\\)`,
      ).exec(preload)
      expect(call, `${method} does not invoke ${channel}`).not.toBeNull()
      expect(call?.[1]).toContain(argument)
    })
  }
})

describe('renderer → preload contract', () => {
  const exposed = new Set([...preload.matchAll(/^\s{2}([a-zA-Z][A-Za-z0-9_]*):\s*\(/gm)].map((m) => m[1]))

  it('every *Bridge interface a component declares is fully satisfied', () => {
    const missing: string[] = []
    for (const file of rendererFiles('renderer')) {
      const text = read(file)
      // \w*Bridge\w* — not just names ending in Bridge. SettingsBridgeMethods
      // declared three methods and was invisible to the earlier pattern.
      for (const match of text.matchAll(/(?:export )?interface (\w*Bridge\w*)\b[^{]*\{([\s\S]*?)\n\}/g)) {
        for (const [, method] of match[2].matchAll(/^\s{2}([a-zA-Z][A-Za-z0-9_]*)\s*[(<]/gm)) {
          if (!exposed.has(method)) missing.push(`${file} ${match[1]}.${method}`)
        }
      }
    }
    expect(missing).toEqual([])
  })

  it('DeckApi does not declare methods the preload no longer exposes', () => {
    const api = read('shared/types.ts')
    const block = api.slice(api.indexOf('interface DeckApi'))
    const declared = [...block.matchAll(/^\s{2}([a-zA-Z][A-Za-z0-9_]*)\s*\(/gm)].map((m) => m[1])
    expect(declared.filter((name) => !exposed.has(name))).toEqual([])
  })
})

/**
 * A fourth shape of the same seam bug: the channel matches, and an **argument**
 * does not travel.
 *
 * The three cases at the top of this file are all "the names do not line up".
 * This one lines up perfectly — same channel, same handler, no type error — and
 * still breaks, because the preload forwards fewer arguments than the handler
 * reads.
 *
 * MCP is where it happened. `~/.claude.json` holds servers at three scopes:
 * `user` at its root, and `project` and `local` keyed on the open folder. So
 * every MCP call has to carry that folder or main cannot find the row the panel
 * has just drawn. `mcp:list` carried it and listed all three; `mcp:connect`,
 * `mcp:inventory` and `mcp:call` did not, so main resolved them against the
 * user scope alone and threw `mcp: no configured server with id local:<name>`
 * — on a page whose expand gesture *is* its connect gesture. Asad: *"On MCP
 * servers did nothing."*
 *
 * Both ends were already right. `mcp-client.ts` has always accepted the
 * argument and `McpInspector`'s own bridge type has always declared it; this
 * file was the one link that dropped it.
 */
describe('the preload forwards what the handler reads', () => {
  const scoped = ['mcp:connect', 'mcp:inventory', 'mcp:call'] as const

  it.each(scoped)('%s carries the project path', (channel) => {
    // The invoke, up to its closing bracket, so this reads the actual call
    // rather than the surrounding function's signature.
    const call = new RegExp(`ipcRenderer\\.invoke\\('${channel}'[^)]*\\)`).exec(preload)?.[0] ?? ''
    expect(call, `${channel} is not invoked from the preload at all`).not.toBe('')
    expect(call, `${channel} drops projectPath, so project- and local-scope servers cannot resolve`)
      .toContain('projectPath')
  })

  it('reads that path in main for the same three channels', () => {
    // The other half: an argument that travels to a handler ignoring it is the
    // same defect wearing the opposite jacket.
    for (const channel of scoped) {
      const handler =
        new RegExp(`ipcMain\\.handle\\('${channel}'[\\s\\S]{0,400}?\\n  \\}?\\)`).exec(main)?.[0] ?? ''
      expect(handler, `${channel} has no handler`).not.toBe('')
      expect(handler, `${channel} ignores the project path the preload now sends`).toContain(
        'projectPath',
      )
    }
  })
})
