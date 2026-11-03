import { afterEach, describe, expect, it } from 'vitest'
import { BRAND } from '../../shared/brand'
import {
  electronPaths,
  installPaths,
  nodePaths,
  paths,
  resetPaths,
  userDataDir,
} from './paths'

afterEach(() => {
  resetPaths()
})

describe('nodePaths', () => {
  it('puts Linux state under XDG_DATA_HOME', () => {
    const p = nodePaths({
      platform: 'linux',
      env: { XDG_DATA_HOME: '/home/asad/.local/share' },
      home: '/home/asad',
    })
    expect(p.userData()).toBe(`/home/asad/.local/share/${BRAND.id}`)
  })

  it('falls back to ~/.local/share when XDG_DATA_HOME is unset', () => {
    const p = nodePaths({ platform: 'linux', env: {}, home: '/home/asad' })
    expect(p.userData()).toBe(`/home/asad/.local/share/${BRAND.id}`)
  })

  it('ignores a relative XDG_DATA_HOME', () => {
    // A service manager's working directory is not somewhere to keep a private
    // key, and POSIX says a relative value here means unset.
    const p = nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: 'share' }, home: '/home/asad' })
    expect(p.userData()).toBe(`/home/asad/.local/share/${BRAND.id}`)
  })

  it('matches the pinned Application Support directory on macOS', () => {
    // The same constant `user-data.ts` pins the Electron build to, so a headless
    // host and the desktop on one Mac read one trust store rather than two.
    const p = nodePaths({ platform: 'darwin', env: {}, home: '/Users/asad' })
    expect(p.userData()).toBe(`/Users/asad/Library/Application Support/${BRAND.id}`)
  })

  it('uses APPDATA on Windows, and derives it when it is missing', () => {
    expect(
      nodePaths({ platform: 'win32', env: { APPDATA: 'C:\\Users\\Asad\\AppData\\Roaming' }, home: 'C:\\Users\\Asad' })
        .userData()
        .replace(/\\/g, '/'),
    ).toBe(`C:/Users/Asad/AppData/Roaming/${BRAND.id}`)

    expect(
      nodePaths({ platform: 'win32', env: {}, home: 'C:\\Users\\Asad' }).userData().replace(/\\/g, '/'),
    ).toBe(`C:/Users/Asad/AppData/Roaming/${BRAND.id}`)
  })

  it('honours XDG_DOWNLOAD_DIR on Linux only', () => {
    const linux = nodePaths({
      platform: 'linux',
      env: { XDG_DOWNLOAD_DIR: '/srv/incoming' },
      home: '/home/asad',
    })
    expect(linux.downloads()).toBe('/srv/incoming')

    const mac = nodePaths({
      platform: 'darwin',
      env: { XDG_DOWNLOAD_DIR: '/srv/incoming' },
      home: '/Users/asad',
    })
    expect(mac.downloads()).toBe('/Users/asad/Downloads')
  })
})

describe('the installed provider', () => {
  it('throws with a sentence naming both shells when nothing installed one', () => {
    expect(() => paths()).toThrow(/headless/i)
    expect(() => userDataDir()).toThrow(/src\/main\/index\.ts/)
  })

  it('refuses a second, different provider', () => {
    const first = nodePaths({ platform: 'linux', env: {}, home: '/home/a' })
    installPaths(first)
    // Installing the same object twice is a re-entrant import, not a conflict.
    expect(() => installPaths(first)).not.toThrow()
    expect(() => installPaths(nodePaths({ platform: 'linux', env: {}, home: '/home/b' }))).toThrow(
      /One process is one shell/,
    )
  })

  it('asks Electron on every call rather than capturing the answer', () => {
    // `pinUserData` moves userData after this is installed. A captured value
    // would leave the store reading the directory from before the pin — the
    // failure user-data.ts exists to close, one layer up.
    let where = '/before/pin'
    installPaths(
      electronPaths({
        getPath: (name) => (name === 'userData' ? where : `/${name}`),
        getAppPath: () => '/app',
      }),
    )
    expect(userDataDir()).toBe('/before/pin')
    where = '/after/pin'
    expect(userDataDir()).toBe('/after/pin')
  })
})
