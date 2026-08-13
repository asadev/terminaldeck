import { describe, expect, it } from 'vitest'
import { TAILSCALE_BIN, tailscaleCandidates } from './tailscale'

describe('where the tailscale CLI is on macOS', () => {
  const paths = tailscaleCandidates('darwin', {})

  it('is the list that was verified on a real machine, unchanged', () => {
    expect(paths).toEqual([
      '/opt/homebrew/bin/tailscale',
      '/usr/local/bin/tailscale',
      '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
      '/usr/bin/tailscale',
    ])
  })

  it('ignores the Windows environment entirely', () => {
    expect(tailscaleCandidates('darwin', { ProgramFiles: 'C:\\Program Files' })).toEqual(paths)
  })
})

describe('where the tailscale CLI is on Windows', () => {
  it('uses the documented default under Program Files', () => {
    // Tailscale's MSI reference: "The installation path defaults to
    // C:\\Program Files\\Tailscale." Quoted rather than guessed, and reached
    // through the environment so it is still right on a machine whose Windows
    // is not on C:.
    expect(tailscaleCandidates('win32', { ProgramFiles: 'C:\\Program Files' })).toEqual([
      'C:\\Program Files\\Tailscale\\tailscale.exe',
    ])
  })

  it('follows Program Files to whatever drive Windows is actually on', () => {
    expect(tailscaleCandidates('win32', { ProgramFiles: 'D:\\Programs' })).toEqual([
      'D:\\Programs\\Tailscale\\tailscale.exe',
    ])
  })

  it('also looks in the 64-bit and x86 trees, without repeating itself', () => {
    // A 32-bit process sees %ProgramFiles% pointing at the (x86) tree while
    // %ProgramW6432% points at the real one, and an x86 Tailscale on 64-bit
    // Windows installs into (x86) regardless. All three keys, one entry each.
    expect(
      tailscaleCandidates('win32', {
        ProgramFiles: 'C:\\Program Files (x86)',
        ProgramW6432: 'C:\\Program Files',
        'ProgramFiles(x86)': 'C:\\Program Files (x86)',
      }),
    ).toEqual([
      'C:\\Program Files (x86)\\Tailscale\\tailscale.exe',
      'C:\\Program Files\\Tailscale\\tailscale.exe',
    ])
  })

  it('builds Windows separators even when it is a Mac doing the building', () => {
    // `path.join` on this machine would produce `C:\Program Files/Tailscale/…`,
    // which is not a path Windows opens and not one anyone would spot in review.
    for (const path of tailscaleCandidates('win32', { ProgramFiles: 'C:\\Program Files' })) {
      expect(path).not.toContain('/')
    }
  })

  it('falls back to a hardcoded root only when the environment says nothing', () => {
    expect(tailscaleCandidates('win32', {})).toEqual(['C:\\Program Files\\Tailscale\\tailscale.exe'])
    expect(tailscaleCandidates('win32', { ProgramFiles: '   ' })).toEqual([
      'C:\\Program Files\\Tailscale\\tailscale.exe',
    ])
  })

  it('is never the only mechanism', () => {
    // INSTALLDIR is a settable MSI property, so an administrator's install is
    // somewhere this list cannot name — which is why `findTailscale` runs the
    // PATH lookup first and treats this as the fallback.
    expect(tailscaleCandidates('win32', { ProgramFiles: 'C:\\Program Files' })).toHaveLength(1)
  })
})

describe('the name looked up on PATH', () => {
  it('carries no extension, because both lookups add their own', () => {
    // `where.exe` resolves PATHEXT itself; `which` would find nothing called
    // `tailscale.exe` on a Mac.
    expect(TAILSCALE_BIN).toBe('tailscale')
  })
})
