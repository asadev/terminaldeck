// Copied from the reference CRM.
import { useEffect, useState } from "react";

/**
 * A time that depends on NOW ("7 mins", "2 hours ago") — rendered only after
 * mount. The server's HTML and the browser's first render both show the local
 * stamp (identical on both, whatever zone each runs in); the relative words
 * replace it once the page is live, and refresh every minute. Without this,
 * the server's "7 mins" is the browser's "8 mins" and React throws away the
 * page's hydration (#418, 2026-09-15). lib/tasks/local-time.ts has the rule.
 */
export function RelativeTime({
  iso,
  format,
  stamp,
  className,
  title,
}: {
  iso: string;
  /** The words, given the current instant. */
  format: (iso: string, now: Date) => string;
  /** What shows before mount (and on hover): no "now" in it. */
  stamp: (iso: string) => string;
  className?: string;
  /** The hover title; defaults to the stamp. */
  title?: string;
}) {
  const [now, setNow] = useState<Date | null>(null);
  useEffect(() => {
    setNow(new Date());
    const t = window.setInterval(() => setNow(new Date()), 60_000);
    return () => window.clearInterval(t);
  }, []);
  return (
    <time dateTime={iso} title={title ?? stamp(iso)} className={className}>
      {now ? format(iso, now) : stamp(iso)}
    </time>
  );
}
