/**
 * Memory: every action a person can take on the Memory page, and the tool that
 * takes it — or why an agent is not given it.
 *
 * See `./types.ts` for what an entry means. The two tools (`../memory-tools.ts`)
 * read the calling agent's **own** memory, so what the page does over every
 * agent's memory at once, and the corrections a person makes to it, are the
 * person's: an agent that could rewrite or delete memory through this server
 * could rewrite another agent's.
 */

import type { CoverageMap } from './types'

const PERSON_CORRECTS =
  'Correcting or deleting an agent’s memory is the person’s act on this page; an agent changes its own memory with its own file tools, and a tool here would let one agent rewrite another’s.'

export const memoryCoverage: CoverageMap = {
  'memory:spaces': {
    skip: 'The list of every agent’s memory on this machine is the person’s view; an agent reaches only its own, through memory.read and memory.search.',
  },
  // A memory's notes and their links: `memory.read` without a path.
  'memory:notes': { tool: 'memory.read' },
  'memory:read': { tool: 'memory.read' },
  'memory:search': { tool: 'memory.search' },
  'memory:save': { skip: PERSON_CORRECTS },
  'memory:delete': { skip: PERSON_CORRECTS },
  'memory:provenance': {
    skip: 'Which conversation wrote a note is read from that folder’s transcripts for the person reviewing it; an agent is given its memory, not the history of who wrote it.',
  },
}
