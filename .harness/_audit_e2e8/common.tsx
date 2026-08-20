import { useEffect, useRef, useState } from 'react'
import { newTab } from '../../src/renderer/browser/tabs'

export const tab: any = { ...newTab('t1'), url: 'https://github.com/asadev/terminaldeck', title: 'x', canGoBack: true, canGoForward: false, loading: false, isolated: false, inspecting: false }
const noop = () => {}
export const common: any = {
  tab, security: 'secure', progress: 1, resolution: { kind: 'url', url: '' }, focusToken: 0,
  onDraft: noop, onEditing: noop, onSubmit: noop, onBack: noop, onForward: noop, onReload: noop,
  onStop: noop, onHome: noop, onInspect: noop, onRecord: noop, onScreenshot: noop, onDevtools: noop,
  devtoolsOpen: false, recording: false, onDraw: noop, drawing: false, deviceOpen: false,
  onToggleDevice: noop, onMenu: noop, menuOpen: false, steps: 0, onToggleIsolation: noop,
  onProfiles: noop, profilesOpen: false, profileName: 'Default',
}

export function Panel({ width, T, tag }: { width: number; T: any; tag: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const [n, setN] = useState('')
  useEffect(() => {
    const id = setTimeout(() => {
      const q = (s: string) => Math.round((ref.current?.querySelector(s) as HTMLElement | null)?.getBoundingClientRect().width ?? 0)
      setN(`address ${q('.bw-address')}  url-input ${q('.bw-url')}  actions ${q('.bw-actions')}  nav ${q('.bw-nav')}`)
    }, 300)
    return () => clearTimeout(id)
  }, [width])
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ font: '12px ui-monospace', color: '#8ad', padding: '2px 6px' }}>
        {tag} panel {width} — <b>{n}</b>
      </div>
      <div ref={ref} className="bw" style={{ width, background: 'var(--bg-primary)', border: '1px solid #444' }}>
        <T {...common} />
      </div>
    </div>
  )
}
