import { useId, type FormEvent } from 'react'
import { BRAND } from '../../shared/brand'
// Relative, not '@shared/…': vitest runs without the electron-vite alias, so a
// *value* import through it resolves in the app and throws in a test. Same note
// as `ProviderPicker.tsx`, for the same reason.
import {
  MAX_ARGS,
  MAX_DESCRIPTION,
  MAX_LABEL,
  describeArgs,
  splitArgs,
  type CustomAgentDraft,
  type CustomAgentProblems,
} from '../../shared/custom-agents'
import './AddAgentForm.css'

/**
 * The plus button's other half: naming an agent this build has never heard of.
 *
 * > *"There should be a plus button to add, with the big list of type of AI
 * > agents to connect — not only Codex, not only Claude Code. There are so many,
 * > Grok agents… They should be able to connect a huge number of type of
 * > agents."*
 *
 * The gallery answers the first half of that — the agents that were installed
 * and launched here before they were written down. This answers the rest, and it
 * has to exist for a reason no longer list can remove: the interesting agent is
 * frequently the one released last week, or the wrapper script in somebody's own
 * `bin` directory, and neither will ever be in a table shipped inside a build.
 *
 * ## Why the form is this short
 *
 * Four fields and a name, because four fields is everything the app can honestly
 * do with an agent nobody here has measured: run this command, with these
 * arguments, in the project's folder, in a real pty. `shared/custom-agents.ts`
 * argues that floor at length. Anything else this form could ask for — where its
 * transcripts land, which variable moves its login, what its resume flag is
 * called — would be asking the person to assert something the app would then act
 * on, and a wrong answer to any of them is a session that fails somewhere the
 * person cannot connect back to a field they filled in.
 *
 * Resume is the one that looks most like a fifth ordinary field and is not. A
 * resume flag that turns out to error in a folder with no history kills the tab
 * with no explanation, so the field is here, empty by default, and empty means
 * the agent simply does not offer resume. The catalogue takes the same line
 * about Gemini for the same reason.
 *
 * ## What it shows back
 *
 * The parse, under the two argument fields. `--system-prompt "answer in French"`
 * is one argument and splitting it on spaces would send two, so the app cannot
 * treat the box as a string it passes on — it has to split it, and the person
 * has to be able to see that it split it the way they meant. `splitArgs` is the
 * one splitter and it runs on both sides of the bridge, so what is previewed
 * here is what gets stored.
 */

export interface Props {
  /** The `<form>` id, so the dialog's footer button can submit from outside it. */
  formId: string
  draft: CustomAgentDraft
  /** Per-field complaints, drawn under the field they belong to. */
  problems: CustomAgentProblems
  /** True while the main process is resolving the command. */
  busy: boolean
  onChange(patch: Partial<CustomAgentDraft>): void
  onSubmit(): void
}

/** One labelled field with its own error line. */
function Field({
  id,
  label,
  hint,
  problem,
  children,
}: {
  id: string
  label: string
  hint?: string
  problem?: string
  children: React.ReactNode
}) {
  return (
    <div className="aa-field" data-invalid={problem === undefined ? undefined : 'true'}>
      <label className="aa-label" htmlFor={id}>
        {label}
      </label>
      {children}
      {/*
        The complaint replaces the hint rather than joining it. Two lines under
        one field — one explaining what the field is for and one saying what is
        wrong with it — is the shape that gets read as a single sentence and
        misunderstood; the hint has done its job by the time there is an error.
      */}
      {problem === undefined ? (
        hint === undefined ? null : (
          <p className="aa-hint">{hint}</p>
        )
      ) : (
        <p className="aa-problem" role="alert">
          {problem}
        </p>
      )}
    </div>
  )
}

export function AddAgentForm({ formId, draft, problems, busy, onChange, onSubmit }: Props) {
  const base = useId()
  const submit = (event: FormEvent): void => {
    event.preventDefault()
    if (!busy) onSubmit()
  }

  const args = splitArgs(draft.args)
  const resumeArgs = splitArgs(draft.resumeArgs)

  return (
    <form id={formId} className="aa" onSubmit={submit}>
      <Field
        id={`${base}-label`}
        label="Name"
        hint="What the picker and the tab will call it."
        problem={problems.label}
      >
        <input
          id={`${base}-label`}
          className="aa-input"
          value={draft.label}
          maxLength={MAX_LABEL}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => onChange({ label: event.target.value })}
        />
      </Field>

      <Field
        id={`${base}-command`}
        label="Command"
        hint="A name on your PATH, or the full path to the program. Just the program — arguments go below."
        problem={problems.command}
      >
        <input
          id={`${base}-command`}
          className="aa-input aa-mono"
          value={draft.command}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => onChange({ command: event.target.value })}
        />
      </Field>

      <Field
        id={`${base}-args`}
        label="Arguments"
        /*
         * Two different sentences rather than one with the parse tacked on. The
         * hint used to read "Optional. Quoted arguments stay together. no
         * arguments." — `describeArgs` answers "no arguments" for an empty line,
         * which is a fine answer to "what did you parse" and reads as a fragment
         * when it is glued to the end of an instruction. An empty field needs
         * the instruction; a filled one needs the parse.
         */
        hint={
          args.length === 0
            ? 'Optional. A quoted argument stays in one piece.'
            : `Sends: ${describeArgs(args)}`
        }
        problem={problems.args}
      >
        <input
          id={`${base}-args`}
          className="aa-input aa-mono"
          value={draft.args}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => onChange({ args: event.target.value })}
        />
      </Field>

      <Field
        id={`${base}-resume`}
        label="Arguments to continue the last session"
        hint={
          resumeArgs.length === 0
            ? 'Optional, and empty is the safe answer — leave it and this agent simply does not offer resume.'
            : `Continues with: ${describeArgs(resumeArgs)}`
        }
        problem={problems.resumeArgs}
      >
        <input
          id={`${base}-resume`}
          className="aa-input aa-mono"
          value={draft.resumeArgs}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => onChange({ resumeArgs: event.target.value })}
        />
      </Field>

      <Field
        id={`${base}-description`}
        label="Description"
        hint="Optional. One line under the name in this list."
        problem={problems.description}
      >
        <input
          id={`${base}-description`}
          className="aa-input"
          value={draft.description}
          maxLength={MAX_DESCRIPTION}
          autoComplete="off"
          onChange={(event) => onChange({ description: event.target.value })}
        />
      </Field>

      {/*
        Said once, at the bottom, rather than as a caveat on every field.

        It is the one thing about an added agent that is different in kind from
        the agents in the gallery, and a person who reads it before pressing Add
        will not later read a missing account row as a bug. The sentence is the
        same promise `customEntry` makes in code: the command runs, and nothing
        above that has been measured.
      */}
      <p className="aa-note">
        {BRAND.name} checks the command exists on this machine when you add it, and then runs it in a
        terminal in the project folder. It has not measured how this agent stores a login or where it
        writes a transcript, so accounts, hooks and token tracking stay off for it. Up to {MAX_ARGS}{' '}
        arguments.
      </p>
    </form>
  )
}
