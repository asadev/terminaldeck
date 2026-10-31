import { describe, expect, it } from 'vitest'
import {
  DEFAULT_STORE_API,
  resolveStoreApi,
  STORE_API_ENV,
  STORE_INDEX_PATH,
  storeApiBase,
  storeIndexUrl,
} from './store-api'

const none: NodeJS.ProcessEnv = {}

describe('where the catalogue is fetched from', () => {
  it('is terminaldeck.dev when nobody says otherwise', () => {
    expect(storeApiBase(none)).toBe(DEFAULT_STORE_API)
    expect(resolveStoreApi(none).overridden).toBe(false)
    expect(resolveStoreApi(none).ignored).toBeNull()
  })

  it('honours an https override', () => {
    const choice = resolveStoreApi({ [STORE_API_ENV]: 'https://staging.terminaldeck.dev' })
    expect(choice.base).toBe('https://staging.terminaldeck.dev')
    expect(choice.overridden).toBe(true)
  })

  it('honours plain http on this machine, which is what makes the local milestone possible', () => {
    for (const base of ['http://127.0.0.1:8931', 'http://localhost:8931', 'http://[::1]:8931']) {
      expect(storeApiBase({ [STORE_API_ENV]: base }), base).toBe(base)
    }
  })

  it('refuses plain http anywhere else, and says why rather than going quiet', () => {
    const choice = resolveStoreApi({ [STORE_API_ENV]: 'http://catalogue.example.com' })
    expect(choice.base).toBe(DEFAULT_STORE_API)
    expect(choice.overridden).toBe(false)
    expect(choice.ignored).toBe('http://catalogue.example.com is plain http, which is only allowed on this machine')
  })

  it('refuses a scheme that is not the web at all', () => {
    expect(resolveStoreApi({ [STORE_API_ENV]: 'file:///tmp/index.json' }).base).toBe(DEFAULT_STORE_API)
    expect(resolveStoreApi({ [STORE_API_ENV]: 'file:///tmp/index.json' }).ignored).toContain('not http or https')
  })

  it('refuses something that is not an address, without throwing', () => {
    expect(resolveStoreApi({ [STORE_API_ENV]: 'not a url' }).base).toBe(DEFAULT_STORE_API)
    expect(resolveStoreApi({ [STORE_API_ENV]: '   ' }).ignored).toBe('it was empty')
  })

  it('lets a variable typed for one run beat a setting somebody left behind', () => {
    const choice = resolveStoreApi({ [STORE_API_ENV]: 'http://localhost:8931' }, 'https://terminaldeck.dev')
    expect(choice.base).toBe('http://localhost:8931')
  })

  it('falls through to the setting when the variable is refused', () => {
    const choice = resolveStoreApi({ [STORE_API_ENV]: 'http://evil.example' }, 'https://staging.terminaldeck.dev')
    expect(choice.base).toBe('https://staging.terminaldeck.dev')
    expect(choice.ignored).toContain('plain http')
  })

  it('takes the trailing slash off, so nothing builds a double one', () => {
    expect(storeApiBase({ [STORE_API_ENV]: 'https://terminaldeck.dev/' })).toBe('https://terminaldeck.dev')
    expect(storeIndexUrl('https://terminaldeck.dev/')).toBe(`https://terminaldeck.dev${STORE_INDEX_PATH}`)
  })

  it('reads nothing from the real environment on its own', () => {
    /*
     * `src/shared` has no `process.env` read anywhere in it, and this file does
     * not become the first. Setting the variable in this process must change
     * nothing, because the environment is an argument.
     */
    const before = process.env[STORE_API_ENV]
    process.env[STORE_API_ENV] = 'https://somewhere.else.example'
    try {
      expect(storeApiBase(none)).toBe(DEFAULT_STORE_API)
    } finally {
      if (before === undefined) delete process.env[STORE_API_ENV]
      else process.env[STORE_API_ENV] = before
    }
  })

  it('builds the one address the catalogue is served at', () => {
    expect(storeIndexUrl('http://127.0.0.1:8931')).toBe('http://127.0.0.1:8931/store/index.json')
  })
})
