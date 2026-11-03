import { describe, expect, it } from 'vitest'
import type { NativeHost } from '../shared/native-shell'
import { HELP_TOPICS, SECTIONS } from './components/HelpPanel'
import { publishHelpContent, type NativeHelpContent } from './native-help'

function host(native: boolean): NativeHost & { tdHelp?: NativeHelpContent } {
  return { document: { documentElement: { dataset: native ? { shell: 'native' } : {} } } }
}

describe('the help is lent to the native window', () => {
  it('leaves every section and topic on the page, as plain data', () => {
    const page = host(true)
    const stop = publishHelpContent(page)
    expect(page.tdHelp?.sections).toBe(SECTIONS)
    expect(page.tdHelp?.topics).toBe(HELP_TOPICS)
    // What the native side reads is JSON: nothing in it may be lost on the way.
    expect(JSON.parse(JSON.stringify(page.tdHelp))).toEqual({ sections: SECTIONS, topics: HELP_TOPICS })
    stop()
    expect(page.tdHelp).toBeUndefined()
  })

  it('does nothing outside the native window', () => {
    const page = host(false)
    publishHelpContent(page)
    expect(page.tdHelp).toBeUndefined()
  })
})
