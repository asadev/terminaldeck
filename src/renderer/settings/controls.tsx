import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { HoverNote } from '../components/HoverNote'
import { useFeatures } from '../features/FeaturesProvider'
import {
  settingsIn,
  valueOf,
  type LiveSectionId,
  type NumberSetting,
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

/*
 * The ⓘ dot used to be three things declared here — `Info`, `MoreBody` and
 * `useMore` — and all three are gone, replaced by {@link HoverNote}.
 *
 * ## One window, one behaviour
 *
 * The instruction the whole copy pass came from:
 *
 *   > "we don't have to give this big descriptions. Let's give only one liner or
 *   > two liner descriptions and one eye buttons next to them so they can click
 *   > or hover over there and they can read the full description of the feature,
 *   > whatever you want to give us more information about that, but not more
 *   > than one or two lines because it's being too big for them."
 *
 * and then, about the same dot on the Copilot pane:
 *
 *   > "the ⓘ dot shows its detail **on hover, as a popup** — not by expanding
 *   > the pane downward."
 *
 * The second was applied to Copilot and nowhere else, which left one Settings
 * window with two dots that look identical and behave differently: a popup that
 * costs nothing below it in Copilot, and a disclosure that pushes every row down
 * the page in General, Appearance, Notifications, Tools, Browser, Advanced,
 * About and Remote. A reader who learns what the dot does on one pane learns the
 * wrong thing about the other eight, and the one they learn on is whichever they
 * happened to open first.
 *
 * The popup is the better of the two and it is now the only one. `HoverNote`
 * carries the reasoning; the short version is that a disclosure is right for a
 * row and wrong for a pane with six of them, because reading the second
 * explanation moves the third somewhere else. It is reachable by hover, focus,
 * click and screen reader, so nothing that could be read before cannot be read
 * now, and `settings-one-info.test.tsx` fails the moment a pane grows downward
 * again.
 *
 * Nothing about the *copy* changed: a row still declares `more`, and the string
 * is still the rest of the same explanation.
 */

export function Row({
  label,
  help,
  more,
  control,
  labelId,
  helpId,
  htmlFor,
}: {
  label: string
  help?: string
  /** The rest of the explanation, put behind an ⓘ beside the label. */
  more?: string
  control: ReactNode
  labelId?: string
  helpId?: string
  /** Set when the control is a single labellable element. */
  htmlFor?: string
}) {
  return (
    <div className="settings-row">
      <div className="settings-row-text">
        <span className="settings-label-line">
          {htmlFor ? (
            <label className="settings-label" id={labelId} htmlFor={htmlFor}>
              {label}
            </label>
          ) : (
            <span className="settings-label" id={labelId}>
              {label}
            </span>
          )}
          {more && <HoverNote label={label}>{more}</HoverNote>}
        </span>
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

/**
 * A paragraph that has to be read, with a line to hang it on.
 *
 * Three sections were reported as walls of text — Power, Remote and Agents —
 * and the reason is the same in all three: the standing explanations had no
 * entry point. A screen-wide paragraph with nothing above it is a paragraph the
 * eye cannot skip, cannot come back to, and cannot tell apart from the
 * paragraph under it. Two of them were also wearing `Notice tone="info"`, which
 * is the *alert* treatment: a tinted block with a rule down its side, used for
 * something that is permanently true. A section of those reads as a page of
 * warnings.
 *
 * The treatment is the brief's, and it is the one the app already uses inside a
 * row (`.settings-label` over `.settings-help`) — brighter title, dimmer body,
 * space around the block:
 *
 *   Title    the brightest ink, and short enough to scan in one go
 *   Body     a step dimmer than body copy, held to a readable measure
 *
 * Not a control and never interactive itself. An action that belongs to the
 * explanation goes inside it as an inline button, exactly as it did in the
 * notices this replaces, so nothing that could be clicked before has moved.
 */
export function Explain({
  title,
  more,
  children,
}: {
  title?: string
  /**
   * The paragraph this block used to be, moved behind an ⓘ beside its title.
   *
   * Every standing explanation in this window was two or three sentences of
   * true, well-meant prose, and the pane read as a document. Cutting them to
   * one line each is only honest if the rest is still reachable, which is what
   * this is for — the same trade a setting row makes with `help` and `more`.
   */
  more?: string
  children: ReactNode
}) {
  return (
    <div className="settings-explain">
      {title && (
        <h5 className="settings-explain-title">
          <span className="settings-label-line">
            {title}
            {more && <HoverNote label={title}>{more}</HoverNote>}
          </span>
        </h5>
      )}
      <p className="settings-explain-body">{children}</p>
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
  title,
  tone = 'default',
  type = 'button',
}: {
  children: ReactNode
  /** Omitted for a submit button, whose form owns the action. */
  onClick?(): void
  disabled?: boolean
  /**
   * Why this button is greyed, or what it will do — through the app's own
   * tooltip layer, which is delegated off `title`. A disabled control with no
   * stated reason is half of a dead control: the app knows why and the person
   * looking at it does not.
   */
  title?: string
  tone?: 'default' | 'primary' | 'danger'
  type?: 'button' | 'submit'
}) {
  return (
    <button
      type={type === 'submit' ? 'submit' : 'button'}
      className="settings-btn"
      data-tone={tone}
      disabled={disabled}
      title={title}
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
  /**
   * Take the option off the list entirely.
   *
   * Stronger than `disabled`, and it exists because *"if we don't have
   * installed Codex, it should not be on the page at all"* is a rule about a
   * whole pane rather than about one list. A greyed-out option is still a line
   * to read and dismiss, and the argument that a missing row is a worse bug
   * report than a greyed one has already been heard and lost once — the agents
   * list acted on it and the pickers beside it did not, so the same machine
   * showed Codex as absent in one control and present-but-dead in two others.
   *
   * The select falls back to drawing a plain value when hiding leaves one
   * option, which is the same rule a one-option picker already lives by.
   */
  hidden?: boolean
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
  /**
   * Replaces the schema's `help` line while some other setting makes it untrue.
   *
   * The same argument as `optionState`, one level up: the schema declares what a
   * row means in general, and only the app knows whether that is the case right
   * now. The live example is Notifications — "Which sound a finished session
   * plays" is a false sentence while the finish sound is switched off, and the
   * row was sitting there stating it under an off switch. Overriding the line is
   * the honest fix, because the control itself is not dead: Test previews it
   * either way, and `finish.test.ts` pins that Test stays pressable.
   *
   * Not a schema field, deliberately. A conditional string in the table would be
   * a `renderCustomThing` by another name, and the condition belongs to the
   * section that can see both settings.
   */
  help?: string
  /** Rendered under the row — a preview, a Test button, an explanation. */
  children?: ReactNode
}

export function SettingControl({
  setting,
  values,
  save,
  disabled,
  optionState,
  help: helpOverride,
  children,
}: SettingControlProps) {
  const ids = useId()
  const labelId = `${ids}-label`
  const helpId = setting.help ? `${ids}-help` : undefined
  const controlId = `${ids}-control`
  const current = valueOf(values, setting)

  /*
   * Does the row have something a `<label for>` may legally point at?
   *
   * A switch labels itself, and a one-option select is drawn as a plain value —
   * a `<span>`. `htmlFor` naming either is invalid HTML and, worse, gives a
   * screen reader a label attached to nothing, which is a quieter version of
   * the same "control over nothing" this window is being cleared of.
   */
  const visibleOptions =
    setting.kind === 'select'
      ? setting.options.filter((option) => optionState?.(option.value)?.hidden !== true)
      : []
  const labellable =
    setting.kind !== 'toggle' && !(setting.kind === 'select' && visibleOptions.length === 1)

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

      case 'select': {
        /*
         * A picker with one option is not a picker, so it is not drawn as one.
         *
         * `general.language` is the live case: an enabled dropdown holding
         * exactly "English", beside a help line that already says English is the
         * only one there is. Opening it changes nothing, choosing the one entry
         * changes nothing, and a control that looks pressable and can never do
         * anything is the fault this window is being swept for. The row still
         * earns its place — the question "can I have this in my language" wants
         * an answer rather than a missing row — so what is drawn is the answer,
         * as a value.
         *
         * A rule here rather than a special case in `GeneralSection`, because
         * this has to reverse itself: the day a second language is translated
         * the schema gains an option and the control comes back, with nobody
         * having to remember that a section file was hiding it.
         */
        /*
         * Options the app has decided are not on this machine, gone rather than
         * greyed. See `OptionState.hidden` — and note this runs *before* the
         * one-option rule below, so a machine with a single agent installed
         * draws the answer instead of a dropdown that cannot be changed.
         */
        const options = visibleOptions
        const only = options.length === 1 ? options[0] : null
        if (only) {
          return (
            <span className="settings-value" id={controlId}>
              {only.label}
            </span>
          )
        }
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
              {options.map((option) => {
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
      }

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

  // An override wins outright rather than being appended: it exists because the
  // schema's sentence is wrong in this state, and printing both would put the
  // contradiction back on one line.
  const help =
    helpOverride ??
    (setting.kind === 'text' && setting.emptyMeans && String(current) === ''
      ? `${setting.help} ${setting.emptyMeans}`
      : setting.help)

  return (
    <div className="settings-item">
      <Row
        label={setting.label}
        help={help}
        // Straight from the schema, so the long half of a description is
        // declared in the same place as the short half and cannot drift from
        // it — and so no section file has to remember to offer one.
        more={setting.more}
        labelId={labelId}
        helpId={helpId}
        htmlFor={labellable ? controlId : undefined}
        control={control}
      />
      {children && <div className="settings-item-extra">{children}</div>}
    </div>
  )
}

/* --------------------------------------------------------------- section -- */

export interface SettingListProps {
  section: LiveSectionId
  values: SettingValues
  save(patch: Record<string, unknown>): void
  disabled?: boolean
  /** Trailing content per setting id. */
  extras?: Readonly<Record<string, ReactNode>>
  optionStates?: Readonly<Record<string, (value: string) => OptionState>>
  /** Replacement help lines by setting id. See `SettingControlProps.help`. */
  helpFor?: Readonly<Record<string, string>>
  /** Ids to leave out, for a section that places one of its settings by hand. */
  omit?: readonly string[]
}

/**
 * Every setting declared for a section, in table order — minus any whose
 * feature is not installed.
 *
 * The feature check is here rather than in each section for the same reason the
 * rows are generated at all: a section lists what it shows and nothing else, so
 * a setting changing hands cannot leave one pane still drawing it. Insight
 * alerts is the live case — the switch belongs to Alerts and sits in General, so
 * uninstalling Alerts has to take a row out of a section that knows nothing
 * about it.
 */
export function SettingList({
  section,
  values,
  save,
  disabled,
  extras,
  optionStates,
  helpFor,
  omit,
}: SettingListProps) {
  const features = useFeatures()
  return (
    <>
      {settingsIn(section)
        .filter((setting) => !omit?.includes(setting.id) && features.settingOn(setting.id))
        .map((setting) => (
          <SettingControl
            key={setting.id}
            setting={setting}
            values={values}
            save={save}
            disabled={disabled}
            optionState={optionStates?.[setting.id]}
            help={helpFor?.[setting.id]}
          >
            {extras?.[setting.id]}
          </SettingControl>
        ))}
    </>
  )
}

/**
 * Shut the `<details>` a menu item was pressed in.
 *
 * The settings window builds its two menus — **Add agent** and a row's ⋯ — out
 * of `<details>` rather than a portal, because this window is asserted through
 * `renderToStaticMarkup` and a portalled menu has no markup a test can read.
 * The cost is that a `<details>` has no idea a button inside it did something:
 * pressing **Remove** left the menu standing open on top of the confirmation it
 * had just raised, and pressing **Claude Code** in Add agent left it open
 * behind the popup.
 *
 * A DOM poke rather than state, deliberately. The alternative is one `open`
 * flag per menu, controlled, plus the click-outside handling a native
 * disclosure already does for free — which is how a `<details>` turns back into
 * the portal it was chosen over.
 */
export function closeMenu(event: { currentTarget: HTMLElement }): void {
  event.currentTarget.closest('details')?.removeAttribute('open')
}
