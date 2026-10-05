/**
 * Goals, on the Tasks page: what your tasks are for, each with how far its
 * tasks have got.
 *
 * A goal can sit under a bigger one, and the list is drawn as that tree. Each
 * row says how many of its tasks — its sub-goals' included — are done, how many
 * of those were checked rather than only claimed, and what has stalled or is
 * waiting on something else, in the status colours the task rows use. A task is
 * linked to a goal from its own row (the Goal cell) or when it is made.
 *
 * Every change goes to the main process (`tasks:goal-save`, `tasks:goal-remove`)
 * and the page redraws from the state it answers with.
 */

import { useState, type CSSProperties, type ReactElement } from 'react'
import {
  GOAL_STATUSES,
  goalDraftOf,
  goalPayload,
  goalTree,
  parentChoices,
  toTasksResult,
  type GoalDraft,
  type GoalRow,
  type TasksBridge,
  type TasksResult,
} from './tasks-model'
import './Goals.css'

/** What the goals list asks of the main process. */
export interface GoalActions {
  save(input: Record<string, unknown>): Promise<TasksResult>
  remove(id: string): Promise<TasksResult>
}

const NOT_HERE: TasksResult = { ok: false, message: 'This build cannot change goals.', state: null, secret: null }

export function goalActions(bridge: Partial<TasksBridge>): GoalActions | undefined {
  const save = bridge.tasksGoalSave
  const remove = bridge.tasksGoalRemove
  if (save === undefined || remove === undefined) return undefined
  const call = async (run: () => Promise<unknown>): Promise<TasksResult> => {
    try {
      return toTasksResult(await run())
    } catch (error) {
      return { ...NOT_HERE, message: error instanceof Error ? error.message : String(error) }
    }
  }
  return { save: (input) => call(() => save(input)), remove: (id) => call(() => remove(id)) }
}

/** "3 of 5 done", then only the counts worth a look. */
export function progressLine(progress: GoalRow['progress']): string {
  if (progress.total === 0) return 'No tasks yet'
  const parts = [`${progress.done} of ${progress.total} done`]
  if (progress.verified > 0) parts.push(`${progress.verified} verified`)
  if (progress.unverified > 0) parts.push(`${progress.unverified} to check`)
  if (progress.stalled > 0) parts.push(`${progress.stalled} stalled`)
  if (progress.blocked > 0) parts.push(`${progress.blocked} waiting`)
  return parts.join(' · ')
}

/** The goals as a picker offers them: tree order, indented. */
export function goalOptions(goals: readonly GoalRow[]): Array<{ id: string; label: string }> {
  return goalTree(goals).map(({ goal, depth }) => ({ id: goal.id, label: `${'\u00a0\u00a0'.repeat(depth)}${depth > 0 ? '↳ ' : ''}${goal.title}` }))
}

export function GoalsSection({
  goals,
  busy,
  actions,
  run,
  creating,
  onCreating,
}: {
  goals: readonly GoalRow[]
  busy: boolean
  actions?: GoalActions
  run(work: () => Promise<TasksResult>): Promise<boolean>
  /** The new-goal form is open (the page's New goal button opens it). */
  creating: boolean
  onCreating(open: boolean): void
}): ReactElement | null {
  // Which goal's form is open: its id, `under:<id>` for a new goal beneath one.
  const [editing, setEditing] = useState<string | null>(null)
  const [removing, setRemoving] = useState<string | null>(null)
  if (goals.length === 0 && !creating) return null
  const save = async (draft: GoalDraft, id: string | null): Promise<boolean> => {
    const checked = goalPayload(draft, id)
    if (!checked.ok) return run(async () => ({ ok: false, message: checked.message, state: null, secret: null }))
    return actions ? run(() => actions.save(checked.payload)) : false
  }
  return (
    <section className="tasks-page-section" aria-label="Goals">
      <h2 className="tasks-page-heading">Goals</h2>
      {creating && actions && (
        <GoalForm
          goal={null}
          goals={goals}
          parentId=""
          busy={busy}
          onSave={async (draft) => {
            if (await save(draft, null)) onCreating(false)
          }}
          onCancel={() => onCreating(false)}
        />
      )}
      {goals.length > 0 && (
        <ul className="goals-list">
          {goalTree(goals).map(({ goal, depth }) => {
            const { progress } = goal
            const share = progress.total === 0 ? 0 : Math.round((progress.done / progress.total) * 100)
            return (
              <li key={goal.id} className="goals-item" style={{ '--depth': depth } as CSSProperties}>
                {editing === goal.id && actions ? (
                  <GoalForm
                    goal={goal}
                    goals={goals}
                    parentId={goal.parentId ?? ''}
                    busy={busy}
                    onSave={async (draft) => {
                      if (await save(draft, goal.id)) setEditing(null)
                    }}
                    onCancel={() => setEditing(null)}
                  />
                ) : (
                  <>
                    <div className="goals-main">
                      <span className="goals-title" data-status={goal.status}>
                        {goal.title}
                      </span>
                      {goal.description !== '' && <p className="goals-description">{goal.description}</p>}
                      <span className="goals-counts" data-stalled={progress.stalled > 0 || undefined}>
                        {progressLine(progress)}
                      </span>
                    </div>
                    <div
                      className="goals-meter"
                      role="progressbar"
                      aria-label={`${goal.title}: ${progressLine(progress)}`}
                      aria-valuemin={0}
                      aria-valuemax={100}
                      aria-valuenow={share}
                    >
                      <span className="goals-meter-fill" style={{ width: `${share}%` }} />
                    </div>
                    {actions && (
                      <span className="goals-actions">
                        <select
                          className="mw-cell-select"
                          aria-label={`Status of the goal ${goal.title}`}
                          value={goal.status}
                          disabled={busy}
                          onChange={(event) => void run(() => actions.save({ id: goal.id, status: event.target.value }))}
                        >
                          {GOAL_STATUSES.map((status) => (
                            <option key={status.id} value={status.id}>
                              {status.label}
                            </option>
                          ))}
                        </select>
                        <button type="button" className="mw-link" disabled={busy} onClick={() => setEditing(`under:${goal.id}`)}>
                          Add a goal under it
                        </button>
                        <button type="button" className="mw-link" disabled={busy} onClick={() => setEditing(goal.id)}>
                          Edit
                        </button>
                        {removing === goal.id ? (
                          <>
                            <button
                              type="button"
                              className="dashboard-btn"
                              disabled={busy}
                              onClick={() => {
                                setRemoving(null)
                                void run(() => actions.remove(goal.id))
                              }}
                            >
                              Remove it
                            </button>
                            <button type="button" className="mw-link" onClick={() => setRemoving(null)}>
                              Keep it
                            </button>
                          </>
                        ) : (
                          <button
                            type="button"
                            className="mw-link"
                            disabled={busy}
                            title="Its tasks and the goals under it move up to the goal above it."
                            onClick={() => setRemoving(goal.id)}
                          >
                            Remove
                          </button>
                        )}
                      </span>
                    )}
                  </>
                )}
                {editing === `under:${goal.id}` && actions && (
                  <GoalForm
                    goal={null}
                    goals={goals}
                    parentId={goal.id}
                    busy={busy}
                    onSave={async (draft) => {
                      if (await save(draft, null)) setEditing(null)
                    }}
                    onCancel={() => setEditing(null)}
                  />
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}

/** New or edited: title, description, status, and the goal it serves. */
export function GoalForm({
  goal,
  goals,
  parentId,
  busy,
  onSave,
  onCancel,
}: {
  goal: GoalRow | null
  goals: readonly GoalRow[]
  parentId: string
  busy: boolean
  onSave(draft: GoalDraft): void
  onCancel(): void
}): ReactElement {
  const [draft, setDraft] = useState<GoalDraft>(() => goalDraftOf(goal, parentId))
  const set = (field: keyof GoalDraft) => (event: { target: { value: string } }) => setDraft((was) => ({ ...was, [field]: event.target.value }))
  const parents = goalOptions(parentChoices(goals, goal?.id ?? null))
  return (
    <form
      className="tasks-local-form"
      aria-label={goal === null ? 'New goal' : `Edit the goal ${goal.title}`}
      onSubmit={(event) => {
        event.preventDefault()
        onSave(draft)
      }}
    >
      <label className="tasks-local-field">
        <span>Goal</span>
        <input className="tasks-page-input" value={draft.title} maxLength={200} disabled={busy} placeholder="What the work is for" onChange={set('title')} />
      </label>
      <label className="tasks-local-field">
        <span>Description</span>
        <textarea
          className="tasks-page-input tasks-page-area"
          value={draft.description}
          maxLength={4000}
          disabled={busy}
          placeholder="Why it matters and what done looks like. Every agent working toward it reads this."
          onChange={set('description')}
        />
      </label>
      <div className="tasks-local-pair">
        <label className="tasks-local-field">
          <span>Status</span>
          <select value={draft.status} disabled={busy} onChange={set('status')}>
            {GOAL_STATUSES.map((status) => (
              <option key={status.id} value={status.id}>
                {status.label}
              </option>
            ))}
          </select>
        </label>
        <label className="tasks-local-field">
          <span>Part of</span>
          <select value={draft.parentId} disabled={busy} onChange={set('parentId')}>
            <option value="">No bigger goal</option>
            {parents.map((choice) => (
              <option key={choice.id} value={choice.id}>
                {choice.label}
              </option>
            ))}
          </select>
        </label>
      </div>
      <div className="tasks-local-buttons">
        <button type="submit" className="dashboard-btn tasks-page-new" disabled={busy || draft.title.trim() === ''}>
          {goal === null ? 'Add goal' : 'Save'}
        </button>
        <button type="button" className="dashboard-btn" disabled={busy} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  )
}
