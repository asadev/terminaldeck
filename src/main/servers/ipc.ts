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

import { mkdirSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
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
import type { ServerFacts } from './facts'
import { NO_SECURE_STORE, credentialFromDraft, type ServerCredential, type SignInDraft } from './credentials'
import { DEFAULT_GRANT_MS, MAX_GRANT_MS, GrantRefused, ServerGrants, type GrantState } from './grants'

/* ------------------------------------------------------------- channels -- */

export const SERVERS_SHELL_OUTPUT_CHANNEL = 'servers:shell:output'
export const SERVERS_SHELL_CLOSED_CHANNEL = 'servers:shell:closed'

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
  const shells = new Map<string, ServerShell>()
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
      if (actionId !== 'logs' && actionId !== 'open' && actionId !== 'copy-address') views.delete(serverId)
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
    views.delete(serverId)
    for (const [id, shell] of shells) {
      if (id.startsWith(`${serverId} `)) {
        shell.close()
        shells.delete(id)
      }
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
    views.delete(serverId)
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
    for (const [shellId, shell] of shells) {
      if (shellId.startsWith(`${serverId} `)) {
        shell.close()
        shells.delete(shellId)
      }
    }
    const view = views.get(serverId)
    if (view !== undefined) {
      for (const card of view.cards) await journal.clear(serverId, card.id).catch(() => undefined)
    }
    views.delete(serverId)
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
    async (_event, serverId: unknown, cols: unknown, rows: unknown): Promise<ServerResult<{ shellId: string }>> => {
      if (typeof serverId !== 'string') return { ok: false, sentence: 'No server was named.', detail: '' }
      if (deps.openShell === undefined) {
        return { ok: false, sentence: 'This copy of the app can’t open a terminal on a server.', detail: '' }
      }
      const size = { cols: clampSize(cols, 120), rows: clampSize(rows, 30) }
      try {
        const shell = await deps.openShell(serverId, size)
        const shellId = `${serverId} ${randomUUID()}`
        /*
         * `onData` and `onClose` hand back an unsubscribe function. They are
         * dropped on purpose: this app is the shell's only listener and the
         * shell is closed rather than merely un-listened-to, so keeping the
         * unsubscribers would be two references to tidy where one already does
         * the job. `close()` is what ends it, on every path.
         */
        shell.onData((chunk) => deps.broadcast(SERVERS_SHELL_OUTPUT_CHANNEL, { shellId, data: chunk }))
        shell.onClose(() => {
          shells.delete(shellId)
          deps.broadcast(SERVERS_SHELL_CLOSED_CHANNEL, { shellId })
        })
        shells.set(shellId, shell)
        return { ok: true, shellId }
      } catch (error) {
        return failed(error)
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
      shell.resize({ cols: clampSize(cols, 120), rows: clampSize(rows, 30) })
      return { resized: true }
    },
  )

  ipcMain.handle('servers:shell:close', (_event, shellId: unknown): { closed: boolean } => {
    if (typeof shellId !== 'string') return { closed: false }
    const shell = shells.get(shellId)
    if (shell === undefined) return { closed: false }
    shell.close()
    shells.delete(shellId)
    return { closed: true }
  })

  return {
    room,
    grants,
    stop: () => {
      for (const shell of shells.values()) shell.close()
      shells.clear()
      for (const serverId of views.keys()) deps.release?.(serverId)
      views.clear()
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
