/**
 * A task agent's standing instructions, kept as a file of their own.
 *
 * ## Where, and why a file
 *
 * `<remote>/agent-instructions/<agent id>.md`, beside `task-config.json` — the
 * remote storage folder of the app's data folder in both shells, which is also
 * what `host-core.ts` knows as `storageDir`. One folder, read by two sides: the
 * task settings write it, and the session launch hands its path (Claude Code)
 * or its text (Codex) to the agent's program. Nowhere in a project folder, for
 * the reason `copilot-layer-is-app-side.test.ts` spells out: a file there would
 * be read by every session started in that folder, not just this agent's.
 *
 * A file rather than a field because a file is what the CLIs take, because it
 * can be longer than a settings value should be, and because the owner can open
 * it in their own editor — the settings page reads it back, so the file is the
 * one place the instructions live.
 *
 * ## What never happens
 *
 * The agent id is the only thing that names a file, and it is checked against
 * the same pattern a saved agent's id is, so no path can be smuggled through
 * it. A missing or unreadable file reads as none; a launch that was told to
 * carry one refuses instead (`agent-launch.ts`).
 */

import { existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export const AGENT_INSTRUCTIONS_DIR = 'agent-instructions'

/** Longest instructions file this app writes or launches with. */
export const MAX_INSTRUCTIONS_FILE_CHARS = 32_000

/** A saved agent's id: what `task-config.ts` accepts, and so the only thing that names a file. */
export const AGENT_ID = /^[a-z0-9][a-z0-9-]{0,39}$/

export function isAgentId(value: unknown): value is string {
  return typeof value === 'string' && AGENT_ID.test(value)
}

/** The folder, from the remote storage folder (`task-config.json`'s, `host-core`'s `storageDir`). */
export function instructionsDir(storageDir: string): string {
  return join(storageDir, AGENT_INSTRUCTIONS_DIR)
}

export function instructionsPath(dir: string, agentId: string): string {
  if (!isAgentId(agentId)) throw new Error(`${String(agentId)} is not an agent id.`)
  return join(dir, `${agentId}.md`)
}

/** The file's text, or null when there is none (missing, unreadable, or only blank). */
export function readInstructions(dir: string, agentId: string): string | null {
  let text: string
  try {
    text = readFileSync(instructionsPath(dir, agentId), 'utf8')
  } catch {
    return null
  }
  return text.trim() === '' ? null : text
}

/**
 * Write the file whole, or not at all: a temp file beside it, then a rename, so
 * a launch never reads half of one. Null or blank removes it.
 */
export function writeInstructions(dir: string, agentId: string, text: string | null): void {
  const file = instructionsPath(dir, agentId)
  if (text === null || text.trim() === '') {
    removeInstructions(dir, agentId)
    return
  }
  if (text.length > MAX_INSTRUCTIONS_FILE_CHARS) {
    throw new Error(`The instructions are longer than ${MAX_INSTRUCTIONS_FILE_CHARS} characters.`)
  }
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.tmp`
  writeFileSync(tmp, text.endsWith('\n') ? text : `${text}\n`, { encoding: 'utf8', mode: 0o600 })
  renameSync(tmp, file)
}

export function removeInstructions(dir: string, agentId: string): void {
  try {
    unlinkSync(instructionsPath(dir, agentId))
  } catch {
    /* already gone */
  }
}

/**
 * Reads that are asked for on every settings redraw and every task start,
 * answered from memory until the file changes on disk — so an edit made in
 * another editor is picked up, and an unchanged file is not read twice.
 */
export class InstructionsFiles {
  private readonly seen = new Map<string, { mtimeMs: number; size: number; text: string | null }>()

  constructor(readonly dir: string) {}

  path(agentId: string): string {
    return instructionsPath(this.dir, agentId)
  }

  has(agentId: string): boolean {
    return isAgentId(agentId) && existsSync(this.path(agentId))
  }

  read(agentId: string): string | null {
    if (!isAgentId(agentId)) return null
    const file = this.path(agentId)
    let stat: { mtimeMs: number; size: number }
    try {
      stat = statSync(file)
    } catch {
      this.seen.delete(agentId)
      return null
    }
    const known = this.seen.get(agentId)
    if (known !== undefined && known.mtimeMs === stat.mtimeMs && known.size === stat.size) return known.text
    const text = readInstructions(this.dir, agentId)
    this.seen.set(agentId, { mtimeMs: stat.mtimeMs, size: stat.size, text })
    return text
  }

  write(agentId: string, text: string | null): void {
    this.seen.delete(agentId)
    writeInstructions(this.dir, agentId, text)
  }

  remove(agentId: string): void {
    this.seen.delete(agentId)
    removeInstructions(this.dir, agentId)
  }
}
