import { describe, expect, it } from 'vitest'
import {
  addAttachment,
  basename,
  composeMessage,
  foldersFrom,
  insideRoot,
  isImagePath,
  kindFor,
  MAX_ATTACHMENTS,
  mentionFor,
  normalise,
  relativeTo,
  removeAttachment,
  SUBMIT_GAP_MS,
  terminalPayload,
  terminalWrites,
  type Attachment,
} from './mentions'

const ROOT = '/Users/apple/Projects/terminaldeck'

function file(path: string): Attachment {
  return { path, relPath: relativeTo(ROOT, path), kind: kindFor(path, false) }
}

describe('containment', () => {
  it('accepts the root and anything under it', () => {
    expect(insideRoot(ROOT, ROOT)).toBe(true)
    expect(insideRoot(ROOT, `${ROOT}/src/main/index.ts`)).toBe(true)
    expect(insideRoot(ROOT, `${ROOT}/`)).toBe(true)
  })

  it('rejects a sibling whose name starts with the root', () => {
    // The separator is the whole test. A plain startsWith lets
    // `terminaldeck-secrets` through, which is a directory traversal with no
    // `..` in it at all.
    expect(insideRoot(ROOT, `${ROOT}-secrets/.env`)).toBe(false)
  })

  it('rejects paths outside the project and relative paths', () => {
    expect(insideRoot(ROOT, '/etc/passwd')).toBe(false)
    expect(insideRoot(ROOT, '/Users/apple/.ssh/id_rsa')).toBe(false)
    expect(insideRoot(ROOT, 'src/main/index.ts')).toBe(false)
  })
})

describe('naming', () => {
  it('strips trailing separators so one path has one identity', () => {
    expect(normalise('/a/b/')).toBe('/a/b')
    expect(normalise('/a/b')).toBe('/a/b')
    expect(normalise('/')).toBe('/')
  })

  it('relates a path to the root, and names the root by its own folder', () => {
    expect(relativeTo(ROOT, `${ROOT}/src/renderer/App.tsx`)).toBe('src/renderer/App.tsx')
    expect(relativeTo(ROOT, ROOT)).toBe('terminaldeck')
  })

  it('reads the last segment', () => {
    expect(basename('/a/b/c.ts')).toBe('c.ts')
    expect(basename('/a/b/')).toBe('b')
  })

  it('recognises images by extension, case-insensitively', () => {
    expect(isImagePath('/a/shot.PNG')).toBe(true)
    expect(isImagePath('/a/diagram.svg')).toBe(true)
    expect(isImagePath('/a/index.ts')).toBe(false)
    expect(isImagePath('/a/png')).toBe(false)
  })
})

describe('the mention form', () => {
  it('always quotes, because backslash escaping does not work', () => {
    // Measured: `@a\ b/c.txt` expands to nothing at all, and quoting a path
    // with no spaces is harmless. One form, no branching on the path.
    expect(mentionFor(file('/a/b/c.ts'))).toBe('@"/a/b/c.ts"')
    expect(mentionFor(file('/a/with space/c.ts'))).toBe('@"/a/with space/c.ts"')
  })

  it('keeps a trailing slash on a folder, which is what makes it list', () => {
    expect(mentionFor({ path: '/a/b', relPath: 'b', kind: 'folder' })).toBe('@"/a/b/"')
  })
})

describe('composing the message', () => {
  const one = file(`${ROOT}/src/main/index.ts`)
  const two = file(`${ROOT}/README.md`)

  it('puts mentions first and the question after', () => {
    expect(composeMessage([one, two], 'why is this slow?')).toBe(
      `@"${ROOT}/src/main/index.ts" @"${ROOT}/README.md" why is this slow?`,
    )
  })

  it('sends the mentions alone when nothing was typed', () => {
    expect(composeMessage([one], '   ')).toBe(`@"${ROOT}/src/main/index.ts"`)
  })

  it('leaves an unattached message untouched', () => {
    expect(composeMessage([], '  hello  ')).toBe('hello')
  })
})

describe('what actually reaches the terminal', () => {
  it('closes the completion popup with a space when the line has a mention', () => {
    // Without this the Enter is eaten by the CLI's own file picker: it accepts
    // the highlighted suggestion, replaces the line with a bare path, and the
    // message is never sent. Reproduced through a real pty before it was fixed.
    expect(terminalPayload('@"/a/b.ts" explain')).toBe('@"/a/b.ts" explain ')
  })

  it('covers a mention the user typed themselves, not only ours', () => {
    expect(terminalPayload('look at @src/main/index.ts')).toBe('look at @src/main/index.ts ')
  })

  it('leaves an ordinary message alone', () => {
    expect(terminalPayload('run the tests')).toBe('run the tests')
  })

  it('keeps the carriage return out of the message write', () => {
    // The CLI classifies a whole stdin chunk before it reads the keys in it,
    // and 64 bytes or more is pasted text — where Enter is a newline, not
    // submit. Measured through a pty: 57 bytes in one write submits, 64 does
    // not, and every message carrying a mention is well past that. So the two
    // halves travel separately, with a gap, or nothing is ever sent.
    const [text, submit] = terminalWrites('@"/a/b.ts" explain')
    expect(text).toBe('@"/a/b.ts" explain ')
    expect(submit).toBe('\r')
    expect(text).not.toContain('\r')
    expect(SUBMIT_GAP_MS).toBeGreaterThanOrEqual(30)
  })

  it('splits a short ordinary message the same way, so there is one path', () => {
    expect(terminalWrites('run the tests')).toEqual(['run the tests', '\r'])
  })
})

describe('the attachment list', () => {
  it('adds a file inside the project', () => {
    const result = addAttachment([], ROOT, `${ROOT}/src/main/index.ts`, false)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.attachments[0]).toEqual({
      path: `${ROOT}/src/main/index.ts`,
      relPath: 'src/main/index.ts',
      kind: 'file',
    })
  })

  it('marks an image so the chip can say the agent will see it', () => {
    const result = addAttachment([], ROOT, `${ROOT}/build/icon.png`, false)
    expect(result.ok && result.attachments[0].kind).toBe('image')
  })

  it('refuses a path outside the project', () => {
    expect(addAttachment([], ROOT, '/Users/apple/.ssh/id_rsa', false)).toEqual({
      ok: false,
      reason: 'outside-root',
    })
  })

  it('refuses a relative path', () => {
    expect(addAttachment([], ROOT, 'src/main/index.ts', false)).toEqual({
      ok: false,
      reason: 'not-absolute',
    })
  })

  it('refuses the same path twice, however it was written', () => {
    const first = addAttachment([], ROOT, `${ROOT}/src`, true)
    expect(first.ok).toBe(true)
    if (!first.ok) return
    expect(addAttachment(first.attachments, ROOT, `${ROOT}/src/`, true)).toEqual({
      ok: false,
      reason: 'duplicate',
    })
  })

  it('caps the list', () => {
    let list: Attachment[] = []
    for (let i = 0; i < MAX_ATTACHMENTS; i++) {
      const step = addAttachment(list, ROOT, `${ROOT}/f${i}.ts`, false)
      expect(step.ok).toBe(true)
      if (step.ok) list = step.attachments
    }
    expect(addAttachment(list, ROOT, `${ROOT}/one-more.ts`, false)).toEqual({
      ok: false,
      reason: 'full',
    })
  })

  it('removes by path, tolerating a trailing separator', () => {
    const list: Attachment[] = [{ path: '/a/b', relPath: 'b', kind: 'folder' }]
    expect(removeAttachment(list, '/a/b/')).toEqual([])
  })
})

describe('folders derived from the file index', () => {
  it('collects every ancestor once, sorted', () => {
    expect(foldersFrom(['src/main/index.ts', 'src/main/git.ts', 'src/renderer/App.tsx', 'README.md']))
      .toEqual(['src', 'src/main', 'src/renderer'])
  })

  it('has no entry for a file at the top level', () => {
    expect(foldersFrom(['package.json'])).toEqual([])
  })
})
