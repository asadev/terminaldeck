/**
 * Tool names a task agent can be told about, or blocked from.
 *
 * Claude Code's own tools are named here because nothing on disk lists them
 * without starting the CLI; MCP servers are read from its configuration
 * (`main/tasks/agent-inventory.ts`). Blocking is Claude Code's
 * `--disallowedTools`: a refusal it enforces itself. Only ever a deny list —
 * the matching allow flag approves tools without asking, and is never used here.
 */
export const CLAUDE_TOOLS: ReadonlyArray<{ name: string; label: string }> = [
  { name: 'Bash', label: 'Run commands' },
  { name: 'Read', label: 'Read files' },
  { name: 'Write', label: 'Write new files' },
  { name: 'Edit', label: 'Edit files' },
  { name: 'MultiEdit', label: 'Several edits at once' },
  { name: 'NotebookEdit', label: 'Edit notebooks' },
  { name: 'Glob', label: 'Find files by name' },
  { name: 'Grep', label: 'Search inside files' },
  { name: 'WebFetch', label: 'Open web pages' },
  { name: 'WebSearch', label: 'Search the web' },
  { name: 'Task', label: 'Start helper agents' },
  { name: 'TodoWrite', label: 'Keep a to-do list' },
]

/**
 * A tool name that is safe on a command line and means one thing: a Claude
 * Code tool, or `mcp__<server>` (every tool of that server) or
 * `mcp__<server>__<tool>`. No spaces, commas or brackets, so a list joins
 * into one argument and can never be read as a flag or a pattern.
 */
export const TOOL_NAME = /^(?:[A-Z][A-Za-z0-9]{0,63}|mcp__[A-Za-z0-9_-]{1,64}(?:__[A-Za-z0-9_-]{1,64})?)$/

/** The `mcp__` name that blocks every tool of one server. */
export function mcpServerTool(server: string): string | null {
  const name = `mcp__${server.replace(/[^A-Za-z0-9_-]/g, '_')}`
  return TOOL_NAME.test(name) ? name : null
}
