// Relative, not '@shared/…' — see the note in `bridge.ts`.
import { KIND_NAMES } from '../../shared/store-manifest'
import { COST_WORDS, type StoreCost } from '../store/storefront'
import { StoreLinkOut } from '../store/StoreLinkOut'
import { StoreLogo } from '../store/StoreLogo'
import { StoreRowMore } from '../store/StoreRowMore'
import { StoreRowName } from '../store/StoreRowName'
import { domainOf, installable, ratingChip, tierWord, type CommunityItem } from './bridge'
import './community.css'

/**
 * One thing somebody else published, on a shelf.
 *
 * ExtensionRow's shape — mark, name, chips, one button, a summary, then exactly
 * one fold — because a store that reads as three stores is what the storefront
 * model was written to stop. What differs is what a community row has to say,
 * and all of it is about the same question: *whose is this, and what can it
 * reach?*
 *
 * ## The fold stays on the shelf
 *
 * `StorePanel.test.tsx` carries a test called *a download row shows URL and
 * fingerprint on this screen, not in a detail view*, and it exists because this
 * was got wrong once. The pinned commit, the artifact address and the sha256 are
 * in this row's markup whether it is folded or not — a `details`, no state, no
 * JavaScript — so an auditor never has to navigate to reach the awkward facts,
 * and the detail page draws them flat because `StoreRowMore` reads
 * `useStoreRowPlace` for itself.
 *
 * The label names what is inside it. *More* would be the summary this store is
 * not allowed to have.
 *
 * ## An off-site listing has no Install, and no greyed one either
 *
 * A paid item we do not host is a classified advertisement: the publisher's own
 * price, and one button out to their own domain. There is no Install anywhere on
 * it — not disabled, not hidden behind a tooltip — because we never touch the
 * money and never hold the bytes, and a button that looks like the one two rows
 * up and does something else is the defect this whole surface is written
 * against.
 *
 * ## What is in the monospace face, and why only that
 *
 * `★ 1,204 · updated 3 days ago · 12 open` is GitHub's numbers, labelled as
 * theirs. The design brief reserves the mono face for data, and on launch day
 * these are the only real signal a row has — the shop has no ratings yet, and a
 * rating chip does not appear until five people have left one.
 */

interface Props {
  item: CommunityItem
  /** Something is in flight for this row, so its button says so. */
  busy: boolean
  /** What the last action on this row answered. `''` when nothing has happened. */
  said: string
  /** Open this row on its own, when there is a page that can show it. */
  onOpen?: () => void
  /** Open the pre-install sheet. Absent on a row that cannot be installed. */
  onInstall?: () => void
  /** Take it off this machine. Absent on a row that is not on it. */
  onRemove?: () => void
}

/**
 * How many days ago, in words, or `''`.
 *
 * Pure and exported because it is the half of the GitHub line that can be wrong
 * without anybody noticing: a date arithmetic mistake reads as a maintained
 * project.
 */
export function updatedWords(iso: string, now: number): string {
  const at = new Date(iso).getTime()
  if (Number.isNaN(at) || at > now) return ''
  const days = Math.floor((now - at) / 86_400_000)
  if (days <= 0) return 'updated today'
  if (days === 1) return 'updated yesterday'
  if (days < 45) return `updated ${days} days ago`
  const months = Math.round(days / 30)
  if (months < 24) return `updated ${months} months ago`
  return `updated ${Math.round(days / 365)} years ago`
}

/**
 * Which of the two buttons this row has earned, or neither.
 *
 * Pure, because "does this row install" is the question the whole safety story
 * rests on and it must be answerable without rendering anything. `null` is a
 * real answer: an off-site listing has a link out and no action at all.
 */
export function rowAction(item: CommunityItem): 'install' | 'update' | 'remove' | null {
  if (!installable(item)) return null
  if (item.state === 'outdated') return 'update'
  if (item.installedVersion !== '') return 'remove'
  return 'install'
}

export function CommunityRow({ item, busy, said, onOpen, onInstall, onRemove }: Props) {
  const action = rowAction(item)
  const rating = ratingChip(item)
  const updated = updatedWords(item.updatedAt, Date.now())
  const domain = domainOf(item.offsiteUrl)

  return (
    <li className="cs-store-row">
      <StoreLogo name={item.name} id={item.id} logo={item.logo} />
      <div className="cs-store-head">
        <StoreRowName name={item.name} className="cs-store-name" onOpen={onOpen} />
        {item.version !== '' && <span className="cs-store-version">{item.version}</span>}
        <span className="cs-grow" />

        {/*
          An off-site listing: one way out, to the publisher's own domain, and
          nothing that looks like an install. `StoreLinkOut` draws nothing at all
          for a URL that is not http(s), so a listing with no address is a row
          with no dead button rather than a row with a broken one.
        */}
        {!installable(item) && domain !== '' && (
          <StoreLinkOut
            url={item.offsiteUrl}
            label={`Get it from ${domain}`}
            describes={`${item.name}, published by @${item.handle}`}
          />
        )}

        {action === 'install' && onInstall !== undefined && (
          <button type="button" className="cs-store-install" disabled={busy} onClick={onInstall}>
            {busy ? 'Installing…' : 'Install'}
          </button>
        )}
        {action === 'update' && onInstall !== undefined && (
          <button type="button" className="cs-store-install" disabled={busy} onClick={onInstall}>
            {busy ? 'Working…' : 'Update'}
          </button>
        )}
        {/*
          Remove sits on every row that has files on this disk, and that includes
          a withdrawn one. The app never uninstalls anything on its own — taking
          a stranger's files off somebody's machine because a form was filled in
          is not a capability a catalogue should have — so removal stays a thing
          a person does, and the button has to be there for them to do it.
        */}
        {item.installedVersion !== '' && onRemove !== undefined && (
          <button type="button" className="cs-text-button" disabled={busy} onClick={onRemove}>
            {busy ? 'Working…' : 'Remove'}
          </button>
        )}
      </div>

      {/*
        The chips, on a line of their own under the name.

        Inline in the head is what the browser department does and it is right
        there — an extension row carries a price and at most one other word. A
        community row carries five, and one of them is a sentence: *Runs a
        program on this machine*. Rendered inline at a half-width column they
        wrapped to three lines and dragged the name down into the middle of
        them, so the first thing read was **Skill · MIT** and the name was
        second. A line of their own costs one row of height and puts the name
        back at the top where it is scanned.
      */}
      <p className="cs-store-meta">
        <span className="cs-store-chip">{KIND_NAMES[item.kind]}</span>
        {item.licence !== '' && <span className="cs-store-chip">{item.licence}</span>}
        <span className="cs-store-chip" data-cost={item.cost}>
          {COST_WORDS[item.cost as StoreCost] ?? item.cost}
        </span>
        {/*
          The tier, in the same words the sheet uses and the phone will use. On
          the shelf rather than behind the fold: it is the one fact that decides
          whether the button above is worth pressing.
        */}
        <span className="cs-store-chip" data-tier={item.tier}>
          {tierWord(item)}
        </span>
        {/* Only from five ratings up, and never on a paid row — see
            `ratingChip`, which is where both rules live. */}
        {rating !== '' && <span className="cs-store-chip">{rating}</span>}
      </p>

      <p className="cs-store-summary">{item.summary}</p>

      {/*
        Whose it is, and a way to go and read about them. `StoreLinkOut` returns
        null for a publisher with no page, so a row without one says `by @handle`
        in plain text rather than offering a link to nowhere.
      */}
      <p className="cs-store-by">
        <span className="cs-quiet">by</span>{' '}
        {item.profileUrl === '' ? (
          <span className="cs-store-handle">@{item.handle}</span>
        ) : (
          <StoreLinkOut
            url={item.profileUrl}
            label={`@${item.handle}`}
            describes={`the page of @${item.handle}, who published ${item.name}`}
          />
        )}
        {/* GitHub's own numbers, said to be GitHub's. Mono, because they are
            data — the design brief keeps that face for exactly this. */}
        {(item.stars >= 0 || updated !== '' || item.openIssues >= 0) && (
          <span className="cs-store-github">
            {item.stars >= 0 ? `★ ${item.stars.toLocaleString('en-GB')}` : ''}
            {item.stars >= 0 && updated !== '' ? ' · ' : ''}
            {updated}
            {item.openIssues >= 0 && (item.stars >= 0 || updated !== '') ? ' · ' : ''}
            {item.openIssues >= 0 ? `${item.openIssues} open` : ''}
          </span>
        )}
      </p>

      {/* The price reality, above the button and never folded: a cost read after
          pressing Install arrived too late. Drawn only when there is one — a
          `Free.` under a chip that already says Free is the padding that teaches
          people to stop reading. */}
      {item.costNote !== '' && <p className="store-rowline">{item.costNote}</p>}

      <StoreRowMore label="Publisher, repository, the exact commit, download and fingerprint">
        <dl className="cs-store-facts">
          <div>
            <dt>Published by</dt>
            <dd>@{item.handle}</dd>
          </div>
          {item.repo !== '' && (
            <div>
              <dt>Repository</dt>
              <dd>{item.repo}</dd>
            </div>
          )}
          {item.commit !== '' && (
            <div>
              <dt>Commit</dt>
              <dd>
                <code>{item.commit}</code>
              </dd>
            </div>
          )}
          {item.artifactUrl !== '' && (
            <div>
              <dt>Download</dt>
              <dd>
                {item.artifactUrl}
                {/* "exactly 15,422 bytes", not "15,422 bytes, exactly" — the word
                    belongs in front of the number it qualifies. Read on screen it
                    landed at the end of a long URL line and looked like a
                    truncation. The claim itself is the point: a download longer
                    or shorter than this is refused before it is opened. */}
                {item.bytes > 0 ? ` — exactly ${item.bytes.toLocaleString('en-GB')} bytes` : ''}
              </dd>
            </div>
          )}
          {item.sha256 !== '' && (
            <div>
              <dt>sha256</dt>
              <dd>
                <code>{item.sha256}</code>
                {item.installedVersion !== ''
                  ? ' — the download matched this before it was unpacked.'
                  : ' — the download must match this, or nothing is saved.'}
              </dd>
            </div>
          )}
          {item.network.length > 0 && (
            <div>
              <dt>Talks to</dt>
              <dd>{item.network.join(', ')}</dd>
            </div>
          )}
          {item.installedVersion !== '' && (
            <div>
              <dt>On this machine</dt>
              <dd>{item.installedVersion}</dd>
            </div>
          )}
        </dl>
      </StoreRowMore>

      {/*
        Everything red stays on the shelf, unfolded.

        A withdrawn row keeps every fact it had and gains a reason. It does not
        vanish — an item that disappeared out from under somebody would leave
        files on their disk with nothing anywhere that names them — and it does
        not delete itself.
      */}
      {item.state === 'withdrawn' && (
        <p className="cs-error">
          {item.reason === '' ? 'Withdrawn from the store.' : `Withdrawn: ${item.reason}`}
        </p>
      )}
      {item.state === 'damaged' && item.message !== '' && <p className="cs-error">{item.message}</p>}
      {said !== '' && <p className="cs-store-said">{said}</p>}
    </li>
  )
}
