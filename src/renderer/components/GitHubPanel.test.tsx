import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import * as panelModule from './GitHubPanel'
import {
  AccessNotice,
  accessSummary,
  bridgeSilentState,
  ConnectionBar,
  ConnectPage,
  countLabel,
  DeviceCodeCard,
  FailureBlock,
  filterRepos,
  folderLine,
  formatAge,
  IssueRow,
  minutesLeft,
  pageFailureOf,
  PullRow,
  RepositoryList,
  repoFailed,
  reviewLabel,
  selectionSentence,
  showsAction,
  sourceSentence,
  type DeviceFlowPrompt,
  type GitHubAuthState,
  type GitHubFailure,
  type Issue,
  type PullRequest,
  type RepoAccessList,
  type RepoRef,
  type RepoSummary,
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

/* ------------------------------------------------------------------ links -- */

/**
 * Where this panel's links go.
 *
 * The helper itself moved to `renderer/link.ts` and is tested there. What has
 * to be pinned *here* is the split, because it is a decision about GitHub
 * rather than about links: pages you read open in this app's own browser, and
 * the two authorisation URLs deliberately still leave. The rows are rendered
 * rather than asserted about in the abstract — an `onClick` nobody wired is
 * exactly the failure this catches.
 */
describe('links', () => {
  const source = readFileSync(join(__dirname, 'GitHubPanel.tsx'), 'utf8')

  /**
   * The line this whole change removed. `openExternal` here meant "deny the
   * window and hand it to `shell.openExternal`", which is how pressing a pull
   * request launched Chrome over the app.
   */
  it('has no route straight to the system browser left in it', () => {
    expect(source).not.toContain('openExternal(')
  })

  it('opens every page you read in a tab of this app', () => {
    // `linkProps` is both handlers at once — left opens it here, right offers
    // the system browser — so a row carrying it cannot have picked up one and
    // forgotten the other.
    for (const url of ['repo.url', 'pull.url', 'issue.url', 'folderRepo.url']) {
      expect(source, `${url} is not opened with linkProps`).toContain(`linkProps(${url})`)
    }
    expect(source).toContain('linkProps(state.identity?.htmlUrl')
  })

  /**
   * The exception, deliberately. The app's browser is the one browser on this
   * machine with no github.com session and no WebAuthn client, so a sign-in
   * page opened there begins by asking you to sign in. See
   * `openAuthorizationUrl` for the long form.
   */
  it('sends the two authorisation pages to the system browser', () => {
    expect(source).toContain('openAuthorizationUrl(started.verificationUri)')
    expect(source).toContain('openAuthorizationUrl(pending.verificationUri)')
    expect(source).toContain('openAuthorizationUrl(installUrl)')
    expect(source).toContain('openAuthorizationUrl(state.installUrl)')
    // And it is the way out, not a second copy of the old habit.
    expect(source).toContain('openLinkExternally(url)')
  })

  it('reads a file it can actually see', () => {
    // Guards the guard: every case above is a `toContain`, and all of them
    // would pass vacuously against an empty read if the path were wrong.
    expect(source.length).toBeGreaterThan(1000)
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
  // A `gh auth login` token, which reports whatever scopes that login happens
  // to carry. Nothing here asks GitHub for scopes any more, so this is a fact
  // the card shows rather than a list measured against a request.
  scopes: ['repo', 'read:org', 'notifications'],
  scopesReported: true,
  ghInstalled: true,
  credentialKind: 'oauth',
  appConfigured: true,
  installUrl: 'https://github.com/apps/terminal-deck/installations/new',
  disconnect: 'Deletes the sign-in this app stored.',
  pending: null,
  failure: null,
  expiredCredentialRemoved: false,
  repo: null,
  branch: null,
  access: null,
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
  installUrl: 'https://github.com/apps/terminal-deck/installations/new',
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
    expect(html).not.toContain('gh-conn-scopes-label')
    // And says nothing at all about the absence. The two sentences that used to
    // explain why the row was missing were the standing prose he has banned.
    expect(html).not.toContain('GitHub App sign-in')
    expect(html).not.toContain('nothing')
  })

  /**
   * Scopes are shown, not graded.
   *
   * There used to be a "Missing one permission" block with a re-authorise
   * button under it, driven by comparing a token's scopes against the list this
   * app requested. It requests none — a GitHub App device request carries no
   * `scope` at all — so the comparison had one answer for every token ever
   * issued, and the button could not have granted anything. What is left is one
   * labelled run of what GitHub reported.
   */
  it('grades nothing, because nothing is asked for', () => {
    const html = bar({ ...CONNECTED, source: 'gh-cli', scopes: ['repo', 'read:org'] })
    expect(html).toContain('Granted')
    expect(html).toContain('repo')
    expect(html).not.toContain('Missing')
    expect(html).not.toContain('Sign in again')
    // And no second run to sort them into: "Also granted" with nothing before
    // it is a label describing a distinction that no longer exists.
    expect(html).not.toContain('Also granted')
    expect(html).not.toContain('Used here')
  })

  /**
   * The dead-control case, which survives the removal above: this process
   * cannot unset a variable in the shell that launched it, and a Disconnect
   * that silently does nothing is worse than none.
   */
  it('offers no Disconnect when the credential comes from the environment', () => {
    const html = bar({ ...CONNECTED, source: 'environment', disconnect: null })
    expect(html).toContain('GH_TOKEN')
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

  it('shows the code, where to type it, and what is about to be asked', () => {
    const html = render()
    expect(html).toContain('E874-5342')
    expect(html).toContain('https://github.com/login/device')
    expect(html).toContain('which repositories')
    expect(html).toContain('Cancel')
  })

  /**
   * The card no longer apologises for the name on GitHub's page.
   *
   * It used to, and it had to: the OAuth path signed in with the GitHub CLI's
   * public client id, so the consent screen said "GitHub CLI" rather than this
   * app's name. That path is gone, the screen names this app, and a warning
   * about somebody else's would now be false.
   */
  it('does not warn about a consent screen naming somebody else', () => {
    expect(render()).not.toContain('GitHub CLI')
  })

  /** No scope list either: a GitHub App request carries none to print. */
  it('never renders an empty "asking for" list', () => {
    expect(render()).not.toContain('Asking for')
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

  /**
   * A build with no GitHub App registered cannot start a sign-in, so it is not
   * offered one.
   *
   * This is the case the deleted OAuth fallback used to absorb: with nothing
   * registered it borrowed the GitHub CLI's client id and signed the user in as
   * another application. There is nothing to send now, so a Connect button here
   * would reach GitHub, take a 404 that names nothing, and do it again every
   * time it was pressed — the "looks clickable, does nothing" failure this
   * codebase puts first. The failure's own sentence carries the two real ways
   * out, and the permissions block is withheld because there are no permissions
   * about to be asked for.
   */
  it('offers no Connect button in a build with no registration', () => {
    const html = render({
      ...DISCONNECTED,
      appConfigured: false,
      installUrl: null,
      failure: {
        ok: false,
        kind: 'not-authenticated',
        message:
          'This build has no GitHub App registered, so there is nothing here to sign in through. Run gh auth login in a terminal and this app will use it, or set TERMINALDECK_GITHUB_APP_CLIENT_ID to a registration of your own.',
        action: 'gh auth login',
        detail: '',
      },
    })
    expect(html).not.toContain('Connect to GitHub')
    expect(html).toContain('no GitHub App registered')
    expect(html).toContain('TERMINALDECK_GITHUB_APP_CLIENT_ID')
    expect(html).not.toContain('What this asks for')
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

/* ----------------------------------------------------------- the folder -- */

const FOLDER_REPO: RepoRef = {
  host: 'github.com',
  owner: 'asadev',
  name: 'terminaldeck',
  nameWithOwner: 'asadev/terminaldeck',
  url: 'https://github.com/asadev/terminaldeck',
  remote: 'origin',
}

describe('folderLine', () => {
  it('names the repository and the branch as one fact', () => {
    expect(folderLine(FOLDER_REPO, { name: 'main', detached: false, head: null })).toBe(
      'asadev/terminaldeck · main',
    )
  })

  /** A detached HEAD is not a branch, and calling it one would be wrong. */
  it('says detached rather than inventing a branch name', () => {
    expect(folderLine(FOLDER_REPO, { name: null, detached: true, head: 'a1b2c3d' })).toBe(
      'asadev/terminaldeck · detached at a1b2c3d',
    )
    expect(folderLine(FOLDER_REPO, { name: null, detached: true, head: null })).toBe(
      'asadev/terminaldeck · detached HEAD',
    )
  })

  it('falls back to the repository alone when no branch was read', () => {
    expect(folderLine(FOLDER_REPO, null)).toBe('asadev/terminaldeck')
  })

  /**
   * The three local failures keep their own sentences here rather than
   * collapsing into "no repository": `github.ts` spends a whole failure
   * vocabulary telling them apart and this is where the user reads it.
   */
  it('passes the resolution’s own sentence through untouched', () => {
    const failure: GitHubFailure = {
      ok: false,
      kind: 'not-a-repo',
      message: 'This folder is not a git repository.',
      action: 'git init',
      detail: '',
    }
    expect(folderLine(failure, null)).toBe('This folder is not a git repository.')
    expect(folderLine(null, null)).toBeNull()
  })
})

/* ------------------------------------------------------ what it asks for -- */

/**
 * The block that exists because of a screenshot: GitHub's page said "Full
 * control of private repositories" and there was no way to pick which ones.
 * These assertions are about the words, because the words are the fix.
 *
 * The screen it warned about was the OAuth path's, and that path is gone. What
 * the block says now is what the one remaining consent screen actually shows,
 * which is a repository picker — and it still renders *before* the button,
 * because the point was never the wording, it was that nobody arrives at
 * GitHub's page surprised.
 */
describe('AccessNotice', () => {
  const render = (state: GitHubAuthState) =>
    renderToStaticMarkup(<AccessNotice state={state} />)

  it('promises the repository choice the sign-in actually offers', () => {
    const html = render({ ...DISCONNECTED, appConfigured: true })
    expect(html).toContain('only select repositories')
    expect(html).toContain('Choose repositories on GitHub')
  })

  /**
   * And it never says the sentence the OAuth grant made it say. `repo` is a
   * single all-or-nothing grant over every private repository the account can
   * reach, write included, and GitHub renders it exactly this way — printing it
   * now would describe a consent screen this app cannot produce.
   */
  it('no longer warns about a whole-account grant it cannot ask for', () => {
    const html = render({ ...DISCONNECTED, appConfigured: true })
    expect(html).not.toContain('Full control of private repositories')
    expect(html).not.toContain('no narrower scope')
    expect(html).not.toContain('Access notifications')
    expect(html).not.toContain('read:org')
  })
})

/* ---------------------------------------------------------- repositories -- */

const REPOS: RepoSummary[] = [
  {
    owner: 'asadev',
    name: 'terminaldeck',
    nameWithOwner: 'asadev/terminaldeck',
    url: 'https://github.com/asadev/terminaldeck',
    private: false,
    fork: false,
    archived: false,
    description: 'A desktop workspace for AI coding agents.',
    language: 'TypeScript',
    defaultBranch: 'main',
    pushedAt: '2026-08-12T09:00:00Z',
    canPush: true,
  },
  {
    owner: 'asadev',
    name: 'commander',
    nameWithOwner: 'asadev/commander',
    url: 'https://github.com/asadev/commander',
    private: true,
    fork: false,
    archived: false,
    description: 'Orchestrator workspace.',
    language: 'PLpgSQL',
    defaultBranch: 'main',
    pushedAt: '2026-08-11T09:00:00Z',
    canPush: true,
  },
]

const ACCESS: RepoAccessList = {
  ok: true,
  repos: REPOS,
  atLeast: 2,
  truncated: false,
  source: 'account',
  selection: null,
  rateRemaining: 4993,
  fetchedAt: NOW,
}

describe('accessSummary', () => {
  it('counts exactly when the whole list is here', () => {
    expect(accessSummary(ACCESS)).toBe('2 repositories')
    expect(accessSummary({ ...ACCESS, repos: [REPOS[0]], atLeast: 1 })).toBe('1 repository')
  })

  /**
   * The regression this is written against is the same one `countLabel` guards
   * on the tabs: a bare "100" for an account with five hundred repositories is
   * a specific wrong number that looks exactly like a right one.
   */
  it('never prints a bare count for a list it knows is cut off', () => {
    const summary = accessSummary({ ...ACCESS, truncated: true, atLeast: 401 })
    expect(summary).toContain('401+')
    expect(summary).toContain('most recently pushed')
  })
})

describe('selectionSentence', () => {
  /** An OAuth `repo` scope leaves no choice, so describing one would be a lie. */
  it('says nothing about selection for an account-wide token', () => {
    expect(selectionSentence(ACCESS)).toBeNull()
  })

  it('tells the two GitHub App installations apart', () => {
    const installed = { ...ACCESS, source: 'installation' as const }
    expect(selectionSentence({ ...installed, selection: 'all' })).toContain('all your repositories')
    expect(selectionSentence({ ...installed, selection: 'selected' })).toContain('you selected')
  })
})

describe('filterRepos', () => {
  it('matches the name and the description, case-insensitively', () => {
    expect(filterRepos(REPOS, 'DECK').map((repo) => repo.name)).toEqual(['terminaldeck'])
    expect(filterRepos(REPOS, 'orchestrator').map((repo) => repo.name)).toEqual(['commander'])
    expect(filterRepos(REPOS, '')).toHaveLength(2)
    expect(filterRepos(REPOS, '   ')).toHaveLength(2)
  })
})

describe('RepositoryList', () => {
  const render = (access: RepoAccessList | GitHubFailure | null, query = '', current: string | null = null) =>
    renderToStaticMarkup(
      <RepositoryList
        access={access}
        query={query}
        onQuery={() => {}}
        current={current}
        installUrl={null}
        onRetry={() => {}}
        now={NOW}
      />,
    )

  it('lists the repositories the sign-in can reach', () => {
    const html = render(ACCESS)
    expect(html).toContain('asadev/terminaldeck')
    expect(html).toContain('asadev/commander')
    expect(html).toContain('TypeScript')
    expect(html).toContain('2 repositories')
  })

  /** Private and public are the one distinction worth a badge in this list. */
  it('marks which repositories are private', () => {
    const html = render(ACCESS)
    expect(html).toContain('>private<')
    expect(html).toContain('>public<')
  })

  it('marks the repository of the folder that is open', () => {
    const html = render(ACCESS, '', 'asadev/commander')
    expect(html).toContain('data-current="true"')
    expect(html).toContain('this folder')
  })

  /**
   * A filter over a truncated page must say so. "No matches" for a repository
   * that exists — because it is on page four — is the kind of wrong answer that
   * looks like a right one.
   */
  it('admits that a filter only searched the page it has', () => {
    const html = render({ ...ACCESS, truncated: true, atLeast: 401 }, 'nothing-matches-this')
    expect(html).toContain('in the page loaded here')
  })

  it('renders a failed listing as a failure, not as an empty list', () => {
    const html = render({
      ok: false,
      kind: 'rate-limited',
      message: 'GitHub’s API rate limit is exhausted.',
      action: null,
      detail: '',
    })
    expect(html).toContain('GitHub rate limit reached')
    expect(html).toContain('Retry')
  })

  /**
   * Signed in, and genuinely nothing to see. It is a real state — a brand new
   * account, or a GitHub App installed on nothing — and it gets a sentence
   * rather than a blank column.
   */
  it('explains an empty list instead of showing a blank page', () => {
    expect(render({ ...ACCESS, repos: [], atLeast: 0 })).toContain('cannot reach any repositories')
  })
})

/* --------------------------------------------------- the bell, removed -- */

/**
 * The notifications bell is gone from this panel, and this is what fails if it
 * comes back.
 *
 * Not a taste decision. GitHub's reference for its notifications endpoints
 * carries the note, verbatim: *"These endpoints only support authentication
 * using a personal access token (classic)."* This app signs in through a GitHub
 * App and nothing else, so the credential it holds is refused by the endpoint
 * itself — there is no permission to tick and no scope to ask for. The feature
 * could not work, so it is not on screen as an empty count or as a standing
 * error explaining itself.
 *
 * The header is where it lived: a count beside the refresh button, tinted with
 * the accent when something was waiting on this repository.
 */
describe('the notifications bell', () => {
  it('is not part of this module’s surface any more', () => {
    expect(Object.keys(panelModule).filter((name) => /notification/i.test(name))).toEqual([])
  })

  /**
   * And no failure kind describes its absence. `notifications-unsupported`
   * existed only to say "GitHub will not serve the bell to this sign-in", which
   * is a sentence about a feature that is no longer there — and it had a
   * headline in `FAILURE_TITLE` that would render for any payload still
   * carrying the kind.
   */
  it('has no failure headline left to render', () => {
    const html = renderToStaticMarkup(
      <FailureBlock
        failure={{ ok: false, kind: 'error', message: 'x', action: null, detail: '' }}
        onRetry={noop}
      />,
    )
    expect(html).not.toContain('Notifications')
    expect(html).not.toContain('classic sign-in')
  })
})

/**
 * Two tabs printing one screen — the complaint that came back three times.
 *
 *   > *"issue and pull request pages are like identical showing the same stuff,
 *   > same error, same buttons."* (2026-08-16)
 *   > *"in the issues and pull requests, this is still like the same old thing
 *   > that we discussed before many times, so it's not being resolved."*
 *   > (2026-08-20)
 *
 * `listBody(kind, section)` took a `kind` and then branched on it in exactly one
 * of its six paths. Every failing state — no repository, no `gh`, a rate limit,
 * an outage — rendered a byte-identical block under both tabs, because both
 * lists come from one call against one repository and there was never more than
 * one answer to show.
 *
 * These tests pin the split that fixes it: which failures are the *page's*, and
 * therefore drawn once with the two list tabs withdrawn.
 */
describe('a failure that is the page’s, not each list’s', () => {
  const failure = (kind: GitHubFailure['kind'], message: string): GitHubFailure => ({
    ok: false,
    kind,
    message,
    action: null,
    detail: '',
  })

  const repo: RepoRef = {
    nameWithOwner: 'asadev/terminaldeck',
    owner: 'asadev',
    name: 'terminaldeck',
    host: 'github.com',
    url: 'https://github.com/asadev/terminaldeck',
    remote: 'origin',
  }

  it('is the repository resolution, when the folder has no GitHub repository', () => {
    // The state Asad was in: a session started in an empty folder. Both tabs
    // used to render this same block.
    const notRepo = failure('not-a-repo', 'This folder is not a git repository.')
    expect(pageFailureOf(notRepo, null)).toBe(notRepo)
  })

  it('is the list read, when the repository resolved but the call did not', () => {
    // `gh` missing, a rate limit, an outage: one call feeds both lists, so its
    // failure is the page's too.
    const noGh = failure('gh-missing', 'The GitHub CLI is not installed.')
    expect(pageFailureOf(repo, noGh)).toBe(noGh)
  })

  it('names the repository first when both are wrong at once', () => {
    // Fixing the folder is what makes the other one possible, so it is the one
    // worth putting on screen.
    const notRepo = failure('no-github-remote', 'No remote points at GitHub.')
    const rateLimited = failure('rate-limited', 'Rate limit reached.')
    expect(pageFailureOf(notRepo, rateLimited)).toBe(notRepo)
  })

  it('is nothing at all when the lists have something to say for themselves', () => {
    // The only state where two tabs are two different screens — and the only
    // state where they are drawn.
    expect(pageFailureOf(repo, null)).toBeNull()
    // Before the sign-in has been read there is no repository either way.
    expect(pageFailureOf(null, null)).toBeNull()
  })

  it('leaves a per-list failure to its own list', () => {
    /*
     * The one thing that must NOT be hoisted. `gh pr list` can fail while
     * `gh issue list` succeeds — a repository with issues disabled is the
     * everyday case — and that is a genuine difference between the two tabs.
     * `pageFailureOf` never sees a section failure, which is what keeps that
     * difference on the page.
     */
    expect(pageFailureOf(repo, null)).toBeNull()
  })
})

/**
 * GitHub Copilot, on the GitHub page rather than in Settings.
 *
 *   > *"we will move this GitHub Copilot from here to the main page of GitHub,
 *   > because we have already a page specifically for GitHub, so don't need to
 *   > keep it inside the settings."*
 *
 * The row is asserted through the file rather than through a render, because
 * what has to stay true is a *placement*: the component exists here, and the id
 * it reads is the one `main/setup.ts` reports.
 */
describe('the Copilot row moved here', () => {
  const source = readFileSync(join(process.cwd(), 'src/renderer/components/GitHubPanel.tsx'), 'utf8')
  const settings = readFileSync(
    join(process.cwd(), 'src/renderer/settings/sections/SetupSection.tsx'),
    'utf8',
  )

  it('is drawn on this page, from the machine probe', () => {
    expect(source).toContain('function CopilotRow')
    expect(source).toMatch(/tools\.find\(\(tool\) => tool\.id === 'copilot'\)/)
  })

  it('left nothing behind in Settings', () => {
    // Not a "moved to the GitHub page" pointer either: a cross-reference is
    // what made Setup and Agents read as two halves of one screen, and one is
    // not being added back on the way out.
    expect(settings).toContain("MOVED_TOOL_IDS: readonly string[] = ['copilot']")
    expect(settings).toContain('MOVED_TOOL_IDS.includes(tool.id)')
  })

  it('brought the name and the state, and none of the four lines under them', () => {
    // The Settings row carried the tool's purpose, a caveat, a remedy and the
    // literal shell probe. *"Don't put any single statement in anywhere."*
    const row = source.slice(source.indexOf('function CopilotRow'))
    const body = row.slice(0, row.indexOf('\n}\n'))
    expect(body).toContain('TOOL_STATE_LABEL[tool.state]')
    expect(body).not.toContain('tool.purpose')
    expect(body).not.toContain('tool.remedy')
    expect(body).not.toContain('tool.probe')
    expect(body).not.toContain('tool.note')
  })
})
