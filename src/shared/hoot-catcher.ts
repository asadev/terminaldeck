/** Bundled with the renderer so the production CSP permits this listener. */
export const CATCHER_REPEAT_MS = 100

interface CatcherEvent { button?: number; preventDefault?(): void }
interface CatcherEvents {
  addEventListener(type: string, listener: (event?: CatcherEvent) => void): void
  removeEventListener(type: string, listener: (event?: CatcherEvent) => void): void
}
interface CatcherPage extends CatcherEvents { documentElement: CatcherEvents }

export function bindCatcher(
  page: CatcherPage,
  say: (kind: 'enter' | 'leave' | 'press') => void,
  menu: () => void,
  now: () => number = Date.now,
): () => void {
  let inside = false
  let said = 0
  const move = (): void => {
    const time = now()
    if (!inside || time - said >= CATCHER_REPEAT_MS) {
      inside = true
      said = time
      say('enter')
    }
  }
  const leave = (): void => {
    if (inside) { inside = false; say('leave') }
  }
  const press = (event: CatcherEvent = {}): void => { if (event.button === 0) say('press') }
  const context = (event: CatcherEvent = {}): void => { event.preventDefault?.(); menu() }
  page.addEventListener('mousemove', move)
  page.documentElement.addEventListener('mouseleave', leave)
  page.addEventListener('mousedown', press)
  page.addEventListener('contextmenu', context)
  return () => {
    page.removeEventListener('mousemove', move)
    page.documentElement.removeEventListener('mouseleave', leave)
    page.removeEventListener('mousedown', press)
    page.removeEventListener('contextmenu', context)
  }
}
