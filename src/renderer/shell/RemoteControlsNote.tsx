import './RemoteControlsNote.css'

/**
 * The two things on the bar of a session running on one of your other machines
 * that are still set over there rather than here.
 *
 * ## What this file used to say, and why three quarters of it is gone
 *
 * Asad, on the recording of 2026-08-18, looking at a session on a paired PC:
 *
 *   > *"why it is all the options are not available with the connected ones
 *   > from other devices. We should have all the options up on the same
 *   > identical options for the remote sessions too, not just for our
 *   > sessions."*
 *
 * This component was the first answer to that, and it was an explanation rather
 * than a fix: it stood *in place of* the whole control cluster and read "Model,
 * effort, connectors and login are set on {machine}." The argument under it was
 * mechanically correct — this app has no API client for any agent, so
 * `src/main/agent-controls.ts` sets a model by typing `/model` into a session's
 * pty and reading the reply off that session's own screen, and at the time not
 * one frame in `src/main/remote/protocol.ts` named a model, an effort or a fast
 * mode.
 *
 * What it got wrong was the conclusion. A paired machine is, by definition, a
 * machine running this app — that is the line `MachinesPanel` draws between a
 * device and a server — so the far end already *has* that module and that pty.
 * The missing piece was never the mechanism, it was a courier, and
 * `CAPABILITY.controls` is it: `controls.read` and `controls.apply` carry the
 * question there and the answer back, and the far end changes the model exactly
 * as its own window would. So the model, the effort and fast mode now act on the
 * remote session and this note has stopped mentioning them.
 *
 * ## The two that are left, and why they are genuinely different
 *
 * **Connectors.** The chip's list comes from `listMcpServers`, which resolves a
 * folder's `.mcp.json` and this app's own registry **on this computer**. The
 * servers that matter to a session on another machine are that machine's, in
 * that machine's registry, and nothing on the wire carries them — a chip fed
 * from this list would name servers the session cannot reach and open a view
 * that manages the wrong computer's.
 *
 * **Login.** Which account an agent was spawned under is not a fact any frame on
 * this wire carries, and every row of the account chip's menu acts on a session
 * this app spawned — start one here, switch this one's login. It would be a menu
 * of choices that reach the wrong computer.
 *
 * Neither is a permanent shape. Both would need a frame that does not exist yet,
 * and saying which frame is the honest form of "not yet" — that is what this
 * sentence is for, rather than an apology.
 *
 * ## Why it says the machine's name rather than "unavailable"
 *
 * Because there is somewhere to go. The window on the far end has both of these
 * on its own bar, live. Naming it turns a refusal into a direction.
 *
 * The fuller reason is on the element's `title` rather than in the bar because a
 * toolbar is 48 pixels tall and this is one line of it; the visible sentence is
 * the part somebody has to have, and the rest is for whoever wonders.
 */
export function RemoteControlsNote({ machine }: { machine: string }) {
  return (
    <p
      className="remote-controls-note"
      /*
       * Every clause is a fact checked in the source rather than a guess about
       * the far end. The connectors half is `use-connectors.ts` calling
       * `listMcpServers`, which reads this machine's registry; the login half is
       * that no frame in `protocol.ts` names an account. The last sentence is
       * deliberately concrete — it is the list of things that *do* work now — so
       * the note reads as a boundary rather than as a gap.
       */
      title={
        `${machine} runs this app too, and this session's window over there has both of these live.\n\n` +
        `Connectors are resolved from a folder on the machine the session is running on — its own ` +
        `.mcp.json and its own registry — and nothing on the link between these two machines carries ` +
        `that list. Which account an agent was started under is not on the link either, and every row ` +
        `of the login menu acts on a session this app spawned.\n\n` +
        `The model, the effort and fast mode do act on this session: they are carried to ${machine}, ` +
        `applied there by the same code its own window uses, and the answer comes back in the CLI's ` +
        `own words. Typing, resizing, scrollback, find and clickable links all work here exactly as ` +
        `they do for a session on this computer.`
      }
    >
      Connectors and login are set on {machine}.
    </p>
  )
}
