import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { AttachPicker, type PickerMode } from './AttachPicker'
import { McpServers } from './McpServers'
import type { Attachment } from './mentions'
import './AttachMenu.css'

/**
 * The plus button and everything behind it.
 *
 * One popover with three faces — a short menu, a picker, the connector list —
 * rather than three floating surfaces, because every one of these ends the same
 * way: something is added to the message and focus goes back to the box the
 * user was typing in.
 */

export type AttachSurface = PickerMode | 'mcp'

interface Props {
  root: string
  attachments: readonly Attachment[]
  /** Project-relative path chosen in the picker. The composer validates it. */
  onAdd: (relPath: string, isDirectory: boolean) => void
  /** Free text to drop into the message, used by the connector list. */
  onInsert: (text: string) => void
  /** Called on every close so the composer can take focus back. */
  onClose: () => void
  disabled?: boolean
}

interface MenuItem {
  surface: AttachSurface
  label: string
  hint: string
  icon: ReactNode
}

const ITEMS: MenuItem[] = [
  {
    surface: 'file',
    label: 'Add files',
    hint: 'Sent as a reference the agent reads',
    icon: (
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" strokeWidth="1.6" strokeLinejoin="round" />
        <path d="M14 3v5h5" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
    ),
  },
  {
    surface: 'folder',
    label: 'Add folder',
    hint: 'The agent gets its listing',
    icon: (
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <path d="M3 7a2 2 0 0 1 2-2h3.6l1.8 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
    ),
  },
  {
    surface: 'image',
    label: 'Add an image',
    hint: 'Screenshots included — the agent sees them',
    icon: (
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <rect x="3" y="5" width="18" height="14" rx="2" strokeWidth="1.6" />
        <path d="M3 16l5-4 4 3 3-2 6 4" strokeWidth="1.6" strokeLinejoin="round" />
      </svg>
    ),
  },
  {
    surface: 'mcp',
    label: 'Connectors',
    hint: 'MCP servers this session can reach',
    icon: (
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <path d="M12 3v6M12 15v6M5 12h14" strokeWidth="1.6" strokeLinecap="round" />
        <circle cx="12" cy="12" r="2.6" strokeWidth="1.6" />
      </svg>
    ),
  },
]

export function AttachMenu({ root, attachments, onAdd, onInsert, onClose, disabled = false }: Props) {
  const [surface, setSurface] = useState<AttachSurface | 'menu' | null>(null)
  const hostRef = useRef<HTMLDivElement>(null)
  const buttonRef = useRef<HTMLButtonElement>(null)

  const close = useCallback(() => {
    setSurface(null)
    onClose()
  }, [onClose])

  // Escape closes from anywhere inside, and a click outside dismisses. Both are
  // registered only while something is open, so the composer costs nothing when
  // the menu is shut.
  useEffect(() => {
    if (surface === null) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        close()
      }
    }
    const onDown = (event: MouseEvent): void => {
      const host = hostRef.current
      if (host && event.target instanceof Node && !host.contains(event.target)) close()
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [surface, close])

  const pick = useCallback(
    (relPath: string, isDirectory: boolean) => {
      onAdd(relPath, isDirectory)
      // Deliberately stays open: attaching three files should be three clicks,
      // not three trips through the menu. The confirmation is the "added" tag
      // the picker puts on the row — measured: this popover is 340×309 anchored
      // over the composer, so it covers the chip row while it is open, and the
      // chips only become the feedback once it closes.
    },
    [onAdd],
  )

  const insert = useCallback(
    (text: string) => {
      onInsert(text)
      close()
    },
    [onInsert, close],
  )

  return (
    <div className="at-host" ref={hostRef}>
      {surface !== null ? (
        <div className="at-pop" role="dialog" aria-label="Attach to this message">
          {surface === 'menu' ? (
            <ul className="at-menu">
              {ITEMS.map((item) => (
                <li key={item.surface}>
                  <button type="button" className="at-item" onClick={() => setSurface(item.surface)}>
                    <span className="at-item-icon">{item.icon}</span>
                    <span className="at-item-text">
                      <span className="at-item-label">{item.label}</span>
                      <span className="at-item-hint">{item.hint}</span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          ) : surface === 'mcp' ? (
            <McpServers root={root} onInsert={insert} onBack={() => setSurface('menu')} />
          ) : (
            <AttachPicker
              root={root}
              mode={surface}
              attachments={attachments}
              onPick={pick}
              onBack={() => setSurface('menu')}
            />
          )}
        </div>
      ) : null}

      {/* Labelled, not a bare plus. It shares `cc-chip` with the controls beside
          it (ChatComposer.css), and the accessible name starts with the word on
          screen so saying "Add" out loud still hits the thing you can see. */}
      <button
        ref={buttonRef}
        type="button"
        className="cc-chip"
        disabled={disabled}
        aria-haspopup="dialog"
        aria-expanded={surface !== null}
        aria-label="Add files, folders, images or connectors to this message"
        title="Add files, folders, images or connectors to this message"
        onClick={() => (surface === null ? setSurface('menu') : close())}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
        </svg>
        Add
      </button>
    </div>
  )
}
