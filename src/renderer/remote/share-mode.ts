import type { Segment } from '../components/SegmentedSwitch'

/**
 * All, or a list somebody ticked — the question three panels on this screen ask.
 *
 * `DeviceApproval` asks it about logins while a device is being let in,
 * `DeviceLogins` asks it about logins afterwards, and `DeviceSessions` asks it
 * about running sessions. Three panels, one shape: a narrowing whose *off*
 * position is "everything" and whose *on* position reveals a list of ticks.
 *
 * The two words were typed three times, in three ternaries reading
 * `mode === 'all' ? 'All' : 'Selected'`, beside three copies of the segmented
 * control itself. `SegmentedSwitch` took the control; this takes the words, so a
 * fourth panel asking the same question cannot come to call it *Some* or *Chosen*
 * and leave the screen holding two names for one idea.
 *
 * Order is load-bearing: All is the default every one of these three grants
 * starts on, and a segmented control reads left to right.
 */
export type ShareMode = 'all' | 'selected'

export const SHARE_MODES: readonly Segment<ShareMode>[] = [
  { id: 'all', label: 'All' },
  { id: 'selected', label: 'Selected' },
]
