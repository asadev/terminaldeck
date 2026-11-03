import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { APPEND_SYSTEM_PROMPT_FILE } from '../copilot-layer'
import { instructionsDir, writeInstructions } from './agent-instructions'
import { instructionLaunchArgs, tomlString, WINDOWS_ARG_ROOM } from './agent-launch'

let storageDir = ''

beforeEach(() => {
  storageDir = mkdtempSync(join(tmpdir(), 'td-agent-launch-'))
  writeInstructions(instructionsDir(storageDir), 'builder', 'Work on a branch.\nSay "done" when "done".')
})

afterEach(() => {
  rmSync(storageDir, { recursive: true, force: true })
})

const launch = (provider: string, over: Partial<Parameters<typeof instructionLaunchArgs>[0]> = {}) =>
  instructionLaunchArgs({ provider, agentId: 'builder', storageDir, platform: 'darwin', insideWsl: false, ...over })

describe('a task agent’s instructions on the command line', () => {
  it('hands Claude Code the file itself, through the one spelling of the flag', () => {
    expect(launch('claude')).toEqual([APPEND_SYSTEM_PROMPT_FILE, join(storageDir, 'agent-instructions', 'builder.md')])
  })

  it('hands Codex the text as its developer instructions, as a TOML string', () => {
    expect(launch('codex')).toEqual(['-c', 'developer_instructions="Work on a branch.\\nSay \\"done\\" when \\"done\\".\\n"'])
  })

  it('refuses an agent that cannot be given them, rather than starting it without', () => {
    for (const provider of ['gemini', 'shell', 'custom:aider']) {
      expect(() => launch(provider), provider).toThrow(/cannot be given standing instructions/)
    }
  })

  it('refuses a missing file, a path for an id, and a session inside WSL', () => {
    expect(() => launch('claude', { agentId: 'nobody' })).toThrow(/missing or empty/)
    expect(() => launch('claude', { agentId: '../../etc/passwd' })).toThrow(/not a task agent id/)
    expect(() => launch('claude', { agentId: 7 })).toThrow(/not a task agent id/)
    expect(() => launch('claude', { insideWsl: true })).toThrow(/WSL/)
  })

  it('refuses Codex instructions too long for a Windows command line, and only there', () => {
    writeInstructions(instructionsDir(storageDir), 'builder', 'x'.repeat(WINDOWS_ARG_ROOM))
    expect(() => launch('codex', { platform: 'win32' })).toThrow(/Windows/)
    expect(launch('codex')[1]?.length).toBeGreaterThan(WINDOWS_ARG_ROOM)
  })
})

describe('a TOML basic string', () => {
  it('escapes what TOML refuses raw, and nothing that reads the same unescaped', () => {
    expect(tomlString('plain — ünïcode ✓')).toBe('"plain — ünïcode ✓"')
    expect(tomlString('a\\b"c')).toBe('"a\\\\b\\"c"')
    expect(tomlString('tab\there\r\n')).toBe('"tab\\there\\r\\n"')
    expect(tomlString('bell\u0007 del\u007f')).toBe('"bell\\u0007 del\\u007f"')
  })

  it('keeps a pair of surrogates and replaces a lone one, which TOML cannot carry', () => {
    expect(tomlString('emoji 😀')).toBe('"emoji 😀"')
    expect(tomlString('lone \ud800 end')).toBe('"lone � end"')
  })
})
