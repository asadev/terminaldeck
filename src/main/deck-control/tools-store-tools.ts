import type { StoreResult, StoreView } from '../browser-store'
import { actionOf, escalateBy, notASession, str } from './browser-area-kit'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.store` — the browser's Tools store: list it, install from it,
 * remove what came from it.
 *
 * `browser.extract` runs an installed tool and has always said, truthfully, that
 * nothing on this surface could install one. That was a choice for the same
 * reason the extension store made it, and 0.16.0 reverses it for the same
 * reason too: Asad's *"everything that I can do manually"*. What makes it safe
 * enough to hand over is what a store tool *is* — `browser-store-recipe.ts`
 * spends its header on it: selectors and a closed set of operations, run by a
 * script this repository wrote, pinned to a digest, never a program. Installing
 * one can never let it exceed `browser.read` on the same page.
 *
 * It is still `alter`, both ways. An install adds a capability every agent on
 * this machine can then reach through `browser.extract`, and a removal takes one
 * away from whatever was using it. Both are changes to what this app can do, and
 * a person says yes to them.
 */

export interface ToolsStoreDeps {
  list(): { view: StoreView; orphans: string[] }
  install(id: string): Promise<StoreResult>
  remove(id: string): StoreResult
}

const ACTIONS = ['list', 'install', 'remove'] as const
type Action = (typeof ACTIONS)[number]

const TIERS: Readonly<Record<Action, Tier>> = { list: 'read', install: 'alter', remove: 'alter' }

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...ACTIONS], description: 'Default list.' },
    tool: { type: 'string', description: 'For install and remove: the tool id from the list.' },
  },
  additionalProperties: false,
}

export function toolsStoreTools(deps: ToolsStoreDeps): ToolSpec[] {
  const known = (id: string): boolean => {
    const { view, orphans } = deps.list()
    return view.tools.some((tool) => tool.id === id) || orphans.includes(id)
  }
  return [
    {
      id: 'browser.store',
      wire: 'browser_store',
      tier: 'read',
      title: 'The browser’s Tools store',
      description:
        'The browser’s Tools store: ready-made page readers that browser.extract then runs on a page. ' +
        '"list" (the default) gives every tool in the store — what it reads, which sites it runs on, ' +
        'whether it is installed, and the digest it is pinned to. "install" downloads, verifies and ' +
        'installs one (tool); "remove" takes one away. A store tool is a set of selectors, not a program, ' +
        'and can never read more than browser.read would. Install and remove ask the person first.',
      index:
        'Tools store of page readers for browser.extract: list, install, remove.',
      inputSchema: SCHEMA,
      escalate: escalateBy(TIERS, 'list'),
      precheck: (args, context: ToolContext) => {
        notASession(context, 'browser.store')
        const action = actionOf(args, ACTIONS, 'list')
        if (action === 'list') return
        const id = str(args, 'tool')
        if (!known(id)) {
          throw new Refused('not-permitted', `the Tools store has no tool ${id}. action "list" names them.`)
        }
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'list'
        const id = typeof args.tool === 'string' ? args.tool : '?'
        const name = deps.list().view.tools.find((tool) => tool.id === id)?.name ?? id
        if (action === 'install') return `Install ${name} from the browser’s Tools store`
        if (action === 'remove') return `Remove ${name} from the browser`
        return 'List the browser’s Tools store'
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, ACTIONS, 'list')
        if (action === 'list') {
          const { view, orphans } = deps.list()
          const tools = view.tools.map((tool) => ({
            tool: tool.id,
            name: tool.name,
            summary: tool.summary,
            state: tool.state,
            version: tool.version,
            installedVersion: tool.installedVersion,
            runsOn: tool.origins.length === 0 ? 'any page' : [...tool.origins],
            reads: tool.reads,
            sha256: tool.sha256,
            licence: tool.licence,
            ...(tool.message === '' ? {} : { message: tool.message }),
          }))
          return {
            value: { tools, ...(orphans.length === 0 ? {} : { withdrawnButInstalled: orphans }) },
            summary: { tools: tools.length, installed: tools.filter((tool) => tool.state === 'installed').length },
          }
        }
        const id = str(args, 'tool')
        const result = action === 'install' ? await deps.install(id) : deps.remove(id)
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return {
          value: {
            tool: id,
            [action === 'install' ? 'installed' : 'removed']: true,
            message: result.message,
            ...(action === 'install' ? { next: 'browser.extract runs it on a page.' } : {}),
          },
          summary: { tool: id },
        }
      },
    },
  ]
}
