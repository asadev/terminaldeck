import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BRAND } from '../../../shared/brand'
import { toPluginsResult, toPluginsState } from '../../plugins/plugins-model'
import { AllowForm, PluginList, PluginsSection } from './PluginsSection'

/**
 * Settings → Plugins, rendered to a string the way every settings test here is.
 *
 * Static markup runs no effects, so the pane's loaded state is drawn by
 * rendering its list with a state already read — through the same narrowing
 * the pane uses, so a field the model drops is a field this test cannot see.
 */

const noop = (): void => undefined
const run = async (): Promise<boolean> => true

const STATE = toPluginsState({
  folder: '/Users/someone/Library/Application Support/terminaldeck/plugins',
  confinement: 'Each plugin runs in a sandbox the Mac enforces.',
  projects: ['/Users/someone/code/site', '/Users/someone/code/app'],
  plugins: [
    {
      id: 'word-count',
      name: 'Word count',
      summary: 'Counts the words in your tasks.',
      version: '1.2.0',
      enabled: true,
      state: 'running',
      note: 'Running.',
      declared: ['tasks.read', 'knowledge.read', 'tools.contribute'],
      granted: ['tasks.read', 'knowledge.read', 'tools.contribute'],
      projects: ['/Users/someone/code/site'],
      allowed: true,
      tools: [{ name: 'count', wire: 'plugin_word-count_count', title: 'Count words', tier: 'read' }],
    },
    {
      id: 'pinger',
      name: 'Pinger',
      summary: 'Tells you when a task changes.',
      version: '0.1.0',
      enabled: false,
      state: 'needs-ok',
      note: 'Not allowed yet. Nothing in it has run.',
      declared: ['tasks.read', 'notify'],
      granted: [],
      projects: [],
      allowed: false,
      tools: [],
      sneaky: 'a field the model does not know',
    },
    { id: 'odd', state: 'exploded' },
  ],
})

describe('Settings → Plugins', () => {
  it('says the channels are missing rather than drawing controls that reach nothing', () => {
    const html = renderToStaticMarkup(<PluginsSection bridge={{}} />)
    expect(html).toContain('Plugins')
    expect(html).toContain('no channels for plugins')
    expect(html).not.toContain('Allow…')
  })

  it('reads before it draws', () => {
    const html = renderToStaticMarkup(
      <PluginsSection bridge={{ pluginsState: () => new Promise(() => undefined), onPluginsChanged: () => noop }} />,
    )
    expect(html).toContain('Reading the plugins folder')
  })

  it('reads only the states it knows', () => {
    expect(STATE?.plugins.map((plugin) => plugin.id)).toEqual(['word-count', 'pinger'])
    expect(toPluginsResult({ ok: false, message: 'You said no, so nothing was allowed.', state: null }).message).toBe(
      'You said no, so nothing was allowed.',
    )
  })

  it('lists each plugin with what it asks for, what it was allowed, and its controls', () => {
    const html = renderToStaticMarkup(<PluginList state={STATE!} busy={false} bridge={{ pluginsEnable: async () => null }} run={run} />)
    // The allowed one: its switch, what it has, where, and the tools it gives Hoot.
    expect(html).toContain('Word count')
    expect(html).toContain('Running')
    expect(html).toContain('Read your tasks — allowed')
    expect(html).toContain('Read what is recorded about the projects you choose: site — allowed')
    expect(html).toContain(`Tools for ${BRAND.assistant}: Count words (read)`)
    expect(html.match(/role="switch"/g)).toHaveLength(1)
    // The new one: nothing allowed, no switch, and the button that asks.
    expect(html).toContain('Not allowed yet. Nothing in it has run.')
    expect(html).toContain('Show you notifications — not allowed')
    expect(html).toContain('Allow…')
    expect(html.match(/Remove…/g)).toHaveLength(2)
  })

  it('starts a first allow from everything it asks for, and says a dialog will ask', () => {
    const pinger = STATE!.plugins[1]
    const html = renderToStaticMarkup(<AllowForm plugin={pinger} projects={STATE!.projects} busy={false} onAllow={async () => undefined} onCancel={noop} />)
    expect(html.match(/role="switch"/g)).toHaveLength(2)
    expect(html.match(/checked=""/g)).toHaveLength(2)
    expect(html).toContain('Allow…')
    expect(html).toContain('You are asked to confirm in a dialog.')
  })

  it('offers the projects under a project-scoped capability, with the one already chosen on', () => {
    const counter = STATE!.plugins[0]
    const html = renderToStaticMarkup(<AllowForm plugin={counter} projects={STATE!.projects} busy={false} onAllow={async () => undefined} onCancel={noop} />)
    expect(html).toContain('/Users/someone/code/site')
    expect(html).toContain('/Users/someone/code/app')
    // Three capabilities on, one project on, one off; nothing new chosen, so it saves without asking.
    expect(html.match(/checked=""/g)).toHaveLength(4)
    expect(html).toContain('>Save<')
  })
})
