import { describe, expect, it } from 'vitest'
import { firstLookupPath, loginPathSpec, lookupSpec } from './lookup'

describe('asking where a binary is', () => {
  it('uses where.exe on Windows and which everywhere else', () => {
    // `which` is not a program on Windows, so the macOS spelling there is not a
    // degraded lookup — it is an ENOENT that reports every CLI as missing.
    expect(lookupSpec('win32', 'claude')).toEqual({ command: 'where.exe', args: ['claude'] })
    expect(lookupSpec('darwin', 'claude')).toEqual({ command: 'which', args: ['claude'] })
    expect(lookupSpec('linux', 'claude')).toEqual({ command: 'which', args: ['claude'] })
  })

  it('passes the name as an argument, never inside the command', () => {
    // These go through execFile with no shell, and the guarantee only holds
    // while the name stays in the argument list.
    expect(lookupSpec('win32', 'a b; rm -rf /').command).toBe('where.exe')
    expect(lookupSpec('win32', 'a b; rm -rf /').args).toEqual(['a b; rm -rf /'])
  })
})

describe('reading what a lookup printed', () => {
  it('takes the single line which prints', () => {
    expect(firstLookupPath('/opt/homebrew/bin/tailscale\n')).toBe('/opt/homebrew/bin/tailscale')
  })

  it('takes the first of the several lines where.exe prints, CRLF and all', () => {
    const stdout = 'C:\\Program Files\\Tailscale\\tailscale.exe\r\nC:\\tools\\tailscale.exe\r\n'
    expect(firstLookupPath(stdout)).toBe('C:\\Program Files\\Tailscale\\tailscale.exe')
  })

  it('answers null for nothing at all', () => {
    expect(firstLookupPath('')).toBeNull()
    expect(firstLookupPath('\r\n  \n')).toBeNull()
  })

  it('does not mistake a diagnostic for a path', () => {
    // where.exe writes this to stderr with a non-zero exit, so a caller should
    // never get here with it — but handing it to accessSync or a spawn is a
    // silent nonsense rather than a failure, so it is refused by name.
    expect(firstLookupPath('INFO: Could not find files for the given pattern(s).')).toBeNull()
  })
})

describe('asking for the user’s real PATH', () => {
  it('spawns the login shell on macOS', () => {
    expect(loginPathSpec('darwin', { SHELL: '/bin/zsh' })).toEqual({
      command: '/bin/zsh',
      args: ['-lic', 'echo -n "$PATH"'],
    })
  })

  it('falls back to zsh when the environment names no shell', () => {
    expect(loginPathSpec('darwin', {})?.command).toBe('/bin/zsh')
  })

  it('spawns nothing at all on Windows', () => {
    // Not "runs a different shell": there is no login shell to ask, and the
    // process environment is already the answer. `null` is how this file says
    // that, and it is what stops `zsh -lic` being spawned into a void.
    expect(loginPathSpec('win32', { COMSPEC: 'C:\\Windows\\system32\\cmd.exe' })).toBeNull()
    // Even when a Unix-ish SHELL is set, which happens under Git Bash.
    expect(loginPathSpec('win32', { SHELL: 'C:\\Program Files\\Git\\bin\\bash.exe' })).toBeNull()
  })
})
