import { useState, type DragEvent } from 'react'
import { tabTitle, type WorkspaceTab } from './tabs'

interface Props {
  tabs: WorkspaceTab[]
  activeKey: string
  onSelect(key: string): void
  onClose(key: string): void
  onOpen(): void
  onReorder(key: string, toIndex: number): void
}

/**
 * The tab strip.
 *
 * Reordering is a drag, and the only interesting part is that the drop target
 * has to be the tab you are hovering rather than a gap between tabs: gaps are
 * two pixels wide, and a drop that misses one does nothing, which reads as the
 * feature being broken. Dropping *on* a tab means "take its place", which is
 * what the pure `moveTab` implements and what every browser does.
 */
export function TabStrip({ tabs, activeKey, onSelect, onClose, onOpen, onReorder }: Props) {
  const [dragKey, setDragKey] = useState<string | null>(null)
  const [overKey, setOverKey] = useState<string | null>(null)

  const startDrag = (event: DragEvent<HTMLDivElement>, key: string): void => {
    setDragKey(key)
    event.dataTransfer.effectAllowed = 'move'
    // Firefox refuses to start a drag without data on the transfer; Electron is
    // Chromium, but this costs nothing and makes the drag testable by hand.
    event.dataTransfer.setData('text/plain', key)
  }

  const dropOn = (event: DragEvent<HTMLDivElement>, key: string): void => {
    event.preventDefault()
    const from = dragKey
    setDragKey(null)
    setOverKey(null)
    if (!from || from === key) return
    onReorder(from, tabs.findIndex((tab) => tab.key === key))
  }

  return (
    <div className="bw-strip" role="tablist" aria-label="Browser tabs">
      <div className="bw-strip-tabs">
        {tabs.map((tab) => (
          <div
            key={tab.key}
            className="bw-tab"
            role="presentation"
            draggable
            data-active={tab.key === activeKey || undefined}
            data-over={tab.key === overKey && tab.key !== dragKey ? '' : undefined}
            data-dragging={tab.key === dragKey || undefined}
            onDragStart={(event) => startDrag(event, tab.key)}
            onDragEnd={() => {
              setDragKey(null)
              setOverKey(null)
            }}
            onDragOver={(event) => {
              event.preventDefault()
              event.dataTransfer.dropEffect = 'move'
              setOverKey(tab.key)
            }}
            onDragLeave={() => setOverKey((current) => (current === tab.key ? null : current))}
            onDrop={(event) => dropOn(event, tab.key)}
          >
            <button
              type="button"
              className="bw-tab-face"
              role="tab"
              aria-selected={tab.key === activeKey}
              title={tab.url || tabTitle(tab)}
              onClick={() => onSelect(tab.key)}
              onAuxClick={(event) => {
                // Middle click closes, as it does everywhere else.
                if (event.button === 1) onClose(tab.key)
              }}
            >
              <StatusDot tab={tab} />
              <span className="bw-tab-title">{tabTitle(tab)}</span>
            </button>
            <button
              type="button"
              className="bw-tab-close"
              aria-label={`Close ${tabTitle(tab)}`}
              onClick={() => onClose(tab.key)}
            >
              <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden="true">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          </div>
        ))}
      </div>

      <button type="button" className="bw-tab-new" aria-label="New browser tab" onClick={onOpen}>
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
          <path d="M12 5v14M5 12h14" />
        </svg>
      </button>
    </div>
  )
}

/**
 * One glyph carrying three states, because a tab is 160px wide and three
 * separate indicators would leave no room for the title. Recording wins over
 * loading: it is the one that is unsafe to forget about.
 */
function StatusDot({ tab }: { tab: WorkspaceTab }) {
  if (tab.recording) {
    return <span className="bw-tab-dot" data-kind="recording" aria-label="Recording" role="img" />
  }
  if (tab.loading) {
    return <span className="bw-tab-dot" data-kind="loading" aria-label="Loading" role="img" />
  }
  if (tab.inspecting) {
    return <span className="bw-tab-dot" data-kind="inspecting" aria-label="Inspecting" role="img" />
  }
  return <span className="bw-tab-dot" data-kind="idle" aria-hidden="true" />
}
