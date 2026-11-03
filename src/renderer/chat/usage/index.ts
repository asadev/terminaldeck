/*
 * `UsageStrip` used to be exported from here. It was the per-session token
 * readout folded inside the chat composer, and it is gone because the composer's
 * whole control row is gone: *"since we have it on top we actually don't need
 * them here — remove them from the chat box side completely, only keep the maybe
 * add files or something."* The reading it drew now lives in the chrome's
 * `UsageBar`, which shows the account's five-hour and weekly limits instead —
 * a different and more useful number, and one visible from a terminal session,
 * which the folded strip never was.
 *
 * What survives is everything below: the hooks and the model. Those were never
 * the strip's, they were only reached through it, and `ChatView` still imports
 * `useTranscriptChanges` from this barrel.
 */
export {
  useUsage,
  useTranscriptChanges,
  resolveUsageBridge,
  type UsageBridge,
  type UsageState,
} from './useUsage'
export * from './usage-model'
export type * from './types'
