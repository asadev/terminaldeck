import { describe, expect, it } from 'vitest'
import { ChannelDesk } from './desk'

describe('ChannelDesk', () => {
  it('calls the handler the renderer would have called', async () => {
    const desk = new ChannelDesk()
    desk.handle('remote:folders:set', (_event, id, folders) => ({ id, folders }))
    expect(await desk.invoke('remote:folders:set', 'device-1', ['/a'])).toEqual({
      id: 'device-1',
      folders: ['/a'],
    })
  })

  it('hands the handler a null event, because no handler may trust its sender', async () => {
    // Every handler in this codebase names the parameter `_event` and never
    // reads it: a main-process handler that trusted its sender could be called
    // by any code running in that window. `null` is therefore the honest value
    // rather than a gap in the stand-in.
    const desk = new ChannelDesk()
    let seen: unknown = 'untouched'
    desk.handle('brand:get', (event) => {
      seen = event
      return null
    })
    await desk.invoke('brand:get')
    expect(seen).toBeNull()
  })

  it('awaits an async handler', async () => {
    const desk = new ChannelDesk()
    desk.handle('remote:start', async () => 'started')
    expect(await desk.invoke('remote:start')).toBe('started')
  })

  it('refuses a second handler for one channel, as ipcMain does', async () => {
    // Silently replacing would let a double registration answer with whichever
    // copy registered last, which is a coin flip that only shows in production.
    const desk = new ChannelDesk()
    desk.handle('remote:status', () => 'first')
    expect(() => desk.handle('remote:status', () => 'second')).toThrow(/Two handlers/)
    expect(await desk.invoke('remote:status')).toBe('first')
  })

  it('says a missing channel is a skipped registration, not an unsupported command', async () => {
    const desk = new ChannelDesk()
    await expect(desk.invoke('remote:pair')).rejects.toThrow(/registration was skipped/)
  })

  it('lists what it holds, sorted, for the seam test and for diagnostics', () => {
    const desk = new ChannelDesk()
    desk.handle('remote:status', () => null)
    desk.handle('machines:code', () => null)
    expect(desk.channels()).toEqual(['machines:code', 'remote:status'])
    expect(desk.has('remote:status')).toBe(true)
    expect(desk.has('remote:nothing')).toBe(false)
  })
})
