import { useEffect, useMemo } from 'react'
import { ChatView } from '../../components/ChatView'
import { sendToTerminal } from '../../chat/attach/mentions'
import { serverChatBridge, useServerChatPush } from './server-chat'
import type { ServersBridge } from './types'

/**
 * A terminal on a server, drawn as its conversation.
 *
 * ## Why it is a pane of its own and not a branch of `mainView`
 *
 * For the reason `ServerSessionPane` beside it is: `mainView` draws **one**
 * thing, so a trip to Files, a split, or a look at a paired machine unmounts
 * whatever it was drawing. That is fatal for the terminal — nothing at the far
 * end keeps a server shell's output — and merely wasteful here, but wasteful
 * over SSH: a remount is the whole conversation read across the wire again. So
 * this is mounted beside the panes and hidden, exactly as everything else in
 * that list is.
 *
 * The terminal and this are the same session in two views, and only one of them
 * is on screen at a time — `sessionView[tabId]` decides which, the same map and
 * the same segmented control every local session uses. The terminal is *hidden*
 * rather than unmounted while this is up, because its scrollback exists nowhere
 * else.
 *
 * ## Why the bridge is memoised here rather than built in `App.tsx`
 *
 * `ChatView` treats its `bridge` as an identity: the effect that loads a
 * conversation depends on it, so a new object every render is the whole
 * transcript re-read on every render. Built inside a `.map` in `App.tsx` there
 * is nowhere to hold one — hooks cannot be called in a loop — which is the
 * mechanical reason this is a component and not four lines inline.
 */
export function ServerChatPane({
  shellId,
  bridge,
  box,
  visible,
}: {
  /**
   * The **far end's** id for the shell, which is what the main process holds
   * the SSH channel and the transcript reader under.
   *
   * Not `shellKey`, which is this window's own handle and names nothing over
   * there. A pane is not drawn at all until the server has answered with one.
   */
  shellId: string
  bridge: ServersBridge
  /**
   * Where in the pane area to draw, when one pane of a split is holding this
   * session. Absent means the whole area — the stylesheet's own `inset: 0`.
   */
  box?: Record<string, string> | undefined
  visible: boolean
}) {
  const chat = useMemo(() => serverChatBridge(bridge, shellId), [bridge, shellId])
  /*
   * Which way this pane is being kept current, and the subscription that makes
   * one of the two answers true. See `server-chat.ts`.
   */
  const { feed, subscribe } = useServerChatPush(bridge, shellId)

  /*
   * Tell the far end when nobody is looking, and when somebody is again.
   *
   * This pane is mounted while it is off screen — unmounting drops the reader in
   * the main process and coming back would be the whole tail window across the
   * link again — and its promise has always been that a hidden one *asks
   * nothing*. That promise now needs saying out loud, because the far end can
   * talk first: a `tail -f` sends a transcript's appends whether or not this
   * side reads them, and a long tool result on a background tab is real traffic
   * on somebody's server for something nobody can see.
   *
   * Coming back is one read, not a re-read: the main process reopens the follow
   * and pushes immediately, which walks the file to the end in a single round
   * trip.
   */
  useEffect(() => {
    void bridge.watchServerChat?.(shellId, visible)
  }, [bridge, shellId, visible])

  return (
    <div
      className="server-chat-pane"
      data-visible={visible}
      data-boxed={box !== undefined}
      /*
       * On the element, so `app.where` and a test can read it off the screen
       * rather than out of a state variable — the same reason `ChatView` writes
       * its session id into an attribute.
       */
      data-feed={feed ?? 'unknown'}
      style={box}
    >
      <ChatView
        /*
         * The fallback, and only the fallback.
         *
         * A local conversation rides a push: the main process has an `fs.watch`
         * on the transcript directory, so the pane costs nothing while the agent
         * is quiet. A server has one now too — a `tail -f` running over there,
         * forwarded on `servers:chat:changed` — so `feed === 'live'` switches
         * this off entirely and the conversation arrives as it is written
         * instead of up to three seconds later. His rule: *"events, not polling
         * — they make the system heavier."*
         *
         * It stays for the two cases where that is not available and the only
         * honest alternative is a stale pane: no transcript has been attributed
         * to this terminal yet, so there is no file to follow, and a server
         * whose `tail` will not follow one. The pane says which of the two it is
         * on rather than looking identical in both.
         *
         * `0` also switches it off for a pane that is mounted but not on screen:
         * a chat view on a background tab keeps everything it has read and asks
         * nothing. It is not unmounted, because unmounting drops the reader in
         * the main process and coming back would be the whole tail window across
         * the link again.
         */
        refreshMs={visible && feed !== 'live' ? 3000 : 0}
        /*
         * And the push that makes the timer above unnecessary whenever the
         * server can manage it. `null` from this — a preload with no such
         * channel — leaves the timer running, which is the build this app had
         * yesterday rather than a broken one.
         */
        subscribe={subscribe}
        /*
         * A handle, not a path. Which file on that server is this terminal's
         * conversation is decided in the main process out of the moment the
         * shell was opened — see `servers/chat.ts` — so this side names a
         * session and is told what was resolved.
         */
        conversationKey={shellId}
        bridge={chat}
        /*
         * No folder. A shell lands wherever that sign-in lands and this app has
         * not asked where; a path here would be resolved against *this*
         * computer, which is how the composer's attach menu ends up offering an
         * agent on somebody's server a file that only exists on this Mac.
         */
        cwd={null}
        /*
         * And therefore no attach menu, with the reason where the plus would
         * have been. A file picked here is a file on *this* Mac, and the agent
         * is on somebody's server — `session-transfer.ts` states the rule and
         * the report behind it. There is no form of the result that fixes that,
         * so the control is withdrawn rather than left to insert a path that
         * names nothing over there.
         */
        noAttachReason="Files on this computer can’t be attached to a session on a server."
        /*
         * Typed into the shell's own pty, which is the same thing the terminal
         * view does with the same keystrokes: chat mode is a different view of
         * one session, not a second channel into it, so a message sent here is
         * in the scrollback when you switch back.
         */
        onSend={(text) => {
          // Two writes with a gap, never one with a `\r` on the end: over 64
          // bytes the CLI reads the chunk as a paste and the carriage return
          // becomes a newline, so the message lands in the agent's input box
          // unsent. `mentions.ts` holds the measurement and the sequence, and
          // the desktop composer had exactly the same defect.
          void sendToTerminal(text, (data) => bridge.writeToServerShell(shellId, data))
        }}
      />
      {/*
        * Which feed this pane is on, said rather than left to be guessed.
        *
        * "As it is written" and "up to three seconds stale" look identical on
        * screen right until somebody is waiting on a reply and wondering whether
        * the machine has stopped. One muted line, present only once there is an
        * answer — a caption that appeared and then corrected itself half a
        * second later would be a flicker nobody can read.
        */}
      {feed === null ? null : (
        <p className="server-chat-feed" data-feed={feed}>
          {feed === 'live'
            ? 'Live — this server sends each reply as it is written.'
            : 'Re-reading every 3 seconds — nothing on this server is streaming this conversation yet.'}
        </p>
      )}
    </div>
  )
}
