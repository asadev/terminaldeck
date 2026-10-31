import {
  everywhere,
  missingApis,
  reachOf,
  usesStaticRulesets,
} from '../browser-extension-support'
import type { ExtensionResult, InstalledExtension, StoreExtension } from '../browser-extensions'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { STORE_PLACE } from './store-tools'
import { Refused, type Tier } from './surface'

/**
 * `browser.extensions` — what is running in the browser a session is driving,
 * and the switch for it.
 *
 * ## What *"use there with session ai"* can honestly mean
 *
 *   > *"extensions store needs to be a proper store from where we can see most
 *   > famous open source tools to attach to the browser and use there with
 *   > session ai."*
 *
 * The tempting reading is a tool per extension — `darkreader.toggle`,
 * `ublock.whitelist` — and it is wrong for a reason that is not about budget.
 * **An extension exposes no interface to the outside.** `chrome.runtime`
 * messaging is between an extension's own contexts and, with `externally_connectable`,
 * pages the extension itself has named; there is no channel from an Electron app
 * into a third-party extension's message handlers, and no manifest in the
 * catalogue names one. A tool called `darkreader.toggle` would have to drive the
 * extension's popup UI by simulating clicks in it — a control that works until
 * the extension's next release moves a button, which is the definition of a
 * surface that looks like it works and does not.
 *
 * So this tool does the two things an extension genuinely can answer, and stops:
 *
 *  1. **Which are on.** An agent driving a page needs this the way it needs to
 *     know whether the browser is signed in. A content blocker changes what a
 *     page contains; Dark Reader rewrites every computed colour on it; ClearURLs
 *     changes the URL a click actually requests. An agent that reads a page
 *     without knowing those are running will report the extension's output as
 *     the site's, and will be confidently wrong about a colour, a missing
 *     element or a stripped parameter it never saw.
 *  2. **Turn one on or off for a run.** This is real: switching off calls
 *     `removeExtension`, which stops the program immediately, and switching on
 *     loads it again — see `browser-extensions-ipc.ts`. It is the honest form of
 *     "use it": *this run needs the page as the site actually sends it*, or
 *     *this run wants the blocker on*.
 *
 * ## Why the switch is `alter` and not `act`
 *
 * Turning an extension off changes what every page in that profile does for
 * everybody using the window, and it outlives the run — the state is written to
 * `installed.json`, because the alternative is a switch that silently flips back
 * and a person who cannot tell why their blocker keeps returning. A change that
 * persists and that somebody else can see is not this run's business alone, so it
 * goes through the gate rather than around it.
 *
 * ## What it did not do until 0.16.0, and what it does now
 *
 * It would not install or remove. The argument was that an install downloads
 * and unpacks a program that then runs on every page of a profile, so it was a
 * decision for the person whose profile it is, at the panel. Asad's answer for
 * this release is the one he gave for everything — *"Everything that I can do
 * manually should be able to do through the MCP"* — and the argument survives as
 * a tier rather than as an absence: **every** change to what is installed is
 * `alter`, so a person reads which extension, in which profile, before it
 * happens, every time. The actions are the panel's own buttons, each calling the
 * same function in `browser-extensions-ipc.ts`: install from the catalogue,
 * remove, reload and rename one you added, open its panel or its settings page,
 * and **add your own** from a folder or a packed file.
 *
 * Add your own keeps the one rule that made it safe at the panel: the path is
 * never an argument. The action opens the same native chooser on this Mac and
 * the person picks the folder, because a path arriving from a caller is a string
 * something composed, and this one is about to be run as a program on every page
 * of a profile.
 *
 * What it still cannot do is drive an extension's own interface. Not a limit of
 * this tool: there is no channel from an Electron app into a third-party
 * extension's message handlers at all, and none of these manifests declares one.
 * Opening its popup or settings page puts that page on the Mac's screen for the
 * person; nothing here reads or clicks it.
 *
 * ## What a session may ask about, and what it may not
 *
 * This tool is on {@link SESSION_TOOLS} as of 2026-08-22, so a session — here or
 * on a server over the relay — can list and switch. One narrowing, applied
 * here rather than at the gate: **a session may not name a `profile`.** It gets
 * the one that is switched on, which is the browser it is driving; the copilot
 * at the desk keeps the argument.
 *
 * The reason is the one `boundOf` gives about windows. A session resolves
 * everything inside its own binding, and a list of what is installed in every
 * profile somebody keeps — which is a list of the separations they went to the
 * trouble of making — is not something a shell on a Linux box needs in order to
 * read a page. Refusing the argument rather than filtering the answer is
 * deliberate: a filtered answer teaches a model to keep trying names, and a
 * refusal that names the working call does not.
 *
 * So, plainly, for the *"use there with session ai"* half:
 *
 *  - **A session can see** every extension installed in the profile it is
 *    driving, catalogue rows and ones the person added themselves alike, what
 *    each reaches, whether it is running, and what about it this browser cannot
 *    carry.
 *  - **A session can switch one off and back on**, which is how it gets a page
 *    as the site actually sends it.
 *  - **A session cannot install, remove, reload, rename, add one, or open an
 *    extension's window.** Those arrived for the copilot in 0.16.0 and stop at
 *    the copilot: a shell on a Linux box has no business putting a program into
 *    the browser on somebody's Mac, and the refusal says so.
 *  - **A session cannot drive an extension's own interface.** Not a limit of
 *    this tool: there is no channel from an Electron app into a third-party
 *    extension's message handlers at all, and none of these manifests declares
 *    one. `darkreader.toggle` would have to be a robot clicking that
 *    extension's popup, which works until its next release moves a button.
 */

export interface ExtensionToolDeps {
  /** Every installed extension in a profile. Asked per call, never snapshotted. */
  installed(profileId: string): InstalledExtension[]
  /** Is it loaded into the live session right now? */
  isLoaded(profileId: string, id: string): boolean
  /** The profile switched on, when the caller names none. */
  currentProfileId(): string
  /** That profile's name, for a sentence. */
  profileName(profileId: string): string
  /** Turn one on or off, on disk and in the session. */
  setEnabled(profileId: string, id: string, on: boolean): Promise<ExtensionResult>
  /*
   * The panel's other buttons, since 0.16.0. Optional so a build that wires
   * only the two original verbs still compiles and says, per action, that this
   * build cannot do it — never a control that answers success for nothing.
   */
  /** Every row the store can show for a profile: the catalogue plus what was added by hand. */
  catalogue?(profileId: string): StoreExtension[]
  install?(profileId: string, id: string): Promise<ExtensionResult>
  remove?(profileId: string, id: string): ExtensionResult
  reload?(profileId: string, id: string): Promise<ExtensionResult>
  rename?(profileId: string, id: string, name: string): ExtensionResult
  openWindow?(profileId: string, id: string, which: 'popup' | 'options'): Promise<ExtensionResult>
  /** Open the native chooser for the person, and add what they pick. */
  addOwn?(profileId: string, kind: 'folder' | 'crx'): Promise<ExtensionResult>
  /** Every profile, so one can be named by its name. */
  profiles?(): { id: string; name: string }[]
}

/** One extension as an agent reads it. */
export interface ExtensionListing {
  extension: string
  name: string
  on: boolean
  /** What it may reach, in its manifest's own patterns. */
  reach: string[]
  /** True when its content scripts run on every page. */
  onEveryPage: boolean
  /** What it changes about a page, when that is worth an agent knowing. */
  note: string
}

/**
 * The sentence an agent needs about one extension, or `''`.
 *
 * Written from the **manifest**, never from the catalogue's prose, so it stays
 * true of what is actually on the disk. Two things earn a sentence: an extension
 * whose content scripts run everywhere is altering pages this agent will read,
 * and an extension asking for `chrome.*` this browser does not have is one whose
 * behaviour will not match its documentation.
 */
export function noteFor(extension: InstalledExtension): string {
  const parts: string[] = []
  if (everywhere(extension.manifest)) {
    parts.push('Its content scripts run on every page, so what you read may be its output')
  }
  const gaps = missingApis(extension.manifest)
  if (gaps.length > 0) {
    parts.push(
      `it asks for ${gaps.map((api) => `chrome.${api}`).join(', ')}, which this browser does not have`,
    )
  }
  if (usesStaticRulesets(extension.manifest)) {
    parts.push(
      'its rules ship as manifest declarativeNetRequest rulesets, which this browser does not switch on',
    )
  }
  if (parts.length === 0) return ''
  return `${parts.join('; ')}.`
}

export function listExtensions(
  deps: ExtensionToolDeps,
  profileId: string,
): ExtensionListing[] {
  return deps.installed(profileId).map((extension) => ({
    extension: extension.entry.id,
    name: extension.entry.name,
    on: deps.isLoaded(profileId, extension.entry.id),
    reach: reachOf(extension.manifest),
    onEveryPage: everywhere(extension.manifest),
    note: noteFor(extension),
  }))
}

/**
 * What this tool can be asked to do. `list` and `switch` are the two it always
 * had, and they keep their old spelling: no `action`, with or without an
 * `extension`, means exactly what it meant before.
 */
const ACTIONS = [
  'list',
  'switch',
  'catalogue',
  'install',
  'remove',
  'reload',
  'rename',
  'popup',
  'options',
  'addfolder',
  'addcrx',
] as const
type Action = (typeof ACTIONS)[number]

/*
 * Everything that changes what is installed, or what it is called, is `alter`.
 * Opening an extension's own window is `act`: it puts a page on the screen for
 * the person and changes nothing.
 */
const TIERS: Readonly<Record<Action, Tier>> = {
  list: 'read',
  switch: 'alter',
  catalogue: 'read',
  install: 'alter',
  remove: 'alter',
  reload: 'alter',
  rename: 'alter',
  popup: 'act',
  options: 'act',
  addfolder: 'alter',
  addcrx: 'alter',
}

/** What a session may do — the two verbs it always had. See the header. */
const SESSION_ACTIONS: ReadonlySet<Action> = new Set(['list', 'switch'])

/** The action a call means, including the old spelling with no `action`. */
function actionFor(args: Record<string, unknown>): Action {
  const raw = args.action
  if (raw === undefined || raw === null || raw === '') {
    return optStr(args, 'extension') === null ? 'list' : 'switch'
  }
  if (typeof raw !== 'string' || !(ACTIONS as readonly string[]).includes(raw)) {
    throw new Refused('not-permitted', `action must be one of: ${ACTIONS.join(', ')}`)
  }
  return raw as Action
}

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: {
      type: 'string',
      enum: [...ACTIONS],
      description: 'Omit to list, or — with extension and on — to switch one.',
    },
    extension: {
      type: 'string',
      description: 'Which extension. Omit to list what is installed and what is on.',
    },
    name: { type: 'string', description: 'For rename: the new name.' },
    on: {
      type: 'boolean',
      description: 'True to switch it on, false to switch it off. Required when naming an extension.',
    },
    profile: {
      type: 'string',
      description: 'Which browser profile. Omit for the one switched on.',
    },
  },
  additionalProperties: false,
}

function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new Refused('not-permitted', `${key} must be a string`)
  return value
}

/** One store row as an agent reads it — what it is, what it reaches, and whether it is here. */
function catalogueRow(row: StoreExtension): Record<string, unknown> {
  return {
    extension: row.id,
    name: row.name,
    summary: row.summary,
    state: row.state,
    on: row.enabled,
    works: row.works,
    reach: row.reach,
    onEveryPage: row.everywhere,
    addedByHand: row.sideloaded,
    hasPanel: row.popup !== '',
    hasSettings: row.optionsPage !== '',
    licence: row.licence,
    ...(row.message === '' ? {} : { message: row.message }),
  }
}

export function extensionTools(deps: ExtensionToolDeps): ToolSpec[] {
  /*
   * A profile named by its id, or — when the profile list is wired — by its
   * name, since that is what a person says. An unknown name is passed through as
   * it always was, which lists nothing in it rather than guessing at a profile.
   */
  const profileIdFor = (named: string | null): string => {
    if (named === null) return deps.currentProfileId()
    const rows = deps.profiles?.() ?? []
    const wanted = named.trim().toLowerCase()
    return (
      rows.find((row) => row.id === named)?.id ??
      rows.find((row) => row.name.trim().toLowerCase() === wanted)?.id ??
      named
    )
  }

  /** Refused for a build that did not wire this action, in words, rather than a success for nothing. */
  const notWired = (what: string): never => {
    throw new Refused('not-permitted', `this build cannot ${what} from here`)
  }

  return [
    {
      id: 'browser.extensions',
      wire: 'browser_extensions',
      tier: 'read',
      title: 'The browser’s extensions',
      description:
        'The browser extensions in a profile (profile: a name or id; omit for the one switched on). With ' +
        'no action: list what is installed and whether each is running, or — with extension and on — ' +
        'switch one on or off. Read it before reading a page: an extension that runs on every page ' +
        'changes what that page contains, so a blocker, a dark-mode rewriter or a URL cleaner will ' +
        'otherwise be reported as the site’s own behaviour; switching one off is how you see a page as ' +
        'the site actually sends it. "catalogue" lists every extension the store offers. "install" ' +
        'downloads, verifies and turns one on; "remove" deletes one; "reload" copies one the person ' +
        'added in again from where it came from; "rename" renames one they added (name). "addfolder" and ' +
        '"addcrx" open the chooser on this Mac so the person picks an extension of their own to add. An ' +
        'extension is a program that runs on every page of the profile, so every one of those asks the ' +
        'person first. "popup" and "options" open an extension’s own panel or settings page on the screen. ' +
        'Nothing here can click inside an extension — there is no channel into another extension’s code. ' +
        // One door, one spelling: the same words the menu row wears, imported
        // from the tool that answers for the other half of the same store.
        `The same store is in ${STORE_PLACE}.`,
      index:
        'The browser’s extensions: see which are running (read before reading a page), switch, install, remove, add your own.',
      inputSchema: SCHEMA,

      /*
       * Listing is a read; everything that changes what is installed persists
       * and everybody in the window sees it. Only ever upwards, which is what
       * `control.ts` does with this — a call with no `extension` stays at
       * `read` and costs nobody a dialog, and an action this has never heard of
       * reads as `alter` before the run refuses it by name.
       */
      escalate: (args): Tier => {
        try {
          return TIERS[actionFor(args)]
        } catch {
          return 'alter'
        }
      },

      summary(args: Record<string, unknown>): string {
        const id = optStr(args, 'extension')
        const profile = optStr(args, 'profile')
        const where = profile === null ? 'the current profile' : `profile ${profile}`
        let action: Action
        try {
          action = actionFor(args)
        } catch {
          return `Change the browser extensions in ${where}`
        }
        switch (action) {
          case 'list':
            return `List the browser extensions in ${where}`
          case 'catalogue':
            return `List the extension store for ${where}`
          case 'switch':
            return `Switch ${id ?? '?'} ${args.on === true ? 'on' : 'off'} in ${where}`
          case 'install':
            return `Install the browser extension ${id ?? '?'} in ${where} — it will run on the pages it asks for`
          case 'remove':
            return `Remove the browser extension ${id ?? '?'} from ${where}`
          case 'reload':
            return `Copy ${id ?? '?'} in again from where it was added, and restart it, in ${where}`
          case 'rename':
            return `Rename ${id ?? '?'} to ${optStr(args, 'name') ?? '?'} in ${where}`
          case 'popup':
            return `Open ${id ?? '?'}'s panel`
          case 'options':
            return `Open ${id ?? '?'}'s settings page`
          case 'addfolder':
            return `Ask the person to pick an extension folder to add to ${where} — it will run as a program in that profile`
          case 'addcrx':
            return `Ask the person to pick a packed extension to add to ${where} — it will run as a program in that profile`
        }
      },

      run: async (args: Record<string, unknown>, context: ToolContext): Promise<ToolOutput> => {
        const named = optStr(args, 'profile')
        const action = actionFor(args)
        /*
         * A session gets the browser it is driving and no other, and only the
         * two verbs it always had. See this file's header: the narrowing is the
         * tool's, not the gate's, because the gate cannot tell one argument from
         * another.
         */
        if (context.caller?.kind === 'session') {
          if (named !== null) {
            throw new Refused(
              'not-permitted',
              'a session can only ask about the browser profile that is switched on. Call this tool ' +
                'with no profile.',
            )
          }
          if (!SESSION_ACTIONS.has(action)) {
            throw new Refused(
              'not-permitted',
              'a session can list the extensions and switch one on or off. Installing, removing and adding ' +
                `them is done by the person, in ${STORE_PLACE}.`,
            )
          }
        }
        const profileId = profileIdFor(named)
        const profileName = deps.profileName(profileId)
        const id = optStr(args, 'extension')

        if (action === 'list') {
          const extensions = listExtensions(deps, profileId)
          /*
           * An empty list is a real answer and is not allowed to read as a
           * failure. `store-tools.ts` makes the same point about its own listing
           * call: the door *"is not allowed to look open when nothing came
           * through it"*, and the way it stays honest is a sentence naming where
           * somebody would install one.
           */
          return {
            value: {
              profile: profileId,
              profileName,
              extensions,
              note:
                extensions.length === 0
                  ? `No extensions are installed in ${profileName}. ` +
                    (context.caller?.kind === 'session'
                      ? `They are installed by hand, in ${STORE_PLACE}.`
                      : `They are installed in ${STORE_PLACE}, or with action "install" here — "catalogue" lists what can be.`)
                  : '',
            },
            summary: {
              profile: profileId,
              installed: extensions.length,
              on: extensions.filter((one) => one.on).length,
            },
          }
        }

        if (action === 'catalogue') {
          if (!deps.catalogue) return notWired('list the extension store')
          const rows = deps.catalogue(profileId).map(catalogueRow)
          return {
            value: { profile: profileId, profileName, extensions: rows },
            summary: { profile: profileId, rows: rows.length },
          }
        }

        if (action === 'addfolder' || action === 'addcrx') {
          if (!deps.addOwn) return notWired('add an extension')
          if (context.attended === false) {
            throw new Refused(
              'not-permitted-unattended',
              'adding your own extension opens a chooser for the person at this Mac, and nobody is there',
            )
          }
          const result = await deps.addOwn(profileId, action === 'addfolder' ? 'folder' : 'crx')
          if (!result.ok) throw new Refused('not-permitted', result.message)
          return {
            value: {
              profile: profileId,
              profileName,
              added: result.message !== '',
              message: result.message === '' ? 'The person closed the chooser without picking anything.' : result.message,
              extensions: listExtensions(deps, profileId),
            },
            summary: { profile: profileId, added: result.message !== '' },
          }
        }

        if (id === null) {
          throw new Refused('not-permitted', `${action} needs extension: which one. Call this tool with no action to list them.`)
        }

        if (action === 'install') {
          if (!deps.install) return notWired('install an extension')
          const result = await deps.install(profileId, id)
          if (!result.ok) throw new Refused('not-permitted', result.message)
          return {
            value: { profile: profileId, profileName, extension: id, installed: true, on: deps.isLoaded(profileId, id), message: result.message },
            summary: { profile: profileId, extension: id, on: deps.isLoaded(profileId, id) },
          }
        }

        const known = deps.installed(profileId).some((one) => one.entry.id === id)
        if (!known) {
          /*
           * Named rather than a bare "no": the refusal a model gets has to teach
           * it the call that would have worked, which here is the listing call.
           */
          throw new Refused(
            'not-permitted',
            `${id} is not installed in ${profileName}. Call this tool with no extension to see what is.`,
          )
        }

        if (action === 'switch') {
          if (typeof args.on !== 'boolean') {
            throw new Refused('not-permitted', 'on must be true or false when you name an extension')
          }
          const result = await deps.setEnabled(profileId, id, args.on)
          if (!result.ok) throw new Refused('not-permitted', result.message)
          /*
           * The answer is re-read from the live session rather than assumed from
           * the call returning ok. A tool that reports `on: true` because nothing
           * threw is reporting its own intention, and the whole reason this tool
           * exists is that an agent needs to know what is *actually* running.
           */
          return {
            value: {
              profile: profileId,
              profileName,
              extension: id,
              on: deps.isLoaded(profileId, id),
              message: result.message,
            },
            summary: { profile: profileId, extension: id, on: deps.isLoaded(profileId, id) },
          }
        }

        let result: ExtensionResult
        switch (action) {
          case 'remove':
            result = deps.remove ? deps.remove(profileId, id) : notWired('remove an extension')
            break
          case 'reload':
            result = deps.reload ? await deps.reload(profileId, id) : notWired('reload an extension')
            break
          case 'rename': {
            const name = optStr(args, 'name')
            if (name === null) throw new Refused('not-permitted', 'rename needs name: what to call it')
            result = deps.rename ? deps.rename(profileId, id, name) : notWired('rename an extension')
            break
          }
          case 'popup':
          case 'options':
            result = deps.openWindow ? await deps.openWindow(profileId, id, action) : notWired('open an extension’s window')
            break
        }
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return {
          value: {
            profile: profileId,
            profileName,
            extension: id,
            done: action,
            on: deps.isLoaded(profileId, id),
            ...(result.message === '' ? {} : { message: result.message }),
          },
          summary: { profile: profileId, extension: id, action },
        }
      },
    },
  ]
}
