/**
 * `git`, run for task workspaces.
 *
 * A separate runner from `git.ts`'s, because that one is for reading — it pins
 * `GIT_OPTIONAL_LOCKS=0` on every call and gives up after eight seconds — and a
 * workspace is made by a write that checks out a whole tree, which in a large
 * repository takes longer than that.
 *
 * Two things the environment could otherwise do are taken away:
 *
 * - Every variable that points git at a particular repository is removed.
 *   `GIT_INDEX_FILE` or `GIT_DIR` inherited from whatever launched this app
 *   would send `git worktree add` at a different index or repository than the
 *   folder it is run in — the user's own checkout among them — and this module
 *   exists to never touch that.
 * - Error text is pinned to English, so the "not a git repository" case can be
 *   told apart from the rest in any locale.
 */

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { currentPlatform, withPath } from '../platform/host'
import { loginPath } from '../providers'

const run = promisify(execFile)

/** A checkout of a large repository is the slow case. */
export const GIT_WRITE_TIMEOUT_MS = 5 * 60 * 1000

const MAX_BUFFER = 16 * 1024 * 1024

/** Variables that choose a repository, an index or an object store for git, instead of the folder it runs in. */
export const REPO_POINTING_VARS = [
  'GIT_DIR',
  'GIT_WORK_TREE',
  'GIT_INDEX_FILE',
  'GIT_COMMON_DIR',
  'GIT_OBJECT_DIRECTORY',
  'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_NAMESPACE',
  'GIT_PREFIX',
] as const

export interface GitOutcome {
  ok: boolean
  stdout: string
  /** git's own words on a failure, trimmed. */
  stderr: string
  /** git itself could not be found. */
  missing: boolean
}

export interface GitCallOptions {
  /** False for a read in a folder an agent may be working in, so the read never takes its index lock. */
  optionalLocks?: boolean
}

export type GitRunner = (cwd: string, args: string[], options?: GitCallOptions) => Promise<GitOutcome>

/** `env` without anything that points git elsewhere, in English, never prompting. */
export function workspaceGitEnv(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const next: NodeJS.ProcessEnv = { ...env, LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0' }
  for (const name of REPO_POINTING_VARS) delete next[name]
  return next
}

/**
 * A runner over `env()`. The app's is {@link runWorkspaceGit}; a test hands in
 * an environment that leaves the machine's own git config out.
 */
export function gitRunner(env: () => Promise<NodeJS.ProcessEnv>): GitRunner {
  return async (cwd, args, options = {}) => {
    const base = workspaceGitEnv(await env())
    if (options.optionalLocks === false) base.GIT_OPTIONAL_LOCKS = '0'
    try {
      const { stdout, stderr } = await run('git', args, {
        cwd,
        env: base,
        timeout: GIT_WRITE_TIMEOUT_MS,
        maxBuffer: MAX_BUFFER,
        windowsHide: true,
      })
      return { ok: true, stdout, stderr: stderr.trim(), missing: false }
    } catch (error) {
      const failure = error as { code?: unknown; stdout?: string; stderr?: string; message?: string }
      return {
        ok: false,
        stdout: failure.stdout ?? '',
        stderr: (failure.stderr || failure.message || 'git failed').trim(),
        missing: failure.code === 'ENOENT',
      }
    }
  }
}

/** git on the login PATH, as every other git call in this app finds it. */
export const runWorkspaceGit: GitRunner = gitRunner(async () =>
  withPath(process.env, await loginPath(), currentPlatform()) as NodeJS.ProcessEnv,
)
