import { describe, expect, it } from 'vitest'
import { argsForSpawn } from './one-conversation'
import { providersFor, withLaunchArgs } from './providers'

/**
 * The command line a session is resumed with, and the one rule the CLI enforces.
 *
 * ## What went wrong, measured rather than reasoned about
 *
 * Claude Code 2.1.237, on this machine, two config directories whose
 * `projects/` are linked to one store — which is exactly what an account switch
 * produces once `shared-projects.ts` has joined the two accounts:
 *
 *     $ CLAUDE_CONFIG_DIR=…/cfgA claude --session-id 5b6e4cd9-… \
 *         -p 'Remember this codeword: PINEAPPLE-7731…'
 *     noted
 *
 *     $ CLAUDE_CONFIG_DIR=…/cfgB claude --session-id 5b6e4cd9-… -p 'What was the codeword?'
 *     Error: Session ID 5b6e4cd9-… is already in use.
 *
 *     $ CLAUDE_CONFIG_DIR=…/cfgB claude --resume 5b6e4cd9-… -p 'What was the codeword?'
 *     PINEAPPLE-7731
 *
 * `--session-id` **declares** an id and the CLI refuses to declare one whose
 * transcript already exists; `--resume` **joins** one. A switch is always the
 * second case, because the transcript it is carrying is the one the outgoing
 * process just wrote. Getting that backwards is not a degraded switch — the
 * replacement prints the error above and exits, and the tab is left empty. That
 * is the whole of *"it's not keeping the conversation history"* on the path
 * built to keep it.
 *
 * Neither half of this file duplicates the decision in `host-core.ts`. Both pin
 * a property that decision *rests on* and which nothing else would notice
 * breaking.
 */

const MAC = { SHELL: '/bin/zsh' }
const RESUMED = '8b1a1a48-14a6-41de-a773-022597c6b96c'

/* ------------------------------------------------ the identity it rests on -- */

/**
 * `host-core.ts` asks *"is this spawn starting a new conversation?"* by
 * comparing the argument list it chose against the resume list by reference:
 *
 *     const namesConversation = provider === 'claude' && chosen !== resumeArgs
 *
 * and only a spawn that answers yes is given `--session-id <new uuid>`. So the
 * reference is load-bearing. If `argsForSpawn` ever handed back a *copy* — a
 * `[...input.resumeArgs]`, a `.slice()`, a filter that happens to change
 * nothing — every resume would compare unequal, be classified as a fresh
 * conversation, and be launched with `--session-id` naming the very id it was
 * resuming. The CLI's answer to that is the error above.
 *
 * A copy is the kind of edit that looks like tidying and passes every test
 * about *contents*. These are about the object.
 */
describe('the array identity that tells a resume from a fresh start', () => {
  const live = [] as const
  const args = ['--start-here'] as const
  const resumeArgs = ['--resume', RESUMED] as const

  it('hands back the resume list itself when the conversation is resumed', () => {
    const chosen = argsForSpawn({
      resume: true,
      resumeArgs,
      args,
      live,
      cwd: '/w/app',
      provider: 'claude',
    })
    expect(chosen).toBe(resumeArgs)
  })

  it('hands back the start list itself when it is a fresh conversation', () => {
    const chosen = argsForSpawn({
      resume: false,
      resumeArgs,
      args,
      live,
      cwd: '/w/app',
      provider: 'claude',
    })
    expect(chosen).toBe(args)
  })

  it('hands back the start list itself when a live session already holds the folder', () => {
    // The guard drops the resume flag here, and the spawn that results really is
    // a fresh conversation — so it must compare unequal to the resume list and
    // get an id of its own.
    const chosen = argsForSpawn({
      resume: true,
      resumeArgs,
      args,
      live: [{ id: 'other', cwd: '/w/app', provider: 'claude', exitCode: null }],
      cwd: '/w/app',
      provider: 'claude',
    })
    expect(chosen).toBe(args)
  })
})

/* --------------------------------------------- the command line it produces -- */

/**
 * The three launch shapes, and the flag that must never appear on any of them.
 *
 * `host-core.ts` builds the named resume as
 * `withLaunchArgs(spec, ['--resume', id], …).spawn.args` rather than by
 * appending to `spec.spawn.args`, for the reason `withLaunchArgs` exists:
 * inside WSL that array is a `wsl.exe` invocation whose last element is a
 * quoted command *line*, and appending there hands `--resume` to the login
 * shell as a positional parameter, where the CLI never sees it — and a
 * replacement that never saw `--resume` starts a new conversation, silently,
 * for the one person whose projects live in Ubuntu.
 */
describe('the argument list a named resume is launched with', () => {
  it('is the resume flag and the id on a POSIX spawn', () => {
    const spec = providersFor('darwin', MAC).claude
    const resume = withLaunchArgs(spec, ['--resume', RESUMED], 'darwin', MAC)
    expect(resume.spawn.command).toBe('claude')
    expect(resume.spawn.args).toEqual(['--resume', RESUMED])
    expect(resume.spawn.args).not.toContain('--session-id')
  })

  it('puts them after the CLI on the Windows command processor, not after cmd', () => {
    const env = { COMSPEC: 'C:\\Windows\\system32\\cmd.exe' }
    const spec = providersFor('win32', env).claude
    const resume = withLaunchArgs(spec, ['--resume', RESUMED], 'win32', env)
    expect(resume.spawn.args).toEqual(['/c', 'claude', '--resume', RESUMED])
    expect(resume.spawn.args).not.toContain('--session-id')
  })

  it('folds them into the shell command line inside a distribution', () => {
    const env = { COMSPEC: 'C:\\Windows\\system32\\cmd.exe', USERPROFILE: 'C:\\Users\\Asad' }
    const target = { distro: 'Ubuntu', cwd: '/home/asad/proj' }
    const spec = providersFor('win32', env, target).claude
    const resume = withLaunchArgs(spec, ['--resume', RESUMED], 'win32', env, target)
    const args = resume.spawn.args
    // Inside the quoted command the login shell runs — the last element — and
    // not trailing after it, where `sh -lic '<cmd>' --resume <id>` would make
    // them the shell's own positional parameters.
    expect(args[args.length - 1]).toBe(`exec claude --resume ${RESUMED}`)
    expect(args.join(' ')).not.toContain('--session-id')
  })

  it('never carries a declared id and a resume on one command line', () => {
    /*
     * The CLI refuses the combination outright — measured on 2.1.237:
     *
     *     $ claude --continue --session-id <uuid> -p '…'
     *     Error: --session-id can only be used with --continue or --resume if
     *            --fork-session is also specified.
     *
     * and `--fork-session` is not a workaround: it copies the conversation into
     * a *new* id, so switching account and back would leave two transcripts
     * holding one conversation. The two flags belong to two different paths and
     * this pins that they are built that way rather than merely used that way.
     */
    const spec = providersFor('darwin', MAC).claude
    const fresh = withLaunchArgs(spec, ['--session-id', 'd203745a-70d6-451b-9357-4ffbf33a1b75'], 'darwin', MAC)
    expect(fresh.spawn.args).not.toContain('--resume')
    expect(fresh.spawn.args).not.toContain('--continue')
  })
})
