// Copied from the reference CRM (its list view's due-date checks, the two the dates cell reads).
import { isYmd } from "../../../shared/crm/local-time";

export function isOverdueYmd(ymd: string, today: string): boolean {
  return isYmd(ymd) && ymd < today;
}

/**
 * Due TODAY at a time of day that has come. `nowHm` is the mounted clock
 * ("HH:MM", this computer's time) — null (the first render) is never
 * "passed": the time decides only after mount.
 */
export function isDueTimePassed(dueDate: string, dueTime: string | null | undefined, today: string, nowHm: string | null): boolean {
  return !!nowHm && !!dueTime && dueDate === today && dueTime <= nowHm;
}
