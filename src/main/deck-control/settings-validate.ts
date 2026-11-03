/**
 * Does this settings patch describe a state the app can actually be in?
 *
 * ## Why this runs before the dialog and not inside the write
 *
 * `settings.write` is the copilot's only alter-tier tool, so it is the only one
 * whose whole flow is *ask a person, then act*. Validating after they answer
 * gets both halves wrong. They are shown a sentence, they read it, they weigh
 * it, they click Allow — and then the call fails, so they have consented to
 * something that did not happen and the model has been told "no" by a mechanism
 * that had already been told "yes". Worse, they have been trained: the next
 * dialog is one more thing to click through, because the last one turned out
 * not to mean anything. Confirmation fatigue is not caused by dangerous
 * prompts, it is caused by prompts that do not correspond to outcomes.
 *
 * So the order is: check the rules that no answer unlocks (`catalogue.ts`'s
 * protected prefixes), check that the values are ones the schema will accept
 * (here), take the snapshot, and only then draw the dialog. Everything a person
 * is asked about is then a thing that will happen if they say yes.
 *
 * ## Why the renderer's table, and not a copy of it
 *
 * `src/renderer/settings/settings-schema.ts` is where a setting's kind, default,
 * options and range are declared, and `settings-extra.ts` says at length why
 * this side of the app deliberately does not know any of that: it is a typed
 * key/value bag with hard limits, and *"duplicating the table here would be a
 * second copy of the truth and would drift within a release."*
 *
 * That argument is about duplication, and it is right. It is not an argument
 * against *reading* the one copy. The file is a pure data table plus pure
 * functions — its only two imports are `import type`, so nothing of the renderer
 * comes with it, no DOM, no React, no bundle — and importing it is what keeps
 * the number of copies at one. `tsconfig.node.json` therefore lists it (and the
 * one type-only file it names) explicitly, which is the smallest possible seam:
 * two files, both pure, both already compiled by the web project.
 *
 * The alternative was a hand-written list of allowed values in this directory,
 * which would have been wrong the first time somebody added an option to a
 * select. This module knows nothing except how to ask.
 *
 * ## What is checked, and what is deliberately not
 *
 * Checked: the key names a real setting; the value is the declared kind; a
 * `select` value is one of the declared options; a `number` is finite. Not
 * checked: whether the value is *sensible*. `coerce` clamps a number into range
 * rather than rejecting it — a font size of 400 was a real preference typed into
 * a build with a wider range, and the schema's author chose clamping on purpose
 * — and this module does not second-guess that. A clamp is recorded as an
 * adjustment and reported, so the confirmation names the value that will be
 * written rather than the one that was asked for.
 */

import { coerce, getSetting, SETTINGS, type SettingValue } from '../../renderer/settings/settings-schema'

/** One thing wrong with a patch, in a sentence a language model can act on. */
export interface SettingProblem {
  key: string
  problem: string
}

export interface PatchCheck {
  /** Empty when the patch may be written. */
  problems: SettingProblem[]
  /**
   * The values that will actually land, after the schema's own coercion.
   *
   * A key set to null in the `settings` scope is absent here: it removes the
   * key rather than writing a value. See `applyPatch` in `settings-extra.ts`.
   */
  effective: Record<string, SettingValue>
  /**
   * Keys whose value the schema changed on the way in — today only clamped
   * numbers. Named so the confirmation can say what will be written.
   */
  adjusted: string[]
}

function describe(id: string): string {
  const setting = getSetting(id)
  if (!setting) return id
  switch (setting.kind) {
    case 'toggle':
      return `${id} is a switch: true or false`
    case 'select':
      return `${id} accepts one of: ${setting.options.map((option) => option.value).join(', ')}`
    case 'number':
      return `${id} is a number between ${setting.min} and ${setting.max}`
    case 'text':
      return `${id} is text`
  }
}

/**
 * Check a patch against the schema.
 *
 * `scope` matters because the two stores are reached differently and only one
 * of them understands "put this back to its default":
 *
 *  - `settings` keys are the schema's own dotted ids and `null` removes one.
 *  - `preferences` keys are the four `Preferences` field names, each owned by a
 *    schema row through its `prefsKey`. `store.setPreferences` merges a partial
 *    without validating it — it has done since it was written — so a `null` here
 *    would be stored as `null` and read back as a theme that is not a theme.
 *    That is refused rather than translated, because "reset this preference" is
 *    a thing the tool does not offer and quietly inventing it is worse than
 *    saying no.
 */
export function checkSettingsValues(
  scope: 'settings' | 'preferences',
  patch: Record<string, unknown>,
): PatchCheck {
  const problems: SettingProblem[] = []
  const effective: Record<string, SettingValue> = {}
  const adjusted: string[] = []

  for (const [key, raw] of Object.entries(patch)) {
    const setting = scope === 'settings' ? getSetting(key) : SETTINGS.find((entry) => entry.prefsKey === key)

    if (!setting) {
      problems.push({
        key,
        problem:
          scope === 'settings'
            ? `there is no setting called ${key}. Call settings.read to see the ones that exist.`
            : `${key} is not a preference this app stores.`,
      })
      continue
    }

    if (raw === null || raw === undefined) {
      if (scope === 'settings') continue // Removing a key: back to its default.
      problems.push({
        key,
        problem: `${key} cannot be set to null. Send the value you want instead — ${describe(setting.id)}.`,
      })
      continue
    }

    /*
     * A prefs-backed id written into the settings scope is a write that changes
     * nothing, and it would report success.
     *
     * The renderer resolves the two stores as
     * `{ ...settingsJson, ...valuesFromPreferences(prefs) }` — preferences last,
     * so they win for every key they own. Writing `agents.defaultProvider` into
     * `settings.json` therefore puts a value on disk that no reader will ever
     * consult, and the copilot would tell the person it had changed their
     * default agent. Refusing and naming the other scope is the only answer that
     * ends with the setting actually changing.
     */
    if (scope === 'settings' && setting.store === 'prefs' && setting.prefsKey) {
      problems.push({
        key,
        problem:
          `${key} lives in preferences, not settings — writing it here would be ignored. ` +
          `Use scope "preferences" with the key ${setting.prefsKey}.`,
      })
      continue
    }

    const value = coerce(setting, raw)
    if (value === null) {
      problems.push({ key, problem: `${describe(setting.id)}; got ${JSON.stringify(raw)}` })
      continue
    }

    effective[key] = value
    if (value !== raw) adjusted.push(key)
  }

  return { problems, effective, adjusted }
}

/** One line naming everything wrong, for the error a tool call comes back with. */
export function problemSentence(problems: readonly SettingProblem[]): string {
  return problems.map((problem) => problem.problem).join(' ')
}
