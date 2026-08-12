import { describe, expect, it } from 'vitest'
import { probeBinary, toProbeResult } from './tool-probe'

/**
 * The wording is the whole feature here — a probe exists so the panel can show
 * what the machine said rather than only what we concluded — and it differs by
 * shell, so it is tested from the outside rather than by running one.
 */

describe('a finished probe', () => {
  it('keeps the shell’s own sentence, which is what zsh writes', () => {
    // Verified on this machine: `zsh -c 'which copilot'` prints exactly this
    // and exits 1. Rewording it here would put a second, slightly different
    // truth on screen.
    const result = toProbeResult('copilot', 'which copilot', {
      stdout: 'copilot not found\n',
      exitCode: 1,
    })
    expect(result.line).toBe('copilot not found')
    expect(result.found).toBe(false)
  })

  it('writes one itself when the shell says nothing at all', () => {
    // /usr/bin/which — what bash and sh get — prints nothing and only sets an
    // exit status, so there would otherwise be no line to show.
    const result = toProbeResult('copilot', 'which copilot', { exitCode: 1 })
    expect(result.line).toBe('copilot not found (which copilot exited 1).')
  })

  it('says so when the probe never finished, rather than inventing a status', () => {
    expect(toProbeResult('codex', 'which codex', { exitCode: -1 }).line).toBe(
      'codex not found (which codex did not finish).',
    )
  })

  it('reports the path when it found one', () => {
    const result = toProbeResult('claude', 'which claude', {
      stdout: '/Users/apple/.local/bin/claude\n',
      exitCode: 0,
    })
    expect(result).toMatchObject({ found: true, line: '/Users/apple/.local/bin/claude' })
  })

  it('keeps a probe to a line or three, not a log', () => {
    const noisy = toProbeResult('gemini', 'which gemini', {
      stdout: 'a\nb\nc\nd\ne\n',
      stderr: `${'x'.repeat(500)}\n`,
      exitCode: 1,
    })
    expect(noisy.output.split('\n')).toHaveLength(3)
    expect(noisy.output.length).toBeLessThanOrEqual(240)
  })
})

describe('probing a name from outside the tables', () => {
  it('refuses rather than handing it to a shell', async () => {
    const result = await probeBinary('claude; rm -rf ~', process.env.PATH ?? '')
    expect(result.found).toBe(false)
    expect(result.line).toContain('not a name this app is willing to run')
  })
})
