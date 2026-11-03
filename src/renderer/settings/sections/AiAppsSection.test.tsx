import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AiAppsSection, resolveAiAppsBridge } from './AiAppsSection'

/**
 * The pane, rendered to a string the way every settings test here is.
 *
 * Static markup cannot run the pane's effects, so what is pinned is the part
 * that can go wrong before any IPC: a build with no channels says so in one
 * sentence rather than drawing controls that reach nothing, and a build with
 * them starts by reading, not by drawing a list it has not been given. The
 * flows — make a key, see it once, set it up, change it, revoke it — are
 * checked by rendering the real window in `.harness/aiapps.html`.
 */

describe('Connect an AI app', () => {
  it('says the channels are missing rather than drawing controls that reach nothing', () => {
    const html = renderToStaticMarkup(<AiAppsSection bridge={{}} />)
    expect(html).toContain('Connect an AI app')
    expect(html).toContain('no channels for AI app keys')
    expect(html).not.toContain('New key')
  })

  it('reads before it draws a list', () => {
    const html = renderToStaticMarkup(
      <AiAppsSection bridge={{ aiAppsState: async () => ({ keys: [] }), onAiAppsChanged: () => () => undefined }} />,
    )
    expect(html).toContain('Reading the keys')
    expect(html).not.toContain('No keys yet')
  })

  it('takes only the methods it names off the preload, each called through its host', async () => {
    const host = {
      calls: 0,
      aiAppsState(this: { calls: number }) {
        this.calls += 1
        return Promise.resolve({ keys: [] })
      },
      somethingElse: () => 'not mine',
    }
    const bridge = resolveAiAppsBridge(host)
    expect(Object.keys(bridge)).toEqual(['aiAppsState'])
    await bridge.aiAppsState?.()
    expect(host.calls).toBe(1)
  })
})
