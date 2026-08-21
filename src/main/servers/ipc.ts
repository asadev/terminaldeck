/**
 * The server room, assembled and wired to the window.
 *
 * This is the only thing the renderer calls (§8.2's B→C seam). It owns four
 * things and delegates everything else:
 *
 *  - **the room** — the cached view of each server, built from A's facts and
 *    `classify.ts`'s inventory, with `actions.ts` deciding what each card may
 *    do;
 *  - **the way back on disk** — the record a `kept` action writes before it
 *    changes anything, kept on *this* computer because a record on the server
 *    is gone in exactly the situation it exists for;
 *  - **the terminal** — one interactive shell per server page, opened on
 *    request and closed with the page;
 *  - **the grant** — the copilot's per-server permission, which is asked for
 *    here and nowhere else.
 *
 * ## When it connects, and when it does not
 *
 * §5.4, which is where Asad's standing **events, not polling** rule is actually
 * paid. Opening a server's page opens one connection; closing it closes the
 * connection. There is no background connection, no timer, no keep-alive sweep,
 * and no connection at all to a server nobody is looking at. Facts are gathered
 * **once per connection** and cached with `measuredAt`, and a page showing an
 * hour-old sentence with its age on screen is the correct behaviour rather than
 * a bug to fix.
 *
 * The one long-lived thing is the terminal, and only while it is on screen. A
 * pty is inherently a stream; that is not polling.
 *
 * ## Why the transport arrives as a dependency
 *
 * `connection.ts` is agent A's file and this is agent B's. Taking `run`,
 * `shell` and `download` as arguments rather than importing them does three
 * things at once: the two halves can be built in parallel against a written
 * seam, the permission and way-back logic is exercisable with a plain object
 * and no `ssh2` anywhere near it — the same argument `deck-control/surface.ts`
 * makes at length — and the headless host, which has no window, can register
 * the identical handlers against its own desk. `remote/machines/ipc.ts` is the
 * precedent and takes its pairing desk the same way.
 *
 * ## Errors do not cross as exceptions
 *
 * Every handler that can fail answers a discriminated result rather than
 * rejecting. A rejected `ipcMain.handle` reaches the renderer as
 * `Error: Error invoking remote method '…': …`, which mangles the one thing
 * this feature must deliver intact: the sentence `actions.ts` wrote. §4.3 has
 * three surfaces rendering one string, and a transport that rewrites it would
 * break that quietly.
 */

import { mkdirSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import { randomUUID } from 'node:crypto'
import type { InvokeRegistrar } from '../ipc-seam'
import { writeSecretFile } from '../remote/secret-file'
import {
  ACTION_IDS,
  ActionFailed,
  ActionRefused,
  DEFAULT_LOG_LINES,
  MAX_LOG_LINES,
  availableActions,
  perform,
  previewOf,
  type ActionDeps,
  type CommandResult,
  type ActionId,
  type ActionOutcome,
  type ActionPreview,
  type AbsentAction,
  type DownloadFromServer,
  type ListServerFolder,
  type PutFileOnServer,
  type OpenServerShell,
  type RunOnServer,
  type ServerRoom,
  type ServerShell,
  type ServerSummary,
  type ServerView,
  type WayBack,
  type WayBackJournal,
} from './actions'
import {
  cannotOf,
  classify,
  emptySurvey,
  howOf,
  parseSurvey,
  waybackScript,
  type ServerCard,
  type WayBackSurvey,
} from './classify'
import { ServerProblem } from './connection'
import { KeyFileOffers, type KeyFileOffer } from './keyfiles'
import type { AgentFact, AgentId, AgentInstallRoom, ServerFacts } from './facts'
import type { ForwardingConnection } from './forward'
/*
 * The one narrow exception to §7's "installing software" non-goal, which §7
 * itself now names: one program, into the account's own home, no administrator
 * access, with a way back, driven by a person pressing a button. It is wired
 * here and it is deliberately **not** wired into `tools.ts` — §6.1, and
 * `no-run-tool.test.ts` pins the copilot's tool list at three names.
 */
import {
  ServerSetups,
  SETUP_AGENTS,
  agentOn,
  agentSetup,
  installConsequence,
  whyNotInstall,
  type SetupState,
} from './setup'
import { NO_SECURE_STORE, credentialFromDraft, type ServerCredential, type SignInDraft } from './credentials'
import { DEFAULT_GRANT_MS, MAX_GRANT_MS, GrantRefused, ServerGrants, type GrantState } from './grants'
/*
 * The same two functions the window's own bar drives, pointed at a shell on a
 * server. See {@link SHELL_CONTROLS} below for why that is honest rather than a
 * hopeful reuse, and `ControlScope` for the one thing that has to change.
 */
import { applyControl, readControls, type ApplyResult, type ControlsReading } from '../agent-controls'
// The shadow terminal every local session already keeps. A server shell is a
// real pty — `client.shell({ term: 'xterm-256color' })` — so the same emulator
// reads it, which is the whole of what makes the controls reach one.
import { ActivityTracker } from '../session-activity'
// One list of control names for the whole main process. Imported rather than
// restated because this handler narrows an IPC argument against it and a second
// copy is a second thing to forget when a control is added.
import { CONTROL_IDS, MAX_UPLOAD_BYTES } from '../remote/protocol'
import { byteSize } from '../../shared/byte-size'

/* ------------------------------------------------------------- channels -- */

export const SERVERS_SHELL_OUTPUT_CHANNEL = 'servers:shell:output'
export const SERVERS_SHELL_CLOSED_CHANNEL = 'servers:shell:closed'
/** Where a server's setup has got to. Pushed, because it changes without a press. */
export const SERVERS_SETUP_CHANNEL = 'servers:setup:changed'

/**
 * One agent's row in the setup pane: what is there, and what could be.
 *
 * Three of these go to the renderer on every look, in a fixed order, whether or
 * not the server has any of them. That is the shape of the rule rather than an
 * implementation detail — a pane that returned only the agents already
 * installed would show a Claude-only machine a Claude-only screen, which is the
 * thing being fixed.
 */
export interface SetupRow {
  agentId: AgentId
  /** The agent's own name, from the table beside the work. */
  label: string
  installed: AgentFact | null
  canInstall: boolean
  why: string | null
  consequence: string
  state: SetupState
}

/** Whether an unknown off the wire names one of the three rows. */
function isSetupAgent(value: unknown): value is AgentId {
  return typeof value === 'string' && (SETUP_AGENTS as readonly string[]).includes(value)
}

/* --------------------------------------------------------------- results -- */

/**
 * What every fallible handler answers.
 *
 * `sentence` is the person's answer and `detail` is the server's own words,
 * kept apart for the reason `ActionFailed` keeps them apart: one goes on a card
 * and the other goes behind a disclosure.
 */
export type ServerResult<T> =
  | ({ ok: true } & T)
  | {
      ok: false
      sentence: string
      detail: string
      /** A's own {@link ServerProblem} kind, when the failure was the connection. */
      kind?: string
      /** Both fingerprints, when the server answered with a different identity. */
      identity?: { expected: string; offered: string }
    }

function failed(error: unknown): Extract<ServerResult<never>, { ok: false }> {
  if (error instanceof ActionRefused) return { ok: false, sentence: error.sentence, detail: '' }
  if (error instanceof ActionFailed) return { ok: false, sentence: error.sentence, detail: error.detail }
  /*
   * Anything else is the transport: a host key that changed, an address that
   * did not answer, a sign-in refused. `connection.ts` maps those to the
   * sentences in §4.5 and throws them; what arrives here is already a sentence,
   * and re-wording it would be this layer inventing copy about a failure it did
   * not diagnose.
   *
   * `kind` and `identity` are carried through rather than flattened, and the
   * reason is one specific failure. A host key that changed is not a failure to
   * try again — §3.6: *"the connection stops and nothing is offered but the
   * fingerprint and a way to cancel."* The window can only draw that if it can
   * tell this failure from the eight that merely need another go, and the two
   * fingerprints are the whole of what makes the check worth having: a person
   * can go and compare them against any other tool.
   */
  if (error instanceof ServerProblem) {
    return {
      ok: false,
      sentence: error.sentence,
      detail: '',
      kind: error.kind,
      ...(error.identity === undefined ? {} : { identity: error.identity }),
    }
  }
  const message = error instanceof Error ? error.message : String(error)
  return { ok: false, sentence: message === '' ? 'Something went wrong reaching that server.' : message, detail: '' }
}

/* ---------------------------------------------------------- the journal -- */

const WAYBACK_FILE = 'server-waybacks.json'
const FORMAT_VERSION = 1

/**
 * The ways back, on this computer, written atomically.
 *
 * Through `writeSecretFile` for the same reason `folder-grants.ts` uses it for
 * a list of folder paths: not because the contents are a secret — an image
 * digest and a commit hash are not — but because the two properties that
 * function exists for are exactly the ones wanted here. **All-or-nothing
 * replacement**, so a crash mid-write cannot leave a half-written record that
 * parses into a rollback pointing at nothing. And **never following a symlink
 * into somewhere else**, so the file cannot be aimed at another program's state.
 *
 * A second hand-rolled atomic write is how two writers eventually disagree
 * about which steps mattered, and this one is the record that has to survive
 * the failure it is a record of.
 */
export class FileJournal implements WayBackJournal {
  private rows: Record<string, WayBack> = {}
  readonly file: string

  constructor(private readonly dir: string) {
    this.file = join(dir, WAYBACK_FILE)
    try {
      const raw: unknown = JSON.parse(readFileSync(this.file, 'utf8'))
      if (typeof raw === 'object' && raw !== null) {
        const stored = (raw as { rows?: unknown }).rows
        if (typeof stored === 'object' && stored !== null && !Array.isArray(stored)) {
          this.rows = stored as Record<string, WayBack>
        }
      }
    } catch {
      // No file, an unreadable one, or one written by something else. An
      // unreadable journal means no rollback is offered, which is the safe
      // direction: the button is absent rather than pointing at a record we
      // could not parse.
      this.rows = {}
    }
  }

  private key(serverId: string, cardId: string): string {
    return `${serverId} ${cardId}`
  }

  async put(serverId: string, cardId: string, record: WayBack): Promise<void> {
    this.rows[this.key(serverId, cardId)] = record
    this.flush()
  }

  async get(serverId: string, cardId: string): Promise<WayBack | null> {
    return this.rows[this.key(serverId, cardId)] ?? null
  }

  async clear(serverId: string, cardId: string): Promise<void> {
    delete this.rows[this.key(serverId, cardId)]
    this.flush()
  }

  private flush(): void {
    mkdirSync(this.dir, { recursive: true })
    /*
     * The **whole path**, not the basename. `writeSecretFile` builds its temp
     * file as `${file}.${pid}.tmp` and renames that to `file`, so a bare name
     * is resolved against the process's working directory — which for a
     * packaged app is wherever it happened to be launched from.
     *
     * This was written wrong first, and the way it failed is worth recording
     * because it is silent in both directions: the write succeeded, the
     * in-memory copy answered every read, and every test that used the
     * in-memory journal passed. The file simply landed somewhere else, so the
     * *next launch* would read an empty journal from `<userData>/servers/` and
     * offer no way back for anything updated before it. `ipc.test.ts` catches
     * it by reading the file off disk rather than asking the object.
     */
    writeSecretFile(this.dir, this.file, `${JSON.stringify({ version: FORMAT_VERSION, rows: this.rows }, null, 2)}\n`)
  }
}

/* ------------------------------------------------------------------ deps -- */

export interface ServersIpcDeps {
  /** Where `server-waybacks.json` and the backup folder live. `<userData>/servers`. */
  storageDir: string
  /** The list of servers. A's `store.ts`; never a credential — §3.7. */
  servers(): ServerSummary[]
  /**
   * The stored list itself, for adding, renaming and forgetting.
   *
   * Optional, because a host that is only *reading* servers — the headless
   * build, a test — has no business being able to change the list, and an
   * absent store answers "this build cannot add a server" honestly rather than
   * throwing inside a handler.
   */
  store?: ServerListStore
  /** Where a sign-in is kept. A's `credentials.ts`, backed by the OS secure store. */
  credentials?: ServerCredentialStore
  /** A's `connection.ts`: connect if needed, run the §3.2 probe once, answer the record. */
  facts(serverId: string): Promise<ServerFacts>
  /** A's `connection.ts`. */
  run: RunOnServer
  /** A's `connection.ts`. One script, one round trip — how the survey is asked. */
  runScript(serverId: string, script: string): Promise<CommandResult>
  /** A's `connection.ts`. Absent means no terminal — the page says so rather than drawing one. */
  openShell?: OpenServerShell
  /**
   * A's `connection.ts`, over SFTP. Absent means the folder picker offers no
   * list and the person types the path — which is a smaller picker, not a
   * broken one, and is the same fallback a server with no SFTP subsystem gets.
   */
  listFolder?: ListServerFolder
  /**
   * Put a file from this computer onto the server, over the same SFTP channel.
   *
   * Optional like `listFolder`, and its absence is answered the same way: a
   * sentence, so the surface that wanted to hand a session a file says it cannot
   * rather than handing over a path on the wrong computer. That is not a
   * hypothetical — a path on this laptop typed at a prompt on somebody's server
   * is a file the agent goes looking for, does not find, and reports missing to
   * a person who is looking straight at it on their own screen.
   */
  putFile?: PutFileOnServer
  /**
   * Copy a file off the server. **Absent today**, and its absence is a stated
   * fact rather than a gap: `connection.ts` exposes `run`, `runScript`, `probe`
   * and `shell`, and no file transfer. Until it does, every Backup button is
   * absent with the reason written on the card, and a database container gets
   * no Update button either — §4.1, an update whose way back does not lead all
   * the way back is not a `kept` action.
   */
  download?: DownloadFromServer
  /**
   * Hold the connection open while a page is looking at this server, and let go
   * when it closes. §5.4.
   *
   * A's pool reference-counts, so these must be paired. Optional because a host
   * without a pool — a test, the headless build — is not a reason to refuse to
   * register.
   */
  acquire?(serverId: string): Promise<void>
  release?(serverId: string): void
  /**
   * Borrow the live connection, for the one thing that needs the connection
   * itself rather than a command on it: carrying a sign-in's redirect back down
   * to the server's own listener. `reach.ts` takes the identical seam.
   *
   * Absent means the seamless sign-in is not available and the person is offered
   * the address to open themselves — which is one paste more, and is said on
   * screen rather than degraded to silently.
   */
  withConnection?<T>(
    serverId: string,
    fn: (client: ForwardingConnection) => Promise<T>,
  ): Promise<T>
  /**
   * Open a web address in the person's own browser.
   *
   * Their browser and not this app's, deliberately. The app's bound browser
   * records every navigation as `BoundWindow.url`, and the navigation that
   * finishes a sign-in *is* the authorization code — so routing it through there
   * would put a one-time code in an in-memory field and a history, which
   * `ACCOUNT-MODEL.md` does not have a "briefly" exception for.
   */
  openInBrowser?(url: string): Promise<void>
  /** Pushes a channel to every window. */
  broadcast(channel: string, payload: unknown): void
  /**
   * Where this computer keeps its SSH keys. `~/.ssh` unless a host says
   * otherwise, and a test says otherwise.
   */
  keyFolder?: string
  /**
   * Open a native panel for a key file, or null when the person closed it.
   *
   * Injected for the reason `copilot-folder.ts` splits the same way: a panel
   * needs a window to be a sheet on, windows live in `index.ts`, and a module
   * that reached for one could not be tested at all. Absent means the app
   * offers the keys it found and the paste box, and no panel — which is a
   * smaller screen, not a broken one.
   */
  pickKeyFile?(): Promise<string | null>
  now?: () => number
}

/**
 * The slice of A's `ServerStore` this file uses.
 *
 * Named narrowly rather than importing the class so that the registration can
 * be exercised against a plain object — the same reason `ipc-seam.ts` exists,
 * and the same reason A's own connection pool takes its store as a constructor
 * argument.
 */
export interface ServerListStore {
  add(candidate: { name: string; address: string; port?: number; username: string }): { id: string }
  /**
   * Record *which kind* of sign-in this server has, never the sign-in.
   *
   * The list is where the window reads it from, and without this call it stays
   * at its default of `none` for the life of the server — so the sign-in
   * section says "this build did not say" about a password the person typed one
   * screen earlier.
   */
  setCredentialKind(id: string, credential: 'password' | 'key' | 'none'): boolean
  rename(id: string, name: unknown): boolean
  forget(id: string): boolean
  /**
   * The folder a session on this server starts in when nothing names one.
   *
   * Written as `{ startIn }` rather than as a bare string so that A's own
   * `get` satisfies it unchanged — the store answers a whole row, and naming
   * one field of it here is what keeps this interface a *slice* rather than a
   * second shape to keep in step with `store.ts`.
   */
  get(id: string): { startIn: string | null } | null
  /** Remember that folder, or clear it with null. See A's `setStartIn`. */
  setStartIn(id: string, path: string | null): boolean
}

/** The slice of A's `ServerCredentials` this file uses. */
export interface ServerCredentialStore {
  available(): boolean
  save(serverId: string, credential: ServerCredential): { ok: boolean; message: string }
  /**
   * Use this sign-in until the app closes, and never write it down.
   *
   * Not an optional extra. It is the *only* place a credential lives in the two
   * cases where {@link save} does not run — somebody who ticked "don't
   * remember" on a borrowed computer, and a machine whose OS has no secure
   * store to save into — and without it both of those people get a server that
   * is added and then cannot connect, with the sentence blaming their password.
   */
  holdForSession(serverId: string, credential: ServerCredential): void
  forget(serverId: string): { ok: boolean; message: string }
}

/**
 * What the window sends when somebody adds a server.
 *
 * Three things anyone can answer — address, username, and a password or a
 * pasted key — with nothing configured in advance. §2.1. The field names are
 * the ones `AddServer.tsx` sends, deliberately: a shape agreed in two places
 * is a shape that drifts, and `contract.test.ts` records three shipping bugs at
 * exactly this seam, none of which was a type error.
 *
 * The credential travels **inbound only**. It is typed once, saved into the
 * operating system's secure store by `credentials.ts`, and never crosses back:
 * `renderer/machines/types.ts` already states the rule for paired devices —
 * *"a screen that held one would be a screenshot away from publishing it"* —
 * and it holds identically here.
 *
 * `remember: false` is §3.7's "don't save" option, and it is honoured by simply
 * not writing anything. Somebody trying this out on a borrowed machine should
 * not have to trust us to be careful.
 */
export interface AddServerDraft extends SignInDraft {
  address: string
  username: string
  name?: string
  port?: number
  remember?: boolean
}

/**
 * Why adding a server did not work, in the closed set the window renders.
 *
 * Every one of these is a *different thing to do next*, which is the whole
 * reason it is not one string: a locked key means show a passphrase field, a
 * refused sign-in means check the username, and an address that does not
 * resolve means check for a typo. `AddServer.tsx` branches on this.
 */
export type AddServerFailure =
  | 'needs-passphrase'
  | 'bad-passphrase'
  | 'key-unreadable'
  | 'sign-in-refused'
  | 'no-such-address'
  | 'no-answer'
  | 'not-a-server'
  | 'said-nothing'
  | 'nothing-in-common'
  | 'unknown'

export interface ServersIpc {
  /** The room, for `tools.ts`. */
  room: ServerRoom
  /** The copilot's per-server permission, for `tools.ts` and for a settings screen. */
  grants: ServerGrants
  /** Close every shell and drop every connection. For shutdown. */
  stop(): void
}

/* ------------------------------------------------------------ registration -- */

export function registerServersIpc(ipcMain: InvokeRegistrar, deps: ServersIpcDeps): ServersIpc {
  const now = deps.now ?? Date.now
  const backupDir = join(deps.storageDir, 'backups')
  const journal = new FileJournal(deps.storageDir)
  const views = new Map<string, ServerView>()
  /**
   * The probe's whole answer, kept beside the view it built.
   *
   * `ServerView.facts` is deliberately the narrow slice the action layer needs,
   * so the agent rows and the install room — which nothing on a card reads —
   * would otherwise be thrown away the moment the view was assembled, and asking
   * for them again would be a second round trip to a machine that already said.
   */
  const probed = new Map<string, ServerFacts>()
  /**
   * Throw away what we measured about one server, both halves together.
   *
   * A helper rather than two lines at five call sites, because the second line
   * is the one that gets left out — and a probe record that outlived the view it
   * built would answer a setup question about a server whose page has since said
   * it needs measuring again.
   */
  const forgetMeasurements = (serverId: string): void => {
    views.delete(serverId)
    probed.delete(serverId)
  }
  const shells = new Map<string, ServerShell>()
  /**
   * One shadow terminal per open server shell, keyed the same way.
   *
   * ## Why a server shell can have controls at all
   *
   * A server is not a machine running this app, so `CAPABILITY.controls` — the
   * frame pair a paired desktop answers — has nobody to answer it. What a server
   * shell *does* have is the one thing `agent-controls.ts` actually needs: a real
   * pty. `connection.ts` opens it with `client.shell({ term: 'xterm-256color' })`
   * and the bytes come back through `SERVERS_SHELL_OUTPUT_CHANNEL`, so they can
   * be written into the same emulator every local session is read from, and the
   * same reader that finds Claude Code's banner, its composer and its footer on
   * a local screen finds them on this one.
   *
   * ## And why that does not put `/model` into somebody's `sh`
   *
   * Because the two gates that already stand in front of every local press stand
   * in front of this one, and neither of them is a guess about the far machine:
   *
   *  - `refuseByProvider` is handed `undefined` — this app did not launch
   *    whatever is in that terminal and does not pretend to know — which makes
   *    the *screen* decisive. A plain `sh` prompt carries none of Claude Code's
   *    markers, so the answer is the sentence "nothing on this session's screen
   *    says Claude Code is running in it" and nothing is written.
   *  - `refuseToType` then refuses anyway, because a shell prompt is not the
   *    CLI's composer: `readComposer` cannot find the box, and the refusal is
   *    "this session's prompt is not on screen, so there is nowhere to type that
   *    could be checked first."
   *
   * So `/model: command not found` is not a risk that is being accepted here; it
   * is a thing two independent readers of the screen have to both fail to notice
   * before a byte is written.
   *
   * ## What is deliberately *not* read
   *
   * This machine's `~/.claude/settings.json`, its transcripts, and this
   * process's environment — see `ControlScope`. They describe this laptop and
   * the session is on somebody's server, so every one of them would be a
   * confident wrong answer. A server shell is read from its screen or it reports
   * nothing, and nothing is what the bar draws as "Unknown".
   */
  const screens = new Map<string, ActivityTracker>()

  /**
   * The session layer `agent-controls.ts` asks for, over an SSH channel.
   *
   * Two methods, the same two a local `PtyManager` supplies, which is the whole
   * reason that module was written against a two-method seam in the first place:
   * *"kept tiny so it is trivially faked"* — and a server shell turns out to be
   * the second real implementation rather than a fake.
   */
  const shellControls = {
    write: (shellId: string, data: string): void => {
      shells.get(shellId)?.write(data)
    },
    screen: async (shellId: string): Promise<string | null> => {
      const tracker = screens.get(shellId)
      if (tracker === undefined) return null
      try {
        return await tracker.settledText()
      } catch {
        /*
         * The shell closed while this read was in flight.
         *
         * `settledText` writes an empty string into the emulator and waits for
         * the parser's callback, and a terminal disposed between those two steps
         * has nothing left to call it back. Null is what the caller already
         * understands as "there is no such session", which is exactly what has
         * just become true — and it is the answer `agent-controls.ts` turns into
         * "That session is no longer running" rather than into a hung promise.
         */
        return null
      }
    },
  }

  /**
   * Close one server shell and forget everything held for it.
   *
   * A helper rather than three lines repeated at five call sites, because the
   * emulator is the line that would be left out: a tracker that is not disposed
   * keeps an `xterm` instance and its scrollback alive for the life of the app,
   * once per terminal anybody ever opened on a server.
   */
  function dropShell(shellId: string, close: boolean): void {
    if (close) shells.get(shellId)?.close()
    shells.delete(shellId)
    screens.get(shellId)?.dispose()
    screens.delete(shellId)
    /*
     * A setup runs its sign-in *in* one of these terminals, so the terminal
     * going away is the sign-in going away — and the listener on this Mac and
     * the scratch folder on their server have to go with it. Leaving either
     * behind is the one failure this whole flow is written not to have.
     */
    const space = shellId.indexOf(' ')
    if (space > 0) void setups.cancel(shellId.slice(0, space))
  }
  const grants = new ServerGrants({ now, knows: (id) => deps.servers().some((server) => server.id === id) })

  const actionDeps = (lines?: number): ActionDeps => ({
    run: deps.run,
    journal,
    download: deps.download,
    backupDir: deps.download === undefined ? undefined : backupDir,
    now,
    logLines: lines,
  })

  /**
   * Build the whole view of one server: facts, cards, and what each card may do.
   *
   * Two round trips at most and never more, whatever else happens on the page.
   * The first is A's probe (§3.2, measured at 179 ms); the second is the
   * way-back survey, which asks only what a `kept` action would need and whose
   * failure costs an Update button rather than a page.
   */
  const look = async (serverId: string): Promise<ServerView> => {
    await deps.acquire?.(serverId)
    const facts = await deps.facts(serverId)
    let survey: WayBackSurvey = emptySurvey()
    const script = waybackScript(facts)
    try {
      const result = await deps.runScript(serverId, script)
      if (result.code === 0) survey = parseSurvey(result.stdout)
    } catch {
      /*
       * Deliberately swallowed. The survey is an extra: without it every card
       * is still drawn and every Safe and Reversible action still works, and
       * the only thing lost is the Update button — which is exactly the thing
       * that should be lost when we cannot establish a way back.
       */
    }
    const cards = classify(facts, survey)
    const offered: Record<string, ActionId[]> = {}
    const absent: Record<string, AbsentAction[]> = {}
    for (const card of cards) {
      const availability = availableActions(card, facts, {
        canDownload: deps.download !== undefined,
        composeAvailable: survey.compose_available,
      })
      offered[card.id] = availability.offered
      absent[card.id] = availability.absent
    }
    const view: ServerView = {
      cards,
      facts,
      composeAvailable: survey.compose_available,
      offered,
      absent,
      how: howOf(facts),
      cannot: cannotOf(facts),
      measuredAt: facts.measuredAt,
    }
    views.set(serverId, view)
    probed.set(serverId, facts)
    return view
  }

  const cardOf = (view: ServerView, cardId: string): ServerCard => {
    const card = view.cards.find((row) => row.id === cardId)
    if (card === undefined) throw new ActionRefused('That isn’t on this server any more. Refresh the page.')
    return card
  }

  const room: ServerRoom = {
    list: () => deps.servers(),
    knows: (serverId) => deps.servers().some((server) => server.id === serverId),
    look,
    cached: (serverId) => views.get(serverId) ?? null,
    preview: async (serverId, cardId, actionId) => {
      const view = views.get(serverId) ?? (await look(serverId))
      return previewOf(actionId, { serverId, card: cardOf(view, cardId), facts: view.facts }, view.composeAvailable)
    },
    act: async (serverId, cardId, actionId) => {
      const view = views.get(serverId) ?? (await look(serverId))
      const card = cardOf(view, cardId)
      /*
       * The availability check runs again here, against the same facts the
       * dialog was built from. `tools.ts` already prechecks it and the card
       * already draws from it; this is the third place and it is the one that
       * actually gates the command. The two above it decide what a person is
       * *shown*, and a rule enforced only where something is shown is a rule the
       * next caller does not have.
       */
      const availability = availableActions(card, view.facts, {
        canDownload: deps.download !== undefined,
        composeAvailable: view.composeAvailable,
      })
      if (actionId !== 'go-back' && !availability.offered.includes(actionId)) {
        const stated = availability.absent.find((row) => row.actionId === actionId)
        throw new ActionRefused(stated?.because ?? `That isn’t something this app can do to ${card.name}.`)
      }
      const outcome = await perform(actionDeps(), actionId, { serverId, card, facts: view.facts })
      /*
       * Anything that changed the server invalidates the view. Not by
       * re-measuring — that would be a fetch nobody asked for, and §5.4 is
       * clear that a refresh is a press — but by dropping the cache, so the
       * next look is a real one and the page never draws a stopped service as
       * running because we remembered it that way.
       */
      if (actionId !== 'logs' && actionId !== 'open' && actionId !== 'copy-address') forgetMeasurements(serverId)
      return outcome
    },
    logs: async (serverId, cardId, lines) => {
      const view = views.get(serverId) ?? (await look(serverId))
      const card = cardOf(view, cardId)
      const outcome = await perform(actionDeps(lines), 'logs', { serverId, card, facts: view.facts })
      const value = outcome.value as { lines?: string[] } | undefined
      return { lines: value?.lines ?? [] }
    },
  }

  /* --------------------------------------------------------- the handlers -- */

  ipcMain.handle('servers:list', (): ServerSummary[] => deps.servers())

  ipcMain.handle('servers:look', async (_event, serverId: unknown): Promise<ServerResult<{ view: ServerView }>> => {
    if (typeof serverId !== 'string') return { ok: false, sentence: 'No server was named.', detail: '' }
    try {
      return { ok: true, view: await look(serverId) }
    } catch (error) {
      return failed(error)
    }
  })

  ipcMain.handle(
    'servers:preview',
    async (
      _event,
      serverId: unknown,
      cardId: unknown,
      actionId: unknown,
    ): Promise<ServerResult<{ preview: ActionPreview }>> => {
      if (typeof serverId !== 'string' || typeof cardId !== 'string' || !isActionId(actionId)) {
        return { ok: false, sentence: 'That isn’t something this app can do.', detail: '' }
      }
      try {
        return { ok: true, preview: await room.preview(serverId, cardId, actionId) }
      } catch (error) {
        return failed(error)
      }
    },
  )

  ipcMain.handle(
    'servers:act',
    async (
      _event,
      serverId: unknown,
      cardId: unknown,
      actionId: unknown,
    ): Promise<ServerResult<{ outcome: ActionOutcome }>> => {
      if (typeof serverId !== 'string' || typeof cardId !== 'string' || !isActionId(actionId)) {
        return { ok: false, sentence: 'That isn’t something this app can do.', detail: '' }
      }
      try {
        return { ok: true, outcome: await room.act(serverId, cardId, actionId) }
      } catch (error) {
        return failed(error)
      }
    },
  )

  ipcMain.handle(
    'servers:logs',
    async (
      _event,
      serverId: unknown,
      cardId: unknown,
      lines: unknown,
    ): Promise<ServerResult<{ lines: string[] }>> => {
      if (typeof serverId !== 'string' || typeof cardId !== 'string') {
        return { ok: false, sentence: 'No server was named.', detail: '' }
      }
      const want = typeof lines === 'number' && Number.isFinite(lines) ? Math.trunc(lines) : DEFAULT_LOG_LINES
      try {
        const result = await room.logs(serverId, cardId, Math.min(Math.max(want, 1), MAX_LOG_LINES))
        return { ok: true, lines: result.lines }
      } catch (error) {
        return failed(error)
      }
    },
  )

  /**
   * The page has been closed. Drop the connection and everything hanging off it.
   *
   * This is the other half of §5.4 and it is the half that is easy to forget.
   * Opening a connection when a page opens is obvious; closing it when the page
   * closes is what stops a person who visited six servers this morning from
   * holding six sockets open all afternoon.
   */
  ipcMain.handle('servers:close', (_event, serverId: unknown): { closed: boolean } => {
    if (typeof serverId !== 'string') return { closed: false }
    forgetMeasurements(serverId)
    for (const id of [...shells.keys()]) {
      if (id.startsWith(`${serverId} `)) dropShell(id, true)
    }
    deps.release?.(serverId)
    return { closed: true }
  })

  /* ------------------------------------------------------ adding and forgetting -- */

  /**
   * Add a server: an address, a username, and a password or a pasted key.
   *
   * The sign-in is saved through the operating system's own secure store and is
   * never answered back. Where there is no secure store — a Linux box with no
   * keyring — the server is still added and the sentence says what happened, so
   * a person can connect by pasting a key each time rather than being refused
   * outright with no explanation.
   */
  /**
   * Add a server, and prove it is reachable before saying it was added.
   *
   * The order is the point. A row in the list that has never connected is a row
   * whose first failure arrives later, on a different screen, with none of the
   * three things the person just typed in front of them — so the connection is
   * attempted **here**, and a server that could not be reached is rolled back
   * out of the list rather than left as a broken entry to puzzle over.
   *
   * The key is checked locally first, because that check is free and its three
   * outcomes are the ones with the most useful next step: *"that key is locked,
   * what is its passphrase"* is a field appearing, not an error.
   *
   * Where there is no secure store — a Linux box with no keyring — the server is
   * still added and the sentence says what happened, so a person can work by
   * pasting a key each launch rather than being refused with no explanation.
   */
  ipcMain.handle(
    'servers:add',
    async (
      _event,
      draft: unknown,
    ): Promise<
      { ok: true; id: string; savedSignIn: boolean; note: string } | { ok: false; kind: AddServerFailure; sentence: string }
    > => {
      const store = deps.store
      if (store === undefined) {
        return { ok: false, kind: 'unknown', sentence: 'This copy of the app can’t add a server.' }
      }
      if (typeof draft !== 'object' || draft === null) {
        return { ok: false, kind: 'unknown', sentence: 'That isn’t a server we can add.' }
      }
      const row = draft as AddServerDraft
      const signIn = credentialFromDraft(row)
      if (!signIn.ok) {
        return {
          ok: false,
          kind: signIn.problem === 'nothing-typed' ? 'unknown' : signIn.problem,
          sentence: signIn.sentence,
        }
      }

      let added: { id: string }
      try {
        added = store.add({
          name: row.name ?? row.address,
          address: row.address,
          port: row.port,
          username: row.username,
        })
      } catch (error) {
        // `store.ts` refuses an address it could not dial and says why in a
        // sentence written for a person. Relayed, never re-worded.
        return { ok: false, kind: 'unknown', sentence: sentenceOf(error) }
      }

      const secure = deps.credentials
      let savedSignIn = false
      let note = ''
      /*
       * Two of these three branches do not write anything down, and both of
       * them must still hand the sign-in to the connection — otherwise the
       * `acquire` a few lines below dials with no credential at all and the
       * person is told their sign-in was refused, on the strength of a password
       * they typed correctly and we then threw away.
       */
      if (secure === undefined || !secure.available()) {
        note = NO_SECURE_STORE
        secure?.holdForSession(added.id, signIn.credential)
      } else if (row.remember === false) {
        note = 'This sign-in is kept only until you close the app.'
        secure.holdForSession(added.id, signIn.credential)
      } else {
        const saved = secure.save(added.id, signIn.credential)
        savedSignIn = saved.ok
        if (!saved.ok) {
          note = saved.message
          // The disk refused it; the connection still needs it. Falling back to
          // the session-only hold means "we couldn't save this for next time"
          // rather than "we couldn't sign you in", which is what actually
          // happened and is a much smaller thing to have gone wrong.
          secure.holdForSession(added.id, signIn.credential)
        }
      }

      /*
       * Dial once, then let go. `acquire`/`release` is A's own pool, so this is
       * the same connection path every later action takes rather than a second
       * one written for this screen — which is how the two eventually disagree
       * about which host keys are acceptable.
       */
      if (deps.acquire !== undefined) {
        try {
          await deps.acquire(added.id)
          deps.release?.(added.id)
        } catch (error) {
          store.forget(added.id)
          secure?.forget(added.id)
          return { ok: false, kind: failureKind(error), sentence: sentenceOf(error) }
        }
      }
      /*
       * The kind, written down once the sign-in has somewhere to live. After
       * the dial rather than before it, so a server whose sign-in was refused —
       * and which is about to be forgotten again a few lines up — never leaves
       * a claim behind about a credential that turned out not to work.
       */
      store.setCredentialKind(added.id, signIn.credential.kind)
      return { ok: true, id: added.id, savedSignIn, note }
    },
  )

  ipcMain.handle('servers:rename', (_event, serverId: unknown, name: unknown): { renamed: boolean } => {
    if (typeof serverId !== 'string' || deps.store === undefined) return { renamed: false }
    forgetMeasurements(serverId)
    return { renamed: deps.store.rename(serverId, name) }
  })

  /**
   * Forget a server. **Nothing on the server changes.**
   *
   * §5.3 is explicit about why this sentence has to be exact: *"'forget' beside
   * a list of the person's websites will read as 'delete' to somebody who does
   * not know better."* So this removes what *this app* holds — the row, the
   * saved sign-in, the recorded host key, and the ways back — and touches the
   * far end not at all. It does not even connect.
   *
   * The ways back go with it deliberately. A rollback record naming a server
   * this app no longer knows is a row that can never be acted on and that
   * carries an image digest from somebody's machine indefinitely.
   */
  ipcMain.handle('servers:forget', async (_event, serverId: unknown): Promise<{ forgotten: boolean }> => {
    if (typeof serverId !== 'string' || deps.store === undefined) return { forgotten: false }
    for (const shellId of [...shells.keys()]) {
      if (shellId.startsWith(`${serverId} `)) dropShell(shellId, true)
    }
    const view = views.get(serverId)
    if (view !== undefined) {
      for (const card of view.cards) await journal.clear(serverId, card.id).catch(() => undefined)
    }
    forgetMeasurements(serverId)
    grants.revoke(serverId)
    deps.release?.(serverId)
    deps.credentials?.forget(serverId)
    return { forgotten: deps.store.forget(serverId) }
  })

  /* --------------------------------------------------- the keys on this computer -- */

  /*
   * Three channels so that adding a server with a key is *picking a name*
   * rather than being told to open a file in a text editor.
   *
   * `keyfiles.ts` carries the argument and the measurements. What matters here
   * is the shape: the list and the panel are the only two ways a path becomes
   * readable, and `offers` remembers which ones it handed out. A path the
   * window invents is refused — otherwise `servers:key-read` is "read any file
   * on this computer" with the renderer's word for which one, and the renderer
   * is the surface that runs other people's web pages in this app.
   */
  const offers = new KeyFileOffers()
  const keyFolder = deps.keyFolder ?? join(homedir(), '.ssh')

  ipcMain.handle('servers:keys', (): KeyFileOffer[] => offers.list(keyFolder))

  ipcMain.handle('servers:key-pick', async (): Promise<KeyFileOffer | null> => {
    if (deps.pickKeyFile === undefined) return null
    const path = await deps.pickKeyFile()
    if (path === null) return null
    return offers.chose(path)
  })

  ipcMain.handle(
    'servers:key-read',
    (_event, path: unknown): { ok: true; key: string } | { ok: false; sentence: string } => {
      if (typeof path !== 'string') {
        return { ok: false, sentence: 'That file could not be read. Choose it again.' }
      }
      return offers.read(path)
    },
  )

  /* ------------------------------------------------------------ the grant -- */

  ipcMain.handle(
    'servers:grant',
    (_event, serverId: unknown, forMs: unknown): ServerResult<{ grant: GrantState }> => {
      if (typeof serverId !== 'string') return { ok: false, sentence: 'No server was named.', detail: '' }
      const want = typeof forMs === 'number' && Number.isFinite(forMs) ? forMs : DEFAULT_GRANT_MS
      try {
        /*
         * `{ kind: 'local' }` is not an assumption. An `ipcMain.handle` is
         * answered for a window on this machine — there is no path from the
         * relay into this channel, because the remote protocol has no server
         * frame at all. `grants.ts` refuses a remote asker anyway, which is the
         * check that keeps holding if that ever stops being true.
         */
        return { ok: true, grant: grants.grant(serverId, { kind: 'local' }, Math.min(want, MAX_GRANT_MS)) }
      } catch (error) {
        if (error instanceof GrantRefused) return { ok: false, sentence: error.message, detail: '' }
        return failed(error)
      }
    },
  )

  ipcMain.handle('servers:revoke', (_event, serverId: unknown): { revoked: boolean } => {
    if (typeof serverId !== 'string') return { revoked: false }
    grants.revoke(serverId)
    return { revoked: true }
  })

  ipcMain.handle('servers:grant-state', (_event, serverId: unknown): GrantState | null =>
    typeof serverId === 'string' ? grants.state(serverId) : null,
  )

  /* --------------------------------------------------------- the terminal -- */

  /**
   * A real shell on that server, one click from the page.
   *
   * §4.6: this is the honest floor. Everything else on the page is a named
   * action with a known consequence; this is a shell, and a shell has no
   * consequence sentence — which is exactly why it lives one door further in,
   * in zone three, and why the copilot has no tool that reaches it (§6.1).
   *
   * It reuses the terminal surface this app already has. The renderer draws it
   * through the same `@xterm/*` stack every session uses; nothing new is needed
   * on either side, which is the whole reason the design document could put a
   * full shell behind one click without inventing a second terminal.
   */
  ipcMain.handle(
    'servers:shell:open',
    async (
      _event,
      serverId: unknown,
      cols: unknown,
      rows: unknown,
      startIn: unknown,
    ): Promise<ServerResult<{ shellId: string }>> => {
      if (typeof serverId !== 'string') return { ok: false, sentence: 'No server was named.', detail: '' }
      if (deps.openShell === undefined) {
        return { ok: false, sentence: 'This copy of the app can’t open a terminal on a server.', detail: '' }
      }
      const size = { cols: clampSize(cols, 120), rows: clampSize(rows, 30) }
      /*
       * A folder the caller named, or this server's own default, or nowhere.
       *
       * The fallback is the whole of *"I can make one of them as default or
       * something so you can always start seamlessly a new session."* It is
       * resolved **here**, in the one place every door goes through, rather
       * than in each of them: the server page's *Open a terminal*, the New
       * session dialog, and the rail's plus on a server group are three presses
       * that pass three different things, and a default honoured by two of them
       * would be a default that looks broken from the third.
       *
       * Which means "no folder named" and "the default" are the same request
       * for a server that has one. Landing wherever the sign-in lands is still
       * reachable — by clearing the default, which is a control the picker
       * draws — and that is deliberately the same act as saying you no longer
       * want one, because a person who has chosen a default has said where
       * their work is.
       */
      const named = typeof startIn === 'string' && startIn !== '' ? startIn : null
      const folder = named ?? deps.store?.get(serverId)?.startIn ?? undefined
      try {
        const shell = await deps.openShell(serverId, size, folder)
        const shellId = `${serverId} ${randomUUID()}`
        /*
         * `onData` and `onClose` hand back an unsubscribe function. They are
         * dropped on purpose: this app is the shell's only listener and the
         * shell is closed rather than merely un-listened-to, so keeping the
         * unsubscribers would be two references to tidy where one already does
         * the job. `close()` is what ends it, on every path.
         */
        /*
         * The bytes go two places, and the second one is what gives this
         * terminal a model chip.
         *
         * `setWatched(false)` immediately afterwards, because the tracker's other
         * job — classifying a session as idle or working on a timer — belongs to
         * the sessions in the rail and nothing here reads it. Unwatched still
         * writes every chunk into the emulator, which is the half that must never
         * be skipped: a gap in what it was fed is a screen that no longer matches
         * the real terminal, and no later byte repairs it.
         */
        const tracker = new ActivityTracker(shellId, () => {}, size.cols, size.rows)
        tracker.setWatched(false)
        screens.set(shellId, tracker)
        shell.onData((chunk) => {
          // Read out of the map rather than closed over, so a chunk that arrives
          // between `close()` and the far end actually stopping is dropped
          // instead of being written into a disposed emulator.
          screens.get(shellId)?.push(chunk)
          deps.broadcast(SERVERS_SHELL_OUTPUT_CHANNEL, { shellId, data: chunk })
        })
        shell.onClose(() => {
          dropShell(shellId, false)
          deps.broadcast(SERVERS_SHELL_CLOSED_CHANNEL, { shellId })
        })
        shells.set(shellId, shell)
        return { ok: true, shellId }
      } catch (error) {
        return failed(error)
      }
    },
  )

  /**
   * Put a file on the server and answer **its** path for it.
   *
   * Answers `{ ok, path }` / `{ ok, message }` rather than this file's own
   * `ServerResult`, and the difference is deliberate: the one consumer is
   * `renderer/session-transfer.ts`, which reads exactly that shape from
   * `machines:upload` as well, and one reader over two channels is what keeps a
   * file going to a server and a file going to a paired PC from drifting into
   * two behaviours. `readHandover` over there refuses an `ok` with no path,
   * which is the one wrong answer either channel could give.
   *
   * The size is checked here, before anything is dialled, for the reason
   * `upload-send.ts` checks it before announcing anything: an over-size file
   * should be one sentence rather than a connection and then a sentence.
   */
  ipcMain.handle(
    'servers:upload',
    async (
      _event,
      serverId: unknown,
      filePath: unknown,
    ): Promise<{ ok: true; path: string } | { ok: false; message: string }> => {
      if (typeof serverId !== 'string' || typeof filePath !== 'string' || filePath === '') {
        return { ok: false, message: 'That is not a server and a file.' }
      }
      if (deps.putFile === undefined) {
        return { ok: false, message: 'This copy of the app cannot put a file on a server.' }
      }
      let size = 0
      try {
        size = statSync(filePath).size
      } catch {
        return { ok: false, message: 'That file is not there any more.' }
      }
      if (size > MAX_UPLOAD_BYTES) {
        return { ok: false, message: `That file is larger than ${byteSize(MAX_UPLOAD_BYTES)}.` }
      }
      try {
        return { ok: true, path: await deps.putFile(serverId, filePath, basename(filePath)) }
      } catch (error) {
        const answer = failed(error)
        return { ok: false, message: answer.sentence || 'That file did not send.' }
      }
    },
  )

  ipcMain.handle('servers:shell:write', (_event, shellId: unknown, data: unknown): { written: boolean } => {
    if (typeof shellId !== 'string' || typeof data !== 'string') return { written: false }
    const shell = shells.get(shellId)
    if (shell === undefined) return { written: false }
    shell.write(data)
    return { written: true }
  })

  /**
   * Columns first, then rows — the same order as `shell({ cols, rows })`.
   *
   * `ssh2` reverses them between `shell()` and `setWindow(rows, cols, …)`, in
   * the same library on the same channel. Getting it wrong produces a terminal
   * that works until the window is resized and then wraps every line at the
   * wrong column, which reads as a rendering bug rather than as a swapped pair
   * of arguments. This port keeps one order everywhere so the flip lives in
   * exactly one adapter, in `connection.ts`, where a test can stand on it.
   */
  ipcMain.handle(
    'servers:shell:resize',
    (_event, shellId: unknown, cols: unknown, rows: unknown): { resized: boolean } => {
      if (typeof shellId !== 'string') return { resized: false }
      const shell = shells.get(shellId)
      if (shell === undefined) return { resized: false }
      const size = { cols: clampSize(cols, 120), rows: clampSize(rows, 30) }
      shell.resize(size)
      // The shadow terminal has to track the real one or its viewport is the
      // wrong shape and the readers look at the wrong lines — `PtyManager.resize`
      // carries the same pairing for the same reason.
      screens.get(shellId)?.resize(size.cols, size.rows)
      return { resized: true }
    },
  )

  /* ---------------------------------------------------------- the folders -- */

  /**
   * What is inside one folder on that server.
   *
   * The one question a folder picker asks, answered over SFTP by
   * `connection.ts`. Everything here is narrowing and a sentence: this file
   * writes no path, resolves no `..` and never assembles a home directory —
   * the server answers with the absolute path it resolved, and that answer is
   * what the next call is made with.
   *
   * ## Refusals are answers, not failures
   *
   * A folder an ordinary account may not read is the *normal* case for half of
   * a Linux root, and a picker that treated it as an error would put a page
   * into a dead state for doing the thing it invites. So it comes back as an
   * ordinary `{ ok: false }` carrying the sentence A wrote, the same shape
   * every other fallible handler here answers with, and the picker draws the
   * sentence and stays where it was.
   */
  ipcMain.handle(
    'servers:folder',
    async (
      _event,
      serverId: unknown,
      path: unknown,
    ): Promise<ServerResult<{ path: string; entries: readonly { name: string; kind: string }[] }>> => {
      if (typeof serverId !== 'string') return { ok: false, sentence: 'No server was named.', detail: '' }
      if (deps.listFolder === undefined) {
        return {
          ok: false,
          sentence: 'This copy of the app cannot list folders on a server. You can still type the path.',
          detail: '',
        }
      }
      // An absent or unusable path is the account's own login directory, which
      // is where SSH would have put them. It is never `/` — starting a stranger
      // at the root of their machine is a picker that opens on the one folder
      // nobody keeps their work in.
      const where = typeof path === 'string' ? path : ''
      try {
        const listing = await deps.listFolder(serverId, where)
        return { ok: true, path: listing.path, entries: listing.entries }
      } catch (error) {
        return failed(error)
      }
    },
  )

  /**
   * Which folder this server starts a session in when nothing names one.
   *
   * A read of a file this process already has in hand — it asks the server
   * nothing and connects to nothing, which is why the picker may call it the
   * moment it is drawn without breaking the rule that a folder listing waits
   * until somebody actually opens the browser.
   */
  ipcMain.handle('servers:start-in', (_event, serverId: unknown): { path: string | null } => {
    if (typeof serverId !== 'string' || deps.store === undefined) return { path: null }
    return { path: deps.store.get(serverId)?.startIn ?? null }
  })

  /**
   * Remember that folder, or clear it.
   *
   * Null and the empty string both clear it, because an emptied box and a
   * *Clear default* press are the same intention arriving in two shapes.
   * Nothing is checked against the server: see `store.ts`'s `setStartIn` for
   * why a folder that exists now proves nothing about the next session.
   */
  ipcMain.handle(
    'servers:start-in:set',
    (_event, serverId: unknown, path: unknown): { saved: boolean } => {
      if (typeof serverId !== 'string' || deps.store === undefined) return { saved: false }
      const folder = typeof path === 'string' && path !== '' ? path : null
      return { saved: deps.store.setStartIn(serverId, folder) }
    },
  )

  /**
   * The model, the effort and fast mode of whatever is running in a server's
   * terminal.
   *
   * ## Why these exist at all, given a server does not run this app
   *
   * Asad, on the recording of 2026-08-18, about both remote surfaces at once:
   *
   *   > *"I still don't see all of these things inside like this header with
   *   > model, high effort and all of these things — I don't see it in server
   *   > sessions and in the remote sessions both."*
   *
   * A paired machine answers that with the `controls` frames, because it is
   * running this app and has its own copy of `agent-controls.ts`. A server has
   * none of that. What it has is the only thing the mechanism actually requires:
   * a pty whose bytes arrive here. So this is not a second implementation — it
   * is `readControls` and `applyControl`, unchanged, against a `SessionAccess`
   * whose two methods reach an SSH channel instead of a `node-pty`.
   *
   * ## The one thing that had to change, and it is the honest half
   *
   * `ControlScope`. Every non-screen source that module reads is *this* laptop's
   * — `~/.claude/settings.json`, the transcripts, `CLAUDE_CODE_EFFORT_LEVEL` —
   * and answering a question about somebody's server with this machine's
   * configuration is the exact class of confident wrong answer the whole controls
   * layer is arranged against. `onThisMachine: false` turns all of them off, so a
   * server shell is read from its screen or it reports nothing.
   *
   * ## And the shell that has no agent in it is the ordinary case
   *
   * It is refused twice and neither refusal is a guess: `refuseByProvider` finds
   * no Claude Code markers on the screen and says so, and `refuseToType` finds no
   * composer to type into and says that. The window draws the sentence in the
   * place the menu would have been, which is the same thing it does for a local
   * shell nobody has started an agent in. See {@link screens} for the argument in
   * full.
   *
   * `provider` is deliberately never passed. This app did not launch whatever is
   * in that terminal and has no record to consult; `undefined` is the value that
   * means "ask the screen", and the screen is the only witness there is.
   */
  ipcMain.handle('servers:controls:read', (_event, shellId: unknown): Promise<ControlsReading> | null => {
    if (typeof shellId !== 'string') return null
    return readControls(shellControls, shellId, undefined, undefined, { onThisMachine: false })
  })

  ipcMain.handle(
    'servers:controls:apply',
    (_event, shellId: unknown, control: unknown, value: unknown): Promise<ApplyResult> | ApplyResult => {
      const unread = { value: null, label: null, source: null }
      if (typeof shellId !== 'string') {
        return { ok: false, message: 'No terminal was named.', reading: unread }
      }
      /*
       * Narrowed against the list rather than cast, because everything past this
       * line composes a slash command and types it at somebody's prompt, and an
       * `ipcMain.handle` argument is whatever the renderer put in it however the
       * type says otherwise. `applyControl` checks the *value* against the CLI's
       * own accepted levels and model shapes; this checks the name of the branch.
       */
      const named = CONTROL_IDS.find((name) => name === control)
      if (named === undefined || typeof value !== 'string' || value === '') {
        return { ok: false, message: 'That is not a control this app can set.', reading: unread }
      }
      return applyControl(shellControls, {
        sessionId: shellId,
        control: named,
        value,
        scope: { onThisMachine: false },
      })
    },
  )

  ipcMain.handle('servers:shell:close', (_event, shellId: unknown): { closed: boolean } => {
    if (typeof shellId !== 'string') return { closed: false }
    if (!shells.has(shellId)) return { closed: false }
    dropShell(shellId, true)
    return { closed: true }
  })

  /* ------------------------------------------------- setting an agent up -- */

  /**
   * The setup flow, wired to the same transport everything else here uses.
   *
   * `withConnection` is optional on the deps and required by the flow, so a host
   * that has none is given one that refuses — which the flow already handles by
   * falling through to the address the person opens themselves, with a sentence
   * saying so. That is the honest degradation; silently doing nothing is not.
   */
  const setups = new ServerSetups({
    runScript: (serverId, script) => deps.runScript(serverId, script),
    withConnection: async (serverId, fn) => {
      if (deps.withConnection === undefined) {
        throw new ServerProblem('lost', 'This copy of the app cannot carry a sign-in.')
      }
      return deps.withConnection(serverId, fn)
    },
    openInBrowser: deps.openInBrowser,
    broadcast: (next) => deps.broadcast(SERVERS_SETUP_CHANNEL, next),
  })

  /**
   * The room a setup needs, or the sentence saying which part of it is missing.
   *
   * Read from `probed` rather than from the cached view, because `ServerView`
   * declares only the slice `actions.ts` acts on and the agent rows are not in
   * it. Same measurement, same round trip — this is the whole record the probe
   * already answered, kept beside the view rather than asked for again.
   */
  const setupRoom = async (
    serverId: string,
  ): Promise<{ ok: true; facts: ServerFacts } | Extract<ServerResult<never>, { ok: false }>> => {
    try {
      if (!probed.has(serverId)) await look(serverId)
      const facts = probed.get(serverId)
      if (facts === undefined) {
        return { ok: false, sentence: 'This server has not been looked at yet.', detail: '' }
      }
      return { ok: true, facts }
    } catch (error) {
      return failed(error)
    }
  }

  ipcMain.handle(
    'servers:setup:state',
    (_event, serverId: unknown, agentId: unknown): SetupState | null =>
      typeof serverId === 'string' && isSetupAgent(agentId)
        ? setups.stateOf(serverId, agentId)
        : null,
  )

  /**
   * What this server has, for each of the three agents, and what it would take
   * to change that.
   *
   * One round trip and three rows, rather than one row about the agent this app
   * happens to be built by. The probe has always found all three; until
   * 2026-08-20 this handler threw two of them away, which is the shape he
   * overruled — *"where we can have an option between Claude, Codex, Gemini, in
   * those places don't name only Claude."*
   *
   * The consequence sentence and every refusal come from `setup.ts`, beside the
   * code that would perform the work — §4.3. The renderer draws them and writes
   * none of them.
   */
  ipcMain.handle(
    'servers:setup:look',
    async (_event, serverId: unknown): Promise<ServerResult<{ rows: SetupRow[] }>> => {
      if (typeof serverId !== 'string') return { ok: false, sentence: 'No server was named.', detail: '' }
      const seen = await setupRoom(serverId)
      if (!seen.ok) return seen
      const name = deps.servers().find((server) => server.id === serverId)?.name ?? 'this server'
      /*
       * A `cannot` about the room is not a reason with a button attached — it is
       * not knowing, and §3.1 is explicit that a control that cannot act is
       * removed rather than drawn hopefully. So no button, and the page says
       * what it could not check rather than offering an install on a guess.
       */
      const roomFact = seen.facts.agentInstall
      const install: AgentInstallRoom | null = roomFact.known === 'yes' ? roomFact.value : null
      return {
        ok: true,
        rows: SETUP_AGENTS.map((agentId) => {
          const why = install === null ? null : whyNotInstall(agentId, install)
          return {
            agentId,
            label: agentSetup(agentId).label,
            installed: agentOn(seen.facts, agentId),
            canInstall: install !== null && why === null,
            why,
            consequence: installConsequence(agentId, name),
            state: setups.stateOf(serverId, agentId),
          }
        }),
      }
    },
  )

  ipcMain.handle(
    'servers:setup:install',
    async (
      _event,
      serverId: unknown,
      agentId: unknown,
      shellId: unknown,
    ): Promise<ServerResult<{ state: SetupState }>> => {
      if (typeof serverId !== 'string' || typeof shellId !== 'string' || !isSetupAgent(agentId)) {
        return { ok: false, sentence: 'No server was named.', detail: '' }
      }
      const shell = shells.get(shellId)
      if (shell === undefined) {
        return { ok: false, sentence: 'That terminal is not open any more.', detail: '' }
      }
      const seen = await setupRoom(serverId)
      if (!seen.ok) return seen
      const where = seen.facts.agentInstall
      if (where.known !== 'yes') {
        return { ok: false, sentence: where.known === 'cannot' ? where.why : 'This server did not answer.', detail: '' }
      }
      const name = deps.servers().find((server) => server.id === serverId)?.name ?? 'this server'
      try {
        return { ok: true, state: await setups.install(serverId, agentId, shell, where.value, name) }
      } catch (error) {
        return failed(error)
      }
    },
  )

  ipcMain.handle(
    'servers:setup:signin',
    async (
      _event,
      serverId: unknown,
      agentId: unknown,
      shellId: unknown,
    ): Promise<ServerResult<{ state: SetupState }>> => {
      if (typeof serverId !== 'string' || typeof shellId !== 'string' || !isSetupAgent(agentId)) {
        return { ok: false, sentence: 'No server was named.', detail: '' }
      }
      const shell = shells.get(shellId)
      if (shell === undefined) {
        return { ok: false, sentence: 'That terminal is not open any more.', detail: '' }
      }
      const seen = await setupRoom(serverId)
      if (!seen.ok) return seen
      const agent = agentOn(seen.facts, agentId)
      if (agent === null || agent.version === '') {
        return {
          ok: false,
          sentence: `${agentSetup(agentId).label} is not ready on this server yet.`,
          detail: '',
        }
      }
      try {
        return { ok: true, state: await setups.signIn(serverId, agentId, shell, agent.path) }
      } catch (error) {
        return failed(error)
      }
    },
  )

  ipcMain.handle('servers:setup:cancel', async (_event, serverId: unknown): Promise<{ cancelled: boolean }> => {
    if (typeof serverId !== 'string') return { cancelled: false }
    await setups.cancel(serverId)
    return { cancelled: true }
  })

  ipcMain.handle(
    'servers:setup:remove',
    async (_event, serverId: unknown, agentId: unknown): Promise<ServerResult<{ state: SetupState }>> => {
      if (typeof serverId !== 'string' || !isSetupAgent(agentId)) {
        return { ok: false, sentence: 'No server was named.', detail: '' }
      }
      const seen = await setupRoom(serverId)
      if (!seen.ok) return seen
      const agent = agentOn(seen.facts, agentId)
      if (agent === null) {
        return { ok: false, sentence: 'There is nothing here for this app to remove.', detail: '' }
      }
      try {
        const next = await setups.remove(serverId, agentId, agent.path)
        // The card is drawn from the facts, and the facts have just changed.
        forgetMeasurements(serverId)
        return { ok: true, state: next }
      } catch (error) {
        return failed(error)
      }
    },
  )

  return {
    room,
    grants,
    stop: () => {
      /*
       * The setups first, and this ordering is the rule rather than tidiness:
       * every one of them may be holding a sign-in open on somebody else's
       * machine, and dropping the shells out from under it would leave that
       * login running with nothing left to stop it.
       */
      void setups.cancelAll()
      for (const shellId of [...shells.keys()]) dropShell(shellId, true)
      for (const serverId of views.keys()) deps.release?.(serverId)
      views.clear()
      probed.clear()
      grants.revokeAll()
    },
  }
}

/** A's own problem kind, narrowed to the closed set the window renders. */
function failureKind(error: unknown): AddServerFailure {
  const known: readonly AddServerFailure[] = [
    'sign-in-refused',
    'no-such-address',
    'no-answer',
    'not-a-server',
    'said-nothing',
    'nothing-in-common',
    'key-unreadable',
  ]
  const kind = (error as { kind?: unknown }).kind
  return known.find((entry) => entry === kind) ?? 'unknown'
}

function sentenceOf(error: unknown): string {
  const said = error instanceof Error ? error.message : String(error)
  return said === '' ? 'That did not work, and the server did not say why.' : said
}

function isActionId(value: unknown): value is ActionId {
  return typeof value === 'string' && (ACTION_IDS as readonly string[]).includes(value)
}

/**
 * A terminal size that cannot be nonsense.
 *
 * Agent CLIs and pagers render against the reported width, so a zero or a
 * negative produces a garbled screen that survives the next correct resize.
 * The same clamp `registerDevServerIpc` applies for the same reason.
 */
function clampSize(value: unknown, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  return Math.min(Math.max(Math.trunc(value), 1), 1000)
}
