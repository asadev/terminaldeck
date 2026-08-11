/**
 * Draggable strip behind the macOS traffic lights. Buttons must opt out of
 * the drag region or they become unclickable.
 */
export function TitleBar() {
  return (
    <header className="titlebar">
      <div className="titlebar-drag" />
    </header>
  )
}
