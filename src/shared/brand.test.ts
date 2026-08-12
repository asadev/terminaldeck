import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { BRAND } from './brand'

/**
 * brand.ts is the only place the product name lives, but four files cannot
 * import TypeScript and have to spell it out. Those four drifted twice during
 * the rename to Terminal Deck — once because a substitution over identifiers
 * also rewrote display strings, leaving the app titled "Deck" while every
 * other file said "Terminal Deck", and the build was green both times because
 * nothing compares them.
 *
 * This is that comparison. It is cheap and it fails loudly, which is the whole
 * point: a name is the one thing a user checks first and a compiler never
 * checks at all.
 */

const ROOT = join(__dirname, '..', '..')
const read = (p: string): string => readFileSync(join(ROOT, p), 'utf8')

describe('the product name agrees everywhere it is spelled out', () => {
  it('package.json matches BRAND', () => {
    const pkg = JSON.parse(read('package.json')) as { name: string; productName: string }
    expect(pkg.productName).toBe(BRAND.name)
    expect(pkg.name).toBe(BRAND.id)
  })

  it('electron-builder.yml matches BRAND', () => {
    const yml = read('electron-builder.yml')
    expect(yml).toMatch(new RegExp(`^productName:\\s*${BRAND.name}\\s*$`, 'm'))
    expect(yml).toMatch(new RegExp(`^appId:\\s*${BRAND.bundleId}\\s*$`, 'm'))
  })

  it('the pre-React title matches BRAND', () => {
    // Shown in the window before the renderer mounts, so a stale value here is
    // visible on every cold start.
    expect(read('src/renderer/index.html')).toContain(`<title>${BRAND.name}</title>`)
  })

  it('the name is not a prefix of itself, which is how the mangling started', () => {
    // `Terminal Deck` -> `Deck` and `Deck` -> `Terminal Deck` are both one bad
    // regex away. Asserting the full string catches either direction.
    expect(BRAND.name).toBe('Terminal Deck')
    expect(BRAND.id).toBe('terminaldeck')
  })
})
