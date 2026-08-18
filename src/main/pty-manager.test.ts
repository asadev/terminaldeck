import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { spawnFailureMessage, type SpawnSpec } from './pty-manager'

/**
 * What the app says when a process will not start.
 *
 * The sentence is the whole test, and it is worth a file because the version
 * that shipped was this, seven times, in Asad's app log on 2026-08-17:
 *
 *     [ipc] session:create failed File not found:
 *
 * — with nothing after the colon. It named no file, no folder and no agent, and
 * it was *accurate*: node-pty reaches that string precisely when it has no path
 * to report. See `spawnFailureMessage` for the mechanism and `wsl.ts`'s
 * `wslExePath` for the measurement.
 *
 * Driven as a function rather than through a real failed spawn because a real
 * one is unreachable here: node-pty on POSIX never throws from `spawn` — a
 * missing program, a missing working directory and a bare name were all
 * measured on this Mac and all three return a live pty whose process exits a
 * moment later. Only ConPTY refuses synchronously. So the choice is between
 * checking the sentence here or checking it on the platform where reading it
 * means somebody already has a bug.
 */

const spec = (over: Partial<SpawnSpec> = {}): SpawnSpec => ({
  provider: 'claude',
  command: 'C:\\Windows\\System32\\wsl.exe',
  args: [],
  path: '',
  ...over,
})

describe('the sentence for a process that would not start', () => {
  it('names the agent, the folder, the program and where the process was to run', () => {
    const message = spawnFailureMessage(
      spec(),
      '/home/asad/ClaudeImza',
      'C:\\Users\\Imza',
      new Error('File not found: '),
    )

    expect(message).toContain('claude')
    expect(message).toContain('/home/asad/ClaudeImza')
    expect(message).toContain('C:\\Windows\\System32\\wsl.exe')
    // Named separately from the session's folder, because for a WSL session the
    // two are deliberately different and a message with only one of them
    // explains the wrong half.
    expect(message).toContain('C:\\Users\\Imza')
  })

  it('keeps what the layer below said, verbatim and last', () => {
    // The only part written by whoever actually refused. Replacing it with a
    // sentence of our own is how a specific failure becomes a vague one.
    const message = spawnFailureMessage(spec(), '/p', '/p', new Error('posix_spawnp failed.'))
    expect(message.endsWith('posix_spawnp failed.')).toBe(true)
  })

  it('ends cleanly when there was nothing to quote', () => {
    /*
     * The case this whole function exists for. `File not found: ` trims to
     * something; an error with an *empty* message trims to nothing, and a
     * sentence ending in a dangling em dash would be the same defect as the
     * dangling colon it replaces.
     */
    const message = spawnFailureMessage(spec(), '/p', '/p', new Error('   '))
    expect(message.endsWith('—')).toBe(false)
    expect(message).toBe('could not start claude in /p: C:\\Windows\\System32\\wsl.exe would not run from /p')
  })

  it('survives something thrown that is not an Error at all', () => {
    expect(spawnFailureMessage(spec(), '/p', '/p', 'nope')).toContain('nope')
  })
})

describe('the spawn is wrapped where the facts still exist', () => {
  it('builds its failure message with this function and keeps the cause', () => {
    /*
     * A source check, and it is the wiring half of the test above: the sentence
     * being right is worth nothing if the `catch` composes its own. `cause` is
     * asserted too — the enriched message is for a person, and anything that
     * wants the real error object has to still be able to reach it.
     */
    const source = readFileSync(join(__dirname, 'pty-manager.ts'), 'utf8')
    const create = source.slice(source.indexOf('  create(input: CreateSessionInput'))
    expect(create).toContain('spawnFailureMessage(spawnSpec, input.cwd, procCwd, error)')
    expect(create).toContain('{ cause: error }')
  })
})
