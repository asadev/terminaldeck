/**
 * Where the handlers go when there is no renderer to send them to.
 *
 * `registerRemoteIpc`, `registerMachinesIpc` and `registerWslIpc` all take the
 * thing they register on as a parameter — an {@link InvokeRegistrar}, one method
 * wide. In the desktop that parameter is Electron's `ipcMain` and each handler
 * ends up answering a renderer across a process boundary. Here it is this: a Map
 * from channel name to the same function, called in-process.
 *
 * That is the whole trick, and it is why the headless build is not a second
 * implementation of anything. `terminaldeck pair` runs the body of
 * `remote:pair`. `terminaldeck folders` runs the body of `remote:folders`. When
 * somebody fixes pairing, both shells get the fix, because there is one copy of
 * it and neither shell owns it.
 *
 * ## Why it refuses a duplicate channel
 *
 * Electron's `ipcMain.handle` throws when a channel already has a handler, and
 * that throw has caught real mistakes here — `registerHookServer` documents
 * calling `removeHandler` first precisely because it promises to be safe to call
 * twice. A desk that silently replaced the earlier handler would let a
 * double registration look fine and answer with whichever copy registered last,
 * which is a coin flip that only shows up in production.
 */

import type { InvokeRegistrar } from '../main/ipc-seam'

export class ChannelDesk implements InvokeRegistrar {
  private readonly handlers = new Map<
    string,
    (event: unknown, ...args: unknown[]) => unknown
  >()

  handle(channel: string, listener: (event: unknown, ...args: unknown[]) => unknown): void {
    if (this.handlers.has(channel)) {
      throw new Error(
        `Two handlers were registered for "${channel}". Electron's ipcMain throws on this and ` +
          'so does this desk: the alternative is a channel that answers with whichever ' +
          'registration ran last.',
      )
    }
    this.handlers.set(channel, listener)
  }

  /**
   * Call a handler the way the renderer would.
   *
   * The `null` event is not a stand-in for something real: every handler in this
   * codebase names its first parameter `_event` and never reads it, because a
   * main-process handler that trusts its sender is a handler that can be called
   * by any code running in that window. Passing `null` is therefore the honest
   * value, not a gap — and it is why this method takes no event of its own.
   *
   * Always a promise, because some handlers are async and a caller that had to
   * know which is a caller that will one day be wrong.
   */
  async invoke(channel: string, ...args: unknown[]): Promise<unknown> {
    const handler = this.handlers.get(channel)
    if (!handler) {
      throw new Error(
        `No handler for "${channel}". The headless host registers the same channels the ` +
          'preload calls; a missing one means a registration was skipped, not that the ' +
          'command is unsupported.',
      )
    }
    return await handler(null, ...args)
  }

  /** Every channel registered, sorted. For diagnostics and for the seam test. */
  channels(): string[] {
    return [...this.handlers.keys()].sort()
  }

  has(channel: string): boolean {
    return this.handlers.has(channel)
  }
}
