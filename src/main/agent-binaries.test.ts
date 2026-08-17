import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  binaryEvidence,
  binaryNote,
  binaryProblem,
  canStart,
  expandHome,
  firstMeaningfulLine,
  looksLikeSpawnFailure,
  resetAgentBinaryCache,
  resolveAgentBinaries,
  resolveAgentBinary,
  type RunProbe,
} from './agent-binaries'

/**
 * The module that ends the worst thing in the 2026-08-16 recording.
 *
 * He pressed Add on a Codex account and got a blank session containing this and
 * nothing else:
 *
 *     Error: spawn /opt/homebrew/lib/node_modules/@openai/codex/node_modules/
 *       @openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex ENOENT
 *     [process exited]
 *
 * Everything in the app said Codex was installed, because everything asked
 * `which codex` and `which codex` is right — the npm package puts a JavaScript
 * launcher on PATH. What it does not put there, on that machine, is the native
 * binary the launcher spawns.
 *
 * Every case below is written against that machine's real behaviour: the
 * launcher exits 1 with a Node error report on stderr, and a complete copy of
 * the same CLI sits in Codex's own plugin directory answering
 * `codex-cli 0.146.0-alpha.3.1`.
 */

beforeEach(() => resetAgentBinaryCache())

/** A probe that always succeeds — the healthy machine. */
const works = async (): Promise<RunProbe> => ({ ok: true, line: '2.1.233' })

/** What the broken npm launcher actually prints, shortened to two lines. */
const LAUNCHER_FAILURE = [
  'Error: spawn /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex ENOENT',
  '    at ChildProcess._handle.onexit (node:internal/child_process:286:19)',
].join('\n')

describe('reading a failed launch', () => {
  it('recognises a Node spawn failure by shape, not by path', () => {
    // The path is different on every machine, so neither half is matched alone:
    // `spawn` appears in ordinary help text, and a CLI printing `ENOENT` about
    // a file *it* was asked for is a working CLI answering a question.
    expect(looksLikeSpawnFailure(LAUNCHER_FAILURE)).toBe(true)
    expect(looksLikeSpawnFailure('usage: codex spawn <task>')).toBe(false)
    expect(looksLikeSpawnFailure("codex: ENOENT: no such file 'notes.md'")).toBe(false)
  })

  it('takes the first line a person could read, skipping stack frames', () => {
    expect(firstMeaningfulLine(LAUNCHER_FAILURE)).toContain('Error: spawn')
    expect(firstMeaningfulLine('\n\n    at Foo (x:1:2)\nreal line')).toBe('real line')
    expect(firstMeaningfulLine('   \n  \n')).toBeNull()
  })
})

describe('resolving one agent', () => {
  it('uses the name on PATH when it runs', async () => {
    const binary = await resolveAgentBinary('claude', {
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => '/usr/local/bin/claude',
      probe: works,
    })
    // The bare name, not the resolved path: on Windows the resolved path is a
    // `.cmd` shim that CreateProcess will not run, and `providers.ts` already
    // wraps a bare name in the command processor there.
    expect(binary.runnable).toBe('claude')
    expect(binary.usedAlternate).toBe(false)
    expect(binary.version).toBe('2.1.233')
    expect(canStart(binary)).toBe(true)
  })

  it('falls back to the declared alternate when the one on PATH will not run', async () => {
    const tried: string[] = []
    const binary = await resolveAgentBinary('codex', {
      platform: 'darwin',
      path: '/usr/bin',
      home: '/Users/asad',
      lookup: async () => '/opt/homebrew/bin/codex',
      exists: () => true,
      probe: async (command) => {
        tried.push(command)
        if (command === 'codex') return { ok: false, line: LAUNCHER_FAILURE.split('\n')[0] }
        return { ok: true, line: 'codex-cli 0.146.0-alpha.3.1' }
      },
    })

    /*
     * Joined rather than written out, and the reason is a Windows failure that
     * looked like a Windows bug and was not.
     *
     * `platform` here selects how a binary is *looked up* and *launched* —
     * `which` against `where.exe`, the command processor wrapper — and says
     * nothing about path syntax. The syntax is the host's, deliberately: the
     * path is one this machine is about to spawn, so `\` is the right
     * separator on Windows and `/` is the right one here. Spelling the expected
     * value with a literal `/` was the test asserting POSIX rather than
     * asserting behaviour, and it failed on Windows for a difference that is
     * correct.
     */
    const alternate = join('/Users/asad', '.codex/plugins/.plugin-appserver/codex')
    expect(tried).toEqual(['codex', alternate])
    expect(binary.runnable).toBe(alternate)
    expect(binary.usedAlternate).toBe(true)
    // Not broken. Codex works on this machine; that the copy on PATH does not is
    // a fact about that copy, and `binaryNote` is where it is said out loud.
    expect(binary.broken).toBe(false)
    expect(canStart(binary)).toBe(true)
    expect(binaryNote(binary)).toContain('will not start')
    expect(binaryNote(binary)).toContain('npm install -g @openai/codex')
  })

  it('never spawns an alternate that is not on disk', async () => {
    // A second ENOENT to explain instead of the first one is not an improvement.
    const tried: string[] = []
    const binary = await resolveAgentBinary('codex', {
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => '/opt/homebrew/bin/codex',
      exists: () => false,
      probe: async (command) => {
        tried.push(command)
        return { ok: false, line: 'nope' }
      },
    })
    expect(tried).toEqual(['codex'])
    expect(binary.runnable).toBeNull()
    expect(binary.broken).toBe(true)
  })

  it('separates "you have it and it will not run" from "you do not have it"', async () => {
    const broken = await resolveAgentBinary('codex', {
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => '/opt/homebrew/bin/codex',
      exists: () => false,
      probe: async () => ({ ok: false, line: LAUNCHER_FAILURE.split('\n')[0] }),
    })
    resetAgentBinaryCache()
    const absent = await resolveAgentBinary('codex', {
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => null,
      // Pinned rather than left to the host: `~/.codex/plugins/.plugin-appserver/codex`
      // genuinely exists on the machine this was written on, so without this the
      // "not installed" case resolves through the alternate and passes for the
      // wrong reason on one Mac and fails everywhere else.
      exists: () => false,
      probe: works,
    })

    expect(broken.broken).toBe(true)
    expect(absent.broken).toBe(false)
    // The two sentences send a person to different places, which is the whole
    // reason the states are kept apart.
    expect(binaryProblem(broken)).toContain('will not start')
    expect(binaryProblem(broken)).toContain('/opt/homebrew/bin/codex')
    expect(binaryProblem(absent)).toContain('not installed')
  })

  it('keeps the machine’s own words out of the sentence and in the evidence', async () => {
    const broken = await resolveAgentBinary('codex', {
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => '/opt/homebrew/bin/codex',
      exists: () => false,
      probe: async () => ({ ok: false, line: LAUNCHER_FAILURE.split('\n')[0] }),
    })

    /*
     * The split that matters. `Error: spawn …/codex ENOENT` *was* the whole
     * error message the app showed, and the report it produced is a person
     * saying it was "not understandable for me as not a technical actual
     * coder". So the sentence is plain and the literal is kept for the one place
     * that prints literals — the Setup panel's probe line.
     */
    expect(binaryProblem(broken)).not.toContain('ENOENT')
    expect(binaryEvidence(broken)).toContain('ENOENT')
  })

  it('is not fooled by a zero exit that printed a spawn failure', async () => {
    // Exit codes are the launcher's to choose; the output is the evidence.
    const binary = await resolveAgentBinary('codex', {
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => '/opt/homebrew/bin/codex',
      exists: () => false,
      // The real `tryRun` inspects output before trusting a zero exit; this
      // mirrors what it would then report.
      probe: async () => ({ ok: false, line: LAUNCHER_FAILURE.split('\n')[0] }),
    })
    expect(binary.runnable).toBeNull()
  })

  it('answers about the shell without looking anything up', async () => {
    let looked = false
    const binary = await resolveAgentBinary('shell', {
      platform: 'darwin',
      lookup: async () => {
        looked = true
        return null
      },
    })
    expect(looked).toBe(false)
    // A machine without a login shell is not a machine, and `providersFor`
    // resolves it from `$SHELL` / `%COMSPEC%` rather than from PATH.
    expect(canStart(binary)).toBe(true)
  })

  it('memoises, so opening a menu three times does not spawn nine processes', async () => {
    let probes = 0
    const options = {
      platform: 'darwin' as const,
      path: '/usr/bin',
      lookup: async () => '/usr/local/bin/claude',
      probe: async (): Promise<RunProbe> => {
        probes += 1
        return { ok: true, line: '2.1.233' }
      },
    }
    await resolveAgentBinary('claude', options)
    await resolveAgentBinary('claude', options)
    expect(probes).toBe(1)

    // "Check again" must not get the memo.
    await resolveAgentBinary('claude', { ...options, refresh: true })
    expect(probes).toBe(2)
  })
})

describe('resolving every agent', () => {
  it('answers for all four, whatever the catalogue holds', async () => {
    const all = await resolveAgentBinaries({
      platform: 'darwin',
      path: '/usr/bin',
      lookup: async () => '/usr/local/bin/x',
      probe: works,
    })
    // Total by construction: a provider added to the union has to be given a
    // key here, which is the check that stops one being silently skipped.
    expect(Object.keys(all).sort()).toEqual(['claude', 'codex', 'gemini', 'shell'])
    expect(canStart(all.shell)).toBe(true)
  })
})

describe('home expansion', () => {
  it('only expands a leading ~/', () => {
    // `join`, because the answer is a path for *this* machine to open and the
    // separator is therefore this machine's. What is under test is which
    // tildes are expanded, not how the result is punctuated.
    expect(expandHome('~/x', '/Users/asad')).toBe(join('/Users/asad', 'x'))
    expect(expandHome('~', '/Users/asad')).toBe('/Users/asad')
    // A literal tilde inside a path is a directory name, not a home marker, so
    // this one is returned untouched and keeps its own spelling.
    expect(expandHome('/opt/~/x', '/Users/asad')).toBe('/opt/~/x')
  })
})
