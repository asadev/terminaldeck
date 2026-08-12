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

function mainSources(): string {
  return readdirSync(join(ROOT, 'main'))
    .filter((f) => f.endsWith('.ts') && !f.includes('.test.'))
    .map((f) => read(join('main', f)))
    .join('\n')
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
