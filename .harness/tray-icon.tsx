/**
 * Hoot's menu bar icon, drawn from `HootMark` itself and photographed.
 *
 * `main/hoot-tray-icons.ts` embeds the PNGs this page produces (the tray has
 * nowhere to read an image from in a packaged build — see `resident.ts`), and
 * `.harness/tray-icons.mjs` is the script that photographs them. One drawing:
 * the menu bar owl is the same owl as the sidebar's, not a second one by hand.
 *
 * Each variant is an 18-point square with an id the script finds it by:
 * `open` (eyes open) and `closed` (lids down, the blink frame).
 */
import { createRoot } from 'react-dom/client'
import { HootMark } from '../src/renderer/copilot/HootMark'

const style = document.createElement('style')
style.textContent = `
  .variant { width: 18px; height: 18px; display: inline-block; margin: 4px; }
  #closed .hoot-lid { transform: scaleY(1) !important; }
`
document.head.append(style)

createRoot(document.getElementById('root')!).render(
  <>
    <span className="variant" id="open"><HootMark size={18} animated={false} /></span>
    <span className="variant" id="closed"><HootMark size={18} animated={false} /></span>
  </>,
)
