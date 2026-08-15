/**
 * Running a session inside WSL, which on a Windows machine is where the Linux
 * work actually is.
 *
 * ## The bug this closes
 *
 * `providers.ts` spawns `%COMSPEC%` on Windows — cmd.exe — and that is correct
 * for an agent CLI installed on Windows. It is useless for the machine this was
 * written for, where `claude` is installed inside Ubuntu and Windows has never
 * heard of it. `where.exe claude` answers "not found", `detectProviders` reports
 * every agent missing, and every tab silently downgrades to a plain cmd.exe
 * shell. The app is installed, launches, and cannot do the one thing it is for.
 *
 * Pointing the existing code at the Linux files instead does not help either.
 * Explorer exposes the distro at `\\wsl.localhost\Ubuntu\…`, and cmd.exe
 * refuses a UNC path as a working directory outright — "CMD does not support
 * UNC paths as current directories" — so the shell starts in `C:\Windows` and
 * every relative path in the session is wrong.
 *
 * ## The rule everything here follows
 *
 * **Keep the shell and the files on the same side of the boundary.** Crossing it
 * is what hurts: Linux files reached from Windows go over 9P, Windows files
 * reached from Linux go over `/mnt/c`, and both are slow enough to be felt on
 * every `git status`. So the decision is made by the folder, not by a setting:
 *
 *   - a folder that is a Linux path (`/home/asad/proj`) runs inside the distro;
 *   - a folder that is a Windows path (`C:\Users\Asad\proj`) runs on Windows,
 *     exactly as it does today.
 *
 * That is why there is no "use WSL" switch. A switch would let the two disagree,
 * and the disagreement is the failure. The one thing a person does choose is
 * *which* distro, because a path alone cannot say — `/home/asad/proj` exists in
 * Ubuntu and in Debian and means a different directory in each.
 *
 * ## What crosses, and what does not
 *
 * Three things are allowed across, all of them small, all of them metadata:
 *
 *   1. `wsl.exe --cd <linux path>` — the *instruction*, not the files.
 *   2. A `\\wsl.localhost\…` path, used **only** for `existsSync`-shaped
 *      questions (did this folder survive since the last launch?) and for
 *      translating a folder the user picked in Explorer's dialog back into the
 *      Linux path it really is. Never as a working directory, never as the place
 *      a command runs.
 *   3. A handful of environment variables, named in `WSLENV` so the boundary
 *      copies them in. See {@link wslEnvBridge}.
 *
 * ## Everything is injected, because none of it can run here
 *
 * This is written and tested on a Mac. `wsl.exe` cannot be run, so the platform
 * and the process runner are both parameters — the same argument
 * `platform/host.ts` makes at length, for the same reason: a branch that can
 * only be exercised on the machine it was written on is a branch whose first
 * user is the one who finds the bug.
 */

import { execFile } from 'node:child_process'
import { win32 } from 'node:path'
import type { InvokeRegistrar } from './ipc-seam'
import { currentPlatform, isWindows, type Env, type Platform } from './platform/host'

/** The command. Named with `.exe` for the reason `lookup.ts` gives for `where.exe`. */
export const WSL_EXE = 'wsl.exe'

/**
 * One registered distribution, as `wsl.exe -l -v` describes it.
 *
 * `running` is deliberately not read from the STATE column. See
 * {@link parseDistroTable}.
 */
export interface WslDistro {
  name: string
  /** 1 or 2. Carried because a WSL1 distro has no `\\wsl.localhost` share. */
  version: number
  running: boolean
  /** The one `wsl.exe` marks with `*` and uses when `-d` is omitted. */
  isDefault: boolean
}

/**
 * The three answers a Windows machine can give, which are three different
 * situations to the person reading them:
 *
 *  - `absent` — there is no `wsl.exe`. Nothing to fix in this app.
 *  - `no-distros` — WSL is there and has nothing to work in. This is also what a
 *    machine with only Docker Desktop's appliance distros looks like, because
 *    those are not places anybody works. See {@link APPLIANCE_DISTROS}.
 *  - `ready` — at least one distro a person could open a shell in.
 */
export type WslState = 'absent' | 'no-distros' | 'ready'

export interface WslReading {
  state: WslState
  /** Empty unless `state` is `ready`. Appliance distros are already filtered out. */
  distros: WslDistro[]
  /**
   * What `wsl.exe` itself said when it refused, verbatim and trimmed.
   *
   * Kept rather than replaced with a sentence of our own because the real
   * messages are specific and actionable ("has no installed distributions",
   * "the Virtual Machine Platform feature is not enabled") and inventing a
   * summary of them would throw away the only accurate thing on the screen.
   * Never parsed — it is localised.
   */
  detail: string | null
}

/* ---------------------------------------------------------------- running -- */

/** One completed run of `wsl.exe`, however it ended. */
export interface WslRun {
  ok: boolean
  stdout: Buffer
  stderr: Buffer
  /** `'ENOENT'` when `wsl.exe` itself is not on the machine; otherwise the exit code. */
  code: number | string | null
}

/**
 * How this module runs `wsl.exe`.
 *
 * It resolves rather than rejects, always. Every caller here has to tell "the
 * command is missing" apart from "the command ran and said no", and a rejected
 * promise flattens both into a `catch` that then has to re-derive the
 * difference from an error object's shape.
 */
export type WslExec = (args: readonly string[], timeoutMs: number) => Promise<WslRun>

/** Fast: it reads a registry-backed list and starts nothing. */
const LIST_TIMEOUT_MS = 10_000

/**
 * Slow on purpose.
 *
 * Anything that runs *inside* a distro may have to start it first, and a cold
 * WSL2 distro takes seconds — it is a virtual machine booting. A tighter
 * timeout would turn "your distro was asleep" into "Claude Code is not
 * installed", which is the exact silent-downgrade this whole module exists to
 * stop.
 */
export const IN_DISTRO_TIMEOUT_MS = 30_000

/** stdout of a distro list is a few hundred bytes; a login shell can be chatty. */
const MAX_OUTPUT_BYTES = 1024 * 1024

export const execWsl: WslExec = (args, timeoutMs) =>
  new Promise((resolve) => {
    execFile(
      WSL_EXE,
      [...args],
      // `encoding: 'buffer'` is load-bearing, not tidiness — see `decodeWslOutput`.
      { encoding: 'buffer', timeout: timeoutMs, maxBuffer: MAX_OUTPUT_BYTES, windowsHide: true },
      (error, stdout, stderr) => {
        const out = Buffer.isBuffer(stdout) ? stdout : Buffer.from(String(stdout))
        const err = Buffer.isBuffer(stderr) ? stderr : Buffer.from(String(stderr))
        if (!error) {
          resolve({ ok: true, stdout: out, stderr: err, code: 0 })
          return
        }
        // `code` is `'ENOENT'` when `wsl.exe` is not on the machine at all and a
        // number when it ran and refused. Both spellings matter and both are on
        // the error already — `ExecFileException` is an `ErrnoException` too —
        // so nothing has to be narrowed by hand.
        resolve({ ok: false, stdout: out, stderr: err, code: error.code ?? null })
      },
    )
  })

/**
 * `wsl.exe` writes **UTF-16LE**, and this is the single most likely way this
 * module breaks.
 *
 * Every other command in this codebase — `which`, `where.exe`, `netstat`,
 * `pmset` — writes bytes that are ASCII either way, so `execFile`'s default
 * utf8 decoding has always been invisible. `wsl.exe` is not one of those: read
 * as utf8 its output is `U\0b\0u\0n\0t\0u\0`, which passes straight through a
 * `split('\n')` and matches no pattern anyone would write, so the app would
 * report "no distributions" on a machine with four. It is the same class of bug
 * as `PATH` vs `Path`, and it is handled here rather than bet on.
 *
 * Sniffed rather than assumed, in this order:
 *
 *  1. a UTF-16LE byte-order mark, which `wsl.exe` usually emits;
 *  2. failing that, NUL bytes in the even-length prefix — UTF-16LE ASCII is
 *     every other byte zero, and real utf8 output never contains a NUL.
 *
 * The sniff matters because `wsl.exe` is not consistent: some subcommands and
 * some Windows builds write plain ANSI, and decoding *those* as UTF-16 produces
 * the same unusable mush in the other direction.
 */
export function decodeWslOutput(buffer: Buffer): string {
  if (buffer.length === 0) return ''
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) {
    return buffer.subarray(2).toString('utf16le')
  }
  const sample = buffer.subarray(0, Math.min(buffer.length, 512))
  let zeros = 0
  for (let i = 1; i < sample.length; i += 2) if (sample[i] === 0) zeros += 1
  // Half the sampled odd bytes being NUL is not something utf8 text does.
  if (zeros > 0 && zeros * 2 >= Math.floor(sample.length / 2)) {
    // An odd trailing byte would make `toString('utf16le')` drop it; there is no
    // such thing as a half code unit, so trimming is the honest read.
    const even = buffer.length - (buffer.length % 2)
    return buffer.subarray(0, even).toString('utf16le')
  }
  return buffer.toString('utf8')
}

/* ---------------------------------------------------------------- parsing -- */

/**
 * Distros that exist to hold a container runtime and are not places to work.
 *
 * This matters more than it sounds. Installing Docker Desktop registers
 * `docker-desktop` (and, on older versions, `docker-desktop-data`) as WSL
 * distributions, and on a machine with no other distro Docker's is the one
 * `wsl.exe` marks default. Adopting it would start every session inside a
 * container appliance whose shell is a busybox with no home directory —
 * technically a running session, and completely useless.
 *
 * `docker-desktop-data` is worse still: it has no init and no shell at all.
 *
 * Filtering by name is a heuristic and is admitted as one. It is the only signal
 * available — nothing in `wsl.exe -l -v` says "this is an appliance" — and the
 * cost of being wrong is one distro missing from a picker, against the cost of
 * not filtering, which is the default choice being a container.
 */
export const APPLIANCE_DISTROS: readonly string[] = [
  'docker-desktop',
  'docker-desktop-data',
  'rancher-desktop',
  'rancher-desktop-data',
  'podman-machine-default',
]

export function isApplianceDistro(name: string): boolean {
  return APPLIANCE_DISTROS.includes(name.toLowerCase())
}

/**
 * Parse `wsl.exe -l -v`.
 *
 * The output looks like this, with the default marked by `*`:
 *
 *     ```
 *       NAME            STATE           VERSION
 *     * Ubuntu          Running         2
 *       Debian          Stopped         2
 *     ```
 *
 * ## Why the columns are measured rather than tokenised
 *
 * Everything printed here is **localised**. A German Windows prints
 * `NAME / STATUS / VERSION` as the header and `Wird ausgeführt` — two words —
 * as the state, so neither the header words nor "the state is one token" holds
 * anywhere but on an English machine. Splitting on whitespace reads that row as
 * a distribution called `Ubuntu Wird`.
 *
 * What *is* stable is the layout: `wsl.exe` pads three columns to a width it
 * computes from the longest value, so the header’s own token offsets are where
 * every data row’s fields begin. Measuring them costs one line and is the only
 * reading of this table that does not depend on the machine’s language.
 *
 * The whitespace split is kept as a fallback for a line the columns cannot
 * explain — and it is also what rejects a stray line, because a row whose last
 * field is not a number is not a row.
 *
 * ## Why STATE is parsed but not trusted for `running`
 *
 * Same reason again. The word is read so a caller *can* see it, but
 * {@link readWsl} decides `running` from `wsl.exe -l --running -q`, which prints
 * names and nothing translatable.
 */
export function parseDistroTable(text: string): Array<WslDistro & { state: string }> {
  const lines = text
    .split(/\r?\n/)
    // A NUL here is the wreckage of a bad decode, and dropping it means one
    // mistake produces empty rows rather than rows with invisible characters in
    // the middle of a distribution name.
    .map((line) => line.replace(/\u0000/g, '').trimEnd())
    .filter((line) => line.trim() !== '')
  if (lines.length === 0) return []

  // The header is the first non-empty line, whatever language it is in. Its
  // three token offsets are the column starts for every row below it.
  const columns = [...lines[0].matchAll(/\S+/g)].map((match) => match.index ?? 0)
  const found: Array<WslDistro & { state: string }> = []

  for (const line of lines.slice(1)) {
    // The `*` sits in column zero, to the left of the NAME column.
    const isDefault = line.trimStart().startsWith('*')
    const row = byColumns(line, columns) ?? byTokens(line)
    if (row === null) continue
    found.push({ ...row, running: false, isDefault })
  }
  return found
}

interface DistroRow {
  name: string
  state: string
  version: number
}

/** The reading that works in any language, when the header gave us its widths. */
function byColumns(line: string, columns: readonly number[]): DistroRow | null {
  if (columns.length < 3) return null
  const name = line.slice(columns[0], columns[1]).replace(/^\s*\*/, '').trim()
  const state = line.slice(columns[1], columns[2]).trim()
  const version = Number(line.slice(columns[2]).trim())
  if (name === '' || !isDistroVersion(version)) return null
  return { name, state, version }
}

/** The fallback, for a row that does not line up with the header. */
function byTokens(line: string): DistroRow | null {
  const bare = line.trimStart()
  const tokens = (bare.startsWith('*') ? bare.slice(1) : bare).trim().split(/\s+/)
  if (tokens.length < 3) return null
  const version = Number(tokens[tokens.length - 1])
  if (!isDistroVersion(version)) return null
  const name = tokens.slice(0, tokens.length - 2).join(' ')
  if (name === '') return null
  return { name, state: tokens[tokens.length - 2], version }
}

/** 1 and 2 are the only ones that exist; the range leaves room for a third. */
function isDistroVersion(value: number): boolean {
  return Number.isInteger(value) && value >= 1 && value <= 9
}

/** Parse any `-q` listing: one name per line, nothing else. */
export function parseNameList(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.replace(/\u0000/g, '').trim())
    .filter((line) => line !== '')
}

/* ------------------------------------------------------------------ probe -- */

/**
 * What is installed, and which of it is awake.
 *
 * Two commands rather than one, issued together because neither depends on the
 * other — the same shape `dev-ports.ts` uses for netstat+tasklist. The second is
 * allowed to fail without failing the reading: not knowing whether a distro is
 * running costs a line of copy in the settings pane, and refusing to list any
 * distro over it would cost the entire feature.
 *
 * Nothing here starts a distro. `-l` reads a registry list; a stopped Ubuntu
 * stays stopped, which is why this is safe to run at launch.
 */
export async function readWsl(exec: WslExec): Promise<WslReading> {
  const [listed, running] = await Promise.all([
    exec(['-l', '-v'], LIST_TIMEOUT_MS),
    exec(['-l', '--running', '-q'], LIST_TIMEOUT_MS).catch(
      (): WslRun => ({ ok: false, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0), code: null }),
    ),
  ])

  if (listed.code === 'ENOENT') {
    return { state: 'absent', distros: [], detail: null }
  }

  // Only ever the *error* stream, plus stdout when the command failed. On a
  // successful run stdout's first line is the column header, and reporting
  // "NAME STATE VERSION" to a user as what Windows said would be worse than
  // saying nothing.
  const detail = listed.ok
    ? null
    : (firstSentence(decodeWslOutput(listed.stderr)) ?? firstSentence(decodeWslOutput(listed.stdout)))
  const awake = new Set(parseNameList(decodeWslOutput(running.stdout)))
  const distros: WslDistro[] = parseDistroTable(decodeWslOutput(listed.stdout))
    .filter((entry) => !isApplianceDistro(entry.name))
    .map((entry) => ({
      name: entry.name,
      version: entry.version,
      isDefault: entry.isDefault,
      running: awake.has(entry.name),
    }))

  if (distros.length === 0) {
    // Reached three ways that are one situation to the reader: WSL installed
    // with nothing in it, the feature present but not enabled, and a machine
    // whose only distros are Docker's. All three mean "there is nowhere to run",
    // and `detail` carries Windows' own sentence about which it was.
    return { state: 'no-distros', distros: [], detail }
  }
  return { state: 'ready', distros, detail }
}

/** The first non-empty line, capped, for a message written by somebody else. */
function firstSentence(text: string): string | null {
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim()
    if (trimmed !== '') return trimmed.slice(0, 400)
  }
  return null
}

/**
 * Which distro sessions should use, given what is installed and what was chosen.
 *
 * The stored choice wins **only if it is still installed**. A distro that was
 * unregistered since the choice was made would otherwise make every session fail
 * with `wsl.exe`'s own "There is no distribution with the supplied name", which
 * names a distro the user cannot see anywhere in the app.
 *
 * `null` is a real answer and means "let `wsl.exe` pick": omitting `-d` uses the
 * machine's own default distribution. That is what makes this feature work
 * before anybody has opened settings, and before the probe has finished — see
 * {@link WslLink.targetFor}.
 */
export function chooseDistro(distros: readonly WslDistro[], stored: string | null): string | null {
  if (stored !== null && distros.some((entry) => entry.name === stored)) return stored
  return distros.find((entry) => entry.isDefault)?.name ?? distros[0]?.name ?? null
}

/* ------------------------------------------------------------------ paths -- */

/**
 * Is this a path inside a Linux filesystem?
 *
 * The whole routing decision rests on this one character. A Windows path is
 * `C:\…` or a UNC `\\…`; a Linux path starts with `/`. Nothing else has to be
 * decided, and deliberately: a heuristic that tried to be cleverer (does the
 * folder exist? is it under /home?) would answer differently depending on
 * whether a distro happened to be awake.
 */
export function isLinuxPath(path: string): boolean {
  return path.startsWith('/')
}

/**
 * The `\\wsl.localhost\Ubuntu\home\asad\proj` a Windows API can stat, for a
 * Linux path we already know the distro of.
 *
 * `wsl.localhost` rather than the older `wsl$`: both are served by the same
 * provider and `wsl$` is the legacy spelling, kept working for compatibility.
 * Used for metadata only — never as a working directory. cmd.exe refuses a UNC
 * working directory outright, and even where a UNC cwd is accepted the files
 * would be reached over 9P, which is the crossing this module exists to avoid.
 */
export function wslUncPath(distro: string, linuxPath: string): string {
  const body = linuxPath.replace(/\//g, '\\')
  return `\\\\wsl.localhost\\${distro}${body.startsWith('\\') ? '' : '\\'}${body}`
}

/**
 * The Linux path behind a `\\wsl$\…` or `\\wsl.localhost\…` UNC path.
 *
 * This is what makes the ordinary folder picker usable: Explorer shows the
 * distro in its sidebar, so a person browsing to their project hands the app
 * `\\wsl.localhost\Ubuntu\home\asad\proj` — a real folder, and a path that would
 * then be handed to cmd.exe as a working directory and rejected. Translating it
 * on the way in means the app stores `/home/asad/proj`, which is the path the
 * shell inside the distro will actually use, and the two never disagree.
 *
 * Returns the distro as well, because the path alone cannot say which one it
 * came from and the same `/home/asad` exists in every distro installed.
 */
export function linuxPathFromUnc(path: string): { distro: string; path: string } | null {
  const match = /^[\\/]{2}(wsl\$|wsl\.localhost)[\\/]([^\\/]+)(.*)$/i.exec(path)
  if (!match) return null
  const distro = match[2]
  const rest = match[3].replace(/\\/g, '/')
  if (distro === '') return null
  // `\\wsl.localhost\Ubuntu` on its own is the distro's root.
  const linux = rest === '' ? '/' : rest.startsWith('/') ? rest : `/${rest}`
  // Collapse the doubled separators a hand-typed UNC path can carry, without
  // touching anything else: `normalize` here would be the win32 one and would
  // hand back backslashes.
  return { distro, path: linux.replace(/\/{2,}/g, '/').replace(/(.)\/$/, '$1') }
}

/**
 * A Windows directory that certainly exists, for the process that *is* wsl.exe.
 *
 * node-pty on Windows calls `path.resolve(cwd)` before handing the value to
 * ConPTY (verified by reading `windowsPtyAgent.js` in the installed copy), and
 * `path.win32.resolve('/home/asad/proj')` is `C:\home\asad\proj` — a directory
 * that does not exist, so process creation fails and the tab dies before
 * anything has been printed. The Linux working directory travels in `--cd`
 * instead, and the Windows-side process starts somewhere harmless.
 *
 * `USERPROFILE` first because it is the one directory a user account is
 * guaranteed to be able to read; `SystemRoot` is the fallback that exists even
 * on a broken profile.
 */
export function windowsFallbackCwd(env: Env): string {
  return env.USERPROFILE || env.SystemRoot || win32.sep
}

/* ---------------------------------------------------------- the login shell -- */

/**
 * Quote one argument for a POSIX shell.
 *
 * The command line built below is read by the shell *inside* the distro, so
 * every value in it has to survive that read. Everything ordinary is passed
 * through untouched — a quoted `--continue` is noise in a log nobody can then
 * grep — and anything else is single-quoted, with the one escape single quotes
 * have.
 */
export function shellQuote(value: string): string {
  if (value !== '' && /^[A-Za-z0-9_@%+=:,./-]+$/.test(value)) return value
  return `'${value.replace(/'/g, `'\\''`)}'`
}

/** A command line for the in-distro shell, from a program and its arguments. */
export function shellCommandLine(parts: readonly string[]): string {
  return parts.map(shellQuote).join(' ')
}

/**
 * The script every in-distro command goes through, and the reason it exists.
 *
 * `wsl.exe -d Ubuntu -- claude` does **not** work for the install everybody
 * actually has. A command run that way is `exec`'d with the environment WSL
 * builds — `/etc/environment` plus the interop PATH — and an agent CLI installed
 * through nvm lives under `~/.nvm/versions/node/<version>/bin`, which is put on
 * PATH by `~/.bashrc`. So `claude` is "not found" inside a distro where `claude`
 * at a prompt works perfectly. That is the same deficit `providers.ts` already
 * documents for GUI apps on macOS, one boundary further in, and it gets the same
 * answer: go through the user's own login shell.
 *
 * `-l` and `-i` are both needed, and neither is superstition. Ubuntu's default
 * `~/.profile` sources `~/.bashrc`, and `~/.bashrc` opens with
 *
 *     case $- in *i*) ;; *) return;; esac
 *
 * so a *login but non-interactive* shell returns from it before reaching the nvm
 * block at the bottom. Only `-lic` reads the whole thing. `providers.ts` uses
 * exactly `-lic` on macOS for the same reason.
 *
 * The shell is resolved from the passwd entry rather than named, because naming
 * `bash` is wrong on a distro that has none — Alpine ships ash — and `$SHELL` is
 * not reliably set for a command wsl.exe launches. The chain ends at `/bin/sh`,
 * which every distro has.
 *
 * The command to run arrives as `$1` rather than being interpolated into this
 * text. That is what keeps the quoting one level deep: this script is a constant
 * with no user data in it, and the caller's command is a separate argument that
 * `wsl.exe` hands across whole.
 */
export const LOGIN_SHELL_SCRIPT =
  's=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7); ' +
  '[ -x "$s" ] || s="${SHELL:-/bin/sh}"; ' +
  'if [ -n "$1" ]; then exec "$s" -lic "$1"; fi; ' +
  'exec "$s" -l'

/** `$0` for the script above. Only ever seen in an error message from `sh`. */
const LOGIN_SHELL_NAME = 'wsl-login'

export interface WslLaunch {
  /** Always `wsl.exe`. */
  command: string
  args: string[]
  /**
   * Where the *Windows* process starts. Not the session's folder — see
   * {@link windowsFallbackCwd}.
   */
  hostCwd: string
}

/**
 * The full `wsl.exe` invocation for one session or one probe.
 *
 * `distro: null` omits `-d` and lets `wsl.exe` use the machine's own default.
 * That is not a fallback for a missing answer so much as the correct answer when
 * nobody has chosen: it is what the user gets by typing `wsl` themselves.
 *
 * `inner: ''` runs a bare login shell, which is what the `shell` provider wants
 * and is also what `wsl.exe` does with no command at all — expressed through the
 * same script so that "plain shell" and "shell running an agent" cannot end up
 * being two different environments.
 */
export function wslLaunch(input: {
  distro: string | null
  cwd: string | null
  inner: string
  env: Env
}): WslLaunch {
  const args: string[] = []
  if (input.distro !== null && input.distro !== '') args.push('-d', input.distro)
  // `--cd` takes a Linux path when it starts with `/`, which is the only kind
  // this is ever given. Anything else would be translated by wsl.exe as a
  // Windows path, which is the crossing being avoided.
  if (input.cwd !== null && isLinuxPath(input.cwd)) args.push('--cd', input.cwd)
  /*
   * `-e`, not `--`, and the difference is the whole quoting story.
   *
   * `wsl.exe --` passes the remaining *command line* on to the distribution's
   * default shell, which means the text is parsed a second time by a shell we
   * did not choose. That is two problems at once. The obvious one is quoting:
   * `LOGIN_SHELL_SCRIPT` contains `$(id -un)`, and a first pass through an outer
   * shell would expand it there instead of leaving it for the login shell — an
   * inner command carrying a `$` or a quote would be reinterpreted by whichever
   * shell that machine happens to have. The quieter one is that the outer shell
   * is neither a login nor an interactive one, so it is the shell *without* the
   * user's PATH — the exact deficit this whole launch exists to make up for.
   *
   * `-e` execs the program with the arguments given and no shell in between, so
   * each element below arrives as its own `argv` entry, exactly as written.
   * There is still a login shell in the picture; it is the one the script
   * chooses on the far side, deliberately, rather than one wsl.exe picked.
   */
  args.push('-e', 'sh', '-c', LOGIN_SHELL_SCRIPT, LOGIN_SHELL_NAME, input.inner)
  return { command: WSL_EXE, args, hostCwd: windowsFallbackCwd(input.env) }
}

/* -------------------------------------------------------------------- env -- */

/**
 * `WSLENV`, the only way an environment variable crosses into the distro.
 *
 * WSL does not inherit the Windows environment. A variable is copied across only
 * if `WSLENV` names it, which is why a session started this way would otherwise
 * arrive with no session marker at all — and the marker is how this app tells
 * its own sessions apart from the agent CLI's idea of a nested one.
 *
 * Two flags are used, and the difference is the point:
 *
 *   - **`/u`** — copy on the way in (Windows invoking WSL), value untouched.
 *     Right for a session id or a `TERM`, which mean the same thing on both
 *     sides.
 *   - **`/p`** — the same, and translate the value as a path. Right for a
 *     profile's config directory, which is a real `C:\Users\…` folder that has
 *     to arrive as `/mnt/c/Users/…` or the agent inside the distro writes its
 *     login to a directory that does not exist.
 *
 * A config directory is the one thing here that deliberately stays on the
 * Windows side of the boundary. It is small and read once at startup, unlike a
 * repository, so the crossing costs nothing measurable — and the alternative,
 * silently giving every profile the same in-distro config, is the exact
 * "two logins quietly sharing one directory" failure `startSession` warns about.
 *
 * An existing `WSLENV` is extended, never replaced: it is a user-facing Windows
 * variable and something else may already rely on it.
 */
export function wslEnvBridge(
  env: Env,
  names: { plain?: readonly string[]; paths?: readonly string[] },
): string {
  const entries: string[] = []
  const seen = new Set<string>()

  for (const existing of (env.WSLENV ?? '').split(':')) {
    const trimmed = existing.trim()
    if (trimmed === '') continue
    entries.push(trimmed)
    seen.add(trimmed.split('/')[0])
  }
  const add = (name: string, flags: string): void => {
    if (name === '' || seen.has(name)) return
    seen.add(name)
    entries.push(`${name}/${flags}`)
  }
  for (const name of names.plain ?? []) add(name, 'u')
  for (const name of names.paths ?? []) add(name, 'up')

  return entries.join(':')
}

/* ------------------------------------------------------------- the service -- */

/** Where a session should run, once the folder has been looked at. */
export interface WslTarget {
  /** `null` means "whatever `wsl.exe` calls default". */
  distro: string | null
  /** The Linux working directory, or null for a probe that needs none. */
  cwd: string | null
}

/** The shape the settings pane is drawn from. */
export interface WslSnapshot {
  /** False everywhere but Windows, where the whole question is meaningless. */
  supported: boolean
  state: WslState
  distros: WslDistro[]
  /** What a person picked, or null if nobody has. */
  chosen: string | null
  /** What sessions in a Linux folder actually use. */
  active: string | null
  /** The home directory inside `active`, once something has asked. */
  home: string | null
  detail: string | null
  /** False until the first reading lands, so the pane can say "checking". */
  read: boolean
}

export interface WslStore {
  /** The distro a person chose on this machine, or null. */
  read(): string | null
  /** `null` puts the machine back to WSL's own default. */
  write(distro: string | null): void
}

export interface WslLinkOptions {
  exec?: WslExec
  platform?: Platform
  store: WslStore
}

/**
 * WSL as this app sees it: one reading, one chosen distro, one home directory.
 *
 * A class rather than module state because everything in it is per-machine
 * configuration that a test has to be able to stand up twice in one file with
 * different answers — the same reason `FolderGrants` is a class with its
 * directory injected.
 */
export class WslLink {
  private readonly exec: WslExec
  private readonly platform: Platform
  private readonly store: WslStore

  private reading: WslReading | null = null
  private homeByDistro = new Map<string, string>()
  private inFlight: Promise<WslReading> | null = null

  constructor(options: WslLinkOptions) {
    this.exec = options.exec ?? execWsl
    this.platform = options.platform ?? currentPlatform()
    this.store = options.store
  }

  /** True only where the question can be asked at all. */
  get supported(): boolean {
    return isWindows(this.platform)
  }

  /**
   * Re-read the machine.
   *
   * Concurrent callers share one run: the settings pane opening while the launch
   * probe is still out is the ordinary case, and two `wsl.exe -l -v` at once buys
   * nothing.
   */
  async refresh(): Promise<WslReading> {
    if (!this.supported) {
      this.reading = { state: 'absent', distros: [], detail: null }
      return this.reading
    }
    if (this.inFlight) return this.inFlight
    this.inFlight = readWsl(this.exec)
      .then((reading) => {
        this.reading = reading
        return reading
      })
      .catch((error: unknown) => {
        // A reading that throws must not leave the app unable to start a
        // session: `targetFor` deliberately does not depend on one.
        console.error('[wsl] could not read the installed distributions:', error)
        const failed: WslReading = { state: 'absent', distros: [], detail: null }
        this.reading = failed
        return failed
      })
      .finally(() => {
        this.inFlight = null
      })
    return this.inFlight
  }

  /** The chosen distro, or WSL's own default, or null when nothing is installed. */
  active(): string | null {
    return chooseDistro(this.reading?.distros ?? [], this.store.read())
  }

  /**
   * Where a session in this folder has to run.
   *
   * **This answers without waiting for a reading, and that is deliberate.** A
   * folder that is a Linux path cannot be opened by cmd.exe under any
   * circumstance, so the answer does not depend on what the probe found: it is
   * WSL or it is nothing. Making it depend on the probe would mean a New Session
   * fired in the first second after launch — before `refresh` has come back —
   * would spawn cmd.exe with `C:\home\asad\proj` and die. The distro is then
   * `null` if nothing is known yet, which `wsl.exe` reads as "use the default",
   * which is exactly right.
   */
  targetFor(cwd: string): WslTarget | null {
    if (!this.supported) return null
    if (!isLinuxPath(cwd)) return null
    return { distro: this.active(), cwd }
  }

  /**
   * The target for a question that is not about a folder — "which agents are
   * installed?" asked with nothing else to go on.
   *
   * A machine with a usable distro answers about the distro. That is the honest
   * reading of the question on a machine set up this way: the folders are Linux
   * folders, the sessions run in Linux, and answering about the Windows PATH
   * would grey out an agent that is installed and working.
   */
  defaultTarget(): WslTarget | null {
    if (!this.supported) return null
    if (this.reading?.state !== 'ready') return null
    return { distro: this.active(), cwd: null }
  }

  /**
   * The Linux home directory of the active distro, if it is already known.
   *
   * Synchronous because its caller is: the folder list a phone is sent is built
   * inside a callback that cannot await. Null means "not asked yet or not
   * answerable", and the caller falls back to the Windows home — a real folder,
   * on the wrong side, which is better than a path that resolves to nothing.
   */
  home(): string | null {
    const distro = this.active()
    return distro === null ? null : (this.homeByDistro.get(distro) ?? null)
  }

  /**
   * Ask the distro for `$HOME`, once.
   *
   * Only asked of a distro that is **already running**. Starting a stopped WSL2
   * distro means booting a virtual machine, and doing that at launch — for a
   * value that is only needed when a phone with no folder grants asks for a list
   * — would be this app deciding to spend a user's memory on its own
   * convenience. Once a session has started the distro, the next call gets it.
   *
   * No login shell here: `$HOME` is set by `wsl.exe` itself and needs no rc file,
   * and a login shell would mix any greeting the user's `.bashrc` prints into the
   * answer.
   */
  async resolveHome(): Promise<string | null> {
    const distro = this.active()
    if (distro === null) return null
    const known = this.homeByDistro.get(distro)
    if (known !== undefined) return known
    if (this.reading?.distros.find((entry) => entry.name === distro)?.running !== true) return null

    const args = ['-d', distro, '--', 'sh', '-c', 'printf %s "$HOME"']
    const run = await this.exec(args, LIST_TIMEOUT_MS)
    const home = decodeWslOutput(run.stdout).trim()
    if (!run.ok || !isLinuxPath(home)) return null
    this.homeByDistro.set(distro, home)
    return home
  }

  /** Everything the settings pane draws, in one object. */
  snapshot(): WslSnapshot {
    const reading = this.reading
    return {
      supported: this.supported,
      state: reading?.state ?? 'absent',
      distros: reading?.distros ?? [],
      chosen: this.store.read(),
      active: this.active(),
      home: this.home(),
      detail: reading?.detail ?? null,
      read: reading !== null,
    }
  }

  /**
   * Record the machine's distro. One choice, kept — not a per-session picker.
   *
   * A name that is not installed is refused rather than stored, because a stored
   * name the machine does not have produces a failure at spawn time, in a
   * terminal, naming a distro the settings pane never showed. `null` clears the
   * choice and goes back to WSL's own default.
   */
  choose(distro: string | null): WslSnapshot {
    if (distro === null || distro === '') {
      this.store.write(null)
      return this.snapshot()
    }
    const known = (this.reading?.distros ?? []).some((entry) => entry.name === distro)
    if (known) this.store.write(distro)
    return this.snapshot()
  }
}

/* -------------------------------------------------------------------- ipc -- */

export const WSL_STATUS_CHANNEL = 'wsl:status'
export const WSL_CHOOSE_CHANNEL = 'wsl:choose'

/**
 * The one thing this module needs from Electron's `IpcMain`.
 *
 * Narrowed rather than imported so the registration can be exercised with an
 * ordinary object instead of a cast — this codebase treats a cast as a defect,
 * and `as unknown as IpcMain` in a test is a cast that also throws away the
 * check that the two channel names are the ones the preload calls.
 * Electron's own `IpcMain` satisfies this, so production passes it unchanged.
 *
 * The shape itself now lives in `ipc-seam.ts`: this file, `remote/server.ts` and
 * `remote/machines/ipc.ts` had each written it out separately, and the headless
 * build needs all three to be the same type. The alias stays so every existing
 * caller and test reads the same.
 */
export type IpcInvokeHandlers = InvokeRegistrar

/**
 * Two channels, and no listener for changes.
 *
 * There is nothing to push: the set of installed distributions changes when a
 * person installs one, which is not an event this app can hear and not one worth
 * a timer — see rule 7.9 in the build preferences. The pane asks when it opens,
 * and its Refresh re-asks.
 */
export function registerWslIpc(ipcMain: IpcInvokeHandlers, link: WslLink): void {
  ipcMain.handle(WSL_STATUS_CHANNEL, async (_event, force?: unknown) => {
    if (force === true || !link.snapshot().read) await link.refresh()
    // Best-effort and never blocking the answer on a distro that is asleep.
    await link.resolveHome().catch(() => null)
    return link.snapshot()
  })

  ipcMain.handle(WSL_CHOOSE_CHANNEL, async (_event, distro?: unknown) => {
    const chosen = typeof distro === 'string' && distro !== '' ? distro : null
    const snapshot = link.choose(chosen)
    await link.resolveHome().catch(() => null)
    return { ...snapshot, home: link.home() }
  })
}
