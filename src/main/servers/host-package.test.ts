import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { HOST_INSTALLER, HOST_TARBALL, NO_PACKAGE, findHostPackage } from './host-package'

/**
 * Where the headless host this app installs actually comes from.
 *
 * The only interesting property here is the **absence**: a build that carries no
 * package must answer null rather than pointing at half of one, because the
 * caller's whole job with a null is to draw no button and say why. A partial
 * answer would produce an install that copied an installer, reached for a
 * tarball that is not there, and failed on somebody else's machine — which is
 * the expensive place to fail.
 */

function tree(...present: string[]): (path: string) => boolean {
  const set = new Set(present)
  return (path) => set.has(path)
}

describe('finding the package this build carries', () => {
  it('finds both files under a packaged app’s resources', () => {
    // These name files on *this* machine — the app's own resources — so they are
    // spelled with the host separator, `join`, exactly as `findHostPackage` does.
    const dir = join('/App/Contents/Resources', 'headless')
    const found = findHostPackage('0.9.1', {
      resources: '/App/Contents/Resources',
      tree: null,
      exists: tree(join(dir, HOST_TARBALL), join(dir, HOST_INSTALLER)),
    })
    expect(found?.tarball).toBe(join(dir, HOST_TARBALL))
    expect(found?.version).toBe('0.9.1')
  })

  it('finds them under out/ when running from a checkout', () => {
    const dir = join('/repo', 'out', 'headless-package')
    const found = findHostPackage('0.9.1', {
      resources: null,
      tree: '/repo',
      exists: tree(join(dir, HOST_TARBALL), join(dir, HOST_INSTALLER)),
    })
    expect(found?.installer).toBe(join(dir, HOST_INSTALLER))
  })

  /*
   * Both files or neither. This is the case that matters: `npm run
   * build:headless` writes the bundle without packing it, so an installer
   * copied in by hand beside no tarball is a real shape a tree can be in.
   */
  it('answers null when only one of the two is there', () => {
    const half = findHostPackage('0.9.1', {
      resources: null,
      tree: '/repo',
      exists: tree(`/repo/out/headless-package/${HOST_INSTALLER}`),
    })
    expect(half).toBeNull()
  })

  it('answers null when there is nothing at all, rather than guessing at npm', () => {
    expect(findHostPackage('0.9.1', { resources: null, tree: null, exists: () => true })).toBeNull()
    expect(NO_PACKAGE).toContain('npm run dist:headless')
  })
})
