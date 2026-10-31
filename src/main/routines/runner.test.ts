import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { copilotPaths } from '../copilot-home'
import {
  createCopilotRunner,
  DENIED_NATIVE_TOOLS,
  killPlan,
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
// The real table, asserted against rather than restated as literals. A Windows
// command line written out by hand in a test is a claim about what somebody
// believed `providers.ts` does; reading it from `providers.ts` is a claim about
// what it does.
import { providersFor } from '../providers'
import type { Env, Platform } from '../platform/host'

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
  platform?: Platform
  env?: Env
  launch?: (input: LaunchInput) => Promise<LaunchResult>
}) {
  return createCopilotRunner({
    mcpConfig: () => (options.config === undefined ? '/state/copilot/deck-control-unattended.json' : options.config),
    paths: () => copilotPaths(dir),
    /*
     * Pinned rather than left to the host, and it is not a formality.
     *
     * What gets spawned is `providersFor(platform, env).claude`, so a case that
     * reads `launched[0].command` while the platform is whatever machine ran the
     * suite is asserting a different thing on each of them — and on the machine
     * this was written on it would assert the *only* shape that never had the
     * bug. Every case below that names an argument means "on macOS", and says
     * so; the Windows cases name win32 and are the only ones that can fail for
     * Windows' reasons.
     */
    platform: options.platform ?? 'darwin',
    env: options.env ?? { SHELL: '/bin/zsh' },
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

/**
 * The half of the launch that is not the arguments.
 *
 * Every one of these forces a platform rather than measuring one, and that is
 * the whole point of the block: the defect it pins was invisible for as long as
 * it existed *because* macOS is the platform where the two halves of the
 * launcher happen to be interchangeable. On macOS `spawn.command` is the string
 * `claude` and `spawn.args` is empty, so a runner that supplied its own argv and
 * threw the table's away produced a byte-identical command line. On Windows the
 * table answers cmd.exe with the actual program in `spawn.args`, and throwing
 * that away ran `cmd.exe --print --output-format json …` with the routine's
 * prompt on the interactive interpreter's stdin — every scheduled routine on
 * Windows failing, and failing as "could not check".
 *
 * A test that let the host decide the platform would have gone green here on the
 * only machine this repository is developed on, which is the shape six tests in
 * this codebase have already had to be fixed for.
 */
describe('how the run is actually launched', () => {
  const WINDOWS: Env = { COMSPEC: 'C:\\Windows\\system32\\cmd.exe' }
  const MAC: Env = { SHELL: '/bin/zsh' }

  it('runs the CLI itself on macOS', async () => {
    await runner({ platform: 'darwin', env: MAC }).run(request())
    expect(launched[0].command).toBe('claude')
    // Nothing wraps anything here, so the first argument is the CLI's own.
    expect(launched[0].args[0]).toBe('--print')
  })

  it('goes through the command processor on Windows, keeping the program', async () => {
    await runner({ platform: 'win32', env: WINDOWS }).run(request())

    // Read off the real table rather than written out here: a hand-written
    // Windows command line asserts what somebody believed `providers.ts` does.
    const table = providersFor('win32', WINDOWS).claude.spawn
    expect(launched[0].command).toBe(table.command)
    expect(launched[0].args.slice(0, table.args.length)).toEqual(table.args)

    // And, said the other way round, because the assertion above would also
    // pass against a table that had somehow become the macOS one: what runs is
    // the command processor, and `/c` — the flag whose absence turned cmd.exe
    // into the interactive interpreter that read the prompt as a batch script.
    expect(launched[0].command).not.toBe('claude')
    expect(launched[0].command.toLowerCase().endsWith('cmd.exe')).toBe(true)
    expect(launched[0].args[0]).toBe('/c')
    expect(launched[0].args[1]).toBe('claude')
  })

  it('loses none of the run’s own flags behind that prefix', async () => {
    await runner({ platform: 'darwin', env: MAC }).run(request())
    await runner({ platform: 'win32', env: WINDOWS }).run(request())
    const [mac, win] = launched

    // The exact defect, stated as an equality: Windows is the same argv with
    // the launcher's prefix in front, not a shorter one.
    const prefix = providersFor('win32', WINDOWS).claude.spawn.args
    expect(win.args.slice(prefix.length)).toEqual(mac.args)
    expect(win.args).toContain('--strict-mcp-config')
    expect(win.args).toContain('--disallowedTools')
  })

  it('still sends the prompt on stdin on Windows, never into cmd', async () => {
    await runner({ platform: 'win32', env: WINDOWS }).run(request())
    // This is why `/c` above is load-bearing rather than cosmetic. cmd.exe
    // without it reads stdin as a batch script, so the prompt's own sentences
    // were being attempted as commands in the runs directory.
    expect(launched[0].stdin).toContain('Say which session is blocked.')
    expect(launched[0].args.join(' ')).not.toContain('Say which session is blocked.')
  })

  it('tells the spawn which platform’s rules to stop the run by', async () => {
    await runner({ platform: 'win32', env: WINDOWS }).run(request())
    expect(launched[0].platform).toBe('win32')
  })
})

/**
 * Stopping a run, which stopped meaning `child.kill()` the moment the launcher
 * fix put cmd.exe between this process and the CLI.
 *
 * A pure plan rather than a function that kills, because forcing win32 in a test
 * on the machine this was written on would otherwise run `taskkill` — and a test
 * that cannot force the platform says nothing whatever about Windows.
 */
describe('stopping a run', () => {
  it('kills the tree on Windows, where the child is only the shell', () => {
    // `/T` because the CLI is a grandchild of cmd.exe and Node's kill reaches
    // the child alone; `/F` because a console app that is not pumping messages
    // ignores the polite form. Without this an unattended run survives its own
    // cancellation still holding the unattended MCP token.
    expect(killPlan(4321, 'win32')).toEqual({
      kind: 'tree',
      command: 'taskkill',
      args: ['/pid', '4321', '/T', '/F'],
    })
  })

  it('signals the CLI itself everywhere else', () => {
    // On macOS the child *is* claude, so the signal lands on the process doing
    // the work — which is what `overlap: cancel` has always meant there.
    expect(killPlan(4321, 'darwin')).toEqual({ kind: 'signal', signal: 'SIGTERM' })
  })

  it('falls back to a signal when there is no pid to name a tree with', () => {
    expect(killPlan(undefined, 'win32')).toEqual({ kind: 'signal', signal: 'SIGTERM' })
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
