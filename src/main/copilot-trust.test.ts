/**
 * The trust record that keeps a phone's first copilot run from stranding.
 *
 * The shape asserted here is not invented: it is what `claude 2.1.237` writes
 * into `<configDir>/.claude.json` after somebody answers *Yes, I trust this
 * folder*, read back off a real run on 2026-08-20 — and what it reads on the
 * next start, checked by spawning the CLI in a pty with the record already in
 * place and finding no modal on the screen.
 */

import { mkdtempSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { claudeConfigFile, claudeTrustFile, trustCopilotFolder } from './copilot-trust'

function scratch(): { configDir: string; folder: string } {
  // Resolved, and that is the point of half of this module: `os.tmpdir()`
  // answers `/var/folders/…` on a Mac while the path really is
  // `/private/var/folders/…`, and a record filed under the first is a record
  // the CLI never matches.
  const base = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-trust-')))
  const configDir = join(base, 'config')
  const folder = join(base, 'copilot')
  mkdirSync(configDir)
  mkdirSync(folder)
  return { configDir, folder }
}

function read(configDir: string): Record<string, any> {
  return JSON.parse(readFileSync(claudeConfigFile(configDir), 'utf8'))
}

describe('recording that the copilot’s own folder is trusted', () => {
  it('writes the flag under the resolved path, into a config that does not exist yet', () => {
    const { configDir, folder } = scratch()
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('recorded')
    expect(read(configDir).projects[folder].hasTrustDialogAccepted).toBe(true)
  })

  it('files it under the path the CLI will look it up by, not the one it was handed', () => {
    /*
     * The bug that made the first three attempts at this look like the flag
     * simply not working. `/var` is a symlink to `/private/var` on macOS, so a
     * folder handed in as `/var/…` and filed as `/var/…` is a record the CLI —
     * which resolves its own cwd — never finds.
     */
    const { configDir, folder } = scratch()
    const viaLink = folder.replace(/^\/private\//, '/')
    if (viaLink === folder) return // Not a Mac layout; nothing to prove here.
    expect(trustCopilotFolder(claudeConfigFile(configDir), viaLink)).toBe('recorded')
    expect(Object.keys(read(configDir).projects)).toEqual([folder])
  })

  it('keeps everything else in a config file it did not write', () => {
    // It may be the person's real `~/.claude.json`, with a hundred projects and
    // an account in it. One boolean is added; nothing is replaced.
    const { configDir, folder } = scratch()
    writeFileSync(
      claudeConfigFile(configDir),
      JSON.stringify({
        userID: 'u-1',
        hasCompletedOnboarding: true,
        projects: { '/Users/me/work': { hasTrustDialogAccepted: true, allowedTools: ['Bash'] } },
      }),
    )
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('recorded')
    const after = read(configDir)
    expect(after.userID).toBe('u-1')
    expect(after.hasCompletedOnboarding).toBe(true)
    expect(after.projects['/Users/me/work']).toEqual({ hasTrustDialogAccepted: true, allowedTools: ['Bash'] })
    expect(after.projects[folder].hasTrustDialogAccepted).toBe(true)
  })

  it('leaves a folder the CLI already knows about alone', () => {
    const { configDir, folder } = scratch()
    writeFileSync(
      claudeConfigFile(configDir),
      JSON.stringify({ projects: { [folder]: { hasTrustDialogAccepted: true, allowedTools: ['Read'] } } }),
    )
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('already')
    expect(read(configDir).projects[folder].allowedTools).toEqual(['Read'])
  })

  it('never reverses a person who answered “No, exit”', () => {
    /*
     * The one guard that makes this safe to do at all. `false` is not an absent
     * decision, it is a decision — somebody stood at this machine and declined —
     * and an app that flips it because a phone would find it convenient is an
     * app that has taken the dialog away rather than answered it.
     */
    const { configDir, folder } = scratch()
    writeFileSync(claudeConfigFile(configDir), JSON.stringify({ projects: { [folder]: { hasTrustDialogAccepted: false } } }))
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('refused')
    expect(read(configDir).projects[folder].hasTrustDialogAccepted).toBe(false)
  })

  it('refuses a config file it cannot understand rather than writing over it', () => {
    const { configDir, folder } = scratch()
    writeFileSync(claudeConfigFile(configDir), '{ this is not json')
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('failed')
    expect(readFileSync(claudeConfigFile(configDir), 'utf8')).toBe('{ this is not json')

    writeFileSync(claudeConfigFile(configDir), '["an array"]')
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('failed')
    expect(readFileSync(claudeConfigFile(configDir), 'utf8')).toBe('["an array"]')
  })

  it('survives a projects key that is the wrong shape entirely', () => {
    const { configDir, folder } = scratch()
    writeFileSync(claudeConfigFile(configDir), JSON.stringify({ projects: 'nonsense' }))
    expect(trustCopilotFolder(claudeConfigFile(configDir), folder)).toBe('recorded')
    expect(read(configDir).projects[folder].hasTrustDialogAccepted).toBe(true)
  })
})

/**
 * The half that decided which file, and got it wrong for the one account most
 * people run under.
 *
 * Measured against `claude 2.1.237` in an isolated `HOME`, already onboarded,
 * with the copilot folder unknown — the state of every machine that installs
 * this app. A record under `~/.claude/.claude.json` left the trust modal on
 * screen; the same record under `~/.claude.json` did not. `profiles.ts` spawns
 * the machine's own login with `CLAUDE_CONFIG_DIR` unset precisely so the CLI
 * reads the second one, and this is the other side of that decision.
 */
describe('which config file the CLI will actually read', () => {
  it('puts an isolated account’s record inside its own config directory', () => {
    expect(claudeTrustFile({ CLAUDE_CONFIG_DIR: '/accounts/second' }, {})).toBe(
      join('/accounts/second', '.claude.json'),
    )
  })

  it('puts the machine’s own login one level above its config directory', () => {
    expect(claudeTrustFile({}, {})).toBe(join(homedir(), '.claude.json'))
  })

  it('follows a CLAUDE_CONFIG_DIR this app was itself launched with', () => {
    // `systemConfigDir` calls that the user's install, and the session inherits
    // the variable, so the record belongs inside it.
    expect(claudeTrustFile({}, { CLAUDE_CONFIG_DIR: '/elsewhere/claude' })).toBe(
      join('/elsewhere/claude', '.claude.json'),
    )
  })

  it('reads an empty or blank variable as unset, the way the CLI does', () => {
    expect(claudeTrustFile({}, { CLAUDE_CONFIG_DIR: '   ' })).toBe(join(homedir(), '.claude.json'))
  })

  it('lets the account override what this app was launched with', () => {
    expect(
      claudeTrustFile({ CLAUDE_CONFIG_DIR: '/accounts/second' }, { CLAUDE_CONFIG_DIR: '/elsewhere/claude' }),
    ).toBe(join('/accounts/second', '.claude.json'))
  })
})
