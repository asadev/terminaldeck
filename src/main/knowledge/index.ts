/**
 * Durable project knowledge, as one object the app holds.
 *
 * `createKnowledge` is the whole of what leaves this folder: the
 * `KnowledgeProvider` the task engine pulls briefs from and reports events to,
 * and the read, claim, supersede and share calls the tools and the memory view
 * use. What it deliberately does not hand out is a way to write `verified` —
 * that stays inside, on the review path (`ingest.ts`), so no caller holding
 * this object can mint one.
 *
 * Nothing happens when it is made: no folder, no file, no share. The store is
 * touched on the first call that needs it.
 */

import type {
  KnowledgeForBrief,
  KnowledgeProvenance,
  KnowledgeProvider,
  KnowledgeView,
  TaskKnowledgeEvent,
} from '../../shared/agent-stack'
import { KnowledgeBook, type ClaimInput, type KnowledgeConsent, type ListOptions, type SupersedeInput } from './book'
import { composeBrief } from './brief'
import { noteTaskEvent } from './ingest'
import type { KnowledgeLogEntry } from './store'

export type { ClaimInput, KnowledgeConsent, ListOptions, ShareRequest, SupersedeInput } from './book'
export { KnowledgeError } from './store'

export interface Knowledge extends KnowledgeProvider {
  /** Records a project may read, newest first; superseded and shared ones only when asked. */
  list(project: string, options?: ListOptions): KnowledgeView[]
  /** One record the project may read — its own or one shared with it. */
  get(project: string, id: string): KnowledgeView | null
  /** What a record replaced, newest first. */
  history(project: string, id: string): KnowledgeView[]
  /** The record that replaced this one, when one did. */
  supersededBy(project: string, id: string): string | null
  /** Write a claim. Only ever a claim. */
  record(project: string, input: ClaimInput): KnowledgeView
  /** Replace a record with a claim, or withdraw it; the old one is kept as superseded and the reason logged. */
  supersede(project: string, id: string, input: SupersedeInput): { superseded: KnowledgeView; replacement: KnowledgeView | null }
  /** Delete a record on purpose, with a reason; the whole record is copied into the log first. */
  remove(project: string, id: string, input: { reason: string; by: KnowledgeProvenance }): void
  /** Let `to` read `from`'s records, if the consent function says yes. */
  share(from: string, to: string, by?: KnowledgeProvenance): Promise<boolean>
  unshare(from: string, to: string, by?: KnowledgeProvenance): boolean
  sharedInto(project: string): string[]
  sharedOut(project: string): string[]
  /** The project's change log: supersedes, deletes, shares. */
  changes(project: string): KnowledgeLogEntry[]
  /** The real path a project's records are kept under — what every view's `project` says. */
  projectOf(project: string): string
  /** The folder a project's records are in — what the memory view opens as its space. */
  dirOf(project: string): string
}

export interface CreateKnowledgeOptions {
  /** The app's userData folder; records live under `<userData>/knowledge/`. */
  userData: string
  now?: () => number
  /** Asked before any share. Absent: every share is refused. */
  consent?: KnowledgeConsent
  /** Modified time of an evidence file. The real disk by default. */
  statMtime?: (path: string) => number | null
  newId?: () => string
  /**
   * Told when an event could not be kept or a brief could not be read. The task
   * flow goes on either way: a task must not stop because its notes could not
   * be written, and a brief without knowledge is still a brief.
   */
  onError?: (error: unknown, what: string) => void
}

const EMPTY: KnowledgeForBrief = { text: '', records: [] }

export function createKnowledge(options: CreateKnowledgeOptions): Knowledge {
  const book = new KnowledgeBook(options)
  const onError = options.onError ?? ((error: unknown, what: string) => console.warn(`[knowledge] ${what}:`, error))
  return {
    async forBrief(input): Promise<KnowledgeForBrief> {
      try {
        const real = book.projectOf(input.project)
        return composeBrief(book.list(real, { shared: true }), { ...input, project: real })
      } catch (error) {
        onError(error, `brief for ${input.project}`)
        return EMPTY
      }
    },
    async noteTaskEvent(event: TaskKnowledgeEvent): Promise<void> {
      try {
        noteTaskEvent(book, event)
      } catch (error) {
        onError(error, `${event.kind} event for task ${event.taskId}`)
      }
    },
    list: (project, listOptions) => book.list(project, listOptions),
    get: (project, id) => book.get(project, id),
    history: (project, id) => book.history(project, id),
    supersededBy: (project, id) => book.supersededBy(project, id),
    record: (project, input) => book.record(project, input),
    supersede: (project, id, input) => book.supersede(project, id, input),
    remove: (project, id, input) => book.remove(project, id, input),
    share: (from, to, by) => book.share(from, to, by),
    unshare: (from, to, by) => book.unshare(from, to, by),
    sharedInto: (project) => book.sharedInto(project),
    sharedOut: (project) => book.sharedOut(project),
    changes: (project) => book.changes(project),
    projectOf: (project) => book.projectOf(project),
    dirOf: (project) => book.store.dirOf(book.projectOf(project)),
  }
}
