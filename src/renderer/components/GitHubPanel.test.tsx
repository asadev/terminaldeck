import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  countLabel,
  FailureBlock,
  formatAge,
  IssueRow,
  openExternal,
  PullRow,
  reviewLabel,
  type GitHubFailure,
  type Issue,
  type PullRequest,
} from './GitHubPanel'

/**
 * There is no DOM environment in this project's test setup, so these render to
 * static markup instead. That is enough to hold the parts most likely to rot
 * silently — the badge each state produces, and the fact that two different
 * failures produce two different sets of instructions.
 */

const NOW = Date.parse('2026-08-12T12:00:00Z')

const PULL: PullRequest = {
  number: 14130,
  title: 'Add support for reading issue field values',
  url: 'https://github.com/cli/cli/pull/14130',
  badge: 'draft',
  draft: true,
  author: 'iulia-b',
  authorIsBot: false,
  createdAt: '2026-08-11T11:46:52Z',
  updatedAt: '2026-08-12T09:00:00Z',
  review: 'review-required',
  labels: [{ name: 'needs-triage', color: 'D6393F' }],
  branch: 'issue-fields/read-field-values',
  fromFork: true,
  additions: 744,
  deletions: 17,
}

const ISSUE: Issue = {
  number: 14134,
  title: 'gh skill publish fails',
  url: 'https://github.com/cli/cli/issues/14134',
  state: 'open',
  reason: null,
  author: 'totwo2',
  authorIsBot: false,
  createdAt: '2026-08-12T03:17:42Z',
  updatedAt: '2026-08-12T03:21:27Z',
  labels: [],
  assignees: ['maintainer'],
}

/* -------------------------------------------------------------------- age -- */

describe('formatAge', () => {
  const at = (iso: string) => formatAge(iso, NOW)

  it('steps through each unit at its boundary', () => {
    expect(at('2026-08-12T11:59:30Z')).toBe('now')
    expect(at('2026-08-12T11:55:00Z')).toBe('5m')
    expect(at('2026-08-12T09:00:00Z')).toBe('3h')
    expect(at('2026-08-10T12:00:00Z')).toBe('2d')
    expect(at('2026-07-22T12:00:00Z')).toBe('3w')
    expect(at('2024-08-12T12:00:00Z')).toBe('2y')
  })

  /** GitHub's clock and this machine's can disagree by a few seconds. */
  it('clamps a future timestamp instead of counting backwards', () => {
    expect(at('2026-08-12T12:00:30Z')).toBe('now')
  })

  it('renders nothing for a timestamp it cannot read', () => {
    expect(at('')).toBe('')
    expect(at('not a date')).toBe('')
  })
})

/* ------------------------------------------------------------ tab counts -- */

describe('countLabel', () => {
  /**
   * Regression: the tab printed `pulls.value.length` raw. The main process
   * fetches at most `limit` rows, so a repository with two hundred open pull
   * requests rendered a confident "20" — a specific wrong number that looks
   * exactly like a right one.
   */
  it('marks a list that was cut off at the row limit', () => {
    expect(countLabel(20, 20)).toBe('20+')
    expect(countLabel(19, 20)).toBe('19')
    expect(countLabel(0, 20)).toBe('0')
  })

  it('renders nothing for a section that failed', () => {
    expect(countLabel(null, 20)).toBeNull()
  })
})

describe('reviewLabel', () => {
  it('spells out each decision, and nothing when there is none', () => {
    expect(reviewLabel('approved')).toBe('Approved')
    expect(reviewLabel('changes-requested')).toBe('Changes requested')
    expect(reviewLabel('review-required')).toBe('Review required')
    expect(reviewLabel(null)).toBeNull()
  })
})

/* --------------------------------------------------------------- external -- */

describe('openExternal', () => {
  const open = vi.fn()
  const host = globalThis as { window?: unknown }

  // There is no DOM here, so `window.open` — the whole mechanism this helper
  // relies on — has to be stood up and torn down around each case.
  beforeEach(() => {
    open.mockClear()
    host.window = { open }
  })

  afterEach(() => {
    delete host.window
  })

  it('hands an https URL to the window-open handler', () => {
    openExternal('https://github.com/cli/cli/pull/1')
    expect(open).toHaveBeenCalledWith('https://github.com/cli/cli/pull/1', '_blank', 'noopener,noreferrer')
  })

  /** These URLs come off the network; a scheme check is cheaper than trust. */
  it('refuses any scheme that is not http or https', () => {
    openExternal('javascript:alert(1)')
    openExternal('file:///etc/passwd')
    openExternal('')
    expect(open).not.toHaveBeenCalled()
  })
})

/* ------------------------------------------------------------------- rows -- */

describe('PullRow', () => {
  const render = (pull: PullRequest) => renderToStaticMarkup(<PullRow pull={pull} now={NOW} />)

  it('shows the badge, number, author, age and review state', () => {
    const html = render(PULL)
    expect(html).toContain('data-badge="draft"')
    expect(html).toContain('#14130')
    expect(html).toContain('iulia-b')
    expect(html).toContain('>3h<')
    expect(html).toContain('data-review="review-required"')
    expect(html).toContain('Review required')
  })

  it('gives each state its own badge', () => {
    expect(render({ ...PULL, badge: 'open' })).toContain('data-badge="open"')
    expect(render({ ...PULL, badge: 'merged' })).toContain('data-badge="merged"')
    expect(render({ ...PULL, badge: 'closed' })).toContain('data-badge="closed"')
  })

  it('links the row at the pull request on github.com', () => {
    expect(render(PULL)).toContain('open on GitHub')
  })

  it('marks a bot author so a dependabot flood is skimmable', () => {
    expect(render({ ...PULL, authorIsBot: true })).toContain('data-bot="true"')
  })

  it('shows the diff stat only when gh reported one', () => {
    expect(render(PULL)).toContain('+744')
    expect(render({ ...PULL, additions: null, deletions: null })).not.toContain('gh-diffstat')
  })

  it('renders at most three labels and counts the rest', () => {
    const many = ['a', 'b', 'c', 'd', 'e'].map((name) => ({ name, color: '0366d6' }))
    const html = render({ ...PULL, labels: many })
    expect(html).toContain('>c<')
    expect(html).not.toContain('>d<')
    expect(html).toContain('+2')
  })
})

describe('IssueRow', () => {
  it('shows state, number, assignees and age', () => {
    const html = renderToStaticMarkup(<IssueRow issue={ISSUE} now={NOW} />)
    expect(html).toContain('data-badge="open"')
    expect(html).toContain('#14134')
    expect(html).toContain('maintainer')
    expect(html).toContain('>8h<')
  })

  it('badges a closed issue differently', () => {
    const html = renderToStaticMarkup(<IssueRow issue={{ ...ISSUE, state: 'closed' }} now={NOW} />)
    expect(html).toContain('data-badge="closed"')
  })
})

/* ---------------------------------------------------------------- failure -- */

describe('FailureBlock', () => {
  const render = (failure: GitHubFailure) =>
    renderToStaticMarkup(<FailureBlock failure={failure} onRetry={() => {}} />)

  const notAuthed: GitHubFailure = {
    ok: false,
    kind: 'not-authenticated',
    message: 'You are not signed in to GitHub.',
    action: 'gh auth login',
    detail: '',
  }

  const noRemote: GitHubFailure = {
    ok: false,
    kind: 'no-github-remote',
    message: 'None of this repository’s remotes point at GitHub.',
    action: 'git remote add github <url>',
    detail: 'origin → https://gitlab.com/g/p.git',
  }

  /**
   * The requirement this whole module exists for: these two must never read
   * like the same problem, because they need opposite things from the user.
   */
  it('gives sign-in and no-remote entirely different instructions', () => {
    const auth = render(notAuthed)
    const remote = render(noRemote)

    expect(auth).toContain('Not signed in to GitHub')
    expect(auth).toContain('gh auth login')
    expect(remote).toContain('No GitHub remote')
    expect(remote).toContain('git remote add github')

    expect(auth).not.toContain('remote')
    expect(remote).not.toContain('Not signed in')
  })

  it('offers Retry for a transient failure', () => {
    const html = render({
      ok: false,
      kind: 'network-down',
      message: 'Could not reach github.com.',
      action: null,
      detail: '',
    })
    expect(html).toContain('Cannot reach GitHub')
    expect(html).toContain('Retry')
  })

  it('hides the details disclosure when there is no tool output to show', () => {
    expect(render(notAuthed)).not.toContain('<details')
    expect(render(noRemote)).toContain('<details')
  })

  it('titles every failure kind it can be handed', () => {
    for (const kind of ['gh-missing', 'rate-limited', 'timeout', 'repo-not-found'] as const) {
      const html = render({ ok: false, kind, message: 'x', action: null, detail: '' })
      expect(html).toContain('gh-failure-title')
      expect(html).not.toContain('undefined')
    }
  })
})
