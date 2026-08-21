/**
 * The segmented switch: a short run of buttons of which exactly one is on.
 *
 * ## Why it exists
 *
 * Asad, on the round this file was written in:
 *
 *   > *"build a proper version for scrapping and server control with switching
 *   > pill just like in coding ai page in settings but build proper settings
 *   > inside too exactly like local machine, exactly means exactly and all other
 *   > applicable places too."*
 *
 * "Just like in coding ai page" names a control that, on the day he said it,
 * existed as **four** copies of the same eleven lines of JSX:
 *
 *  - `ScopeSwitch` in `settings/sections/AgentsSection.tsx` — the one he means;
 *  - `DeviceApproval.tsx`, `DeviceLogins.tsx` and `DeviceSessions.tsx`, each
 *    hand-rolling `<div className="settings-scope">` with its own pair of
 *    buttons for All / Selected.
 *
 * Four copies of a control is not a style problem, it is a drift problem, and it
 * had already drifted before anybody looked: `DeviceApproval` wrote
 * `className="settings-scope da-scope"` and **no stylesheet in this repo defines
 * `.da-scope`**. Its two neighbours define `.ds-scope` and use it to cancel the
 * bottom margin `.settings-scope` carries for its use at the top of a pane; the
 * third named a class that does not exist, so its pill row sat in a flex column
 * with a `--sp-2` gap and carried a `--sp-6` margin underneath it — three times
 * the space of every other gap on that step, for no reason anybody chose.
 *
 * So this is that control, once. The markup is `ScopeSwitch`'s, unchanged, down
 * to `data-on` for the stylesheet and `aria-pressed` for the reader — both
 * derived from one prop, so a button can never look chosen and read as unchosen.
 *
 * ## The class is `.settings-scope`, and it is not settings-only
 *
 * The rules live in `settings/SettingsWindow.css` because that is where the
 * control was born. They are loaded app-wide regardless: there is one renderer
 * entry (`electron.vite.config.ts`), `App.tsx` imports `SettingsWindow`
 * statically, and its `import './SettingsWindow.css'` therefore lands in the one
 * bundle. That is why `RemoteSection` — a **panel**, not a settings pane — has
 * been able to use the class since it was written. Renaming the class would be a
 * cosmetic change to every one of those call sites, so it keeps its name.
 *
 * ## `aria-pressed`, not a tablist and not a radiogroup
 *
 * Inherited from `ScopeSwitch` and worth restating, because both of the tidier
 * roles promise something this app does not implement. `role="tablist"` promises
 * a tab panel relationship; `role="radiogroup"` promises arrow-key navigation.
 * What is actually here is a run of buttons of which one is on, which is what a
 * segmented control is everywhere else in this app, and `role="group"` with a
 * label is the honest description of it.
 */

/** One button of the run. */
export interface Segment<Id extends string> {
  id: Id
  label: string
  /**
   * The hover sentence, where the label alone does not carry it.
   *
   * Optional because most runs are two or three plain words. The MCP page's
   * machine run is the case that needs it — a machine's own configuration is
   * resolved for one session's folder over there, and saying which is the
   * difference between a list and a list you can check.
   */
  title?: string
}

interface Props<Id extends string> {
  options: readonly Segment<Id>[]
  /** The one that is on. A value matching no option leaves the run with none on. */
  value: Id
  onChange(next: Id): void
  /** What this run is asking, for somebody reading with a screen reader. */
  label: string
  /**
   * Sitting inside a row rather than at the top of a pane.
   *
   * `.settings-scope` carries a bottom margin sized for the gap between the
   * switch at the top of the Coding AI pane and the first group under it. In a
   * flex row beside a device name, or inside a step whose own gap is already
   * chosen, that margin is somebody else's spacing. `data-inline` cancels it in
   * one rule instead of one bespoke class per caller — which is the arrangement
   * that produced `.da-scope`, a class name with nothing behind it.
   */
  inline?: boolean
  /** Every button at once, while a write to the far end is in flight. */
  disabled?: boolean
  /** One more class for a caller that has geometry of its own to add. */
  className?: string
}

export function SegmentedSwitch<Id extends string>({
  options,
  value,
  onChange,
  label,
  inline = false,
  disabled = false,
  className,
}: Props<Id>) {
  return (
    <div
      className={className === undefined ? 'settings-scope' : `settings-scope ${className}`}
      data-inline={inline ? '' : undefined}
      role="group"
      aria-label={label}
    >
      {options.map((option) => (
        <button
          key={option.id}
          type="button"
          data-on={value === option.id ? '' : undefined}
          aria-pressed={value === option.id}
          title={option.title}
          disabled={disabled || undefined}
          onClick={() => onChange(option.id)}
        >
          {option.label}
        </button>
      ))}
    </div>
  )
}
