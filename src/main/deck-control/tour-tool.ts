/**
 * `tour.play` — the one tool driving mode adds, and the two gates it carries on
 * top of its tier.
 *
 * ## Where driving sits, and why it is not the tier above
 *
 * **`act`.** Logged, visible, undoable — `surface.ts`'s definition of the middle
 * tier, and driving is all three: a row in the action log, a panel that takes
 * the rail, and an Escape key that ends it.
 *
 * Not `read`, because it changes what is on screen, takes the reader's context
 * away and hides everything else. That is not free and it should leave a row.
 *
 * Not `alter`, because nothing driving does persists: no file, no setting, no
 * process. Putting a confirmation dialog in front of every tour is precisely the
 * confirmation fatigue `surface.ts` and `consent.ts` both refuse — *"a gate that
 * fires on everything is a gate nobody reads."*
 *
 * ## The two gates `act` does not give
 *
 * **Local only.** A paired phone must never make this Mac's screen move. A
 * remote `act` grant is a real thing somebody might hand out — `TierGrant` is
 * three booleans and `act` is the middle one — and driving must not ride in on
 * it. `COPILOT-CAPABILITIES.md` item 5 applied to a surface it did not
 * anticipate: the tool name is the same on both surfaces, deliberately, so the
 * grant that names the surface rather than the power hands over all of it.
 *
 * **Attended only.** A routine firing at 03:00 must not start a tour on a locked
 * screen. What a routine *may* do is ask for `start: 'offer'`, which posts an
 * alert and nothing else; playing it needs a click from somebody awake. The
 * refusal reason is `not-permitted-unattended`, which already exists at exactly
 * this level of the file for exactly this class of problem.
 *
 * Both are checks here rather than sentences in the instruction file, because
 * the prose version of a rule has been tried twice in this codebase and broken
 * both times.
 *
 * ## And the third gate, which is not in this file
 *
 * While a tour is playing, `sessions.send`, `sessions.start`, `sessions.stop`,
 * `settings.write` and `routines.*` are refused with
 * `not-permitted-while-driving`. That gate is in `control.ts`, because it
 * applies to *other* tools; this file only supplies the fact it reads. The
 * argument for it being a mechanism rather than a policy is in `control.ts` and
 * is worth reading before anybody relaxes it.
 */

import { byAttention } from './attention'
import { viewOf, type ToolContext, type ToolSpec } from './catalogue'
import {
  parseTourPlan,
  tourSummary,
  TourRefused,
  validateTour,
  MAX_NOTE_CHARS,
  MAX_QUOTE_CHARS,
  MAX_TOUR_STOPS,
} from './tour'
import type { TourStage } from './tour-stage'
import { Refused, type SessionView } from './surface'

/**
 * Every live session, in the order `attention.ts` puts them.
 *
 * `viewOf` and `byAttention` are the dispatcher's own, asked for rather than
 * reimplemented: this is the same list `sessions.list` returns and the same
 * order the sidebar draws, so a plan validated against it is validated against
 * the fleet the person is actually looking at.
 *
 * Rebuilt per call rather than cached. A tour is validated at the moment it
 * plays, which is the whole point of re-checking — a session can finish, die or
 * unblock between the plan being written and the screen moving.
 */
function fleetOf(context: ToolContext): SessionView[] {
  return context.surface
    .listSessions()
    .map((meta) => viewOf(context, meta))
    .sort(byAttention)
}

/**
 * The setting that decides whether the scan is put on the screen.
 *
 * `copilot.interactive`. **On by default**, because the feature is the showing:
 * somebody who has never touched this setting asked for a copilot that drives,
 * and defaulting to the quiet path would make the whole thing invisible until
 * discovered.
 *
 * It is a setting rather than a tool argument on purpose. The copilot must not
 * be able to decide whether its own work is watched — that is the person's
 * choice about their own screen — and it cannot: `PROTECTED_SETTING_PREFIXES`
 * in `catalogue.ts` already contains `copilot.`, so `settings.write` refuses
 * this key with no new work. The same mechanism that stops it changing its own
 * instructions stops it turning off the light.
 */
export const INTERACTIVE_KEY = 'copilot.interactive'

export function interactiveDriving(context: ToolContext): boolean {
  const value = context.surface.readSettings().settings[INTERACTIVE_KEY]
  // Anything other than an explicit false is on. A settings file that lost the
  // key, or holds a string from a hand edit, gets the documented default rather
  // than a quietly disabled feature.
  return value !== false
}

export function tourTool(stage: TourStage): ToolSpec {
  return {
    id: 'tour.play',
    wire: 'tour_play',
    tier: 'act',
    title: 'Drive the screen through what matters',
    description:
      'Walk the person through what happened, on their own screen: for each stop the app navigates to the ' +
      'session, draws a box around the exact text you quoted and lays a field of dots over everything else, ' +
      'then moves straight on at machine speed. It does NOT pause for them to read — they watch it work, ' +
      'and the reading happens at the end, when you post the combined answer. You write the whole tour in ' +
      'one call and the app plays it — there is no second ' +
      'turn per stop, so everything you want shown has to be in this one plan. ' +
      `At most ${MAX_TOUR_STOPS} stops; a longer plan is REFUSED rather than trimmed, and so is a quote over ` +
      `${MAX_QUOTE_CHARS} characters or a note over ${MAX_NOTE_CHARS}. ` +
      'Put the actual answer in `headline` — it is posted to this chat before anything moves, so the person ' +
      'has it whether or not they watch. The tour is the evidence, not the answer. ' +
      'Every quote is checked against the real transcript or the real terminal before it is shown, and every ' +
      '`why` is re-checked against this app\'s own data; a stop that fails either is dropped and the drop is ' +
      'reported to the person. So quote exactly, and only claim what is true. ' +
      'Nothing in a tour types, sends, starts or stops anything, and while it is playing the tools that ' +
      'change things are refused — ask afterwards. Do not use this for one thing you could say in a sentence.',
    index:
      'Drive the person\'s screen through what happened, quoting the real transcripts, as one plan of up to 12 stops.',
    inputSchema: {
      type: 'object',
      properties: {
        question: {
          type: 'string',
          description: 'What they asked, in their words. Kept in the record so the recap says what it answers.',
        },
        headline: {
          type: 'string',
          description:
            'The answer, in prose. Posted to this chat before the first stop. Write it as if the tour will ' +
            'not be watched.',
        },
        start: {
          type: 'string',
          enum: ['now', 'offer'],
          description:
            "'now' plays it. 'offer' posts a notification and waits for a click — the only thing a routine " +
            'with nobody at the machine may ask for.',
        },
        stops: {
          type: 'array',
          maxItems: MAX_TOUR_STOPS,
          description: 'In the order they should be seen. Worst first, as sessions.list already orders them.',
          items: {
            type: 'object',
            properties: {
              kind: {
                type: 'string',
                // No 'message' any more. It pointed at a bubble in the chat view,
                // and chat mode was removed from every ordinary session this round
                // — *"I don't think it can work smoothly, so it's better to
                // completely remove this."* The only chat that still renders is
                // the copilot's own conversation, which a tour never points at, so
                // a 'message' stop would resolve to an anchor nothing draws and the
                // person would be left on a lit-up nothing. 'screen' is the same
                // content read off the terminal.
                enum: ['screen', 'anchor'],
                description:
                  "'screen' points at a passage of terminal output, found by its text. 'anchor' points " +
                  "at a changed file or a session's usage reading, and carries no quote, because there " +
                  'is no source to check one against.',
              },
              sessionId: { type: 'string', description: 'The session this stop is about.' },
              quote: {
                type: 'string',
                maxLength: MAX_QUOTE_CHARS,
                description:
                  'Verbatim, exactly as it appears. This is checked; text that is not really there means the ' +
                  'stop is dropped.',
              },
              at: {
                type: 'string',
                enum: ['git-file', 'usage'],
                description:
                  "Which place. 'git-file' is a changed file in Source control; 'usage' is the session's " +
                  'own usage reading — the stacked limit bars in the toolbar above it.',
              },
              path: { type: 'string', description: 'For a git-file anchor: the path git reports as changed.' },
              note: {
                type: 'string',
                maxLength: MAX_NOTE_CHARS,
                description: 'Your one line about why this matters. Not a restatement of the quote.',
              },
              why: {
                type: 'string',
                enum: [
                  'blocked-on-you',
                  'failed',
                  'finished',
                  'looping',
                  'tool-failing',
                  'compacted',
                  'expensive',
                  'files-changed',
                  'question-asked',
                  'decision',
                ],
                description:
                  'The reason this app will check. Nine of these are looked up in data this app already ' +
                  'holds. "decision" is the one that is not — you get at most one per session, and its ' +
                  'quote still has to be real.',
              },
            },
            required: ['kind', 'sessionId', 'note', 'why'],
            additionalProperties: false,
          },
        },
      },
      required: ['question', 'headline', 'stops'],
      additionalProperties: false,
    },

    summary: (args) => {
      const stops = Array.isArray(args.stops) ? args.stops.length : 0
      const question = typeof args.question === 'string' ? args.question : ''
      return `Drive the screen through ${stops} stop${stops === 1 ? '' : 's'}: "${question.slice(0, 80)}"`
    },

    /*
     * Both gates in the precheck, ahead of the budgets and ahead of everything
     * else, for the reason `control.ts` gives about rules in general: a rule
     * that is checked after a call has spent a budget slot is a rule that costs
     * something to break. Neither of these can be unlocked by any answer, by
     * waiting, or by retrying.
     */
    precheck: (args, context) => {
      if (context.caller.kind !== 'local') {
        throw new Refused(
          'not-granted',
          'tour.play only runs for the person sitting at this machine. Driving moves the desktop screen and ' +
            'hides most of it, so a paired device cannot ask for it however it was granted. Answer in words ' +
            'instead — you can say everything a tour would have shown.',
        )
      }
      if (!context.attended) {
        throw new Refused(
          'not-permitted-unattended',
          'tour.play needs somebody watching the screen, and this run has nobody at the machine. Do not ' +
            'retry and do not look for another way. Say what you would have shown; if it is worth waking ' +
            'them for, ask with start: "offer", which posts a notification and waits for a click.',
        )
      }
      // Shape and budget, before anything is read off disk. A plan over budget
      // costs nothing to refuse and the model gets a sentence it can act on.
      //
      // Converted to `Refused` rather than allowed to escape as itself: a budget
      // is a *rule*, and `control.ts` records a rule and a fault as different
      // rows — "the copilot was told no" and "the copilot broke" must not
      // collapse into one line in the Activity pane.
      try {
        parseTourPlan(args)
      } catch (error) {
        if (error instanceof TourRefused) throw new Refused('not-permitted', error.message)
        throw error
      }
    },

    run: async (args, context) => {
      let plan
      try {
        plan = parseTourPlan(args)
      } catch (error) {
        if (error instanceof TourRefused) throw new Refused('not-permitted', error.message)
        throw error
      }

      const validated = await validateTour(plan, {
        surface: context.surface,
        sessions: fleetOf(context),
        now: context.now(),
      })
      const summary = tourSummary(validated)

      if (validated.plan.stops.length === 0) {
        /*
         * Nothing survived. Not an error — the checks did exactly what they are
         * for — and emphatically not a tour played with no stops, which would be
         * a panel taking the rail to show nothing.
         */
        return {
          value: {
            played: false,
            why: 'every stop was dropped',
            dropped: summary.reasons,
            advice:
              'Nothing in that plan could be stood behind. Re-read the sessions you are quoting: the text ' +
              'has to be there and the reason has to be true right now. Then answer in words, or send a ' +
              'smaller tour of the stops you can source.',
          },
          summary: { playing: 0, dropped: summary.dropped },
        }
      }

      if (!interactiveDriving(context)) {
        /*
         * Interactive mode is off. Same work, same checks, same answer — nothing
         * on the screen.
         *
         * Returned as a success rather than as a refusal, and the wording is
         * load-bearing: the copilot has to understand that the tour *happened*
         * and that its findings are the answer, or it will apologise for a
         * feature the person deliberately turned off. The one thing it must not
         * do is retry with `start: 'offer'` and put a notification on somebody's
         * screen instead.
         */
        const record = stage.quietly(validated)
        return {
          value: {
            played: false,
            shown: 'background',
            tourId: record.id,
            found: summary.playing,
            dropped: summary.dropped,
            droppedDetail: summary.reasons,
            note:
              'Interactive mode is off, so nothing was driven on their screen — but everything you sent was ' +
              'checked and recorded, and it is in the copilot’s own window as the answer. Say what you found, ' +
              'session by session, in your reply. Do not apologise for not driving and do not ask for it: they ' +
              'chose this.',
          },
          summary: { found: summary.playing, dropped: summary.dropped, shown: 'background' },
        }
      }

      const outcome = await stage.play(validated)
      if (!outcome.ok) {
        return {
          value: { played: false, why: outcome.why, ...sentenceFor(outcome.why) },
          summary: { playing: 0, dropped: summary.dropped, failed: outcome.why },
        }
      }

      return {
        value: {
          played: true,
          tourId: outcome.record.id,
          playing: summary.playing,
          dropped: summary.dropped,
          droppedDetail: summary.reasons,
          note:
            'The tour is on their screen now. It plays without you — do not narrate it, do not call this ' +
            'again, and wait: tools that change anything are refused until it ends.',
        },
        summary: { playing: summary.playing, dropped: summary.dropped, tourId: outcome.record.id },
      }
    },
  }
}

function sentenceFor(why: 'no-window' | 'no-answer' | 'already-driving'): { advice: string } {
  switch (why) {
    case 'no-window':
      return {
        advice:
          'There is no window open to play it in, so nothing was shown. Answer in words instead — the ' +
          'headline you wrote is the answer.',
      }
    case 'no-answer':
      return {
        advice:
          'The window was given the tour and did not start it. Nothing is on screen and nothing was ' +
          'changed. Say so, and answer in words.',
      }
    case 'already-driving':
      return {
        advice:
          'A tour is already playing on that screen. Two at once is not a thing a person can watch. Wait ' +
          'for it to finish.',
      }
  }
}
