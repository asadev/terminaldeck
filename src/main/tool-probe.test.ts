import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { launchSpec, probeBinary, toProbeResult } from './tool-probe'

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

/* ------------------------------------------------------------ launching -- */

/**
 * Two separate Windows defects meet in `launchSpec`, and each of them is
 * invisible from macOS: Node will not spawn a `.cmd` without `shell: true`, and
 * `shell: true` does not quote the file it puts on the cmd.exe command line.
 * Fixing only the first turns "no version at all" into "no version whenever the
 * path has a space in it", which is most installs.
 */
describe('how a found binary is launched', () => {
  it('runs the name directly on macOS, with no shell in the way', () => {
    expect(launchSpec('claude', '/opt/homebrew/bin/claude', 'darwin')).toEqual({
      command: 'claude',
      shell: false,
    })
    // A `.cmd` on a Mac is a file with an odd name, not a batch file.
    expect(launchSpec('claude', '/opt/homebrew/bin/claude.cmd', 'darwin').shell).toBe(false)
  })

  it('sends a Windows shim through the command processor', () => {
    // `where.exe claude` on a machine with the npm package installed prints
    // exactly this shape: an absolute path to a batch file.
    expect(launchSpec('claude', 'C:\\Users\\Asad\\AppData\\Roaming\\npm\\claude.cmd', 'win32')).toEqual({
      command: '"C:\\Users\\Asad\\AppData\\Roaming\\npm\\claude.cmd"',
      shell: true,
    })
    expect(launchSpec('claude', 'C:\\tools\\claude.BAT', 'win32').shell).toBe(true)
  })

  it('quotes a path with a space, which is where the default install puts it', () => {
    // Node builds `cmd.exe /d /s /c "<file> <args>"` and does not quote <file>.
    // Unquoted, cmd splits this at the space and tries to run `C:\Program`;
    // quoted, `/s` strips only the outer pair and the inner quotes survive to
    // hold the path together.
    const spec = launchSpec('claude', 'C:\\Program Files\\nodejs\\claude.cmd', 'win32')
    expect(spec).toEqual({
      command: '"C:\\Program Files\\nodejs\\claude.cmd"',
      shell: true,
    })
    // The property, stated without reference to how it is spelled: the path is
    // not exposed to the command line with its space unprotected.
    expect(spec.command.startsWith('"') && spec.command.endsWith('"')).toBe(true)
    expect(spec.command.slice(1, -1)).toBe('C:\\Program Files\\nodejs\\claude.cmd')
  })

  it('leaves a real Windows executable alone', () => {
    // `git.exe` is not a batch file, so there is nothing to route around and no
    // reason to pay for a cmd.exe.
    expect(launchSpec('git', 'C:\\Program Files\\Git\\cmd\\git.exe', 'win32')).toEqual({
      command: 'git',
      shell: false,
    })
  })

  it('uses the command processor when it was never told where the binary is', () => {
    // Nothing resolved means we cannot tell a shim from an exe, and cmd runs
    // both. Only names that passed SAFE_BIN can get here, so there is no shell
    // metacharacter to smuggle through.
    expect(launchSpec('copilot', null, 'win32')).toEqual({ command: '"copilot"', shell: true })
    expect(launchSpec('copilot', null, 'darwin')).toEqual({ command: 'copilot', shell: false })
  })
})

/* ------------------------------------------------------- windowsHide -- */

/**
 * The pattern guard for a spawn that flashes a console window.
 *
 * On Windows every child process this app starts is a console program, and
 * without `windowsHide` each one paints a black window on screen for as long as
 * it runs and takes focus with it. That is not a crash and no test of behaviour
 * can see it — the command still works — so it survives review the same way
 * `{ ...process.env, PATH }` did: it is correct on macOS, invisible in the
 * output, and wrong only where nobody here is sitting. `platform/env-path.test.ts`
 * makes the same argument at length and this scan is deliberately its twin.
 *
 * The rule is mechanical and has no exceptions, including for calls guarded by
 * a macOS-only branch: guards move, and a reader should not have to re-derive
 * whether this particular one still holds.
 *
 * Scope is the files this change owns. A repo-wide sweep would be better and is
 * the obvious next step, but a scan that fails on somebody else's in-flight
 * work teaches people to skip the suite.
 */

const ROOT = resolve(__dirname, '..', '..')

const SPAWNS = [
  'src/main/tool-probe.ts',
  'src/main/prerequisites.ts',
  'src/main/copilot.ts',
  'src/main/diagnostics.ts',
  'src/main/menu.ts',
]

/** Anything that starts a child process. `run` is this codebase's promisified `execFile`. */
const SPAWNERS = /\b(run|exec|execSync|execFile|execFileSync|spawn|spawnSync)\s*\(/g

/**
 * Source with comments and string bodies blanked to spaces, offsets preserved.
 *
 * Same technique, and the same two reasons, as `platform/env-path.test.ts`:
 * prose about the hazard is dense in exactly the files being scanned and would
 * otherwise trip it, and a `//` inside a string would eat the rest of a real
 * line and hide a genuine offence.
 */
function blankCommentsAndStrings(source: string): string {
  const out = source.split('')
  const blank = (from: number, to: number): void => {
    for (let i = from; i < to && i < out.length; i++) if (out[i] !== '\n') out[i] = ' '
  }
  let i = 0
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      const end = source.indexOf('\n', i)
      const stop = end === -1 ? source.length : end
      blank(i, stop)
      i = stop
      continue
    }
    if (source.startsWith('/*', i)) {
      const end = source.indexOf('*/', i + 2)
      const stop = end === -1 ? source.length : end + 2
      blank(i, stop)
      i = stop
      continue
    }
    const quote = source[i]
    if (quote === "'" || quote === '"' || quote === '`') {
      let j = i + 1
      while (j < source.length && source[j] !== quote) j += source[j] === '\\' ? 2 : 1
      blank(i + 1, Math.min(j, source.length))
      i = j + 1
      continue
    }
    i++
  }
  return out.join('')
}

/** The text between a call's parentheses, however deeply nested. */
function callArguments(text: string, open: number): string {
  let depth = 0
  for (let i = open; i < text.length; i++) {
    if (text[i] === '(') depth++
    else if (text[i] === ')') {
      depth--
      if (depth === 0) return text.slice(open + 1, i)
    }
  }
  return text.slice(open + 1)
}

/** Every child-process call site in the source, as `file:line`. */
function findCalls(source: string, file: string): { at: string; hidden: boolean }[] {
  const text = blankCommentsAndStrings(source)
  const calls: { at: string; hidden: boolean }[] = []
  for (const match of text.matchAll(SPAWNERS)) {
    const open = match.index + match[0].length - 1
    calls.push({
      at: `${file}:${text.slice(0, match.index).split('\n').length}`,
      hidden: /\bwindowsHide\b/.test(callArguments(text, open)),
    })
  }
  return calls
}

/** `file:line` for every child-process call that does not pass `windowsHide`. */
function findOffences(source: string, file: string): string[] {
  return findCalls(source, file)
    .filter((call) => !call.hidden)
    .map((call) => call.at)
    .sort()
}

describe('no child process is spawned without windowsHide', () => {
  it('finds the pattern when it is there', () => {
    const cases = [
      "await run(bin, ['--version'], { timeout: 4000 })",
      "execFile('gh', ['auth', 'status'], { env })",
      "spawn(binary, args)",
      "const child = spawnSync(bin, args, { encoding: 'utf8' })",
      // Options on their own lines, which is how every real call here is written.
      'const { stdout } = await run(spec.command, spec.args, {\n  env,\n  timeout: 4000,\n})',
    ]
    for (const source of cases) {
      expect(findOffences(source, 'fixture.ts'), source).not.toHaveLength(0)
    }
  })

  it('leaves the correct forms alone', () => {
    const cases = [
      "await run(bin, ['--version'], { timeout: 4000, windowsHide: true })",
      'const { stdout } = await run(spec.command, spec.args, {\n  env,\n  windowsHide: true,\n})',
      // `windowsHide` inside a nested literal still reaches the child.
      'run(bin, args, { ...base, windowsHide: true })',
      // Not a spawn: the promisify wrapper, and an import.
      "import { execFile } from 'node:child_process'\nconst run = promisify(execFile)",
      // Prose quoting the bad form — there is a lot of it in these files.
      '// run(bin, args, { timeout: 1 }) is the bug\nconst x = 1',
      '/** Never write `spawn(bin, args)` without windowsHide. */\nconst y = 2',
    ]
    for (const source of cases) {
      expect(findOffences(source, 'fixture.ts'), source).toEqual([])
    }
  })

  it('reports the line the call opens on', () => {
    const source = ['const a = 1', '', '/* comment', '   lines */', 'run(bin, args, {})'].join('\n')
    expect(findOffences(source, 'fixture.ts')).toEqual(['fixture.ts:5'])
  })

  it('is looking at real call sites and not at nothing', () => {
    // Without this the sweep below passes just as happily when the regex stops
    // matching, the file list goes stale, or the calls move to another module —
    // a green check guarding nothing, which is worse than no check.
    //
    // Counted rather than pinned by line, so that editing a comment above a
    // call does not fail a test about spawning.
    const counts = Object.fromEntries(
      SPAWNS.map((file) => [file, findCalls(readFileSync(join(ROOT, file), 'utf8'), file).length]),
    )
    expect(counts).toEqual({
      // probeBinary, and readVersion.
      'src/main/tool-probe.ts': 2,
      // which, version, and the macOS keychain check.
      'src/main/prerequisites.ts': 3,
      // gh auth status, and gh extension list.
      'src/main/copilot.ts': 2,
      // Neither of these starts a process today; listed so that the day one
      // does, it arrives inside the sweep rather than outside it.
      'src/main/diagnostics.ts': 0,
      'src/main/menu.ts': 0,
    })
  })

  it('holds across every file this change owns', () => {
    const offences = SPAWNS.flatMap((file) =>
      findOffences(readFileSync(join(ROOT, file), 'utf8'), file),
    ).sort()

    expect(
      offences,
      'On Windows a spawn without `windowsHide: true` flashes a console window over whatever ' +
        'the user is doing. Add it — there is no case here where the window is wanted.',
    ).toEqual([])
  })
})
