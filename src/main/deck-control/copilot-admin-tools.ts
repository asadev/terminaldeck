/**
 * The copilot's own management — start it, stop it, read and edit what it is
 * told and what it remembers — plus three small doors a person uses from
 * Settings: the tool server's own status, whether notifications reach them, and
 * opening a link in the Mac's own browser.
 *
 * ## Why an AI in another app may manage the copilot at all
 *
 * Because Asad asked for everything he can do by hand, and Settings → Copilot
 * is a page of things he does by hand. Each is the same function the page's
 * channel calls (`copilot-session.ts`, `copilot-inspect.ts`), and each is tiered
 * by what it changes: reading is free, starting it is ordinary work, and editing
 * its instructions, deleting a memory or stopping it is confirmed — the
 * instructions *are* the agent, and a copilot that answers differently next week
 * is a thing somebody will try to explain.
 *
 * ## What is deliberately not here
 *
 *  - **Choosing the copilot's folder.** `copilot.home` is under `copilot.`, which
 *    `catalogue.ts` refuses to every tool however a person answers — it decides
 *    where the agent runs, and a permission an agent can edit is a suggestion.
 *    Reading which folder it is in is fine and is in `hoot.state`.
 *  - **Reading the action log.** `confine/records.ts` fences it from the copilot
 *    on purpose — *"a record of what something did is worth nothing if that same
 *    thing can compose it"*, and being able to check which actions were recorded,
 *    in what words, is the first move toward shaping behaviour around a record.
 *    A tool that read it back would hand every caller, the copilot included, the
 *    one thing that fence exists to withhold. The person reads it in Activity.
 *
 * Nothing here returns a credential. The sign-in answer is a state, an account
 * name and a plan, which is what the pane draws.
 */

import { BadArgument, optBool, optInt, optStr, str, type ToolSpec } from './catalogue'
import { BRAND } from '../../shared/brand'

/* -------------------------------------------------------------- the deps -- */

export type InstructionsWhich = 'yours' | 'folder' | 'contract' | 'composed'

export interface CopilotAdminDeps {
  copilot: {
    /** `copilotState(deps)` — status, folder, files, profile. No secrets. */
    state(): unknown
    /** `readCopilotSignIn(deps)` — signed in or out, the account name, the plan. */
    signIn(): Promise<unknown>
    /** `ensureCopilot(deps)` — start it if it is not running. */
    start(): Promise<unknown>
    /** `stopCopilot(deps)`. */
    stop(): unknown
    /** `scaffoldCopilotHome` — write the folder and its starter files, nothing else. */
    scaffold(): unknown
    /** `revealCopilotPlace` — open one of its places in Finder. */
    reveal(place: string): Promise<{ opened: boolean; path: string | null; message: string }>
    instructions: {
      read(which: InstructionsWhich): unknown
      write(which: 'yours' | 'folder', text: string): unknown
      reset(): unknown
    }
    memory: {
      list(): unknown
      read(name: string): unknown
      write(name: string, text: string): unknown
      delete(name: string): unknown
    }
  }
  /** `deckControlStatus` over the live handle, or null before the server is up. */
  status(): unknown
  notifications: {
    /** `notificationSupport()` — whether the pane and the delivery read exist here. */
    support(): unknown
    /** `notificationDelivery(since)` — did banners actually reach the screen. */
    delivery(sinceMs: number): Promise<unknown>
    /** `openNotificationSettings()` — the system pane for this app. */
    openSettings(): Promise<unknown>
  }
  /** `openSystemUrl` — the Mac's own default browser. False when the URL is refused. */
  openUrl(url: string): boolean
}

/** The places `copilot:reveal` knows. Kept in step with `PLACE_KIND` by the deps' own answer. */
const PLACES = ['root', 'instructions', 'memory', 'log', 'routines', 'layer', 'contract', 'composed'] as const

/* ----------------------------------------------------------------- tools -- */


export function copilotAdminTools(deps: CopilotAdminDeps): ToolSpec[] {
  return [
    {
      id: 'hoot.state',
      wire: 'hoot_state',
      /*
       * The names these four had before the assistant was called Hoot. Outside
       * AI apps read tool names, so they follow the rename; but an app or a
       * routine set up the day before must not start failing with "no such
       * tool", so both old spellings keep answering for one release, unlisted
       * (`ToolSpec.aliases`). Delete the four `aliases` lines in the release
       * after 0.16.x.
       */
      aliases: ['copilot.state', 'copilot_state'],
      tier: 'read',
      title: `${BRAND.assistant}’s state`,
      index: `Whether ${BRAND.assistant} is running, signed in, which folder and account it uses, and its files.`,
      description:
        `${BRAND.assistant}, the assistant built into this app (pinned at the top of the sidebar): whether it is running and its session id, ` +
        'whether it is signed in and as which account and plan, the folder it works in (and why, if a chosen ' +
        'folder could not be used), its startup files and whether its instructions are the default.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => `Read ${BRAND.assistant}’s state`,
      run: async () => ({
        value: { state: deps.copilot.state(), signIn: await deps.copilot.signIn() },
        summary: {},
      }),
    },

    {
      id: 'hoot.run',
      wire: 'hoot_run',
      aliases: ['copilot.run', 'copilot_run'],
      tier: 'act',
      title: `Start, stop or set up ${BRAND.assistant}`,
      index: `Start or stop ${BRAND.assistant}, create its folder and starter files, or open one of its places in Finder.`,
      description:
        `"start" starts ${BRAND.assistant} if it is not running (it spends money like any agent session). "stop" ends ` +
        `its session — confirmed, and if you ARE ${BRAND.assistant} it ends you. "scaffold" writes its folder and ` +
        'starter files without starting it, so they can be read first. "reveal" opens one of its places in ' +
        `Finder on this Mac: ${PLACES.join(', ')}. A changed instruction file takes effect at the next start.`,
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['start', 'stop', 'scaffold', 'reveal'] },
          place: { type: 'string', enum: [...PLACES], description: 'For "reveal".' },
        },
        required: ['action'],
        additionalProperties: false,
      },
      escalate: (args) => (optStr(args, 'action') === 'stop' ? 'alter' : 'act'),
      precheck: (args) => {
        const action = runAction(args)
        if (action === 'reveal') str(args, 'place')
      },
      summary: (args) => {
        switch (optStr(args, 'action')) {
          case 'start':
            return `Start ${BRAND.assistant}`
          case 'stop':
            return `Stop ${BRAND.assistant}`
          case 'scaffold':
            return `Create ${BRAND.assistant}’s folder and starter files`
          default:
            return `Open ${BRAND.assistant}’s ${optStr(args, 'place') ?? '?'} in Finder`
        }
      },
      run: async (args) => {
        const action = runAction(args)
        if (action === 'start') return { value: { state: await deps.copilot.start() }, summary: { action } }
        if (action === 'stop') return { value: { state: deps.copilot.stop() }, summary: { action } }
        if (action === 'scaffold') return { value: deps.copilot.scaffold(), summary: { action } }
        const revealed = await deps.copilot.reveal(str(args, 'place'))
        return { value: revealed, summary: { action, opened: revealed.opened } }
      },
    },

    {
      id: 'hoot.instructions',
      wire: 'hoot_instructions',
      aliases: ['copilot.instructions', 'copilot_instructions'],
      tier: 'read',
      title: `What ${BRAND.assistant} is told`,
      index: `Read or change ${BRAND.assistant}’s instructions — yours, its folder’s, the generated part, or all composed.`,
      description:
        `${BRAND.assistant}’s instructions, the same four the Settings pane shows. "read" with \`which\`: "yours" (the ` +
        'part the person edits), "folder" (the working folder’s own instructions file), "contract" (generated from what ' +
        'is wired — read only), "composed" (everything it was handed at its last start). "write" replaces ' +
        '"yours" or "folder" with `text`; the previous file is kept beside it. "reset" puts this build’s default ' +
        `wording back. Writes are confirmed, and reach ${BRAND.assistant} only at its next start.`,
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['read', 'write', 'reset'] },
          which: { type: 'string', enum: ['yours', 'folder', 'contract', 'composed'] },
          text: { type: 'string', description: 'For "write": the whole new file.' },
        },
        required: ['action'],
        additionalProperties: false,
      },
      escalate: (args) => (optStr(args, 'action') === 'read' ? 'read' : 'alter'),
      precheck: (args) => {
        instructionsCall(args)
      },
      summary: (args) => {
        const action = optStr(args, 'action')
        const which = optStr(args, 'which') ?? 'yours'
        if (action === 'write') {
          return `Replace ${BRAND.assistant}’s ${which === 'folder' ? 'folder' : 'own'} instructions (${typeof args.text === 'string' ? args.text.length : 0} characters)`
        }
        if (action === 'reset') return `Put ${BRAND.assistant}’s instructions back to this build’s default`
        return `Read ${BRAND.assistant}’s ${which} instructions`
      },
      run: async (args) => {
        const call = instructionsCall(args)
        if (call.action === 'read') return { value: deps.copilot.instructions.read(call.which), summary: call }
        if (call.action === 'reset') return { value: deps.copilot.instructions.reset(), summary: call }
        return {
          value: deps.copilot.instructions.write(call.which as 'yours' | 'folder', call.text),
          summary: { action: call.action, which: call.which, chars: call.text.length },
        }
      },
    },

    {
      id: 'hoot.memory',
      wire: 'hoot_memory',
      aliases: ['copilot.memory', 'copilot_memory'],
      tier: 'read',
      title: `What ${BRAND.assistant} remembers`,
      index: `List, read, write or delete ${BRAND.assistant}’s remembered facts.`,
      description:
        `${BRAND.assistant}’s memory: one small file per remembered fact, in its memory folder. "list" names them, ` +
        '"read" returns one, "write" saves one (a new name creates it), "delete" removes one — confirmed. A name ' +
        'is a plain file name with no folders in it.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['list', 'read', 'write', 'delete'] },
          name: { type: 'string' },
          text: { type: 'string', description: 'For "write".' },
        },
        required: ['action'],
        additionalProperties: false,
      },
      escalate: (args) => {
        const action = optStr(args, 'action')
        return action === 'delete' ? 'alter' : action === 'write' ? 'act' : 'read'
      },
      precheck: (args) => {
        memoryCall(args)
      },
      summary: (args) => {
        const name = optStr(args, 'name') ?? '?'
        switch (optStr(args, 'action')) {
          case 'read':
            return `Read ${BRAND.assistant}’s memory “${name}”`
          case 'write':
            return `Save ${BRAND.assistant}’s memory “${name}”`
          case 'delete':
            return `Delete ${BRAND.assistant}’s memory “${name}”`
          default:
            return `List what ${BRAND.assistant} remembers`
        }
      },
      run: async (args) => {
        const call = memoryCall(args)
        switch (call.action) {
          case 'list':
            return { value: deps.copilot.memory.list(), summary: { action: call.action } }
          case 'read':
            return { value: deps.copilot.memory.read(call.name), summary: { action: call.action, name: call.name } }
          case 'write':
            return {
              value: deps.copilot.memory.write(call.name, call.text),
              summary: { action: call.action, name: call.name, chars: call.text.length },
            }
          case 'delete':
            return { value: deps.copilot.memory.delete(call.name), summary: { action: call.action, name: call.name } }
        }
      },
    },

    {
      id: 'tools.status',
      wire: 'tools_status',
      tier: 'read',
      title: 'This tool server’s status',
      index: 'This tool server: its tools and tiers, how many confirmations are waiting, whether the log is written.',
      description:
        'The state of this tool server: every tool and its tier, what the listing costs in tokens, how many ' +
        `confirmations are waiting for a person right now, which sessions ${BRAND.assistant} started, and whether the ` +
        'action log is actually being written. Never a token or a key.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Read the tool server’s status',
      run: async () => {
        const status = deps.status()
        return {
          value: status ?? { running: false, note: 'The tool server has not finished starting.' },
          summary: {},
        }
      },
    },

    {
      id: 'notifications.status',
      wire: 'notifications_status',
      tier: 'read',
      title: 'Do notifications reach the person',
      index: 'Whether this app’s banners actually reach the person’s screen; can open the system notification settings.',
      description:
        'Whether this app’s notification banners actually reached the screen recently (read from macOS’s own ' +
        'record where it can be), and whether the system pane for them exists here. Set `openSettings` to open ' +
        'that pane on this Mac — for the person to change, since nothing here changes system settings.',
      inputSchema: {
        type: 'object',
        properties: {
          sinceMinutes: { type: 'integer', description: 'How far back to look. Default 60, max 10080.' },
          openSettings: { type: 'boolean' },
        },
        additionalProperties: false,
      },
      escalate: (args) => (optBool(args, 'openSettings', false) ? 'act' : 'read'),
      summary: (args) =>
        optBool(args, 'openSettings', false)
          ? 'Open the system notification settings for this app'
          : 'Check whether notifications reach the person',
      run: async (args, context) => {
        const sinceMs = context.now() - optInt(args, 'sinceMinutes', 60, 1, 10_080) * 60_000
        const opened = optBool(args, 'openSettings', false) ? await deps.notifications.openSettings() : undefined
        return {
          value: {
            support: deps.notifications.support(),
            delivery: await deps.notifications.delivery(sinceMs),
            ...(opened === undefined ? {} : { opened }),
          },
          summary: { opened: opened !== undefined },
        }
      },
    },

    {
      id: 'links.open',
      wire: 'links_open',
      tier: 'act',
      title: 'Open a link in the Mac’s browser',
      index: 'Open a web link in this Mac’s own default browser (not the in-app one — use browser.open for that).',
      description:
        'Open a web address in this Mac’s own default browser, the way "Open in your browser" does. Only http ' +
        'and https. For a page you want to read or drive, use browser.open, which opens it inside the app.',
      inputSchema: {
        type: 'object',
        properties: { url: { type: 'string' } },
        required: ['url'],
        additionalProperties: false,
      },
      precheck: (args) => {
        webAddress(args)
      },
      summary: (args) => `Open ${optStr(args, 'url') ?? '?'} in the Mac’s browser`,
      run: async (args) => {
        const url = webAddress(args)
        if (!deps.openUrl(url)) throw new BadArgument(`${url} could not be opened outside the app`)
        return { value: { url, opened: true }, summary: { url } }
      },
    },
  ]
}

/* --------------------------------------------------------------- helpers -- */

function runAction(args: Record<string, unknown>): 'start' | 'stop' | 'scaffold' | 'reveal' {
  const action = str(args, 'action')
  if (action === 'start' || action === 'stop' || action === 'scaffold' || action === 'reveal') return action
  throw new BadArgument('action must be "start", "stop", "scaffold" or "reveal"')
}

type InstructionsCall =
  | { action: 'read'; which: InstructionsWhich }
  | { action: 'write'; which: 'yours' | 'folder'; text: string }
  | { action: 'reset' }

function instructionsCall(args: Record<string, unknown>): InstructionsCall {
  const action = str(args, 'action')
  const which = optStr(args, 'which') ?? 'yours'
  if (action === 'reset') return { action }
  if (action === 'read') {
    if (which === 'yours' || which === 'folder' || which === 'contract' || which === 'composed') return { action, which }
    throw new BadArgument('which must be "yours", "folder", "contract" or "composed"')
  }
  if (action === 'write') {
    if (which !== 'yours' && which !== 'folder') {
      throw new BadArgument('only "yours" and "folder" can be written; the contract is generated from what is wired')
    }
    const text = args.text
    if (typeof text !== 'string' || text.trim() === '') throw new BadArgument('text is required for "write"')
    return { action, which, text }
  }
  throw new BadArgument('action must be "read", "write" or "reset"')
}

type MemoryCall =
  | { action: 'list' }
  | { action: 'read' | 'delete'; name: string }
  | { action: 'write'; name: string; text: string }

function memoryCall(args: Record<string, unknown>): MemoryCall {
  const action = str(args, 'action')
  if (action === 'list') return { action }
  if (action === 'read' || action === 'delete') return { action, name: str(args, 'name') }
  if (action === 'write') {
    const text = args.text
    if (typeof text !== 'string' || text.trim() === '') throw new BadArgument('text is required for "write"')
    return { action, name: str(args, 'name'), text }
  }
  throw new BadArgument('action must be "list", "read", "write" or "delete"')
}

function webAddress(args: Record<string, unknown>): string {
  const url = str(args, 'url').trim()
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new BadArgument('url must be a full web address, like https://example.com')
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new BadArgument('only http and https links are opened this way')
  }
  return parsed.toString()
}
