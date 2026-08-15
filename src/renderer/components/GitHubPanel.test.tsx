import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  bridgeSilentState,
  ConnectionBar,
  ConnectPage,
  countLabel,
  DeviceCodeCard,
  FailureBlock,
  formatAge,
  IssueRow,
  minutesLeft,
  missingScopeCost,
  openExternal,
  PullRow,
  repoFailed,
  reviewLabel,
  scopeBuys,
  showsAction,
  sourceSentence,
  type DeviceFlowPrompt,
  type GitHubAuthState,
  type GitHubFailure,
  type Issue,
  type PullRequest,
  type RepoRef,
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

  /**
   * Several messages name their own fix — "Connect here, or run gh auth login
   * in a terminal" — and the command line under them then said it a second
   * time, in the next sentence. Rendered, that reads as generated text rather
   * than written text.
   */
  it('does not repeat a command the message already gave', () => {
    expect(
      showsAction({
        ok: false,
        kind: 'not-authenticated',
        message: 'Connect here, or run gh auth login in a terminal — either one works.',
        action: 'gh auth login',
        detail: '',
      }),
    ).toBe(false)
    expect(showsAction(noRemote)).toBe(true)
    expect(showsAction({ ...noRemote, action: null })).toBe(false)
  })

  it('titles every failure kind it can be handed', () => {
    for (const kind of ['gh-missing', 'rate-limited', 'timeout', 'repo-not-found'] as const) {
      const html = render({ ok: false, kind, message: 'x', action: null, detail: '' })
      expect(html).toContain('gh-failure-title')
      expect(html).not.toContain('undefined')
    }
  })
})

/* ------------------------------------------------------------- connection -- */

/**
 * The sign-in half of the page. Same argument as the block above: what is being
 * pinned is that the states read *differently*, because the complaint that
 * started this feature was a Windows machine that looked half connected with
 * nothing on screen saying which half.
 *
 * These render to static markup, so what they can check is what a user would
 * see — the words, the buttons that exist, and the buttons that deliberately do
 * not. That is the right level for this: every bug being guarded against here
 * is a sentence, not a state transition.
 */

const CONNECTED: GitHubAuthState = {
  connected: true,
  source: 'device-flow',
  host: 'github.com',
  identity: {
    login: 'asadev',
    name: 'Asad',
    htmlUrl: 'https://github.com/asadev',
    avatarUrl: 'https://avatars.githubusercontent.com/u/1?v=4',
  },
  scopes: ['repo', 'read:org', 'notifications'],
  scopesReported: true,
  missingScopes: [],
  ghInstalled: true,
  borrowedClient: true,
  disconnect: 'Deletes the sign-in this app stored.',
  pending: null,
  failure: null,
  expiredCredentialRemoved: false,
  repo: null,
}

const DISCONNECTED: GitHubAuthState = {
  ...CONNECTED,
  connected: false,
  source: null,
  identity: null,
  scopes: [],
  scopesReported: false,
  disconnect: null,
  failure: {
    ok: false,
    kind: 'not-authenticated',
    message: 'Not signed in to GitHub. Connect here, or run gh auth login in a terminal.',
    action: 'gh auth login',
    detail: '',
  },
}

const PROMPT: DeviceFlowPrompt = {
  userCode: 'E874-5342',
  verificationUri: 'https://github.com/login/device',
  expiresAt: NOW + 14 * 60_000,
  scopes: ['repo', 'read:org', 'notifications'],
  borrowedClient: true,
}

const noop = () => {}

function bar(state: GitHubAuthState, confirming = false): string {
  return renderToStaticMarkup(
    <ConnectionBar
      state={state}
      confirming={confirming}
      onAskDisconnect={noop}
      onDisconnect={noop}
      onKeep={noop}
      onReconnect={noop}
    />,
  )
}

describe('sourceSentence', () => {
  /**
   * Three sources, three sentences, and the environment one is the sentence
   * the whole feature was written for: a token in a shell profile is
   * indistinguishable from a sign-in until Disconnect fails to remove it.
   */
  it('names where the credential came from, differently every time', () => {
    const device = sourceSentence('device-flow', 'github.com')
    const cli = sourceSentence('gh-cli', 'github.com')
    const env = sourceSentence('environment', 'github.com')

    expect(device).toContain('this app')
    expect(cli).toContain('GitHub CLI')
    expect(env).toContain('GH_TOKEN')
    expect(new Set([device, cli, env]).size).toBe(3)
  })

  it('carries an enterprise host into the sentence rather than assuming one', () => {
    expect(sourceSentence('gh-cli', 'git.acme.co')).toContain('git.acme.co')
    expect(sourceSentence('gh-cli', 'git.acme.co')).not.toContain('github.com')
  })
})

describe('scopes, in the user’s terms', () => {
  it('says what each requested scope buys, and nothing about ones we did not ask for', () => {
    expect(scopeBuys('repo')).toContain('private')
    expect(scopeBuys('notifications')).toContain('unread')
    // A `gist` scope arrives on plenty of real `gh auth login` tokens. Showing
    // it is honest; claiming to know why it is there is not.
    expect(scopeBuys('gist')).toBeNull()
  })

  it('says what a missing scope costs, not just that it is missing', () => {
    expect(missingScopeCost('notifications')).toContain('unread count')
    expect(missingScopeCost('repo')).toContain('Private repositories')
    expect(missingScopeCost('gist')).toContain('gist')
    expect(missingScopeCost('repo')).not.toBe(missingScopeCost('read:org'))
  })
})

describe('ConnectionBar', () => {
  it('names the account and every scope GitHub reported', () => {
    const html = bar(CONNECTED)
    expect(html).toContain('asadev')
    for (const scope of ['repo', 'read:org', 'notifications']) expect(html).toContain(scope)
    expect(html).toContain('Disconnect')
  })

  /**
   * A fine-grained token or a GitHub App installation sends no
   * `X-OAuth-Scopes` header at all. Rendering that as "granted: nothing" tells
   * somebody their working credential is broken.
   */
  it('does not report an unreported scope list as an empty one', () => {
    const html = bar({ ...CONNECTED, scopes: [], scopesReported: false })
    expect(html).toContain('fine-grained')
    expect(html).not.toContain('gh-conn-scopes-label')
  })

  it('names the missing permission and what it costs', () => {
    const html = bar({
      ...CONNECTED,
      source: 'gh-cli',
      scopes: ['repo', 'read:org'],
      missingScopes: ['notifications'],
    })
    expect(html).toContain('Missing one permission')
    expect(html).toContain('notifications')
    expect(html).toContain('unread count')
    expect(html).toContain('Sign in again')
  })

  /**
   * The dead-control case. `gh` and this panel both prefer `GH_TOKEN`, so a
   * fresh sign-in would be stored, shadowed, and never used — a button here
   * would do nothing at all, visibly.
   */
  it('offers no re-sign-in when the credential comes from the environment', () => {
    const html = bar({
      ...CONNECTED,
      source: 'environment',
      disconnect: null,
      missingScopes: ['notifications'],
    })
    expect(html).not.toContain('Sign in again')
    expect(html).toContain('GH_TOKEN')
    // Nor a Disconnect: this process cannot unset a variable in the shell that
    // launched it, and a button that silently does nothing is worse than none.
    expect(html).not.toContain('gh-conn-action')
    expect(html).toContain('Nothing to disconnect')
  })

  /**
   * Disconnecting a `gh` login signs the user's *terminal* out. The sentence
   * that says so has to be on screen before the press that does it, not after.
   */
  it('shows what disconnecting will do before it does it', () => {
    const state: GitHubAuthState = {
      ...CONNECTED,
      source: 'gh-cli',
      disconnect: 'Signs the GitHub CLI out on this machine, so your terminal is signed out too.',
    }
    expect(bar(state, true)).toContain('your terminal is signed out too')
    expect(bar(state, true)).toContain('Keep it')
    expect(bar(state, false)).toContain('Disconnect')
    expect(bar(state, false)).not.toContain('Keep it')
  })

  /**
   * `img-src 'self' data:` blocks avatars.githubusercontent.com outright, so an
   * `<img>` here renders as a broken-image glyph in the one block that is
   * claiming the app works.
   */
  it('never renders a remote avatar', () => {
    expect(bar(CONNECTED)).not.toContain('<img')
    expect(bar(CONNECTED)).not.toContain('avatars.githubusercontent.com')
  })
})

describe('DeviceCodeCard', () => {
  const render = (prompt = PROMPT, onCopy?: () => void) =>
    renderToStaticMarkup(
      <DeviceCodeCard prompt={prompt} now={NOW} onCopy={onCopy} onOpen={noop} onCancel={noop} />,
    )

  it('shows the code, where to type it, and what is being asked for', () => {
    const html = render()
    expect(html).toContain('E874-5342')
    expect(html).toContain('https://github.com/login/device')
    expect(html).toContain('repo, read:org, notifications')
    expect(html).toContain('Cancel')
  })

  /** Borrowed OAuth client: the consent screen says GitHub CLI, so we do too. */
  it('warns that the consent screen names somebody else', () => {
    expect(render()).toContain('GitHub CLI')
    expect(render({ ...PROMPT, borrowedClient: false })).not.toContain('GitHub CLI')
  })

  it('counts the code down and says when it is dead', () => {
    expect(render()).toContain('about 14 more minutes')
    expect(render({ ...PROMPT, expiresAt: NOW - 1000 })).toContain('expired')
    expect(minutesLeft(NOW + 60_000, NOW)).toBe(1)
    expect(minutesLeft(NOW - 60_000, NOW)).toBe(0)
  })

  /**
   * Where there is no clipboard API there is no Copy button. A copy control
   * that silently does nothing is the promise this codebase's rules put first,
   * and the code stays selectable text either way.
   */
  it('offers Copy only when the panel handed it a way to copy', () => {
    expect(render(PROMPT, noop)).toContain('Copy')
    expect(render(PROMPT, undefined)).not.toContain('Copy')
    expect(render(PROMPT, undefined)).toContain('E874-5342')
  })
})

describe('ConnectPage', () => {
  const render = (state: GitHubAuthState) =>
    renderToStaticMarkup(<ConnectPage state={state} onConnect={noop} onRetry={noop} />)

  it('offers a Connect button rather than a command to go and type', () => {
    const html = render(DISCONNECTED)
    expect(html).toContain('Connect to GitHub')
    // The CLI route is still named — it works, and somebody who prefers it
    // should not have to guess — but it is the hint, not the instruction.
    expect(html).toContain('gh auth login')
  })

  /**
   * The four sign-in failures a person actually hits. Each has a different fix,
   * so each has to arrive as a different screen — collapsing them into "GitHub
   * failed" is the bug this whole feature exists to remove.
   */
  it('gives every sign-in failure its own headline', () => {
    const titles = (['gh-missing', 'auth-declined', 'auth-code-expired', 'auth-unavailable'] as const).map(
      (kind) =>
        render({
          ...DISCONNECTED,
          failure: { ok: false, kind, message: `message for ${kind}`, action: null, detail: '' },
        }),
    )
    expect(titles[0]).toContain('GitHub CLI not installed')
    expect(titles[1]).toContain('Sign-in refused')
    expect(titles[2]).toContain('The sign-in code expired')
    expect(titles[3]).toContain('GitHub would not start a sign-in')
    for (const html of titles) expect(html).not.toContain('undefined')
  })

  /**
   * Connecting cannot fix an outage, and a Connect button during one produces a
   * second identical error. Those get Retry instead.
   */
  it('offers Retry, not Connect, for a failure a sign-in cannot fix', () => {
    const html = render({
      ...DISCONNECTED,
      failure: {
        ok: false,
        kind: 'network-down',
        message: 'Could not reach github.com — check your connection.',
        action: null,
        detail: '',
      },
    })
    expect(html).toContain('Try again')
    expect(html).not.toContain('Connect to GitHub')
  })

  it('says the folder’s repository while you are still signing in', () => {
    const repo: RepoRef = {
      host: 'github.com',
      owner: 'asadev',
      name: 'terminaldeck',
      nameWithOwner: 'asadev/terminaldeck',
      url: 'https://github.com/asadev/terminaldeck',
      remote: 'origin',
    }
    expect(render({ ...DISCONNECTED, repo })).toContain('asadev/terminaldeck')

    // And when the folder is the problem, that is said here too — it is not a
    // sign-in fault and must not be reported as one.
    const notARepo = render({
      ...DISCONNECTED,
      repo: {
        ok: false,
        kind: 'not-a-repo',
        message: 'This folder is not a git repository.',
        action: 'git init',
        detail: '',
      },
    })
    expect(notARepo).toContain('not a git repository')
    expect(notARepo).toContain('Connect to GitHub')
  })

  it('says so when a dead stored sign-in was cleaned up on the way past', () => {
    expect(render({ ...DISCONNECTED, expiredCredentialRemoved: true })).toContain('was deleted')
    expect(render(DISCONNECTED)).not.toContain('was deleted')
  })
})

describe('bridgeSilentState', () => {
  /**
   * The bridge going quiet is its own answer, and every field of it has to be a
   * fact: claiming `ghInstalled` or a granted scope when nothing was ever
   * probed would put an unchecked sentence on screen.
   */
  it('claims nothing it has not checked', () => {
    const state = bridgeSilentState()
    expect(state.connected).toBe(false)
    expect(state.ghInstalled).toBe(false)
    expect(state.scopes).toEqual([])
    expect(state.scopesReported).toBe(false)
    expect(state.disconnect).toBeNull()
    expect(state.failure?.message).toContain('did not answer')
  })
})

describe('repoFailed', () => {
  /**
   * The one place in this file where the discriminator is the *presence* of
   * `ok` rather than its value: a `RepoRef` has no such field, so `isFailure`
   * would be a near-miss that happens to compile nowhere.
   */
  it('tells a resolved repository from the reason there is none', () => {
    expect(
      repoFailed({
        host: 'github.com',
        owner: 'a',
        name: 'b',
        nameWithOwner: 'a/b',
        url: 'https://github.com/a/b',
        remote: 'origin',
      }),
    ).toBe(false)
    expect(
      repoFailed({ ok: false, kind: 'no-remote', message: 'x', action: null, detail: '' }),
    ).toBe(true)
  })
})
