import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  app: { getPath: () => '/tmp/terminaldeck-profiles-test' },
  session: { fromPartition: () => ({}) },
}))

const {
  DEFAULT_PARTITION,
  DEFAULT_PROFILE_ID,
  MAX_PROFILE_NAME,
  cleanProfileName,
  partitionFor,
  readProfileState,
} = await import('./browser-profiles')

describe('the partition a profile gets', () => {
  it('is the one that predates profiles, for the default', () => {
    /*
     * The upgrade property, and the one worth a test: somebody installing this
     * build is already signed into things in `persist:terminaldeck-browser`. A
     * profiles feature whose first act is a fresh partition would sign them out
     * of everything and look like data loss.
     */
    expect(partitionFor(DEFAULT_PROFILE_ID)).toBe(DEFAULT_PARTITION)
  })

  it('is refused for anything this module did not mint', () => {
    // Ids arrive from the renderer, and `fromPartition` will create a directory
    // for any string it is handed — including one with a path separator in it.
    // The same discipline `isIsolationKey` applies in `browser-isolation.ts`.
    expect(partitionFor('../../etc')).toBeNull()
    expect(partitionFor('persist:something-else')).toBeNull()
    expect(partitionFor(42)).toBeNull()
    expect(partitionFor('')).toBeNull()
  })

  it('is the prefix plus the id, for a real one', () => {
    const id = '3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d'
    expect(partitionFor(id)).toBe(`persist:terminaldeck-browser-${id}`)
  })

  it('cannot collide with the default partition', () => {
    // Both are `persist:terminaldeck-browser…`, so this is a real risk rather
    // than a hypothetical one: a profile whose partition equalled the default's
    // would share its cookies while claiming to be separate.
    const id = '00000000-0000-4000-8000-000000000000'
    expect(partitionFor(id)).not.toBe(DEFAULT_PARTITION)
  })
})

describe('the name a profile is shown under', () => {
  it('collapses whitespace and control characters', () => {
    // A newline in a menu row is a rendering bug a person cannot see the cause
    // of, and a name is read aloud by a screen reader.
    expect(cleanProfileName('  Work\n\tAccount ')).toBe('Work Account')
  })

  it('falls back rather than showing an empty row', () => {
    expect(cleanProfileName('   ', 'Default')).toBe('Default')
    expect(cleanProfileName(null, 'Default')).toBe('Default')
  })

  it('clamps a paste', () => {
    expect(cleanProfileName('x'.repeat(500)).length).toBe(MAX_PROFILE_NAME)
  })
})

describe('reading the stored list', () => {
  it('always has a default profile, even if the file lost it', () => {
    // A list with no default is a list where the partition holding every login
    // from before this feature is unreachable.
    const state = readProfileState({ profiles: [], activeId: 'whatever' })
    expect(state.profiles.map((p) => p.id)).toContain(DEFAULT_PROFILE_ID)
    expect(state.activeId).toBe(DEFAULT_PROFILE_ID)
  })

  it('pulls a dangling active id back to the default', () => {
    // Otherwise every new tab opens into a partition with nothing in it, and
    // there is nothing on screen to say why the person is signed out.
    const state = readProfileState({
      profiles: [{ id: DEFAULT_PROFILE_ID, name: 'Default' }],
      activeId: 'deleted-one',
    })
    expect(state.activeId).toBe(DEFAULT_PROFILE_ID)
  })

  it('drops an entry whose id would not make a partition', () => {
    const state = readProfileState({
      profiles: [{ id: DEFAULT_PROFILE_ID, name: 'Default' }, { id: '../escape', name: 'Bad' }],
      activeId: DEFAULT_PROFILE_ID,
    })
    expect(state.profiles).toHaveLength(1)
  })

  it('survives a file that is not what it expected', () => {
    expect(readProfileState(null).profiles).toHaveLength(1)
    expect(readProfileState('nope').profiles).toHaveLength(1)
    expect(readProfileState({ profiles: 'nope' }).profiles).toHaveLength(1)
  })

  it('keeps the default undeletable by marking it', () => {
    expect(readProfileState(null).profiles[0].isDefault).toBe(true)
  })
})
