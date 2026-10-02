import type { AgentCliVersion, Handover, SignInTrouble } from '../browser-signin'
import { actionOf, escalateBy, notASession, str } from './browser-area-kit'
import { mayDrive } from './browser-tools'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.signin` — the sign-in trouble banner, as a tool.
 *
 * `browser-signin.ts` exists because some sign-ins do not work inside an
 * embedded browser and the honest response is to say so and hand them to the
 * Mac's own browser: Google refuses embedded engines, and an out-of-date agent
 * CLI is refused server-side however the page is opened. The banner does three
 * things and so does this — diagnose an address, hand it over, and check the
 * agent CLIs whose sign-in is known to fail on an old build.
 *
 * Handing over opens a page in the person's own default browser, which holds
 * every login they have, so it passes {@link mayDrive}: the person at this
 * machine, attended. It is `act` rather than `alter` because it is exactly what
 * the banner's button does — open the address the person was already looking
 * at, outside — and `handoverFor` refuses anything that is not http or https.
 * Diagnosing reads nothing but the address it is given.
 */

export interface SignInToolDeps {
  diagnose(url: string): SignInTrouble | null
  handover(url: string): Promise<Handover | null>
  agents(): Promise<AgentCliVersion[]>
}

const ACTIONS = ['diagnose', 'handover', 'agents'] as const
type Action = (typeof ACTIONS)[number]

const TIERS: Readonly<Record<Action, Tier>> = { diagnose: 'read', handover: 'act', agents: 'read' }

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...ACTIONS], description: 'Default diagnose.' },
    url: { type: 'string', description: 'For diagnose and handover: the sign-in page’s address.' },
  },
  additionalProperties: false,
}

export function signInTools(deps: SignInToolDeps): ToolSpec[] {
  return [
    {
      id: 'browser.signin',
      wire: 'browser_signin',
      tier: 'read',
      title: 'Sign-ins that do not work here',
      description:
        'For a sign-in that fails inside the in-app browser. "diagnose" (the default) says whether this ' +
        'address is one known not to work in an embedded browser — Google’s, for one — and what to do. ' +
        '"handover" opens it in the Mac’s own browser instead, where it works, and says which sites’ ' +
        'cookies to bring back afterwards with browser.import. "agents" checks the agent command-line ' +
        'tools whose sign-in is refused on an old version, and says how to update them.',
      index:
        'Sign-ins that fail in the in-app browser: diagnose, open in the Mac’s own browser, old agent CLIs.',
      inputSchema: SCHEMA,
      escalate: escalateBy(TIERS, 'diagnose'),
      precheck: (args, context: ToolContext) => {
        notASession(context, 'browser.signin')
        const action = actionOf(args, ACTIONS, 'diagnose')
        if (action !== 'agents') str(args, 'url')
        if (action === 'handover') mayDrive(context, 'browser.signin')
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'diagnose'
        const url = typeof args.url === 'string' ? args.url : '?'
        if (action === 'handover') return `Open ${url} in the Mac’s own browser to sign in there`
        if (action === 'agents') return 'Check the agent command-line tools for an out-of-date sign-in'
        return `Check whether signing in at ${url} works in this browser`
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, ACTIONS, 'diagnose')
        if (action === 'agents') {
          const stale = await deps.agents()
          return {
            value: {
              stale: stale.map((entry) => ({ command: entry.command, version: entry.version, advice: entry.advice })),
              note: stale.length === 0 ? 'No agent command-line tool is known to be too old to sign in.' : '',
            },
            summary: { stale: stale.length },
          }
        }
        const url = str(args, 'url')
        if (action === 'diagnose') {
          const trouble = deps.diagnose(url)
          return {
            value:
              trouble === null
                ? { known: false, note: 'Nothing is known to stop this sign-in working here.' }
                : { known: true, kind: trouble.kind, headline: trouble.headline, detail: trouble.detail, sites: trouble.domains },
            summary: { known: trouble !== null },
          }
        }
        const plan = await deps.handover(url)
        if (plan === null) {
          throw new Refused('not-permitted', `${url} is not an http or https address, so it was not handed over`)
        }
        return {
          value: {
            opened: plan.url,
            bringBack: plan.domains,
            note: 'It is open in the Mac’s own browser. Once the person has signed in there, browser.import with action "run" and these sites brings the sign-in back here.',
          },
          summary: { sites: plan.domains.length },
        }
      },
    },
  ]
}
