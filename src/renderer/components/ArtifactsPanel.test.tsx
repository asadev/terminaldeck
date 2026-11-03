import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ArtifactRow,
  ArtifactsPanel,
  ChangeBody,
  changeSummary,
  describeRead,
  diffLines,
  directoryOf,
  fileUrl,
  isArtifact,
  kindOf,
  nothingButFiles,
  nothingFound,
  onlyArtifacts,
  openLabel,
  previewKindOf,
  wasMade,
  ARTIFACT_EXTENSIONS,
  MAX_DIFF_LINES,
  SCAN_FRESH_MS,
  scanOutcome,
  splitLines,
  summarize,
  type Artifact,
  type ArtifactChange,
  type ArtifactList,
  type ArtifactsBridge,
} from './ArtifactsPanel'

/**
 * There is no DOM environment in this project's test setup, so these render to
 * static markup. That covers the diff alignment, the honesty of the summary
 * line and the accessible structure — the parts most likely to rot. The async
 * load is state, and is exercised through `src/main/artifacts.test.ts` against
 * real transcript fixtures.
 */

const NOW = Date.parse('2026-08-16T12:00:00.000Z')

function artifact(overrides: Partial<Artifact> & { relPath: string }): Artifact {
  const relPath = overrides.relPath
  return {
    name: relPath.slice(relPath.lastIndexOf('/') + 1),
    firstAt: NOW - 3600_000,
    lastAt: NOW - 600_000,
    writes: 1,
    edits: 0,
    lastChars: 40,
    lastTool: 'Write',
    sessionIds: ['sess-1'],
    onDisk: { bytes: 1024, modifiedAt: NOW - 600_000 },
    ...overrides,
  }
}

function list(overrides: Partial<ArtifactList> = {}): ArtifactList {
  return {
    root: '/p',
    scope: 'project',
    artifacts: [],
    sessions: [],
    sessionsScanned: 3,
    outsideProject: 0,
    truncated: false,
    cancelled: false,
    tookMs: 12,
    ...overrides,
  }
}

/* ------------------------------------------------------------------- diff -- */

describe('splitLines', () => {
  it('lets a trailing newline terminate the last line', () => {
    expect(splitLines('a\nb\n')).toEqual(['a', 'b'])
    expect(splitLines('a\nb')).toEqual(['a', 'b'])
    expect(splitLines('')).toEqual([])
  })
})

describe('diffLines', () => {
  it('keeps every line of both sides, in order', () => {
    // The safety property. A diff that silently drops a line is worse than no
    // diff at all, because it looks like the agent never wrote it.
    const before = 'one\ntwo\nthree\n'
    const after = 'one\nTWO\nthree\nfour\n'
    const { lines } = diffLines(before, after)

    expect(lines.filter((line) => line.kind !== 'add').map((line) => line.text)).toEqual([
      'one',
      'two',
      'three',
    ])
    expect(lines.filter((line) => line.kind !== 'del').map((line) => line.text)).toEqual([
      'one',
      'TWO',
      'three',
      'four',
    ])
  })

  it('marks only what changed', () => {
    const { lines } = diffLines('a\nb\nc\n', 'a\nB\nc\n')
    expect(lines).toEqual([
      { kind: 'same', text: 'a' },
      { kind: 'del', text: 'b' },
      { kind: 'add', text: 'B' },
      { kind: 'same', text: 'c' },
    ])
  })

  it('handles a pure insertion without rewriting its neighbours', () => {
    const { lines } = diffLines('a\nc\n', 'a\nb\nc\n')
    expect(lines).toEqual([
      { kind: 'same', text: 'a' },
      { kind: 'add', text: 'b' },
      { kind: 'same', text: 'c' },
    ])
  })

  it('handles a one-line edit, which is what most Edits are', () => {
    const { lines } = diffLines('const a = 0', 'const a = 1')
    expect(lines).toEqual([
      { kind: 'del', text: 'const a = 0' },
      { kind: 'add', text: 'const a = 1' },
    ])
  })

  it('falls back to a block replacement rather than a quadratic stall', () => {
    // O(n×m) on two 10,000-line sides is 100 million cells in the render path.
    const huge = Array.from({ length: MAX_DIFF_LINES + 10 }, (_, i) => `line ${i}`).join('\n')
    const { lines, truncated } = diffLines(huge, huge.replace('line 0', 'line zero'))
    expect(truncated).toBe(true)
    expect(lines.some((line) => line.kind === 'same')).toBe(false)
  })
})

/* ---------------------------------------------------------------- summary -- */

/**
 * The zero he could not check.
 *
 *   > *"No artifacts are still. I don't know. We don't have artifacts maybe."*
 *
 * The page said "Nothing written or edited in 15 sessions." and stopped, which
 * leaves no way to tell a correct zero from a broken page — and his was almost
 * certainly correct. Every assertion here is about a fact the answer already
 * carried and the sentence threw away.
 */
describe('nothingFound', () => {
  it('names the folder it read, so the zero can be checked', () => {
    expect(nothingFound(list())).toBe('Nothing written or edited in /p — 3 sessions read.')
  })

  it('distinguishes "no sessions" from "sessions that produced nothing"', () => {
    expect(nothingFound(list({ sessionsScanned: 0 }))).toBe(
      'Nothing written or edited in /p — no sessions have been recorded for it yet.',
    )
  })

  /**
   * The interesting zero, and the one the page never showed: an agent launched
   * from a parent workspace writes into *that* folder, so the scan sees the
   * writes and files them outside the project. "15 sessions, 40 files, none of
   * them here" is an explanation; "nothing in 15 sessions" is a shrug.
   */
  it('reports changes that landed outside the folder, which is why there are none in it', () => {
    expect(nothingFound(list({ outsideProject: 40 }))).toBe(
      'Nothing written or edited in /p — 3 sessions read, 40 changes to files outside it.',
    )
  })

  it('says nothing about files elsewhere when there were none', () => {
    expect(nothingFound(list({ outsideProject: 0 }))).not.toContain('outside')
  })
})

describe('summarize', () => {
  it('hands an empty list to the sentence that explains itself', () => {
    expect(summarize(list(), 0, 'made')).toBe(nothingFound(list()))
  })

  it('counts what is shown against what was found', () => {
    const found = list({
      artifacts: [artifact({ relPath: 'a.html' }), artifact({ relPath: 'b.html' })],
      sessions: [{ sessionId: 's', at: NOW, files: 2 }],
    })
    expect(summarize(found, 2, 'made')).toBe('2 made here · 1 session')
    expect(summarize(found, 1, 'made')).toBe('1 of 2 made here · 1 session')
  })

  it('admits when a cap stopped the scan', () => {
    const found = list({
      artifacts: [artifact({ relPath: 'a.html' })],
      sessions: [{ sessionId: 's', at: NOW, files: 1 }],
      truncated: true,
    })
    expect(summarize(found, 1, 'made')).toContain('older work not read')
  })

  it('tells an empty folder apart from a folder that only holds prose', () => {
    /*
     * The list this sentence heads is the narrowed one, so an empty one has two
     * causes and they are not the same fact. *"Nothing written or edited in /p"*
     * over a folder an agent filled with markdown is a page claiming it did
     * nothing, which is the shrug the empty state was rebuilt to stop.
     */
    expect(summarize(list(), 0, 'made', 7)).toBe(
      'No prototypes in /p — 7 files of prose or source, which is what Files is for.',
    )
    expect(summarize(list(), 0, 'made', 7)).not.toContain('Nothing written or edited')
    expect(summarize(list(), 0, 'made')).toBe(nothingFound(list()))
  })
})

describe('nothingButFiles', () => {
  it('counts in the reader’s own grammar', () => {
    expect(nothingButFiles(list(), 1)).toContain('1 file of prose')
    expect(nothingButFiles(list(), 2)).toContain('2 files of prose')
  })

  it('names the folder, so the zero can be checked', () => {
    expect(nothingButFiles(list({ root: '/work/deck' }), 3)).toContain('/work/deck')
  })
})

describe('changeSummary', () => {
  it('leaves out the half that is zero', () => {
    expect(changeSummary(artifact({ relPath: 'a.ts', writes: 1, edits: 0 }))).toBe('1 write')
    expect(changeSummary(artifact({ relPath: 'a.ts', writes: 0, edits: 3 }))).toBe('3 edits')
    expect(changeSummary(artifact({ relPath: 'a.ts', writes: 2, edits: 1 }))).toBe(
      '2 writes · 1 edit',
    )
  })
})

describe('directoryOf', () => {
  it('is empty at the project root', () => {
    expect(directoryOf('README.md')).toBe('')
    expect(directoryOf('src/main/index.ts')).toBe('src/main')
  })
})

/* ----------------------------------------------------------------- render -- */

describe('ArtifactRow', () => {
  it('leads with what the thing is, not with where it lives', () => {
    // A prototype rather than the `plans/launch.md` this fixture used to be:
    // markdown is not a row on this page any more. See `isArtifact`.
    const html = renderToStaticMarkup(
      <ArtifactRow
        artifact={artifact({ relPath: 'plans/launch.html', writes: 1, edits: 4 })}
        now={NOW}
        selected={false}
        onSelect={() => undefined}
      />,
    )
    expect(html).toContain('launch.html')
    // The kind, in a word, is the second thing on the row — it is what stops a
    // list of artifacts reading as a list of paths.
    expect(html).toContain('Web page')
    expect(html).toContain('1.0 KB')
    expect(html).toContain('10m ago')
    // The folder is still there, and still last: it is how two files of the
    // same name are told apart and nothing more.
    expect(html).toContain('plans')
    expect(html.indexOf('Web page')).toBeLessThan(html.indexOf('>plans<'))
  })

  it('says when a file the agent made is no longer there', () => {
    const html = renderToStaticMarkup(
      <ArtifactRow
        artifact={artifact({ relPath: 'scratch/mock.html', onDisk: null })}
        now={NOW}
        selected={false}
        onSelect={() => undefined}
      />,
    )
    expect(html).toContain('not on disk')
  })
})

describe('ChangeBody', () => {
  function change(overrides: Partial<ArtifactChange> = {}): ArtifactChange {
    return {
      at: NOW - 60_000,
      sessionId: 'sess-1',
      action: 'edit',
      tool: 'Edit',
      before: 'const a = 0',
      after: 'const a = 1',
      replaceAll: false,
      clipped: false,
      ...overrides,
    }
  }

  it('renders an edit as a diff with both halves', () => {
    const html = renderToStaticMarkup(<ChangeBody change={change()} />)
    expect(html).toContain('data-kind="del"')
    expect(html).toContain('data-kind="add"')
    expect(html).toContain('const a = 0')
    expect(html).toContain('const a = 1')
  })

  it('renders a write as the text it put in, not as a wall of green', () => {
    const html = renderToStaticMarkup(
      <ChangeBody change={change({ action: 'write', before: '', after: 'hello\nworld\n' })} />,
    )
    expect(html).toContain('data-write="true"')
    expect(html).not.toContain('data-kind="add"')
    expect(html).toContain('hello')
  })
})

describe('ArtifactsPanel', () => {
  const bridge: ArtifactsBridge = {
    listArtifacts: async () => ({ ok: true, ...list() }),
    artifactChanges: async () => ({
      ok: true,
      root: '/p',
      relPath: 'a.ts',
      changes: [],
      totalChanges: 0,
      truncated: false,
      cancelled: false,
      tookMs: 1,
    }),
  }

  it('opens on a reading state rather than on an instruction', () => {
    // The defect this page and the Files page were both reported for: a whole
    // pane spent telling you to click something.
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    expect(html).toContain('Reading this project’s history…')
    expect(html).not.toMatch(/pick something/i)
  })

  it('names itself for a screen reader', () => {
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    expect(html).toContain('aria-label="Artifacts"')
  })

  it('offers both scopes, with this project’s own sessions first', () => {
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    expect(html).toContain('This project’s sessions')
    expect(html).toContain('Every session')
    expect(html.indexOf('This project’s sessions')).toBeLessThan(html.indexOf('Every session'))
  })

  it('opens on every session that wrote here, not only the ones started here', () => {
    /*
     * Asad, on this row: *"on the sessions here, would be better if you show
     * the other ones also, not the local only."*
     *
     * The narrow scope reads the transcripts filed under this folder, and
     * `src/main/artifacts.ts` measured what that leaves out on this very
     * repository: 16 transcripts with zero writes in them, against 193 real
     * writes filed under the parent workspace the agents were launched from.
     * A default that hides the sessions which did the work is the defect; the
     * chip is still there for the visit where this folder's own history is the
     * question.
     */
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    const every = html.indexOf('Every session')
    const own = html.indexOf('This project’s sessions')
    // The pressed one is the widened one.
    expect(html.slice(every - 220, every)).toContain('aria-pressed="true"')
    expect(html.slice(own - 220, own)).toContain('aria-pressed="false"')
  })
})

/* ------------------------------------------- what the word Artifacts means -- */

/**
 * The regression that came back, pinned so it cannot come back again.
 *
 * Reported twice, in the same words: *"they are showing some kind of files
 * instead of artifacts."* Both times the page was rebuilt from the transcript
 * data, which is a list of file paths, and both times it arrived back at a file
 * browser — the second time with the reasoning written into the source as
 * settled ("the only honest definition").
 *
 * The meaning is a decision, not a consequence of the data, so it is asserted
 * here rather than left to the next reader's judgement:
 *
 * **An artifact is a file the agent produced whole** — at least one recorded
 * `Write`. A file it only ever *edited* is a change to something that already
 * existed, and belongs under a word that says so.
 *
 * Breaking that means deleting these assertions, which is a thing somebody has
 * to do on purpose and explain.
 */
describe('an artifact is something the agent made', () => {
  // Both fixtures are artifacts by the *other* rule on this page — see
  // `isArtifact` — so that what these assertions pin is the made/changed split
  // and not the prototypes-only one beside it.
  const made = artifact({ relPath: 'demo/index.html', writes: 2, edits: 1 })
  const edited = artifact({ relPath: 'demo/hero.png', writes: 0, edits: 6 })

  it('counts a whole-file write as making it, and an edit alone as not', () => {
    expect(wasMade(made)).toBe(true)
    expect(wasMade(edited)).toBe(false)
    // One write is enough. An agent that wrote a file and then refined it four
    // times still made that file; demoting it for improving it would move an
    // artifact off this page the moment it got better.
    expect(wasMade(artifact({ relPath: 'a.html', writes: 1, edits: 40 }))).toBe(true)
  })

  it('shows only what was made, by default', () => {
    const html = renderToStaticMarkup(
      <ArtifactsPanel
        projectPath="/p"
        now={NOW}
        bridge={{
          listArtifacts: async () => ({ ok: true, ...list({ artifacts: [made, edited] }) }),
          artifactChanges: async () => ({
            ok: true,
            root: '/p',
            relPath: 'a.ts',
            changes: [],
            totalChanges: 0,
            truncated: false,
            cancelled: false,
            tookMs: 1,
          }),
        }}
      />,
    )
    // The two chips, with their counts, so nothing is hidden and the split is
    // between two honest words rather than between shown and dropped.
    expect(html).toContain('Made here')
    expect(html).toContain('Changed')
    // Default is Made — `aria-pressed` is what a static render can prove.
    const madeChip = html.slice(html.indexOf('Made here') - 220, html.indexOf('Made here'))
    expect(madeChip).toContain('aria-pressed="true"')
  })

  it('names the list for what it holds, not "files"', () => {
    const html = renderToStaticMarkup(
      <ArtifactsPanel
        projectPath="/p"
        now={NOW}
        bridge={{
          listArtifacts: async () => ({ ok: true, ...list({ artifacts: [made, edited] }) }),
          artifactChanges: async () => ({
            ok: true,
            root: '/p',
            relPath: 'a.ts',
            changes: [],
            totalChanges: 0,
            truncated: false,
            cancelled: false,
            tookMs: 1,
          }),
        }}
      />,
    )
    // The page's own subtitle lives in `panels.ts`; this is the list's
    // accessible name, which said "Files this project's agents produced".
    expect(html).not.toContain('Filter by path')
    expect(html).toContain('Filter by name')
  })
})

describe('what kind of thing an artifact is', () => {
  it('answers in one word somebody already knows', () => {
    // Still the right *word* for a markdown file, and no longer a row on this
    // page: the vocabulary and the filter are two questions, and `isArtifact`
    // is the one that decides what is listed.
    expect(kindOf('memory/2026-08-15.md')).toBe('Document')
    expect(kindOf('index.html')).toBe('Web page')
    expect(kindOf('logo.svg')).toBe('Image')
    expect(kindOf('data/leads.csv')).toBe('Data')
    expect(kindOf('src/app.tsx')).toBe('Code')
    expect(kindOf('notes.ipynb')).toBe('Notebook')
  })

  it('has a word for a recording, which is a thing an agent makes', () => {
    // "File, 8.2 MB" is true and useless about a screen recording, and a
    // recording is a row on this page now.
    expect(kindOf('walkthrough.mov')).toBe('Video')
    expect(kindOf('demo.mp4')).toBe('Video')
    expect(kindOf('voiceover.mp3')).toBe('Sound')
    expect(kindOf('shots/hero.heic')).toBe('Image')
  })

  it('does not call a dotfile a Document because of its name', () => {
    // `.claudeignore` and `.gitignore` have no extension at all — their whole
    // name is the type, and "File" would be true and useless.
    expect(kindOf('.claudeignore')).toBe('Setting')
    expect(kindOf('.gitignore')).toBe('Setting')
    // A dotfile that does carry an extension keeps it.
    expect(kindOf('.eslintrc.json')).toBe('Data')
  })

  it('renders a note as prose and never pretends to render what it cannot', () => {
    expect(previewKindOf('notes.md')).toBe('document')
    // A PDF is a Document nobody here can turn into prose. Showing its bytes
    // would be worse than saying what it is.
    expect(previewKindOf('report.pdf')).toBe('text')
    expect(previewKindOf('logo.png')).toBe('image')
    expect(previewKindOf('shots/hero.heic')).toBe('image')
    expect(previewKindOf('build.bin')).toBe('none')
    // Nothing in the pane plays a video, and reading one as text spends a
    // megabyte to arrive at a note saying it is not text.
    expect(previewKindOf('walkthrough.mov')).toBe('none')
    expect(previewKindOf('voiceover.mp3')).toBe('none')
  })

  it('calls a prototype a page, which is the thing he asked about by name', () => {
    // Its own answer rather than `text`, and the difference is one sentence on
    // screen: the markup is worth reading and is not the thing.
    expect(previewKindOf('demo/index.html')).toBe('page')
    expect(previewKindOf('mock.htm')).toBe('page')
  })
})

/* ------------------------------------------------ artifacts are not files -- */

/**
 * The third report of the same page, pinned so there cannot be a fourth.
 *
 *   > *"an artifact is still showing the MD files, which is — multiple times I
 *   > have discussed about it. Artifact should not show the MD files. It should
 *   > be only for purely the prototypes."*
 *
 * There are two of this rule, deliberately: `isArtifact` in
 * `src/main/remote/panels/artifacts.ts` filters the phone at the scan, and this
 * one filters the window at the seam. They are copies because the renderer
 * cannot import `src/main` — `tsconfig.web.json` does not include it and both
 * projects are `composite` — and the header comment says so. These assertions
 * are what makes a copy that has drifted noticeable.
 */
describe('an artifact is a prototype, not a file', () => {
  it('keeps a prototype, a picture and a recording', () => {
    expect(isArtifact('demo/index.html')).toBe(true)
    expect(isArtifact('mock.htm')).toBe(true)
    expect(isArtifact('shots/hero.png')).toBe(true)
    expect(isArtifact('logo.svg')).toBe(true)
    expect(isArtifact('walkthrough.mov')).toBe(true)
    expect(isArtifact('deck.pdf')).toBe(true)
  })

  it('drops the markdown he has now reported three times', () => {
    expect(isArtifact('memory/2026-08-15.md')).toBe(false)
    expect(isArtifact('README.md')).toBe(false)
    expect(isArtifact('PLAN.markdown')).toBe(false)
    expect(isArtifact('notes.txt')).toBe(false)
  })

  it('drops source, data and everything else Files is the page for', () => {
    expect(isArtifact('src/app.tsx')).toBe(false)
    expect(isArtifact('data/leads.csv')).toBe(false)
    expect(isArtifact('styles/app.css')).toBe(false)
    expect(isArtifact('.gitignore')).toBe(false)
    expect(isArtifact('Makefile')).toBe(false)
    expect(isArtifact('build/app.zip')).toBe(false)
  })

  it('has a word for everything it lists', () => {
    // A row this page draws and then has no name for is "File, 8.2 MB", which
    // is the vaguest thing that can be said about a screen recording.
    for (const extension of ARTIFACT_EXTENSIONS) {
      expect(kindOf(`a.${extension}`)).not.toBe('File')
    }
  })
})

describe('onlyArtifacts', () => {
  const prototype = artifact({ relPath: 'demo/index.html', sessionIds: ['s1'] })
  const note = artifact({ relPath: 'memory/2026-08-15.md', sessionIds: ['s1', 's2'] })
  const plan = artifact({ relPath: 'PLAN.md', sessionIds: ['s2'] })
  const scanned = list({
    artifacts: [prototype, note, plan],
    sessions: [
      { sessionId: 's1', at: NOW, files: 2 },
      { sessionId: 's2', at: NOW, files: 2 },
    ],
  })

  it('narrows the scan to what the page will draw', () => {
    const { list: kept, hidden } = onlyArtifacts(scanned)
    expect(kept.artifacts.map((found) => found.relPath)).toEqual(['demo/index.html'])
    expect(hidden).toBe(2)
  })

  it('recounts the session chips off what survived', () => {
    // A chip reading "Rewrite the hero · 2 files" that opens an empty list is a
    // control that cannot act. `s2` wrote nothing but prose, so it is not a
    // chip at all any more.
    const { list: kept } = onlyArtifacts(scanned)
    expect(kept.sessions).toEqual([{ sessionId: 's1', at: NOW, files: 1 }])
  })

  it('hands the same list straight back when nothing was dropped', () => {
    const clean = list({ artifacts: [prototype] })
    expect(onlyArtifacts(clean).list).toBe(clean)
    expect(onlyArtifacts(clean).hidden).toBe(0)
  })

  it('judges the deleted half by the same rule as the live half', () => {
    // Both arrive with `onDisk: null`. A prototype an agent made and threw away
    // is still something it made and still wears its "not on disk" tag; a
    // PLAN.md it threw away is still prose.
    const { list: kept } = onlyArtifacts(
      list({
        artifacts: [
          artifact({ relPath: 'demo/index.html', onDisk: null }),
          artifact({ relPath: 'PLAN.md', onDisk: null }),
        ],
      }),
    )
    expect(kept.artifacts.map((found) => found.relPath)).toEqual(['demo/index.html'])
  })

  it('draws the prototype and not the markdown beside it', () => {
    /*
     * The rows themselves, which is the report — *"an artifact is still showing
     * the MD files."* This project's tests have no DOM and run no effects, so a
     * rendered `ArtifactsPanel` is its loading state and has no rows in it at
     * all; the seam is where the rows are decided, so the rows are drawn from
     * what the seam kept.
     */
    const { list: kept } = onlyArtifacts(scanned)
    const html = kept.artifacts
      .map((found) =>
        renderToStaticMarkup(
          <ArtifactRow artifact={found} now={NOW} selected={false} onSelect={() => undefined} />,
        ),
      )
      .join('')
    expect(html).toContain('index.html')
    expect(html).toContain('Web page')
    expect(html).not.toContain('2026-08-15.md')
    expect(html).not.toContain('PLAN.md')
  })

  it('never lets a count stand above a list it does not have', () => {
    // "3 made here" over an empty list is the seam failure this rule had to
    // avoid: the sentence and the rows read the same narrowed list.
    const { list: kept, hidden } = onlyArtifacts(list({ artifacts: [note, plan] }))
    expect(kept.artifacts).toHaveLength(0)
    expect(summarize(kept, kept.artifacts.length, 'made', hidden)).toBe(
      'No prototypes in /p — 2 files of prose or source, which is what Files is for.',
    )
  })
})

describe('opening an artifact on the machine', () => {
  it('names the button after what the thing is', () => {
    // *"Open it"* on a prototype undersells the case he asked about by name;
    // *"Run it"* on a `.zip` would be a lie.
    expect(openLabel('page')).toBe('Run it in your browser')
    expect(openLabel('image')).toBe('Open the picture')
    expect(openLabel('document')).toBe('Open it on this machine')
    expect(openLabel('none')).toBe('Open it on this machine')
  })

  it('builds a file URL a machine will take', () => {
    expect(fileUrl('/work/deck', 'demo/index.html')).toBe('file:///work/deck/demo/index.html')
    // A trailing separator would put `//` in the middle of the path, which some
    // openers follow and others do not.
    expect(fileUrl('/work/deck/', 'a.md')).toBe('file:///work/deck/a.md')
  })

  it('escapes what a URL cannot carry, and keeps the separators', () => {
    // A space, a `#` and a `?` all mean something else in a URL, and all three
    // are legal in a filename an agent writes.
    expect(fileUrl('/work/deck', 'design notes/read me.md')).toBe(
      'file:///work/deck/design%20notes/read%20me.md',
    )
    expect(fileUrl('/work/deck', 'a#b?c.md')).toBe('file:///work/deck/a%23b%3Fc.md')
  })

  it('spells a Windows root the way Windows takes it', () => {
    // Three slashes, forward separators, and the drive letter kept whole — a
    // `C%3A` is not a path any opener resolves.
    expect(fileUrl('C:\\Users\\asad\\deck', 'demo/index.html')).toBe(
      'file:///C:/Users/asad/deck/demo/index.html',
    )
  })
})

describe('describeRead', () => {
  it('turns each of fs:read’s three answers into something to show', () => {
    expect(describeRead({ kind: 'text', text: '# Hi' }, 4)).toEqual({
      status: 'text',
      text: '# Hi',
    })
    // An empty artifact is a fact, not a blank pane.
    expect(describeRead({ kind: 'text', text: '  \n' }, 3).status).toBe('note')
    expect(describeRead({ kind: 'binary' }, 2048).status).toBe('note')
    expect(describeRead({ kind: 'too-large', limit: 2_097_152 }, null).status).toBe('note')
  })

  it('never renders a reply it does not understand as if it were content', () => {
    expect(describeRead(null, null).status).toBe('error')
    expect(describeRead({ kind: 'something-new' }, null).status).toBe('error')
  })
})

/* ------------------------------------------------- every reply is an answer -- */

/**
 * The page that never resolved.
 *
 * Two of the four stuck sentences in the recording — "Reading this project’s
 * history…" and "Reading the changes…" — came from one omission here:
 *
 *     if (response.ok) setList(ready)
 *     else if (response.error !== 'cancelled') setList(error)
 *
 * A `cancelled` reply set nothing at all, so the page kept the sentence it had
 * and kept it for good. The main process produces that reply whenever a scan is
 * superseded, and — until the fix in `artifacts.ts` — a *changes* request
 * superseded the *list* request beside it on every scope toggle.
 *
 * The generation guard in the component already drops replies the page has
 * moved on from, so anything reaching this function is a reply the page is
 * still waiting on. Every one of them has to end the wait.
 */
describe('scanOutcome', () => {
  it('hands a successful scan straight through', () => {
    const ok = { ok: true as const, artifacts: [] }
    expect(scanOutcome(ok)).toEqual({ done: ok })
  })

  it('turns a cancelled scan into something the page can act on', () => {
    const outcome = scanOutcome({ ok: false, error: 'cancelled', message: 'Scan cancelled.' })
    expect(outcome).not.toEqual({ done: expect.anything() })
    expect('failed' in outcome && outcome.failed.length > 0).toBe(true)
  })

  it('quotes the main process’s own reason for anything else', () => {
    expect(scanOutcome({ ok: false, error: 'failed', message: 'Could not read it.' })).toEqual({
      failed: 'Could not read it.',
    })
  })

  it('never answers with nothing, whatever the error is called', () => {
    // The shape of the original bug: an error name nobody thought of falling
    // through every arm and leaving the spinner where it was.
    for (const error of ['cancelled', 'failed', 'invalid-project', 'something-new']) {
      const outcome = scanOutcome({ ok: false, error, message: 'why' })
      expect('failed' in outcome).toBe(true)
    }
  })
})

describe('SCAN_FRESH_MS', () => {
  it('is long enough that a trip to a terminal does not re-walk every transcript', () => {
    // Asad watched this page re-scan from scratch each time he came back to it.
    // The scan is the most expensive read in the app; the window has to cover a
    // working session of flipping between the page and a session.
    expect(SCAN_FRESH_MS).toBeGreaterThanOrEqual(60_000)
  })
})
