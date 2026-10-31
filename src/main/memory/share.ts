import { lstat, mkdir, symlink } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { encodeProjectPath } from '../transcript'
import { realDir } from './spaces'

/**
 * Letting one project folder read another's Claude memory — only when a person
 * asks for it and then says yes.
 *
 * Claude Code reads a project's memory from `<store>/projects/<encoded
 * folder>/memory/`. Two folders remember the same things when the second one's
 * `memory` is a link to the first one's, which is exactly how the sharing this
 * app already finds on disk was made by hand (`spaces.ts`). This is that one
 * act, done for somebody, under three rules:
 *
 *  - **Never on its own.** Nothing in the app calls this without a person's
 *    request in front of it, and the link is made only after the injected
 *    `consent` answers `true` to a question that names both folders and what
 *    changes. Anything else — false, a throw, no answer — changes nothing.
 *  - **Never over something.** A folder that already has memory of its own, or
 *    a link already, is refused rather than replaced: replacing it would throw
 *    away what that folder had learned. Checked again after the yes, because a
 *    question can sit on screen while an agent writes its first memory.
 *  - **Inside one store.** Both folders are in the same account store's
 *    `projects/`; a link from one account's memory into another's is not this.
 *
 * Undoing it is deleting the link, which leaves the memory itself where it was.
 */

export interface ShareMemoryRequest {
  /** One account store's `projects/` folder. */
  projectsDir: string
  /** The project whose memory is shared. */
  from: string
  /** The project that will read it too. */
  to: string
}

export interface ShareQuestion {
  title: string
  detail: string
}

/** Ask the person; true only for an explicit yes. */
export type ShareConsent = (question: ShareQuestion) => Promise<boolean>

export type ShareMemoryResult = { ok: true; link: string; target: string } | { ok: false; message: string }

async function exists(path: string): Promise<boolean> {
  try {
    await lstat(path)
    return true
  } catch {
    return false
  }
}

export async function shareProjectMemory(request: ShareMemoryRequest, consent: ShareConsent): Promise<ShareMemoryResult> {
  const projectsDir = await realDir(request.projectsDir)
  if (projectsDir === null) return { ok: false, message: 'That account has no project history on this machine.' }
  const from = resolve(request.from)
  const to = resolve(request.to)
  if (from === to) return { ok: false, message: 'A folder already reads its own memory.' }

  const target = await realDir(join(projectsDir, encodeProjectPath(from), 'memory'))
  if (target === null) return { ok: false, message: `${from} has no memory to share yet.` }
  const folder = join(projectsDir, encodeProjectPath(to))
  const link = join(folder, 'memory')
  if (await exists(link)) {
    return { ok: false, message: `${to} already has memory of its own. Nothing was changed.` }
  }

  let yes = false
  try {
    yes =
      (await consent({
        title: 'Share this memory?',
        detail:
          `Claude Code sessions in ${to} will read and write the same memory as ${from}, from now on. ` +
          'Nothing is copied or deleted; removing the link later undoes it.',
      })) === true
  } catch {
    yes = false
  }
  if (!yes) return { ok: false, message: 'Not shared. Nothing was changed.' }

  if (await exists(link)) {
    return { ok: false, message: `${to} gained memory of its own while you were asked. Nothing was changed.` }
  }
  await mkdir(folder, { recursive: true })
  await symlink(target, link, process.platform === 'win32' ? 'junction' : 'dir')
  return { ok: true, link, target }
}
