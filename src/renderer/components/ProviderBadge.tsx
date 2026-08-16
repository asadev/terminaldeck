import type { ReactElement } from 'react'
import type { ProviderId } from '@shared/types'
import './ProviderBadge.css'

/**
 * The mark that says which agent you are talking to.
 *
 * Asked for in as many words: *"in the dropdown we can see which account is
 * connected — but next to it we should also see the logo of the LLM."* The
 * account name answers "whose login"; it does not answer "which model", and in
 * a window running four sessions against three agents that is the question a
 * person is actually asking. A word would answer it too, but the account row
 * already carries two words and an email; a 14px mark answers it without
 * costing a line.
 *
 * ## Where these drawings came from, and why they are safe to ship
 *
 * Every path below was constructed here from a geometric rule, not traced from
 * anyone's artwork and not lifted from an icon package. That matters twice
 * over: this repository's ground rule is that copying a component pulls its
 * licence in permanently, and a brand mark carries a trademark on top of the
 * copyright. What is drawn is the *shape family* each service is recognised by,
 * at the size a client app identifies a connected service at — which is the
 * ordinary, expected use of a mark and is why a mail client may draw an
 * envelope beside "Gmail".
 *
 *  - **Claude** — an eight-spoke radial burst. Eight equal strokes at 45°,
 *    inner radius 1.6, outer 6.2, round caps. Anthropic's mark is a burst; this
 *    is a burst, built from `for (angle of 0..315 step 45)` and written out.
 *  - **Codex / ChatGPT** — an open hexagonal loop with a tail turning inward.
 *    A regular hexagon on radius 6, one edge left out, and a short stroke from
 *    each open end heading toward the centre. OpenAI's mark is a six-fold
 *    interlace; a six-fold loop that does not quite close is the same gestalt
 *    reduced to what survives at 14px, and none of the interlace geometry is
 *    reproduced.
 *  - **Gemini** — a four-pointed sparkle with concave sides, drawn as four
 *    quadratic curves between the points. This is the generic "sparkle" glyph
 *    that predates and outlives any one product; it is in every emoji font.
 *  - **Shell** — a prompt chevron and an underscore. Not a brand at all.
 *
 * ## Monochrome, deliberately
 *
 * Every path is `currentColor`, so the mark takes the colour of whatever text
 * it sits beside and is correct in both themes without a second definition —
 * which is the house rule about never defining a colour only inside
 * `[data-theme='dark']`, satisfied by not defining one at all. Brand colours
 * were considered and dropped: the palette here is warm and narrow, four
 * saturated logos in a toolbar would be the loudest thing on screen, and the
 * only tokens available to tint them with are *status* colours, where a green
 * mark would read as "this agent is fine".
 *
 * Nothing is fetched. The paths are inline, so there is no network request to
 * be blocked by the app's CSP and nothing to fail when the app is offline.
 */

/** 16-unit box for every mark, so they optically match at any rendered size. */
const BOX = 16

/**
 * The eight spokes of the Claude burst, generated rather than typed.
 *
 * Written as a computation because that is what it is — eight identical
 * strokes on a circle — and because a hand-typed list of sixteen coordinates is
 * a list with a typo in it that nobody sees until the mark is on screen.
 */
const CLAUDE_SPOKES: ReadonlyArray<{ x1: number; y1: number; x2: number; y2: number }> = Array.from(
  { length: 8 },
  (_unused, index) => {
    const angle = (index * Math.PI) / 4
    const cx = BOX / 2
    const cy = BOX / 2
    const round = (value: number): number => Math.round(value * 100) / 100
    return {
      x1: round(cx + Math.cos(angle) * 1.6),
      y1: round(cy - Math.sin(angle) * 1.6),
      x2: round(cx + Math.cos(angle) * 6.2),
      y2: round(cy - Math.sin(angle) * 6.2),
    }
  },
)

function ClaudeMark() {
  return (
    <>
      {CLAUDE_SPOKES.map((spoke) => (
        <line
          key={`${spoke.x1},${spoke.y1}`}
          x1={spoke.x1}
          y1={spoke.y1}
          x2={spoke.x2}
          y2={spoke.y2}
        />
      ))}
    </>
  )
}

function CodexMark() {
  return (
    <>
      {/* Five of a hexagon's six edges, starting after the missing one. */}
      <path d="M13.2 5 L13.2 11 L8 14 L2.8 11 L2.8 5 L8 2" />
      {/* The two open ends turn inward, which is what makes it read as a knot
          rather than as a hexagon somebody forgot to close. */}
      <path d="M8 2 L10.4 3.4" />
      <path d="M13.2 5 L10.9 6.35" />
    </>
  )
}

function GeminiMark() {
  return (
    <path
      d="M8 1.4 Q9.1 6.9 14.6 8 Q9.1 9.1 8 14.6 Q6.9 9.1 1.4 8 Q6.9 6.9 8 1.4 Z"
      fill="currentColor"
      stroke="none"
    />
  )
}

function ShellMark() {
  return (
    <>
      <path d="M3.6 4.8 L7.4 8 L3.6 11.2" />
      <path d="M8.8 11.6 L12.6 11.6" />
    </>
  )
}

const MARKS: Record<ProviderId, () => ReactElement> = {
  claude: ClaudeMark,
  codex: CodexMark,
  gemini: GeminiMark,
  shell: ShellMark,
}

/**
 * Whether there is a mark for this id at all.
 *
 * Exported so a caller can decide between "draw the badge" and "leave the space
 * out" rather than reserving a gap for something that will not appear. A
 * provider this build has never heard of — a session restored from a newer
 * version, a `list` frame from a desktop running ahead of this one — gets
 * nothing drawn, because a placeholder glyph beside an account name is a claim
 * about which service the login belongs to, and a wrong one.
 */
export function hasProviderMark(provider: string | null | undefined): provider is ProviderId {
  return typeof provider === 'string' && provider in MARKS
}

interface Props {
  /** Anything at all; unrecognised ids render nothing. See `hasProviderMark`. */
  provider: string | null | undefined
  /** Rendered edge length in px. Defaults to the 14px control metric. */
  size?: number
  /**
   * The agent's name, for anyone not looking at the screen.
   *
   * When the mark sits *beside* text that already names the agent, pass
   * nothing: the badge then goes `aria-hidden`, because a screen reader
   * announcing "Claude Code Claude Code" is worse than one announcing it once.
   */
  label?: string
  className?: string
}

export function ProviderBadge({ provider, size = 14, label, className }: Props) {
  if (!hasProviderMark(provider)) return null
  const Mark = MARKS[provider]

  return (
    <svg
      className={className === undefined ? 'provider-badge' : `provider-badge ${className}`}
      data-provider={provider}
      viewBox={`0 0 ${BOX} ${BOX}`}
      width={size}
      height={size}
      // Strokes rather than fills for three of the four, so one width setting
      // controls the weight of all of them and they sit at the same optical
      // density beside 13px text.
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      strokeLinejoin="round"
      role={label === undefined ? 'presentation' : 'img'}
      aria-hidden={label === undefined ? true : undefined}
      aria-label={label}
    >
      {label !== undefined && <title>{label}</title>}
      <Mark />
    </svg>
  )
}
