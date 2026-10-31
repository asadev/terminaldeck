// Copied from the reference CRM.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Plus } from "lucide-react";
import { cn } from "./lib/utils";

/**
 * The frame every optional section shares (Subtasks, Checklist, Dependencies,
 * Attachments): a small title row with an optional counter on the right, and
 * the rows beneath. One frame, so the four of them line up.
 */
export function Section({
  title,
  aside,
  children,
  testId,
}: {
  title: string;
  /** The counter or control on the right of the title — "0 of 2". */
  aside?: ReactNode;
  children: ReactNode;
  testId?: string;
}) {
  return (
    <section data-testid={testId} className="rounded-lg border border-slate-200">
      <header className="flex items-center gap-2 border-b border-slate-100 px-3 py-1.5">
        <h3 className="text-xs font-semibold text-slate-700">{title}</h3>
        {aside && <span className="ml-auto text-[11px] tabular-nums text-slate-500">{aside}</span>}
      </header>
      <div className="px-2 py-1.5">{children}</div>
    </section>
  );
}

/**
 * "+ Add subtask" that becomes a text box when pressed. Enter adds, Escape
 * puts the "+" back. After an add the box STAYS OPEN and empty, because the
 * common case is typing three items in a row.
 *
 * 🔴 ENTER MUST NOT REACH THE FORM. This lives inside the New-item `<form>`,
 * whose submit button is "Add task" and whose submit handler writes a row to
 * the production database. A bare `<input>` inside a form submits it on Enter.
 * Every key handler here calls `preventDefault()` first.
 */
export function InlineAdd({
  label,
  placeholder,
  onAdd,
  autoOpen = false,
}: {
  label: string;
  placeholder: string;
  onAdd: (title: string) => void;
  /** Open with the box showing — for a section that was just revealed and is empty. */
  autoOpen?: boolean;
}) {
  const [editing, setEditing] = useState(autoOpen);
  const [text, setText] = useState("");
  const ref = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (editing) ref.current?.focus();
  }, [editing]);

  function commit() {
    const t = text.trim();
    if (!t) return;
    onAdd(t);
    setText("");
  }

  if (!editing) {
    return (
      <button
        type="button"
        onClick={() => setEditing(true)}
        className="inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs text-slate-500 hover:bg-slate-100 hover:text-slate-800"
      >
        <Plus className="h-3.5 w-3.5" aria-hidden />
        {label}
      </button>
    );
  }

  return (
    <div className="flex items-center gap-1.5 px-1 py-0.5">
      <input
        ref={ref}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            commit();
          } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            setText("");
            setEditing(false);
          }
        }}
        onBlur={() => {
          // Leaving an empty box closes it; leaving text keeps it, so a click
          // on the assign button of a neighbouring row does not eat a
          // half-typed title.
          if (!text.trim()) setEditing(false);
        }}
        placeholder={placeholder}
        aria-label={label}
        maxLength={300}
        className="h-7 flex-1 rounded-md border border-slate-200 bg-white px-2 text-sm placeholder:text-slate-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
      />
      <button
        type="button"
        onClick={commit}
        disabled={!text.trim()}
        className={cn(
          "h-7 rounded-md px-2 text-xs font-medium",
          text.trim() ? "bg-slate-900 text-white hover:bg-slate-800" : "bg-slate-100 text-slate-400",
        )}
      >
        Add
      </button>
    </div>
  );
}

/** The tick box every subtask and checklist row starts with. */
export function RowTick({
  done,
  onChange,
  label,
}: {
  done: boolean;
  onChange: (next: boolean) => void;
  label: string;
}) {
  return (
    <input
      type="checkbox"
      checked={done}
      onChange={(e) => onChange(e.target.checked)}
      aria-label={label}
      className="h-3.5 w-3.5 shrink-0 cursor-pointer rounded border-slate-300 accent-blue-600"
    />
  );
}
