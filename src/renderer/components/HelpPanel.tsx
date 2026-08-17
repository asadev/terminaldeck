import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Modal } from './Modal'
import { PANELS, type PanelId } from '../shell/panels'
import { detectMac, formatBinding, groupedKeymap, KEYMAP, searchKeymap } from '../keymap'
import './HelpPanel.css'

/**
 * In-app help.
 *
 * Written for the moment it is actually opened, which is never "I would like a
 * tour" and almost always "this does not work and I do not know why". So the
 * troubleshooting section is not generic advice — every entry is a failure mode
 * this app really has, with the reason it happens and the command that proves
 * it, and the causes are the ones the code actually implements:
 *
 *  - `providers.ts` asks the login shell for its PATH because a GUI app does
 *    not inherit one. On the machine this was written on, `claude` lives in
 *    `~/.local/bin` (its native installer), `codex`, `gemini` and `gh` in
 *    `/opt/homebrew/bin` — none of which are on a bare GUI PATH.
 *  - `prerequisites.ts` refuses to guess at authentication and lets the CLI's
 *    own login prompt appear in the terminal, so "installed but not signed in"
 *    is a real, distinct state the help has to explain.
 *
 * The shortcut list is generated from `keymap.ts` and the panel list from
 * `shell/panels.ts`. A hand-written copy of either is a copy that rots quietly,
 * and help that lies is worse than no help.
 *
 * The product name is never hardcoded here: copy uses `{app}`, filled in from
 * whatever the bridge reports.
 */

/* ------------------------------------------------------------------ types -- */

export type HelpSectionId = 'start' | 'panels' | 'shortcuts' | 'trouble' | 'about'

export type HelpBlock =
  | { kind: 'text'; text: string }
  | { kind: 'steps'; items: string[] }
  | { kind: 'bullets'; items: string[] }
  | { kind: 'code'; code: string }
  | { kind: 'note'; text: string }

export interface HelpTopic {
  id: string
  section: HelpSectionId
  title: string
  blocks: HelpBlock[]
  /** Words a user might search for that the copy does not contain. */
  keywords?: string[]
}

export interface AboutInfo {
  name: string
  tagline: string
  version: string
  electron: string
  chrome: string
  node: string
  v8: string
  platform: string
  arch: string
  packaged: boolean
}

/** The slice of the preload bridge this panel needs. */
export interface HelpBridge {
  about(): Promise<AboutInfo>
}

export const SECTIONS: ReadonlyArray<{ id: HelpSectionId; label: string; hint: string }> = [
  { id: 'start', label: 'Getting started', hint: 'From nothing installed to a running session.' },
  { id: 'panels', label: 'The views', hint: 'What each surface in the app is for.' },
  { id: 'shortcuts', label: 'Shortcuts', hint: 'Every key the app answers to.' },
  { id: 'trouble', label: 'Troubleshooting', hint: 'The things that actually go wrong.' },
  { id: 'about', label: 'About', hint: 'Versions, and what to include in a bug report.' },
]

/* ---------------------------------------------------------------- content -- */

/** One line each, in the user's terms rather than the module's. */
export const PANEL_HELP: Record<PanelId, string> = {
  // No `copilot` line. The copilot is not a view any more — it is a window,
  // with a pill in the tab strip and the same toolbar every session has —
  // so it is written out by hand in `HELP_TOPICS` below rather than generated
  // from a panel entry that no longer exists, exactly like Alerts. `PANEL_HELP`
  // is keyed by `PanelId`, so leaving the line here would not compile, which is
  // the check working.
  overview: 'A dashboard for the open project: sessions, token usage, git state and readiness in one place. Widgets can be rearranged.',
  files: 'The project tree, with anything your ignore rules exclude hidden. Open a file to read it beside the session.',
  artifacts: 'Every file your agents wrote or changed here, with the diff of each change. Searching past transcripts moved to the command palette — type ? in it.',
  git: 'Working-tree status and diffs for the project, refreshed as the agent edits files.',
  github: 'Pull requests, issues and checks. Needs the GitHub CLI installed, signed in, and a GitHub remote on the repo.',
  readiness: 'How ready this repo is for an agent to work in — instructions, tests, structure — with a fix offered where one is safe.',
  // No `alerts` line. Alerts is not a view any more — it is a pop-up over
  // whatever you are doing, opened by the bell beside Settings — so it is
  // written out by hand in `HELP_TOPICS` below rather than generated from a
  // panel entry that no longer exists. `PANEL_HELP` is keyed by `PanelId`, so
  // leaving the line here would not compile, which is the check working.
  mcp: 'Connect to MCP servers, browse the tools, resources and prompts they expose, and call one by hand to see what it returns.',
  hooks: 'Installs callbacks into each agent CLI’s own settings file, so the app knows what the agent is doing without scraping the terminal.',
  remote: 'Pair a phone or another computer with this one, then drive these sessions from it. A code is six digits, lives a minute, and is used once — and the device still has to be approved here before it gets in.',
  // No `machines` line, because there is no Machines view: your other computers
  // live in Settings → Remote now, beside the phones that can reach this one.
  // `PANEL_HELP` is keyed by `PanelId`, so a line for a view that no longer
  // exists would not compile — which is the check working.
}

const GETTING_STARTED: HelpTopic[] = [
  {
    id: 'start-cli',
    section: 'start',
    title: 'Install an agent CLI',
    keywords: ['install', 'setup', 'claude code', 'codex', 'gemini', 'npm', 'homebrew'],
    blocks: [
      {
        kind: 'text',
        text: '{app} does not talk to any model API itself. It runs the agent CLI you already use — Claude Code, Codex or Gemini CLI — inside a real terminal, and puts a workspace around it. So the first step is having at least one of them installed and working in your own shell.',
      },
      {
        kind: 'text',
        text: 'Install whichever you want the way its own documentation says, then check it from a terminal:',
      },
      { kind: 'code', code: 'which claude && claude --version' },
      {
        kind: 'note',
        text: 'If that works in your terminal but the app still says the CLI is missing, that is a PATH problem, not an install problem — see “The app cannot find my agent CLI”.',
      },
    ],
  },
  {
    id: 'start-signin',
    section: 'start',
    title: 'Sign in to it',
    keywords: ['login', 'auth', 'authenticate', 'account', 'subscription', 'api key'],
    blocks: [
      {
        kind: 'text',
        text: 'Signing in happens inside the CLI, not in this app. Start a session and the CLI shows its own login flow in the terminal — the same one you would get in a terminal window, because it is the same program.',
      },
      {
        kind: 'text',
        text: '{app} deliberately does not test your credentials by starting a session behind your back: that would cost you money. It reports what it can see for free and lets the CLI ask.',
      },
    ],
  },
  {
    id: 'start-project',
    section: 'start',
    title: 'Open a project',
    keywords: ['folder', 'directory', 'repo', 'open'],
    blocks: [
      {
        kind: 'steps',
        items: [
          // A plain +, not U+FF0B: a fullwidth plus is the only fullwidth
          // character in this window and it sets twice as wide as the type
          // around it.
          'Press the + beside “Open” in the sidebar, or use the Open a project shortcut.',
          'Pick the root of the repo you want to work in — the folder the agent should treat as its working directory.',
          'It stays in the list, most recent first, until you remove it.',
        ],
      },
      {
        kind: 'note',
        text: 'Removing a project also kills its running sessions. That is intentional — a session with no row in the sidebar is a process you cannot stop.',
      },
    ],
  },
  {
    id: 'start-session',
    section: 'start',
    title: 'Start a session',
    keywords: ['new session', 'tab', 'terminal', 'resume', 'continue'],
    blocks: [
      {
        kind: 'text',
        text: 'A session is one agent process running in one project folder, listed under that project in the sidebar. Start one with the New session shortcut, or resume the most recent conversation in that folder with Resume the last session here.',
      },
      {
        kind: 'bullets',
        items: [
          'The dot beside a session is its state: working, waiting on you, or finished.',
          'Everything you type goes to the agent. The app only claims the shortcuts listed under Shortcuts — the rest reaches the terminal.',
          'Splitting a pane runs two sessions side by side in the same window.',
        ],
      },
    ],
  },
]

const TROUBLESHOOTING: HelpTopic[] = [
  {
    id: 'trouble-path',
    section: 'trouble',
    title: 'The app cannot find my agent CLI',
    keywords: ['path', 'not found', 'command not found', 'missing', 'which', 'nvm', 'homebrew', 'zshrc'],
    blocks: [
      {
        kind: 'text',
        text: 'This is the most common problem, and it is almost never a broken install. An app launched from the Dock or Finder inherits a minimal PATH from the OS — roughly `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`. It does not inherit the PATH your terminal has, because nothing ran your shell profile.',
      },
      {
        kind: 'text',
        text: 'Agent CLIs almost never live in that minimal set. Claude Code’s own installer puts it in `~/.local/bin`, Homebrew uses `/opt/homebrew/bin`, and an npm install through nvm puts it under `~/.nvm`. All three are invisible to a GUI app by default.',
      },
      {
        kind: 'text',
        text: '{app} works around this by asking your login shell for its real PATH once at startup and using that for every session it spawns. So the fix is to make sure your shell actually exports the directory when it starts:',
      },
      {
        kind: 'steps',
        items: [
          'In a terminal, run `which claude` (or codex, or gemini). If that fails too, it is genuinely not installed.',
          'If it succeeds, check the PATH export lives somewhere your login shell reads — `~/.zprofile` or `~/.zshrc` for zsh — and not somewhere only your terminal app sets up.',
          'Quit the app completely and reopen it. The PATH is read once per launch and cached.',
          'Still wrong? Open the Debug panel: it lists the PATH the app is actually using, entry by entry.',
        ],
      },
    ],
  },
  {
    id: 'trouble-signin',
    section: 'trouble',
    title: 'The CLI is installed but nothing happens when I start a session',
    keywords: ['not signed in', 'login', 'auth', 'credentials', 'unauthorised', 'unauthorized'],
    blocks: [
      {
        kind: 'text',
        text: 'An installed but unauthenticated CLI starts fine and then asks to log in — inside the terminal. If a session looks like it is doing nothing, read what is actually in it; the prompt is usually right there waiting for a keystroke.',
      },
      {
        kind: 'text',
        text: 'There is no reliable, free way to ask an agent CLI whether it is signed in, so the app only claims that state where it can check something cheap. For Claude Code that is the credentials file or the login keychain entry:',
      },
      { kind: 'code', code: 'ls -l ~/.claude/.credentials.json' },
      {
        kind: 'note',
        text: 'Signing in through the app is not possible and not planned — credentials belong to the CLI that owns them.',
      },
    ],
  },
  {
    id: 'trouble-gh',
    section: 'trouble',
    title: 'The GitHub panel is empty and I have gh installed',
    keywords: ['gh', 'github cli', 'auth', 'token', 'unauthenticated', 'pull requests'],
    blocks: [
      {
        kind: 'text',
        text: 'Installed is not the same as signed in. Every GitHub feature here shells out to `gh`, so if `gh` is not authenticated, each call fails and the panel has nothing to show.',
      },
      { kind: 'code', code: 'gh auth status\ngh auth login' },
      {
        kind: 'text',
        text: 'Sign in for the host the repo lives on — a GitHub Enterprise remote needs its own entry. Then refresh the panel; results are cached briefly, so the first refresh after signing in is the slow one.',
      },
    ],
  },
  {
    id: 'trouble-remote',
    section: 'trouble',
    title: 'The GitHub panel says there is no remote',
    keywords: ['remote', 'origin', 'not a repository', 'git init', 'clone'],
    blocks: [
      {
        kind: 'text',
        text: 'The panel needs a GitHub remote to have anything to talk about. A folder that was never cloned — `git init` and nothing else — has no remote at all, and a repo whose remote points somewhere other than GitHub has nothing for `gh` to query.',
      },
      { kind: 'code', code: 'git remote -v\ngit remote add origin git@github.com:owner/repo.git' },
      {
        kind: 'note',
        text: 'The Source control panel does not need a remote. Status, diffs and branches all work on a purely local repository.',
      },
    ],
  },
  {
    id: 'trouble-exit',
    section: 'trouble',
    title: 'A session opens and closes immediately',
    keywords: ['exits', 'crash', 'closed', 'exit code', 'dies', 'quits'],
    blocks: [
      {
        kind: 'text',
        text: 'The terminal shows the exit code when the process ends. In order of likelihood:',
      },
      {
        kind: 'bullets',
        items: [
          'The command is not there — the same PATH problem as above, which usually exits 127.',
          'The project folder has been moved, renamed or deleted since you added it. A process cannot start in a directory that does not exist.',
          'The CLI rejected its own config: a malformed settings file, a bad hook, or an MCP server it cannot start. Run the same command in a terminal in that folder and read what it prints.',
          'Your shell profile exits — for a shell session, anything that calls `exit` in `~/.zshrc` closes the session the instant it opens.',
        ],
      },
      {
        kind: 'text',
        text: 'Turn on Settings → Advanced → Debug mode: its process table shows every session and its exit code, and the log below it usually names the cause.',
      },
    ],
  },
  {
    id: 'trouble-keys',
    section: 'trouble',
    title: 'A shortcut does nothing while I am in a session',
    keywords: ['keyboard', 'shortcut', 'ctrl+c', 'escape', 'not working'],
    blocks: [
      {
        kind: 'text',
        text: 'That is deliberate. A terminal is a full keyboard application, so the app only takes chords the platform reserves for applications — Command on macOS, Ctrl with Shift or Alt elsewhere. Everything else, including Ctrl+C and Escape, belongs to the agent.',
      },
      {
        kind: 'text',
        text: 'The Shortcuts section marks anything the app never intercepts as “passes through”.',
      },
    ],
  },
]

export const HELP_TOPICS: HelpTopic[] = [
  ...GETTING_STARTED,
  {
    id: 'panels-overview',
    section: 'panels',
    title: 'Panels',
    keywords: ['sidebar', 'rail', 'panel'],
    blocks: [
      {
        kind: 'text',
        text: 'The sidebar down the left switches views. They all act on the project that is currently open, and the window shows one at a time.',
      },
    ],
  },
  /**
   * Shortcuts are not printed here. The sidebar's own tooltips read them out of
   * `keymap.ts` through `chordFor`, so they are already both real and correct
   * for the platform; the Shortcuts section lists the whole set. Printing a
   * third copy here is a third thing to keep true.
   */
  ...PANELS.map<HelpTopic>((panel) => ({
    id: `panel-${panel.id}`,
    section: 'panels',
    title: panel.label,
    keywords: [panel.id],
    blocks: [{ kind: 'text', text: PANEL_HELP[panel.id] }],
  })),
  /*
   * Alerts, written out rather than generated.
   *
   * It sits in this section because that is where somebody looking for it will
   * look — it is one of the app's surfaces, and the section is called "The
   * views" in the same loose sense that Settings is one. What it is not is a
   * `PanelId`, so there is no entry to generate it from, and a topic dropped
   * because the entry went would be the app quietly forgetting how to explain
   * one of its own features.
   */
  /*
   * The copilot, written out for the same reason and since the same day.
   *
   * It is a window rather than a view — it always was a real session, and on
   * 2026-08-17 it stopped pretending to be a page as well — so there is no
   * `PanelId` to generate this from. Somebody looking for it will look in "The
   * views" all the same, because to a reader it is one of the app's surfaces.
   */
  {
    id: 'panel-copilot',
    section: 'panels',
    title: 'Copilot',
    keywords: ['copilot', 'assistant', 'agent', 'routines'],
    blocks: [
      {
        kind: 'text',
        text: 'An assistant for this deck, pinned at the top of the sidebar. It is a real session — it opens as a window like any other, with a pill in the tab strip, its own account, and the same model, effort, fast-mode and connector controls in the bar. It runs in a folder of its own, with its own memory, as one of the accounts you have already signed in. Ask it which of your sessions needs you, to review a diff before it lands, or to turn a rough ask into a prompt worth giving a sub-session. Anything it does that changes your settings or touches a session you started asks you first.',
      },
    ],
  },
  {
    id: 'panel-alerts',
    section: 'panels',
    title: 'Alerts',
    keywords: ['alerts', 'notifications', 'bell', 'stalled', 'blocked'],
    blocks: [
      {
        kind: 'text',
        text: 'Things worth knowing without watching: a session filling its context window, a tool failing repeatedly, work that has stalled. The bell beside Settings at the bottom of the sidebar opens them in a panel over your work — a dot on the bell means there is something in there. Each alert carries the one thing to do about it, and pressing that closes the panel and takes you to it.',
      },
    ],
  },
  ...TROUBLESHOOTING,
]

/* ----------------------------------------------------------------- search -- */

function topicText(topic: HelpTopic): string {
  const blocks = topic.blocks
    .map((block) => {
      if (block.kind === 'steps' || block.kind === 'bullets') return block.items.join(' ')
      if (block.kind === 'code') return block.code
      return block.text
    })
    .join(' ')
  return `${topic.title} ${blocks} ${(topic.keywords ?? []).join(' ')}`.toLowerCase()
}

/**
 * Every term has to appear somewhere in the topic, in any order. Substring
 * rather than word matching, so "auth" finds "authenticated" — help is searched
 * with half-remembered words.
 */
export function searchHelp(query: string, topics: readonly HelpTopic[] = HELP_TOPICS): HelpTopic[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return [...topics]
  return topics.filter((topic) => {
    const haystack = topicText(topic)
    return terms.every((term) => haystack.includes(term))
  })
}

/**
 * What a search has to hit for the About card to count as a result.
 *
 * This used to be `'about version build'.includes(query)`, which is a substring
 * test against a fixed sentence and wrong in both directions: a single letter
 * ("a", "b", "u") matched it, while "electron", "chromium" and "node" — the
 * things actually printed on the card — did not.
 */
const ABOUT_KEYWORDS = [
  'about',
  'version',
  'build',
  'electron',
  'chromium',
  'chrome',
  'node',
  'v8',
  'platform',
  'arch',
  'release',
  'runtime',
  'bug',
  'report',
]

/**
 * Matched against whole words, by prefix. Prefixes because help is searched with
 * half-remembered words and "electr" should still find it; whole words because
 * a substring test over a joined sentence is what let a single letter through.
 * Anything under three characters has to be the keyword exactly, so `v8` works
 * and `a` does not.
 */
export function matchesAbout(query: string): boolean {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return false
  return terms.every((term) =>
    ABOUT_KEYWORDS.some((word) => word === term || (term.length >= 3 && word.startsWith(term))),
  )
}

/* --------------------------------------------------------------- bridging -- */

/**
 * Read the bridge defensively — the preload is wired separately, so the panel
 * has to degrade rather than crash if it mounts before `about` exists.
 */
export function resolveHelpBridge(): HelpBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: Record<string, unknown> }).deck
  if (!host || typeof host.about !== 'function') return null
  return host as unknown as HelpBridge
}

/* ---------------------------------------------------------------- render -- */

/**
 * Fill in the product name and render `backticked` spans as code.
 *
 * Without the second half the copy prints its own backticks, which reads as
 * markdown someone forgot to render — and the commands in the troubleshooting
 * steps are the part a stuck user is going to copy.
 */
export function fill(text: string, appName: string): ReactNode[] {
  return text
    .replaceAll('{app}', appName)
    .split(/`([^`]+)`/)
    .map((part, index) =>
      index % 2 === 1 ? (
        <code key={index} className="help-inline-code">
          {part}
        </code>
      ) : (
        part
      ),
    )
}

function Block({ block, appName }: { block: HelpBlock; appName: string }): ReactNode {
  switch (block.kind) {
    case 'text':
      return <p className="help-text">{fill(block.text, appName)}</p>
    case 'note':
      return <p className="help-note">{fill(block.text, appName)}</p>
    case 'code':
      return (
        <pre className="help-code">
          <code>{block.code}</code>
        </pre>
      )
    case 'steps':
      return (
        <ol className="help-steps">
          {block.items.map((item) => (
            <li key={item}>{fill(item, appName)}</li>
          ))}
        </ol>
      )
    case 'bullets':
      return (
        <ul className="help-bullets">
          {block.items.map((item) => (
            <li key={item}>{fill(item, appName)}</li>
          ))}
        </ul>
      )
  }
}

export function TopicView({ topic, appName }: { topic: HelpTopic; appName: string }) {
  return (
    <article className="help-topic" data-topic={topic.id}>
      <h3 className="help-topic-title">{topic.title}</h3>
      {topic.blocks.map((block, index) => (
        <Block key={`${topic.id}-${index}`} block={block} appName={appName} />
      ))}
    </article>
  )
}

/**
 * The shortcut table.
 *
 * Rows are built from `keymap.ts` — the same source the ⌘/ sheet uses — rather
 * than by embedding that component, which brings its own search field and
 * would leave two search boxes stacked on top of each other.
 */
export function ShortcutTable({ query, isMac }: { query: string; isMac: boolean }) {
  const groups = useMemo(() => groupedKeymap(searchKeymap(query, KEYMAP, isMac)), [query, isMac])

  if (groups.length === 0) {
    return <p className="help-empty">No shortcut matches that.</p>
  }

  return (
    <>
      {groups.map((group) => (
        <section key={group.scope} className="help-keys-group">
          <h4 className="help-keys-title">{group.title}</h4>
          <p className="help-keys-hint">{group.hint}</p>
          <ul className="help-keys">
            {group.bindings.map((binding) => (
              <li key={binding.id} className="help-key-row">
                <span className="help-key-label">
                  {binding.label}
                  {binding.passthrough && <span className="help-flag">passes through</span>}
                </span>
                <span className="help-key-chords">
                  {formatBinding(binding, isMac).map((chord, index) => (
                    <span key={chord}>
                      {index > 0 && <span className="help-or">or</span>}
                      <kbd>{chord}</kbd>
                    </span>
                  ))}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </>
  )
}

export function AboutCard({ info, onCopy }: { info: AboutInfo | null; onCopy?: () => void }) {
  if (!info) {
    return <p className="help-empty">Version information is not available in this window.</p>
  }

  const rows: Array<[string, string]> = [
    ['Version', `${info.version}${info.packaged ? '' : ' (development build)'}`],
    ['Electron', info.electron],
    ['Chromium', info.chrome],
    ['Node', info.node],
    ['V8', info.v8],
    ['Platform', `${info.platform} ${info.arch}`],
  ]

  return (
    <div className="help-about">
      <h3 className="help-about-name">{info.name}</h3>
      <p className="help-about-tagline">{info.tagline}</p>
      <dl className="help-about-rows">
        {rows.map(([label, value]) => (
          <div key={label} className="help-about-row">
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
      {onCopy && (
        <button type="button" className="help-copy" onClick={onCopy}>
          Copy version details
        </button>
      )}
      <p className="help-note">
        Filing a bug? The Debug panel builds a support bundle with all of this plus the recent log,
        with credentials and your home directory stripped out.
      </p>
    </div>
  )
}

/* ----------------------------------------------------------------- panel -- */

export interface HelpPanelProps {
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: HelpBridge | null
  isMac?: boolean
  initialSection?: HelpSectionId
  /**
   * Sections to leave out entirely — out of the sub-nav, out of the search.
   *
   * Settings passes `['shortcuts', 'about']`, because that window's own nav
   * already has a Shortcuts row and an About row, and Help sitting inside it
   * was offering a second way into both, two panels apart, listing the same
   * keymap and the same version numbers. The ⌘? dialog is not inside anything
   * and keeps all five.
   */
  hideSections?: readonly HelpSectionId[]
  /**
   * Seeds the search field. Mostly a test seam: the searching branch — the
   * result count, the empty state, About-as-a-result — is otherwise reachable
   * only by typing, so a static render can never exercise any of it.
   */
  initialQuery?: string
  /** Rendered as a link at the end of troubleshooting when provided. */
  onOpenDebug?: () => void
  /** Off in tests, where there is no real focus to take. */
  autoFocus?: boolean
}

export function HelpPanel({
  bridge,
  isMac = detectMac(),
  initialSection = 'start',
  initialQuery = '',
  onOpenDebug,
  autoFocus = true,
  hideSections = [],
}: HelpPanelProps) {
  const sections = useMemo(
    () => SECTIONS.filter((entry) => !hideSections.includes(entry.id)),
    // The array is a literal at every call site, so compare by contents rather
    // than by identity — otherwise this re-runs on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [hideSections.join(',')],
  )
  const [section, setSection] = useState<HelpSectionId>(initialSection)
  const [query, setQuery] = useState(initialQuery)
  const [about, setAbout] = useState<AboutInfo | null>(null)
  const [copied, setCopied] = useState(false)
  const searchRef = useRef<HTMLInputElement>(null)

  const resolved = useMemo(() => bridge ?? resolveHelpBridge(), [bridge])

  useEffect(() => {
    if (!autoFocus) return
    // Modal takes focus for its own panel first, so this has to land after it.
    const frame = requestAnimationFrame(() => searchRef.current?.focus())
    return () => cancelAnimationFrame(frame)
  }, [autoFocus])

  useEffect(() => {
    if (!resolved) return
    let live = true
    void resolved
      .about()
      .then((info) => {
        if (live) setAbout(info)
      })
      .catch(() => {
        // Version details are a nicety; the rest of the help still works.
      })
    return () => {
      live = false
    }
  }, [resolved])

  const searching = query.trim().length > 0
  const shown = useMemo(
    () => HELP_TOPICS.filter((topic) => sections.some((entry) => entry.id === topic.section)),
    [sections],
  )
  const matches = useMemo(() => searchHelp(query, shown), [query, shown])
  const hasShortcuts = sections.some((entry) => entry.id === 'shortcuts')
  const hasAbout = sections.some((entry) => entry.id === 'about')
  const shortcutMatches = useMemo(
    () => (searching ? searchKeymap(query, KEYMAP, isMac).length : KEYMAP.length),
    [query, searching, isMac],
  )
  const appName = about?.name ?? 'This app'

  // A hidden `initialSection` would otherwise leave the panel showing nothing
  // at all, with no row in the nav to click back out of it.
  const current = sections.some((entry) => entry.id === section) ? section : (sections[0]?.id ?? 'start')
  const visible = searching ? matches : matches.filter((topic) => topic.section === current)
  // A hidden section is hidden from the search too. Half-hiding it — no row in
  // the nav, but its whole shortcut table arriving as a search result — is the
  // duplication back again, just harder to predict.
  const showShortcuts = hasShortcuts && (searching ? shortcutMatches > 0 : current === 'shortcuts')
  const showAbout = hasAbout && (searching ? matchesAbout(query) : current === 'about')
  const nothing = visible.length === 0 && !showShortcuts && !showAbout
  // The About card is a result too — leaving it out meant a search that found
  // only the version details reported "0 results" above the version details.
  const resultCount = visible.length + (showShortcuts ? shortcutMatches : 0) + (showAbout ? 1 : 0)

  const copyAbout = (): void => {
    if (!about) return
    const text = [
      `${about.name} ${about.version}${about.packaged ? '' : ' (dev)'}`,
      `Electron ${about.electron} · Chromium ${about.chrome} · Node ${about.node}`,
      `${about.platform} ${about.arch}`,
    ].join('\n')
    void navigator.clipboard?.writeText(text).then(
      () => setCopied(true),
      () => setCopied(false),
    )
  }

  // A confirmation that never goes away stops being a confirmation: the second
  // copy showed the "Copied." from the first and said nothing about itself.
  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  return (
    <div className="help">
      <div className="help-search">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <circle cx="11" cy="11" r="7" strokeWidth="2" />
          <path d="M16.5 16.5L21 21" strokeWidth="2" strokeLinecap="round" />
        </svg>
        <input
          ref={searchRef}
          type="search"
          className="help-input"
          value={query}
          placeholder={hasShortcuts ? 'Search help and shortcuts' : 'Search help'}
          aria-label="Search help"
          onChange={(event) => setQuery(event.target.value)}
        />
        {searching && (
          <span className="help-count" role="status" aria-live="polite">
            {resultCount} {resultCount === 1 ? 'result' : 'results'}
          </span>
        )}
      </div>

      <div className="help-body">
        {!searching && sections.length > 1 && (
          <nav className="help-nav" aria-label="Help sections">
            {sections.map((entry) => (
              <button
                key={entry.id}
                type="button"
                className="help-nav-item"
                data-active={entry.id === current || undefined}
                aria-current={entry.id === current ? 'true' : undefined}
                onClick={() => setSection(entry.id)}
              >
                {entry.label}
              </button>
            ))}
          </nav>
        )}

        <div className="help-content">
          {!searching && (
            <p className="help-section-hint">{sections.find((s) => s.id === current)?.hint}</p>
          )}

          {nothing && <p className="help-empty">Nothing in the help matches “{query.trim()}”.</p>}

          {visible.map((topic) => (
            <TopicView key={topic.id} topic={topic} appName={appName} />
          ))}

          {!searching && current === 'trouble' && onOpenDebug && (
            <button type="button" className="help-link" onClick={onOpenDebug}>
              Open the Debug panel
            </button>
          )}

          {showShortcuts && (
            <div className="help-topic">
              {searching && <h3 className="help-topic-title">Shortcuts</h3>}
              <ShortcutTable query={searching ? query : ''} isMac={isMac} />
            </div>
          )}

          {showAbout && (
            <>
              <AboutCard info={about} onCopy={about ? copyAbout : undefined} />
              {copied && (
                <p className="help-note" role="status">
                  Copied.
                </p>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  )
}

export interface HelpDialogProps extends HelpPanelProps {
  open: boolean
  onClose(): void
}

export function HelpDialog({ open, onClose, ...panel }: HelpDialogProps) {
  return (
    <Modal open={open} title="Help" description="How this works, and what to do when it does not." onClose={onClose} size="lg">
      <HelpPanel {...panel} />
    </Modal>
  )
}
