/**
 * The help's words, lent to the native window (lane S).
 *
 * The native Help sheet and the native Settings → Help draw `HelpPanel` in Swift,
 * but its words — every section and topic — stay here, in `HelpPanel.tsx`, the one
 * place they are written. In the native window this page leaves them on
 * `window.tdHelp` for the native side to read, so the two can never say different
 * things. Inside Electron nothing is set.
 */

import { isNativeShell, type NativeHost } from '../shared/native-shell'
import { HELP_TOPICS, SECTIONS } from './components/HelpPanel'

export interface NativeHelpContent {
  sections: typeof SECTIONS
  topics: typeof HELP_TOPICS
}

interface HelpHost extends NativeHost {
  tdHelp?: NativeHelpContent
}

export function publishHelpContent(host: HelpHost = globalThis as HelpHost): () => void {
  if (!isNativeShell(host)) return () => {}
  host.tdHelp = { sections: SECTIONS, topics: HELP_TOPICS }
  return () => {
    delete host.tdHelp
  }
}
