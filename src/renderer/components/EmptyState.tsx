interface Props {
  onOpenProject(): void
}

export function EmptyState({ onOpenProject }: Props) {
  return (
    <div className="empty-state">
      <div className="empty-mark" aria-hidden="true">
        <svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="currentColor">
          <path d="M4 17l6-6-6-6" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          <path d="M12 19h8" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
      </div>
      <h1>Deck</h1>
      <p>Run and watch your Claude sessions.</p>
      <button type="button" className="btn-primary" onClick={onOpenProject}>
        Open a project
      </button>
      <p className="empty-hint">
        <kbd>⌘</kbd> <kbd>O</kbd> to open · <kbd>⌘</kbd> <kbd>T</kbd> for a new session
      </p>
    </div>
  )
}
