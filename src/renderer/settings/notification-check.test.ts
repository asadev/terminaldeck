import { describe, expect, it } from 'vitest'
import { deliveryCopy } from './notification-check'

/**
 * The wording is the feature, so the wording is what is tested.
 *
 * This pane once printed **"Sent. If nothing appeared, the banner was
 * suppressed by a Focus mode."** for a banner macOS had silently dropped — a
 * confident success it had not confirmed, followed by the single cause that had
 * already been checked and ruled out. Both halves sent whoever was debugging it
 * in the wrong direction for hours.
 *
 * These tests are the tripwire on both halves.
 */
describe('deliveryCopy', () => {
  it('only sounds like success when the OS confirmed it', () => {
    const copy = deliveryCopy({ verdict: 'delivered', at: '2026-08-14 09:52:11' }, 'test', 'mac')
    expect(copy.tone).toBe('info')
    expect(copy.text).toContain('macOS recorded a banner')
    expect(copy.text).toContain('09:52:11')
    // Nothing to escape to: it worked.
    expect(copy.offerSettings).toBe(false)
  })

  it('says the OS has no record when the OS has no record', () => {
    const copy = deliveryCopy({ verdict: 'absent', at: null }, 'test', 'mac')
    expect(copy.tone).toBe('warn')
    expect(copy.text).toContain('no record')
    expect(copy.offerSettings).toBe(true)
  })

  it('names authorisation, not a Focus mode, as the likely cause', () => {
    const copy = deliveryCopy({ verdict: 'absent', at: null }, 'test', 'mac')
    expect(copy.text).toMatch(/pending or has been refused/i)
    expect(copy.text).not.toMatch(/focus/i)
  })

  it('says where Allow hides, because that is the bug', () => {
    for (const kind of ['test', 'enabled'] as const) {
      const copy = deliveryCopy({ verdict: 'absent', at: null }, kind, 'mac')
      expect(copy.text).toContain('Options')
    }
    expect(deliveryCopy({ verdict: 'unknown', at: null }, 'enabled', 'mac').text).toContain('Options')
  })

  it('never claims delivery it could not check', () => {
    const copy = deliveryCopy({ verdict: 'unknown', at: null }, 'test', 'mac')
    expect(copy.tone).toBe('warn')
    expect(copy.text).toContain('cannot read')
    expect(copy.text).not.toMatch(/^Sent\b/)
    expect(copy.offerSettings).toBe(true)
  })

  it('names the reader’s own OS, never macOS at a Windows user', () => {
    const windows = deliveryCopy({ verdict: 'unknown', at: null }, 'test', 'windows')
    expect(windows.text).toContain('Windows')
    expect(windows.text).not.toContain('macOS')

    const other = deliveryCopy({ verdict: 'absent', at: null }, 'test', 'other')
    expect(other.text).not.toContain('macOS')
    expect(other.text).not.toContain('Windows')
  })

  it('reports a switch being turned on without pretending it is proven', () => {
    const unknown = deliveryCopy({ verdict: 'unknown', at: null }, 'enabled', 'mac')
    expect(unknown.text).toMatch(/^On\./)
    expect(unknown.tone).toBe('warn')

    const proven = deliveryCopy({ verdict: 'delivered', at: '2026-08-14 09:52:11' }, 'enabled', 'mac')
    expect(proven.text).toMatch(/proven/i)
    expect(proven.tone).toBe('info')
  })
})
