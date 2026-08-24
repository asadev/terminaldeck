import { HoverNote } from './HoverNote'
import {
  COST_LABELS,
  mcpLinkOut,
  needsWords,
  runsWords,
  sourceWords,
  unfilled,
  type McpStoreInput,
  type McpStoreRow as Row,
} from './mcp-store-bridge'
import { StoreLinkOut } from '../store/StoreLinkOut'
import { StoreRowName } from '../store/StoreRowName'
import { StoreLogo } from '../store/StoreLogo'
import { StoreRowMore } from '../store/StoreRowMore'

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
 * ## Where each of the four is, since the shelf was screenshotted
 *
 * All four are still on the row and none of them changed a word. Two of them —
 * *How it runs* and *Needs* — are the two a person weighs while scanning, so
 * they are one line under the summary; the other two are looked **up**, by
 * somebody checking a particular thing, so they are folded behind a line that
 * names them. `store/StoreRowMore.tsx` carries the measurement: printed inline,
 * these five definition rows put **one server on a 1440px screen**.
 *
 * The *Needs* argument above is what decides where the fold stops, and it is
 * about the **sentence**, not about the form. `Needs Personal access token` is
 * unfolded, on the row, in words, before anything is pressed. The boxes those
 * words name are behind Install — see {@link Props.asking} and the ask below.
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
 * ## Press Install, and it asks for what it needs
 *
 * This is a reversal, and the thing it reverses was right about a defect and
 * wrong about where the fix belonged. The rule used to be:
 *
 *   > *The fields are not behind a disclosure: a token that is required is the
 *   > first thing somebody has to decide about, and hiding it one click away is
 *   > how a store ends up with an Install that fails.*
 *
 * That argument is about **disclosure**, and it was carrying the form as well as
 * the sentence because at the time the row had nothing else to say it with. The
 * density pass gave it one: `Runs with npx … · Needs Personal access token,
 * Project reference` is unfolded, on the row, in the catalogue's own words,
 * before the button. Disclosure is satisfied there.
 *
 * What the form cost, measured on the shipped page at 1440x900 over the real
 * catalogue: an extension row is 137px and an MCP row was **372–420px**, of
 * which roughly 90px per required input is label, box, hint and a hover dot —
 * and `supabase` takes two. Standing on *Databases*, **no row at all** was
 * fully on screen. Every person browsing paid for a form that only the person
 * installing that one row will ever type into.
 *
 * So the boxes moved behind the press: Install on a row with inputs opens the
 * ask, in place, carrying the same fields, the same hints, the same
 * "where this is kept" note and the same links to where a person gets the key.
 * Nothing was reworded and nothing was dropped.
 *
 * **Why the defect the old rule feared cannot come back.** It feared an Install
 * that fails for a value nobody was asked for. Three things stop that, and none
 * of them is a habit:
 *
 *  - The row **says what it needs** before the button, unfolded — the `Needs`
 *    half of the line above, from `needsWords`, which is the catalogue's answer
 *    rather than this component's.
 *  - Install on a row with inputs **cannot install**. It opens the ask; only the
 *    ask's own button calls `onAct('install')`, and that one is disabled while
 *    {@link unfilled} is non-empty, with the missing labels named under it. A
 *    press that silently writes a half-filled config has no code path.
 *  - `mcp-store.ts` refuses the install a second time, in the process that does
 *    the writing, printing the same words. Both ends check, as they always did.
 *
 * **Cancelling installs nothing.** It cannot: the only write is
 * `mcpStoreInstall`, and the ask's Cancel does not call it. What it does do is
 * throw away what was typed — see `McpStore.tsx` — so a cancelled ask leaves no
 * secret in this window's state either.
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
  /**
   * The ask is open on this row: Install was pressed and it is collecting what
   * the row said it needs.
   *
   * State rather than a derived answer, and owned by the store rather than by
   * the row, for the same reason {@link Props.arming} is: only one row on a
   * shelf may be mid-question at a time, and a boolean per row would eventually
   * be two of them true. It also means a row rendered by a test or the harness
   * can be stood in either state with one prop — which is the only way the
   * asking half of this component is ever looked at.
   */
  asking: boolean
  onValue(key: string, value: string): void
  onAct(verb: 'install' | 'remove'): void
  onArm(on: boolean): void
  /**
   * Open or shut the ask.
   *
   * Shutting it is a cancel: nothing is written, and the store drops what was
   * typed into this row rather than keeping it for a press that may never come.
   */
  onAsk(on: boolean): void
  /**
   * Open this server on its own, where there is a page that can show it.
   *
   * Absent everywhere there is not — see `store/StoreRowName.tsx`. It adds a
   * way to look at one row and removes nothing from this one: the command that
   * will be written, what it needs and where it comes from are all still here.
   */
  onOpen?: () => void
  /**
   * Open this row in the edit form. Absent means this build's preload has no
   * `mcp:edit`, and the button is then **not drawn** rather than drawn dead —
   * the standing rule for a control that cannot do anything.
   */
  onEdit?(): void
  /** Write this row out as a file somebody else can read. Same rule. */
  onExport?(): void
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
  asking,
  onValue,
  onAct,
  onArm,
  onAsk,
  onOpen,
  onEdit,
  onExport,
}: Props) {
  const missing = unfilled(row, values)
  const verb = actionVerb(row)
  const blocked = missing.length > 0
  /*
   * Whether pressing Install has a question to ask first.
   *
   * `inputs.length`, not `missing.length`. A row whose token is already exported
   * by the login shell has nothing *missing* and still has a field — the one
   * that says "Leave blank to use SUPABASE_ACCESS_TOKEN from your shell" — and a
   * store that quietly used a variable a person never saw named would be making
   * the choice for them. Same for a path: `filesystem` installed without asking
   * which directory would write a configuration nobody chose.
   */
  const asks = hasAction(row) && verb === 'install' && row.inputs.length > 0
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
        {/*
          Every chip on the head, in one cluster that wraps inside itself.

          The wrapping is `store/store-page.css`'s — a half-width column cannot
          hold this head on one line and it says so. What it could not decide,
          with the chips as flat children of the head, was *which* child moved:
          at 575px the thing that dropped to line two was **Install**, alone,
          left-aligned under the name, reading as a button belonging to nothing.
          Reproduced on `supabase`, which carries an origin, a price, a licence
          and a version.

          Grouped, the head has three parts — name, this, the controls — and the
          part that gives way is the one made of chips. The name keeps the top
          line and the button stays at its right, which is where a row's action
          is on every other surface in this app.
        */}
        <span className="mcp-store-meta">
        {/* Where it comes from. A custom row says *Added by you*, because
            `origin` is a fact the catalogue established about a project and a
            server this app has never heard of has no such fact. */}
        <span className="mcp-tag">{sourceWords(row)}</span>
        {/*
          What it costs, in the head, next to the licence rather than buried in
          the facts below — because the two answer different questions and the
          licence has been quietly answering both. Nearly every row here is MIT;
          `tavily` is MIT and does nothing at all without a key that is billed.
          A row that printed *MIT* and stopped would be telling the truth in a
          way that leaves somebody worse informed.
        */}
        <span className="mcp-tag" data-cost={row.cost}>
          {COST_LABELS[row.cost]}
        </span>
        {/* Both drawn only when there is one. A hand-written server has no
            licence and no version, and an empty chip beside a name is a fact
            somebody has to squint at to discover is absent. */}
        {row.licence !== '' && <span className="mcp-tag">{row.licence}</span>}
        {row.version !== '' && <span className="mcp-store-version">{row.version}</span>}
        {row.state === 'installed' && (
          <span className="mcp-store-state">
            Installed{row.scope === '' ? '' : ` · ${row.scope}`}
          </span>
        )}
        {/*
          Measured, and separate from the state — after it rather than before it,
          which rendering this and looking at it is what settled. A row reading
          *Cannot start here · Installed* looks like two chips arguing; the true
          order is that it **is** installed and it will not start, and that is
          what the sentence at the foot of the row then explains.

          A server you added whose runtime has since gone never reaches the
          `unavailable` state a catalogue row would, because it is in the
          configuration and will fail when something tries to start it — so it
          keeps every one of its controls, including the Remove somebody almost
          certainly wants at this moment.
        */}
        {row.custom && row.runtimeMissing && (
          <span className="mcp-store-chip mcp-store-chip-no">Will not start here</span>
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
        </span>

        {/*
          The two controls a row somebody typed has that a catalogue row cannot.
          Hidden while the Remove is armed, so the only two things on screen at
          that moment are the question and its two answers.

          **Edit** is the reason this store's custom half is usable at all: the
          only way to change a server before it was to delete it — taking its API
          key with it — and type the key in again. See `src/main/mcp-edit.ts`.

          **Share** writes a plain, readable file holding the definition and no
          values. See `src/main/mcp-share.ts` for why the browser half of this
          store deliberately has no equivalent.
        */}
        {row.custom && !arming && onEdit !== undefined && (
          <button type="button" className="mcp-server-action" disabled={busy} onClick={onEdit}>
            Edit
          </button>
        )}
        {row.custom && !arming && onExport !== undefined && (
          <button type="button" className="mcp-server-action" disabled={busy} onClick={onExport}>
            Share
          </button>
        )}

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
        {/*
          Install, and it is not disabled any more for a value nobody typed.

          It cannot be, because it no longer installs on a row that wants
          something: it opens the ask. A greyed-out Install over a row whose
          fields were three lines below it was the shape that made the fields
          have to be there in the first place. Gone while the ask is open — the
          question and its two answers are the only things on the row then, which
          is the shape armed Remove already uses a few lines above.
        */}
        {hasAction(row) && verb === 'install' && !asking && (
          <button
            type="button"
            className="mcp-store-install"
            disabled={busy}
            onClick={() => (asks ? onAsk(true) : onAct('install'))}
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

      {/*
        The two facts weighed while scanning, on one line, unfolded.

        **How it runs** is the catalogue's phrase for one of three runtimes, or —
        for a server somebody typed — the binary its command actually names and
        whether it was found here. "npx — fetched from npm the first time it
        runs" is true of most rows and a straight lie under
        `/usr/local/bin/serve`.

        **Needs** is what the *catalogue* says a row wants before it can work,
        before the button rather than after, and a custom row has no catalogue
        entry — so it draws no *Needs* at all rather than "Nothing", which would
        be a claim nobody measured.
      */}
      <p className="store-rowline">
        Runs with <b>{runsWords(row)}</b>
        {!row.custom && (
          <>
            {' · Needs '}
            <b>{needsWords(row)}</b>
          </>
        )}
      </p>

      {/*
        The price reality, in the catalogue's own sentence, above the button and
        unfolded: **never imply free when a key costs money**, and a sentence
        somebody reads after pressing Install is a sentence that arrived too
        late.

        Drawn only when there is one to draw. A row that is simply free — the
        filesystem one, the clock — carries no note, and printing *Free.* under a
        chip that already says *Free* would be the padding that teaches people to
        stop reading.
      */}
      {row.costNote !== '' && <p className="store-rowline">{row.costNote}</p>}

      <StoreRowMore label="Source, package and the exact command">
        <dl className="mcp-store-facts">
          {/*
            Both links are drawn only when there is an address behind them. A
            server somebody typed has neither — nobody published it — and an empty
            `<a href="">` is a link to the page you are on, which is the dead
            control this store is not allowed to have. Rendering the store with a
            custom row in it is what caught this.
          */}
          {row.homepage !== '' && (
            <div>
              <dt>Source</dt>
              <dd>
                <a href={row.homepage} target="_blank" rel="noreferrer noopener">
                  {row.homepage}
                </a>
              </dd>
            </div>
          )}
          {row.registry !== '' && (
            <div>
              <dt>Package</dt>
              <dd>
                <a href={row.registry} target="_blank" rel="noreferrer noopener">
                  {row.registry}
                </a>
              </dd>
            </div>
          )}
          {/*
            The variables it carries, by name. Never a value: `configuredForStore`
            sends names, and `mcp-edit.ts` is where a value is merged back in,
            inside the process that already has it.
          */}
          {row.envKeys.length > 0 && (
            <div>
              <dt>Environment</dt>
              <dd>
                {row.envKeys.join(', ')} —{' '}
                {row.envKeys.length === 1 ? 'its value is' : 'their values are'} in your
                configuration and {row.envKeys.length === 1 ? 'is' : 'are'} not shown here.
              </dd>
            </div>
          )}
          <div>
            <dt>{row.transport === 'stdio' ? 'Command' : 'URL'}</dt>
            <dd>
              <code>{row.command}</code>
            </dd>
          </div>
        </dl>
      </StoreRowMore>

      {/*
        What Install asked for.

        The same fields, the same hints, the same links to the page that issues
        the key — nothing here was reworded when it moved behind the press, and
        the header on this file says why it moved and why the *"an Install that
        fails"* defect the old placement guarded against cannot come back.

        `asks` is the gate rather than `state !== 'installed'`, and rendering the
        page and looking at it is what caught the difference in the first place:
        the *"cannot run on this machine"* and *"a server already has this name"*
        rows were drawing their fields too — a Personal access token box under a
        GitHub row with no Install anywhere on it. Something you can type a
        secret into that nothing can ever use is the dead control this store is
        not allowed to have, and it is worse than an inert button because a
        person can put a real token in it. `asks` is built on `hasAction`, so
        those rows have no way into this at all: with no Install there is nothing
        to press, and with nothing to press there is no ask.
      */}
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

      {asks && asking && (
        <div className="mcp-store-ask">
          {/*
            Said again, at the top of the form, and that is not a repeat of the
            row's own Needs line doing nothing. That line is what a person read
            while deciding; this is what they are being asked for now, and a form
            that opens with no sentence over it is a form somebody has to infer
            the purpose of from its first label.
          */}
          <p className="mcp-store-ask-head">
            {row.inputs.some((input) => input.required) ? (
              <>
                {/* `needsWords` and not a second join of the same labels: this
                    sentence and the `Needs …` line on the row above it name the
                    same fields, and two spellings of one field on one row reads
                    as two different things. */}
                <b>{row.name}</b> needs {needsWords(row)}.
              </>
            ) : (
              <>
                <b>{row.name}</b> requires nothing, and these are what it can be
                pointed at.
              </>
            )}{' '}
            Nothing is written until you press Install.
          </p>
          <div className="mcp-store-fields">
            {row.inputs.map((input, at) => (
              <label
                className="mcp-field"
                key={input.key}
                htmlFor={`mcp-store-${row.id}-${input.key}`}
              >
                <span className="mcp-field-label">
                  {input.label}
                  {input.required && <span className="mcp-field-required">*</span>}
                  {input.kind === 'secret' && <span className="mcp-tag">secret</span>}
                  {/*
                    The one place the secret question is answered, and it is
                    answered differently depending on what was measured on this
                    machine — see `mcp-store.ts` for why there are exactly two
                    places a token can live and why a third, encrypted in this
                    app, would be a value nothing could decrypt when it was
                    needed.

                    On the label line, and that is a fix rather than a
                    preference. It used to be a sibling of the hint, which is a
                    flex item in a column — so it drew on a line of its own,
                    beside nothing, under every secret-taking field in the store.
                    Moving it *inside* the hint was not enough either: these
                    hints fill their line, so the dot wrapped alone anyway, and a
                    non-breaking space did not hold it back in Chromium. The
                    label line is short, it is already a flex row with the
                    asterisk and the `secret` chip in it, and the note is about
                    the field rather than about the sentence under it — so here
                    there is always something beside it, at every width.
                  */}
                  {input.kind !== 'path' && input.into === 'env' && (
                    <>
                      {input.inEnvironment ? (
                        <HoverNote label={`${input.key} is already in your shell`}>
                          {`${input.key} is exported by your login shell, which is where sessions run, so leaving this blank writes nothing down at all. One thing that comes with that: opening this server from the servers list starts it from this app rather than from a shell, and this app may not carry that variable — so it can report a missing key there while working perfectly in a session.`}
                        </HoverNote>
                      ) : (
                        <HoverNote label="Where this is kept">
                          {`Typed here, it is written into your Claude Code configuration as ${input.key}=…, in plain text, in a file that only your account can read. That is where the server reads it from, so there is nowhere better for it to be — encrypting it inside this app would put it somewhere nothing could decrypt it at the moment it is needed.`}
                        </HoverNote>
                      )}
                    </>
                  )}
                </span>
                <input
                  id={`mcp-store-${row.id}-${input.key}`}
                  type={fieldType(input)}
                  className="mcp-input"
                  autoComplete="off"
                  spellCheck={false}
                  /*
                    Focus follows the press, into the first box.

                    Not a flourish: the button that opened this is *gone* — it
                    is replaced by the question, the way armed Remove replaces
                    itself — so without this, a keyboard or screen-reader user
                    presses Install and focus falls to the body with no
                    announcement that anything appeared. It also scrolls the ask
                    into view on a shelf, which is what a pointer user wanted
                    anyway.
                  */
                  // eslint-disable-next-line jsx-a11y/no-autofocus
                  autoFocus={at === 0}
                  value={values[input.key] ?? ''}
                  placeholder={
                    input.inEnvironment
                      ? `Leave blank to use ${input.key} from your shell`
                      : input.key
                  }
                  onChange={(event) => onValue(input.key, event.target.value)}
                />
                <span className="mcp-field-hint">{input.hint}</span>
              </label>
            ))}
          </div>

          {/*
            What is still empty, named. The same sentence that used to sit under
            a permanently-visible form; it belongs here now, next to the button
            it is the reason for.
          */}
          {missing.length > 0 && (
            <p className="mcp-run-hint">Needs {missing.join(', ')} before it can be installed.</p>
          )}

          {/*
            The question's two answers, under the fields rather than up in the
            head. Armed Remove keeps its pair in the head because there is
            nothing between the question and the answer there; here there is a
            form, and a confirm at the top of a form is a confirm somebody
            scrolls back up to.

            Which is also why the whole ask sits at the *foot* of the row, under
            the caveat rather than above it. `mcp-store-caveat` is the sentence
            about something Install does not fix — archived, metered, writes to
            your repository — and it is nobody's idea of a disclosure if the
            button that acts on it is three paragraphs higher up.
          */}
          <div className="mcp-store-ask-actions">
            <button
              type="button"
              className="mcp-store-install"
              disabled={busy || blocked}
              onClick={() => onAct('install')}
            >
              {busy ? 'Working…' : 'Install'}
            </button>
            <button type="button" className="mcp-server-action" onClick={() => onAsk(false)}>
              Cancel
            </button>
          </div>
        </div>
      )}

      {said !== '' && <p className="mcp-store-said">{said}</p>}
    </li>
  )
}
