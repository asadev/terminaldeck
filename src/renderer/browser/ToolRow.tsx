import { GRANT_WORDS, originWords, type StoreTool } from './store-bridge'

/**
 * One row of the store's built-in half — a page-reading tool.
 *
 * This file held the whole "Browser tools" dialog until the store was unified:
 * two doors — Tools with six built-in recipes, Extensions with the real
 * downloads — when what Asad asked for was one store, *"a tools store for
 * extensions to this browser with all open source best tools in the market …
 * which tools will not be here only when they download."* A store surface named
 * Tools in which nothing downloads was that ask inverted, so the dialog now
 * lives in `StorePanel.tsx`, holding both halves, and this file is the row.
 *
 * ## What a row promises, and why it says so much
 *
 * The facts on a row are not decoration — they are the disclosure the install
 * is checked against. `browser-store.ts` refuses a tool whose recipe asks for a
 * grant or an origin this row did not say, so what is on screen and what runs
 * are the same thing or neither happens.
 *
 * ## The Source fact: a built-in must not pretend to be a download
 *
 * Every row now says where its bytes come from, and the two answers are
 * different kinds of thing, said in different words. A bundled tool says
 * outright that it ships inside this app and that installing it downloads
 * nothing — because a store that let its built-ins sit indistinguishable
 * beside its downloads would be dressing the six things it wrote itself as
 * the open-source catalogue he asked for. A fetched tool says the exact URL
 * and the exact fingerprint the download must match, before anybody presses
 * anything — a store that says "verified" and will not say against what is
 * asking for the same trust it exists to replace.
 */

/**
 * What one press will do, in the one word the button wears.
 *
 * Pure and exported because a button whose label disagrees with its handler is
 * the defect this app names outright — a control that looks like it works and
 * does something else — and a label assembled inline out of three ternaries is
 * exactly where that happens. `damaged` says Remove and not Reinstall: the file
 * on disk is not the one that was installed, and the honest first move is to
 * delete it.
 */
export function actionLabel(tool: StoreTool, busy: boolean): string {
  if (busy) return 'Working…'
  if (tool.state === 'installed' || tool.state === 'damaged') return 'Remove'
  return tool.fetched ? 'Download' : 'Install'
}

/** Which verb that press sends. The other half of {@link actionLabel}. */
export function actionVerb(tool: StoreTool): 'install' | 'remove' {
  return tool.state === 'installed' || tool.state === 'damaged' ? 'remove' : 'install'
}

interface RowProps {
  tool: StoreTool
  busy: boolean
  /** The sentence the last press on this row produced. */
  said: string
  onAct(verb: 'install' | 'remove'): void
}

/**
 * One row: the facts, one button, and whatever the last press said.
 *
 * Exported so it can be rendered on its own — this project has no DOM in its
 * test setup, so a dialog's first paint under SSR is an empty shell and the row
 * is where everything worth asserting lives.
 */
export function ToolRow({ tool, busy, said, onAct }: RowProps) {
  const verb = actionVerb(tool)
  const installed = tool.state === 'installed'
  return (
    <li className="bw-store-row">
      <div className="bw-store-head">
        <span className="bw-store-name">{tool.name}</span>
        <span className="bw-store-version">{tool.version}</span>
        {/* The state, said rather than implied by which button is drawn — in
            the unified store the built-in section is one list, so a row carries
            its own answer to "do I have this". */}
        {installed && <span className="bw-store-state">Installed</span>}
        <span className="bw-grow" />
        <button
          type="button"
          className={verb === 'remove' ? 'bw-text-button' : 'bw-store-install'}
          disabled={busy}
          onClick={() => onAct(verb)}
        >
          {actionLabel(tool, busy)}
        </button>
      </div>

      <p className="bw-store-summary">{tool.summary}</p>

      <dl className="bw-store-facts">
        <div>
          <dt>Reads</dt>
          <dd>{tool.grants.map((grant) => GRANT_WORDS[grant] ?? grant).join('. ') || 'nothing'}</dd>
        </div>
        <div>
          <dt>Runs on</dt>
          <dd>{originWords(tool.origins)}</dd>
        </div>
        <div>
          <dt>Licence</dt>
          <dd>{tool.licence}</dd>
        </div>
        <div>
          <dt>Source</dt>
          <dd>
            {tool.fetched
              ? tool.url
              : 'Built into this app. Installing it downloads nothing — it ships in the app’s own bytes.'}
          </dd>
        </div>
        {/* Only for a download: what its bytes must hash to, pinned in this
            app, before or after the fetch. A built-in is verified against the
            same kind of digest, but printing a fingerprint for a thing that is
            never fetched would dress it as a download. */}
        {tool.fetched && (
          <div>
            <dt>sha256</dt>
            <dd>
              <code>{tool.sha256}</code>
              {installed
                ? ' — the download matched this before it was saved, and is checked against it again every time it is read.'
                : ' — the download must match this, or nothing is saved.'}
            </dd>
          </div>
        )}
        {/* Only once it is installed, because until then there is no file to
            read the field names out of, and inventing them from the catalogue
            would be this panel's word rather than the recipe's. */}
        {tool.reads.length > 0 && (
          <div>
            <dt>Collects</dt>
            <dd>{tool.reads.join(', ')}</dd>
          </div>
        )}
      </dl>

      {tool.state === 'damaged' && <p className="bw-error">{tool.message}</p>}
      {said !== '' && <p className="bw-store-said">{said}</p>}
    </li>
  )
}
