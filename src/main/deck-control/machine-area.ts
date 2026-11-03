import type { ServersIpc } from '../servers/ipc'
import type { ToolSpec } from './catalogue'
import { channelCall, createChannelTap, type ChannelTap } from './channel-tap'
import { gitHubTools, type GitHubChannels } from './github-tools'
import { machineTools, stateWaiter, type MachineChannels } from './machine-tools'
import { watchMachines, type MachineWatch } from './machine-watch'
import { remoteTools, type RemoteChannels } from './remote-tools'
import { serverRoomTools, type ServerChannels } from './server-room-tools'

/**
 * The machines, servers, devices and GitHub tools, assembled — so `index.ts`
 * needs one import and three short lines.
 *
 * ## Why one object that lives for the whole process
 *
 * Because two of its three jobs start before there are any tools. The tap has
 * to be on `ipcMain` before the registrations it should see run, and on `send`
 * before the first push leaves; the watch has to be listening before a window
 * attaches to its first remote session, or the replay that answers the attach —
 * the whole screen — lands before anything is there to keep it. The tools are
 * built later, at the `extraTools` site, from the same two.
 *
 * `createMachineArea` is the factory a test uses; {@link machineArea} is the one
 * the app uses.
 */

export interface MachineArea {
  tap: ChannelTap
  watch: MachineWatch
  /**
   * Every tool in the area, built over the tap.
   *
   * `servers` is `index.ts`'s `servers`, which is null on a wiring order that
   * did not build the server room; the server-room tools are then absent rather
   * than present and failing, the same judgement the `serverTools` line beside
   * it makes.
   */
  tools(options: { servers: Pick<ServersIpc, 'openShells' | 'shellScreen'> | null; userData(): string }): ToolSpec[]
}

export function createMachineArea(tap: ChannelTap = createChannelTap()): MachineArea {
  const watch = watchMachines(tap)
  return {
    tap,
    watch,
    tools: ({ servers, userData }) => [
      ...machineTools({ call: channelCall<MachineChannels>(tap), nextState: stateWaiter(tap), watch, userData }),
      ...(servers === null
        ? []
        : serverRoomTools({
            call: channelCall<ServerChannels>(tap),
            openShells: () => servers.openShells(),
            shellScreen: (shellId) => servers.shellScreen(shellId),
            userData,
          })),
      ...remoteTools({ call: channelCall<RemoteChannels>(tap) }),
      ...gitHubTools({ call: channelCall<GitHubChannels>(tap) }),
    ],
  }
}

/** The app's one. See the header for why it is module-level. */
export const machineArea: MachineArea = createMachineArea()
