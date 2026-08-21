import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { readFailure, withDeadline } from '../deadline'
import { recall, remember } from '../panel-cache'
import { panelSpec } from '../shell/panels'
import { PageEmpty, PageNote } from './PageEmpty'
import './GitPanel.css'

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of the types in `src/main/git.ts`. They are duplicated rather than
 * imported because the renderer tsconfig does not include `src/main` — once
 * the orchestrator lifts them into `src/shared/types.ts`, this block goes away
 * and the imports point there instead.
 */
export type GitFileGroup = 'staged' | 'unstaged' | 'untracked' | 'conflicted'

export type GitChangeKind =
  | 'added'
  | 'modified'
  | 'deleted'
  | 'renamed'
  | 'copied'
  | 'typechange'
  | 'untracked'
  | 'conflicted'
  | 'unknown'

export interface GitFile {
  path: string
  origPath: string | null
  group: GitFileGroup
  code: string
  kind: GitChangeKind
  score: number | null
  insertions: number | null
  deletions: number | null
  binary: boolean
}

export interface GitBranch {
  name: string | null
  detached: boolean
  oid: string | null
  upstream: string | null
  ahead: number
  behind: number
}

export interface GitRepoStatus {
  repo: true
  cwd: string
  root: string
  branch: GitBranch
  staged: GitFile[]
  unstaged: GitFile[]
  untracked: GitFile[]
  conflicted: GitFile[]
  clean: boolean
}

export type GitUnavailableReason = 'not-a-repo' | 'git-missing' | 'no-such-folder' | 'error'

export interface GitNotRepo {
  repo: false
  cwd: string
  reason: GitUnavailableReason
  message: string
  /** Mirrors `GitNotRepo.canInit` in `src/main/git.ts` — see the note there. */
  canInit?: boolean
}

export type GitStatusResult = GitRepoStatus | GitNotRepo

/** The slice of the preload bridge this panel needs. */
export interface GitBridge {
  gitStatus(cwd: string): Promise<GitStatusResult>
  watchGit(cwd: string): Promise<GitStatusResult>
  unwatchGit(cwd: string): void
  onGitStatus(cb: (cwd: string, status: GitStatusResult) => void): () => void
  /**
   * Unified diff for one file, as text.
   *
   * Optional on the type, present in every real build. `git:diff` has been
   * registered in the main process and exposed on the preload as `gitDiff`
   * since Source control was written, and **nothing in the renderer ever
   * called it** — which is the whole of the defect this pane fixes. A page that
   * lists changed files and cannot show a change is a page whose every row has
   * to go somewhere else, and where it went was Files:
   *
   *   > *"If I click on source control, click on something, it takes me to
   *   > files."*
   *
   * It is optional rather than required so that `resolveBridge` below does not
   * start refusing a window whose bridge predates this — a missing `gitDiff`
   * turns the rows back into the old hand-off, which is a worse page but a
   * working one, rather than an empty "Source control is not available here".
   */
  gitDiff?(cwd: string, path: string, options?: { staged?: boolean; untracked?: boolean }): Promise<string>
  /**
   * `git init` in this folder, answering with the status that follows.
   *
   * Optional for the same reason `gitDiff` is: a window whose preload predates
   * it keeps a working page, minus one button, rather than collapsing to "not
   * available here". The button is only ever drawn when this is present, so
   * there is no dead control in the older build.
   */
  gitInit?(cwd: string): Promise<GitStatusResult>
}

export interface GitPanelProps {
  /** Absolute path of the project folder to report on. */
  cwd: string
  /**
   * Open this file on the Files page.
   *
   * No longer what a row click does — see `gitDiff` above. It is a button in
   * the diff pane's header now, so leaving Source control is something a person
   * asks for rather than something that happens to them when they click a file
   * on a page whose job is to show that file's changes.
   */
  onSelectFile?(file: GitFile): void
  /** Path of the row to open on, when the host knows which file is wanted. */
  selectedPath?: string | null
  /**
   * A group to open on, scrolled to and marked.
   *
   * The dashboard's git tile counts staged, changed and untracked files, and a
   * count is a door: clicking "staged 3" has to land on those three rather than
   * on the top of a page that happens to contain them.
   */
  focusGroup?: GitFileGroup
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: GitBridge
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * The bridge is read defensively: git is wired into the preload separately, so
 * the panel has to render something sane rather than crash if it is mounted
 * before those methods exist.
 */
function resolveBridge(): GitBridge | null {
  const host = (window as unknown as { deck?: Partial<GitBridge> }).deck
  if (
    !host ||
    typeof host.watchGit !== 'function' ||
    typeof host.unwatchGit !== 'function' ||
    typeof host.onGitStatus !== 'function' ||
    typeof host.gitStatus !== 'function'
  ) {
    return null
  }
  return host as GitBridge
}

function baseName(path: string): string {
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path
  const cut = trimmed.lastIndexOf('/')
  return cut === -1 ? path : `${trimmed.slice(cut + 1)}${path.endsWith('/') ? '/' : ''}`
}

function dirName(path: string): string {
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path
  const cut = trimmed.lastIndexOf('/')
  return cut === -1 ? '' : trimmed.slice(0, cut)
}

function describe(file: GitFile): string {
  if (file.origPath) return `${file.origPath} → ${file.path}`
  return file.path
}

/**
 * What git's status letter means, in a word.
 *
 * This column printed exactly what porcelain prints — `M`, `A`, `D`, and for an
 * untracked file a bare `?`. Asad, on a page of question marks: *"what are
 * these question marks? Is this normal? Is this like for all of the other tools
 * are also doing like this?"* `?` is porcelain's code for untracked, and the
 * fact that it needs that sentence to explain is the whole argument for not
 * showing it. `src/main/git.ts` already turns every code into a `kind`; nothing
 * was reading it.
 *
 * The letter survives in one case: a code this app does not recognise keeps its
 * own character, because inventing a word for something unrecognised is worse
 * than showing what git actually said. It is also still in the row's `title`,
 * so the raw status is one hover away for anybody who wants it.
 *
 * Kept in step with the dashboard tile's copy of the same table by
 * `GitPanel.test.tsx`, which asserts the two produce the same word.
 */
const CHANGE_WORD: Record<GitChangeKind, string> = {
  added: 'Added',
  modified: 'Modified',
  deleted: 'Deleted',
  renamed: 'Renamed',
  copied: 'Copied',
  typechange: 'Type',
  untracked: 'Untracked',
  conflicted: 'Conflict',
  unknown: '',
}

export function changeLabel(kind: GitChangeKind, code: string): string {
  return CHANGE_WORD[kind] || code.trim() || '?'
}

/*
 * What is wrong, in as few words as will carry it — and in the same words the
 * Overview's git tile uses for the same four situations.
 *
 * They were four *different* words until 2026-08-21. The tile said "Nothing to
 * track here" and this page said "Not a repository" about the same folder in
 * the same second, and `widgets.tsx` carried a comment claiming they were "the
 * same headings Source control uses", which had quietly stopped being true.
 * Two names for one situation is how a person ends up believing they are
 * looking at two findings.
 */
const UNAVAILABLE_TITLE: Record<GitUnavailableReason, string> = {
  'not-a-repo': 'Nothing to track here',
  'git-missing': 'git is not installed',
  'no-such-folder': 'That folder is gone',
  error: 'Source control is unavailable',
}

/**
 * What the page shows when there is no repository to show — decided once, in a
 * pure function, because it is the half of this branch that can be wrong in a
 * way nobody notices.
 *
 * The button is offered **only** where `git init` would actually help: offering
 * "Create a repository" over a repository git is refusing on ownership grounds
 * would make a second one beside the first. `canInit` comes from `main/git.ts`
 * rather than being guessed here.
 *
 * ## Why the sentence is back
 *
 * It was suppressed whenever the button was drawn, on the argument that a title
 * plus a button already say "no repository, and here is how to get one" and the
 * sentence would be a third copy of one fact. He looked at the result on
 * 2026-08-21 and said:
 *
 *   > *"Source control, nothing."*
 *
 * Two words in the middle of a window and a button is what "nothing" looks
 * like. The Overview page he had been on one click earlier had the answer he
 * was missing — *"Nothing to track here — This folder is not a git repository.
 * Source control can create one."* — and the page named after that sentence did
 * not carry it.
 *
 * So the page says why, always, and the version it says is the tile's minus its
 * last clause: *"Source control can create one"* is a pointer to this page,
 * from a page that is not this one, and the button under this sentence is that
 * offer rather than a description of it. Which folder it is about is on the
 * scope line above the page — see `components/PageScope.tsx` — so the sentence
 * does not repeat the path either.
 */
export interface UnavailableView {
  title: string
  /** Never null: a page with nothing on it has to say what it looked at. */
  message: string
  canInit: boolean
}

/** The tile's sentence, minus the clause that points at this very page. */
const NOT_A_REPO_HERE = 'This folder is not a git repository.'

export function unavailableView(
  status: GitStatusResult | null,
  hasInit: boolean,
): UnavailableView {
  const reason = status !== null && !status.repo ? status.reason : 'error'
  const canInit = status !== null && !status.repo && status.canInit === true && hasInit
  return {
    title: UNAVAILABLE_TITLE[reason],
    /*
     * The written message from `git.ts` wherever there is one, because it is the
     * one that names a way out no title can — the `safe.directory` command for a
     * repository refused on ownership grounds, git's own words for a failure
     * nobody anticipated. The plain sentence is used only where the message
     * would send the reader to the page they are already on.
     */
    message: canInit
      ? NOT_A_REPO_HERE
      : status !== null && !status.repo
        ? status.message
        : 'git could not read this folder',
    canInit,
  }
}

interface Group {
  key: GitFileGroup
  label: string
  files: GitFile[]
}

/**
 * A checkout across a large refactor, or a build directory that slipped past
 * .gitignore, can put tens of thousands of entries in one group. Every row is
 * a button with its own listeners, so rendering the list unbounded is how this
 * panel turns a big-but-normal repo into a frozen window. The overflow is
 * stated on screen rather than silently dropped.
 */
export const MAX_ROWS_PER_GROUP = 500

/**
 * How long the first `git status` has to come back.
 *
 * `git.ts` runs the tool with its own timeout, so a slow repository is already
 * handled below this line. What is not handled below this line is the read
 * never returning at all — a channel this build never registered, a handler
 * awaiting something that does not finish — and before this the page answered
 * that by printing "Reading repository…" until the app was quit. Fifteen
 * seconds is comfortably longer than `git status` on a large working tree and
 * short enough that nobody sits looking at a dead page.
 */
const WATCH_DEADLINE_MS = 15_000

function statusKey(cwd: string): string {
  return `git:status:${cwd}`
}

/* -------------------------------------------------------------------- diff -- */

/**
 * One line of a unified diff, classified for colour.
 *
 * `meta` is everything git prints that is not content — the `diff --git`
 * header, the index line, the `+++`/`---` pair, and the `\ No newline at end of
 * file` marker. `hunk` is the `@@ … @@` line, which is the only piece of that
 * furniture worth keeping visible, because it is what says *where* in the file
 * you are.
 */
export type DiffLineKind = 'add' | 'del' | 'hunk' | 'meta' | 'context'

export interface GitDiffLine {
  kind: DiffLineKind
  text: string
}

/**
 * Lines rendered before the rest is folded away.
 *
 * Every line is its own element with its own colour, and a `replace_all` across
 * a generated file or a first commit of a vendored directory can be a hundred
 * thousand of them — enough to lock the window while React reconciles a list
 * nobody is going to read to the end. The overflow is *stated*, never silently
 * dropped: a diff that quietly stops is a diff that lies about what changed.
 */
export const MAX_DIFF_LINES = 2000

/**
 * Split `git diff` output into classified lines.
 *
 * Deliberately not a diff *algorithm* — git has already done the work and the
 * text it hands back is the answer. This only decides what colour each line is,
 * which is why it is a pure function over a string and is pinned by its own
 * tests rather than by looking at a screenshot.
 *
 * The `---`/`+++` check comes before the `-`/`+` check on purpose. Those two
 * header lines start with the same characters as a removal and an addition, and
 * classifying them as content paints the file's own name red and green at the
 * top of every diff.
 */
export function parseUnifiedDiff(text: string): GitDiffLine[] {
  if (text === '') return []
  const raw = text.split('\n')
  // A trailing newline terminates the last line rather than starting an empty
  // one, the same rule the artifact diff uses.
  if (raw[raw.length - 1] === '') raw.pop()

  return raw.map((line): GitDiffLine => {
    if (line.startsWith('@@')) return { kind: 'hunk', text: line }
    if (line.startsWith('+++') || line.startsWith('---')) return { kind: 'meta', text: line }
    if (line.startsWith('diff ') || line.startsWith('index ') || line.startsWith('\\')) {
      return { kind: 'meta', text: line }
    }
    if (line.startsWith('new file') || line.startsWith('deleted file') || line.startsWith('similarity')) {
      return { kind: 'meta', text: line }
    }
    if (line.startsWith('rename ') || line.startsWith('old mode') || line.startsWith('new mode')) {
      return { kind: 'meta', text: line }
    }
    if (line.startsWith('+')) return { kind: 'add', text: line.slice(1) }
    if (line.startsWith('-')) return { kind: 'del', text: line.slice(1) }
    return { kind: 'context', text: line.startsWith(' ') ? line.slice(1) : line }
  })
}

/**
 * Which of git's three diff modes a file needs.
 *
 * The group a file is in *is* the answer, and getting it wrong produces an
 * empty pane rather than an error: `git diff -- path` on a staged-only change
 * prints nothing at all, and so does a plain diff of a file git has never
 * heard of. Both were indistinguishable from "no changes" before the pane
 * existed to show them.
 */
export function diffModeFor(group: GitFileGroup): { staged?: boolean; untracked?: boolean } {
  if (group === 'staged') return { staged: true }
  if (group === 'untracked') return { untracked: true }
  // Conflicts diff like unstaged work: the working tree against the index.
  return {}
}

/**
 * Why a file has no diff to show, in a sentence, or null when it should have
 * one.
 *
 * Every one of these is a *fact about the file*, not a failure — which is the
 * distinction the pane has to make, because "git printed nothing" is the same
 * observation for a folder, a binary and a bug. Saying "no changes" for an
 * untracked folder would be false; the folder is the change.
 */
/**
 * Where a change is waiting, said as a state rather than as a list heading.
 *
 * The pane's meta line reused the group's own label and produced "Modified ·
 * changes" and, worse, "Untracked · untracked" — the heading of the list on the
 * left, lowercased, standing in for a fact about the file. These are the four
 * answers to "and then what?", which is what somebody looking at a diff wants
 * to know before they act on it.
 */
export const GROUP_STATE: Record<GitFileGroup, string> = {
  conflicted: 'needs resolving',
  staged: 'ready to commit',
  unstaged: 'not staged yet',
  untracked: 'not tracked yet',
}

export function noDiffReason(file: GitFile): string | null {
  if (file.path.endsWith('/')) {
    return 'This is a folder git has not looked inside yet — it lists the whole folder as one untracked entry. Commit or ignore it and the files inside get their own rows.'
  }
  if (file.binary) return 'A binary file. There is no text to line up side by side.'
  if (file.kind === 'deleted') return null
  return null
}

/* -------------------------------------------------------------- component -- */

interface DiffState {
  status: 'idle' | 'loading' | 'ready' | 'error'
  /** The file this text belongs to, so a stale body is never drawn under a new header. */
  path: string | null
  text: string
  message?: string
}

/**
 * How long one `git diff` has to come back.
 *
 * Shorter than the status read: a diff is one file against one index entry and
 * comes back in milliseconds even on a large tree. Past ten seconds nothing is
 * coming, and the pane has to say so with a Retry rather than sit on "Reading
 * the change…" — the exact failure mode the recording caught on Artifacts.
 */
const DIFF_DEADLINE_MS = 10_000

export function GitPanel({ cwd, onSelectFile, selectedPath, bridge, focusGroup }: GitPanelProps) {
  const api = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const [status, setStatus] = useState<GitStatusResult | null>(null)
  const [loading, setLoading] = useState(true)
  /**
   * Why the first read failed, in words.
   *
   * There was nowhere for this to go before: the `.catch` swallowed the error
   * and cleared `loading`, which dropped the page into the generic "this folder
   * is not a git repository" empty state — a sentence that is simply false when
   * what actually happened is that the read never came back. A page that
   * misreports its own failure is worse than one that admits it.
   */
  const [failure, setFailure] = useState<string | null>(null)
  /** The folder currently on screen, so a slow reply for an old one is dropped. */
  const shownCwd = useRef<string | null>(null)
  const focusRef = useRef<HTMLDivElement | null>(null)

  /**
   * The row whose change is in the pane on the right.
   *
   * Held here rather than by the host, which is the whole point of the fix: the
   * host's idea of "selected" was a path on the *Files* page, so selecting
   * something here meant navigating there. This page shows its own selection's
   * diff and never moves the window.
   */
  const [chosen, setChosen] = useState<string | null>(selectedPath ?? null)
  const [diff, setDiff] = useState<DiffState>({ status: 'idle', path: null, text: '' })
  /** Drops a slow diff whose row is no longer the selected one. */
  const diffRun = useRef(0)
  /** Bumped to ask for a diff again after one failed. */
  const [diffAttempt, setDiffAttempt] = useState(0)

  useEffect(() => {
    if (!api) {
      setLoading(false)
      return
    }

    let live = true
    shownCwd.current = cwd
    setFailure(null)

    /*
     * The status this folder had the last time this page was open.
     *
     * Painted immediately, so returning to Source control shows the repository
     * rather than "Reading repository…" while `git status` runs again. Always
     * re-read behind it — this page carries a live watcher and correctness here
     * is a number of staged files, so the cached copy is a seed and never an
     * answer. `recall` with no window is exactly that: paint it, then check.
     */
    const held = recall<GitStatusResult>(statusKey(cwd))
    setStatus(held?.value ?? null)
    setLoading(!held)

    // Subscribed before the first read, so a change landing during that read
    // is not dropped in the gap.
    const off = api.onGitStatus((path, next) => {
      if (!live || path !== cwd) return
      remember(statusKey(cwd), next)
      setStatus(next)
    })

    withDeadline(api.watchGit(cwd), 'Reading this repository', WATCH_DEADLINE_MS)
      .then((first) => {
        remember(statusKey(cwd), first)
        if (!live) return
        setStatus(first)
        setLoading(false)
      })
      .catch((error: unknown) => {
        if (!live) return
        setLoading(false)
        // A failed re-read behind a status that is already drawn leaves it
        // alone; there is nothing better on offer than what is on screen.
        if (!held) setFailure(readFailure(error))
      })

    return () => {
      live = false
      shownCwd.current = null
      off()
      api.unwatchGit(cwd)
    }
  }, [api, cwd])

  // The reply is checked against the folder still on screen: a manual refresh
  // that is still in flight when the user switches projects (or closes the
  // panel) must not paint one project's status over another's.
  const refresh = useCallback(() => {
    if (!api) return
    const asked = cwd
    setFailure(null)
    void withDeadline(api.gitStatus(cwd), 'Reading this repository', WATCH_DEADLINE_MS)
      .then((next) => {
        remember(statusKey(asked), next)
        if (shownCwd.current === asked) setStatus(next)
      })
      .catch((error: unknown) => {
        // A refresh that fails behind a status already on screen says so and
        // leaves the numbers alone; one that fails with nothing on screen is
        // the page's whole state, and it must not go back to being silent.
        if (shownCwd.current === asked) setFailure(readFailure(error))
      })
  }, [api, cwd])

  /** True while `git init` is in flight, so the button says so and cannot be double-pressed. */
  const [initialising, setInitialising] = useState(false)

  /**
   * Make this folder a repository, and show what follows.
   *
   * The answer to `git:init` is the status read *after* the init, so the page
   * goes straight from "Not a repository" to a working tree with the new
   * repository's untracked files in it — there is no refresh to press and no
   * moment where the page still claims the old state. A failure is put where
   * every other failed read on this page goes.
   */
  const startRepo = useCallback(() => {
    const call = api?.gitInit
    if (!call || initialising) return
    const asked = cwd
    setInitialising(true)
    setFailure(null)
    void withDeadline(call(cwd), 'Creating this repository', WATCH_DEADLINE_MS)
      .then((next) => {
        remember(statusKey(asked), next)
        if (shownCwd.current === asked) setStatus(next)
      })
      .catch((error: unknown) => {
        if (shownCwd.current === asked) setFailure(readFailure(error))
      })
      .finally(() => {
        if (shownCwd.current === asked) setInitialising(false)
      })
  }, [api, cwd, initialising])

  /**
   * Bring the asked-for group into view.
   *
   * After `status`, not on mount: the groups do not exist until the first read
   * comes back, so a scroll on mount would have nothing to scroll to.
   */
  useEffect(() => {
    if (!focusGroup || !status?.repo) return
    focusRef.current?.scrollIntoView({ block: 'nearest' })
  }, [focusGroup, status])

  const groups = useMemo<Group[]>(() => {
    if (!status?.repo) return []
    return (
      [
        { key: 'conflicted', label: 'Conflicts', files: status.conflicted },
        { key: 'staged', label: 'Staged', files: status.staged },
        { key: 'unstaged', label: 'Changes', files: status.unstaged },
        { key: 'untracked', label: 'Untracked', files: status.untracked },
      ] as Group[]
    ).filter((group) => group.files.length > 0)
  }, [status])

  /** Every changed file in reading order, so a selection can be resolved to a row. */
  const rows = useMemo(() => groups.flatMap((group) => group.files.map((file) => ({ file, group }))), [groups])

  /**
   * Whether this window can show a diff at all.
   *
   * Read once here rather than at each call site, because it decides two things
   * that must agree: whether a row is a control that selects, and whether the
   * pane exists. A build with no `gitDiff` keeps the old hand-off to Files —
   * worse, but not a row that highlights and does nothing.
   */
  const canDiff = typeof api?.gitDiff === 'function'

  /*
   * The page opens on a change, not on an instruction.
   *
   * The same rule Artifacts follows: a pane reading "pick something from the
   * list and it appears here" is half the window spent telling somebody to do
   * the obvious. Only when the current pick is gone — committing a file must
   * not yank the pane off a file that is still listed.
   */
  useEffect(() => {
    if (!canDiff) return
    if (rows.length === 0) {
      if (chosen !== null) setChosen(null)
      return
    }
    if (chosen && rows.some((row) => row.file.path === chosen)) return
    /*
     * The first row that has a change to show, not simply the first row.
     *
     * Groups are listed conflicts-staged-changes-untracked and an untracked run
     * often begins with a *folder* — git lists a directory it has not looked
     * inside as one entry ending in `/`, and there is no diff of a directory. So
     * opening on `rows[0]` landed the page on an explanation of why there is
     * nothing to see, every time, in a working tree full of new folders.
     */
    const first = rows.find((row) => noDiffReason(row.file) === null) ?? rows[0]
    setChosen(first.file.path)
  }, [rows, chosen, canDiff])

  const current = useMemo(
    () => rows.find((row) => row.file.path === chosen) ?? null,
    [rows, chosen],
  )

  /**
   * Read the selected file's diff.
   *
   * Keyed on the *group* as well as the path, because the group decides which
   * of git's three diff modes answers — see `diffModeFor`. A file that moves
   * from Changes to Staged while the pane is open is the same path and a
   * different question.
   */
  const currentPath = current?.file.path ?? null
  const currentGroup = current?.group.key ?? null
  const currentBinary = current?.file.binary ?? false
  const currentIsFolder = currentPath?.endsWith('/') ?? false

  useEffect(() => {
    const diffFor = api?.gitDiff
    if (!diffFor || !currentPath || !currentGroup) {
      setDiff({ status: 'idle', path: null, text: '' })
      return
    }
    // A folder and a binary have no text to line up, and asking git for one
    // returns an empty string that would be indistinguishable from "unchanged".
    // `noDiffReason` says which it is; there is nothing to read.
    if (currentIsFolder || currentBinary) {
      setDiff({ status: 'ready', path: currentPath, text: '' })
      return
    }

    const id = diffRun.current + 1
    diffRun.current = id
    setDiff({ status: 'loading', path: currentPath, text: '' })

    void withDeadline(
      diffFor(cwd, currentPath, diffModeFor(currentGroup)),
      'Reading this change',
      DIFF_DEADLINE_MS,
    )
      .then((text) => {
        if (diffRun.current !== id) return
        setDiff({ status: 'ready', path: currentPath, text: typeof text === 'string' ? text : '' })
      })
      .catch((error: unknown) => {
        if (diffRun.current !== id) return
        setDiff({ status: 'error', path: currentPath, text: '', message: readFailure(error) })
      })
  }, [api, cwd, currentPath, currentGroup, currentBinary, currentIsFolder, diffAttempt])

  if (!api) {
    return (
      <section className="git-panel" aria-label="Git status">
        <PageEmpty icon={panelSpec('git').icon} title="No git bridge in this window" />
      </section>
    )
  }

  if (loading && !status) {
    return (
      <section className="git-panel" aria-label="Git status" aria-busy="true">
        <PageNote page busy>
          Reading repository…
        </PageNote>
      </section>
    )
  }

  /*
   * The read itself failed, which is a different thing from "not a repository".
   *
   * These were the same state before: the `.catch` cleared `loading` with
   * `status` still null and the page fell into the empty state below, which
   * says "This folder is not a git repository". For a read that timed out or a
   * bridge that threw, that sentence is a guess, and a wrong one.
   */
  if (!status && failure) {
    return (
      <section className="git-panel" aria-label="Git status">
        <PageEmpty
          icon={panelSpec('git').icon}
          title="Could not read this repository"
          action={{ label: 'Try again', onClick: refresh, primary: true }}
        >
          {failure}
        </PageEmpty>
      </section>
    )
  }

  if (!status || !status.repo) {
    /*
     * The way out, where there is one this app can take.
     *
     * `canInit` is set by `git.ts` only for a folder with no repository in it —
     * never for a repository git refuses on ownership grounds, where `init`
     * would make a second one beside the first. See the note on `GitNotRepo`.
     */
    const view = unavailableView(status, typeof api.gitInit === 'function')
    return (
      <section className="git-panel" aria-label="Git status">
        <PageEmpty
          icon={panelSpec('git').icon}
          title={view.title}
          action={
            view.canInit
              ? { label: initialising ? 'Creating…' : 'Create a repository', onClick: startRepo, busy: initialising, primary: true }
              : undefined
          }
        >
          {/* Why the page is empty, always — see `unavailableView`. */}
          {view.message}
        </PageEmpty>
      </section>
    )
  }

  const { branch } = status
  const branchLabel = branch.detached
    ? `detached at ${branch.oid ? branch.oid.slice(0, 7) : 'unknown'}`
    : (branch.name ?? 'no branch')
  const changeCount =
    status.staged.length + status.unstaged.length + status.untracked.length + status.conflicted.length

  return (
    <section className="git-panel" aria-label="Git status">
      <header className="git-head">
        <svg
          className="git-head-icon"
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          aria-hidden="true"
        >
          <circle cx="7" cy="5" r="2.4" />
          <circle cx="7" cy="19" r="2.4" />
          <circle cx="17" cy="9" r="2.4" />
          <path d="M7 7.4v9.2M17 11.4c0 3.2-3.4 3.6-6.6 4.2" />
        </svg>

        <span className="git-branch" data-detached={branch.detached} title={branch.upstream ?? undefined}>
          {branchLabel}
        </span>

        {branch.ahead > 0 && (
          <span className="git-track" title={`${branch.ahead} commit(s) to push`}>
            ↑{branch.ahead}
          </span>
        )}
        {branch.behind > 0 && (
          <span className="git-track" title={`${branch.behind} commit(s) to pull`}>
            ↓{branch.behind}
          </span>
        )}

        <span className="git-head-spacer" />

        {changeCount > 0 && <span className="git-count">{changeCount}</span>}

        <button
          type="button"
          className="git-refresh"
          onClick={refresh}
          title="Refresh"
          aria-label="Refresh git status"
        >
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
            <path d="M20 12a8 8 0 1 1-2.6-5.9" />
            <path d="M20 4v4.4h-4.4" />
          </svg>
        </button>
      </header>

      {/* Two words and no sentence under them. "Nothing staged, nothing changed,
          nothing untracked" was here, spelling out what "clean" means to a
          reader who is looking at a source-control page and already knows. */}
      {status.clean ? (
        <PageEmpty icon={panelSpec('git').icon} title="Working tree clean" />
      ) : (
        <div className="git-body" data-diff={canDiff || undefined}>
        <div className="git-groups">
          {groups.map((group) => (
            <div
              className="git-group"
              key={group.key}
              data-focused={group.key === focusGroup || undefined}
              ref={group.key === focusGroup ? focusRef : undefined}
            >
              <div className="git-group-head">
                <span className="git-group-label">{group.label}</span>
                <span className="git-group-count">{group.files.length}</span>
              </div>
              <ul className="git-list">
                {group.files.slice(0, MAX_ROWS_PER_GROUP).map((file) => (
                  <li key={`${group.key}:${file.path}`}>
                    <button
                      type="button"
                      className="git-row"
                      data-selected={canDiff ? file.path === chosen : file.path === selectedPath}
                      /*
                       * How the copilot's focus overlay says "this file
                       * changed".
                       *
                       * Keyed on `cwd` and the repo-relative path, because that
                       * pair is what actually identifies a changed file here: a
                       * project folder has one working tree no matter how many
                       * sessions are open in it. `driving/focus-target.ts`
                       * carries the argument, and the reason it disagrees with
                       * the design note.
                       *
                       * On the button rather than the `<li>` so the box lands on
                       * the row a person can click. The two boxes would differ
                       * by the list's own row gap, and a highlight that includes
                       * the gap reads as pointing at the space between two
                       * files.
                       */
                      data-drive-anchor={`git-file:${cwd}:${file.path}`}
                      /*
                       * A click stays on this page.
                       *
                       * It used to be `onSelectFile(file)`, which the host
                       * answered by opening the file on the Files page — so the
                       * one thing a changed file could not do from Source
                       * control was show you what changed in it. Leaving is now
                       * a named button in the pane's header.
                       */
                      onClick={() => (canDiff ? setChosen(file.path) : onSelectFile?.(file))}
                      title={
                        canDiff
                          ? `${describe(file)} — git status ${file.code.trim() || '?'}`
                          : `Open ${describe(file)} on the Files page`
                      }
                    >
                      {/* No longer `aria-hidden`. It was hidden because a lone
                          `M` read aloud is noise; a word is the one part of the
                          row that says what happened to the file. */}
                      <span className="git-code" data-kind={file.kind}>
                        {changeLabel(file.kind, file.code)}
                      </span>
                      <span className="git-name">{baseName(file.path)}</span>
                      <span className="git-dir">
                        {file.origPath ? `← ${file.origPath}` : dirName(file.path)}
                      </span>
                      {file.binary ? (
                        <span className="git-stat git-binary">bin</span>
                      ) : (
                        <span className="git-stat">
                          {file.insertions ? <span className="git-plus">+{file.insertions}</span> : null}
                          {file.deletions ? <span className="git-minus">−{file.deletions}</span> : null}
                        </span>
                      )}
                    </button>
                  </li>
                ))}
                {group.files.length > MAX_ROWS_PER_GROUP && (
                  <li className="git-overflow">
                    {group.files.length - MAX_ROWS_PER_GROUP} more not shown
                  </li>
                )}
              </ul>
            </div>
          ))}
        </div>

        {canDiff && current && (
          <DiffPane
            file={current.file}
            group={current.group}
            state={diff}
            onRetry={() => setDiffAttempt((n) => n + 1)}
            onOpenFile={onSelectFile}
          />
        )}
        </div>
      )}
    </section>
  )
}

/* ------------------------------------------------------------- diff pane -- */

/**
 * What actually changed in the selected file.
 *
 * The header names the file and what happened to it, and carries the one way
 * off this page: **Open in Files**, drawn only when the host gave this panel
 * somewhere to send it. A disabled button here would teach nothing and a live
 * one that goes nowhere is the defect this pane exists to remove.
 */
function DiffPane({
  file,
  group,
  state,
  onRetry,
  onOpenFile,
}: {
  file: GitFile
  group: Group
  state: DiffState
  onRetry(): void
  onOpenFile?(file: GitFile): void
}) {
  const reason = noDiffReason(file)
  // Only the body that belongs to this file. Without the guard the previous
  // file's diff stays on screen under the new file's name for as long as the
  // read takes, which is a page telling two different truths at once.
  const mine = state.path === file.path
  const lines = useMemo(
    () => (mine && state.status === 'ready' ? parseUnifiedDiff(state.text) : []),
    [mine, state.status, state.text],
  )
  /*
   * git's file header is dropped, not dimmed.
   *
   * Every diff begins with four lines that name the file twice more and then
   * quote two object hashes: `diff --git a/x b/x`, `index 1c798e5..2e598b3
   * 100644`, `--- a/x`, `+++ b/x`. The pane's own heading already says which
   * file this is, so all four are the same fact in a language his audience does
   * not read — *"my audience will be mostly non-technical vibe coders."* They
   * were kept and greyed at first, which is four lines of grey at the top of
   * every single change.
   *
   * The `@@` hunk lines stay: they are the only part of git's furniture that
   * carries information the header does not, namely where in the file you are.
   */
  const body = lines.filter((line) => line.kind !== 'meta')
  const shown = body.slice(0, MAX_DIFF_LINES)

  return (
    <div className="git-diff" aria-label={`Changes in ${file.path}`}>
      <header className="git-diff-head">
        <h3 className="git-diff-path" title={file.path}>
          {file.path}
        </h3>
        <p className="git-diff-meta">
          {[
            // What happened to the file, and what happens to it next.
            `${changeLabel(file.kind, file.code)} · ${GROUP_STATE[group.key]}`,
            file.binary
              ? 'binary'
              : [
                  file.insertions ? `+${file.insertions}` : null,
                  file.deletions ? `−${file.deletions}` : null,
                ]
                  .filter(Boolean)
                  .join(' ') || null,
          ]
            .filter(Boolean)
            .join(' · ')}
        </p>
        {onOpenFile && !file.path.endsWith('/') && (
          <button type="button" className="git-diff-open" onClick={() => onOpenFile(file)}>
            Open in Files
          </button>
        )}
      </header>

      {reason ? (
        <PageNote>{reason}</PageNote>
      ) : !mine || state.status === 'loading' ? (
        <PageNote busy>Reading this change…</PageNote>
      ) : state.status === 'error' ? (
        <div className="git-diff-failed">
          <PageNote>{state.message}</PageNote>
          <button type="button" className="git-diff-retry" onClick={onRetry}>
            Try again
          </button>
        </div>
      ) : body.length === 0 ? (
        /*
         * git printed nothing, and that is a fact rather than a failure.
         *
         * The common case is a file whose only change is staged while the row
         * sits in Changes, or the reverse — the working tree and the index
         * agree for the mode this group asks about. Saying "no changes" flat
         * would contradict the row two centimetres to the left.
         */
        <PageNote>
          git reports no text change for this file where it is — {GROUP_STATE[group.key]}. Its
          counterpart in another group may hold the change.
        </PageNote>
      ) : (
        <div className="git-diff-body">
          {shown.map((line, index) => (
            <div className="git-diff-line" data-kind={line.kind} key={index}>
              <span className="git-diff-mark" aria-hidden="true">
                {line.kind === 'add' ? '+' : line.kind === 'del' ? '−' : ' '}
              </span>
              <span className="git-diff-text">{line.text}</span>
            </div>
          ))}
          {body.length > shown.length && (
            <p className="git-diff-more">
              {(body.length - shown.length).toLocaleString()} more lines not shown.
            </p>
          )}
        </div>
      )}
    </div>
  )
}
