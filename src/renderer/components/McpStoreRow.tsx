import { HoverNote } from './HoverNote'
import {
  mcpLinkOut,
  needsWords,
  ORIGIN_WORDS,
  RUNTIME_WORDS,
  unfilled,
  type McpStoreInput,
  type McpStoreRow as Row,
} from './mcp-store-bridge'
import { StoreLinkOut } from '../store/StoreLinkOut'
import { StoreRowName } from '../store/StoreRowName'
import { StoreLogo } from '../store/StoreLogo'

/**
 * One row of the MCP store.
 *
 * ## What a row is allowed to say
 *
 * The same contract `browser/ToolRow.tsx` holds itself to: the facts on the row
 * are not decoration, they are the disclosure the install is checked against.
 * `mcp-store.ts` refuses an install whose runtime is missing or whose required
 * value is unfilled, and prints the same words the row printed — so what is on
 * screen and what happens are the same thing or neither happens.
 *
 * Four facts, and each earns its line:
 *
 *  - **Source** — the project, as a URL, because *"most probably most of the
 *    open sourced one"* is a claim a person is entitled to check rather than be
 *    told. The registry entry is beside it, because that is the thing that is
 *    actually fetched and the two are not always the same organisation.
 *  - **How it runs** — `npx`, `uvx` or `docker`, said plainly, because it is the
 *    difference between something that starts in a second and something that
 *    pulls a container image.
 *  - **Needs** — a token, a path, or nothing, **before** the button rather than
 *    after. A row that cannot work without a key and does not say so until the
 *    install fails is the defect this store was written against.
 *  - **Command** — exactly what will be written into the configuration, with the
 *    placeholders visible. Nothing is added behind it.
 *
 * ## The button, and the row that has none
 *
 * A row whose runtime is not on this machine, or whose name is already taken by
 * a server this store did not write, carries **no Install** — not a disabled one
 * — and one sentence saying which of those it is. That is the browser store's
 * rule for its "cannot work in this browser" rows, and it exists because a
 * greyed-out button is a thing people press repeatedly and a sentence is a thing
 * they read once.
 *
 * It carries **Get it** instead, which opens the project's own page and writes
 * nothing. The refusal is unchanged; what it stops being is a dead end.
 *
 * ## The chip
 *
 * The store browses by shelf now — Databases, Driving a browser — so a row with
 * no Install sits under a heading about what it does rather than under one about
 * why it cannot be had. One word in the head says which kind it is; the sentence
 * below still says why, in the main process's own words.
 */

/** What one press will do, in the word the button wears. Pure, so a test pins it. */
export function actionLabel(row: Row, busy: boolean): string {
  if (busy) return 'Working…'
  return row.state === 'installed' ? 'Remove' : 'Install'
}

/** Which verb that press sends. The other half of {@link actionLabel}. */
export function actionVerb(row: Row): 'install' | 'remove' {
  return row.state === 'installed' ? 'remove' : 'install'
}

/**
 * Whether this row draws a button at all.
 *
 * `blocked` is the main process's sentence and it is the single source of the
 * answer: anything with something to say about why it cannot be installed says
 * it instead of offering a control. An installed row always keeps its Remove —
 * a runtime that has since been uninstalled does not make the line in the config
 * file undeletable, and that is exactly when somebody wants it gone.
 */
export function hasAction(row: Row): boolean {
  return row.state === 'installed' || row.blocked === ''
}

interface Props {
  row: Row
  busy: boolean
  /** What was typed into this row's fields, keyed by input key. */
  values: Record<string, string>
  /** The sentence the last press on this row produced. */
  said: string
  /** Armed Remove, the two-press shape the servers list already uses. */
  arming: boolean
  onValue(key: string, value: string): void
  onAct(verb: 'install' | 'remove'): void
  onArm(on: boolean): void
  /**
   * Open this server on its own, where there is a page that can show it.
   *
   * Absent everywhere there is not — see `store/StoreRowName.tsx`. It adds a
   * way to look at one row and removes nothing from this one: the command that
   * will be written, what it needs and where it comes from are all still here.
   */
  onOpen?: () => void
}

function fieldType(input: McpStoreInput): string {
  return input.kind === 'secret' ? 'password' : 'text'
}

export function McpStoreRow({
  row,
  busy,
  values,
  said,
  arming,
  onValue,
  onAct,
  onArm,
  onOpen,
}: Props) {
  const missing = unfilled(row, values)
  const verb = actionVerb(row)
  const blocked = missing.length > 0
  /* Where to send somebody this store cannot install it for. `''` on every row
     that has a real Install, so no row ever carries both. */
  const elsewhere = mcpLinkOut(row)

  return (
    <li className="mcp-store-row mcp-store-row-logo" data-state={row.state}>
      {/*
        The mark. Six of these rows wear the Model Context Protocol's own,
        because six of them are that project's reference servers and that is the
        true answer to whose they are — see `McpCatalogueEntry.logo`.
      */}
      <StoreLogo name={row.name} id={row.id} logo={row.logo} />
      <div className="mcp-store-head">
        <StoreRowName name={row.name} className="mcp-store-name" onOpen={onOpen} />
        <span className="mcp-tag">{ORIGIN_WORDS[row.origin]}</span>
        <span className="mcp-tag">{row.licence}</span>
        <span className="mcp-store-version">{row.version}</span>
        {row.state === 'installed' && (
          <span className="mcp-store-state">
            Installed{row.scope === '' ? '' : ` · ${row.scope}`}
          </span>
        )}
        {/*
          The one-word version of why this row has no Install, because the
          sections that used to carry it are gone. The store browses by shelf now
          — Databases, Driving a browser — and a row with no button sitting inside
          one of those would otherwise be a row somebody has to read a paragraph
          of to understand. The chip says which kind; the paragraph underneath
          still says why, in the main process's own words.
        */}
        {row.state === 'unavailable' && (
          <span className="mcp-store-chip mcp-store-chip-no">Cannot run here</span>
        )}
        {row.state === 'taken' && <span className="mcp-store-chip">Name taken</span>}
        <span className="mcp-grow" />

        {/* Remove is armed, exactly as it is on the servers list: this deletes a
            line out of another application's configuration and nothing in this
            app has an undo. */}
        {hasAction(row) && verb === 'remove' && arming && (
          <>
            <button
              type="button"
              className="mcp-server-action"
              data-danger="true"
              disabled={busy}
              onClick={() => onAct('remove')}
            >
              Remove
            </button>
            <button type="button" className="mcp-server-action" onClick={() => onArm(false)}>
              Keep
            </button>
          </>
        )}
        {hasAction(row) && verb === 'remove' && !arming && (
          <button type="button" className="mcp-server-action" disabled={busy} onClick={() => onArm(true)}>
            {actionLabel(row, busy)}
          </button>
        )}
        {hasAction(row) && verb === 'install' && (
          <button
            type="button"
            className="mcp-store-install"
            disabled={busy || blocked}
            title={blocked ? `Fill in ${missing.join(', ')} first` : undefined}
            onClick={() => onAct('install')}
          >
            {actionLabel(row, busy)}
          </button>
        )}
        {/*
          The honest fallback. A row whose runtime is missing, and a row whose
          name is taken by somebody else's server, both correctly get no Install
          — and used to get no control at all, which reads as a dead end rather
          than as the two different true things they are. This opens the
          project's own page, in a tab of this app's browser, and writes nothing
          anywhere. See `store/StoreLinkOut.tsx`.
        */}
        {elsewhere !== '' && (
          <StoreLinkOut url={elsewhere} describes={`open the ${row.name} project`} />
        )}
      </div>

      <p className="mcp-store-summary">{row.summary}</p>

      <dl className="mcp-store-facts">
        <div>
          <dt>Source</dt>
          <dd>
            <a href={row.homepage} target="_blank" rel="noreferrer noopener">
              {row.homepage}
            </a>
          </dd>
        </div>
        <div>
          <dt>Package</dt>
          <dd>
            <a href={row.registry} target="_blank" rel="noreferrer noopener">
              {row.registry}
            </a>
          </dd>
        </div>
        <div>
          <dt>How it runs</dt>
          <dd>{RUNTIME_WORDS[row.runtime]}</dd>
        </div>
        <div>
          <dt>Needs</dt>
          <dd>{needsWords(row)}</dd>
        </div>
        <div>
          <dt>Command</dt>
          <dd>
            <code>{row.command}</code>
          </dd>
        </div>
      </dl>

      {/*
        Every field this row takes, on the row, before the button — and only on a
        row that has a button.

        The fields are not behind a disclosure: a token that is required is the
        first thing somebody has to decide about, and hiding it one click away is
        how a store ends up with an Install that fails.

        `hasAction` is the gate rather than `state !== 'installed'`, and
        rendering the page and looking at it is what caught the difference. The
        *"cannot run on this machine"* and *"a server already has this name"*
        rows were drawing their fields too — a Personal access token box under a
        GitHub row with no Install anywhere on it. Something you can type a
        secret into that nothing can ever use is the dead control this store is
        not allowed to have, and it is worse than an inert button because a
        person can put a real token in it.
      */}
      {hasAction(row) && verb === 'install' && row.inputs.length > 0 && (
        <div className="mcp-store-fields">
          {row.inputs.map((input) => (
            <label className="mcp-field" key={input.key} htmlFor={`mcp-store-${row.id}-${input.key}`}>
              <span className="mcp-field-label">
                {input.label}
                {input.required && <span className="mcp-field-required">*</span>}
                {input.kind === 'secret' && <span className="mcp-tag">secret</span>}
              </span>
              <input
                id={`mcp-store-${row.id}-${input.key}`}
                type={fieldType(input)}
                className="mcp-input"
                autoComplete="off"
                spellCheck={false}
                value={values[input.key] ?? ''}
                placeholder={
                  input.inEnvironment ? `Leave blank to use ${input.key} from your shell` : input.key
                }
                onChange={(event) => onValue(input.key, event.target.value)}
              />
              <span className="mcp-field-hint">{input.hint}</span>
              {/*
                The one place the secret question is answered, and it is answered
                differently depending on what was measured on this machine — see
                `mcp-store.ts` for why there are exactly two places a token can
                live and why a third, encrypted in this app, would be a value
                nothing could decrypt when it was needed.
              */}
              {input.kind !== 'path' && input.into === 'env' && (
                <span className="mcp-field-hint" data-secret="true">
                  {input.inEnvironment ? (
                    <HoverNote label={`${input.key} is already in your shell`}>
                      {`${input.key} is exported by your login shell, which is where sessions run, so leaving this blank writes nothing down at all. One thing that comes with that: opening this server from the servers list starts it from this app rather than from a shell, and this app may not carry that variable — so it can report a missing key there while working perfectly in a session.`}
                    </HoverNote>
                  ) : (
                    <HoverNote label="Where this is kept">
                      {`Typed here, it is written into your Claude Code configuration as ${input.key}=…, in plain text, in a file that only your account can read. That is where the server reads it from, so there is nowhere better for it to be — encrypting it inside this app would put it somewhere nothing could decrypt it at the moment it is needed.`}
                    </HoverNote>
                  )}
                </span>
              )}
            </label>
          ))}
        </div>
      )}

      {/* Something true that Install does not fix — archived, metered, writes to
          your repository. Above the button in reading order, always shown. */}
      {row.caveat !== '' && <p className="mcp-store-caveat">{row.caveat}</p>}

      {/* Why there is no button. Never a greyed-out control with a tooltip. */}
      {row.blocked !== '' && row.state !== 'installed' && <p className="mcp-note">{row.blocked}</p>}
      {row.taken !== '' && (
        <p className="mcp-server-command" title={row.taken}>
          {row.taken}
        </p>
      )}

      {/*
        Only while there is still an install to block. Rendering the page and
        looking at it caught this saying *"Needs Directory it may touch before it
        can be installed"* under an installed `filesystem` row that was plainly
        already installed and carrying a Remove — the fields are hidden once a
        row is installed, so nothing could ever have filled it in.
      */}
      {missing.length > 0 && row.blocked === '' && row.state !== 'installed' && (
        <p className="mcp-run-hint">Needs {missing.join(', ')} before it can be installed.</p>
      )}

      {said !== '' && <p className="mcp-store-said">{said}</p>}
    </li>
  )
}
