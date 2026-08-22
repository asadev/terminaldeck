import { describe, expect, it } from 'vitest'
import {
  addAttachment,
  addAttachments,
  basename,
  composeMessage,
  foldersFrom,
  insideRoot,
  isAbsolutePath,
  isImagePath,
  kindFor,
  MAX_ATTACHMENTS,
  mentionFor,
  normalise,
  OUTSIDE_FOLDER_CAUTION,
  REJECTION_TEXT,
  relativeTo,
  removeAttachment,
  samePath,
  sendToTerminal,
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
    // The same on the other spelling. `normalise` trimmed `/+$` only, so a
    // folder inserted into a Windows command line arrived as
    // `"C:\\Users\\asad\\project\\"` — a trailing backslash inside double
    // quotes, which cmd.exe reads as escaping the quote.
    expect(shellQuote('C:\\Users\\asad\\project\\')).toBe('"C:\\Users\\asad\\project"')
  })
})

/* ------------------------------------------------------------- windows ----- */

/**
 * The shape all three doors actually hand over on Windows.
 *
 * Every path in this section is a literal `C:\…` or `\\server\…` string, which
 * is what makes these tests worth anything: they are not asking the machine
 * running them what platform it is — there is no Windows machine here and there
 * was none when the bug shipped — they are forcing the *data* the Windows
 * routes produce through the same functions the Mac routes use. Run on this
 * Mac against the code as it stood, every assertion below fails.
 *
 * Where the strings come from, so they cannot drift into being invented:
 * `dialog.showOpenDialog` (Browse), the preload's `webUtils` path for a drop,
 * and the clipboard for a paste all return the native spelling, and
 * `normalisePick` in `main/attach-outside.ts` rewrites only `\\wsl.localhost\…`
 * — `main/wsl.test.ts` pins `linuxPathFromUnc('C:\\Users\\Asad\\proj')` as null.
 */

/** A project as `dialog.showOpenDialog` spells it on Windows. */
const WIN_ROOT = 'C:\\Users\\asad\\Projects\\terminaldeck'

describe('a Windows path', () => {
  describe('absolute, in the spelling this machine cannot produce', () => {
    it('accepts both spellings and a UNC share', () => {
      expect(isAbsolutePath('/Users/apple/Projects/app')).toBe(true)
      expect(isAbsolutePath('C:\\Users\\asad\\app')).toBe(true)
      expect(isAbsolutePath('C:/Users/asad/app')).toBe(true)
      // A mapped share is where a lot of ordinary work lives on a Windows
      // machine. `isAbsoluteCommand` refuses UNC because it decides whether to
      // launch a binary off someone else's file server; reading a file the user
      // just chose in their own panel is a different question.
      expect(isAbsolutePath('\\\\fileserver\\design\\brief.docx')).toBe(true)
    })

    it('still refuses a relative path in either spelling', () => {
      // Reaching both platforms is one gate widened, not removed.
      expect(isAbsolutePath('src/main/index.ts')).toBe(false)
      expect(isAbsolutePath('src\\main\\index.ts')).toBe(false)
      expect(isAbsolutePath('..\\..\\secrets')).toBe(false)
      expect(isAbsolutePath('')).toBe(false)
      // A drive letter with nothing after the colon is `C:`-relative — the
      // current directory on that drive, which nothing here knows.
      expect(isAbsolutePath('C:notes.txt')).toBe(false)
    })
  })

  describe('the blocker itself: adding one', () => {
    it('attaches a file from the project, which used to be refused as not absolute', () => {
      /*
       * This is the whole defect in one assertion. `addAttachment` gated on
       * `target.startsWith('/')`, so this returned
       * `{ ok: false, reason: 'not-absolute' }` and the composer printed "That
       * path is not absolute, so the agent could not resolve it." about a file
       * the user had picked in Explorer two seconds earlier.
       */
      const result = addAttachment([], WIN_ROOT, `${WIN_ROOT}\\src\\main\\index.ts`, false)
      expect(result).toMatchObject({ ok: true })
      if (!result.ok) return
      expect(result.attachments[0]).toEqual({
        path: `${WIN_ROOT}\\src\\main\\index.ts`,
        // The pick's own spelling, not a rewritten one: this string is shown
        // back to the person who chose it.
        relPath: 'src\\main\\index.ts',
        kind: 'file',
      })
    })

    it('attaches a file from anywhere on the disk, which is the outside route', () => {
      const desktop = 'C:\\Users\\asad\\Desktop\\screenshot.PNG'
      const result = addAttachment([], WIN_ROOT, desktop, false, 'anywhere')
      expect(result).toMatchObject({ ok: true })
      if (!result.ok) return
      expect(result.attachments[0]).toEqual({
        path: desktop,
        relPath: desktop,
        kind: 'image',
        outside: true,
      })
    })

    it('attaches from a UNC share', () => {
      const share = '\\\\fileserver\\design\\brief.docx'
      const result = addAttachment([], WIN_ROOT, share, false, 'anywhere')
      expect(result).toMatchObject({ ok: true })
      if (!result.ok) return
      expect(result.attachments[0]?.path).toBe(share)
    })

    it('keeps every file of a Windows batch — Browse, a drop and a paste all fold here', () => {
      const result = addAttachments(
        [],
        WIN_ROOT,
        [
          { path: 'C:\\Users\\asad\\Desktop\\one.png', isDirectory: false },
          { path: '\\\\fileserver\\design\\brief.docx', isDirectory: false },
          { path: `${WIN_ROOT}\\README.md`, isDirectory: false },
        ],
        'anywhere',
      )
      expect(result.attachments.map((a) => a.path)).toEqual([
        'C:\\Users\\asad\\Desktop\\one.png',
        '\\\\fileserver\\design\\brief.docx',
        `${WIN_ROOT}\\README.md`,
      ])
      expect(result.notice).toBeNull()
    })

    it('refuses a relative Windows path, so the gate is widened and not lifted', () => {
      expect(addAttachment([], WIN_ROOT, 'src\\main\\index.ts', false, 'anywhere')).toEqual({
        ok: false,
        reason: 'not-absolute',
      })
    })
  })

  describe('containment', () => {
    it('accepts the root and anything under it', () => {
      expect(insideRoot(WIN_ROOT, WIN_ROOT)).toBe(true)
      expect(insideRoot(WIN_ROOT, `${WIN_ROOT}\\src\\main\\index.ts`)).toBe(true)
      expect(insideRoot(WIN_ROOT, `${WIN_ROOT}\\`)).toBe(true)
    })

    it('rejects a sibling whose name starts with the root', () => {
      // The same directory-traversal-without-a-`..` this suite already pins for
      // POSIX, in the spelling where the separator is a backslash.
      expect(insideRoot(WIN_ROOT, `${WIN_ROOT}-secrets\\.env`)).toBe(false)
    })

    it('holds across the two spellings, because the root and the pick have different sources', () => {
      /*
       * `git rev-parse --show-toplevel` prints forward slashes even on Windows
       * (main/git.ts), while a pick comes from the open panel with backslashes.
       * Comparing those character by character answers no for every file in the
       * project — the same class of failure as `fleet-diff.ts:263`, which is a
       * separate finding in this sweep.
       */
      expect(insideRoot('C:/Users/asad/Projects/terminaldeck', `${WIN_ROOT}\\src\\a.ts`)).toBe(true)
      expect(relativeTo('C:/Users/asad/Projects/terminaldeck', `${WIN_ROOT}\\src\\a.ts`)).toBe(
        'src\\a.ts',
      )
    })

    it('folds case for a Windows path only, because NTFS does and APFS is asked not to', () => {
      expect(insideRoot(WIN_ROOT, 'c:\\users\\asad\\projects\\terminaldeck\\src\\a.ts')).toBe(true)
      // A Mac is not told the same thing. `README.md` and `readme.md` are two
      // files there, and a containment test that folded case would be answering
      // a question about a filesystem it is not on.
      expect(insideRoot('/Users/apple/Projects/App', '/users/apple/projects/app/a.ts')).toBe(false)
    })

    it('does not let a backslash in a POSIX name pass as a separator', () => {
      /*
       * The one thing separator-folding must not buy. `proj\secrets` is a legal
       * file name on a Mac sitting *beside* `proj`, so unifying separators for
       * every path would turn this containment test into a way out of the
       * project. `comparable` therefore only touches a Windows-shaped path.
       */
      expect(insideRoot('/Users/asad/proj', '/Users/asad/proj\\secrets')).toBe(false)
    })

    it('handles the drive root, which is the one path that keeps its separator', () => {
      // `C:\` is the top of the drive; `C:` is the current directory *on* that
      // drive, which is a different place. So `normalise` may not trim it.
      expect(normalise('C:\\')).toBe('C:\\')
      expect(insideRoot('C:\\', 'C:\\Users\\asad\\a.txt')).toBe(true)
    })
  })

  describe('naming', () => {
    it('strips a trailing backslash so one folder has one identity', () => {
      expect(normalise('C:\\a\\b\\')).toBe('C:\\a\\b')
      expect(normalise('  C:\\a\\b  ')).toBe('C:\\a\\b')
    })

    it('reads the last segment', () => {
      /*
       * Split on `/` alone this returned the *whole path*, and that was visible
       * on Windows even with the attach gate shut: `partialRefusal`
       * (outside.ts) names a refused pick with `basename`, and on a confined
       * session every pick was refused because `insideRoot` was POSIX-only too
       * — so the sentence under the composer read
       * "C:\Users\asad\Desktop\shot.png was not attached." where a filename
       * belongs. It is also what every chip's label and the folder in
       * `confinedRefusal` go through.
       */
      expect(basename('C:\\a\\b\\c.ts')).toBe('c.ts')
      expect(basename('C:\\a\\b\\')).toBe('b')
      expect(basename('\\\\fileserver\\design\\brief.docx')).toBe('brief.docx')
    })

    it('names the root by its own folder', () => {
      expect(relativeTo(WIN_ROOT, WIN_ROOT)).toBe('terminaldeck')
    })

    it('recognises an image by extension', () => {
      /*
       * Honest note: this one passed before the fix as well, by accident. The
       * old `basename` handed back the whole path, and the last dot in a whole
       * Windows path is still the extension's — so `isImagePath` is the one
       * function in this file the separator bug happened to miss. It is pinned
       * because it now rides on the *new* `basename`, and because `kindFor` is
       * what tells the chip the model will actually see the file.
       */
      expect(isImagePath('C:\\Users\\asad\\Desktop\\shot.PNG')).toBe(true)
      expect(isImagePath('C:\\Users\\asad\\Projects\\app\\index.ts')).toBe(false)
    })
  })

  describe('one file, however it is spelled', () => {
    it('calls two spellings of one Windows file the same path', () => {
      expect(samePath('C:\\Users\\Asad\\App\\README.md', 'c:\\users\\asad\\app\\readme.md')).toBe(
        true,
      )
      expect(samePath('C:/Users/asad/app/a.ts', 'C:\\Users\\asad\\app\\a.ts')).toBe(true)
      expect(samePath('C:\\a\\b\\', 'C:\\a\\b')).toBe(true)
    })

    it('keeps two POSIX files that differ only in case apart', () => {
      expect(samePath('/Users/apple/app/README.md', '/Users/apple/app/readme.md')).toBe(false)
    })

    it('refuses the same Windows file picked from two panels', () => {
      const first = addAttachment([], WIN_ROOT, `${WIN_ROOT}\\README.md`, false)
      expect(first.ok).toBe(true)
      if (!first.ok) return
      expect(addAttachment(first.attachments, WIN_ROOT, `${WIN_ROOT}\\readme.md`, false)).toEqual({
        ok: false,
        reason: 'duplicate',
      })
    })

    it('removes the chip the duplicate test would have matched', () => {
      // Otherwise a Windows user holds an attachment that can neither be added
      // again nor taken off.
      const list: Attachment[] = [{ path: 'C:\\a\\b', relPath: 'b', kind: 'folder' }]
      expect(removeAttachment(list, 'C:\\A\\B\\')).toEqual([])
    })
  })

  describe('the mention', () => {
    it('carries the path the user picked, backslashes and all', () => {
      // A guard rather than a proof — the old code drew this line correctly
      // too. It is here because the tempting fix for everything above was to
      // rewrite separators on the way in, and that would have changed it.
      expect(mentionFor(file(`${WIN_ROOT}\\src\\main\\index.ts`))).toBe(
        `@"${WIN_ROOT}\\src\\main\\index.ts"`,
      )
    })

    it('marks a folder with the separator the path already uses', () => {
      // Not `C:\a\b/` — the only character this function writes is the one it
      // can get wrong, and the CLI stats the same directory either way.
      expect(mentionFor({ path: 'C:\\a\\b', relPath: 'b', kind: 'folder' })).toBe('@"C:\\a\\b\\"')
      // A forward-slashed Windows path keeps its own spelling too.
      expect(mentionFor({ path: 'C:/a/b', relPath: 'b', kind: 'folder' })).toBe('@"C:/a/b/"')
    })
  })

  describe('folders derived from a Windows file index', () => {
    it('collects every ancestor once', () => {
      // No live caller since the in-app project list was deleted; fixed anyway,
      // because on `/`-only splitting this returned nothing at all for a
      // Windows index and the picker would simply have been empty.
      expect(
        foldersFrom(['src\\main\\index.ts', 'src\\main\\git.ts', 'src\\renderer\\App.tsx', 'README.md']),
      ).toEqual(['src', 'src\\main', 'src\\renderer'])
    })
  })
})

/* ------------------------------------------------------ actually sending -- */

describe('sending a chat message into a session', () => {
  /**
   * The defect this closes, measured in the packed app on 2026-08-22 and
   * photographed: a 145-character message typed into chat mode arrived in Claude
   * Code's input box, the carriage return was read as a newline, the cursor
   * dropped to the next line and nothing was submitted. Both chat composers were
   * doing `write(`${text}\r`)` in one call while this file's own
   * `terminalWrites` had documented the rule for weeks.
   */
  it('writes the message and the return separately, never as one chunk', async () => {
    const writes: string[] = []
    await sendToTerminal('a'.repeat(200), (data) => {
      writes.push(data)
    })
    expect(writes).toHaveLength(2)
    expect(writes[0]).toBe('a'.repeat(200))
    expect(writes[1]).toBe('\r')
    // The failing form, named so a future rewrite cannot reintroduce it.
    expect(writes.some((chunk) => chunk.length >= 64 && chunk.endsWith('\r'))).toBe(false)
  })

  it('keeps the trailing space a mention needs, on the first write only', async () => {
    const writes: string[] = []
    await sendToTerminal('@"/p/a.ts" look', (data) => {
      writes.push(data)
    })
    expect(writes[0]).toBe('@"/p/a.ts" look ')
    expect(writes[1]).toBe('\r')
  })

  it('waits for an asynchronous write to land before sending the return', async () => {
    // The server composer's write is an `invoke`, so the gap has to be between
    // the writes *landing* rather than between the calls being made.
    const order: string[] = []
    await sendToTerminal('hello', async (data) => {
      await new Promise((resolve) => setTimeout(resolve, 5))
      order.push(`landed:${data === '\r' ? 'return' : 'text'}`)
    })
    expect(order).toEqual(['landed:text', 'landed:return'])
  })

  it('leaves a gap the CLI can tell two chunks apart across', async () => {
    const at: number[] = []
    const started = Date.now()
    await sendToTerminal('short', () => {
      at.push(Date.now() - started)
    })
    expect(at[1] - at[0]).toBeGreaterThanOrEqual(SUBMIT_GAP_MS - 5)
  })
})
