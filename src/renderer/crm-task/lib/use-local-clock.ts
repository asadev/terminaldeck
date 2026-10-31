// Copied from the reference CRM.
import { useEffect, useState } from "react";
import { localNowHm } from "../../../shared/crm/local-time";

/**
 * THE LIST'S CLOCK — local "HH:MM", MOUNTED ONLY (inc8 re-panel #11 / #12). null on the server and on the
 * browser's first render, so the server's HTML and the first client render never differ by the minute (React
 * #418); then the time, kept fresh at each minute while the tab is open. A due TIME colours a row (or the task page's
 * Dates field) red and moves it into Overdue only from here — never during the server render.
 */
export function useLocalClockHm(): string | null {
  const [hm, setHm] = useState<string | null>(null);
  useEffect(() => {
    const tick = () => setHm((cur) => {
      const now = localNowHm();
      return cur === now ? cur : now;
    });
    let timer: number | undefined;
    // At once after mount (in a timer, not the effect body), then on the next minute's turn, and every one after.
    const arm = (ms: number) => {
      timer = window.setTimeout(() => {
        tick();
        arm(60_000 - (Date.now() % 60_000) + 50);
      }, ms);
    };
    arm(0);
    const onFocus = () => tick();
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onFocus);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onFocus);
    };
  }, []);
  return hm;
}
