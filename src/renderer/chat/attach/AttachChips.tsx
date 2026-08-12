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
 */

const KIND_LABEL: Record<Attachment['kind'], string> = {
  file: 'file',
  folder: 'folder',
  image: 'image',
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
          title={`${attachment.relPath} — sent as a ${KIND_LABEL[attachment.kind]} reference`}
        >
          <span className="at-chip-kind" aria-hidden="true">
            {attachment.kind === 'folder' ? '/' : attachment.kind === 'image' ? '▣' : '·'}
          </span>
          <span className="at-chip-name">{basename(attachment.relPath)}</span>
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
