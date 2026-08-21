/**
 * The names of the asset tools, and nothing else.
 *
 * Its own file, with no imports at all, for one reason: `session-tools.ts` needs
 * this list to put on a session's allow-list, and `session-tools.ts` is loaded
 * on the launch path of every session in the app. Importing it out of
 * `asset-tools.ts` would drag `catalogue.ts` — and through it the binding, the
 * fleet diff and half the surface — into that path to read eight strings.
 *
 * Both spellings of each, because the wire name and the dotted id are two names
 * for one tool and a caller picks which to send. `server.ts` gates `tools/list`
 * and `tools/call` on the same set, so a name missing from here is a tool a
 * session can neither find nor call.
 */
export const ASSET_TOOL_NAMES: readonly string[] = Object.freeze([
  'assets.rendition',
  'assets_rendition',
  'assets.ledger',
  'assets_ledger',
  'assets.coverage',
  'assets_coverage',
  'assets.blocks',
  'assets_blocks',
])
