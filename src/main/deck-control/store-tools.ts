import type { BrowserDrive } from '../browser-driver'
import {
  MAX_EXTRACT_LIMIT,
  planFor,
  type ExtractResult,
} from '../browser-store-script'
import { originWords, recipeAllowsUrl } from '../browser-store-recipe'
import type { InstalledTool } from '../browser-store'
import { boundOf } from './browser-tools'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused } from './surface'

/**
 * `browser.extract` — the one door every installed store tool comes through.
 *
 * ## Why one tool and not one per install
 *
 * Because a tool definition is not free and an install must not change what
 * every session on this machine pays on every turn. `catalogue.ts` holds the
 * whole listing to `MAX_CATALOGUE_TOOLS` and `MAX_CATALOGUE_TOKENS` and its
 * instruction to whoever runs out is explicit — *"do not raise the number,
 * disclose progressively"* — and a store that added a schema per installed tool
 * is the fastest way to run out that this codebase could invent. It would also
 * mean the tool list a model sees changing shape underneath it whenever
 * somebody pressed Install in a window they are not looking at.
 *
 * So there is one definition. Called with no `tool` it lists what is installed,
 * with what each one reads and where it may run; called with a name it runs
 * that one. That is the progressive disclosure the budget's own note asks for,
 * and it means the tool is never a dead end: the first call an agent makes
 * teaches it the second.
 *
 * ## What an installed tool may do, and where that is enforced
 *
 * Three bounds, and none of them is inside the recipe:
 *
 *  1. **It is not code.** A store tool is selectors and a closed op set, run by
 *     `browser-store-script.ts` — a script this repository wrote — through the
 *     same `withArgs` seam every other read uses. See `browser-store-recipe.ts`
 *     for the whole argument, including why downloading programs was refused.
 *  2. **It can never exceed `browser.read`.** Same isolated world, same baton,
 *     same secret guard, same window resolution — {@link boundOf}, imported
 *     rather than re-implemented, so a session can name only its own windows.
 *     That is why this tool's tier is `read` and not something new: it discloses
 *     nothing `browser.read` on the same page would not.
 *  3. **It may be less.** A recipe naming hosts is refused on every other page,
 *     and the refusal happens **here**, at the dispatcher's gate, against the
 *     URL the WebContents actually holds — never inside the recipe, which is
 *     the untrusted half and could not be asked to police itself. The origin is
 *     read the same way `browser-tools.ts` reads it for its escalation, and for
 *     the same stated reason: it is *"a main-process fact needing nobody's
 *     cooperation"*, so the bound lapses the moment a redirect moves the page.
 *
 * ## The number it always reports
 *
 * Seven per cent of a dataset once shipped as complete because nothing compared
 * it against the total the page itself stated. So every answer carries
 * `rowsOnPage`, `rowsReturned` and — when the recipe names it — `stated`, and
 * when they disagree the result says so in a sentence rather than leaving the
 * arithmetic to whoever reads it. A tool that reports only what it collected
 * cannot notice that it collected the wrong amount.
 */

export interface StoreToolDeps {
  drive: BrowserDrive
  /** Every verified, parsed tool. Asked per call, so an install lands at once. */
  installed(): InstalledTool[]
}

/**
 * Where somebody turns a tool on.
 *
 * Named in the refusal a model gets when it asks for a tool nobody installed,
 * because *"install it"* with no place to do it is the dead end this whole
 * round is about. It is the same words the menu row uses.
 */
export const STORE_PLACE = "the browser's ⋯ menu, under Tools"

function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new Refused('not-permitted', `${key} must be a string`)
  return value
}

function optInt(args: Record<string, unknown>, key: string, max: number): number | undefined {
  const value = args[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Refused('not-permitted', `${key} must be a number`)
  }
  return Math.min(Math.max(Math.trunc(value), 1), max)
}

/** What a listing call answers with, per installed tool. */
export interface ToolListing {
  tool: string
  name: string
  reads: string
  /** `any page`, or the hosts it is bound to. */
  runsOn: string
  fields: string[]
}

export function listInstalled(tools: readonly InstalledTool[]): ToolListing[] {
  return tools.map(({ recipe }) => {
    const fields = recipe.fields.map((field) => field.name)
    if (recipe.rows) for (const field of recipe.rows.fields) fields.push(`${field.name} (per row)`)
    return {
      tool: recipe.id,
      name: recipe.name,
      reads: recipe.summary,
      runsOn: originWords(recipe.origins),
      fields,
    }
  })
}

/**
 * How many things this call was actually about, and how many the page had.
 *
 * A recipe collects in one of two shapes and the arithmetic has to know which:
 * a **repeating block** counts rows, and a **list field** counts matches. Both
 * were needed. `page-images` has no rows at all — it is one `all` field of every
 * `<img>` — so a completeness check written only against rows would have read
 * "0 came back" on a page with two hundred images and said so out loud, which is
 * a false alarm; and one written only against fields would have missed a short
 * table, which is a false all-clear. False all-clears are the expensive kind.
 *
 * Which shape it is comes off the **recipe**, never off the answer: a page that
 * happens to have no rows today would otherwise change how its own totals are
 * read.
 */
export function collectedBy(
  recipe: { rows: unknown | null },
  result: {
    rowsOnPage: number
    rowsReturned: number
    counts: Record<string, { matched: number; returned: number }>
  },
): { onPage: number; returned: number } {
  if (recipe.rows !== null) return { onPage: result.rowsOnPage, returned: result.rowsReturned }
  let onPage = 0
  let returned = 0
  for (const count of Object.values(result.counts ?? {})) {
    onPage = Math.max(onPage, count.matched)
    returned = Math.max(returned, count.returned)
  }
  return { onPage, returned }
}

/**
 * The page's own total, but only when it can be believed.
 *
 * A stated total **smaller** than what came back cannot be a total of what came
 * back, so it is not one — the ordinary cause is a selector pointed at a
 * sentence like *"showing 1-20 of 1,248"*, where the first number in the text is
 * the 1. Believing it would compute `20 >= 1` and call a partial read complete,
 * which is precisely the failure this whole accounting exists for. So it is
 * dropped, and {@link completenessNote} says it was dropped rather than letting
 * a bad selector pass silently.
 */
export function trustedStated(stated: number | null, returned: number): number | null {
  if (stated === null || !Number.isFinite(stated) || stated < 0) return null
  return stated < returned ? null : stated
}

/**
 * Is this the whole set? `null` when there is nothing to compare against.
 *
 * Three-valued on purpose. `null` means the recipe names no total this app can
 * believe, which is honestly different from "we know it is short" — and a
 * boolean that quietly meant "probably" is how seven per cent of a dataset gets
 * shipped as a complete one.
 */
export function isComplete(stated: number | null, returned: number): boolean | null {
  const trusted = trustedStated(stated, returned)
  return trusted === null ? null : returned >= trusted
}

/**
 * The sentence about completeness, or `''` when there is nothing to say.
 *
 * Separate and pure so a test can name every branch of it, because this is the
 * one piece of the tool whose absence was itself the bug.
 */
export function completenessNote(counted: {
  stated: number | null
  onPage: number
  returned: number
}): string {
  const { stated, onPage, returned } = counted
  if (stated !== null && stated >= 0 && stated < returned) {
    return (
      `The page states ${stated}, which is fewer than the ${returned} that came back, so that ` +
      `total was not believed. Check what the recipe is reading it from.`
    )
  }
  if (stated !== null && stated > returned) {
    const why = onPage > returned ? ' The limit on this call is part of it.' : ''
    return (
      `The page accounts for ${stated} and ${returned} came back. This is not the whole set — ` +
      `raise the limit or page on before treating it as complete.${why}`
    )
  }
  if (onPage > returned) {
    return `The page has ${onPage} and ${returned} came back, because of the limit on this call.`
  }
  return ''
}

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    tool: {
      type: 'string',
      description: 'Which installed tool to run. Omit to list the tools that are installed.',
    },
    sessionId: { type: 'string', description: 'Whose window. Omit for your own.' },
    window: { type: 'string', description: 'Window name, like B1. Omit for the first one.' },
    limit: {
      type: 'number',
      description: `Most rows to bring back, up to ${MAX_EXTRACT_LIMIT}.`,
    },
  },
  additionalProperties: false,
}

export function storeTools(deps: StoreToolDeps): ToolSpec[] {
  return [
    {
      id: 'browser.extract',
      wire: 'browser_extract',
      tier: 'read',
      title: 'Read a page with an installed tool',
      description:
        'Run one of the tools installed from the browser tools store against an attached page ' +
        'and return what it collects. Call with no tool to list what is installed. Every answer ' +
        'says how many the page has and how many came back, so a partial read is never mistaken ' +
        'for a complete one.',
      index:
        'Read an attached page with a tool installed from the browser tools store. Call it naming no tool to list what is installed.',
      inputSchema: SCHEMA,
      summary(args: Record<string, unknown>): string {
        const tool = optStr(args, 'tool')
        return tool === null ? 'list the installed browser tools' : `read the page with ${tool}`
      },
      async run(args: Record<string, unknown>, context: ToolContext): Promise<ToolOutput> {
        const installed = deps.installed()
        const wanted = optStr(args, 'tool')

        if (wanted === null) {
          const tools = listInstalled(installed)
          return {
            value: {
              tools,
              /*
               * An empty store is a real state, and it is answered with the
               * place rather than with a shrug — a model told "nothing is
               * installed" and nothing else will invent a way to install one.
               */
              note:
                tools.length === 0
                  ? `No browser tools are installed. They are installed by a person, from ${STORE_PLACE}.`
                  : '',
            },
            summary: { tools: tools.length },
          }
        }

        const found = installed.find((entry) => entry.recipe.id === wanted)
        if (!found) {
          const names = installed.map((entry) => entry.recipe.id)
          throw new Refused(
            'not-permitted',
            names.length === 0
              ? `no browser tool called ${wanted} is installed, and nor is any other. ` +
                `A person installs them from ${STORE_PLACE}.`
              : `no browser tool called ${wanted} is installed. These are: ${names.join(', ')}.`,
          )
        }

        const bound = boundOf(args, context)
        const target = bound?.target ?? null

        /*
         * The origin gate, on the URL the page actually holds.
         *
         * Before the recipe runs and not inside it. A page whose address cannot
         * be read at all is refused too, which is the conservative direction —
         * `origin()` answers null when there is no contents, and running a
         * host-bound recipe against a page we cannot name would be running it
         * against an unknown one.
         */
        const origin = deps.drive.origin(target)
        if (origin === null || !recipeAllowsUrl(found.recipe, origin)) {
          throw new Refused(
            'not-permitted',
            `${found.recipe.name} only runs on ${originWords(found.recipe.origins)}, and this page ` +
              `is ${origin === null ? 'not one this app can read an address for' : origin}.`,
          )
        }

        const result: ExtractResult = await deps.drive.extract(
          planFor(found.recipe, { limit: optInt(args, 'limit', MAX_EXTRACT_LIMIT) }),
          target,
        )
        const counted = collectedBy(found.recipe, result)
        const note = completenessNote({ stated: result.stated, ...counted })
        return {
          value: {
            tool: found.recipe.id,
            url: result.url,
            title: result.title,
            fields: result.fields,
            rows: result.rows,
            rowsOnPage: result.rowsOnPage,
            rowsReturned: result.rowsReturned,
            /* Per list field: how many the page had against how many came back.
               A caller writing files needs the first number to know when it is
               done, and only the second one was ever being reported. */
            counts: result.counts,
            onPage: counted.onPage,
            returned: counted.returned,
            stated: result.stated,
            complete: isComplete(result.stated, counted.returned),
            next: result.next,
            note,
          },
          // Numbers, never the payload. `ToolOutput.summary`: *"Never the
          // payload … the log is an audit trail and not a second copy of the
          // app's data."*
          summary: {
            tool: found.recipe.id,
            rows: counted.returned,
            onPage: counted.onPage,
            stated: result.stated,
            short: note !== '',
          },
        }
      },
    },
  ]
}
