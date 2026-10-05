import { createHash } from 'node:crypto'
import { lstat, open, readFile, readdir, realpath, stat } from 'node:fs/promises'
import { basename, join } from 'node:path'
import {
  KNOWLEDGE_DIR,
  KNOWLEDGE_PROJECT_FILE,
  type MemorySpace,
  type MemorySpaceKind,
} from '../../shared/agent-stack'
import { BRAND } from '../../shared/brand'
import { encodeProjectPath, listTranscripts } from '../transcript'

/**
 * Where the agents' memory actually is on this machine, found rather than
 * assumed.
 *
 * Four kinds, each read where its writer keeps it:
 *
 *  - **Claude Code**: `<store>/projects/<encoded folder>/memory/`, one per
 *    project folder, in every account store this app knows. Account profiles
 *    link their `projects/` to one shared store (`shared-projects.ts`), so the
 *    stores are grouped by the real path of that folder and a memory folder seen
 *    through three accounts is one space, not three.
 *  - **Codex**: `$CODEX_HOME/memories/`, one per Codex account.
 *  - **Hoot**: the `memory/` folder in its home (`copilot-home.ts`).
 *  - **Project knowledge**: `<userData>/knowledge/<key>/`, written by the
 *    knowledge store, one folder per project (`shared/agent-stack.ts`).
 *
 * ## Sharing that already exists
 *
 * A project's `memory` can already be a link to another project's — somebody
 * made one by hand so two folders remember the same things. That is found here
 * by resolving every memory folder to its real path and grouping: the folder
 * whose `memory` is the real directory owns the space, and every folder that
 * reaches it through a link is listed in `sharedWith`. Nothing here creates,
 * removes or retargets a link, and nothing is moved; this module only reads.
 *
 * ## Naming a project folder honestly
 *
 * Claude Code's folder names are a lossy one-way encoding (`transcript.ts`
 * `encodeProjectPath`): `-` stands for `/`, `.`, space and more. So a name is
 * never decoded and presented as fact. A folder is named by the `cwd` its own
 * newest conversation recorded, kept only when it encodes back to the same
 * folder name; failing that, by the plain decoding when that folder exists and
 * encodes back exactly; failing both, by the stored name itself, and the space
 * says it is unconfirmed by leaving `project` null.
 */

export interface AccountStore {
  provider: 'claude' | 'codex'
  /** The agent's config directory: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`. */
  configDir: string
  /** The account's name, as the person gave it. */
  name: string
}

export interface DiscoverInput {
  stores: readonly AccountStore[]
  /** Hoot's `memory/` folder, or null when it has none. */
  hootMemory: string | null
  /** `<userData>`, where project knowledge lives, or null. */
  userData: string | null
}

/** One folder that reaches a Claude memory space, as found on disk. */
export interface SpaceMember {
  /** The encoded folder name under `projects/`. */
  folder: string
  /** The project folder it is for, when that could be confirmed. */
  project: string | null
  /** True when its `memory` reaches the space through a link. */
  linked: boolean
}

/**
 * A space as discovery found it: the shared shape, plus what the service needs
 * to find conversations and to resolve a session's own memory.
 */
export interface FoundSpace extends MemorySpace {
  /** Claude only: the real `projects/` folders it was seen in. */
  projectsDirs: string[]
  /** Claude only: every folder that reaches it, the owner first. */
  members: SpaceMember[]
  /** Every account store it was seen through, by config directory. */
  stores: string[]
  /** The names of those accounts, for a label. */
  accounts: string[]
}

/** How much of a conversation's head is read to find the folder it ran in. */
const HEAD_BYTES = 64 * 1024

export function spaceId(kind: MemorySpaceKind, root: string): string {
  return `${kind}:${createHash('sha256').update(root).digest('hex').slice(0, 12)}`
}

async function realDir(path: string): Promise<string | null> {
  try {
    const real = await realpath(path)
    return (await stat(real)).isDirectory() ? real : null
  } catch {
    return null
  }
}

/** The `cwd` the newest conversation in a Claude project folder recorded, read from its head only. */
async function recordedCwd(dir: string): Promise<string | null> {
  for (const file of (await listTranscripts(dir)).slice(0, 3)) {
    let text = ''
    try {
      const handle = await open(file.path, 'r')
      try {
        const buffer = Buffer.alloc(HEAD_BYTES)
        const { bytesRead } = await handle.read(buffer, 0, HEAD_BYTES, 0)
        text = buffer.subarray(0, bytesRead).toString('utf8')
      } finally {
        await handle.close()
      }
    } catch {
      continue
    }
    for (const line of text.split('\n')) {
      if (!line.includes('"cwd"')) continue
      try {
        const cwd = (JSON.parse(line) as { cwd?: unknown }).cwd
        if (typeof cwd === 'string' && cwd !== '') return cwd
      } catch {
        // The last line of a head is usually cut in half; the next file may do.
      }
    }
  }
  return null
}

/**
 * The project folder an encoded Claude folder name is for, or null when it
 * cannot be confirmed. Never a guess: every answer encodes back to `folder`.
 */
export async function projectOfFolder(projectsDir: string, folder: string): Promise<string | null> {
  const recorded = await recordedCwd(join(projectsDir, folder))
  if (recorded !== null && encodeProjectPath(recorded) === folder) return recorded
  if (folder.startsWith('-')) {
    const plain = folder.replace(/-/g, '/')
    if (encodeProjectPath(plain) === folder && (await realDir(plain)) !== null) return plain
  }
  return null
}

function labelOf(member: SpaceMember): string {
  return member.project !== null ? basename(member.project) || member.project : member.folder
}

async function claudeSpaces(stores: readonly AccountStore[]): Promise<FoundSpace[]> {
  // The stores grouped by the real `projects/` folder, so linked accounts are read once.
  const byProjects = new Map<string, AccountStore[]>()
  for (const store of stores) {
    if (store.provider !== 'claude') continue
    const real = await realDir(join(store.configDir, 'projects'))
    if (real === null) continue
    byProjects.set(real, [...(byProjects.get(real) ?? []), store])
  }

  interface Group {
    root: string
    projectsDirs: Set<string>
    members: Array<SpaceMember & { projectsDir: string }>
    stores: AccountStore[]
  }
  const groups = new Map<string, Group>()
  for (const [projectsDir, seenBy] of byProjects) {
    let folders: string[]
    try {
      folders = await readdir(projectsDir)
    } catch {
      continue
    }
    for (const folder of folders.sort()) {
      const memory = join(projectsDir, folder, 'memory')
      let link: boolean
      try {
        link = (await lstat(memory)).isSymbolicLink()
      } catch {
        continue
      }
      const root = await realDir(memory)
      if (root === null) continue
      // A memory folder reached through a linked project folder is a link too.
      const folderReal = await realDir(join(projectsDir, folder))
      const linked = link || (folderReal !== null && folderReal !== join(projectsDir, folder))
      const group = groups.get(root) ?? { root, projectsDirs: new Set(), members: [], stores: [] }
      group.projectsDirs.add(projectsDir)
      if (!group.members.some((one) => one.folder === folder && one.projectsDir === projectsDir)) {
        group.members.push({ folder, project: null, linked, projectsDir })
      }
      for (const store of seenBy) if (!group.stores.includes(store)) group.stores.push(store)
      groups.set(root, group)
    }
  }

  const spaces: FoundSpace[] = []
  for (const group of groups.values()) {
    for (const member of group.members) member.project = await projectOfFolder(member.projectsDir, member.folder)
    // The owner is the folder whose memory is the real directory; links follow.
    const members = [...group.members].sort((a, b) => Number(a.linked) - Number(b.linked) || a.folder.localeCompare(b.folder))
    const owner = members[0]
    spaces.push({
      id: spaceId('claude-project', group.root),
      kind: 'claude-project',
      label: labelOf(owner),
      root: group.root,
      project: owner.project,
      store: group.stores[0]?.configDir ?? null,
      sharedWith: members.slice(1).map((member) => member.project ?? member.folder),
      projectsDirs: [...group.projectsDirs],
      members: members.map(({ folder, project, linked }) => ({ folder, project, linked })),
      stores: group.stores.map((store) => store.configDir),
      accounts: group.stores.map((store) => store.name),
    })
  }
  return spaces.sort((a, b) => a.label.localeCompare(b.label))
}

async function codexSpaces(stores: readonly AccountStore[]): Promise<FoundSpace[]> {
  const byRoot = new Map<string, AccountStore[]>()
  for (const store of stores) {
    if (store.provider !== 'codex') continue
    const root = await realDir(join(store.configDir, 'memories'))
    if (root === null) continue
    byRoot.set(root, [...(byRoot.get(root) ?? []), store])
  }
  const several = byRoot.size > 1
  return [...byRoot].map(([root, seenBy]) => ({
    id: spaceId('codex', root),
    kind: 'codex',
    label: several ? `Codex · ${seenBy[0].name}` : 'Codex',
    root,
    project: null,
    store: seenBy[0].configDir,
    sharedWith: [],
    projectsDirs: [],
    members: [],
    stores: seenBy.map((store) => store.configDir),
    accounts: seenBy.map((store) => store.name),
  }))
}

async function hootSpace(memory: string | null): Promise<FoundSpace[]> {
  if (memory === null) return []
  const root = await realDir(memory)
  if (root === null) return []
  return [
    {
      id: spaceId('hoot', root),
      kind: 'hoot',
      label: BRAND.assistant,
      root,
      project: null,
      store: null,
      sharedWith: [],
      projectsDirs: [],
      members: [],
      stores: [],
      accounts: [],
    },
  ]
}

async function knowledgeSpaces(userData: string | null): Promise<FoundSpace[]> {
  if (userData === null) return []
  const base = join(userData, KNOWLEDGE_DIR)
  let keys: string[]
  try {
    keys = await readdir(base)
  } catch {
    return []
  }
  const spaces: FoundSpace[] = []
  for (const key of keys.sort()) {
    const root = await realDir(join(base, key))
    if (root === null) continue
    let project: string | null = null
    try {
      const parsed = JSON.parse(await readFile(join(root, KNOWLEDGE_PROJECT_FILE), 'utf8')) as { project?: unknown }
      project = typeof parsed.project === 'string' && parsed.project !== '' ? parsed.project : null
    } catch {
      continue
    }
    if (project === null) continue
    spaces.push({
      id: spaceId('knowledge', root),
      kind: 'knowledge',
      label: basename(project) || project,
      root,
      project,
      store: null,
      sharedWith: [],
      projectsDirs: [],
      members: [],
      stores: [],
      accounts: [],
    })
  }
  return spaces
}

/** Every memory space on this machine that this app can read, in a stable order. */
export async function discoverSpaces(input: DiscoverInput): Promise<FoundSpace[]> {
  const [claude, codex, hoot, knowledge] = await Promise.all([
    claudeSpaces(input.stores),
    codexSpaces(input.stores),
    hootSpace(input.hootMemory),
    knowledgeSpaces(input.userData),
  ])
  return [...hoot, ...claude, ...codex, ...knowledge]
}

/**
 * The memory folder a Claude session in `cwd` reads, under its own account
 * store, for each spelling the folder has — a session started in a linked
 * folder is filed under the real one too (`projectPathSpellings`).
 */
export function claudeMemoryPathsFor(configDir: string, spellings: readonly string[]): string[] {
  return [...new Set(spellings.map((spelling) => join(configDir, 'projects', encodeProjectPath(spelling), 'memory')))]
}

export { realDir }
