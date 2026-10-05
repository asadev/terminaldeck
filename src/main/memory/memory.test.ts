import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { copilotPaths } from '../copilot-home'
import { MemoryService, type NoteRead } from './service'
import { shareProjectMemory, type ShareQuestion } from './share'
import { discoverSpaces, type DiscoverInput, type FoundSpace } from './spaces'

/**
 * The agents' memory, as this app finds and changes it — every case against a
 * folder made for the test. Nothing here reads a real `~/.claude` or
 * `~/.codex`: the stores are temp directories laid out the way the real ones
 * are (`projects/<encoded folder>/memory/`, `$CODEX_HOME/memories/`).
 */

let dir: string

function write(path: string, text: string): string {
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, text)
  return path
}

/** A conversation line Claude Code writes, recording the folder it ran in. */
function conversation(folderDir: string, id: string, cwd: string, extra: string[] = []): void {
  const head = JSON.stringify({ type: 'user', cwd, sessionId: id, message: { role: 'user', content: 'hi' } })
  write(join(folderDir, `${id}.jsonl`), [head, ...extra].join('\n') + '\n')
}

function writeCall(path: string, at: string): string {
  return JSON.stringify({
    type: 'assistant',
    timestamp: at,
    message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Write', input: { file_path: path, content: 'x' } }] },
  })
}

interface Fixture {
  claude: string
  projects: string
  alphaMemory: string
  betaMemory: string
  codexHome: string
  userData: string
  input: DiscoverInput
}

/**
 * Two accounts sharing one `projects/` (the way `shared-projects.ts` links
 * them), `/work/alpha` with memory, `/work/beta` whose `memory` is a link to
 * alpha's, `/work/gamma` with its own, a Codex home, Hoot, and one project's
 * knowledge.
 */
function fixture(): Fixture {
  const claude = join(dir, 'claude')
  const projects = join(claude, 'projects')
  const alpha = join(projects, '-work-alpha')
  const alphaMemory = join(alpha, 'memory')
  write(
    join(alphaMemory, 'MEMORY.md'),
    '# Memory index\n\n- [Deploy rules](feedback_deploy.md) — ship to TestFlight\n- [Keep it open](keep_open.md) — the latest build\n- [Gone](gone.md) — deleted long ago\n',
  )
  write(
    join(alphaMemory, 'feedback_deploy.md'),
    '---\nname: deploy-rules\ndescription: Deploy means TestFlight\ntype: feedback\n---\n\nDeploy means a TestFlight release. See [[keep_open]] and [[nowhere]].\n',
  )
  write(join(alphaMemory, 'keep_open.md'), '---\nname: keep_open\ndescription: Leave the build running\n---\nThe platypus build stays open.\n')
  conversation(alpha, 'conv-alpha', '/work/alpha')

  const beta = join(projects, '-work-beta')
  mkdirSync(beta, { recursive: true })
  symlinkSync(alphaMemory, join(beta, 'memory'))
  conversation(beta, 'conv-beta', '/work/beta')

  const gamma = join(projects, '-work-gamma')
  write(join(gamma, 'memory', 'MEMORY.md'), '# Gamma\n\n- [Secret plan](plan.md)\n')
  write(join(gamma, 'memory', 'plan.md'), 'The gamma plan mentions platypus too.\n')
  conversation(gamma, 'conv-gamma', '/work/gamma')

  // A second account whose `projects/` is the shared one.
  const second = join(dir, 'profile-two')
  mkdirSync(second, { recursive: true })
  symlinkSync(projects, join(second, 'projects'))

  const codexHome = join(dir, 'codex')
  write(join(codexHome, 'memories', 'MEMORY.md'), '# Codex memory\n')
  write(join(codexHome, 'memories', 'memory_summary.md'), 'Codex remembers the platypus too.\n')
  write(join(codexHome, 'memories', 'rollout_summaries', 'r1.md'), 'A rollout.\n')

  const userData = join(dir, 'userData')
  const hoot = copilotPaths(userData)
  write(join(hoot.memory, 'MEMORY.md'), '# Hoot\n\n- [Prefers short answers](pref.md)\n')
  write(join(hoot.memory, 'pref.md'), '---\ndescription: Short answers\ntype: preference\n---\nShort, plain answers.\n')

  const knowledge = join(userData, 'knowledge', 'abc123')
  write(join(knowledge, 'project.json'), JSON.stringify({ project: '/work/alpha' }))
  write(
    join(knowledge, 'k1.md'),
    '---\nid: k1\nkind: decision\nsubject: storage\nstatus: verified\nsource: review\nverified: 1759622400000\n---\nNotes live on disk.\n',
  )

  return {
    claude,
    projects,
    alphaMemory,
    betaMemory: join(beta, 'memory'),
    codexHome,
    userData,
    input: {
      stores: [
        { provider: 'claude', configDir: claude, name: 'Own' },
        { provider: 'claude', configDir: second, name: 'Two' },
        { provider: 'codex', configDir: codexHome, name: 'Codex own' },
      ],
      hootMemory: hoot.memory,
      userData,
    },
  }
}

function byKind(spaces: FoundSpace[], kind: FoundSpace['kind']): FoundSpace[] {
  return spaces.filter((space) => space.kind === kind)
}

function serviceFor(input: DiscoverInput, trashed: string[] = []): MemoryService {
  const trash = join(dir, 'Trash')
  return new MemoryService({
    sources: () => input,
    trash: async (path) => {
      mkdirSync(trash, { recursive: true })
      renameSync(path, join(trash, `${trashed.length}-${basename(path)}`))
      trashed.push(path)
    },
    hootPaths: () => copilotPaths(input.userData ?? dir),
  })
}

async function readOk(service: MemoryService, spaceId: string, path: string): Promise<Extract<NoteRead, { ok: true }>> {
  const read = await service.read(spaceId, path)
  if (!read.ok) throw new Error(read.error)
  return read
}

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-memory-')))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/* -------------------------------------------------------------- discovery -- */

describe('finding the memory on this machine', () => {
  it('finds one space per real memory folder, and lists a linked folder as sharing it', async () => {
    const f = fixture()
    const claude = byKind(await discoverSpaces(f.input), 'claude-project')
    expect(claude.map((space) => space.label)).toEqual(['alpha', 'gamma'])
    const alpha = claude[0]
    expect(alpha.root).toBe(f.alphaMemory)
    expect(alpha.project).toBe('/work/alpha')
    expect(alpha.sharedWith).toEqual(['/work/beta'])
    expect(alpha.members).toEqual([
      { folder: '-work-alpha', project: '/work/alpha', linked: false },
      { folder: '-work-beta', project: '/work/beta', linked: true },
    ])
    // Two accounts on one `projects/` see one space, not two.
    expect(alpha.accounts).toEqual(['Own', 'Two'])
    expect(claude[1].sharedWith).toEqual([])
  })

  it('names a folder it cannot confirm by its stored name, and does not claim a project for it', async () => {
    const f = fixture()
    write(join(f.projects, '-somewhere-odd-name', 'memory', 'MEMORY.md'), '# odd\n')
    const odd = (await discoverSpaces(f.input)).find((space) => space.label === '-somewhere-odd-name')
    expect(odd?.project).toBeNull()
  })

  it('finds Codex’s memories, Hoot’s memory and each project’s knowledge', async () => {
    const f = fixture()
    const spaces = await discoverSpaces(f.input)
    expect(byKind(spaces, 'codex').map((space) => [space.label, space.root])).toEqual([['Codex', join(f.codexHome, 'memories')]])
    expect(byKind(spaces, 'hoot').map((space) => space.label)).toEqual(['Hoot'])
    expect(byKind(spaces, 'knowledge').map((space) => [space.label, space.project])).toEqual([['alpha', '/work/alpha']])
  })

  it('never creates, removes or retargets a link while it looks', async () => {
    const f = fixture()
    const before = readlinkSync(f.betaMemory)
    await discoverSpaces(f.input)
    await serviceFor(f.input).spaces()
    expect(lstatSync(f.betaMemory).isSymbolicLink()).toBe(true)
    expect(readlinkSync(f.betaMemory)).toBe(before)
    expect(existsSync(join(f.projects, '-work-delta'))).toBe(false)
  })
})

/* --------------------------------------------------------- notes and links -- */

describe('a space’s notes, links and search', () => {
  it('lists notes with their front matter, and knowledge with its labels', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const spaces = await service.spaces()
    const alpha = byKind(spaces, 'claude-project')[0]
    const notes = await service.notes(alpha.id)
    const deploy = notes.find((note) => note.path === 'feedback_deploy.md')
    expect(deploy).toMatchObject({ title: 'deploy-rules', name: 'deploy-rules', description: 'Deploy means TestFlight', type: 'feedback' })
    expect(deploy?.links).toEqual(['keep_open', 'nowhere'])

    const knowledge = byKind(spaces, 'knowledge')[0]
    const [record] = await service.notes(knowledge.id)
    expect(record.labels).toEqual([
      { key: 'kind', value: 'decision' },
      { key: 'status', value: 'verified' },
      { key: 'source', value: 'review' },
      { key: 'verified', value: '2025-10-05' },
    ])
    await service.close()
  })

  it('reads a Codex memory’s nested summaries too', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const codex = byKind(await service.spaces(), 'codex')[0]
    expect((await service.notes(codex.id)).map((note) => note.path).sort()).toEqual([
      'MEMORY.md',
      'memory_summary.md',
      'rollout_summaries/r1.md',
    ])
  })

  it('resolves links by name and file, answers backlinks, and lists links that reach nothing', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const read = await readOk(service, alpha.id, 'feedback_deploy.md')
    expect(read.links).toEqual([
      { target: 'keep_open', to: 'keep_open.md' },
      { target: 'nowhere', to: null },
    ])
    expect(read.backlinks).toEqual(['MEMORY.md'])
    expect(read.indexed).toBe(true)

    const graph = await service.graph(alpha.id)
    expect(graph.edges).toEqual([
      { from: 'MEMORY.md', to: 'feedback_deploy.md' },
      { from: 'MEMORY.md', to: 'keep_open.md' },
      { from: 'feedback_deploy.md', to: 'keep_open.md' },
    ])
    expect(graph.dangling).toEqual([
      { from: 'MEMORY.md', target: 'gone.md' },
      { from: 'feedback_deploy.md', target: 'nowhere' },
    ])
  })

  it('searches only the spaces it is given', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const spaces = await service.spaces()
    const [alpha, gamma] = byKind(spaces, 'claude-project')
    const codex = byKind(spaces, 'codex')[0]

    const own = await service.searchIn('platypus', [alpha.id])
    expect(own.map((hit) => [hit.spaceId, hit.path])).toEqual([[alpha.id, 'keep_open.md']])
    const both = await service.searchIn('platypus', [alpha.id, gamma.id, codex.id])
    expect(new Set(both.map((hit) => hit.spaceId))).toEqual(new Set([alpha.id, gamma.id, codex.id]))
    expect(await service.searchIn('platypus', ['claude-project:nope'])).toEqual([])
  })
})

/* ---------------------------------------------------------- changing notes -- */

describe('correcting a note', () => {
  it('refuses any path that leaves the space, however it is spelled', async () => {
    const f = fixture()
    write(join(dir, 'outside.md'), 'not memory')
    symlinkSync(join(dir, 'outside.md'), join(f.alphaMemory, 'escape.md'))
    const service = serviceFor(f.input)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const version = { modifiedAt: 0, bytes: 0 }
    for (const path of ['../-work-gamma/memory/plan.md', join(dir, 'outside.md'), 'escape.md', 'sub/../../x.md', 'notes.txt']) {
      const saved = await service.save(alpha.id, path, 'overwritten', version)
      expect(saved.ok, path).toBe(false)
    }
    expect(readFileSync(join(dir, 'outside.md'), 'utf8')).toBe('not memory')
    // And the link out is not listed as one of the space's notes.
    expect((await service.notes(alpha.id)).map((note) => note.path)).not.toContain('escape.md')
  })

  it('refuses a save when the note changed after it was read', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const read = await readOk(service, alpha.id, 'keep_open.md')
    writeFileSync(join(f.alphaMemory, 'keep_open.md'), 'An agent rewrote this meanwhile, with more words in it.\n')
    const saved = await service.save(alpha.id, 'keep_open.md', 'my draft', read.version)
    expect(saved).toMatchObject({ ok: false })
    expect(readFileSync(join(f.alphaMemory, 'keep_open.md'), 'utf8')).toContain('An agent rewrote this')
  })

  it('saves over the note that was read, and hands back the new version', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const read = await readOk(service, alpha.id, 'keep_open.md')
    const saved = await service.save(alpha.id, 'keep_open.md', 'Corrected.\n', read.version)
    expect(saved.ok).toBe(true)
    expect(readFileSync(join(f.alphaMemory, 'keep_open.md'), 'utf8')).toBe('Corrected.\n')
    // The old version no longer saves; the new one does.
    expect((await service.save(alpha.id, 'keep_open.md', 'again', read.version)).ok).toBe(false)
    if (saved.ok && saved.version) expect((await service.save(alpha.id, 'keep_open.md', 'again', saved.version)).ok).toBe(true)
  })

  it('records an edit of Hoot’s memory in its action log, as the person’s', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const hoot = byKind(await service.spaces(), 'hoot')[0]
    const read = await readOk(service, hoot.id, 'pref.md')
    expect((await service.save(hoot.id, 'pref.md', 'Longer answers now.\n', read.version)).ok).toBe(true)
    const log = readFileSync(copilotPaths(f.userData).actions, 'utf8')
    expect(log).toContain('"action":"memory.edited"')
    expect(log).toContain('you edited memory/pref.md from the Memory page')
  })
})

describe('deleting a note', () => {
  it('moves it to the Trash through the injected function, and leaves MEMORY.md alone unless asked', async () => {
    const f = fixture()
    const trashed: string[] = []
    const service = serviceFor(f.input, trashed)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const index = readFileSync(join(f.alphaMemory, 'MEMORY.md'), 'utf8')

    const removed = await service.remove(alpha.id, 'keep_open.md')
    expect(removed).toMatchObject({ ok: true, indexLineRemoved: false })
    expect(trashed).toEqual([join(f.alphaMemory, 'keep_open.md')])
    expect(existsSync(join(f.alphaMemory, 'keep_open.md'))).toBe(false)
    expect(existsSync(join(dir, 'Trash', '0-keep_open.md'))).toBe(true)
    expect(readFileSync(join(f.alphaMemory, 'MEMORY.md'), 'utf8')).toBe(index)
    expect((await service.notes(alpha.id)).map((note) => note.path)).not.toContain('keep_open.md')
  })

  it('takes out exactly the matching MEMORY.md line when asked', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const removed = await service.remove(alpha.id, 'feedback_deploy.md', { indexLine: true })
    expect(removed).toMatchObject({ ok: true, indexLineRemoved: true })
    expect(readFileSync(join(f.alphaMemory, 'MEMORY.md'), 'utf8')).toBe(
      '# Memory index\n\n- [Keep it open](keep_open.md) — the latest build\n- [Gone](gone.md) — deleted long ago\n',
    )
  })

  it('refuses to delete anything outside the space', async () => {
    const f = fixture()
    const trashed: string[] = []
    const service = serviceFor(f.input, trashed)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    expect((await service.remove(alpha.id, '../-work-gamma/memory/plan.md')).ok).toBe(false)
    expect(trashed).toEqual([])
  })
})

/* -------------------------------------------------------------- provenance -- */

describe('who wrote a note', () => {
  it('finds the conversations that wrote it, through any folder that links to it, and no others', async () => {
    const f = fixture()
    const note = join(f.alphaMemory, 'keep_open.md')
    conversation(join(f.projects, '-work-alpha'), 'conv-writer', '/work/alpha', [writeCall(note, '2026-10-01T10:00:00Z')])
    // Written through beta's link — the same file.
    conversation(join(f.projects, '-work-beta'), 'conv-linked', '/work/beta', [
      writeCall(join(f.betaMemory, 'keep_open.md'), '2026-10-02T10:00:00Z'),
    ])
    // A file of the same name in another memory does not count.
    conversation(join(f.projects, '-work-gamma'), 'conv-other', '/work/gamma', [
      writeCall(join(f.projects, '-work-gamma', 'memory', 'keep_open.md'), '2026-10-03T10:00:00Z'),
    ])
    const service = serviceFor(f.input)
    const alpha = byKind(await service.spaces(), 'claude-project')[0]
    const found = await service.provenance(alpha.id, 'keep_open.md')
    expect(found.ok).toBe(true)
    if (!found.ok) return
    expect(found.writes.map((write) => [write.conversationId, write.folder, write.tool])).toEqual([
      ['conv-linked', '/work/beta', 'Write'],
      ['conv-writer', '/work/alpha', 'Write'],
    ])
  })

  it('is only offered for Claude Code memory', async () => {
    const f = fixture()
    const service = serviceFor(f.input)
    const codex = byKind(await service.spaces(), 'codex')[0]
    expect((await service.provenance(codex.id, 'MEMORY.md')).ok).toBe(false)
  })
})

/* ---------------------------------------------------------------- watching -- */

describe('staying current', () => {
  it('picks up a note an agent writes, and says which space changed', async () => {
    const f = fixture()
    const changed: string[] = []
    const service = new MemoryService({
      sources: () => f.input,
      trash: async () => {},
      onChanged: (spaceId) => changed.push(spaceId),
      watch: true,
    })
    try {
      const alpha = byKind(await service.spaces(), 'claude-project')[0]
      await service.notes(alpha.id)
      // chokidar is ready a moment after the watch starts.
      await new Promise((resolve) => setTimeout(resolve, 300))
      write(join(f.alphaMemory, 'fresh.md'), '---\nname: fresh\n---\nA new fact about wombats.\n')
      const deadline = Date.now() + 4_000
      while (!changed.includes(alpha.id) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50))
      expect(changed).toContain(alpha.id)
      expect((await service.notes(alpha.id)).map((note) => note.path)).toContain('fresh.md')
      expect((await service.searchIn('wombats', [alpha.id])).map((hit) => hit.path)).toEqual(['fresh.md'])
    } finally {
      await service.close()
    }
  })
})

/* ---------------------------------------------------------------- sharing -- */

describe('sharing one project’s memory with another', () => {
  function ask(answer: boolean | Error): { questions: ShareQuestion[]; consent: (q: ShareQuestion) => Promise<boolean> } {
    const questions: ShareQuestion[] = []
    return {
      questions,
      consent: async (question) => {
        questions.push(question)
        if (answer instanceof Error) throw answer
        return answer
      },
    }
  }

  it('changes nothing when the person says no, or the question fails', async () => {
    const f = fixture()
    for (const answer of [false, new Error('window gone')]) {
      const { questions, consent } = ask(answer)
      const result = await shareProjectMemory({ projectsDir: f.projects, from: '/work/alpha', to: '/work/delta' }, consent)
      expect(result.ok).toBe(false)
      expect(questions).toHaveLength(1)
      expect(existsSync(join(f.projects, '-work-delta', 'memory'))).toBe(false)
    }
  })

  it('makes the link only after a yes, and discovery then shows it as shared', async () => {
    const f = fixture()
    const { questions, consent } = ask(true)
    const result = await shareProjectMemory({ projectsDir: f.projects, from: '/work/alpha', to: '/work/delta' }, consent)
    expect(result).toMatchObject({ ok: true, target: f.alphaMemory })
    expect(questions[0].detail).toContain('/work/delta')
    expect(realpathSync(join(f.projects, '-work-delta', 'memory'))).toBe(f.alphaMemory)
    const alpha = (await discoverSpaces(f.input)).find((space) => space.root === f.alphaMemory)
    expect(alpha?.sharedWith).toContain('-work-delta')
  })

  it('never replaces a folder’s own memory, and does not even ask', async () => {
    const f = fixture()
    const { questions, consent } = ask(true)
    const result = await shareProjectMemory({ projectsDir: f.projects, from: '/work/alpha', to: '/work/gamma' }, consent)
    expect(result.ok).toBe(false)
    expect(questions).toEqual([])
    expect(lstatSync(join(f.projects, '-work-gamma', 'memory')).isSymbolicLink()).toBe(false)
  })
})
