/**
 * Where a search term goes.
 *
 * This lived in `renderer/browser/omnibox.ts` alone, which was right for as
 * long as the URL bar was the only thing in the app that could start a search.
 * The page's own right-click menu can start one now — *"Search the web for …"*
 * on a selection — and that menu is built in the **main** process, which cannot
 * import a renderer module and must not answer the same question with a second
 * copy of the answer. Two search templates that disagree is the kind of bug
 * nobody notices until the day one of them is changed.
 *
 * So the template sits in `shared/`, the one directory main, the preload and the
 * renderer are all allowed to import, and `omnibox.ts` re-exports it so its own
 * callers did not have to move.
 */

/** Where a search term goes. `%s` is replaced with the encoded query. */
export const DEFAULT_SEARCH = 'https://duckduckgo.com/?q=%s'

/**
 * The URL that searches for `query`.
 *
 * A template with no `%s` gets the query appended instead, which is how the
 * shorter `https://example.com/?q=` form — the shape people paste out of a
 * browser's search-engine settings — keeps working.
 */
export function searchUrl(query: string, template: string = DEFAULT_SEARCH): string {
  return template.includes('%s')
    ? template.replace('%s', encodeURIComponent(query))
    : `${template}${encodeURIComponent(query)}`
}
