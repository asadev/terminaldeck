import {
  everywhere,
  missingApis,
  reachOf,
  usesStaticRulesets,
} from '../browser-extension-support'
import type { ExtensionResult, InstalledExtension } from '../browser-extensions'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { STORE_PLACE } from './store-tools'
import { Refused } from './surface'

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
 * ## What it will not do
 *
 * It will not install or remove. An install downloads and unpacks a program that
 * then runs on every page of a profile, and that is a decision for the person
 * whose profile it is, at the panel, having read what it reaches. There is no
 * argument for putting it behind a model's judgement, and a store whose
 * catalogue an agent could work through is a store that can install nine
 * programs while nobody is looking.
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

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    extension: {
      type: 'string',
      description: 'Which extension to switch. Omit to list what is installed and what is on.',
    },
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

export function extensionTools(deps: ExtensionToolDeps): ToolSpec[] {
  return [
    {
      id: 'browser.extensions',
      wire: 'browser_extensions',
      tier: 'read',
      title: 'See and switch the browser’s extensions',
      description:
        'List the browser extensions installed in a profile and whether each one is running, or ' +
        'switch one on or off. Read it before reading a page: an extension that runs on every page ' +
        'changes what that page contains, so a blocker, a dark-mode rewriter or a URL cleaner will ' +
        'otherwise be reported as the site’s own behaviour. Switching one off is how you see a page ' +
        'as the site actually sends it. It cannot install or remove anything — that is done by hand ' +
        // One door, one spelling: the same words the menu row wears, imported
        // from the tool that answers for the other half of the same store.
        `in ${STORE_PLACE}.`,
      index:
        'List which browser extensions are running in a profile, and switch one on or off. Read it before reading a page an extension may be altering.',
      inputSchema: SCHEMA,

      /*
       * Listing is a read; switching persists and everybody in the window sees
       * it. Only ever upwards, which is what `control.ts` does with this — a
       * call with no `extension` stays at `read` and costs nobody a dialog.
       */
      escalate: (args) => (optStr(args, 'extension') === null ? 'read' : 'alter'),

      summary(args: Record<string, unknown>): string {
        const id = optStr(args, 'extension')
        const profile = optStr(args, 'profile')
        const where = profile === null ? 'the current profile' : `profile ${profile}`
        if (id === null) return `List the browser extensions in ${where}`
        return `Switch ${id} ${args.on === true ? 'on' : 'off'} in ${where}`
      },

      run: async (args: Record<string, unknown>, _context: ToolContext): Promise<ToolOutput> => {
        const profileId = optStr(args, 'profile') ?? deps.currentProfileId()
        const profileName = deps.profileName(profileId)
        const id = optStr(args, 'extension')

        if (id === null) {
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
                  ? `No extensions are installed in ${profileName}. They are installed by hand, in ${STORE_PLACE}.`
                  : '',
            },
            summary: {
              profile: profileId,
              installed: extensions.length,
              on: extensions.filter((one) => one.on).length,
            },
          }
        }

        if (typeof args.on !== 'boolean') {
          throw new Refused('not-permitted', 'on must be true or false when you name an extension')
        }
        const known = deps.installed(profileId).some((one) => one.entry.id === id)
        if (!known) {
          /*
           * Named rather than a bare "no": the refusal a model gets has to teach
           * it the call that would have worked, which here is the listing call
           * one line up.
           */
          throw new Refused(
            'not-permitted',
            `${id} is not installed in ${profileName}. Call this tool with no extension to see what is.`,
          )
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
      },
    },
  ]
}
