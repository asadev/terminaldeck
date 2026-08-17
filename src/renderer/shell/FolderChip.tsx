/**
 * The folder a session is running in. A title, and nothing else.
 *
 * ## Why this stopped being a control
 *
 * It was a dropdown, and the menu it opened did not do what a dropdown beside a
 * running session implies. Asad, walking the app on 2026-08-16:
 *
 * > *"If I am already inside a session, if I choose another folder, so what
 * > happens? Does it create a new one or does it change? … If it makes any
 * > sense and it can work in the same session, we can bring something by adding
 * > a folder and that can be useful for the same session, then it makes sense to
 * > have a dropdown here and add another folder inside the same session. If not,
 * > then just title is good enough for us to know which folder we are in right
 * > now. That's it. Dropdown will be only for the accounts."*
 *
 * It cannot work in the same session, and that is not a limitation of this app.
 * A pty has one working directory for its whole life: the process was spawned
 * with a `cwd` and there is no call that changes it from outside. Adding a
 * second folder to a running agent is not a thing this app is choosing not to
 * do — there is nowhere to put it. So the honest answer to his question is
 * "neither: it starts a different session", and once that is the answer, the
 * chevron is a control offering something the user did not ask for, sitting in
 * the one place they would look for something the app cannot do.
 *
 * Everything the menu used to reach is still reachable and is now in one place
 * rather than two: the `+` on a project row and the `+` on a tab both start a
 * session in a named folder, and the ＋ beside the sidebar's *Open* heading
 * reaches a folder that is not open yet.
 *
 * ## Its neighbour, which is still a control
 *
 * `AccountChip` sits beside this and keeps its menu, because the answer there
 * is the opposite: an account is a config directory handed to an agent at
 * spawn, so picking one is a real decision about the session you are about to
 * start, and there is one place in the window to make it.
 *
 * The path is set in mono because it is data — the characters are exact and
 * countable — while the label around it is ordinary UI text. That line runs
 * through the whole window.
 *
 * The file keeps the old name on purpose: `browser/overlay-watch.ts` names it in
 * prose, and a rename that leaves a stale filename in another agent's comment
 * costs more than it buys. The export says what the thing is.
 */

interface Props {
  /** The folder the session on screen is running in. */
  path: string
}

/** Last segment of a path — what a person calls the folder. */
export function folderLabel(path: string): string {
  const parts = path.split(/[/\\]/).filter(Boolean)
  return parts[parts.length - 1] ?? path
}

export function FolderTitle({ path }: Props) {
  return (
    <span
      className="folder-title"
      /*
       * The whole path, because the line only has room for the last segment and
       * two projects called `web` are not an unusual thing to have open — and
       * then the fact behind the missing dropdown, in the one place somebody
       * would go looking for it. It is a statement about how sessions work, not
       * an apology: the folder was fixed when the process was spawned.
       */
      title={`${path}\nA session keeps this folder for its whole life. Start another to work somewhere else.`}
    >
      {folderLabel(path)}
    </span>
  )
}
