/**
 * The one question a phone cannot answer, answered before it is asked.
 *
 * ## What strands a first run, measured rather than reasoned about
 *
 * A copilot run is a Claude CLI in a pty, and the CLI puts a modal up before
 * anything else when it is started in a directory it has no record of:
 *
 *     Quick safety check: Is this a project you created or one you trust?
 *     ❯ 1. Yes, I trust this folder
 *       2. No, exit
 *       Enter to confirm · Esc to cancel
 *
 * Nothing on the phone can see it. `copilot.chat` is built from the run's
 * *transcript*, and a run parked on that modal has never written one — so the
 * phone shows an empty conversation, `copilot.say` types a sentence into a
 * screen that is not a prompt, and the person waits out `SAY_TIMEOUT_MS` for an
 * answer that cannot come. On a machine where the copilot has never been started
 * at the desk, that is *every* run, forever.
 *
 * ## Why this is not the app deciding something on the person's behalf
 *
 * The folder is the copilot's own — `copilotPaths().root`, which this app
 * created inside its own `userData` and filled with its own generated
 * `CLAUDE.md`, `memory/` and action log — or a folder the person picked
 * themselves, at this machine, in Settings → Copilot. Both are the same act the
 * dialog is asking about, already performed, at the desk, by the person. What
 * the dialog adds for a phone is not a decision; it is a dead end.
 *
 * Two rules keep it that way, and they are the whole of the caution here:
 *
 *  - **Only the copilot's own working directory.** Never a project folder, never
 *    anything a session might be started in. This function takes one path and
 *    its callers pass the copilot root.
 *  - **Never over an answer that already exists.** A person who chose *No, exit*
 *    has `hasTrustDialogAccepted: false` recorded, and that is a decision. This
 *    writes only where the CLI has no record of the folder at all.
 *
 * ## What the CLI actually reads, which is not what it looked like
 *
 * Measured against `claude 2.1.237` on 2026-08-20 by spawning it in a fresh
 * directory with a fresh `CLAUDE_CONFIG_DIR` and reading the screen back out of
 * the pty:
 *
 *  - `{ projects: { <cwd>: { hasTrustDialogAccepted: true } } }` in
 *    `<configDir>/.claude.json` suppresses the modal. `allowedTools` and the
 *    other six keys the CLI writes alongside it are not needed for this.
 *  - **The key must be the resolved path.** The first three attempts at this
 *    failed and looked like the flag not working: `os.tmpdir()` answers
 *    `/var/folders/…`, the CLI files the same directory under
 *    `/private/var/folders/…`, and the two do not match as strings. On his Mac
 *    the copilot root is under `~/Library/Application Support` and has no
 *    symlink in it, so this would have worked by luck — which is exactly the
 *    kind of thing that stops working on somebody else's machine. `realpathSync`
 *    is why it is recorded correctly rather than by luck.
 *
 * A record the CLI does not recognise costs nothing: the modal comes back, which
 * is the state this fixes rather than a new failure. So every error here is
 * swallowed to a boolean and no run is refused over it.
 */

import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/** Where the CLI keeps per-folder decisions, inside whichever config dir is in play. */
export function claudeConfigFile(configDir: string): string {
  return join(configDir, '.claude.json')
}

/**
 * What one call did, so a caller can log it and a test can pin it.
 *
 * `already` and `refused` are deliberately different from `recorded`: the first
 * two mean the file already holds a decision, and the difference between them is
 * whether the copilot is about to start or about to sit on a modal that a person
 * at the desk said no to.
 */
export type TrustOutcome = 'recorded' | 'already' | 'refused' | 'failed'

/**
 * Record that the copilot's own folder is trusted, unless something already says.
 *
 * Returns what it found rather than throwing. A configuration file that cannot
 * be read or written is a copilot that shows a modal — worse, and not worth
 * refusing a run over.
 */
export function trustCopilotFolder(configDir: string, folder: string): TrustOutcome {
  let resolved: string
  try {
    // The path as the CLI will file it. See the note above: a `/var` that is
    // really `/private/var` is a record under a key nothing ever matches.
    resolved = realpathSync(folder)
  } catch {
    resolved = folder
  }

  const file = claudeConfigFile(configDir)
  let config: Record<string, unknown> = {}
  try {
    const raw = readFileSync(file, 'utf8')
    const parsed: unknown = JSON.parse(raw)
    // A file that is not an object is one this app did not write and does not
    // understand. Replacing it would throw away somebody's whole configuration
    // to remove one dialog.
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return 'failed'
    config = parsed as Record<string, unknown>
  } catch (error) {
    // ENOENT is the ordinary case for a managed profile that has never been run,
    // and an empty object is the right thing to build on. Anything else — a
    // permission error, a torn file — is a state this must not paper over by
    // writing a fresh config over the top of it.
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') return 'failed'
  }

  const projects = config.projects
  const table: Record<string, unknown> =
    typeof projects === 'object' && projects !== null && !Array.isArray(projects)
      ? (projects as Record<string, unknown>)
      : {}

  const existing = table[resolved]
  if (typeof existing === 'object' && existing !== null && !Array.isArray(existing)) {
    const record = existing as Record<string, unknown>
    if (record.hasTrustDialogAccepted === true) return 'already'
    // A person answered *No, exit*, at this machine. That is a decision and it
    // is not this function's to reverse — the phone gets the modal it cannot
    // answer, and the sentence on the desktop is where that gets fixed.
    if (record.hasTrustDialogAccepted === false) return 'refused'
  }

  const next = {
    ...config,
    projects: {
      ...table,
      [resolved]: {
        ...(typeof existing === 'object' && existing !== null && !Array.isArray(existing) ? existing : {}),
        hasTrustDialogAccepted: true,
      },
    },
  }

  try {
    mkdirSync(dirname(file), { recursive: true })
    /*
     * Written beside and renamed over, never in place.
     *
     * This file is the CLI's own and may be the person's real `~/.claude.json`
     * with a hundred projects in it. A partial write there is not a lost dialog,
     * it is a Claude Code that will not start — and the CLI reads it at launch,
     * which is exactly when this app is most likely to be writing it.
     */
    const scratch = `${file}.deck-${process.pid}`
    writeFileSync(scratch, `${JSON.stringify(next, null, 2)}\n`, 'utf8')
    renameSync(scratch, file)
    return 'recorded'
  } catch {
    return 'failed'
  }
}
