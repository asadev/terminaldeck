import {
  canAct,
  extensionActionLabel,
  extensionActionVerb,
  reachWords,
  type StoreExtension,
} from './extensions-bridge'

/**
 * One row of the store's download half — an open-source browser extension.
 *
 * This file held the whole "Browser extensions" dialog until the store was
 * unified into `StorePanel.tsx`; the reasoning that shaped that dialog moved
 * there with it, and this file is the row.
 *
 * ## Why a row can say "cannot work here" and still be a row
 *
 * Because the first question anybody opens an extension store with is *where is
 * uBlock Origin*, and there are two different true answers: "this app never
 * heard of it" and "it loads and blocks nothing". Omitting it gives the first
 * answer to a person for whom the second is true, and they will go and install
 * it by hand and get the same nothing with no explanation attached.
 *
 * Those rows have **no button**. Not a disabled one either: a disabled Install
 * with a tooltip is still a store offering something, and this app's rule is that
 * a control which looks like it works and does not is the defect. What they have
 * instead is the sentence describing what was measured.
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
  onAct(verb: 'install' | 'remove'): void
  onEnable(on: boolean): void
  onOpenPopup(): void
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
  onAct,
  onEnable,
  onOpenPopup,
}: RowProps) {
  const actionable = canAct(extension)
  const isInstalled = extension.state === 'installed'
  return (
    <li className="bw-store-row">
      <div className="bw-store-head">
        <span className="bw-store-name">{extension.name}</span>
        <span className="bw-store-version">{extension.version}</span>
        <span className="bw-grow" />
        {/* An extension that draws a panel of its own gets a way in. Only when
            it has one and only when it is running — a button opening the popup
            of a program that is not loaded has nothing to show. */}
        {isInstalled && extension.enabled && extension.popup !== '' && canOpenPopup && (
          <button type="button" className="bw-text-button" onClick={onOpenPopup}>
            Open panel
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
        {actionable && (
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
        )}
      </div>

      <p className="bw-store-summary">{extension.summary}</p>

      <dl className="bw-store-facts">
        <div>
          <dt>Reaches</dt>
          {/*
            Before the button, always, installed or not. This is the whole of
            what somebody is agreeing to: an extension is a program, and the one
            thing that decides how much of your browsing it sees is the host
            patterns in its manifest.

            The catalogue states it before the install and the manifest on disk
            replaces that answer afterwards — and `browser-extensions.ts` refuses
            an install whose manifest reaches wider than this line said, so the
            two can never be different things.
          */}
          <dd>{reachWords(extension.reach, extension.everywhere)}</dd>
        </div>
        <div>
          <dt>Licence</dt>
          <dd>{extension.licence}</dd>
        </div>
        <div>
          <dt>Project</dt>
          <dd>{extension.homepage}</dd>
        </div>
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
