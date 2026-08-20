/**
 * The per-device session choice, on its own, in a real browser.
 *
 * The panel `DeviceSessions.tsx` draws: All / Selected per device, and a tick
 * per running session under Selected. Rendered here rather than through the
 * whole app because it lives inside a settings modal three presses deep, and
 * the thing to look at is whether it says anything it should not — the rule for
 * this round is that a screen explains nothing in prose.
 *
 * The bridge is local and mutable, so pressing the buttons really does write and
 * read back, exactly as the component does against the main process.
 *
 * `?theme=light` for the other appearance.
 */
import { StrictMode, useMemo } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'
import { DeviceSessions } from '../src/renderer/remote/DeviceSessions'
import { DeviceFolders } from '../src/renderer/remote/DeviceFolders'

const theme = new URLSearchParams(location.search).get('theme') === 'light' ? 'light' : 'dark'
document.documentElement.dataset.theme = theme

const running = [
  { id: 's1', title: 'terminaldeck', cwd: '/Users/apple/Projects/terminaldeck', exitCode: null },
  { id: 's2', title: 'Update Claude Code terminal to new API', cwd: '/Users/apple/Projects/terminaldeck/pwa', exitCode: null },
  { id: 's3', title: 'imza-crm', cwd: '/Users/apple/Projects/imza-crm', exitCode: null },
  // Exited, so the panel must not offer a tick for it.
  { id: 's4', title: 'old build', cwd: '/Users/apple/Projects/terminaldeck', exitCode: 0 },
]

function Harness() {
  const bridge = useMemo(() => {
    const grants: Array<{ deviceId: string; mode: 'all' | 'selected'; sessions: string[] }> = [
      { deviceId: 'dev-2', mode: 'selected', sessions: ['s2'] },
    ]
    return {
      listSessionGrants: async () => grants,
      listRunningSessions: async () => running,
      setSessionGrants: async (deviceId: string, mode: string, sessions: string[]) => {
        const at = grants.findIndex((row) => row.deviceId === deviceId)
        const row = {
          deviceId,
          mode: mode === 'all' ? ('all' as const) : ('selected' as const),
          sessions: mode === 'all' ? [] : [...sessions],
        }
        if (at >= 0) grants[at] = row
        else grants.push(row)
        return grants
      },
    }
  }, [])

  /*
   * The folder panel above it, because the seam between the two is half of what
   * this page is for: they are read one after the other and a different card
   * shape or a different gap between them would suggest a difference that is not
   * there. Its bridge is the smallest one that renders — the folder half has its
   * own harness coverage elsewhere.
   */
  const folderBridge = useMemo(
    () => ({
      listDeviceFolders: async () => [
        { deviceId: 'dev-2', folders: ['/Users/apple/Projects/terminaldeck'] },
      ],
      setDeviceFolders: async () => [
        { deviceId: 'dev-2', folders: ['/Users/apple/Projects/terminaldeck'] },
      ],
      pickProjectFolder: async () => null,
    }),
    [],
  )

  return (
    // The real window's wrapper at the real width: half the defects a panel like
    // this has are wrapping ones that only appear at 690px.
    <div className="settings">
      <div className="settings-panel" style={{ width: '690px', padding: '24px' }}>
        <DeviceFolders devices={[{ id: 'dev-2', name: 'Office PC' }]} bridge={folderBridge} />
        <DeviceSessions
          devices={[
            { id: 'dev-1', name: "Asad's iPhone" },
            { id: 'dev-2', name: 'Office PC' },
          ]}
          bridge={bridge}
        />
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Harness />
  </StrictMode>,
)
