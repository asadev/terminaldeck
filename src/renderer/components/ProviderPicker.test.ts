import { describe, expect, it } from 'vitest'
import {
  buildProviderRows,
  firstAvailable,
  PROVIDER_OPTIONS,
  resumeAvailability,
} from './ProviderPicker'

/**
 * Pure logic only. There is no DOM in this project's test setup and the picker
 * renders through `Modal`, which portals into `document.body` — so the parts
 * worth holding to a contract are extracted and exercised directly.
 */

const detected = {
  claude: true,
  codex: false,
  gemini: false,
  shell: true,
}

describe('PROVIDER_OPTIONS', () => {
  it('covers every provider the app can spawn', () => {
    expect(PROVIDER_OPTIONS.map((p) => p.id)).toEqual(['claude', 'codex', 'gemini', 'shell'])
  })

  it('mirrors which providers have a resume command in the main process', () => {
    // `claude --continue` and `codex resume --last` exist; the Gemini CLI has
    // no equivalent, and a shell has no session to resume.
    const resumable = PROVIDER_OPTIONS.filter((p) => p.canResume).map((p) => p.id)
    expect(resumable).toEqual(['claude', 'codex'])
  })

  it('offers an install command for every agent that can be missing', () => {
    for (const option of PROVIDER_OPTIONS) {
      if (option.id === 'shell') expect(option.install).toBeNull()
      else expect(option.install).toBeTruthy()
    }
  })
})

describe('buildProviderRows', () => {
  it('marks installed providers available', () => {
    const rows = buildProviderRows(detected)
    expect(rows.find((r) => r.id === 'claude')?.available).toBe(true)
    expect(rows.find((r) => r.id === 'claude')?.reason).toBeNull()
  })

  it('explains why a missing provider cannot be picked', () => {
    const rows = buildProviderRows(detected)
    const codex = rows.find((r) => r.id === 'codex')
    expect(codex?.available).toBe(false)
    expect(codex?.reason).toContain('PATH')
  })

  it('lists every provider even when most are missing', () => {
    // A missing agent is information the user needs, not something to hide —
    // the install command is right there in the row.
    expect(buildProviderRows(detected)).toHaveLength(PROVIDER_OPTIONS.length)
  })

  it('always keeps the shell available', () => {
    const rows = buildProviderRows({ claude: false, codex: false, gemini: false, shell: false })
    expect(rows.find((r) => r.id === 'shell')?.available).toBe(true)
  })

  it('fails open when detection produced nothing usable', () => {
    // Locking every agent out on a failed `which` would make the app useless
    // in exactly the case it is least able to diagnose.
    for (const broken of [null, undefined, {}, 'nope', 42]) {
      const rows = buildProviderRows(broken)
      expect(rows.every((r) => r.available)).toBe(true)
    }
  })

  it('treats an all-false result as a real answer, not a broken detector', () => {
    const rows = buildProviderRows({ claude: false, codex: false, gemini: false, shell: false })
    expect(rows.filter((r) => r.available).map((r) => r.id)).toEqual(['shell'])
  })
})

describe('resumeAvailability', () => {
  const rows = buildProviderRows(detected)
  const row = (id: string) => rows.find((r) => r.id === id)

  it('is offered for an installed provider that supports it', () => {
    expect(resumeAvailability(row('claude'))).toEqual({ enabled: true, reason: null })
  })

  it('explains itself for an installed provider with no resume command', () => {
    const installed = buildProviderRows({ claude: true, codex: true, gemini: true, shell: true })
    const result = resumeAvailability(installed.find((r) => r.id === 'gemini'))
    expect(result.enabled).toBe(false)
    expect(result.reason).toContain('no resume command')
  })

  it('says nothing extra for a provider that is not installed', () => {
    // The row itself already says why it cannot be used; repeating it under
    // the checkbox would be noise.
    expect(resumeAvailability(row('codex'))).toEqual({ enabled: false, reason: null })
  })

  it('is off when nothing is selected', () => {
    expect(resumeAvailability(undefined)).toEqual({ enabled: false, reason: null })
  })
})

describe('firstAvailable', () => {
  it('picks the first provider that can actually be used', () => {
    const rows = buildProviderRows({ claude: false, codex: true, gemini: false, shell: true })
    expect(firstAvailable(rows)).toBe('codex')
  })

  it('falls back to the shell when no agent is installed', () => {
    expect(firstAvailable(buildProviderRows({ claude: false, codex: false, gemini: false }))).toBe(
      'shell',
    )
  })

  it('returns null for an empty list', () => {
    expect(firstAvailable([])).toBeNull()
  })
})
