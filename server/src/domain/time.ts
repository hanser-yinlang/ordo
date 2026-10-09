/**
 * 时间工具:契约 §2 规定「时间戳统一 epoch millis(Int64);日期用 YYYY-MM-DD;
 * 日期时间用 YYYY-MM-DDTHH:mm(本地时区,不带秒)」。
 *
 * 服务端不依赖宿主机时区,统一使用配置项 TZ_OFFSET_MINUTES(默认 +480,即 UTC+8)
 * 把「本地时间串」与 epoch millis 互相换算。
 */

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const DATETIME_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;

export interface LocalParts {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number;
  minute: number;
  /** 0=周日 */
  dow: number;
}

export function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

/** 把 epoch millis 换算到配置时区的「本地日历字段」 */
export function localParts(ms: number, offsetMinutes: number): LocalParts {
  const shifted = new Date(ms + offsetMinutes * 60_000);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
    hour: shifted.getUTCHours(),
    minute: shifted.getUTCMinutes(),
    dow: shifted.getUTCDay()
  };
}

export function isDateString(v: unknown): v is string {
  return typeof v === 'string' && DATE_RE.test(v);
}

export function isLocalDateTimeString(v: unknown): v is string {
  return typeof v === 'string' && DATETIME_RE.test(v);
}

/** 今天(配置时区)的 YYYY-MM-DD */
export function todayISO(ms: number, offsetMinutes: number): string {
  const p = localParts(ms, offsetMinutes);
  return `${p.year}-${pad2(p.month)}-${pad2(p.day)}`;
}

/** YYYY-MM-DD → epoch millis(该日本地 00:00) */
export function dateToEpoch(date: string, offsetMinutes: number): number {
  const m = DATE_RE.exec(date);
  if (!m) throw new Error(`非法日期:${date}`);
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) - offsetMinutes * 60_000;
}

/** "YYYY-MM-DDTHH:mm"(本地)→ epoch millis */
export function localDateTimeToEpoch(value: string, offsetMinutes: number): number | null {
  const m = DATETIME_RE.exec(value);
  if (!m) return null;
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5])) - offsetMinutes * 60_000;
}

/** epoch millis → "YYYY-MM-DDTHH:mm"(本地) */
export function epochToLocalDateTime(ms: number, offsetMinutes: number): string {
  const p = localParts(ms, offsetMinutes);
  return `${p.year}-${pad2(p.month)}-${pad2(p.day)}T${pad2(p.hour)}:${pad2(p.minute)}`;
}

/** 日期加减天数(纯日期运算,不受时区影响) */
export function addDaysISO(date: string, days: number): string {
  const m = DATE_RE.exec(date);
  if (!m) throw new Error(`非法日期:${date}`);
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  d.setUTCDate(d.getUTCDate() + days);
  return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}`;
}

/** 月份加减(日期溢出取当月最后一天),契约 §6 */
export function addMonthsISO(date: string, months: number): string {
  const m = DATE_RE.exec(date);
  if (!m) throw new Error(`非法日期:${date}`);
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const target = new Date(Date.UTC(y, mo - 1 + months, 1));
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  return `${target.getUTCFullYear()}-${pad2(target.getUTCMonth() + 1)}-${pad2(Math.min(d, lastDay))}`;
}

export function addYearsISO(date: string, years: number): string {
  return addMonthsISO(date, years * 12);
}

/** 两个 YYYY-MM-DD 之间的天数差(a - b) */
export function diffDays(a: string, b: string): number {
  const ma = DATE_RE.exec(a);
  const mb = DATE_RE.exec(b);
  if (!ma || !mb) throw new Error('非法日期');
  const ta = Date.UTC(Number(ma[1]), Number(ma[2]) - 1, Number(ma[3]));
  const tb = Date.UTC(Number(mb[1]), Number(mb[2]) - 1, Number(mb[3]));
  return Math.round((ta - tb) / 86_400_000);
}

/** 比较两个 YYYY-MM-DD 的先后;两者都必须是合法日期串 */
export function compareDate(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
