import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { copilotPaths } from '../copilot-home'
import {
  createCopilotRunner,
  DENIED_NATIVE_TOOLS,
  NOTHING_MARKER,
  parseRunOutput,
  runPrompt,
  runsDir,
  SILENCE_THRESHOLD_CHARS,
  worthReporting,
  type LaunchInput,
  type LaunchResult,
} from './runner'
import type { RoutineRunRequest } from './engine'
import type { Routine } from './format'

/**
 * The other end of every trigger in the engine.
 *
 * Two things are load-bearing here and both are about a run that nobody is
 * watching. It must **not be able to ask for anything** — no shell, no writes,
 * no sub-agents, and a tool surface that is enumerated rather than wildcarded,
 * so a tool added to the catalogue next month is not silently reachable from
 * every routine on the machine. And it must **stay quiet** unless it found
 * something, because a routine that reports every time it runs is a routine
 * that gets switched off, and a switched-off routine is worse than an absent
 * one — it looks like coverage.
 */

let dir = ''
let launched: LaunchInput[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-runner-'))
  launched = []
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function routine(over: Partial<Routine> = {}): Routine {
  return {
    id: 'blocked-agent',
    name: 'Something is waiting on you',
    triggers: [{ kind: 'manual' }],
    folder: '/work/api',
    prompt: 'Say which session is blocked.',
    enabled: true,
    overlap: 'skip',
    maxRunsPerHour: 6,
    maxRunsPerDay: 24,
    quietForMs: 0,
    expectEveryMs: null,
    unknown: {},
    ...over,
  }
}

function request(over: Partial<RoutineRunRequest> = {}): RoutineRunRequest {
  return {
    routine: routine(),
    runId: 'run-1',
    cause: { kind: 'manual', by: 'user' },
    chain: [],
    signal: new AbortController().signal,
    attended: false,
    control: null,
    ...over,
  }
}

function runner(options: {
  reply?: string
  code?: number
  stderr?: string
  config?: string | null
  launch?: (input: LaunchInput) => Promise<LaunchResult>
}) {
  return createCopilotRunner({
    mcpConfig: () => (options.config === undefined ? '/state/copilot/deck-control-unattended.json' : options.config),
    paths: () => copilotPaths(dir),
    launch:
      options.launch ??
      (async (input) => {
        launched.push(input)
        return {
          stdout: JSON.stringify({
            result: options.reply ?? NOTHING_MARKER,
            is_error: false,
            num_turns: 3,
            session_id: 'cli-session-1',
            total_cost_usd: 0.02,
          }),
          stderr: options.stderr ?? '',
          code: options.code ?? 0,
        }
      }),
  })
}

describe('what a routine run is allowed to do', () => {
  it('is given no shell, no writes and no sub-agents', async () => {
    await runner({}).run(request())
    const args = launched[0].args
    const denied = args.slice(args.indexOf('--disallowedTools') + 1)
    // An unattended agent with Bash is the riskiest shape in this design, and a
    // routine has no need of one: its job is to look and to report.
    for (const tool of DENIED_NATIVE_TOOLS) expect(denied).toContain(tool)
    expect(denied).toContain('Bash')
    expect(denied).toContain('Task')
  })

  it('names every tool it may use, rather than wildcarding the server', async () => {
    await runner({}).run(request())
    const args = launched[0].args
    const allowed = args.slice(args.indexOf('--allowedTools') + 1, args.indexOf('--disallowedTools'))
    expect(allowed).toContain('Read')
    expect(allowed).toContain('mcp__deck-control__sessions_result')
    // No wildcard: a tool added to the catalogue must not become reachable from
    // every routine on the machine the day it lands. Somebody has to decide.
    expect(allowed.every((tool) => !tool.includes('*'))).toBe(true)
    // And the one tool that changes settings is not on the list at all — it
    // would be refused as unattended anyway, and offering it would waste a turn
    // discovering that.
    expect(allowed).not.toContain('mcp__deck-control__settings_write')
  })

  it('is pinned to this server and cannot inherit whatever else is configured', async () => {
    await runner({}).run(request())
    expect(launched[0].args).toContain('--strict-mcp-config')
    expect(launched[0].args).toContain('/state/copilot/deck-control-unattended.json')
  })

  it('sends the prompt on stdin, never on the command line', async () => {
    await runner({}).run(request())
    // A multi-paragraph prompt on a command line is a quoting bug waiting for
    // the first apostrophe, and on a machine where argv is readable it is the
    // prompt in everybody's process list.
    expect(launched[0].stdin).toContain('Say which session is blocked.')
    expect(launched[0].args.join(' ')).not.toContain('Say which session is blocked.')
  })

  /**
   * `<copilot>/runs`, not `<copilot>` — and the distinction is not tidiness.
   *
   * The CLI writes its transcript into `~/.claude/projects/<encoded cwd>/`, so a
   * run whose cwd was the copilot's own folder dropped its conversation into the
   * store `transcript-match.ts` searches for that folder's *sessions*. Seen on
   * the first real run: the overnight routine reported three of the app's own
   * sessions as blocked, one of them carrying that run's own opening line as its
   * last message. A subdirectory still inherits the copilot's `CLAUDE.md`,
   * because the CLI collects it from every directory above the cwd too.
   */
  it('runs beneath the copilot’s folder, so its transcript is not a session’s', async () => {
    await runner({}).run(request())
    expect(launched[0].cwd).toBe(runsDir(copilotPaths(dir)))
    expect(launched[0].cwd.startsWith(copilotPaths(dir).root)).toBe(true)
    expect(launched[0].cwd).not.toBe(copilotPaths(dir).root)
  })

  it('refuses to run at all when there are no tools to run with', async () => {
    const outcome = await runner({ config: null }).run(request())
    expect(outcome.ok).toBe(false)
    // Not "it ran and found nothing": a run that could see nothing would still
    // cost a turn and would still produce a confident answer about a machine it
    // cannot observe.
    expect(outcome.error).toMatch(/no way to see anything/)
    expect(launched).toEqual([])
  })
})

describe('the prompt a run is given', () => {
  it('tells it nobody is watching and what to do about that', () => {
    const text = runPrompt(request())
    expect(text).toMatch(/Nobody is watching/)
    expect(text).toMatch(/not-permitted-unattended/)
    expect(text).toContain(NOTHING_MARKER)
  })

  it('says why it fired, in words', () => {
    expect(runPrompt(request({ cause: { kind: 'session-failed', sessionId: 's1', exitCode: 3 } }))).toContain(
      'session s1 failed with exit code 3',
    )
    expect(runPrompt(request({ cause: { kind: 'schedule', dueAt: 0, missed: 2 } }))).toContain(
      '2 earlier runs were missed',
    )
  })

  it('states the prompt-injection boundary rather than assuming it', () => {
    // The copilot's own CLAUDE.md says this, and a routine run does not read
    // it — the run is a fresh process with the bootstrap files skipped, which
    // is the whole reason it is cheap.
    expect(runPrompt(request())).toMatch(/untrusted source/)
  })
})

describe('staying quiet', () => {
  it('drops a reply that found nothing', () => {
    expect(worthReporting(NOTHING_MARKER)).toBe(false)
    // The polite version, which is the shape that would otherwise defeat a
    // threshold applied before the marker was stripped.
    expect(worthReporting(`${NOTHING_MARKER}. All eight sessions look fine.`)).toBe(false)
  })

  it('drops a reply too short to be a finding', () => {
    expect(worthReporting('Everything looks fine.')).toBe(false)
    expect(worthReporting('x'.repeat(SILENCE_THRESHOLD_CHARS - 1))).toBe(false)
    expect(worthReporting('x'.repeat(SILENCE_THRESHOLD_CHARS))).toBe(true)
  })

  it('writes a report row only when there is something to report', async () => {
    const log = copilotPaths(dir).actions

    await runner({}).run(request())
    expect(readLog(log)).toEqual([])

    await runner({ reply: 'y'.repeat(SILENCE_THRESHOLD_CHARS + 10) }).run(request())
    const rows = readLog(log)
    expect(rows).toHaveLength(1)
    expect(rows[0].action).toBe('routine.report')
    expect(rows[0].sessionId).toBe('cli-session-1')
  })
})

describe('reading what the CLI printed', () => {
  it('takes the answer out of the JSON envelope', () => {
    const parsed = parseRunOutput(
      JSON.stringify({ result: 'two sessions are blocked', is_error: false, num_turns: 4, session_id: 'abc' }),
    )
    expect(parsed).toEqual({
      text: 'two sessions are blocked',
      failed: false,
      turns: 4,
      sessionId: 'abc',
      costUsd: null,
    })
  })

  it('treats unparseable output as the answer rather than throwing', () => {
    // This is another program's output format. A build that changes it should
    // degrade to "the run produced text nobody could parse", not to an
    // exception inside the engine.
    expect(parseRunOutput('Not logged in · Please run /login').text).toBe(
      'Not logged in · Please run /login',
    )
  })

  it('keeps the answer off a non-zero exit instead of throwing it away', async () => {
    // `execFile` hangs output off the *error object* on a non-zero exit, a trap
    // this repository has already paid for once. A failed run has usually still
    // produced its JSON.
    const outcome = await runner({ reply: 'z'.repeat(400), code: 1 }).run(request())
    expect(outcome.ok).toBe(true)
    expect(readLog(copilotPaths(dir).actions)).toHaveLength(1)
  })

  it('reports a run that died with nothing to say', async () => {
    const outcome = await runner({ reply: '', code: 127, stderr: 'claude: command not found' }).run(
      request(),
    )
    expect(outcome.ok).toBe(false)
    expect(outcome.error).toMatch(/command not found/)
  })
})

function readLog(file: string): Array<{ action: string; sessionId?: string }> {
  try {
    return readFileSync(file, 'utf8')
      .split('\n')
      .filter((line) => line.trim() !== '')
      .map((line) => JSON.parse(line) as { action: string; sessionId?: string })
  } catch {
    return []
  }
}
