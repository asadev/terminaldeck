import { describe, expect, it } from 'vitest'
import { BRAND } from '../../shared/brand'
import { contextFor, fakeSurface, toolNamed } from './sessions-lane.fixture'
import { filesTools, MAX_UPLOAD_BYTES, rankMatches, secretShapeOf, type FilesToolDeps } from './files-tools'

function depsWith(overrides: Partial<FilesToolDeps> = {}): { deps: FilesToolDeps; calls: string[] } {
  const calls: string[] = []
  const deps: FilesToolDeps = {
    listDir: async (_root, relDir) => ({
      entries: [{ name: 'src', relPath: relDir === '' ? 'src' : `${relDir}/src`, kind: 'dir', symlink: false, blocked: false, bytes: 1 }],
      truncated: false,
    }),
    readFile: async (_root, relPath) => ({
      kind: 'text',
      relPath,
      text: Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join('\n'),
      bytes: 70,
      lines: 10,
    }),
    listFiles: async (_root, options) => {
      calls.push(`list refresh=${options.refresh}`)
      return { files: ['src/login/form.ts', 'src/app.ts', 'docs/login.md', 'test/login-form.test.ts'], truncated: false, source: 'git' }
    },
    ignore: {
      overview: async (root) => ({ root, sources: [], ruleCount: 0 }),
      explain: async (_root, relPath) => ({ relPath, ignored: true }),
      filter: async (_root, paths) => paths.filter((path) => !path.startsWith('dist/')),
      invalidate: (root) => {
        calls.push(`invalidate ${root}`)
      },
    },
    stage: async (name, bytes) => {
      calls.push(`stage ${name} ${bytes.byteLength}`)
      return { ok: true, path: `/Users/me/Downloads/${BRAND.name}/${name}` }
    },
    boundaryOf: () => null,
    bringIn: async (source, folder) => {
      calls.push(`copy ${source}`)
      return `${folder}/${BRAND.name}/${source.split('/').pop() ?? ''}`
    },
    isDirectory: async (path) => (path.endsWith('/') || path === '/Users/me/folder' ? true : path.includes('missing') ? null : false),
    ...overrides,
  }
  return { deps, calls }
}

describe('credential files', () => {
  it('recognises the shapes the sandbox carves out, at any depth', () => {
    expect(secretShapeOf('.env')?.name).toBe('dotenv')
    expect(secretShapeOf('config/.env.production')?.name).toBe('dotenv')
    expect(secretShapeOf('deploy/key.pem')?.name).toBe('private-key-file')
    expect(secretShapeOf('.npmrc')?.name).toBe('registry-auth')
    expect(secretShapeOf('/Users/me/.ssh/id_ed25519')).not.toBeNull()
  })

  it('leaves the templates readable, because they are how a repo documents what it needs', () => {
    expect(secretShapeOf('.env.example')).toBeNull()
    expect(secretShapeOf('src/.env.d.ts')).toBeNull()
    expect(secretShapeOf('src/environment.ts')).toBeNull()
  })

  it('refuses to read one before anything is opened', () => {
    const { surface } = fakeSurface()
    const read = toolNamed(filesTools(depsWith().deps), 'files.read')
    expect(() => read.precheck?.({ cwd: '/work/api', path: 'server/.env' }, contextFor(surface))).toThrow(/credential file/)
  })
})

describe('reading a project', () => {
  it('pages through a file by lines', async () => {
    const { surface } = fakeSurface()
    const read = toolNamed(filesTools(depsWith().deps), 'files.read')
    const page = (await read.run({ cwd: '/work/api', path: 'src/app.ts', fromLine: 4, lines: 3 }, contextFor(surface))).value
    expect(page).toMatchObject({ fromLine: 4, toLine: 6, more: true, text: 'line 4\nline 5\nline 6' })
  })

  it('stays inside the project folder and inside the folders this app has open', () => {
    const { surface } = fakeSurface()
    const read = toolNamed(filesTools(depsWith().deps), 'files.read')
    expect(() => read.precheck?.({ cwd: '/work/api', path: '../web/x.ts' }, contextFor(surface))).toThrow(/inside the project/)
    expect(() => read.precheck?.({ cwd: '/work/api', path: '/etc/passwd' }, contextFor(surface))).toThrow(/relative/)
    expect(() => read.precheck?.({ cwd: '/etc', path: 'passwd' }, contextFor(surface))).toThrow(/not a folder this app has open/)
  })

  it('lists one level, without sizes unless asked', async () => {
    const { surface } = fakeSurface()
    const list = toolNamed(filesTools(depsWith().deps), 'files.list')
    const plain = (await list.run({ cwd: '/work/api' }, contextFor(surface))).value as { entries: Array<Record<string, unknown>> }
    expect(plain.entries[0]).not.toHaveProperty('bytes')
  })

  it('finds by every word, file-name matches first, and lists again when asked', async () => {
    expect(rankMatches(['src/login/form.ts', 'test/login-form.test.ts', 'docs/login.md'], ['login', 'form'])).toEqual([
      'test/login-form.test.ts',
      'src/login/form.ts',
    ])
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    await toolNamed(filesTools(deps), 'files.find').run({ cwd: '/work/api', query: 'login', refresh: true }, contextFor(surface))
    expect(calls).toEqual(['list refresh=true'])
  })

  it('re-reads the ignore rules when asked, then explains', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const output = await toolNamed(filesTools(deps), 'files.ignored').run(
      { action: 'filter', cwd: '/work/api', paths: ['dist/a.js', 'src/a.ts'], refresh: true },
      contextFor(surface),
    )
    expect(calls).toEqual(['invalidate /work/api'])
    expect(output.value).toMatchObject({ kept: ['src/a.ts'], hidden: ['dist/a.js'] })
  })
})

describe('putting a file on this machine', () => {
  it('stages the bytes and answers with a path and the mention to type', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const output = await toolNamed(filesTools(deps), 'files.upload').run(
      { name: 'shot.png', contentBase64: Buffer.from('png bytes').toString('base64') },
      contextFor(surface),
    )
    expect(calls).toEqual(['stage shot.png 9'])
    expect(output.value).toMatchObject({ mention: `@"/Users/me/Downloads/${BRAND.name}/shot.png"` })
  })

  it('refuses a file larger than the transport can carry, with the reason', () => {
    const { surface } = fakeSurface()
    const upload = toolNamed(filesTools(depsWith().deps), 'files.upload')
    const big = Buffer.alloc(MAX_UPLOAD_BYTES + 1).toString('base64')
    expect(() => upload.precheck?.({ name: 'big.bin', contentBase64: big }, contextFor(surface))).toThrow(/at most/)
    expect(() => upload.precheck?.({ name: 'x', contentBase64: 'not base64!' }, contextFor(surface))).toThrow(/base64/)
  })

  it('keeps the bytes out of the action log', () => {
    const upload = toolNamed(filesTools(depsWith().deps), 'files.upload')
    expect(upload.redactArgs?.({ name: 'a.txt', contentBase64: 'aGVsbG8=' })).toEqual({
      name: 'a.txt',
      contentBase64: '[8 base64 characters]',
    })
  })
})

describe('giving a session files', () => {
  it('copies into a held session’s folder, and leaves an ordinary session reading the original', async () => {
    const { surface } = fakeSurface()
    const held = depsWith({ boundaryOf: () => ({ folder: '/work/api', readableProjects: ['/work/web'] }) })
    const attachHeld = toolNamed(filesTools(held.deps), 'sessions.attach')
    const inside = (await attachHeld.run({ sessionId: 's1', paths: ['/Users/me/Desktop/shot.png'] }, contextFor(surface))).value
    expect(held.calls).toEqual(['copy /Users/me/Desktop/shot.png'])
    expect(inside).toMatchObject({
      heldInFolder: '/work/api',
      attached: [{ path: `/work/api/${BRAND.name}/shot.png`, mention: `@"/work/api/${BRAND.name}/shot.png"` }],
    })

    const plain = depsWith()
    const loose = (await toolNamed(filesTools(plain.deps), 'sessions.attach').run(
      { sessionId: 's1', paths: ['/Users/me/Desktop/shot.png', '/Users/me/folder'] },
      contextFor(surface),
    )).value
    expect(plain.calls).toEqual([])
    expect(loose).toMatchObject({
      heldInFolder: null,
      attached: [{ path: '/Users/me/Desktop/shot.png' }, { path: '/Users/me/folder', mention: '@"/Users/me/folder/"' }],
    })
  })

  it('will not hand a session a key or a .env, whoever asks', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith({ boundaryOf: () => ({ folder: '/work/api', readableProjects: [] }) })
    const output = (await toolNamed(filesTools(deps), 'sessions.attach').run(
      { sessionId: 's1', paths: ['/Users/me/.ssh/id_rsa', '/Users/me/app/.env'] },
      contextFor(surface),
    )).value as { attached: unknown[]; refused: Array<{ why: string }> }
    expect(calls).toEqual([])
    expect(output.attached).toEqual([])
    expect(output.refused.map((entry) => entry.why)).toEqual([
      'it is a credential file (ssh-private-key)',
      'it is a credential file (dotenv)',
    ])
  })

  it('is a read when it only asks, and follows whose session it is when it copies', () => {
    const { surface } = fakeSurface()
    const attach = toolNamed(filesTools(depsWith().deps), 'sessions.attach')
    expect(attach.escalate?.({ sessionId: 's1' }, contextFor(surface))).toBe('read')
    expect(attach.escalate?.({ sessionId: 's1', paths: ['/a'] }, contextFor(surface, { own: ['s1'] }))).toBe('act')
    expect(attach.escalate?.({ sessionId: 's1', paths: ['/a'] }, contextFor(surface))).toBe('alter')
  })
})
