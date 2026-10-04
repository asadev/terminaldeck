/**
 * Who is making a change to one of your tasks, for the length of one call.
 *
 * The window changes your tasks as you (`me`). Hoot and connected AI apps change
 * them through the MCP tools (`local-task-tools.ts`), and a change they make is
 * written down as theirs — the task's notes, its Activity, a comment's author, a
 * time entry — not as yours. The tool runs the call inside {@link asActor}, and
 * everything underneath (`LocalTasks`, `LocalTaskDetail`) reads {@link actorNow}
 * rather than taking an extra argument through every function: one async
 * context, so two calls in flight at once can never borrow each other's name.
 */
import { AsyncLocalStorage } from 'node:async_hooks'
import { ME } from './task-store'

const current = new AsyncLocalStorage<string>()

/** `me` (the window), `hoot`, or `app:<key name>` for an AI app on an access key. */
export function actorNow(): string {
  return current.getStore() ?? ME
}

/** Run one call as this actor. */
export function asActor<T>(actor: string, run: () => T): T {
  return current.run(actor, run)
}

/** The actor id for an AI app on an access key, by the name its key was given. */
export function appActor(keyName: string): string {
  return `app:${keyName}`
}

/** How an actor id reads to a person; null for the ids people already have (`me`, `hoot`, an agent). */
export function appActorName(id: string): string | null {
  return id.startsWith('app:') ? `${id.slice(4)} (AI app)` : null
}
