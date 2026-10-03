/**
 * Agent accounts: the logins each coding agent runs as on this computer.
 *
 * The Accounts pane, as tools. A person there can list the accounts, see
 * whether each is signed in, add one, rename it, delete it, make it the
 * default (everywhere or for one folder), sign it in, sign it out, and share or
 * stop sharing its conversation history with the machine's own login. Each of
 * those is one tool here, and each calls the function that pane's channel calls.
 *
 * ## The deps are deliberately thin, and typed loosely
 *
 * The release this lands in is also rebuilding where accounts are *stored* — an
 * encrypted vault in the app, any number of accounts — and that lane is keeping
 * the channel names and the main-process function signatures while it changes
 * what is behind them. So every account operation here arrives through
 * {@link AccountToolDeps}, one plain function per action, and the integrator
 * points them at the new functions in one place (`agents-area-live.ts`) if a
 * signature moves. The readings come back as `unknown` and are passed through
 * {@link withoutSecrets} on the way out: nothing in a `Profile` today is a
 * credential, but a field that becomes one in the vault must not reach an
 * outside model because this file trusted the shape.
 *
 * ## Signing in returns a link, never a credential
 *
 * Signing in is interactive and happens in a browser — the agent's own login
 * flow prints a URL, sometimes a code, and waits. `accounts.sign_in` starts a
 * session on the account so the agent asks; whoever drives it reads the link
 * off the session's screen and gives it to the person. That is exactly what
 * the pane's Sign in button does: it opens a session on the account. Nothing
 * here ever reads, returns or stores the token the flow produces — it lands in
 * the agent's own store (the macOS Keychain, for Claude Code), where it was
 * always going to.
 *
 * ## Tiers
 *
 * Everything that writes is `alter`: an account is a credential boundary, and
 * which one a folder's sessions run as decides whose subscription is billed and
 * whose history they can read. Reading is `read`, including the sign-in probe —
 * it runs the agent's own `auth status` command, which changes nothing.
 */

import type { CreateSessionInput, ProviderId } from '../../shared/types'
import { requireKnownFolder, type JsonSchema, type ToolContext, type ToolSpec } from './catalogue'
import { optBool, optStr, str, withoutSecrets } from './agents-area-args'
import { remoteDevice, requireDeviceFolder } from './remote-start'
import { Refused, sessionOriginFor } from './surface'

/** The little of an account this file reads itself: enough to name it in a dialog. */
export interface AccountRef {
  id: string
  name: string
  provider: string
}

export interface AccountToolDeps {
  /** `profiles:list` — the snapshot, narrowed to one agent when one is named. */
  list(agent: string | null): unknown
  /** `profiles:account-providers` — which agents can hold accounts, and why not. */
  agents(): unknown
  /** `profiles:resolve` — the account a new session in this folder would run as. */
  resolve(input: { projectPath: string | null; provider: string | null }): unknown
  /** One account by id, or null. Used to name it in a confirmation. */
  find(id: string): AccountRef | null
  /** `profiles:status`. */
  status(id: string): unknown
  /** `profiles:signin` — runs the agent's own status command under the account. */
  signIn(id: string, refresh: boolean): Promise<unknown>
  /** `accounts:history-state`, with the three sentences the pane shows beside it. */
  history(id: string): { state: unknown; share: string; unshare: string; remove: string }
  /** `profiles:create`. */
  create(name: string, options: { provider?: string; configDir?: string }): unknown
  /** `profiles:rename`. */
  rename(id: string, name: string): unknown
  /** `profiles:delete`. */
  remove(id: string, options: { deleteFiles: boolean }): unknown
  /** `profiles:set-default`. Null means the machine's own login. */
  setDefault(id: string | null): unknown
  /** `profiles:set-project-default`. Null clears the folder's choice. */
  setProjectDefault(projectPath: string, id: string | null): unknown
  /** `profiles:signout` — runs the agent's logout, then proves it took. */
  signOut(id: string): Promise<{ ok: boolean; message: string }>
  /** `accounts:history-share`. */
  share(id: string): unknown
  /** `accounts:history-unshare`. */
  unshare(id: string): unknown
}

/** Same starting shape `sessions.start` gives a session no window has drawn yet. */
const START_COLS = 120
const START_ROWS = 30

const ACCOUNT_ID = { type: 'string', description: 'The account id, from accounts.list.' }

function named(deps: AccountToolDeps, args: Record<string, unknown>): string {
  const id = optStr(args, 'accountId')
  if (id === null) return 'an account'
  const found = deps.find(id)
  return found === null ? `account ${id}` : `the ${found.provider} account ${found.name}`
}

function requireAccount(deps: AccountToolDeps, id: string): AccountRef {
  const found = deps.find(id)
  if (found === null) {
    throw new Refused('not-permitted', `there is no account with id ${id} on this computer. accounts.list shows them.`)
  }
  return found
}

/**
 * The folder a sign-in session runs in.
 *
 * The same two doors `sessions.start` uses, and not a wider one: an open
 * project for the person at this keyboard, and only the folders a paired
 * device was granted for a call that came over the relay. A sign-in session is
 * a session — it runs an agent with the account's login — so it is held to
 * exactly the rule every other session start is.
 */
function signInFolder(context: ToolContext, folder: string): { cwd: string; device: string | null } {
  const device = remoteDevice(context.caller)
  if (device !== null) return { cwd: requireDeviceFolder(context.surface, device, folder), device }
  return { cwd: requireKnownFolder(context.surface, folder), device: null }
}

export function accountTools(deps: AccountToolDeps): ToolSpec[] {
  const idOnly: JsonSchema = {
    type: 'object',
    properties: { accountId: ACCOUNT_ID },
    required: ['accountId'],
    additionalProperties: false,
  }

  return [
    {
      id: 'accounts.list',
      wire: 'accounts_list',
      tier: 'read',
      title: 'List agent accounts',
      description:
        'The logins each coding agent can run as on this computer: the machine’s own login for each agent plus ' +
        'any extra accounts added here, which is the default everywhere and which folders have their own, and ' +
        'which agents can hold more than one account (with the reason when one cannot). Give projectPath to ' +
        'also learn which account a new session in that folder would run as. No credentials are ever included.',
      index: 'List the agent accounts on this computer, the defaults, and which one a folder would use.',
      inputSchema: {
        type: 'object',
        properties: {
          agent: { type: 'string', description: 'Only this agent’s accounts: claude, codex or gemini.' },
          projectPath: { type: 'string', description: 'An open folder: also say which account it would use.' },
        },
        additionalProperties: false,
      },
      summary: () => 'List the agent accounts',
      run: async (args, context) => {
        const agent = optStr(args, 'agent')
        const project = optStr(args, 'projectPath')
        const value: Record<string, unknown> = {
          accounts: deps.list(agent),
          agents: deps.agents(),
        }
        if (project !== null) {
          value['newSessionHere'] = deps.resolve({
            projectPath: requireKnownFolder(context.surface, project),
            provider: agent,
          })
        }
        return { value: withoutSecrets(value), summary: { agent, projectPath: project } }
      },
    },

    {
      id: 'accounts.status',
      wire: 'accounts_status',
      tier: 'read',
      title: 'Check an agent account',
      description:
        'Whether one account is signed in and as whom (by asking the agent’s own CLI, exactly as the Accounts ' +
        'pane does), whether its folder exists, whether its login is really separate from the others, and ' +
        'whether its conversation history is shared with the machine’s own login. Answers are cached for a ' +
        'short while; refresh asks again.',
      index: 'Check whether an agent account is signed in, and its history sharing.',
      inputSchema: {
        type: 'object',
        properties: { accountId: ACCOUNT_ID, refresh: { type: 'boolean', description: 'Ask the CLI again.' } },
        required: ['accountId'],
        additionalProperties: false,
      },
      summary: (args) => `Check ${named(deps, args)}`,
      run: async (args) => {
        const account = requireAccount(deps, str(args, 'accountId'))
        const signIn = await deps.signIn(account.id, optBool(args, 'refresh', false))
        return {
          value: withoutSecrets({
            account,
            status: deps.status(account.id),
            signIn,
            history: deps.history(account.id),
          }),
          summary: { accountId: account.id },
        }
      },
    },

    {
      id: 'accounts.create',
      wire: 'accounts_create',
      tier: 'alter',
      title: 'Add an agent account',
      description:
        'Add another account for a coding agent, so its sessions can run under a different login from the ' +
        'machine’s own. It starts signed out — call accounts.sign_in next. The person confirms it.',
      index: 'Add another login for a coding agent.',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'What it is called, e.g. Work.' },
          agent: { type: 'string', description: 'Which agent it is a login of. Default claude.' },
        },
        required: ['name'],
        additionalProperties: false,
      },
      summary: (args) => `Add a ${optStr(args, 'agent') ?? 'claude'} account called ${optStr(args, 'name') ?? '?'}`,
      precheck: (args) => {
        str(args, 'name')
      },
      run: async (args) => {
        const agent = optStr(args, 'agent')
        const created = deps.create(str(args, 'name'), agent === null ? {} : { provider: agent })
        return { value: withoutSecrets({ created }), summary: { agent } }
      },
    },

    {
      id: 'accounts.rename',
      wire: 'accounts_rename',
      tier: 'alter',
      title: 'Rename an agent account',
      description: 'Change the name an account is shown under. Its login and history are not touched.',
      index: 'Rename an agent account.',
      inputSchema: {
        type: 'object',
        properties: { accountId: ACCOUNT_ID, name: { type: 'string' } },
        required: ['accountId', 'name'],
        additionalProperties: false,
      },
      summary: (args) => `Rename ${named(deps, args)} to ${optStr(args, 'name') ?? '?'}`,
      precheck: (args) => {
        str(args, 'name')
      },
      run: async (args) => {
        const account = requireAccount(deps, str(args, 'accountId'))
        const renamed = deps.rename(account.id, str(args, 'name'))
        return { value: withoutSecrets({ renamed }), summary: { accountId: account.id } }
      },
    },

    {
      id: 'accounts.delete',
      wire: 'accounts_delete',
      tier: 'alter',
      title: 'Delete an agent account',
      description:
        'Remove an account from this app. Folders that used it as their default go back to the machine’s own ' +
        'login. With deleteFiles, its folder on disk goes too — its settings and any conversation history that ' +
        'is not shared — and the result says whether the login itself survived. The machine’s own login for an ' +
        'agent cannot be deleted. Call accounts.status first: its history sentence says what would be lost.',
      index: 'Delete an agent account, optionally with its files.',
      inputSchema: {
        type: 'object',
        properties: {
          accountId: ACCOUNT_ID,
          deleteFiles: { type: 'boolean', description: 'Also delete its folder on disk. Default false.' },
        },
        required: ['accountId'],
        additionalProperties: false,
      },
      /*
       * The sentence a person reads before saying yes, and it names what goes.
       *
       * With `deleteFiles` the pane shows `describeDelete` — how many folders of
       * history this account holds that nothing else can read — and the dialog
       * here says the same thing, because a confirmation that said "delete
       * account" over the loss of three projects' conversations would be asking
       * for consent to something smaller than what happens.
       */
      summary: (args) => {
        const files = args['deleteFiles'] === true
        let loses = ''
        if (files) {
          try {
            const id = optStr(args, 'accountId')
            if (id !== null) loses = ` ${deps.history(id).remove}`
          } catch {
            loses = ''
          }
        }
        return `Delete ${named(deps, args)}${files ? ' and its files on disk.' : ' (its files stay on disk).'}${loses}`
      },
      run: async (args) => {
        const account = requireAccount(deps, str(args, 'accountId'))
        const result = deps.remove(account.id, { deleteFiles: optBool(args, 'deleteFiles', false) })
        return { value: withoutSecrets({ accountId: account.id, result }), summary: { accountId: account.id } }
      },
    },

    {
      id: 'accounts.set_default',
      wire: 'accounts_set_default',
      tier: 'alter',
      title: 'Choose the default account',
      description:
        'Choose which account new sessions run as — everywhere, or (with projectPath) only in one open folder. ' +
        'Pass no accountId to go back to the machine’s own login (everywhere), or to clear the folder’s choice ' +
        'so it follows the general default. Running sessions are not moved.',
      index: 'Choose which account new sessions use, everywhere or in one folder.',
      inputSchema: {
        type: 'object',
        properties: {
          accountId: { type: 'string', description: 'Omit to clear the choice.' },
          projectPath: { type: 'string', description: 'An open folder. Omit for the default everywhere.' },
        },
        additionalProperties: false,
      },
      summary: (args) => {
        const where = optStr(args, 'projectPath')
        const who = optStr(args, 'accountId') === null ? 'the default login' : named(deps, args)
        return where === null ? `Make ${who} the default for new sessions` : `Make ${who} the default in ${where}`
      },
      run: async (args, context) => {
        const id = optStr(args, 'accountId')
        if (id !== null) requireAccount(deps, id)
        const project = optStr(args, 'projectPath')
        const state =
          project === null
            ? deps.setDefault(id)
            : deps.setProjectDefault(requireKnownFolder(context.surface, project), id)
        return { value: withoutSecrets({ accounts: state }), summary: { accountId: id, projectPath: project } }
      },
    },

    {
      id: 'accounts.sign_in',
      wire: 'accounts_sign_in',
      tier: 'alter',
      title: 'Sign an agent account in',
      description:
        'Start a session on this account in an open folder so its agent runs its own sign-in. The agent prints a ' +
        'link (and sometimes a code) to open in a browser and waits: read it off the session with the session ' +
        'tools and give it to the person, who finishes signing in there. Nothing here sees the password or the ' +
        'token — the agent keeps them. Then accounts.status says whether it worked. The person confirms the ' +
        'start, because the session runs under that login.',
      index: 'Start a session on an account so its agent shows a sign-in link.',
      inputSchema: {
        type: 'object',
        properties: {
          accountId: ACCOUNT_ID,
          folder: { type: 'string', description: 'An open folder to run the session in. See projects.list.' },
        },
        required: ['accountId', 'folder'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        signInFolder(context, str(args, 'folder'))
      },
      summary: (args) => `Start a session in ${optStr(args, 'folder') ?? '?'} to sign in ${named(deps, args)}`,
      run: async (args, context) => {
        const account = requireAccount(deps, str(args, 'accountId'))
        const { cwd, device } = signInFolder(context, str(args, 'folder'))
        const input: CreateSessionInput = {
          cwd,
          cols: START_COLS,
          rows: START_ROWS,
          provider: account.provider as ProviderId,
          profileId: account.id,
          ...sessionOriginFor(context.caller),
          originRunId: context.callId,
        }
        const meta = await context.surface.startSession(input, device ?? undefined)
        // Started by this run, so reading and typing the sign-in answers into
        // it stays an ordinary action rather than a dialog per keystroke.
        context.noteStarted(meta.id)
        return {
          value: {
            sessionId: meta.id,
            accountId: account.id,
            next:
              'the agent is starting in that session. Its sign-in link appears on its screen within a few ' +
              'seconds; read the screen, then hand the link to the person.',
          },
          summary: { sessionId: meta.id, accountId: account.id },
        }
      },
    },

    {
      id: 'accounts.sign_out',
      wire: 'accounts_sign_out',
      tier: 'alter',
      title: 'Sign an agent account out',
      description:
        'Run the agent’s own logout for this account, then check that it really took. Sessions already running ' +
        'under it are not stopped. Some agents have no logout command; the answer says so.',
      index: 'Sign an agent account out.',
      inputSchema: idOnly,
      summary: (args) => `Sign out ${named(deps, args)}`,
      run: async (args) => {
        const account = requireAccount(deps, str(args, 'accountId'))
        const answer = await deps.signOut(account.id)
        return {
          value: { accountId: account.id, ok: answer.ok, message: answer.message },
          summary: { accountId: account.id, ok: answer.ok },
        }
      },
    },

    {
      id: 'accounts.share_history',
      wire: 'accounts_share_history',
      tier: 'alter',
      title: 'Share an account’s conversation history',
      description:
        'Share this account’s conversation history with the machine’s own login, so either one can resume the ' +
        'other’s conversations in a folder — or, with share false, stop sharing and give it its own copy again. ' +
        'accounts.status shows the current state and the sentence for each direction.',
      index: 'Share or stop sharing an account’s conversation history.',
      inputSchema: {
        type: 'object',
        properties: { accountId: ACCOUNT_ID, share: { type: 'boolean', description: 'true to share, false to stop.' } },
        required: ['accountId', 'share'],
        additionalProperties: false,
      },
      summary: (args) => {
        const share = args['share'] !== false
        let said = ''
        try {
          const id = optStr(args, 'accountId')
          if (id !== null) {
            const history = deps.history(id)
            said = ` ${share ? history.share : history.unshare}`
          }
        } catch {
          said = ''
        }
        return `${share ? 'Share' : 'Stop sharing'} the conversation history of ${named(deps, args)}.${said}`
      },
      run: async (args) => {
        const account = requireAccount(deps, str(args, 'accountId'))
        const share = optBool(args, 'share', true)
        const result = share ? deps.share(account.id) : deps.unshare(account.id)
        return { value: withoutSecrets({ accountId: account.id, shared: share, result }), summary: { accountId: account.id, share } }
      },
    },
  ]
}
