// Copied from the reference CRM.
import { useEffect, useRef, useState } from "react";
import type { TagAreaKey, TagHit } from "../../shared/crm/tag-areas";
import { searchTagsLocally } from "./local-actions";

/**
 * One debounced, abortable search against `/api/tags/search` — the cross-CRM
 * lookup the Related-to chips already use. Shared by the people search (area
 * `person`), the dependency picker (area `task`) and the attachment linker
 * (area `file`), so the three of them cannot drift on the rules below.
 *
 *  · NOTHING IS FETCHED UNDER TWO CHARACTERS. Opening a picker costs no query.
 *  · EVERY KEYSTROKE ABORTS THE ONE BEFORE IT, so a slow response cannot land
 *    after a newer query and overwrite it with stale rows.
 *  · A RESULT IS KEYED BY THE QUERY THAT MADE IT. Rows for "hh" are never
 *    shown under "hhh" while the new fetch is in flight — the list says
 *    "Searching…" instead. That is also what keeps this hook free of
 *    setState-in-effect: the effect only ever writes from inside the fetch
 *    callback, and everything else is derived on render.
 *  · A FAILURE IS SAID OUT LOUD. A search that quietly shows nothing is
 *    indistinguishable from "there is nothing there" — the route itself
 *    learned this the hard way (see its `rowsOf`).
 */
export const MIN_TAG_QUERY = 2;

type Settled = { key: string; hits: TagHit[] | null; failed: string | null };

export function useTagSearch(area: TagAreaKey, query: string) {
  const q = query.trim();
  const active = q.length >= MIN_TAG_QUERY;
  const key = `${area}:${q}`;
  const [settled, setSettled] = useState<Settled | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!active) {
      abortRef.current?.abort();
      return;
    }
    const t = setTimeout(async () => {
      abortRef.current?.abort();
      const ac = new AbortController();
      abortRef.current = ac;
      // Local: the search runs in the main process over your tasks, people and files (the CRM asks its web route).
      const res = await searchTagsLocally(area, q);
      if (ac.signal.aborted) return;
      if (res.ok) setSettled({ key, hits: res.hits, failed: null });
      else setSettled({ key, hits: null, failed: "Could not search just now. Try again." });
    }, 250);
    return () => clearTimeout(t);
  }, [q, area, active, key]);

  const current = active && settled?.key === key ? settled : null;
  return {
    hits: current?.hits ?? null,
    failed: current?.failed ?? null,
    busy: active && current === null,
    tooShort: !active,
  };
}
