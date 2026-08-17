import { describe, expect, it } from 'vitest'
import {
  addAttachment,
  addAttachments,
  basename,
  composeMessage,
  foldersFrom,
  insideRoot,
  isImagePath,
  kindFor,
  MAX_ATTACHMENTS,
  mentionFor,
  normalise,
  OUTSIDE_FOLDER_CAUTION,
  REJECTION_TEXT,
  relativeTo,
  removeAttachment,
  shellQuote,
  SUBMIT_GAP_MS,
  terminalPayload,
  terminalWrites,
  type AttachCandidate,
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

  /*
   * The escape hatch, and the reason it is a parameter rather than a relaxation.
   *
   * "I should be able to take anything from my PC to paste here" is the request,
   * and the answer is not to stop checking — it is to make the three routes that
   * genuinely reach outside say so at the call. The project-scoped picker keeps
   * the old behaviour by default, so it cannot start producing outside paths
   * because somebody changed a shared function.
   */
  describe('a path from outside the project', () => {
    const DESKTOP = '/Users/apple/Desktop/screenshot.png'

    it('is still refused when the caller did not ask to reach outside', () => {
      expect(addAttachment([], ROOT, DESKTOP, false)).toEqual({
        ok: false,
        reason: 'outside-root',
      })
    })

    it('is accepted when the caller says anywhere, and is marked as outside', () => {
      const result = addAttachment([], ROOT, DESKTOP, false, 'anywhere')
      expect(result.ok).toBe(true)
      if (!result.ok) return
      expect(result.attachments[0]).toEqual({
        path: DESKTOP,
        // The absolute path, not a slice of the wrong string. `relativeTo`
        // slices by the root's length, so pointed at a path outside the root it
        // returns a fragment rather than an error — which is why the label for
        // an outside file has to be the whole path.
        relPath: DESKTOP,
        kind: 'image',
        outside: true,
      })
    })

    it('leaves an inside path unmarked even when anywhere was allowed', () => {
      // Absent rather than `outside: false`, so the common case keeps exactly
      // the shape it has always had.
      const result = addAttachment([], ROOT, `${ROOT}/src/main/index.ts`, false, 'anywhere')
      expect(result.ok).toBe(true)
      if (!result.ok) return
      expect('outside' in result.attachments[0]).toBe(false)
      expect(result.attachments[0].relPath).toBe('src/main/index.ts')
    })

    it('still refuses a relative path, a duplicate and a full list', () => {
      // Reaching outside the project is one gate coming down, not all of them.
      expect(addAttachment([], ROOT, 'Desktop/x.png', false, 'anywhere')).toEqual({
        ok: false,
        reason: 'not-absolute',
      })
      const first = addAttachment([], ROOT, DESKTOP, false, 'anywhere')
      expect(first.ok).toBe(true)
      if (!first.ok) return
      expect(addAttachment(first.attachments, ROOT, DESKTOP, false, 'anywhere')).toEqual({
        ok: false,
        reason: 'duplicate',
      })
    })

    /*
     * The bug this suite would not have caught on its own.
     *
     * Two files dropped on the composer produced one chip. `addAttachment` was
     * right; the composer called it in a loop, and every call in that loop read
     * the same list, so each result discarded the one before it. Nothing that
     * attaches one thing at a time can see it — which is every other test here.
     */
    describe('a whole batch at once', () => {
      it('keeps every file, not just the last one', () => {
        const result = addAttachments(
          [],
          ROOT,
          [
            { path: '/Users/apple/Desktop/one.png', isDirectory: false },
            { path: '/tmp/two.txt', isDirectory: false },
            { path: `${ROOT}/README.md`, isDirectory: false },
          ],
          'anywhere',
        )
        expect(result.attachments.map((a) => a.path)).toEqual([
          '/Users/apple/Desktop/one.png',
          '/tmp/two.txt',
          `${ROOT}/README.md`,
        ])
        expect(result.notice).toBeNull()
      })

      it('applies the ceiling across the batch rather than per file', () => {
        const full: AttachCandidate[] = Array.from({ length: MAX_ATTACHMENTS + 3 }, (_, i) => ({
          path: `/tmp/f${i}.txt`,
          isDirectory: false,
        }))
        const result = addAttachments([], ROOT, full, 'anywhere')
        expect(result.attachments).toHaveLength(MAX_ATTACHMENTS)
        expect(result.notice).toBe(REJECTION_TEXT.full)
      })

      it('reports a refusal ahead of a caution', () => {
        // Someone who dropped a folder onto a full list needs to know the list
        // is full, not that the folder was outside the project.
        const result = addAttachments(
          [],
          ROOT,
          [
            { path: '/tmp/outside-folder', isDirectory: true },
            { path: 'not-absolute', isDirectory: false },
          ],
          'anywhere',
        )
        expect(result.notice).toBe(REJECTION_TEXT['not-absolute'])
      })

      it('cautions about a folder from outside, which is the one measured exception', () => {
        const result = addAttachments(
          [],
          ROOT,
          [{ path: '/tmp/outside-folder', isDirectory: true }],
          'anywhere',
        )
        expect(result.attachments).toHaveLength(1)
        expect(result.notice).toBe(OUTSIDE_FOLDER_CAUTION)
      })

      it('says nothing about a folder inside the project, which works normally', () => {
        const result = addAttachments([], ROOT, [{ path: `${ROOT}/src`, isDirectory: true }])
        expect(result.notice).toBeNull()
      })

      it('still defaults to the project, so a batch cannot smuggle an outside path', () => {
        const result = addAttachments([], ROOT, [
          { path: '/Users/apple/Desktop/one.png', isDirectory: false },
        ])
        expect(result.attachments).toEqual([])
        expect(result.notice).toBe(REJECTION_TEXT['outside-root'])
      })
    })

    it('mentions an outside file by its absolute path, which is what the CLI expands', () => {
      const result = addAttachment([], ROOT, DESKTOP, false, 'anywhere')
      expect(result.ok).toBe(true)
      if (!result.ok) return
      expect(mentionFor(result.attachments[0])).toBe(`@"${DESKTOP}"`)
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

describe('a path typed at a shell prompt', () => {
  it('quotes an ordinary path, so a space cannot split it into two arguments', () => {
    expect(shellQuote('/Users/asad/My Project/notes.md')).toBe("'/Users/asad/My Project/notes.md'")
  })

  it('leaves the shell nothing to expand inside the quotes', () => {
    // Single quotes rather than double ones for exactly this: in double quotes
    // `$HOME` and a backtick are still live, so a file literally called
    // `$HOME` would be replaced by the home directory on its way to the pty.
    const quoted = shellQuote('/tmp/$HOME `whoami` "x" \\n')
    expect(quoted).toBe("'/tmp/$HOME `whoami` \"x\" \\n'")
  })

  it("closes, escapes and reopens around an apostrophe — the one character single quotes cannot hold", () => {
    // `'it'\''s'` is the standard form, and it is the whole reason this is a
    // function rather than a template literal at the call site.
    expect(shellQuote("/Users/asad/it's here/a.txt")).toBe("'/Users/asad/it'\\''s here/a.txt'")
  })

  it('uses double quotes for a Windows path, which cmd.exe parses and sh does not', () => {
    // The style follows the path rather than the machine, because on Windows a
    // POSIX path launches through wsl.exe and a drive-letter path through
    // cmd.exe — the same rule sessions themselves are routed by.
    expect(shellQuote('C:/Users/asad/My Project')).toBe('"C:/Users/asad/My Project"')
    expect(shellQuote('\\\\server\\share\\file.txt')).toBe('"\\\\server\\share\\file.txt"')
  })

  it('drops a trailing separator, so a folder arrives as one word', () => {
    expect(shellQuote('/Users/asad/project/')).toBe("'/Users/asad/project'")
  })
})
