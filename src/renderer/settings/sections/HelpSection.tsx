import { Group, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import type { SectionProps } from '../settings-bridge'
import { HelpPanel } from '../../components/HelpPanel'
import { AboutSection } from './AboutSection'

/**
 * Help — a real page, which is what was asked for.
 *
 *   > "We should have a help page where we can see all the help-related
 *   > features, options — whatever you had before, those kinds of stuff. So
 *   > this can be a separate page."
 *
 * ## What "jumps to a page" meant, and why this replaces it
 *
 * Help was a link in the rail's footer that opened the marketing site in the
 * user's own browser. That came from an earlier instruction of his — *"maybe we
 * can make it like help button… it should take to terminal website"* — and this
 * one supersedes it, so the link is gone from the footer and the site is a row
 * *on* this page instead (About's "Website"). Nothing about that is a
 * contradiction to smooth over: a later statement wins, and the professional
 * thing he wanted is now one click from the help rather than in place of it.
 *
 * ## Assembled from what already exists, twice over
 *
 * Neither half of this pane is written here, and that is the point.
 *
 * `HelpPanel` is the ⌘? dialog's own component. It builds its shortcut table
 * from `keymap.ts` and its list of views from `shell/panels.ts`, so the help
 * cannot drift from the app the way a hand-written copy does — and its
 * stylesheet says out loud that it is used in both frames, so nothing in it
 * reaches outside its own box. `AboutSection` is the pane About used to be,
 * rendered in place. The alternative in both cases was retyping, which is the
 * failure he named: *"when you reorganize you mostly miss the things and you
 * drop some stuff."*
 *
 * ## The two sections this page deliberately does not draw
 *
 * **Shortcuts** is the popover off the rail's footer, which he asked for in
 * those words — *"maybe it can be only an icon here where we click and see the
 * shortcut as pop-up"* — so drawing the same forty chords again here would put
 * the longest reference in the window back on a page, one click away from the
 * popover that replaced it.
 *
 * **About** is hidden *inside* `HelpPanel` and drawn *above* it from the real
 * `AboutSection`, which is not the same thing as skipping it. The help panel's
 * own About card knows the version and the build line; the settings pane also
 * knows the licence, the source, the website and whether an update exists, and
 * it is the one the application menu opens. Showing both would be the version
 * number in two places on one screen.
 */
export function HelpSection(props: SectionProps) {
  const meta = sectionMeta('help')
  const { goTo } = props

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {/*
        The masthead first: what you are running, before how it works.

        This is also what makes the merge safe. `openSettings('about')` from the
        application menu resolves to this pane, and it has to arrive at the same
        block it has always arrived at rather than somewhere down a page of
        troubleshooting.
      */}
      <AboutSection {...props} />

      {/*
        A heading, and it is doing more than decoration.

        `HelpPanel` is not a `settings-*` element, so it inherits none of this
        window's rhythm — rendered bare it butted its search field straight
        against the update button above it, with no gap and nothing to say that
        one block had ended and another begun. A `Group` gives it the same space
        above it that every other block on every other pane gets, and the title
        names what the reader is about to be looking at, which the search field
        alone did not.
      */}
      <Group title="How it works">
        <HelpPanel
          // Both hidden for reasons that are not the same — see the note above.
          hideSections={['shortcuts', 'about']}
          /*
           * The one dead-ish link on the troubleshooting page, made live.
           *
           * "Open the Debug panel" is the last step of half the troubleshooting
           * topics, and in the ⌘? dialog it is only drawn when the host passes a
           * handler. Here the host is Settings, and the debug switch is two rail
           * entries down, so the button can genuinely take you to it. A screen
           * that says "this is not ready" has to say what to press; a screen
           * that says "open the Debug panel" has to open it.
           */
          onOpenDebug={() => goTo('advanced')}
          /*
           * Off, deliberately. The ⌘? dialog opens with the search field focused
           * because you opened a thing whose only job is search. This pane is
           * reached by clicking a row in a tab list whose arrow keys move
           * between panes, and stealing focus out of that list is how a keyboard
           * user loses their place in the rail.
           */
          autoFocus={false}
        />
      </Group>
    </>
  )
}
