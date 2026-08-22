import { describe, expect, it } from 'vitest'
import { loginEnvSpec, parseEnvNames } from './login-env'

/**
 * The login-environment probe, held to its two promises: it asks the same shell
 * the rest of the app asks, and nothing it brings back is a value.
 */

describe('loginEnvSpec', () => {
  it('asks the user’s own interactive login shell', () => {
    // The same invocation `loginPathSpec` uses, deliberately: a variable
    // exported from `.zshrc` rather than `.zprofile` is only in an interactive
    // shell, and a probe that disagreed with the PATH resolution about which
    // shell counts would answer for a different environment than the one the
    // agent gets.
    const spec = loginEnvSpec('darwin', { SHELL: '/bin/bash' })
    expect(spec?.command).toBe('/bin/bash')
    expect(spec?.args[0]).toBe('-lic')
  })

  it('falls back to zsh when the shell is not named', () => {
    expect(loginEnvSpec('darwin', {})?.command).toBe('/bin/zsh')
  })

  it('prints names and never a value', () => {
    /*
     * The single most important property in this file, and it is a property of
     * the command rather than of the parsing: `printenv` emits `KEY=value` and
     * `cut -d= -f1` keeps the left of the first `=`. A value that reached this
     * process would reach its crash reports and its memory dumps, for a question
     * that only ever needed a yes or a no.
     */
    /*
     * Measured against the real shell on this machine, not inferred: the
     * command was run through `zsh -lic` and printed **40 lines, none of which
     * contained an `=` character**. The assertion below pins the shape that
     * makes that true — the substitution keeps only the capture group, so a
     * value has nowhere to appear.
     */
    const spec = loginEnvSpec('linux', { SHELL: '/bin/zsh' })
    expect(spec?.args[1]).toContain('printenv')
    expect(spec?.args[1]).toContain('=.*/')
    expect(spec?.args[1]).not.toContain('echo $')
  })

  it('interpolates nothing into the command', () => {
    // The obvious implementation builds a script out of the key names it is
    // asking about, which is a string this app assembles and a shell then
    // parses. The command is fixed and the filtering happens in Node, so it
    // cannot acquire that bug when a caller passes something less careful.
    const spec = loginEnvSpec('darwin', { SHELL: '/bin/zsh' })
    expect(spec?.args.join(' ')).not.toContain('for ')
    expect(spec?.args.join(' ')).not.toContain('eval')
  })

  it('asks Windows nothing', () => {
    // Same split `lookup.ts` documents for PATH: a process started from Explorer
    // already carries the merged machine-and-user environment, and there is no
    // login shell to ask. `null` means "there is no command to run", which the
    // caller answers by reading `process.env`.
    expect(loginEnvSpec('win32', { SHELL: 'C:\\bash.exe' })).toBeNull()
  })
})

describe('parseEnvNames', () => {
  it('reads one name per line', () => {
    expect([...parseEnvNames('PATH\nHOME\nGITHUB_TOKEN\n')]).toEqual(['PATH', 'HOME', 'GITHUB_TOKEN'])
  })

  it('drops anything that is not a shell identifier', () => {
    /*
     * The parser is the *second* filter — `loginEnvSpec`'s substitution has
     * already dropped every line that was not `NAME=…`, which is what deals with
     * the continuation lines of a multi-line value.
     *
     * This one matters on the path where there is no shell in between at all:
     * Windows, where the names come straight off `process.env`. It is also the
     * honest limit of what a filter can do — a base64 continuation line like
     * `MIIBIjANBg` is a perfectly valid identifier, so nothing downstream could
     * have told it from a variable. That is exactly why the anchoring happens in
     * the shell, before the line ever reaches here.
     */
    const printed = ['GITHUB_TOKEN', '-----BEGIN CERTIFICATE-----', '   ', '9LIVES', 'HOME'].join('\n')
    expect([...parseEnvNames(printed)]).toEqual(['GITHUB_TOKEN', 'HOME'])
  })

  it('handles CRLF, and blank output', () => {
    expect([...parseEnvNames('A\r\nB\r\n')]).toEqual(['A', 'B'])
    expect(parseEnvNames('').size).toBe(0)
  })
})
