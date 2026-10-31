import { basename, type Attachment } from './mentions'
import './AttachChips.css'

/**
 * What is riding along with this message.
 *
 * Each chip is removable, and each says what the agent will actually get,
 * because the three kinds are not the same thing at all: a file arrives as
 * text, a folder as a listing, and an image as an image the model can see. That
 * last one is the surprising one — it was measured rather than assumed — and it
 * is worth the user knowing before they send.
 *
 * ## Where it came from is part of what it is
 *
 * A chip has always shown a project-relative path, which is short because it is
 * relative and unambiguous because everything was in one project. Now that a
 * file can come from anywhere on the disk, `basename` alone would draw
 * `screenshot.png` for a file in the project and `screenshot.png` for one on the
 * desktop — the same six words for two different files, in a row whose whole job
 * is to say what is about to be sent.
 *
 * So an outside attachment is marked, and the mark is the word "outside" rather
 * than a colour: this row is read for its content, and a tint that means
 * something only to whoever wrote it is not a label. The full path is on the
 * hover for both, which is where the disambiguation actually lives.
 */

/**
 * What the agent is being handed, with its article.
 *
 * The article is in the table rather than in the sentence because one of the
 * three words starts with a vowel, and the sentence built with a hard-coded "a"
 * read "sent as a image reference" on every screenshot ever attached. Three
 * strings is cheaper than a rule, and it cannot be wrong for a fourth kind
 * because a fourth kind would have to be added here.
 */
const KIND_LABEL: Record<Attachment['kind'], string> = {
  file: 'a file',
  folder: 'a folder',
  image: 'an image',
}

interface Props {
  attachments: readonly Attachment[]
  onRemove: (path: string) => void
  /** Why the last attempt was refused. Sits with the chips, not in a toast. */
  notice?: string | null
}

export function AttachChips({ attachments, onRemove, notice }: Props) {
  if (attachments.length === 0 && !notice) return null

  return (
    <div className="at-chips">
      {attachments.map((attachment) => (
        <span
          key={attachment.path}
          className={`at-chip at-chip-${attachment.kind}`}
          title={
            attachment.outside === true
              ? `${attachment.path} — outside this project, sent as ${KIND_LABEL[attachment.kind]} reference`
              : `${attachment.relPath} — sent as ${KIND_LABEL[attachment.kind]} reference`
          }
        >
          <span className="at-chip-kind" aria-hidden="true">
            {attachment.kind === 'folder' ? '/' : attachment.kind === 'image' ? '▣' : '·'}
          </span>
          <span className="at-chip-name">{basename(attachment.relPath)}</span>
          {attachment.outside === true ? <span className="at-chip-out">outside</span> : null}
          <button
            type="button"
            className="at-chip-x"
            onClick={() => onRemove(attachment.path)}
            aria-label={`Remove ${attachment.relPath}`}
            title="Remove"
          >
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
              <path d="M6 6l12 12M18 6L6 18" strokeWidth="2.4" strokeLinecap="round" />
            </svg>
          </button>
        </span>
      ))}
      {notice ? (
        <span className="at-chips-notice" role="status">
          {notice}
        </span>
      ) : null}
    </div>
  )
}
