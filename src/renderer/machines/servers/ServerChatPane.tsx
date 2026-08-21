import { useMemo } from 'react'
import { ChatView } from '../../components/ChatView'
import { serverChatBridge } from './server-chat'
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

  return (
    <div className="server-chat-pane" data-visible={visible} data-boxed={box !== undefined} style={box}>
      <ChatView
        /*
         * Asked again on a timer, and only while somebody is looking at it.
         *
         * A local conversation rides a push: the main process already has an
         * `fs.watch` on the transcript directory, so this pane costs nothing
         * while the agent is quiet. A server has no such thing to ride — nothing
         * over there knows this app exists — and the honest alternatives are a
         * timer or a stale pane.
         *
         * So it is a timer, and it is kept to the narrowest shape his standing
         * rule leaves room for. `0` switches it off entirely, which is what a
         * pane that is mounted but not on screen gets: a chat view on a
         * background tab keeps everything it has read and asks nothing. The
         * pane is not unmounted in that case, because unmounting drops the
         * reader in the main process and coming back would be the whole tail
         * window across the link again.
         *
         * A little slower than the local default, because each ask is a round
         * trip over SSH rather than a message to a process on this machine.
         */
        refreshMs={visible ? 3000 : 0}
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
          void bridge.writeToServerShell(shellId, `${text}\r`)
        }}
      />
    </div>
  )
}
