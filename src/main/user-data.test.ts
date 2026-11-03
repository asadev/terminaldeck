import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { App } from 'electron'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import { pinUserData, userDataFlag } from './user-data'

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

describe('an explicit --user-data-dir', () => {
  /*
   * The flag that was silently discarded.
   *
   * A second copy of the app was launched with its own `--user-data-dir` so it
   * could not disturb the installed one. Electron folded the flag into
   * `getPath('userData')`, `pinUserData` rewrote that to
   * `dirname(flag)/terminaldeck`, and both processes ended up on the same
   * `relay-identity.json` — then spent hours evicting each other at the relay.
   * The visible symptom was a phone that could never pair, with nothing
   * anywhere reporting an error.
   */
  it('is read from argv, in both spellings', () => {
    expect(userDataFlag(['electron', '--user-data-dir=/tmp/probe'])).toBe('/tmp/probe')
    expect(userDataFlag(['electron', '--user-data-dir', '/tmp/probe'])).toBe('/tmp/probe')
  })

  it('is absent when it is not given, or given nothing', () => {
    expect(userDataFlag(['electron', '.'])).toBeNull()
    expect(userDataFlag(['electron', '--user-data-dir='])).toBeNull()
    // A following flag is not a path — this is the case that would otherwise
    // steal the next argument and pin userData to something like `--inspect`.
    expect(userDataFlag(['electron', '--user-data-dir', '--inspect'])).toBeNull()
  })

  it('stops pinUserData from moving the directory the caller named', () => {
    const argv = process.argv
    process.argv = ['electron', '--user-data-dir=/tmp/td-explicit']
    try {
      let asked: string | null = null
      const app = {
        getPath: () => '/tmp/td-explicit',
        setPath: (_k: string, value: string) => {
          asked = value
        },
      } as unknown as Parameters<typeof pinUserData>[0]
      pinUserData(app)
      // Not merely "pinned to the right place" — not touched at all.
      expect(asked).toBeNull()
    } finally {
      process.argv = argv
    }
  })
})
