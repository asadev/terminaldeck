/**
 * How the MCP server list is read. The list itself is drawn in the window's bar.
 *
 * This was a React component too — a "Connectors" face inside the composer's
 * attach popover. That face is gone with the rest of the controls the composer
 * was duplicating from the top bar, in his words: *"Options is showing the same
 * options that we already have here… since we have it on top we actually don't
 * need them here."* The window's own Connectors chip is one click away on every
 * session, including the ones drawn as a terminal, which the composer's copy
 * never was.
 *
 * What is left is the part that was never about where it was drawn: reading the
 * status list, which crosses the preload as `unknown`. `shell/use-connectors.ts`
 * is the caller now, and it is the only one — hence `.ts`, no JSX, one owner.
 *
 * The notes below are kept because they are the record of what this list may
 * and may not claim, and that judgement outlives the surface it was written for.
 *
 * Read-only is the honest ceiling here, and it follows from what chat mode is.
 * The only channel to the agent is characters typed into its terminal, and
 * there is no keystroke that makes the CLI call an MCP tool on the user's
 * behalf — the agent decides that, mid-turn, from the conversation. Deck *can*
 * dial these servers itself (the inspector does), but a tool called
 * from this app would run outside the session the user is talking to and would
 * not appear in the transcript, so a "Run" button here would be a different
 * feature wearing this one's clothes.
 *
 * What a typed message genuinely does is aim the agent: MCP tools are named
 * `mcp__<server>__<tool>`, so putting that prefix in the prompt names the
 * server unambiguously. That is what a row inserts.
 *
 * The list itself is the user's own configuration — `src/main/mcp-client.ts`
 * reads the same `~/.claude.json` the CLI does — so a server added with
 * `claude mcp add` shows up here without being entered twice.
 */

export interface McpRow {
  id: string
  name: string
  /** Null when the list did not carry it. Never guessed — see {@link readServers}. */
  scope: string | null
  transport: string | null
  enabled: boolean
  /** Why the CLI would not load it, when it would not. */
  disabledReason: string | null
}

/**
 * Coerce the status list, which crosses the preload as `unknown`.
 *
 * Exported for its own test: the shapes here come from a module the renderer
 * cannot import, so the only way to keep the two honest is to state what is
 * read and check that a partial row degrades instead of throwing.
 *
 * A missing field becomes null rather than a plausible value. "user · stdio"
 * under a server name reads as something this app went and looked up; printing
 * it for a row that carried neither would be inventing the two facts most
 * likely to be wrong when the bridge and the main process have drifted.
 */
export function readServers(response: unknown): McpRow[] | null {
  if (!Array.isArray(response)) return null
  const rows: McpRow[] = []
  for (const entry of response) {
    if (!entry || typeof entry !== 'object') continue
    const server = entry as Record<string, unknown>
    if (typeof server.id !== 'string' || typeof server.name !== 'string') continue
    rows.push({
      id: server.id,
      name: server.name,
      scope: typeof server.scope === 'string' ? server.scope : null,
      transport: typeof server.transport === 'string' ? server.transport : null,
      enabled: server.enabled !== false,
      disabledReason: typeof server.disabledReason === 'string' ? server.disabledReason : null,
    })
  }
  return rows
}

/** What the second column says: the reason it is off, or what was read of it. */
export function rowDetail(row: McpRow): string {
  if (row.disabledReason) return row.disabledReason
  return [row.scope, row.transport].filter((part): part is string => part !== null).join(' · ')
}

/** The namespace every tool on a server shares. */
export function toolPrefix(name: string): string {
  return `mcp__${name}__`
}
