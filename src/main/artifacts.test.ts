import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { encodeProjectPath } from './transcript'
import {
  artifactHistory,
  isRecordedAbsolute,
  listArtifacts,
  MAX_CHANGE_CHARS,
  mayCarryFileWrite,
  parseToolTouches,
  relativeToRoot,
} from './artifacts'

/**
 * The whole point of this module is that it does not invent artifacts, so the
 * fixtures are the field layout of real transcript lines rather than a
 * convenient shape: an assistant turn whose `message.content` is an array of
 * blocks, `tool_use` blocks carrying `name` and `input`, an ISO `timestamp` on
 * the line and not on the block. Those are the shapes verified against the 175
 * transcripts on the machine this was written on.
 */

const temps: string[] = []

afterAll(async () => {
  await Promise.all(temps.map((dir) => rm(dir, { recursive: true, force: true })))
})

async function makeProject(): Promise<{ configDir: string; project: string }> {
  const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-artifacts-'))
  temps.push(dir)
  const configDir = join(dir, 'config')
  const project = join(dir, 'project')
  await mkdir(join(configDir, 'projects'), { recursive: true })
  await mkdir(project, { recursive: true })
  return { configDir, project }
}

async function writeTranscript(
  configDir: string,
  cwd: string,
  sessionId: string,
  lines: unknown[],
): Promise<string> {
  const dir = join(configDir, 'projects', encodeProjectPath(cwd))
  await mkdir(dir, { recursive: true })
  const path = join(dir, `${sessionId}.jsonl`)
  await writeFile(path, lines.map((line) => JSON.stringify(line)).join('\n') + '\n', 'utf8')
  return path
}

function toolLine(at: string, blocks: unknown[]): unknown {
  return {
    type: 'assistant',
    isSidechain: false,
    timestamp: at,
    message: { role: 'assistant', model: 'claude-opus-5', content: blocks },
  }
}

function write(path: string, content: string): unknown {
  return { type: 'tool_use', id: 'toolu_1', name: 'Write', input: { file_path: path, content } }
}

function edit(path: string, before: string, after: string, replaceAll = false): unknown {
  return {
    type: 'tool_use',
    id: 'toolu_2',
    name: 'Edit',
    input: { file_path: path, old_string: before, new_string: after, replace_all: replaceAll },
  }
}

/* ------------------------------------------------------------- the parser -- */

describe('mayCarryFileWrite', () => {
  it('passes a line with a tool_use naming a file', () => {
    expect(mayCarryFileWrite('{"type":"tool_use","input":{"file_path":"/a"}}')).toBe(true)
    expect(mayCarryFileWrite('{"type":"tool_use","input":{"notebook_path":"/a"}}')).toBe(true)
  })

  it('rejects the lines that make up the bulk of a transcript', () => {
    // The gate exists because the lines it lets through are also the expensive
    // ones to parse — a single Write line can be half a megabyte.
    expect(mayCarryFileWrite('{"type":"user","message":{"content":"hello"}}')).toBe(false)
    expect(mayCarryFileWrite('{"type":"tool_use","input":{"command":"ls"}}')).toBe(false)
  })
})

describe('parseToolTouches', () => {
  it('reads a Write as a write, with the content it put in', () => {
    const [touch] = parseToolTouches(
      JSON.stringify(toolLine('2026-08-16T10:00:00.000Z', [write('/p/a.ts', 'hello')])),
    )
    expect(touch).toMatchObject({
      path: '/p/a.ts',
      action: 'write',
      before: '',
      after: 'hello',
      tool: 'Write',
    })
    expect(touch.at).toBe(Date.parse('2026-08-16T10:00:00.000Z'))
  })

  it('reads an Edit as both halves of the change', () => {
    const [touch] = parseToolTouches(
      JSON.stringify(toolLine('2026-08-16T10:00:00.000Z', [edit('/p/a.ts', 'old', 'new', true)])),
    )
    expect(touch).toMatchObject({
      action: 'edit',
      before: 'old',
      after: 'new',
      replaceAll: true,
      tool: 'Edit',
    })
  })

  it('reads a NotebookEdit through its own field names', () => {
    // notebook_path/new_source, from the live tool schema. No transcript on
    // this machine contains one, which is exactly why it is pinned here.
    const [touch] = parseToolTouches(
      JSON.stringify(
        toolLine('2026-08-16T10:00:00.000Z', [
          {
            type: 'tool_use',
            name: 'NotebookEdit',
            input: { notebook_path: '/p/n.ipynb', new_source: 'print(1)', edit_mode: 'replace' },
          },
        ]),
      ),
    )
    expect(touch).toMatchObject({ path: '/p/n.ipynb', action: 'edit', after: 'print(1)' })
  })

  it('reads every tool_use on one line, not just the first', () => {
    // The parallel-edit pattern puts several Edit blocks in one content array;
    // reading only the first under-counts every busy turn.
    const touches = parseToolTouches(
      JSON.stringify(
        toolLine('2026-08-16T10:00:00.000Z', [
          { type: 'text', text: 'editing both' },
          edit('/p/a.ts', 'x', 'y'),
          edit('/p/b.ts', 'q', 'r'),
        ]),
      ),
    )
    expect(touches.map((touch) => touch.path)).toEqual(['/p/a.ts', '/p/b.ts'])
  })

  it('ignores tools that do not write files', () => {
    const touches = parseToolTouches(
      JSON.stringify(
        toolLine('2026-08-16T10:00:00.000Z', [
          { type: 'tool_use', name: 'Read', input: { file_path: '/p/a.ts' } },
          { type: 'tool_use', name: 'Bash', input: { command: 'echo hi > /p/b.ts' } },
        ]),
      ),
    )
    // Read changes nothing, and a shell redirect is not something the record
    // can prove happened — guessing at `>` is how the list becomes wrong.
    expect(touches).toEqual([])
  })

  it('drops a relative path rather than resolving it against a guess', () => {
    const touches = parseToolTouches(
      JSON.stringify(toolLine('2026-08-16T10:00:00.000Z', [write('src/a.ts', 'x')])),
    )
    expect(touches).toEqual([])
  })

  it('survives a torn last line', () => {
    expect(parseToolTouches('{"type":"assistant","message":{"cont')).toEqual([])
  })
})

describe('relativeToRoot', () => {
  const root = '/Users/a/proj'

  it('keeps a file inside the project', () => {
    expect(relativeToRoot(root, '/Users/a/proj/src/main.ts')).toBe('src/main.ts')
  })

  it('refuses the root itself — a directory is not an artifact', () => {
    expect(relativeToRoot(root, '/Users/a/proj')).toBeNull()
  })

  it('refuses a sibling whose name merely starts with the root', () => {
    expect(relativeToRoot(root, '/Users/a/proj2/src/main.ts')).toBeNull()
  })

  it('refuses anything outside — the agent edits its own config too', () => {
    // Real transcripts here are full of Edits to ~/.claude/settings.json.
    expect(relativeToRoot(root, '/Users/a/.claude/settings.json')).toBeNull()
  })
})

describe('isRecordedAbsolute', () => {
  it('accepts both spellings a transcript can carry', () => {
    expect(isRecordedAbsolute('/Users/a/x.ts')).toBe(true)
    expect(isRecordedAbsolute('C:\\src\\x.ts')).toBe(true)
    expect(isRecordedAbsolute('src/x.ts')).toBe(false)
    expect(isRecordedAbsolute('')).toBe(false)
  })
})

/* --------------------------------------------------------------- the list -- */

describe('listArtifacts', () => {
  it('gathers the files an agent wrote and edited, newest first', async () => {
    const { configDir, project } = await makeProject()
    await writeFile(join(project, 'a.ts'), 'const a = 1\n', 'utf8')
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'a.ts'), 'const a = 0\n')]),
      toolLine('2026-08-16T10:05:00.000Z', [edit(join(project, 'a.ts'), '0', '1')]),
      toolLine('2026-08-16T10:10:00.000Z', [write(join(project, 'docs/plan.md'), '# Plan\n')]),
    ])

    const result = await listArtifacts(project, { configDir, deviceHomes: null })

    expect(result.artifacts.map((artifact) => artifact.relPath)).toEqual(['docs/plan.md', 'a.ts'])
    const [plan, a] = result.artifacts
    expect(plan).toMatchObject({ name: 'plan.md', writes: 1, edits: 0, lastTool: 'Write' })
    expect(a).toMatchObject({ name: 'a.ts', writes: 1, edits: 1, lastTool: 'Edit' })
    expect(a.firstAt).toBe(Date.parse('2026-08-16T10:00:00.000Z'))
    expect(a.lastAt).toBe(Date.parse('2026-08-16T10:05:00.000Z'))
  })

  it('says which files are still on disk and which are gone', async () => {
    const { configDir, project } = await makeProject()
    await writeFile(join(project, 'kept.ts'), 'kept\n', 'utf8')
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'kept.ts'), 'kept\n')]),
      toolLine('2026-08-16T10:01:00.000Z', [write(join(project, 'scratch.tmp'), 'gone\n')]),
    ])

    const result = await listArtifacts(project, { configDir, deviceHomes: null })
    const byPath = new Map(result.artifacts.map((artifact) => [artifact.relPath, artifact]))

    // A row that offers to open a deleted scratch file is offering a read
    // error, so the list has to know the difference.
    expect(byPath.get('kept.ts')?.onDisk?.bytes).toBe(5)
    expect(byPath.get('scratch.tmp')?.onDisk).toBeNull()
  })

  it('counts the agent’s edits outside the project instead of listing them', async () => {
    const { configDir, project } = await makeProject()
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [edit('/Users/a/.claude/settings.json', 'x', 'y')]),
      toolLine('2026-08-16T10:01:00.000Z', [write(join(project, 'in.ts'), 'in\n')]),
    ])

    const result = await listArtifacts(project, { configDir, deviceHomes: null })
    expect(result.artifacts.map((artifact) => artifact.relPath)).toEqual(['in.ts'])
    expect(result.outsideProject).toBe(1)
  })

  it('merges the same file across sessions and reports both', async () => {
    const { configDir, project } = await makeProject()
    await writeTranscript(configDir, project, 'older', [
      toolLine('2026-08-15T09:00:00.000Z', [write(join(project, 'a.ts'), 'v1\n')]),
    ])
    await writeTranscript(configDir, project, 'newer', [
      toolLine('2026-08-16T09:00:00.000Z', [edit(join(project, 'a.ts'), 'v1', 'v2')]),
    ])

    const result = await listArtifacts(project, { configDir, deviceHomes: null })
    expect(result.artifacts).toHaveLength(1)
    // Newest session first — the one somebody reviewing is looking for.
    expect(result.artifacts[0].sessionIds).toEqual(['newer', 'older'])
    expect(result.sessions.map((session) => session.sessionId)).toEqual(['newer', 'older'])
    expect(result.sessions[0].files).toBe(1)
  })

  it('finds work an agent did from a parent workspace, under the wider scope', async () => {
    // The case that made this module look broken, reproduced. Measured on this
    // machine: /Users/apple/Projects/terminaldeck has 16 transcripts of its own
    // holding zero file writes, while 193 real Write/Edit calls into that same
    // folder sit under -Users-apple-ClaudeAsad, because the agent was launched
    // from a parent workspace and reached in.
    const { configDir, project } = await makeProject()
    const orchestrator = join(project, '..', 'workspace')
    await writeTranscript(configDir, orchestrator, 'from-parent', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'src/deep.ts'), 'reached in\n')]),
    ])

    const own = await listArtifacts(project, { configDir, deviceHomes: null, skipDiskCheck: true })
    expect(own.artifacts).toEqual([])
    expect(own.scope).toBe('project')

    const all = await listArtifacts(project, {
      configDir,
      deviceHomes: null,
      scope: 'all',
      skipDiskCheck: true,
    })
    expect(all.artifacts.map((artifact) => artifact.relPath)).toEqual(['src/deep.ts'])
    expect(all.scope).toBe('all')
  })

  it('does not drag another project’s files in under the wider scope', async () => {
    // Widening which transcripts are *read* must not widen which files are
    // *kept* — the root check is what makes "all sessions" honest.
    const { configDir, project } = await makeProject()
    const elsewhere = join(project, '..', 'other-repo')
    await writeTranscript(configDir, elsewhere, 'other', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(elsewhere, 'x.ts'), 'not ours\n')]),
    ])

    const all = await listArtifacts(project, {
      configDir,
      deviceHomes: null,
      scope: 'all',
      skipDiskCheck: true,
    })
    expect(all.artifacts).toEqual([])
    expect(all.outsideProject).toBe(1)
  })

  it('is empty, and says so honestly, for a project no agent has written in', async () => {
    const { configDir, project } = await makeProject()
    const result = await listArtifacts(project, { configDir, deviceHomes: null })
    expect(result.artifacts).toEqual([])
    expect(result.sessionsScanned).toBe(0)
    expect(result.truncated).toBe(false)
  })

  it('reports truncation rather than silently shortening the list', async () => {
    const { configDir, project } = await makeProject()
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'a.ts'), 'a')]),
      toolLine('2026-08-16T10:01:00.000Z', [write(join(project, 'b.ts'), 'b')]),
      toolLine('2026-08-16T10:02:00.000Z', [write(join(project, 'c.ts'), 'c')]),
    ])

    const result = await listArtifacts(project, {
      configDir,
      deviceHomes: null,
      maxArtifacts: 2,
      skipDiskCheck: true,
    })
    expect(result.artifacts).toHaveLength(2)
    expect(result.truncated).toBe(true)
  })

  it('stops at the time budget instead of reading a whole history', async () => {
    const { configDir, project } = await makeProject()
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'a.ts'), 'a')]),
    ])
    await writeTranscript(configDir, project, 'sess-2', [
      toolLine('2026-08-16T09:00:00.000Z', [write(join(project, 'b.ts'), 'b')]),
    ])

    // A clock that is already past the deadline on its second reading, so the
    // budget is proven to bite without the test depending on machine speed.
    let ticks = 0
    const result = await listArtifacts(project, {
      configDir,
      deviceHomes: null,
      skipDiskCheck: true,
      timeBudgetMs: 1,
      clock: () => (ticks++ === 0 ? 0 : 1_000_000),
    })
    expect(result.truncated).toBe(true)
    expect(result.sessionsScanned).toBeLessThan(2)
  })
})

/* ------------------------------------------------------------ one history -- */

describe('artifactHistory', () => {
  it('returns every recorded change to one file, newest first', async () => {
    const { configDir, project } = await makeProject()
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'a.ts'), 'const a = 0\n')]),
      toolLine('2026-08-16T10:05:00.000Z', [edit(join(project, 'a.ts'), '0', '1')]),
      toolLine('2026-08-16T10:06:00.000Z', [edit(join(project, 'other.ts'), 'p', 'q')]),
    ])

    const history = await artifactHistory(project, 'a.ts', { configDir, deviceHomes: null })
    expect(history.changes).toHaveLength(2)
    expect(history.changes[0]).toMatchObject({
      action: 'edit',
      before: '0',
      after: '1',
      sessionId: 'sess-1',
    })
    expect(history.changes[1]).toMatchObject({ action: 'write', before: '', after: 'const a = 0\n' })
  })

  it('clips a huge write and admits it', async () => {
    const { configDir, project } = await makeProject()
    const huge = 'x'.repeat(MAX_CHANGE_CHARS + 500)
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'big.txt'), huge)]),
    ])

    const history = await artifactHistory(project, 'big.txt', { configDir, deviceHomes: null })
    expect(history.changes[0].after).toHaveLength(MAX_CHANGE_CHARS)
    expect(history.changes[0].clipped).toBe(true)
  })

  it('refuses a path that climbs out of the project', async () => {
    const { configDir, project } = await makeProject()
    await writeTranscript(configDir, project, 'sess-1', [
      toolLine('2026-08-16T10:00:00.000Z', [write(join(project, 'a.ts'), 'a')]),
    ])

    // The renderer is not trusted with a path, and this one would otherwise
    // read a file from outside the folder being shown.
    const history = await artifactHistory(project, '../../etc/hosts', {
      configDir,
      deviceHomes: null,
    })
    expect(history.changes).toEqual([])
  })
})
