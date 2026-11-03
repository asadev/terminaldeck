/**
 * The agents somebody added, on this machine's disk.
 *
 * ## What this owns and what it does not
 *
 * `shared/custom-agents.ts` holds the shapes, the splitter and the validation —
 * everything both sides need to agree about, so that the form previewing what it
 * parsed and the store writing what it parsed cannot disagree. This file is the
 * half that can only run here: the file on disk, and the one check the renderer
 * is not allowed to make.
 *
 * That check is the whole point of the module. The catalogue's rule has no
 * exceptions — *never declare an agent that has not been launched* — and a form
 * that took any string would drive straight through it, putting a row in the
 * picker that dies on selection. So the command is resolved against the user's
 * **login** PATH before anything is written, and a draft whose command cannot be
 * found is refused with the sentence the lookup produced. `loginPath` rather
 * than this process's PATH is not a detail: a GUI app on macOS inherits a
 * minimal one, so half the machine is invisible to it, and refusing an agent
 * that is installed and working would be the same lie in the other direction.
 *
 * ## Why it is not in `state.json`
 *
 * `store.ts` holds preferences, the project list and the open-session ledger —
 * three things the app rewrites constantly, the last of them on every session
 * open and close. This is a list a person edits by hand a few times ever, and it
 * decides what gets executed. A corrupt write to a file that busy costs a
 * preference; here it would cost the definition of a program the app spawns. Its
 * own file also means one bad entry is one bad entry: `parseCustomAgents` drops
 * what it cannot read and keeps the rest, which cannot be done inside a document
 * whose other keys are the app's state.
 *
 * ## Why it lives on the core rather than beside the IPC
 *
 * `createHostCore` builds it, so the headless build has the same agents as the
 * window. A session started from a phone goes through the same `startSession`,
 * and an agent that existed only in the Electron shell would be a picker row on
 * the desktop and a silent fall back to a plain shell from anywhere else — the
 * exact class of divergence `host-core.ts` was split out to prevent.
 */

import { execFile } from 'node:child_process'
import { accessSync, constants, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { AGENT_ENTRIES } from '../shared/agent-catalog'
import {
  CUSTOM_PROVIDER_PREFIX,
  customAgentId,
  draftIsValid,
  isCustomProviderId,
  parseCustomAgents,
  parseDraft,
  splitArgs,
  validateDraft,
  type CustomAgent,
  type CustomAgentProblems,
} from '../shared/custom-agents'
import { currentPlatform, isWindows, withPath, type Env, type Platform } from './platform/host'
import { firstLookupPath, lookupSpec } from './platform/lookup'
import { loginPath } from './providers'

const run = promisify(execFile)

/** The file, in `<userData>` beside `state.json`. */
export const CUSTOM_AGENTS_FILE = 'custom-agents.json'

/** Written so a later format can tell itself apart from this one. */
const FORMAT_VERSION = 1

/**
 * How many agents one machine may add.
 *
 * A bound on a file the app reads at every session start rather than a judgement
 * about how many agents anybody needs — thirty-two rows is already a picker
 * nobody scrolls to the end of, and the seven CLIs the catalogue header lists as
 * measured-but-undeclared are the realistic upper end of what somebody adds.
 */
export const MAX_CUSTOM_AGENTS = 32

/** Larger than the cap can produce; a file past it is not this app's. */
const MAX_FILE_BYTES = 256 * 1024

/** How long a `which`/`where.exe` may take before it counts as not found. */
const LOOKUP_TIMEOUT_MS = 5000

/**
 * What `add` answers.
 *
 * Problems keyed by field rather than one sentence, because the form draws them
 * under the field they belong to and a single string would have to be parsed
 * back apart to do that. The `command` key is where a failed lookup lands, which
 * is why this shape is the same one `validateDraft` returns: from the form's
 * point of view "you typed a name with a pipe in it" and "there is no such
 * program on this machine" are the same kind of answer about the same field.
 */
export type AddAgentOutcome =
  | { ok: true; agent: CustomAgent }
  | { ok: false; problems: CustomAgentProblems }

/**
 * Where a command resolves on this machine, or nothing.
 *
 * A dependency rather than a call, so the store can be tested against a machine
 * that has no agents installed and against one that has. The default below is
 * the real lookup.
 */
export type CommandLookup = (command: string) => Promise<string | null>

interface StoredState {
  version: number
  agents: unknown[]
}

/**
 * What Windows runs when it is handed a file name, if `PATHEXT` says nothing.
 *
 * The four the OS itself falls back to. Longer real-world values add script
 * hosts (`.VBS`, `.JS`, `.WSF`), and those are honoured when the machine names
 * them — this constant is only the floor for an environment that arrived
 * without the variable, which is what a stripped service environment looks
 * like.
 */
const DEFAULT_PATHEXT = '.COM;.EXE;.BAT;.CMD'

/**
 * Would Windows execute a file with this name?
 *
 * Read case-insensitively out of the environment for the reason `platform/
 * host.ts` gives about `PATH`: a Windows environment object copied with a
 * spread keeps whatever spelling the OS used, and `PATHEXT` is spelled that way
 * in `process.env` while a hand-written test environment is not. Missing
 * entirely falls back to {@link DEFAULT_PATHEXT} rather than to "anything
 * goes"; an environment with no `PATHEXT` is a stripped one, not a permissive
 * one.
 */
function windowsExecutable(command: string, env: Env): boolean {
  const key = Object.keys(env).find((name) => name.toUpperCase() === 'PATHEXT')
  const raw = (key === undefined ? undefined : env[key]) ?? DEFAULT_PATHEXT
  const dot = command.lastIndexOf('.')
  const slash = Math.max(command.lastIndexOf('\\'), command.lastIndexOf('/'))
  if (dot <= slash + 1) return false
  const extension = command.slice(dot).toLowerCase()
  return raw
    .split(';')
    .map((part) => part.trim().toLowerCase())
    .some((part) => part !== '' && part !== '.' && part === extension)
}

/**
 * Resolve a command the way the app will resolve it when it spawns.
 *
 * Two paths, because a person may type either.
 *
 * An **absolute path** is checked with `access(X_OK)` and nothing else. Running
 * it to see whether it works would be running an arbitrary program the person
 * has only just named, before they have pressed anything that says "start", and
 * on the strength of a form — a thing this app should not do at any point and
 * least of all here. Executability is the honest floor: it is what the spawn
 * needs, and it is checkable without side effects.
 *
 * On Windows the floor needs one more plank, because `access(X_OK)` there is not
 * the check its name suggests. libuv has no execute bit to consult, so the mode
 * is ignored and `X_OK` behaves exactly like `F_OK` — measured on Windows 11
 * (26.7.0), where `accessSync('%TEMP%\\td-x-probe.txt', X_OK)` returns rather
 * than throwing. Taken alone it would accept any file that exists, so a person
 * who pointed the form at a readme would get an agent in the picker that dies
 * the moment it is selected: precisely the "never declare an agent that has not
 * been launched" rule this module exists to enforce, broken on the one platform
 * where the check cannot enforce it. So the extension has to be one Windows will
 * actually execute, read from `PATHEXT` — the same list `where.exe` searches by,
 * so a name found on PATH and a path typed in full are held to one standard.
 * This is not reachable on POSIX, where the execute bit is real and the
 * extension means nothing.
 *
 * A **bare name** goes through `which` / `where.exe` against the login PATH,
 * which is the same question `agent-binaries.ts` asks for the shipped agents and
 * the same answer the spawn will get. `firstLookupPath` takes the first line,
 * because `where.exe` prints every match in search order and the first is the
 * one that would run.
 *
 * Deliberately *not* a version probe. `agent-binaries.ts` runs `--version` for
 * the four agents in the catalogue and can, because the catalogue records which
 * flag each one has; an agent nobody here has seen has no known flag, guessing
 * `--version` would report a working CLI without one as broken, and a wrong
 * refusal is worse than a missing proof. `customEntry` says exactly that by
 * leaving `versionArgs` null.
 */
export async function lookupCommand(
  command: string,
  platform: Platform = currentPlatform(),
  env: Env = process.env,
): Promise<string | null> {
  if (command.startsWith('/') || /^[A-Za-z]:[\\/]/.test(command)) {
    if (isWindows(platform) && !windowsExecutable(command, env)) return null
    try {
      accessSync(command, constants.X_OK)
      return command
    } catch {
      return null
    }
  }

  const spec = lookupSpec(platform, command)
  try {
    const { stdout } = await run(spec.command, spec.args, {
      timeout: LOOKUP_TIMEOUT_MS,
      windowsHide: true,
      // The user's real PATH, through `withPath` rather than a spread with a
      // `PATH:` key in it — see `platform/env-path.test.ts`, which scans for the
      // second form because it leaves a Windows child holding two spellings.
      env: withPath(process.env, await loginPath(platform), platform),
    })
    return firstLookupPath(stdout)
  } catch {
    // Not found, refused, or slower than the timeout. All three are "this app
    // cannot start it", which is the only thing the answer is used for.
    return null
  }
}

/**
 * The agents this machine has added.
 *
 * Kept in memory and written through, the same shape `FolderGrants` and
 * `CopilotAccess` use: every read is a map lookup on a path a session start is
 * waiting on, and the file is only ever written by a person pressing a button.
 */
export class CustomAgentStore {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private agents: CustomAgent[] = []
  private readonly lookup: CommandLookup

  constructor(userData: string, options: { lookup?: CommandLookup } = {}) {
    this.file = join(userData, CUSTOM_AGENTS_FILE)
    this.lookup = options.lookup ?? ((command) => lookupCommand(command))
    this.load()
  }

  /** Every added agent, in the order they were added. */
  list(): CustomAgent[] {
    return [...this.agents]
  }

  /** One by id, or undefined. The lookup a session start makes. */
  get(id: string): CustomAgent | undefined {
    if (!isCustomProviderId(id)) return undefined
    return this.agents.find((agent) => agent.id === id)
  }

  /**
   * Add one, or say why not.
   *
   * The draft is re-validated here even though the form already did, because a
   * renderer is not a place to enforce a rule that decides what gets executed —
   * and because this is reachable from anywhere the bridge is, not only from the
   * form that was written for it.
   */
  async add(raw: unknown): Promise<AddAgentOutcome> {
    const draft = parseDraft(raw)
    const problems = validateDraft(draft, this.takenLabels())
    if (!draftIsValid(problems)) return { ok: false, problems }

    if (this.agents.length >= MAX_CUSTOM_AGENTS) {
      return {
        ok: false,
        problems: {
          label: `This machine already has ${MAX_CUSTOM_AGENTS} added agents. Remove one first.`,
        },
      }
    }

    const command = draft.command.trim()
    const resolvedPath = await this.lookup(command)
    if (resolvedPath === null) {
      return {
        ok: false,
        problems: {
          /*
           * The sentence names the command and says where it looked, because
           * the two things that are actually wrong when this fires are "it is
           * spelled differently" and "it is installed somewhere this app cannot
           * see". A bare "not found" distinguishes neither, and the second is
           * the one a person cannot guess: a GUI app's PATH is not the PATH
           * they have in their terminal, which is exactly why the lookup runs
           * against the login shell's.
           */
          command:
            `\`${command}\` is not on your PATH and is not a program this machine can run. ` +
            'Check the spelling, or give the full path to it.',
        },
      }
    }

    const agent: CustomAgent = {
      id: customAgentId(draft.label.trim(), this.agents.map((existing) => existing.id)),
      label: draft.label.trim(),
      description: draft.description.trim(),
      command,
      args: splitArgs(draft.args),
      resumeArgs: splitArgs(draft.resumeArgs),
      addedAt: Date.now(),
      resolvedPath,
    }

    this.commit([...this.agents, agent])
    return { ok: true, agent }
  }

  /**
   * Forget one. False when there was nothing to forget.
   *
   * Nothing is done to the sessions already running on it, and that is the right
   * answer rather than a gap: the pty is a live process with the person's work
   * in it, and removing a row from a picker is not a reason to kill it. What it
   * does mean is that such a session cannot be *restored* on the next launch —
   * `startSession` will not find the agent, and `planRestore` drops it — which is
   * the same thing that happens when an agent is uninstalled.
   */
  remove(id: string): boolean {
    if (!this.agents.some((agent) => agent.id === id)) return false
    this.commit(this.agents.filter((agent) => agent.id !== id))
    return true
  }

  /* ------------------------------------------------------------- internals */

  /**
   * Every name already spoken for, shipped agents included.
   *
   * Two rows called "Codex" in one picker is not a duplicate-key bug, it is
   * worse: they are indistinguishable and one of them can resume a conversation
   * while the other cannot.
   */
  private takenLabels(): string[] {
    return [...AGENT_ENTRIES.map((entry) => entry.label), ...this.agents.map((a) => a.label)]
  }

  private commit(next: readonly CustomAgent[]): void {
    const state: StoredState = { version: FORMAT_VERSION, agents: [...next] }
    try {
      mkdirSync(dirname(this.file), { recursive: true })
      const tmp = `${this.file}.tmp`
      writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, 'utf8')
      renameSync(tmp, this.file)
    } catch (error) {
      // Loud, and the in-memory list is left alone. A list the picker believes
      // and the disk does not is an agent that vanishes at the next launch, and
      // the person is far better placed to notice a failure now than a
      // disappearance tomorrow.
      console.error('[agents] could not write the added agents:', error)
      throw error
    }
    this.agents = [...next]
  }

  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the ordinary case and will stay the ordinary case.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[agents] the added-agents file is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[agents] could not read the added agents:', error)
      return
    }

    const agents =
      typeof parsed === 'object' && parsed !== null
        ? parseCustomAgents((parsed as { agents?: unknown }).agents)
        : []
    this.agents = agents.slice(0, MAX_CUSTOM_AGENTS)
  }
}

/* -------------------------------------------------------------------- ipc -- */

export const AGENTS_LIST_CHANNEL = 'agents:list'
export const AGENTS_ADD_CHANNEL = 'agents:add'
export const AGENTS_REMOVE_CHANNEL = 'agents:remove'

/**
 * The three channels behind `listAgents`, `addAgent` and `removeAgent`.
 *
 * `add` is deliberately the only way one comes into existence — there is no
 * "save this list" channel taking an array. A bulk write would be a way to put
 * an agent in the file without the PATH check, which is the one rule this whole
 * module exists to enforce, and it would arrive from the renderer where the rule
 * cannot be trusted to have been applied.
 */
export function registerCustomAgentsIpc(ipcMain: IpcMain, store: CustomAgentStore): void {
  ipcMain.handle(AGENTS_LIST_CHANNEL, () => store.list())
  ipcMain.handle(AGENTS_ADD_CHANNEL, (_event, draft: unknown) => store.add(draft))
  ipcMain.handle(AGENTS_REMOVE_CHANNEL, (_event, id: unknown) =>
    typeof id === 'string' && id.startsWith(CUSTOM_PROVIDER_PREFIX) ? store.remove(id) : false,
  )
}
