import { useId, type CSSProperties } from 'react'
import './HootMark.css'

/**
 * Hoot, drawn: an orange owl in round glasses whose eyes blink now and then.
 *
 * The one component every picture of the assistant goes through: the pinned
 * sidebar row, its tab, the window toolbar, its chat bubbles, the setup dialog,
 * Settings, and the empty states. Before 2026-10-03 each of those drew a compass
 * path from `identity.ts` on its own; one component is what keeps them the same
 * animal.
 *
 * ## Why the colours are hex, in this file, and not tokens
 *
 * The token rule in `CLAUDE.md` ("never raw hex") is about the *chrome*: the
 * greys, the accent and the status ramp that must change with the theme and
 * clear contrast against every surface. This is a mascot illustration. Hoot is
 * the same orange owl on a light window and a dark one, the way an app icon is,
 * so its colours are fixed brand art rather than theme values. They are named
 * once below and handed to the SVG as attributes, so no stylesheet carries a
 * hex and no chrome rule can borrow one by accident.
 *
 * ## Why one inline SVG per use, never `<use href>`
 *
 * A shared `<symbol>` puts the eyelids in a shadow tree that page styles cannot
 * animate per icon. Each mark is its own copy of the drawing, so each owl can
 * keep its own rhythm, which is the other half of the next note.
 *
 * ## Why two owls never blink together
 *
 * The blink is a 7-second cycle with a quick blink and an occasional softer
 * second one, the right eye 30 ms behind the left. Every instance shifts its
 * own cycle length and start through `--blink` / `--blink-at`, derived from
 * where it is mounted (`useId`), so the sidebar owl and the chat owl blink at
 * different moments and keep doing so across renders. A screen of owls blinking
 * in lock-step reads as a machine; out of step, they read as characters.
 *
 * Reduced motion turns the blink off entirely (in `HootMark.css`), and
 * `animated={false}` draws the same art with the lids folded, for any spot
 * where a moving thing would be noise.
 */

/** The palette, fixed brand art. See the header for why these are not tokens. */
const HOOT_COLOURS = {
  body: '#F7882F',
  bodyDark: '#E8701A',
  belly: '#FFD3A8',
  bellyLine: '#F2A86A',
  face: '#FFE7CF',
  eyeWhite: '#FFFFFF',
  pupil: '#2A1A10',
  lidLine: '#7A3E12',
  frames: '#5A3418',
  beak: '#B4500F',
  glint: '#FFFFFF',
} as const

interface Props {
  /** Pixels, square. Reads at 16 (sidebar) up to 200 (welcome). */
  size?: number
  /** False draws the same owl with its eyes open and still. */
  animated?: boolean
  /**
   * A label for screen readers, when the owl is the only thing naming Hoot.
   * Omitted, the mark is decorative and hidden from them, because almost every
   * place it appears already says the name in text beside it.
   */
  label?: string
  className?: string
}

/** A stable small number from a React id, so each mount gets its own rhythm. */
function seedOf(id: string): number {
  let hash = 0
  for (let i = 0; i < id.length; i += 1) hash = (hash * 31 + id.charCodeAt(i)) >>> 0
  return hash
}

export function HootMark({ size = 16, animated = true, label, className }: Props) {
  const seed = seedOf(useId())
  // 7 s to 9.5 s a cycle, starting anywhere in its first five seconds.
  const rhythm = {
    '--blink': `${(7 + (seed % 6) * 0.5).toFixed(1)}s`,
    '--blink-at': `${((seed >>> 3) % 50) / 10}s`,
  } as CSSProperties
  const c = HOOT_COLOURS
  return (
    <svg
      className={`hoot-mark${className ? ` ${className}` : ''}`}
      data-animated={animated ? 'true' : 'false'}
      width={size}
      height={size}
      viewBox="0 0 64 64"
      style={rhythm}
      {...(label === undefined
        ? { 'aria-hidden': true }
        : { role: 'img', 'aria-label': label })}
      focusable="false"
    >
      {/* ear tufts */}
      <path d="M15 17 L18 5 L26 14 Z" fill={c.bodyDark} />
      <path d="M49 17 L46 5 L38 14 Z" fill={c.bodyDark} />
      {/* body */}
      <path d="M32 9 C48 9 55 21 55 35 C55 50 45 59 32 59 C19 59 9 50 9 35 C9 21 16 9 32 9 Z" fill={c.body} />
      {/* belly */}
      <path d="M32 33 C42 33 46 41 46 47 C46 54 40 58 32 58 C24 58 18 54 18 47 C18 41 22 33 32 33 Z" fill={c.belly} />
      <path d="M26 44 q3 3 6 0 q3 3 6 0" stroke={c.bellyLine} strokeWidth="1.6" fill="none" strokeLinecap="round" />
      <path d="M28.5 50 q3.5 3 7 0" stroke={c.bellyLine} strokeWidth="1.6" fill="none" strokeLinecap="round" />
      {/* wings */}
      <path d="M10 33 C8 42 11 50 17 54 C15 46 15 39 17 33 Z" fill={c.bodyDark} />
      <path d="M54 33 C56 42 53 50 47 54 C49 46 49 39 47 33 Z" fill={c.bodyDark} />
      {/* face disc */}
      <ellipse cx="22.5" cy="25.5" rx="9.5" ry="9" fill={c.face} />
      <ellipse cx="41.5" cy="25.5" rx="9.5" ry="9" fill={c.face} />
      {/* eyes */}
      <circle cx="23" cy="26" r="5.4" fill={c.eyeWhite} />
      <circle cx="41" cy="26" r="5.4" fill={c.eyeWhite} />
      <circle cx="23.6" cy="26.6" r="3" fill={c.pupil} />
      <circle cx="41.6" cy="26.6" r="3" fill={c.pupil} />
      <circle cx="24.6" cy="25.4" r="1" fill={c.eyeWhite} />
      <circle cx="42.6" cy="25.4" r="1" fill={c.eyeWhite} />
      {/* eyelids: the body's orange, folded up until they blink */}
      <g className="hoot-lid">
        <ellipse cx="23" cy="26" rx="5.9" ry="5.9" fill={c.body} />
        <path d="M18.6 28.4 Q23 31.6 27.4 28.4" stroke={c.lidLine} strokeWidth="1.5" fill="none" strokeLinecap="round" />
      </g>
      <g className="hoot-lid hoot-lid-r">
        <ellipse cx="41" cy="26" rx="5.9" ry="5.9" fill={c.body} />
        <path d="M36.6 28.4 Q41 31.6 45.4 28.4" stroke={c.lidLine} strokeWidth="1.5" fill="none" strokeLinecap="round" />
      </g>
      {/* glasses: round frames, a bridge, and arms to the tufts */}
      <circle cx="23" cy="26" r="8" fill="none" stroke={c.frames} strokeWidth="2.4" />
      <circle cx="41" cy="26" r="8" fill="none" stroke={c.frames} strokeWidth="2.4" />
      <path d="M30.6 24.6 Q32 23 33.4 24.6" fill="none" stroke={c.frames} strokeWidth="2.4" strokeLinecap="round" />
      <path d="M15 24 L11.5 22.5" stroke={c.frames} strokeWidth="2.2" strokeLinecap="round" />
      <path d="M49 24 L52.5 22.5" stroke={c.frames} strokeWidth="2.2" strokeLinecap="round" />
      {/* a glint on each lens */}
      <path d="M18.5 21.5 q2 -2 4.5 -2.2" stroke={c.glint} strokeOpacity=".75" strokeWidth="1.3" fill="none" strokeLinecap="round" />
      <path d="M36.5 21.5 q2 -2 4.5 -2.2" stroke={c.glint} strokeOpacity=".75" strokeWidth="1.3" fill="none" strokeLinecap="round" />
      {/* beak */}
      <path d="M29.6 33 L34.4 33 L32 37.4 Z" fill={c.beak} />
    </svg>
  )
}
