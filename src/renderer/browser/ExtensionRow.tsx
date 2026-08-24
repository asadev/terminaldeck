import {
  extensionActionLabel,
  extensionActionVerb,
  reachWords,
  type StoreExtension,
} from './extensions-bridge'
import { StoreRowName } from '../store/StoreRowName'
import { StoreLogo } from '../store/StoreLogo'
import { StoreRowMore } from '../store/StoreRowMore'
import { COST_WORDS } from '../store/storefront'

/**
 * One row of the store's download half — an open-source browser extension.
 *
 * This file held the whole "Browser extensions" dialog until the store was
 * unified into `StorePanel.tsx`; the reasoning that shaped that dialog moved
 * there with it, and this file is the row.
 *
 * ## Every row here has an Install, and that is new
 *
 * This file used to draw three kinds of row: one with an Install, one this app
 * watched failing, and one whose project publishes nothing this app can fetch.
 * The last two had no Install and a **Get it** in its place, which opened the
 * project's own page — often the Chrome Web Store. Asad, on what that adds up
 * to:
 *
 *   > *"They click Get and it takes them to the Chrome store … we should not
 *   > offer tools that don't work with our architecture."*
 *
 * So the catalogue stopped holding those rows rather than this file learning to
 * draw them better — see `CatalogueEntry` in `src/main/browser-extensions.ts`,
 * which will not let one be written. What is left here is a row with one action
 * on it, and no branch anywhere deciding whether the action is real.
 *
 * ## The Download and sha256 facts
 *
 * A download row says the exact URL it fetches, the exact byte count it will
 * accept, and the fingerprint the bytes must match — before Install is pressed,
 * because that is the disclosure, and still there after, because "where did this
 * program on my disk come from" deserves a better answer than a homepage link.
 * The words change with the state: *must match* is a promise about a fetch that
 * has not happened, *matched* is a record of one that did. A store that fetches
 * programs and will not say from where, or says "verified" and not against
 * what, is asking for the trust it exists to replace.
 *
 * ## Where those facts are, since this row was screenshotted
 *
 * On the row, folded, under a line that names them. All of them, unchanged, in
 * the markup whether it is open or shut — see `store/StoreRowMore.tsx`, which
 * carries the measurement that forced it: four lines of build metadata and a
 * paragraph of measurement per row put **two rows on a 1440px screen**, and a
 * sixty-four character hash is not something a person reads while choosing an
 * ad blocker.
 *
 * What did **not** fold is what somebody is agreeing to. *Reaches* is the whole
 * of the permission decision and it stays on the shelf — as one line rather than
 * a definition list, because the label column was pushing a three-word answer to
 * a second tab stop. The price sentence stays for the same reason it was put
 * above the button in the first place: a cost read after installing arrived too
 * late. So does anything red.
 *
 * ## Why the switch and the Remove are separate controls
 *
 * Off and gone are different things and a person means one of them. Off calls
 * `removeExtension` — the program stops immediately and does not come back at
 * the next launch — and the files stay, with whatever the extension had stored.
 * Remove deletes them. A store with only Remove makes "stop this for an hour"
 * cost everything the extension knows.
 */

interface RowProps {
  extension: StoreExtension
  busy: boolean
  said: string
  canOpenPopup: boolean
  /** Whether this build's preload carries the settings-page door. */
  canOpenOptions: boolean
  onAct(verb: 'install' | 'remove'): void
  onEnable(on: boolean): void
  onOpenPopup(): void
  onOpenOptions(): void
  /**
   * Open this extension on its own, when there is a page that can show it.
   *
   * Absent everywhere there is not — see `store/StoreRowName.tsx`. It adds a
   * way to *look at* one row and takes nothing off this one: every fact below,
   * the download URL and the fingerprint included, is drawn here whether or not
   * anybody presses it. `StorePanel.test.tsx` pins that, and it is the reason a
   * detail view was refused the first time it was proposed.
   */
  onOpen?: () => void
  /**
   * Copy this one in again from where it came from, and restart it.
   *
   * Only ever handed down for a row somebody added, and only when this build's
   * preload carries the channel. An absent handler draws no button — absent
   * rather than disabled, the standing rule for this whole menu.
   */
  onReload?(): void
  /** Open the rename box on this row, or shut it. */
  onStartRename?(on: boolean): void
  /** The rename box is open on this row. */
  renaming?: boolean
  /** What is typed in it, held by the panel so it survives a re-read. */
  renameDraft?: string
  onRenameDraft?(value: string): void
  onRename?(): void
}

/**
 * One row: what it is, where it comes from, what it reaches, what was measured,
 * and the controls it has actually earned.
 *
 * Exported so it can be rendered on its own — this project has no DOM in its
 * test setup, so a dialog's first paint under SSR is an empty shell and the row
 * is where everything worth asserting lives. The same reason `ToolRow` is.
 */
export function ExtensionRow({
  extension,
  busy,
  said,
  canOpenPopup,
  canOpenOptions,
  onAct,
  onEnable,
  onOpenPopup,
  onOpenOptions,
  onOpen,
  onReload,
  onStartRename,
  renaming = false,
  renameDraft = '',
  onRenameDraft,
  onRename,
}: RowProps) {
  const isInstalled = extension.state === 'installed'
  return (
    <li className="bw-store-row bw-store-row-logo">
      {/*
        The mark, first child and spanning the row — see `store/StoreLogo.css`.
        It is what turns twenty-four paragraphs into a shelf somebody can scan,
        and it comes out of this app's own bundle rather than off the vendor's
        server. A row with no mark, which is every extension somebody added from
        a folder, gets this app's own monogram rather than a broken picture.
      */}
      <StoreLogo name={extension.name} id={extension.id} logo={extension.logo} />
      <div className="bw-store-head">
        <StoreRowName name={extension.name} className="bw-store-name" onOpen={onOpen} />
        {/* A version only when there is a release this app has actually got
            hold of. A number under a name this app has never run would be one
            more true-looking thing that is not a measurement. */}
        {extension.version !== '' && (
          <span className="bw-store-version">{extension.version}</span>
        )}
        {/*
          What it costs, in the head, before anything is pressed.

          Every extension in a browser store is a free download, so *free to
          install* had been quietly standing in for *free to use* — which is
          true of uBlock Origin and was false of the rows that wanted a
          subscription. Those rows are gone and every row here reads Free, and
          the chip stays: a price that only appeared on the expensive rows would
          make its absence a claim as well, and the next row added may not be
          free.
        */}
        <span className="bw-store-chip" data-cost={extension.cost}>
          {COST_WORDS[extension.cost]}
        </span>
        {/*
          Two chips used to sit here — *Cannot work here* and *Nothing measured*
          — for the two kinds of row that had no Install. Neither kind is in the
          store any more, so neither chip is drawn: every catalogue row installs.
          What is left is the one chip that still separates two real things, a
          row this app measured from a folder somebody added themselves.
        */}
        {extension.sideloaded && <span className="bw-store-chip">Added by you</span>}
        <span className="bw-grow" />
        {/* An extension that draws a panel of its own gets a way in. Only when
            it has one and only when it is running — a button opening the popup
            of a program that is not loaded has nothing to show. */}
        {isInstalled && extension.enabled && extension.popup !== '' && canOpenPopup && (
          <button type="button" className="bw-text-button" onClick={onOpenPopup}>
            Open panel
          </button>
        )}
        {/*
          And its settings, which had no door at all until now. An extension can
          declare an options page and no popup — two in this catalogue do — and
          such a thing installed, loaded and ran with nothing anywhere that could
          open it. Drawn on the same terms as the panel: only when it has one,
          and only when it is running.
        */}
        {isInstalled && extension.enabled && extension.optionsPage !== '' && canOpenOptions && (
          <button type="button" className="bw-text-button" onClick={onOpenOptions}>
            Open settings
          </button>
        )}
        {/*
          Editing what you added, which is two things and not one.

          **Reload** copies it in again from the folder or file it came from —
          the loop somebody writing an extension is in all day, and before it
          existed the only route was to find the same folder in a file dialog
          after every build. **Rename** changes the name this row wears, which is
          the only part of somebody else's program this app wrote down and
          therefore the only part it has any business editing. The rest of an
          extension is changed by changing the extension and pressing Reload.

          Both only on a row somebody added, both only when the preload carries
          them, and neither while the rename box is open — the two answers to an
          open question are the only things that should be beside it.
        */}
        {extension.sideloaded && isInstalled && !renaming && onReload !== undefined && (
          <button type="button" className="bw-text-button" disabled={busy} onClick={onReload}>
            Reload
          </button>
        )}
        {extension.sideloaded && isInstalled && !renaming && onStartRename !== undefined && (
          <button
            type="button"
            className="bw-text-button"
            disabled={busy}
            onClick={() => onStartRename(true)}
          >
            Rename
          </button>
        )}
        {isInstalled && (
          <label className="bw-ext-switch">
            <input
              type="checkbox"
              checked={extension.enabled}
              disabled={busy}
              onChange={(event) => onEnable(event.target.checked)}
            />
            On
          </label>
        )}
        {/*
          Unconditional, where it used to be behind `canAct`. Every row in this
          store installs, so there is no longer a row for which this button
          would be a lie — and nothing beside it opens somebody else's store.
        */}
        <button
          type="button"
          className={
            extensionActionVerb(extension) === 'remove' ? 'bw-text-button' : 'bw-store-install'
          }
          disabled={busy}
          onClick={() => onAct(extensionActionVerb(extension))}
        >
          {extensionActionLabel(extension, busy)}
        </button>
      </div>

      {/*
        The rename box, under the head rather than inside it: a text field wedged
        between the switch and the Remove would reflow the whole row's controls
        every time it opened.
      */}
      {renaming && onRenameDraft !== undefined && onRename !== undefined && (
        <div className="bw-store-rename">
          <input
            className="bw-store-rename-input"
            value={renameDraft}
            placeholder={extension.name}
            spellCheck={false}
            autoComplete="off"
            aria-label={`A name for ${extension.name}`}
            disabled={busy}
            onChange={(event) => onRenameDraft(event.target.value)}
          />
          <button
            type="button"
            className="bw-store-install"
            disabled={busy || renameDraft.trim() === ''}
            onClick={onRename}
          >
            {busy ? 'Working…' : 'Save'}
          </button>
          <button
            type="button"
            className="bw-text-button"
            disabled={busy}
            onClick={() => onStartRename?.(false)}
          >
            Cancel
          </button>
        </div>
      )}

      <p className="bw-store-summary">{extension.summary}</p>

      {/*
        What somebody is agreeing to, on the shelf, before the button, installed
        or not. An extension is a program, and the one thing that decides how
        much of your browsing it sees is the host patterns in its manifest.

        The catalogue states it before the install and the manifest on disk
        replaces that answer afterwards — and `browser-extensions.ts` refuses an
        install whose manifest reaches wider than this line said, so the two can
        never be different things.

        A line rather than the first row of a definition list: it is the one
        fact read while scanning, and the label column was pushing *every page
        you open in this profile* out to a second tab stop for nothing.
      */}
      <p className="store-rowline">
        Reaches <b>{reachWords(extension.reach, extension.everywhere)}</b>
      </p>

      {/*
        The price reality, in the catalogue's own sentence, above the button and
        unfolded — because a cost somebody reads after pressing Install arrived
        too late, which is the one argument that survives every pass over this
        row. Drawn only when there is one: a row that is simply free carries
        none, and printing *Free.* under a chip that already says *Free* is the
        padding that teaches people to stop reading.
      */}
      {extension.costNote !== '' && <p className="store-rowline">{extension.costNote}</p>}

      <StoreRowMore label="Licence, download, checksum and what was measured">
        <dl className="bw-store-facts">
          {/*
            What it would like to reach and never will. `optional_host_permissions`
            is a real part of a manifest and this browser can grant none of it:
            there is no runtime prompt here, and the compatibility layer answers
            permissions.request() with false. Left off the row entirely, this reads
            as an extension that asks for less than it does.

            Folded rather than beside *Reaches*, and the difference is that this
            one is a promise about what can never happen: the sentence is thirty
            words and it qualifies a decision the line above has already stated
            truthfully.
          */}
          {extension.mayAsk.length > 0 && (
            <div>
              <dt>Would like to reach</dt>
              <dd>
                {extension.mayAsk.join(', ')} — it can ask for this at any time and this browser
                always answers no, so it never gets it.
              </dd>
            </div>
          )}
          {extension.licence !== '' && (
            <div>
              <dt>Licence</dt>
              <dd>{extension.licence}</dd>
            </div>
          )}
          {extension.homepage !== '' && (
            <div>
              <dt>Project</dt>
              <dd>{extension.homepage}</dd>
            </div>
          )}
          {/*
            Where a folder or a .crx somebody added came from, and what its
            signature is worth. Both on the row for the same reason the URL and
            the digest are on a catalogue row: "where did this program on my disk
            come from" has an answer and it is not a shrug.
          */}
          {extension.sideloaded && extension.origin !== '' && (
            <div>
              <dt>Added from</dt>
              <dd>
                <code>{extension.origin}</code>
              </dd>
            </div>
          )}
          {extension.sideloaded && extension.crxId !== '' && (
            <div>
              <dt>Signed as</dt>
              <dd>
                <code>{extension.crxId}</code> — its signature matched its contents, which says the
                file has not changed since it was packed and says nothing at all about who packed
                it. That id is the fingerprint of the signing key.
              </dd>
            </div>
          )}
          {/*
            Where the bytes come from and what they must hash to — drawn only when
            there is a download at all. A row this app measured failing pins no
            download, and printing a URL under it would offer provenance for a
            fetch that can never happen.
          */}
          {extension.url !== '' && (
            <div>
              <dt>Download</dt>
              <dd>
                {extension.url}
                {extension.bytes > 0 ? ` — ${extension.bytes.toLocaleString('en-US')} bytes, exactly` : ''}
              </dd>
            </div>
          )}
          {extension.url !== '' && extension.sha256 !== '' && (
            <div>
              <dt>sha256</dt>
              <dd>
                <code>{extension.sha256}</code>
                {isInstalled || extension.state === 'damaged'
                  ? ' — the download matched this before it was unpacked.'
                  : ' — the download must match this, or nothing is saved.'}
              </dd>
            </div>
          )}
          {extension.missing.length > 0 && (
            <div>
              <dt>Not available here</dt>
              <dd>{extension.missing.map((api) => `chrome.${api}`).join(', ')}</dd>
            </div>
          )}
          {/*
            What this app had to add to the extension for it to start at all, and
            what is still not there afterwards. Both on the row, because the layer
            rewrote files inside a program somebody agreed to install: an app that
            edits somebody's extension and does not say so is keeping a secret for
            no reason, and one that says "works" without naming what is inert is
            the store row version of a button that does nothing.
          */}
          {extension.provides.length > 0 && (
            <div>
              <dt>Filled in by this app</dt>
              <dd>{extension.provides.map((api) => `chrome.${api}`).join(', ')}</dd>
            </div>
          )}
          {extension.inert.length > 0 && (
            <div>
              <dt>Still not there</dt>
              <dd>{extension.inert.join('; ')}</dd>
            </div>
          )}
        </dl>

        {/*
          What this app saw, in its own words. On every row, including the ones
          that work: a verdict with no observation behind it is an opinion, and a
          store full of opinions is what this one was written to avoid.

          Inside the disclosure and not below it. This is the longest thing on the
          row — Dark Reader's runs to sixty words — and it is a record of a
          measurement rather than a warning: the two red lines under this block are
          what a person has to be told without pressing anything.
        */}
        <p className="bw-store-said">{extension.measured}</p>

        {/*
          Manifest declarativeNetRequest rulesets are not switched on when an
          extension loads here — `browser-extension-support.ts` measured
          getEnabledRulesets() answering [] with "enabled": true on the resource.
          This used to be the end of the sentence and a red line on the row. It is
          now something this app does something about, once, after installing, and
          the row says which of the two happened rather than keeping the older,
          more alarming half.
        */}
        {extension.state === 'installed' && extension.rulesetsSwitchedOn > 0 && (
          <p className="bw-store-said">
            This browser does not switch manifest declarativeNetRequest rulesets on when an extension
            loads. This app switched its {extension.rulesetsSwitchedOn} on, once, after installing —
            and leaves them alone afterwards, so turning one off in the extension stays off.
          </p>
        )}
      </StoreRowMore>

      {/*
        Everything red stays on the shelf, unfolded.

        A store may fold what it measured; it may not fold what is broken. These
        three are the cases where something on this machine is not doing what the
        row above it appears to promise — a file that is not the one that was
        installed, rules that are not in force, an extension that loaded with a
        complaint — and a person scanning the shelf has to see them without
        pressing anything.
      */}
      {extension.state === 'installed' &&
        extension.rulesetsSwitchedOn === 0 &&
        extension.staticRulesets && (
          <p className="bw-error">
            Its rules ship as manifest declarativeNetRequest rulesets that its own manifest leaves
            off, and this browser does not switch those on, so they are not in force.
          </p>
        )}
      {extension.state === 'damaged' && <p className="bw-error">{extension.message}</p>}
      {extension.state === 'installed' && extension.message !== '' && (
        <p className="bw-error">{extension.message}</p>
      )}
      {said !== '' && <p className="bw-store-said">{said}</p>}
    </li>
  )
}
