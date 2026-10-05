/**
 * A task agent's standing instructions, on its session's command line.
 *
 * `host-core.ts` asks this once per start that carries an agent id
 * (`CreateSessionInput.agentInstructions`), with the provider the session
 * actually became — never the one that was asked for, because an agent that
 * fell back to another must not be started as if it were the first.
 *
 * ## Per agent, as the capability table says
 *
 *  - Claude Code: `--append-system-prompt-file <file>` — the path, so the file
 *    is read by the CLI itself and what the owner opens is what it was told.
 *    The flag is spelled once, in `copilot-layer.ts`, and imported from there.
 *  - Codex: `-c developer_instructions="<text>"` — the text, as a TOML string;
 *    Codex has no file form that adds rather than replaces.
 *  - Anyone else: refused. The engine only sends an id for an agent whose row
 *    says `enforced`, so reaching here means the session fell back to another
 *    agent, and starting that one without what it was given is the silent
 *    downgrade this app refuses everywhere else.
 *
 * Inside WSL it is refused too: the file is on this side of the boundary and
 * the Linux process could not open its path.
 *
 * Claude Code records the system prompt with a conversation the first time it
 * is sent (`--system-prompt-snapshot`, on by default), so a resumed
 * conversation may keep the instructions it began with. The brief restates the
 * current ones on every start for that reason (`task-engine.ts`'s `stackOf`).
 */

import { APPEND_SYSTEM_PROMPT_FILE } from '../copilot-layer'
import { isWindows, type Platform } from '../platform/host'
import { enforces, familyOf } from '../../shared/agent-capabilities'
import { InstructionsFiles, instructionsDir, isAgentId, MAX_INSTRUCTIONS_FILE_CHARS } from './agent-instructions'

/**
 * Room left for one argument on a Windows command line. Codex is launched there
 * through `%COMSPEC% /c`, whose whole line stops at 8191 characters.
 */
export const WINDOWS_ARG_ROOM = 7_000

export interface InstructionLaunch {
  /** The provider the session is starting as. */
  provider: string
  /** `CreateSessionInput.agentInstructions`, unchecked. */
  agentId: unknown
  /** `host-core`'s `storageDir`: the remote storage folder the task settings write into. */
  storageDir: string
  platform: Platform
  /** The session runs inside a WSL distribution. */
  insideWsl: boolean
  /** For tests: the files, read through one cache. */
  files?: InstructionsFiles
}

/** The arguments that hand the agent its instructions, or a sentence saying why it cannot start. */
export function instructionLaunchArgs(launch: InstructionLaunch): string[] {
  if (!isAgentId(launch.agentId)) throw new Error(`${String(launch.agentId)} is not a task agent id.`)
  const family = familyOf(launch.provider)
  if (!enforces(launch.provider, 'instructions')) {
    throw new Error('This coding agent cannot be given standing instructions at the start, so the task agent was not started on it.')
  }
  if (launch.insideWsl) {
    throw new Error('A task agent’s instructions file cannot reach a session inside WSL, so it was not started there.')
  }
  const files = launch.files ?? new InstructionsFiles(instructionsDir(launch.storageDir))
  const text = files.read(launch.agentId)
  if (text === null) {
    throw new Error(`The instructions file for ${launch.agentId} is missing or empty (${files.path(launch.agentId)}). Save the agent’s instructions again, or clear them.`)
  }
  if (text.length > MAX_INSTRUCTIONS_FILE_CHARS) {
    throw new Error(`The instructions file for ${launch.agentId} is longer than ${MAX_INSTRUCTIONS_FILE_CHARS} characters. Shorten it.`)
  }
  if (family === 'claude') return [APPEND_SYSTEM_PROMPT_FILE, files.path(launch.agentId)]
  const setting = `developer_instructions=${tomlString(text)}`
  if (isWindows(launch.platform) && setting.length > WINDOWS_ARG_ROOM) {
    throw new Error(`On Windows, Codex takes instructions of at most about ${WINDOWS_ARG_ROOM} characters on its command line. Shorten them.`)
  }
  return ['-c', setting]
}

/**
 * A TOML basic string. Codex parses a `-c` value as TOML and, when that fails,
 * takes the raw text — quotes included — so an escape missed here would not
 * error, it would hand the agent different instructions. TOML refuses raw
 * control characters (all but tab) and DEL, and any `\u` escape of a lone
 * surrogate; JSON's escaping covers neither of the last two. A lone surrogate
 * cannot be written at all, so it becomes U+FFFD, as a UTF-8 file would.
 */
export function tomlString(text: string): string {
  let out = '"'
  // `for…of` walks code points, so a surrogate seen alone here has no partner.
  for (const char of text) {
    const code = char.codePointAt(0) ?? 0
    if (code >= 0xd800 && code <= 0xdfff) out += '�'
    else if (char === '"') out += '\\"'
    else if (char === '\\') out += '\\\\'
    else if (char === '\n') out += '\\n'
    else if (char === '\r') out += '\\r'
    else if (char === '\t') out += '\\t'
    else if (code < 0x20 || code === 0x7f) out += `\\u${code.toString(16).padStart(4, '0')}`
    else out += char
  }
  return `${out}"`
}
