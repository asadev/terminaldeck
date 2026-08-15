import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react'
import {
  settingsIn,
  valueOf,
  type NumberSetting,
  type SectionId,
  type Setting,
  type SettingValues,
} from './settings-schema'
import { NO_VERSION, NO_VERSION_HINT, toolVersionLabel, type ToolState } from './setup-status'

/**
 * The controls every section is built from.
 *
 * A row is generated from a schema entry — the label, the help line and the
 * kind of control all come from the declaration, so a section file lists the
 * settings it shows and nothing else. Anything a section needs beyond a row of
 * controls (a preview, a Test button, a list of installed browsers) is passed
 * in as trailing content rather than folded into the schema, because those are
 * not settings and pretending otherwise is how a "declarative" table ends up
 * with a `renderCustomThing` field.
 */

/* ----------------------------------------------------------------- parts -- */

export function SectionHead({ title, blurb }: { title: string; blurb?: string }) {
  return (
    <header className="settings-head">
      <h3 className="settings-head-title">{title}</h3>
      {blurb && <p className="settings-head-blurb">{blurb}</p>}
    </header>
  )
}

export function Group({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="settings-group">
      {title && <h4 className="settings-group-title">{title}</h4>}
      {children}
    </section>
  )
}

export function Row({
  label,
  help,
  control,
  labelId,
  helpId,
  htmlFor,
}: {
  label: string
  help?: string
  control: ReactNode
  labelId?: string
  helpId?: string
  /** Set when the control is a single labellable element. */
  htmlFor?: string
}) {
  return (
    <div className="settings-row">
      <div className="settings-row-text">
        {htmlFor ? (
          <label className="settings-label" id={labelId} htmlFor={htmlFor}>
            {label}
          </label>
        ) : (
          <span className="settings-label" id={labelId}>
            {label}
          </span>
        )}
        {help && (
          <span className="settings-help" id={helpId}>
            {help}
          </span>
        )}
      </div>
      <div className="settings-row-control">{control}</div>
    </div>
  )
}

export function Notice({
  tone = 'info',
  children,
}: {
  tone?: 'info' | 'warn' | 'error'
  children: ReactNode
}) {
  return (
    <p className="settings-notice" data-tone={tone} role={tone === 'info' ? undefined : 'status'}>
      {children}
    </p>
  )
}

export function Button({
  children,
  onClick,
  disabled,
  tone = 'default',
  type = 'button',
}: {
  children: ReactNode
  /** Omitted for a submit button, whose form owns the action. */
  onClick?(): void
  disabled?: boolean
  tone?: 'default' | 'primary' | 'danger'
  type?: 'button' | 'submit'
}) {
  return (
    <button
      type={type === 'submit' ? 'submit' : 'button'}
      className="settings-btn"
      data-tone={tone}
      disabled={disabled}
      onClick={onClick}
    >
      {children}
    </button>
  )
}

/**
 * The version beside a tool's name, on every screen that lists tools.
 *
 * One component rather than the same conditional written out in three files,
 * because the interesting case is the one all three used to skip: a tool that
 * was found and still has no version. See `toolVersionLabel`.
 */
export function ToolVersion({
  tool,
}: {
  // `label` is optional and used only to drop a trailing "(Claude Code)" that
  // repeats the row's own heading — see `toolVersionLabel`.
  tool: { state: ToolState; version?: string; label?: string }
}) {
  const label = toolVersionLabel(tool)
  if (!label) return null
  const missing = label === NO_VERSION
  return (
    <span
      className={missing ? 'settings-tool-version settings-tool-version-none' : 'settings-tool-version'}
      title={missing ? NO_VERSION_HINT : undefined}
    >
      {label}
    </span>
  )
}

/** An external link. The main process turns window.open into the real browser. */
export function LinkOut({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a className="settings-link" href={href} target="_blank" rel="noreferrer">
      {children}
    </a>
  )
}

export function Switch({
  checked,
  disabled,
  labelledBy,
  describedBy,
  onChange,
}: {
  checked: boolean
  disabled?: boolean
  labelledBy?: string
  describedBy?: string
  onChange(next: boolean): void
}) {
  return (
    <label className="settings-switch">
      <input
        type="checkbox"
        role="switch"
        checked={checked}
        disabled={disabled}
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        onChange={(event) => onChange(event.target.checked)}
      />
      <span className="settings-switch-track" aria-hidden="true">
        <span className="settings-switch-thumb" />
      </span>
    </label>
  )
}

/* ------------------------------------------------------------ typed fields -- */

/**
 * What a half-typed field should store, which is usually nothing.
 *
 * The field is controlled by the *stored* value, and the stored value is
 * clamped on the way in — so writing on every keystroke made the control
 * unusable: starting from 13 and typing "16" wrote 1, which clamped to the
 * minimum of 9, which then took the 6 to make 96, which clamped to 24. A value
 * that is still on its way to being in range is held in the field instead, and
 * committed when the user leaves it.
 *
 * The empty string is held for the same reason, and because `Number('')` is 0,
 * not NaN: clearing the field to retype it used to write the minimum
 * immediately, which is exactly the keystroke a user is about to replace.
 */
export function numberWhileTyping(setting: NumberSetting, raw: string): number | null {
  const text = raw.trim()
  if (text === '') return null
  const value = Number(text)
  if (!Number.isFinite(value)) return null
  if (value < setting.min || value > setting.max) return null
  return value
}

/** What a field holds once the user has finished with it. Clamped, not discarded. */
export function numberOnLeaving(setting: NumberSetting, raw: string): number | null {
  const text = raw.trim()
  if (text === '') return null
  const value = Number(text)
  if (!Number.isFinite(value)) return null
  return Math.min(setting.max, Math.max(setting.min, value))
}

/**
 * What the field shows, and a way to override it while it is being edited.
 *
 * A draft outlives the keystroke that made it but not a change from elsewhere:
 * the Browser section writes `browser.startUrl` from its "Use it" buttons while
 * that very field is on screen, and a stale draft would quietly put the old
 * address back the next time the field was flushed.
 */
function useDraft(external: string): [string, (next: string | null) => void] {
  const [draft, setDraft] = useState<string | null>(null)
  const seen = useRef(external)
  if (seen.current !== external) {
    seen.current = external
    if (draft !== null && draft !== external) setDraft(null)
  }
  return [draft ?? external, setDraft]
}

/** How long a text field waits before writing what has been typed into it. */
export const TEXT_COMMIT_DELAY_MS = 400

/**
 * A text setting. Written on a pause rather than on every keystroke — each save
 * is a whole settings file rewritten and renamed in the main process, and a
 * typed-in font name is thirty of those.
 *
 * Whatever is pending is flushed when the field loses focus and when the row is
 * unmounted, so closing the window mid-word still saves the word.
 */
function TextField({
  id,
  value,
  placeholder,
  disabled,
  describedBy,
  onCommit,
}: {
  id: string
  value: string
  placeholder?: string
  disabled?: boolean
  describedBy?: string
  onCommit(next: string): void
}) {
  const [text, setDraft] = useDraft(value)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pending = useRef<string | null>(null)
  // Read through a ref so the flush that runs on unmount uses the current
  // handler without the timer being torn down every time the parent re-renders.
  const commit = useRef(onCommit)
  commit.current = onCommit

  const flush = useCallback(() => {
    if (timer.current !== null) {
      clearTimeout(timer.current)
      timer.current = null
    }
    const next = pending.current
    pending.current = null
    if (next !== null) commit.current(next)
  }, [])

  useEffect(() => () => flush(), [flush])

  // A write from elsewhere wins over a keystroke that has not landed yet.
  // `useDraft` already replaces what is on screen; without this the queued
  // text would fire a moment later and put it straight back — reachable by
  // typing in the start-page field and then pressing one of Browser's "Use it"
  // buttons. After our own commit this runs with nothing queued, so it costs
  // nothing.
  useEffect(() => {
    if (timer.current !== null) {
      clearTimeout(timer.current)
      timer.current = null
    }
    pending.current = null
  }, [value])

  return (
    <input
      id={id}
      type="text"
      className="settings-input wide"
      value={text}
      placeholder={placeholder}
      disabled={disabled}
      spellCheck={false}
      autoComplete="off"
      aria-describedby={describedBy}
      onChange={(event) => {
        const next = event.target.value
        setDraft(next)
        pending.current = next
        if (timer.current !== null) clearTimeout(timer.current)
        timer.current = setTimeout(flush, TEXT_COMMIT_DELAY_MS)
      }}
      onBlur={flush}
    />
  )
}

/** A number setting, with the mid-edit rules above. */
function NumberField({
  id,
  setting,
  value,
  disabled,
  describedBy,
  onCommit,
}: {
  id: string
  setting: NumberSetting
  value: number
  disabled?: boolean
  describedBy?: string
  onCommit(next: number): void
}) {
  const [text, setDraft] = useDraft(String(value))

  return (
    <input
      id={id}
      type="number"
      className="settings-input"
      value={text}
      min={setting.min}
      max={setting.max}
      step={setting.step}
      disabled={disabled}
      aria-describedby={describedBy}
      onChange={(event) => {
        const raw = event.target.value
        setDraft(raw)
        const next = numberWhileTyping(setting, raw)
        if (next !== null) onCommit(next)
      }}
      onBlur={(event) => {
        const next = numberOnLeaving(setting, event.target.value)
        setDraft(null)
        if (next !== null && next !== value) onCommit(next)
      }}
    />
  )
}

/* --------------------------------------------------------------- the row -- */

export interface OptionState {
  disabled?: boolean
  /** Appended to the option label — 'not installed', 'unverified'. */
  suffix?: string
}

export interface SettingControlProps {
  setting: Setting
  values: SettingValues
  save(patch: Record<string, unknown>): void
  disabled?: boolean
  /**
   * Per-option availability discovered at runtime, e.g. an agent that is not on
   * PATH. The schema declares what exists; only the app knows what works now.
   */
  optionState?(value: string): OptionState
  /** Rendered under the row — a preview, a Test button, an explanation. */
  children?: ReactNode
}

export function SettingControl({
  setting,
  values,
  save,
  disabled,
  optionState,
  children,
}: SettingControlProps) {
  const ids = useId()
  const labelId = `${ids}-label`
  const helpId = setting.help ? `${ids}-help` : undefined
  const controlId = `${ids}-control`
  const current = valueOf(values, setting)

  const control = ((): ReactNode => {
    switch (setting.kind) {
      case 'toggle':
        return (
          <Switch
            checked={current === true}
            disabled={disabled}
            labelledBy={labelId}
            describedBy={helpId}
            onChange={(next) => save({ [setting.id]: next })}
          />
        )

      case 'select':
        return (
          <span className="settings-select-wrap">
            <select
              id={controlId}
              className="settings-select"
              value={String(current)}
              disabled={disabled}
              aria-describedby={helpId}
              onChange={(event) => save({ [setting.id]: event.target.value })}
            >
              {setting.options.map((option) => {
                const state = optionState?.(option.value) ?? {}
                return (
                  <option key={option.value} value={option.value} disabled={state.disabled}>
                    {option.label}
                    {state.suffix ? ` — ${state.suffix}` : ''}
                  </option>
                )
              })}
            </select>
          </span>
        )

      case 'number':
        return (
          <span className="settings-number">
            <NumberField
              id={controlId}
              setting={setting}
              value={typeof current === 'number' ? current : setting.default}
              disabled={disabled}
              describedBy={helpId}
              onCommit={(next) => save({ [setting.id]: next })}
            />
            {setting.unit && <span className="settings-unit">{setting.unit}</span>}
          </span>
        )

      case 'text':
        return (
          <TextField
            id={controlId}
            value={String(current)}
            placeholder={setting.placeholder}
            disabled={disabled}
            describedBy={helpId}
            onCommit={(next) => save({ [setting.id]: next })}
          />
        )
    }
  })()

  const help =
    setting.kind === 'text' && setting.emptyMeans && String(current) === ''
      ? `${setting.help} ${setting.emptyMeans}`
      : setting.help

  return (
    <div className="settings-item">
      <Row
        label={setting.label}
        help={help}
        labelId={labelId}
        helpId={helpId}
        htmlFor={setting.kind === 'toggle' ? undefined : controlId}
        control={control}
      />
      {children && <div className="settings-item-extra">{children}</div>}
    </div>
  )
}

/* --------------------------------------------------------------- section -- */

export interface SettingListProps {
  section: SectionId
  values: SettingValues
  save(patch: Record<string, unknown>): void
  disabled?: boolean
  /** Trailing content per setting id. */
  extras?: Readonly<Record<string, ReactNode>>
  optionStates?: Readonly<Record<string, (value: string) => OptionState>>
  /** Ids to leave out, for a section that places one of its settings by hand. */
  omit?: readonly string[]
}

/** Every setting declared for a section, in table order. */
export function SettingList({
  section,
  values,
  save,
  disabled,
  extras,
  optionStates,
  omit,
}: SettingListProps) {
  return (
    <>
      {settingsIn(section)
        .filter((setting) => !omit?.includes(setting.id))
        .map((setting) => (
          <SettingControl
            key={setting.id}
            setting={setting}
            values={values}
            save={save}
            disabled={disabled}
            optionState={optionStates?.[setting.id]}
          >
            {extras?.[setting.id]}
          </SettingControl>
        ))}
    </>
  )
}
