import { useState } from 'react'
import { HoverNote } from './HoverNote'

/**
 * The form behind the MCP panel's Add button.
 *
 * ## Why there is an Add button at all now
 *
 * There was only ever Reload, and the panel's own empty state told people to go
 * and type `claude mcp add` somewhere else. That is defensible for a window
 * that genuinely cannot write — but it was never checked whether this one
 * could, and the answer is that it can: `claude mcp add` is a documented,
 * non-interactive command, and it writes exactly the file this panel already
 * reads. So the silence was not a limit, it was a gap, and a gap with no
 * explanation on screen reads as a broken feature.
 *
 * The write still goes through that CLI rather than through us — see
 * `src/main/mcp-add.ts` for why touching another application's seventy-kilobyte
 * live config from a second process is a bad trade for one added key.
 *
 * ## The scope picker is not a formality
 *
 * Two of the three scopes are addressed by the working directory the CLI runs
 * in, not by a flag, so "this project" means nothing without a project open.
 * Rather than offer three choices and let two of them fail, `scopeChoices`
 * offers only what can actually be written right now and the form says why the
 * others are missing. A picker whose options can silently do nothing is the
 * same class of lie as a Test button that always says "Sent."
 */

/* ------------------------------------------------------------------ types -- */

/**
 * Mirrors of `src/main/mcp-add.ts`, duplicated rather than imported for the
 * same reason as the types at the top of `McpInspector.tsx`: the renderer
 * tsconfig does not include `src/main`.
 */
export type McpAddScope = 'user' | 'project' | 'local'
export type McpAddTransport = 'stdio' | 'http' | 'sse'

export interface McpAddResult {
  ok: boolean
  message: string
}

export interface McpAddDraft {
  name: string
  scope: McpAddScope
  transport: McpAddTransport
  command: string
  url: string
  /** One `KEY=value` (or `Name: value`) per line; split on the way out. */
  extras: string
}

export const EMPTY_DRAFT: McpAddDraft = {
  name: '',
  scope: 'user',
  transport: 'stdio',
  command: '',
  url: '',
  extras: '',
}

export interface ScopeChoice {
  value: McpAddScope
  label: string
  help: string
}

/**
 * Which scopes can be written right now.
 *
 * `user` is always available; the other two need somewhere to be relative to.
 * Exported so a test can pin the no-project case, which is the one that used to
 * be impossible to get right by inspection.
 */
export function scopeChoices(projectPath: string | null): ScopeChoice[] {
  const choices: ScopeChoice[] = [
    {
      value: 'user',
      label: 'All projects',
      help: 'Available everywhere.',
    },
  ]
  if (projectPath) {
    choices.push(
      {
        value: 'local',
        label: 'This project only',
        help: 'Private to this folder. Not committed.',
      },
      {
        value: 'project',
        // Measured, not guessed: a server added this way comes back from the
        // reader as `enabled: false` with "Not approved for this project yet.",
        // because Claude Code gates shared `.mcp.json` servers behind an
        // approval. Saying so here is the difference between a greyed-out row
        // reading as a working safeguard and reading as a failed add.
        label: 'This project, shared',
        // The approval clause stays. A server added this way comes back from
        // the reader as `enabled: false` — measured, not guessed — and without
        // the warning a working safeguard reads as a failed add. What went was
        // the sentence about `.mcp.json` being committable, which the label
        // ("shared") already carries.
        help: 'Stays inactive until Claude Code asks you to approve it.',
      },
    )
  }
  return choices
}

/**
 * Turn what is on screen into what crosses the bridge.
 *
 * Pure, and exported, because the interesting part is what it drops: the field
 * belonging to the transport that was not chosen. Sending both a command and a
 * URL and letting the far side decide is how a form that has been switched back
 * and forth ends up adding a server from a field the user could no longer see.
 */
export function draftToRequest(draft: McpAddDraft, projectPath: string | null): Record<string, unknown> {
  return {
    name: draft.name.trim(),
    scope: draft.scope,
    transport: draft.transport,
    command: draft.transport === 'stdio' ? draft.command.trim() : '',
    url: draft.transport === 'stdio' ? '' : draft.url.trim(),
    extras: draft.extras
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line !== ''),
    projectPath,
  }
}

/**
 * What the form is still missing, or null when there is something to send.
 *
 * Pure and exported so the button's own state and the sentence under it are one
 * decision rather than two that can disagree. It exists because pressing "Add
 * server" on an empty form did *nothing whatsoever*: no write, no error, no
 * message — the request went across the bridge with an empty name, the CLI was
 * never given anything it could act on, and the form sat there looking as if
 * the click had missed. A control that looks pressable has to answer.
 */
export function missingFrom(draft: McpAddDraft): string | null {
  // Each of these is a hover label on a button somebody cannot press. It has to
  // name the empty field and nothing else — "it is how you refer to it later"
  // was answering a question the reader had not asked, in a tooltip.
  if (draft.name.trim() === '') return 'Give the server a name first.'
  if (draft.transport === 'stdio' && draft.command.trim() === '')
    return 'Say which command starts it.'
  if (draft.transport !== 'stdio' && draft.url.trim() === '')
    return 'Say which URL it is reached at.'
  return null
}

/* ------------------------------------------------------------------- form -- */

/**
 * What the form starts from, when it is not starting from nothing.
 *
 * Two callers hand it one: **Edit**, on a server that is already configured,
 * and **Import**, on a definition somebody was sent. Both are drafts rather than
 * writes — the fields are filled in and the person presses the button — which is
 * the same shape as installing a catalogue row that needs a token.
 *
 * `savedKeys` is what makes editing survivable. A server's environment *values*
 * are never sent to a renderer, so an edit form cannot show them; what it shows
 * instead is `KEY=` with nothing after it, and the rule — stated on the form,
 * and enforced in `src/main/mcp-edit.ts` — is that an empty value keeps whatever
 * is saved. Deleting the line is how you delete the variable.
 */
export interface McpFormStart {
  draft: McpAddDraft
  /** Variable names that already have a value in the configuration. */
  savedKeys: string[]
}

/**
 * An edit draft for one configured server.
 *
 * Pure and exported because the `KEY=` lines are the visible half of a promise
 * about somebody's API key, and a promise assembled inline in JSX is one nothing
 * can pin.
 */
export function editStart(server: {
  name: string
  scope: McpAddScope
  transport: McpAddTransport
  command: string
  envKeys: readonly string[]
}): McpFormStart {
  return {
    draft: {
      name: server.name,
      scope: server.scope,
      transport: server.transport,
      command: server.transport === 'stdio' ? server.command : '',
      url: server.transport === 'stdio' ? '' : server.command,
      extras: server.envKeys.map((key) => `${key}=`).join('\n'),
    },
    savedKeys: [...server.envKeys],
  }
}

/**
 * A draft for a definition that arrived in a file.
 *
 * `savedKeys` is empty and that is the difference from an edit: the file carries
 * variable *names* and no values, on purpose, so every one of them is a field
 * this person has to fill in rather than one they can leave alone.
 */
export function importStart(
  imported: { name: string; transport: McpAddTransport; command: string; url: string; env: readonly string[] },
  scope: McpAddScope,
): McpFormStart {
  return {
    draft: {
      name: imported.name,
      scope,
      transport: imported.transport,
      command: imported.command,
      url: imported.url,
      extras: imported.env.map((key) => `${key}=`).join('\n'),
    },
    savedKeys: [],
  }
}

export interface McpAddFormProps {
  projectPath: string | null
  /**
   * Adding something new, or changing something that is already there.
   *
   * The same fields either way — a server is a server — and what differs is the
   * word on the button and whether a blank value means *empty* or *keep what is
   * saved*. Two forms would have been two places to get the scope picker wrong.
   */
  mode?: 'add' | 'edit'
  /** What to open with. Absent means an empty form. */
  start?: McpFormStart
  onSubmit(request: Record<string, unknown>): Promise<McpAddResult>
  /**
   * Called after a server was actually added, carrying what the CLI said.
   *
   * The message is passed on rather than dropped because the CLI names the file
   * it wrote — "Added stdio MCP server files to user config" — and which of the
   * three configs it landed in is the one thing the user cannot see from the
   * list afterwards.
   */
  onAdded(message: string): void
  onCancel(): void
}

export function McpAddForm({
  projectPath,
  mode = 'add',
  start,
  onSubmit,
  onAdded,
  onCancel,
}: McpAddFormProps) {
  const [draft, setDraft] = useState<McpAddDraft>(start?.draft ?? EMPTY_DRAFT)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const editing = mode === 'edit'
  const savedKeys = start?.savedKeys ?? []

  const choices = scopeChoices(projectPath)
  const stdio = draft.transport === 'stdio'
  const set = <K extends keyof McpAddDraft>(key: K, value: McpAddDraft[K]): void =>
    setDraft((current) => ({ ...current, [key]: value }))

  const missing = missingFrom(draft)

  const submit = async (): Promise<void> => {
    // Checked here as well as on the button, because Return in any field
    // submits a form whose primary button is disabled.
    if (missing !== null) {
      setError(missing)
      return
    }
    setBusy(true)
    setError(null)
    try {
      const result = await onSubmit(draftToRequest(draft, projectPath))
      if (result.ok) {
        // Cleared only on success, so a rejected command is still on screen to
        // be corrected rather than retyped from memory — and only when adding.
        // Blanking an edit form would repaint the person's own server as an
        // empty form for the frame before its caller closes it.
        if (!editing) setDraft(EMPTY_DRAFT)
        onAdded(result.message)
        return
      }
      setError(result.message)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <form
      className="mcp-add"
      onSubmit={(event) => {
        event.preventDefault()
        void submit()
      }}
    >
      <div className="mcp-add-grid">
        <label className="mcp-field">
          <span className="mcp-field-label">Name</span>
          <input
            className="mcp-input"
            value={draft.name}
            onChange={(event) => set('name', event.target.value)}
            placeholder="filesystem"
            spellCheck={false}
            autoComplete="off"
            disabled={busy}
          />
        </label>

        <label className="mcp-field">
          <span className="mcp-field-label">How it is reached</span>
          <select
            className="mcp-input"
            value={draft.transport}
            onChange={(event) => {
              const next = event.target.value
              // Narrowed by comparison rather than asserted: a cast here would
              // be a defect, and the select can only ever hold these three.
              if (next === 'stdio' || next === 'http' || next === 'sse') set('transport', next)
            }}
            disabled={busy}
          >
            <option value="stdio">A command on this machine</option>
            <option value="http">An HTTP server</option>
            <option value="sse">An SSE server</option>
          </select>
        </label>

        <label className="mcp-field mcp-field-wide">
          <span className="mcp-field-label">{stdio ? 'Command' : 'URL'}</span>
          <input
            className="mcp-input"
            value={stdio ? draft.command : draft.url}
            onChange={(event) => set(stdio ? 'command' : 'url', event.target.value)}
            placeholder={stdio ? 'npx -y @modelcontextprotocol/server-filesystem ~/Documents' : 'https://example.com/mcp'}
            spellCheck={false}
            autoComplete="off"
            disabled={busy}
          />
          {/* The caption that used to be here said what the placeholder in the
              box already shows. *"Don't put any single statement in anywhere…
              Let the smart people use it."* */}
        </label>

        <label className="mcp-field mcp-field-wide">
          <span className="mcp-field-label">
            {stdio ? 'Environment variables' : 'Headers'}
            {/*
              The one thing about this box that cannot be read off it, and only
              on the screen where it is true. A value this app is not allowed to
              show, on a line that looks empty, needs saying out loud — the
              alternative is somebody pressing Save and wiping the key they came
              here to keep.
            */}
            {editing && stdio && savedKeys.length > 0 && (
              <HoverNote label="Leave a value blank to keep it">
                {`${savedKeys.join(', ')} already ${savedKeys.length === 1 ? 'has a value' : 'have values'} in your configuration, and this app is never sent them — so they are shown with nothing after the =. A line left that way keeps what is saved. Type something to replace it. Delete the whole line to drop the variable.`}
              </HoverNote>
            )}
          </span>
          <textarea
            className="mcp-input mcp-textarea"
            value={draft.extras}
            onChange={(event) => set('extras', event.target.value)}
            placeholder={stdio ? 'API_KEY=…' : 'Authorization: Bearer …'}
            spellCheck={false}
            rows={2}
            disabled={busy}
          />
          {/* Same: `API_KEY=…` in the box is the format, and a line saying so
              underneath is the same thing twice. A pasted line in the wrong
              shape is refused by name — see `resolveRequest`. */}
          {/*
            Headers are the one thing an edit genuinely cannot preserve, so it
            says so rather than quietly dropping them. This app's reader does not
            read an HTTP server's headers back out of the configuration — it has
            never needed to — and an edit is a remove followed by an add, so
            whatever is in this box is what the server ends up with.
          */}
          {editing && !stdio && (
            <span className="mcp-field-hint">
              This app does not read an HTTP server’s headers back, so it cannot show you the ones
              that are there. Saving replaces them with whatever is in this box.
            </span>
          )}
        </label>

        <label className="mcp-field mcp-field-wide">
          <span className="mcp-field-label">
            Save it for
            {/*
              The one caption on this form that survives, and it is behind the
              dot rather than on the page. Three scopes are three different
              files with three different lifetimes, and the shared one comes
              back needing an approval — none of which the option labels can
              carry. His rule, verbatim: *"if somewhere it's very required, give
              the i icon like other ones."*
            */}
            <HoverNote label="Where this gets saved">
              {`${choices.find((choice) => choice.value === draft.scope)?.help ?? ''}${
                projectPath ? '' : ' Open a project to save one for that project alone.'
              }`}
            </HoverNote>
          </span>
          <select
            className="mcp-input"
            value={draft.scope}
            onChange={(event) => {
              const next = event.target.value
              if (next === 'user' || next === 'local' || next === 'project') set('scope', next)
            }}
            disabled={busy}
          >
            {choices.map((choice) => (
              <option key={choice.value} value={choice.value}>
                {choice.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      {error && <p className="mcp-error">{error}</p>}

      <div className="mcp-add-actions">
        <button
          type="submit"
          className="mcp-run"
          disabled={busy || missing !== null}
          // The reason is on the button rather than only in the error line, so
          // it is readable before the click as well as after it.
          title={missing ?? undefined}
        >
          {busy ? (editing ? 'Saving…' : 'Adding…') : editing ? 'Save changes' : 'Add server'}
        </button>
        <button type="button" className="mcp-server-action" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
      </div>
    </form>
  )
}
