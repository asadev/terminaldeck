import { DEVICE_PRESETS, FIT_ID, MAX_DIMENSION, MIN_DIMENSION, type Orientation, type Size } from './devices'

interface Props {
  presetId: string
  orientation: Orientation
  /** Raw text, so a half-typed width does not snap the view about. */
  customWidth: string
  customHeight: string
  /** What the page actually got, after the panel clamped it. */
  applied: Size
  clamped: boolean
  zoom: number
  mobileUserAgent: boolean

  onPreset(id: string): void
  onRotate(): void
  onCustom(axis: 'width' | 'height', value: string): void
  onZoom(delta: number): void
  onResetZoom(): void
  onMobileUserAgent(on: boolean): void
}

const CUSTOM_ID = 'custom'

/**
 * The responsive bar.
 *
 * It lives in the chrome above the page rather than floating over it, and that
 * is a constraint rather than a preference: the page is a native view painted
 * on top of this React tree, so a dropdown opening downwards would be drawn
 * *behind* the site it is meant to be resizing. Everything here is therefore
 * inline — a row of buttons and two number fields — and the bar grows taller
 * instead of opening a menu.
 */
export function DeviceBar({
  presetId,
  orientation,
  customWidth,
  customHeight,
  applied,
  clamped,
  zoom,
  mobileUserAgent,
  onPreset,
  onRotate,
  onCustom,
  onZoom,
  onResetZoom,
  onMobileUserAgent,
}: Props) {
  const framed = presetId !== FIT_ID

  return (
    <div className="bw-devices">
      <div className="bw-segmented" role="group" aria-label="Viewport size">
        <button
          type="button"
          data-on={presetId === FIT_ID || undefined}
          onClick={() => onPreset(FIT_ID)}
        >
          Fit
        </button>
        {DEVICE_PRESETS.map((preset) => (
          <button
            key={preset.id}
            type="button"
            data-on={presetId === preset.id || undefined}
            title={`${preset.width} x ${preset.height}`}
            onClick={() => onPreset(preset.id)}
          >
            {preset.label}
          </button>
        ))}
        <button
          type="button"
          data-on={presetId === CUSTOM_ID || undefined}
          onClick={() => onPreset(CUSTOM_ID)}
        >
          Custom
        </button>
      </div>

      {presetId === CUSTOM_ID && (
        <div className="bw-custom">
          <label>
            <span className="bw-field-label">W</span>
            <input
              type="text"
              inputMode="numeric"
              value={customWidth}
              aria-label="Custom width in pixels"
              onChange={(event) => onCustom('width', event.target.value)}
            />
          </label>
          <span className="bw-times">x</span>
          <label>
            <span className="bw-field-label">H</span>
            <input
              type="text"
              inputMode="numeric"
              value={customHeight}
              aria-label="Custom height in pixels"
              onChange={(event) => onCustom('height', event.target.value)}
            />
          </label>
          <span className="bw-note">
            {MIN_DIMENSION}–{MAX_DIMENSION}
          </span>
        </div>
      )}

      <button
        type="button"
        className="bw-chip"
        disabled={!framed}
        aria-label="Rotate"
        title="Rotate"
        onClick={onRotate}
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <rect x="3" y="8" width="12" height="9" rx="2" />
          <path d="M17 6a5 5 0 0 1 4 4" />
          <path d="M21 6v4h-4" />
        </svg>
        {orientation === 'portrait' ? 'Portrait' : 'Landscape'}
      </button>

      <div className="bw-zoom" role="group" aria-label="Zoom">
        <button type="button" aria-label="Zoom out" onClick={() => onZoom(-1)}>
          –
        </button>
        <button type="button" className="bw-zoom-value" onClick={onResetZoom} title="Reset to 100%">
          {Math.round(zoom * 100)}%
        </button>
        <button type="button" aria-label="Zoom in" onClick={() => onZoom(1)}>
          +
        </button>
      </div>

      <label className="bw-toggle">
        <input
          type="checkbox"
          checked={mobileUserAgent}
          onChange={(event) => onMobileUserAgent(event.target.checked)}
        />
        Mobile UA
      </label>

      <span className="bw-applied" data-clamped={clamped || undefined}>
        {applied.width} x {applied.height}
        {clamped && <em> — clipped to fit the panel</em>}
      </span>
    </div>
  )
}
