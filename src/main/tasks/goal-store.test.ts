import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { GOALS_FILE, GoalStore, MAX_GOAL_DEPTH } from './goal-store'

/** Goals on disk, in a temporary folder: the tree's rules, and what survives a restart. */

let dir = ''
let at = 1_000
const now = (): number => (at += 1)

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-goals-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('a goal tree', () => {
  it('makes, changes and chains goals, child first up to the root', () => {
    const goals = new GoalStore({ dir: null, now })
    const root = goals.create({ title: 'A Mac release every fortnight', description: 'Steady cadence.' })
    const release = goals.create({ title: 'Ship 0.18', parentId: root.id, project: '/work/app', status: 'planned' })
    const notes = goals.create({ title: 'Release notes', parentId: release.id })
    expect(root).toMatchObject({ status: 'active', parentId: null, project: null, description: 'Steady cadence.' })
    expect(release).toMatchObject({ status: 'planned', parentId: root.id, project: '/work/app' })
    expect(goals.chain(notes.id).map((goal) => goal.title)).toEqual(['Release notes', 'Ship 0.18', 'A Mac release every fortnight'])
    expect(goals.subtree(root.id).map((goal) => goal.id)).toEqual([root.id, release.id, notes.id])
    goals.update(release.id, { status: 'achieved', title: 'Ship 0.18.0' })
    expect(goals.byId(release.id)).toMatchObject({ status: 'achieved', title: 'Ship 0.18.0', project: '/work/app' })
  })

  it('refuses a missing title, a bad status, a relative folder, an unknown parent and a loop', () => {
    const goals = new GoalStore({ dir: null, now })
    expect(() => goals.create({ title: '  ' })).toThrow(/title cannot be empty/)
    expect(() => goals.create({ title: 'x', status: 'done' })).toThrow(/planned, active, achieved, cancelled/)
    expect(() => goals.create({ title: 'x', project: 'relative' })).toThrow(/not a full folder path/)
    expect(() => goals.create({ title: 'x', parentId: 'goal-nope' })).toThrow(/parent goal no longer exists/)
    const a = goals.create({ title: 'A' })
    const b = goals.create({ title: 'B', parentId: a.id })
    expect(() => goals.update(a.id, { parentId: b.id })).toThrow(/cannot sit under itself/)
    expect(() => goals.update(a.id, { parentId: a.id })).toThrow(/cannot sit under itself/)
  })

  it('keeps the tree no deeper than the limit', () => {
    const goals = new GoalStore({ dir: null, now })
    let parent = goals.create({ title: 'level 1' })
    for (let level = 2; level <= MAX_GOAL_DEPTH; level += 1) parent = goals.create({ title: `level ${level}`, parentId: parent.id })
    expect(() => goals.create({ title: 'one too deep', parentId: parent.id })).toThrow(new RegExp(`at most ${MAX_GOAL_DEPTH} deep`))
  })

  it('moves a removed goal’s sub-goals up to its parent and says which parent that is', () => {
    const goals = new GoalStore({ dir: null, now })
    const root = goals.create({ title: 'Root' })
    const middle = goals.create({ title: 'Middle', parentId: root.id })
    const leaf = goals.create({ title: 'Leaf', parentId: middle.id })
    expect(goals.remove(middle.id).parentId).toBe(root.id)
    expect(goals.byId(leaf.id)?.parentId).toBe(root.id)
    expect(goals.has(middle.id)).toBe(false)
    expect(() => goals.remove(middle.id)).toThrow(/no longer exists/)
  })

  it('tells its listeners after a change', () => {
    const goals = new GoalStore({ dir: null, now })
    let heard = 0
    const stop = goals.onChange(() => (heard += 1))
    goals.create({ title: 'A' })
    stop()
    goals.create({ title: 'B' })
    expect(heard).toBe(1)
  })
})

describe('kept on disk', () => {
  it('survives a restart, owner-only, and reads a hand-broken parent as none', async () => {
    const goals = new GoalStore({ dir, now })
    const root = goals.create({ title: 'Root' })
    goals.create({ title: 'Child', parentId: root.id, description: 'Under root.' })
    goals.flush()
    const file = join(dir, GOALS_FILE)
    expect(statSync(file).mode & 0o777).toBe(0o600)
    const again = new GoalStore({ dir, now })
    expect(again.all().map((goal) => goal.title)).toEqual(['Root', 'Child'])

    const raw = JSON.parse(readFileSync(file, 'utf8')) as { v: 1; goals: Array<Record<string, unknown>> }
    raw.goals = raw.goals.filter((goal) => goal.title !== 'Root')
    raw.goals.push({ id: 'junk' })
    writeFileSync(file, JSON.stringify(raw))
    const broken = new GoalStore({ dir, now })
    expect(broken.all()).toHaveLength(1)
    expect(broken.all()[0]).toMatchObject({ title: 'Child', parentId: null })
  })
})
