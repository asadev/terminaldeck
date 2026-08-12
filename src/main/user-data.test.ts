import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { App } from 'electron'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import { pinUserData } from './user-data'

let root: string

/** A stand-in for Electron's App with just the two path methods used here. */
const fakeApp = (userData: string): { app: App; current: () => string } => {
  let path = userData
  return {
    app: {
      getPath: () => path,
      setPath: (_name: string, value: string) => {
        path = value
      },
    } as unknown as App,
    current: () => path,
  }
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'userdata-'))
})
afterEach(() => rmSync(root, { recursive: true, force: true }))

describe('pinUserData', () => {
  it('moves userData to the slug, not the display name', () => {
    const named = join(root, BRAND.name)
    mkdirSync(named, { recursive: true })
    const { app, current } = fakeApp(named)

    pinUserData(app)

    expect(current()).toBe(join(root, BRAND.id))
  })

  it('carries state.json over on the first run after a rename', () => {
    const old = join(root, 'Pawl')
    mkdirSync(old, { recursive: true })
    writeFileSync(join(old, 'state.json'), '{"projects":["kept"]}')
    const { app, current } = fakeApp(old)

    pinUserData(app)

    expect(JSON.parse(readFileSync(join(current(), 'state.json'), 'utf8')).projects).toEqual(['kept'])
  })

  it('never overwrites state the pinned directory already has', () => {
    // The rename is not a one-way door: launching an older build re-creates the
    // old directory, and a second pin must not clobber newer settings with it.
    const old = join(root, 'Pawl')
    const pinned = join(root, BRAND.id)
    mkdirSync(old, { recursive: true })
    mkdirSync(pinned, { recursive: true })
    writeFileSync(join(old, 'state.json'), '{"projects":["stale"]}')
    writeFileSync(join(pinned, 'state.json'), '{"projects":["current"]}')

    pinUserData(fakeApp(old).app)

    expect(JSON.parse(readFileSync(join(pinned, 'state.json'), 'utf8')).projects).toEqual(['current'])
  })

  it('leaves the path alone when it is already pinned', () => {
    const pinned = join(root, BRAND.id)
    mkdirSync(pinned, { recursive: true })
    const { app, current } = fakeApp(pinned)

    pinUserData(app)

    expect(current()).toBe(pinned)
  })
})
