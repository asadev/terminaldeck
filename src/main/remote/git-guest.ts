/**
 * The git a session started from somebody else's device runs with.
 *
 * ## The hole this closes
 *
 * A shell inherits the account it was spawned by. That is the whole of the
 * problem: a session started in a folder granted to a phone runs as the person
 * who owns the machine, so `git push` picks up *their* credential helper, *their*
 * `gh` token and *their* ssh keys, and pushes as them. Nobody chose that. It is
 * simply what a child process is.
 *
 * So a guest session is handed its own git configuration instead of the
 * machine's. Nothing here confines a process — see the honesty section below —
 * but the default path from `git push` to the owner's GitHub account is cut, and
 * cutting it is worth doing on its own, whether or not anything ever answers a
 * credential request.
 *
 * ## Four doors, and all four are shut here
 *
 * Every one of these was measured on the machine this was written on rather than
 * reasoned about, because the obvious version of this file closes one door and
 * leaves the other three open, and a feature that closes three quarters of a
 * credential leak is not a feature.
 *
 * 1. **The credential helper.** `~/.gitconfig` on a Mac that has ever pushed
 *    over HTTPS says `credential.helper = osxkeychain`; Git for Windows puts
 *    `manager` in the *system* config, which redirecting the global one does not
 *    touch. Helpers are tried in order and the first that answers wins, so
 *    adding ours is not enough — the owner's answers first. The fix is an empty
 *    `credential.helper` value, which git treats as "forget every helper
 *    configured so far", followed by ours. Observed: without the empty entry,
 *    `git credential fill` answered with the owner's real token and the helper
 *    below was never even executed.
 * 2. **Everything else in the owner's global config.** `url.<x>.insteadOf` can
 *    silently reroute an HTTPS remote to ssh; `http.<url>.extraHeader` can carry
 *    an `Authorization:` outright; `include.path` can pull in a file that does
 *    either. So the whole file is replaced rather than patched, with
 *    `GIT_CONFIG_GLOBAL`.
 * 3. **`gh`.** `gh auth setup-git` writes a helper into the global config, which
 *    (2) already handles — but `gh` itself reads its own `hosts.yml` and is on
 *    the PATH of every session. `GH_CONFIG_DIR` points it somewhere empty, and
 *    the token environment variables go with it.
 * 4. **ssh.** `git@github.com:` remotes are the common case in a working
 *    checkout, and an ssh remote never asks a credential helper anything: it
 *    uses the agent, or a key sitting in `~/.ssh`. Two answers, and they are
 *    different in kind. GitHub's ssh remotes are **rewritten to HTTPS**, so they
 *    go through the proxy like everything else and the guest's own account is
 *    what pushes. Anything left over gets an `ssh` with no agent and no identity
 *    file, so it fails with `Permission denied (publickey)` instead of quietly
 *    succeeding as the owner.
 *
 * ## Why the settings ride in the environment and not in the file
 *
 * `GIT_CONFIG_COUNT` and its `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` pairs are
 * exactly `git -c`, and `-c` outranks **every** configuration file, including a
 * repository's own `.git/config`. That matters here more than it looks: the
 * folders being granted are the owner's checkouts, and a repository the owner
 * has configured with `credential.helper = osxkeychain` locally would otherwise
 * beat anything written into a global file we control. Verified against git
 * 2.50.1 — with a local helper set in the repository, the environment entries
 * still won and the helper below still ran.
 *
 * The redirected global file is kept anyway, for (2) and for one more thing: it
 * is somewhere for the guest's own `git config --global` to land that is not the
 * owner's. It is written once and never rewritten, so an identity a guest sets
 * survives their next session.
 *
 * ## What this does not do, and no wording anywhere may imply otherwise
 *
 * It is **not a sandbox**. A guest has a shell on somebody else's computer as
 * that person's account. They can read `~/.ssh`, run `ssh` themselves, run
 * `git -c credential.helper=osxkeychain`, or read the owner's `~/.gitconfig` and
 * copy what they find. Every one of those is available to any process that
 * account can start, and none of it is closed by configuration. What this file
 * changes is what happens **by default**, which is what happens in practice.
 * Confinement is separate work and does not exist yet.
 *
 * ## Version floor
 *
 * `GIT_CONFIG_COUNT` needs git 2.31 and `GIT_CONFIG_GLOBAL` needs 2.32, both
 * from 2021. An older git ignores them, which fails **open** — the guest gets
 * the owner's configuration back. That is stated rather than defended: there is
 * no way to detect it from here without shelling out on the spawn path, and the
 * alternative to failing open is a session that cannot run git at all.
 */

import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { BRAND } from '../../shared/brand'
import { currentPlatform, isWindows, type Platform } from '../platform/host'

/**
 * The environment variables this feature owns, named off the brand.
 *
 * Spelled out from `BRAND.id` rather than written as literals for the reason the
 * whole codebase does it, and with one extra consequence here: `redact.ts` treats
 * any variable whose name contains `credential` as a secret, so the key below is
 * folded out of a support bundle by a rule that already exists rather than by one
 * somebody has to remember to add.
 */
const PREFIX = BRAND.id.toUpperCase()

/** Where the loopback endpoint answers. Absent from a session with no proxy. */
export const CREDENTIAL_URL_VAR = `${PREFIX}_CREDENTIAL_URL`

/** This session's key at that endpoint. Environment only; never written to disk. */
export const CREDENTIAL_KEY_VAR = `${PREFIX}_CREDENTIAL_KEY`

/** File name of the helper git is pointed at, inside the guest git directory. */
export const HELPER_FILE = 'askpass.sh'

/** The redirected global config, one per device. */
export const CONFIG_FILE = 'gitconfig'

/**
 * Everything the proxy needs to be reachable from inside a session.
 *
 * Absent is meaningful and is the whole of the "half one ships on its own"
 * promise: with no link the guest still gets an isolated git, and its credential
 * helper list is *empty* — so a push asks nobody, is refused in milliseconds, and
 * cannot reach the owner's login on the way past.
 */
export interface CredentialLink {
  /** `http://127.0.0.1:<port>/credential`. */
  url: string
  /** Per-session secret the helper presents. */
  key: string
  /** Absolute path of the helper script. */
  helper: string
}

export interface GuestGitOptions {
  /** This device's own directory, which is where its global config lives. */
  dir: string
  /** The proxy, when it is running. */
  link?: CredentialLink
  platform?: Platform
}

/**
 * What to change about a session's environment.
 *
 * Two lists, because setting a variable and taking one away are genuinely
 * different operations and only one of them can be expressed by spreading an
 * object. `SSH_AUTH_SOCK` has to *go*: an empty value is not the same as an unset
 * one to every program that reads it, and "the agent is at the empty path" is a
 * different bug from "there is no agent".
 */
export interface GuestGitEnv {
  set: Record<string, string>
  remove: string[]
  /**
   * Which of {@link set}'s names hold a filesystem path.
   *
   * Only one thing reads this and it could not work without it: a session inside
   * WSL is handed the Windows environment through `WSLENV`, which needs to be
   * told, per variable, whether the value is a path it should translate to
   * `/mnt/c/…`. A `GIT_CONFIG_GLOBAL` that crossed untranslated would point git
   * inside Linux at `C:\Users\…`, which it cannot open — so it would read the
   * *default* global config instead, which is the owner's, which is the entire
   * thing this file exists to prevent. Naming them here rather than guessing at
   * the far end keeps that answer with the code that chose the variables.
   */
  paths: string[]
}

/**
 * Environment variables that hand a process somebody's GitHub account.
 *
 * `gh` reads all four, and so does everything built on it. They are removed
 * rather than overwritten because there is nothing honest to overwrite them
 * with — this machine does not hold the guest's token and never will.
 */
const TOKEN_VARS = ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN']

/**
 * Variables that decide *how* git authenticates, inherited from whatever
 * launched this app.
 *
 * A desktop app started from a terminal inside an editor carries that editor's
 * `GIT_ASKPASS`, which is a program that will happily answer a prompt out of the
 * editor's own credential store. `GIT_CONFIG` is the pre-2.32 spelling of "read
 * this file instead of the global one" and would quietly point at the owner's.
 */
const AUTH_VARS = ['GIT_ASKPASS', 'SSH_ASKPASS', 'SSH_AUTH_SOCK', 'GIT_CONFIG', 'GIT_SSH', 'GIT_SSH_COMMAND']

/**
 * An `ssh` with nothing to offer.
 *
 * All three options are needed and each closes a different door: `IdentityAgent`
 * is the agent socket, `IdentityFile` replaces the default `~/.ssh/id_*` list,
 * and `IdentitiesOnly` stops ssh from offering anything it found elsewhere.
 * Checked with `ssh -G` on the machine this was written on — all three come back
 * applied rather than ignored.
 *
 * The null device is spelled per platform because `/dev/null` is not a path
 * Windows has.
 */
function blindSsh(platform: Platform): string {
  const nowhere = isWindows(platform) ? 'NUL' : '/dev/null'
  return `ssh -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile=${nowhere}`
}

/**
 * Quote a path for the shell git runs a helper through.
 *
 * Git always executes a credential helper through a shell, so an absolute path
 * with a space in it — `/Users/x/Application Support/...`, which is exactly where
 * this lands on a Mac — is two arguments unless it is quoted. Single quotes,
 * with the POSIX escape for an embedded one.
 *
 * Backslashes become forward slashes first. On Windows the shell in question is
 * the one git ships, where a backslash inside quotes is an escape character and
 * `C:\Users\x` therefore arrives as `C:Usersx`. Git accepts forward slashes in
 * every path on every platform, so there is nothing to lose by always writing
 * them.
 */
export function shellPath(path: string): string {
  const forward = path.split('\\').join('/')
  return `'${forward.split("'").join(`'\\''`)}'`
}

/**
 * The configuration entries that outrank every file on the machine.
 *
 * Order matters in exactly one place and it is load-bearing: the empty
 * `credential.helper` has to come before ours, because it means "discard the
 * helpers seen so far" and a helper added before it would be discarded too.
 */
export function guestGitConfigEntries(options: GuestGitOptions): Array<[string, string]> {
  const platform = options.platform ?? currentPlatform()
  const entries: Array<[string, string]> = [['credential.helper', '']]

  if (options.link) entries.push(['credential.helper', `!${shellPath(options.link.helper)}`])

  // Without this git decides that one login covers a whole host, and the helper
  // is handed `host=github.com` and nothing else — no repository name, so no way
  // to ask about one and no way to scope an approval to one. It is the single
  // setting that makes per-repository consent possible at all.
  entries.push(['credential.useHttpPath', 'true'])

  // GitHub's ssh remotes, sent the long way round so they arrive at the proxy.
  // Both spellings, because a checkout can carry either and they are different
  // strings to git even though they name the same place.
  entries.push(['url.https://github.com/.insteadOf', 'git@github.com:'])
  entries.push(['url.https://github.com/.insteadOf', 'ssh://git@github.com/'])

  // `core.sshCommand` rather than `GIT_SSH_COMMAND`: the config key overrides the
  // environment variable, so a repository that sets one locally would otherwise
  // win. Everything here is chosen to beat a repository's own configuration,
  // because the repositories being granted belong to the person being protected.
  entries.push(['core.sshCommand', blindSsh(platform)])

  // A commit has to say who made it, and nobody has said yet. Git will not invent
  // an identity from the account name with this set, which turns "committed as
  // the owner of this machine" into an error message that names the fix. The
  // repository's own `user.email`, if it has one, still wins — that is the
  // owner's file in the owner's checkout, and rewriting what a repository says
  // about itself would break their own sessions in the same folder.
  entries.push(['user.useConfigOnly', 'true'])

  return entries
}

/**
 * The seed for a device's own global git config.
 *
 * Deliberately almost empty. Its job is to *replace* the owner's file, not to be
 * a good one — anything added here would be this app deciding how somebody
 * else's git behaves. Written once, then left alone so that a `git config
 * --global user.email` a guest runs is still there next time.
 */
export function guestGitConfigText(): string {
  return [
    `# Written by ${BRAND.name} for a session started from another device.`,
    '# It stands in for the global git config so that this session cannot read',
    '# the login of the account that owns this machine. Yours to edit.',
    '',
    '[user]',
    '\tuseConfigOnly = true',
    '',
  ].join('\n')
}

/**
 * The helper itself, in POSIX shell.
 *
 * ## Why it is a shell script and not a program
 *
 * It has to be something git can execute on a machine where this app is a
 * packaged Electron bundle, without adding a build artefact and without assuming
 * anything is installed. Git runs every credential helper through a shell — its
 * own bundled one on Windows — so one POSIX script covers all three platforms,
 * and `curl` is the one program that is already there on all three: `/usr/bin/curl`
 * on macOS, in the shell git ships on Windows, and on any Linux with git.
 *
 * ## Why it holds no secret
 *
 * The endpoint's address and this session's key both arrive in the environment,
 * so the file on disk is identical for every session and every device and is
 * worth nothing to anyone who reads it. The alternative — baking a token into the
 * script — would put a live secret in a file for a feature whose entire promise
 * is that no secret is written to this machine.
 *
 * ## The three hats, and why two of them refuse
 *
 * Git calls a credential helper with `get`, `store` or `erase`. Only `get` is
 * answered. `store` **exits without doing anything**, and that is the feature:
 * it is git offering to save the credential on this machine, and the answer is
 * no, every time. `erase` has nothing to erase.
 *
 * Anything else is git in its *other* mode — `GIT_ASKPASS`, where the argument is
 * a prompt like `Password for 'https://github.com'` and there is no repository
 * name anywhere in it. That is refused, because an answer with no repository is
 * consent to a push against anything on the host, which is the one thing the
 * approval model exists to prevent.
 *
 * It refuses **silently**, and that was measured rather than assumed. Git only
 * reaches the askpass path *after* a credential helper has already declined, so
 * by the time this branch runs the useful sentence — "your device isn't
 * reachable", "that push was refused on your device" — has already been printed
 * by the `get` branch above. An explanation here is therefore always the
 * *second* one, about a different thing, and it read as a contradiction:
 *
 *     Your device isn't reachable — open the app to approve this push.
 *     This session cannot answer a prompt that does not name a repository.
 *     error: unable to read askpass response from '…/askpass.sh'
 *
 * The middle line is the only one nobody can act on. Silence leaves git's own
 * two lines, which say what git did, under ours, which says what to do.
 */
export function askpassScript(): string {
  return `#!/bin/sh
# ${BRAND.id}-askpass — forwards a git credential request to the device that owns it.
# Generated; edits are overwritten. Holds no secret: the address and the key for
# this session both arrive in the environment.
case "$1" in
  get) ;;
  store|erase)
    # Nothing about somebody else's login is written to this machine.
    exit 0 ;;
  *)
    # The askpass hat. A prompt names a host and never a repository, so there is
    # nothing here that could be asked of anybody. Silent on purpose: git only
    # gets here after the branch above has already printed the real reason.
    exit 1 ;;
esac

if [ -z "\${${CREDENTIAL_URL_VAR}}" ] || [ -z "\${${CREDENTIAL_KEY_VAR}}" ]; then
  echo "This session has no way to reach your device for a GitHub login." >&2
  exit 1
fi

CURL=/usr/bin/curl
[ -x "$CURL" ] || CURL=curl

# --max-time has to outlast the desk's own deadlines, or curl gives up first and
# the person reads a timeout from the wrong layer. The desk answers every request
# it is holding; this is only here so a lost reply cannot wedge a git forever.
answer=$("$CURL" -s --max-time 180 \\
  -H "x-${BRAND.id}-credential: \${${CREDENTIAL_KEY_VAR}}" \\
  -H "x-${BRAND.id}-pid: $$" \\
  --data-binary @- "\${${CREDENTIAL_URL_VAR}}") || {
  echo "This session could not reach the app on this machine for a GitHub login." >&2
  exit 1
}

# A leading '!' marks a sentence for the person, not an answer for git. Git reads
# stdout as credential fields, so the two cannot share it.
case "$answer" in
  '!'*)
    printf '%s\\n' "\${answer#!}" >&2
    exit 1 ;;
esac

printf '%s\\n' "$answer"
`
}

/**
 * Where a device's guest git files live.
 *
 * Per device rather than per session or per app, and each of those is a decision.
 * Per app would mean two guests sharing one global config, so the identity one of
 * them sets becomes the other's. Per session would mean a new directory on every
 * spawn, so nothing a guest configures survives their own next session, and a
 * folder of litter besides.
 */
export function guestGitDir(root: string, deviceKey: string): string {
  return join(root, deviceKey)
}

/**
 * Put the files in place and answer with the environment for the session.
 *
 * The config is written **only when it is not already there**; the helper is
 * written every time. That asymmetry is the point: the config belongs to the
 * guest once it exists, and the helper belongs to this app and must match the
 * code that is running.
 */
export function prepareGuestGit(options: GuestGitOptions): GuestGitEnv {
  const configFile = join(options.dir, CONFIG_FILE)
  mkdirSync(options.dir, { recursive: true, mode: 0o700 })
  if (!existsSync(configFile)) writeFileSync(configFile, guestGitConfigText(), { mode: 0o600 })
  if (options.link) {
    // Written beside the config rather than inside it, so that one script serves
    // every device and there is exactly one file to keep in step with this code.
    writeFileSync(options.link.helper, askpassScript(), { mode: 0o700 })
  }
  return guestGitEnv({ ...options, configFile })
}

/**
 * The environment, with nothing written and nothing read.
 *
 * Split from {@link prepareGuestGit} so the interesting half is a pure function
 * of its arguments: what a guest session's git is told is the thing worth pinning
 * in a test, and a test that has to make directories to ask the question is a
 * test that will one day be skipped.
 */
export function guestGitEnv(options: GuestGitOptions & { configFile: string }): GuestGitEnv {
  const entries = guestGitConfigEntries(options)
  const set: Record<string, string> = {
    GIT_CONFIG_GLOBAL: options.configFile,
    GIT_CONFIG_COUNT: String(entries.length),
    // Belt and braces with the helper's own refusal above: with no helper able to
    // answer, git's last resort is the terminal, and the session *has* a terminal.
    // A prompt there would be answered by whoever is at the keyboard on the far
    // end, about a repository the prompt does not name.
    GIT_TERMINAL_PROMPT: '0',
    // `gh` keeps its token in its own directory and reads it whatever git is
    // configured to do. Pointed somewhere empty rather than removed, because
    // unsetting it leaves the default — the owner's.
    GH_CONFIG_DIR: join(options.dir, 'gh'),
  }
  for (const [index, [key, value]] of entries.entries()) {
    set[`GIT_CONFIG_KEY_${index}`] = key
    set[`GIT_CONFIG_VALUE_${index}`] = value
  }

  const paths = ['GIT_CONFIG_GLOBAL', 'GH_CONFIG_DIR']

  const remove = [...TOKEN_VARS, ...AUTH_VARS]
  if (options.link) {
    set[CREDENTIAL_URL_VAR] = options.link.url
    set[CREDENTIAL_KEY_VAR] = options.link.key
    // The same script in git's other hat. It refuses every prompt that names no
    // repository, which is all of them here — what it buys is that the refusal is
    // a sentence in the session rather than a bare "terminal prompts disabled".
    set.GIT_ASKPASS = options.link.helper
    set.SSH_ASKPASS = options.link.helper
    paths.push('GIT_ASKPASS', 'SSH_ASKPASS')
  }

  return { set, paths, remove: remove.filter((name) => set[name] === undefined) }
}
