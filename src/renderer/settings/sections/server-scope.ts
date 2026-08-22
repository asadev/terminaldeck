/**
 * Everything this window can be told about **this** machine, and what a server
 * does about each one.
 *
 * ## Why this is a table and not a paragraph in a component
 *
 * Because the instruction it answers is an exact one — *"build proper settings
 * inside too exactly like local machine, exactly means exactly and all other
 * applicaple places too"* — and "exactly" is a claim that has to be checkable.
 * A pane that draws five of the fifteen controls this window offers has failed
 * the instruction; a pane that draws all fifteen and leaves two of them inert
 * has failed it worse, because an inert control costs a click to discover.
 *
 * So the comparison is written down once, in code, with three properties that a
 * comment could not have:
 *
 *  - **It is complete against the schema.** Every setting `settings-schema.ts`
 *    declares is named by exactly one row here, and `server-scope.test.ts`
 *    fails if one is added and not answered for. Somebody adding a settings row
 *    is thereby asked what it means for a server, at the moment they add it,
 *    which is the only moment anybody knows.
 *  - **Every "cannot" is traced.** A row that says a server cannot carry
 *    something names the file that decides it and a string that must still be
 *    in that file. When the decision changes, the test goes red and the sentence
 *    on screen gets revisited instead of quietly becoming a lie.
 *  - **The pane reads it.** The sentences the Servers pane prints in place of
 *    the controls it does not draw are checked against these rows rather than
 *    typed twice.
 *
 * ## The four answers, and why there are four rather than two
 *
 * *Carried* and *cannot* are the obvious two. The other two are the ones a
 * yes/no table would have got wrong:
 *
 *  - **`app-wide`** — the setting is not a property of a machine at all. The
 *    theme is the theme; it does not become a different theme because a session
 *    is on somebody's server. Filing these as "cannot" would put a dozen
 *    apologies on a pane for things nobody was looking for.
 *  - **`instead`** — this machine's control cannot cross, *and* a server holds a
 *    different live control answering the same question. A server has no lid to
 *    keep open; what it has is whether our host is installed on it and survives
 *    a restart. Saying only "cannot" there would hide a real control one door
 *    away.
 */

/** What a server does about one of this window's controls. */
export type ServerVerdict =
  /** A server carries it, and this app applies it there. */
  | 'carried'
  /** It cannot cross, and the pane says so and draws nothing. */
  | 'cannot'
  /** Not a machine's setting at all — it belongs to this app. */
  | 'app-wide'
  /** It cannot cross, and a different live control answers the same question. */
  | 'instead'

/**
 * Which group of the Servers pane answers this row, when one does.
 *
 * The pane prints a row's sentence where somebody would go looking for the
 * control it stands in for — the account answers beside the accounts, the lid
 * answer beside the host — and nowhere else. A row with no group is one this
 * table records and the pane deliberately does not print; that decision has to
 * be defended in {@link ServerControlEntry.quiet}, because "we left it off the
 * screen" is exactly the kind of judgement that goes unexamined.
 */
export type ServerGroup = 'sessions' | 'coding' | 'browser' | 'copilot' | 'power'

/**
 * The file that decides a row, and a string that must still be in it.
 *
 * Not a line number: lines move on every edit above them and a number that is
 * wrong is worse than no number, because it looks precise. A string the file
 * must contain is a claim that stays true while the decision does, and fails
 * the day somebody changes it.
 */
export interface ServerTrace {
  /** Repo-relative, from the repository root. */
  file: string
  says: string
}

export interface ServerControlEntry {
  /** The control, as this window names it for this machine. */
  local: string
  /**
   * The settings this row answers for, by their schema ids.
   *
   * Empty for the controls that are not declared settings — the account list,
   * the installs, the copilot pane, the keep-awake switch — which are most of
   * what this window actually offers. The ids are here so the completeness
   * check has something exact to run against, not because ids are the subject.
   */
  mirrors: readonly string[]
  verdict: ServerVerdict
  /** One plain sentence. For a `cannot`, it names the reason. */
  say: string
  /** Required for `cannot` and `instead`; the reason has to be traceable. */
  traced?: ServerTrace
  /**
   * Where the Servers pane prints {@link ServerControlEntry.say}.
   *
   * Every row a server cannot carry has one, unless {@link quiet} says why not.
   * `carried` rows have none: what says a control is carried is the control.
   */
  group?: ServerGroup
  /**
   * Why a row a server cannot carry is nevertheless not on the pane.
   *
   * Only for the ones nobody goes looking for on a screen about a server. A
   * sentence about a microphone, printed beside a machine in a rack, is noise
   * charged to every reader in order to complete a table two people will read.
   */
  quiet?: string
}

export const SERVER_CONTROLS: readonly ServerControlEntry[] = [
  /* ------------------------------------------------ how sessions behave -- */
  {
    local: 'Bring sessions back when the app starts',
    mirrors: ['general.restoreSessions'],
    verdict: 'cannot',
    say: 'A server’s terminals are not brought back: nothing at the far end is holding one, so there is nothing left to restore.',
    traced: {
      file: 'src/renderer/machines/servers/server-sessions.ts',
      says: 'Nothing survives a relaunch',
    },
    group: 'sessions',
  },
  {
    local: 'Name sessions from the conversation',
    mirrors: ['general.autoNameSessions'],
    verdict: 'cannot',
    say: 'A server terminal’s output arrives on a channel of its own, which the naming never reads, so its tab keeps the server’s name.',
    traced: {
      file: 'src/renderer/machines/servers/types.ts',
      says: "`servers:shell:output`",
    },
    group: 'sessions',
  },
  {
    local: 'Ask before closing a working session',
    mirrors: ['general.confirmCloseWorking'],
    verdict: 'carried',
    say: 'Closing a terminal on a server asks first, exactly as closing one here does.',
  },
  {
    local: 'Copy on select',
    mirrors: ['general.copyOnSelect'],
    verdict: 'carried',
    say: 'Selecting text in a terminal on a server copies it, the same as everywhere else in this window.',
    traced: {
      file: 'src/renderer/machines/servers/ServerSessionPane.tsx',
      says: 'copyOnSelect={copyOnSelect}',
    },
  },

  /* ------------------------------------------------------- how it looks -- */
  {
    local: 'Theme and density',
    mirrors: ['appearance.theme', 'appearance.density'],
    verdict: 'app-wide',
    say: 'The window looks the way you set it, wherever a session happens to be running.',
  },
  {
    local: 'Terminal type',
    mirrors: ['appearance.terminalFontSize', 'appearance.terminalFontFamily'],
    verdict: 'carried',
    say: 'A terminal on a server takes the size and typeface you chose here.',
    traced: {
      file: 'src/renderer/machines/servers/ServerSessionPane.tsx',
      says: 'fontFamily={fontFamily}',
    },
  },

  /* ----------------------------------------------------- what it tells you -- */
  {
    local: 'What the app tells you, and how',
    mirrors: [
      'notifications.onNeedsInput',
      'notifications.onComplete',
      'notifications.showInsightAlerts',
      'notifications.onFinishSound',
      'notifications.soundName',
      'notifications.onlyWhenUnfocused',
    ],
    verdict: 'cannot',
    say: 'Nothing here classifies what a terminal on a server is doing, so one is never reported as needing you or as having finished.',
    traced: {
      file: 'src/renderer/machines/servers/server-sessions.ts',
      says: "status: 'idle'",
    },
    group: 'sessions',
  },

  /* --------------------------------------------- what runs your sessions -- */
  {
    local: 'Default coding tool',
    mirrors: ['agents.defaultProvider'],
    verdict: 'cannot',
    say: 'A session here opens the account’s own shell and the agent is typed into it, so there is nothing for this to choose.',
    traced: {
      file: 'src/renderer/machines/servers/types.ts',
      says: 'openServerShell(id: string, cols: number, rows: number, startIn?: string)',
    },
    group: 'coding',
  },
  {
    local: 'Primary account',
    mirrors: [],
    verdict: 'cannot',
    /*
     * Read it aloud before changing it. This line has been wrong twice: it
     * shipped as *“hands a shell on a server no account”*, was repaired on
     * 2026-08-22 to *“no account of its own”* — and the repair fixed the
     * missing words without fixing the sentence, which still had a shell being
     * handed *an account*. Rendered on the pane the same day, it printed:
     * “This app hands a shell on a server no account of its own, so…”
     *
     * The fact underneath is one clause long — nothing of ours has a login on
     * that machine — so it is now said in one clause instead of hung off a
     * verb that cannot carry it.
     */
    say: 'This app keeps no account of its own on a server, so a session runs as whichever login that server’s own home already holds.',
    traced: { file: 'src/main/profiles.ts', says: 'export function supportsProfiles' },
    group: 'coding',
  },
  {
    local: 'The logins this machine holds',
    mirrors: [],
    verdict: 'carried',
    say: 'Every agent the server was asked about, in the same three runs the list here uses.',
  },
  {
    local: 'Sign an account in',
    mirrors: [],
    verdict: 'carried',
    say: 'The agent’s own sign-in, in a terminal on that server, which is what signing in is at this desk too.',
  },
  {
    local: 'Sign an account out',
    mirrors: [],
    verdict: 'cannot',
    say: 'Nothing signs an agent out on any machine, this one included: no agent ships a command for it.',
    traced: { file: 'src/shared/agent-catalog.ts', says: 'signInArgs' },
    group: 'coding',
  },
  {
    local: 'Add another account of an agent',
    mirrors: [],
    verdict: 'cannot',
    say: 'A second account is a configuration folder handed to a process this app starts, and it starts no process on a server.',
    traced: { file: 'src/main/provider-accounts.ts', says: 'export function supportsAccounts' },
    group: 'coding',
  },
  {
    local: 'Install a coding tool',
    mirrors: [],
    verdict: 'carried',
    say: 'Installed from the pane, into that account’s own home, with a way back for whatever this app put there.',
  },
  {
    local: 'The folder a session starts in',
    mirrors: [],
    verdict: 'carried',
    say: 'One folder per server, remembered here, and every session on it starts there.',
  },

  /* ------------------------------------------------------------- tools -- */
  {
    local: 'Voice dictation',
    mirrors: [],
    verdict: 'cannot',
    say: 'Dictation records from the microphone attached to this computer, and a server has none of yours.',
    traced: { file: 'src/renderer/chat/voice/DictateButton.tsx', says: 'getUserMedia' },
    quiet: 'Nobody opens a pane about a server looking for a microphone setting.',
  },
  {
    local: 'Which Linux a session runs inside',
    mirrors: [],
    verdict: 'cannot',
    say: 'That question is about running Linux on Windows. A server runs its own system, and this pane reports which one it found.',
    traced: {
      file: 'src/renderer/settings/sections/LinuxSection.tsx',
      says: 'A session opens where its folder is',
    },
    quiet: 'The Linux pane is Windows-only, and this row exists to answer somebody who read it.',
  },

  /* ----------------------------------------------------------- browser -- */
  {
    local: 'The built-in browser',
    mirrors: ['browser.startUrl', 'browser.persistSession'],
    verdict: 'instead',
    say: 'The browser is a tab in this window rather than anything a server has. What a server holds is whether its terminals may act on the windows you attach.',
    traced: { file: 'src/main/servers/store.ts', says: 'drivesWindows' },
    group: 'browser',
  },

  /* ----------------------------------------------------------- copilot -- */
  {
    local: 'The copilot: its files, memory and log',
    mirrors: [],
    verdict: 'instead',
    say: 'A server never runs a copilot, even with our host installed on it. What it holds is whether this computer’s copilot may act on it, an hour at a time.',
    traced: { file: 'src/headless/host.ts', says: 'NO_COPILOT_HERE' },
    group: 'copilot',
  },

  /* ------------------------------------------------------------- power -- */
  {
    local: 'Keep running with the lid closed',
    mirrors: [],
    verdict: 'instead',
    say: 'A server has no lid, and this app is not running on it. What it holds is whether our host is there and whether that survives a restart.',
    traced: { file: 'src/main/servers/host.ts', says: 'export function reachLine' },
    group: 'power',
  },

  /* ---------------------------------------------------------- advanced -- */
  {
    local: 'Debug mode',
    mirrors: ['advanced.debugMode'],
    verdict: 'app-wide',
    say: 'It turns on this app’s own logging, which is written here whatever a session is running on.',
  },
  {
    local: 'Start over',
    mirrors: [],
    verdict: 'instead',
    say: 'Forgetting a server is the way back for one: it removes this app’s record and the sign-in kept here, and changes nothing on the server.',
    traced: { file: 'src/main/servers/ipc.ts', says: "'servers:forget'" },
    quiet: 'The Forget control is drawn on the pane and says what it removes, which is this sentence with a button on it.',
  },
] as const

/** The rows a pane has to say something about, because a person will look. */
export function controlsWith(verdict: ServerVerdict): ServerControlEntry[] {
  return SERVER_CONTROLS.filter((entry) => entry.verdict === verdict)
}

/**
 * The rows one group of the Servers pane prints, in the order they are declared.
 *
 * Order is the table's, not the pane's, so the sentence a reader meets first is
 * the one about the control that is highest on the pane it is missing from.
 */
export function controlsIn(group: ServerGroup): ServerControlEntry[] {
  return SERVER_CONTROLS.filter((entry) => entry.group === group)
}
