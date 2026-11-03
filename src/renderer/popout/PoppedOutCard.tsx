import { PageEmpty } from '../components/PageEmpty'
import './popout.css'

/**
 * What the main window shows where a session's terminal was, while that
 * session is in a window of its own.
 *
 * Not the terminal. Two terminals attached to one pty would both type into it
 * and fight over its size, so the main window stops drawing this one while it
 * is out — and says where it went, with the one thing a person wants from
 * here: to get to that window. Moving it back is the quieter second action.
 *
 * The display's name, when there is more than one, because "it is in another
 * window" is not much use to somebody whose other window is on another
 * monitor they are not looking at.
 */

/** A window with an arrow out of its corner — the same mark the bar's button wears. */
export const POPPED_ICON =
  'M15 4h5v5M20 4l-7 7M10 6H6.5A2.5 2.5 0 0 0 4 8.5v9A2.5 2.5 0 0 0 6.5 20h9a2.5 2.5 0 0 0 2.5-2.5V14'

interface Props {
  visible: boolean
  /** The display it is on, when the person has more than one. Empty otherwise. */
  where: string
  onShow(): void
  onDock(): void
}

export function PoppedOutCard({ visible, where, onShow, onDock }: Props) {
  return (
    <div className="popped-pane" data-visible={visible}>
      <PageEmpty
        icon={POPPED_ICON}
        title="Open in its own window"
        action={{ label: 'Show window', onClick: onShow, primary: true }}
        extra={
          <button type="button" className="popped-back" onClick={onDock}>
            Move back here
          </button>
        }
      >
        {where === '' ? null : `On ${where}`}
      </PageEmpty>
    </div>
  )
}
