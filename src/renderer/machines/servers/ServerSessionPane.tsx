import { useAppSettings } from '../../settings/useAppSettings'
import { booleanSetting, numberSetting, stringSetting } from '../../settings/settings-schema'
import { ServerTerminal } from './ServerTerminal'
import type { ServersBridge } from './types'

/**
 * One shell on one server, as a pane the window keeps.
 *
 * ## Why it is mounted for as long as the tab exists
 *
 * This is the difference between a session and a rectangle, and it is worth the
 * paragraph because the obvious arrangement — mount it when it is on screen,
 * unmount it when it is not — is the one that cannot work here.
 *
 * A local session survives being unmounted because the main process holds its
 * output and hands it back on the way in; `TerminalView` asks for it with
 * `getScrollback` on every mount. A session on a paired desktop survives because
 * the far end holds it and replays it when this window attaches. A shell on a
 * server has neither: nothing on the far end is keeping it — there is no app
 * there to keep it — and nothing on this side is recording what it printed. So
 * an unmount would either lose every line the shell had produced, or, if the
 * shell were left open to avoid that, strand a live one on somebody's machine
 * with no way back to it.
 *
 * The window therefore mounts one of these per open tab and hides the ones that
 * are not in front, which is exactly what it already does with local terminals
 * and browser pages: *"Every browser and terminal stays mounted and is shown or
 * hidden, so a page keeps its scroll position and a terminal keeps its
 * scrollback when you switch away and come back."* Being hidden costs a DOM node
 * and a subscription; the shell was going to be running either way.
 *
 * The consequence, which is the behaviour that was asked for: taking the tab off
 * the list unmounts this, and unmounting closes the shell over there. That is
 * what the ✕ means — the same thing it means on a session belonging to a paired
 * desktop, one shell's worth — and the server itself is untouched by it.
 *
 * ## Why it is a positioned block of its own
 *
 * `.panes` is a positioned block rather than a flex container, so a pane handed
 * to it has to make itself the size of it. `.remote-pane` next door solves the
 * identical problem for a session on a paired desktop and says so; this is the
 * same shape with the visibility attribute the local terminals use, because
 * unlike that one this pane is drawn whether or not it is the one in front.
 */
export function ServerSessionPane({
  serverId,
  shellKey,
  startIn,
  run,
  bridge,
  box,
  visible,
  onEnded,
  onOpened,
  serverName,
  onReopen,
}: {
  serverId: string
  /**
   * This window's handle for the shell.
   *
   * Not read by anything below — the terminal opens its own shell and learns the
   * far end's id for itself. It is here because it is what makes this pane's
   * React key unique, and because a second terminal on the same server is a
   * genuinely different pane rather than the same one re-rendered. Naming it in
   * the props is what stops somebody keying these on `serverId` and getting one
   * terminal that flickers between two shells.
   */
  shellKey: string
  /**
   * The folder the shell opens in, or null for wherever the sign-in lands.
   *
   * Passed through rather than read here: the terminal is what opens the shell,
   * and this is the one fact about the shell that has to be in hand at that
   * moment. See `ServerFolderPicker` for where the answer comes from.
   */
  startIn: string | null
  /**
   * A command to type once the shell opens, or null for a plain prompt.
   *
   * Passed through for the reason `startIn` is: the terminal is what opens the
   * shell, and this is the second of the two facts that have to be in hand at
   * that moment. See `ServerSession.run` for who mints it — the account chip's
   * "New terminal running …" rows.
   */
  run: string | null
  bridge: ServersBridge
  /**
   * Where in the pane area to draw, when one pane of a split is holding this
   * shell rather than the whole window.
   *
   * Absent means the whole pane area, which is the stylesheet's own `inset: 0`
   * and the unsplit window. This pane cannot be *moved* into the pane tree —
   * unmounting it closes the SSH shell — so a split draws an empty box where it
   * belongs and this is the rectangle of it. See `layout/pane-slots.ts`.
   */
  box?: Record<string, string> | undefined
  visible: boolean
  onEnded(): void
  /**
   * The far end's id for this shell, once it exists.
   *
   * Passed straight through. The window keeps it because the control cluster on
   * the bar addresses a server terminal by that id — see `ServerTerminal`'s own
   * note for why this pane cannot mint it.
   */
  onOpened(shellId: string): void
  /**
   * What this server is called, for the card drawn when the shell ends.
   *
   * The row already carries it and keeps it in step through `renameServersIn`,
   * so it is passed rather than looked up — a pane cannot reach the servers
   * list, which lives inside a panel that is usually not the thing on screen.
   */
  serverName: string
  /**
   * Open another terminal on this server, from that card.
   *
   * The window's, because only the window can put a tab on the list. This is
   * the press that answers the one question a closed SSH channel leaves open —
   * whether the shell ended or the server did — by trying it.
   */
  onReopen(): void
}) {
  /*
   * Read here rather than threaded down from the window.
   *
   * The hook is one read at launch plus whatever the settings window pushes, so
   * asking for it costs nothing — and the alternative is the bug this repository
   * has already shipped twice: a font size in Settings that reaches a preview
   * and no terminal.
   */
  const { values: settings } = useAppSettings()
  const fontSize = numberSetting(settings, 'appearance.terminalFontSize')
  const fontFamily = stringSetting(settings, 'appearance.terminalFontFamily')
  /*
   * The third of the terminal settings, and it was the one that never arrived.
   * The two above were threaded through when this pane was written; selecting
   * text in a server shell simply did not copy it, on a machine where every
   * other terminal in the window did. See `ServerTerminal.copyOnSelect`.
   */
  const copyOnSelect = booleanSetting(settings, 'general.copyOnSelect')

  return (
    <div
      className="server-pane"
      data-visible={visible}
      data-boxed={box !== undefined}
      style={box}
      data-shell={shellKey}
    >
      <ServerTerminal
        serverId={serverId}
        startIn={startIn}
        runCommand={run}
        bridge={bridge}
        fontSize={fontSize}
        fontFamily={fontFamily}
        copyOnSelect={copyOnSelect}
        visible={visible}
        onEnded={onEnded}
        onOpened={onOpened}
        serverName={serverName}
        onReopen={onReopen}
      />
    </div>
  )
}
