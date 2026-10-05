/**
 * A channel between two pages of the native macOS window — same origin, so a
 * `BroadcastChannel` reaches from one to the other with nothing from the engine
 * or the native side in between.
 *
 * Used where a page that is not the main window has to hand something to it:
 * Settings (`settings/native-settings.ts`) and the island (`island/native-island.ts`).
 * A message a page posts is not delivered back to that page, so each end only
 * ever hears the other, and anything that is not one of the channel's own
 * messages is dropped at the door.
 */

export interface ChannelLike {
  postMessage(message: unknown): void
  addEventListener(type: 'message', listener: (event: { data: unknown }) => void): void
  removeEventListener(type: 'message', listener: (event: { data: unknown }) => void): void
  close(): void
}

export interface Relay<M> {
  post(message: M): void
  listen(handler: (message: M) => void): () => void
  close(): void
}

export function openRelay<M>(
  name: string,
  accept: (value: unknown) => value is M,
  open: (name: string) => ChannelLike = (channel) => new BroadcastChannel(channel),
): Relay<M> {
  const channel = open(name)
  return {
    post: (message) => channel.postMessage(message),
    listen(handler) {
      const listener = (event: { data: unknown }): void => {
        if (accept(event.data)) handler(event.data)
      }
      channel.addEventListener('message', listener)
      return () => channel.removeEventListener('message', listener)
    },
    close: () => channel.close(),
  }
}
