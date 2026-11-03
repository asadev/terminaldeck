/**
 * An agent reading its own memory: `memory.search` and `memory.read`.
 *
 * ## Whose memory, decided by who is asking
 *
 * The scope is never an argument a caller can widen. It is worked out from the
 * caller this endpoint already knows (`callers.ts`):
 *
 *  - **A session** reads the memory its own agent keeps, and nothing else. A
 *    Claude session: its account store's memory for the folder it runs in —
 *    which, when that folder's `memory` is a link to another folder's, *is* the
 *    other folder's memory, and the answer says it is shared rather than hiding
 *    it. A Codex session: its Codex home's `memories/`. A session cannot name a
 *    project, so it cannot read the folder next door.
 *  - **Hoot** reads its own memory, and — for planning — the memory of a project
 *    it names explicitly, read-only: that project's Claude memory in every
 *    account store, and its project knowledge. Only a folder this app has open
 *    can be named (`requireKnownFolder`), the same boundary every tool here
 *    keeps.
 *  - **Anybody else** — a paired device, an AI app on a key — is refused. The
 *    memory of the agents on this machine is read on this machine.
 *
 * ## Where the answer goes
 *
 * What these tools return is a tool result: it goes to the calling agent and,
 * through it, to that agent's model provider, exactly like the output of any
 * other tool it calls. That is the reason the scope above is the caller's own
 * memory and not more — a note one agent never wrote is not sent to its
 * provider by this tool.
 *
 * Both are `read` and held behind `tools.describe` with an index line, so they
 * cost the standing listing nothing.
 */

import type { SessionMeta } from '../../shared/types'
import type { FoundSpace } from '../memory/spaces'
import type { MemoryService } from '../memory/service'
import { BadArgument, optInt, optStr, requireKnownFolder, str, type ToolContext, type ToolSpec } from './catalogue'
import { Refused } from './surface'

export interface MemoryToolDeps {
  /** The one memory service the Memory page uses, or null before it exists. */
  memory(): MemoryService | null
  /** The account store a session runs under, or null for an agent whose memory is not read here. */
  storeOf(session: SessionMeta): string | null
}

/** Most characters of one note handed back. A note longer than this says so. */
export const MAX_READ_CHARS = 64 * 1024

interface Scope {
  /** Spaces this caller may read, its own first. */
  spaces: FoundSpace[]
  /** One sentence on what the scope is, for the answer. */
  about: string
}

function service(deps: MemoryToolDeps): MemoryService {
  const memory = deps.memory()
  if (memory === null) throw new Refused('not-permitted', 'Memory is not available in this build.')
  return memory
}

function sharedNote(space: FoundSpace): string | null {
  if (space.sharedWith.length === 0) return null
  return `This memory is shared: ${space.sharedWith.join(', ')} read${space.sharedWith.length === 1 ? 's' : ''} and write${
    space.sharedWith.length === 1 ? 's' : ''
  } the same notes, through a link that already exists on disk.`
}

/** The spaces the caller may read. Never wider than its own memory, plus what Hoot names for planning. */
export async function scopeOf(deps: MemoryToolDeps, context: ToolContext, project: string | null): Promise<Scope> {
  const memory = service(deps)
  const caller = context.caller

  if (caller.kind === 'session') {
    if (project !== null) {
      throw new Refused('not-permitted', 'A session reads its own memory only; it cannot name another project.')
    }
    if (caller.machineId !== undefined && caller.machineId !== '') {
      throw new Refused('not-permitted', 'This session runs on another computer, and its memory is there, not on this one.')
    }
    const session = context.surface.listSessions().find((one) => one.id === caller.sessionId)
    if (session === undefined) throw new Refused('not-permitted', 'This session is not one this app is running.')
    const store = deps.storeOf(session)
    if (store === null) return { spaces: [], about: `This app does not read ${session.provider}'s memory.` }
    if (session.provider === 'codex') {
      const space = await memory.codexSpaceFor(store)
      return space === null
        ? { spaces: [], about: 'Codex has kept no memory under this account yet.' }
        : { spaces: [space], about: 'Your own Codex memory.' }
    }
    const space = await memory.claudeSpaceFor(store, session.cwd)
    if (space === null) return { spaces: [], about: `No memory has been kept for ${session.cwd} under this account yet.` }
    return { spaces: [space], about: sharedNote(space) ?? `Your own memory for ${session.cwd}.` }
  }

  if (caller.kind === 'local') {
    const own = await memory.hootSpace()
    const spaces = own === null ? [] : [own]
    if (project === null) return { spaces, about: 'Your own memory.' }
    const folder = requireKnownFolder(context.surface, project)
    const theirs = await memory.spacesForProject(folder)
    return {
      spaces: [...spaces, ...theirs],
      about:
        theirs.length === 0
          ? `Your own memory; ${folder} has no memory or knowledge kept yet.`
          : `Your own memory, and ${folder}'s memory and knowledge, read-only, for planning.`,
    }
  }

  throw new Refused('not-permitted', 'The memory of the agents on this computer is read on this computer only.')
}

function spaceView(space: FoundSpace): Record<string, unknown> {
  return {
    space: space.id,
    kind: space.kind,
    label: space.label,
    project: space.project,
    ...(space.sharedWith.length > 0 ? { sharedWith: space.sharedWith } : {}),
  }
}

export function memoryTools(deps: MemoryToolDeps): ToolSpec[] {
  return [
    {
      id: 'memory.search',
      wire: 'memory_search',
      tier: 'read',
      audience: 'copilot',
      title: 'Search your memory',
      index: 'Search the memory notes your agent keeps for this project (or, for Hoot, a project it names).',
      description:
        'Search the memory notes you keep — the ones your agent reads at the start of a conversation — by words. ' +
        'A session searches its own memory for the folder it runs in; Hoot searches its own, and may add `project` ' +
        'to read one open project’s memory and knowledge for planning. Answers each note’s place, title and the ' +
        'line that matched; memory.read opens one. What comes back goes to you as tool output.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Words to look for.' },
          project: { type: 'string', description: 'Hoot only: an open project folder whose memory to read too.' },
          limit: { type: 'number', description: 'Most results, 1–40. Default 10.' },
        },
        required: ['query'],
        additionalProperties: false,
      },
      summary: (args) => `Search memory for “${optStr(args, 'query') ?? ''}”`,
      run: async (args, context) => {
        const query = str(args, 'query')
        const limit = optInt(args, 'limit', 10, 1, 40)
        const scope = await scopeOf(deps, context, optStr(args, 'project'))
        const hits = await service(deps).searchIn(
          query,
          scope.spaces.map((space) => space.id),
          limit,
        )
        const labels = new Map(scope.spaces.map((space) => [space.id, space.label]))
        return {
          value: {
            scope: scope.about,
            spaces: scope.spaces.map(spaceView),
            results: hits.map((hit) => ({
              space: hit.spaceId,
              memory: labels.get(hit.spaceId) ?? hit.spaceId,
              path: hit.path,
              title: hit.title,
              snippet: hit.snippet,
            })),
          },
          summary: { spaces: scope.spaces.length, results: hits.length },
        }
      },
    },
    {
      id: 'memory.read',
      wire: 'memory_read',
      tier: 'read',
      audience: 'copilot',
      title: 'Read your memory',
      index: 'Read one of your memory notes, with what it links to and what links to it — or list them all.',
      description:
        'Read one memory note by its `path` (as memory.search or a listing gives it): its text, the notes it links ' +
        'to, the links that reach nothing, and the notes that link to it. Without `path`, lists the notes in your ' +
        'memory. Same scope as memory.search: your own memory, and for Hoot a named `project`’s, read-only. ' +
        'Pass `space` when more than one memory is in scope. What comes back goes to you as tool output.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'The note, relative to its memory folder. Omit to list.' },
          space: { type: 'string', description: 'Which memory, when more than one is in scope.' },
          project: { type: 'string', description: 'Hoot only: an open project folder whose memory to read.' },
        },
        additionalProperties: false,
      },
      summary: (args) => {
        const path = optStr(args, 'path')
        return path === null ? 'List memory notes' : `Read memory note ${path}`
      },
      run: async (args, context) => {
        const scope = await scopeOf(deps, context, optStr(args, 'project'))
        const memory = service(deps)
        const wanted = optStr(args, 'space')
        const path = optStr(args, 'path')
        const spaces = wanted === null ? scope.spaces : scope.spaces.filter((space) => space.id === wanted)
        if (wanted !== null && spaces.length === 0) throw new BadArgument(`${wanted} is not a memory you can read`)

        if (path === null) {
          const listed = await Promise.all(
            spaces.map(async (space) => {
              const [notes, graph] = await Promise.all([memory.notes(space.id), memory.graph(space.id)])
              return {
                ...spaceView(space),
                notes: notes.map((note) => ({ path: note.path, title: note.title, description: note.description, type: note.type })),
                linksToNothing: graph.dangling,
              }
            }),
          )
          return {
            value: { scope: scope.about, memories: listed },
            summary: { spaces: listed.length, notes: listed.reduce((sum, one) => sum + one.notes.length, 0) },
          }
        }

        if (spaces.length > 1 && wanted === null) {
          throw new BadArgument(`more than one memory is in scope; pass space as one of ${spaces.map((space) => space.id).join(', ')}`)
        }
        const space = spaces[0]
        if (space === undefined) throw new Refused('not-permitted', scope.about)
        const read = await memory.read(space.id, path)
        if (!read.ok) throw new BadArgument(read.error)
        const long = read.text.length > MAX_READ_CHARS
        return {
          value: {
            ...spaceView(space),
            path: read.path,
            title: read.note.title,
            text: long ? read.text.slice(0, MAX_READ_CHARS) : read.text,
            ...(long || read.truncated ? { cut: 'This note is longer than what is shown.' } : {}),
            linksTo: read.links.filter((link) => link.to !== null).map((link) => link.to),
            linksToNothing: read.links.filter((link) => link.to === null).map((link) => link.target),
            linkedFrom: read.backlinks,
          },
          summary: { path: read.path, chars: Math.min(read.text.length, MAX_READ_CHARS) },
        }
      },
    },
  ]
}
