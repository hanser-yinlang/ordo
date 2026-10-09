/**
 * Ordo · 日期时间工具(纯函数)
 * 契约来源:docs/03-数据模型与同步协议.md §2(时间格式)、§4(日期比较)、§6(月末溢出取当月最后一天)
 *
 * 约定:
 *  - 日期       : "YYYY-MM-DD"(本地时区)
 *  - 日期时间   : "YYYY-MM-DDTHH:mm"(本地时区,不带秒)
 *  - 时间戳     : epoch millis(Int64 / ArkTS number)
 * 所有函数均按**本地时区**计算,不做 UTC 换算(与契约 §2 一致)。
 */

const CN_WEEKDAYS: string[] = ['日', '一', '二', '三', '四', '五', '六'];

export function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

/** Date → "YYYY-MM-DD" */
export function dateToISO(d: Date): string {
  return d.getFullYear().toString() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

/** "YYYY-MM-DD" → Date(本地 00:00);非法输入返回今天 */
export function isoToDate(iso: string): Date {
  const parts: string[] = iso.split('-');
  if (parts.length !== 3) {
    const now: Date = new Date();
    return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  }
  const y: number = parseInt(parts[0], 10);
  const m: number = parseInt(parts[1], 10);
  const d: number = parseInt(parts[2], 10);
  return new Date(y, m - 1, d);
}

/** 今天的 "YYYY-MM-DD" */
export function todayISO(): string {
  return dateToISO(new Date());
}

/** 当前本地日期时间 "YYYY-MM-DDTHH:mm" */
export function nowLocalDateTime(): string {
  const d: Date = new Date();
  return dateToISO(d) + 'T' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/** "YYYY-MM-DDTHH:mm" → 日期部分;非法输入返回今天 */
export function datePartOf(dateTime: string): string {
  if (dateTime.length >= 10) {
    return dateTime.substring(0, 10);
  }
  return todayISO();
}

/** "YYYY-MM-DDTHH:mm" → "HH:mm" */
export function timePartOf(dateTime: string): string {
  if (dateTime.length >= 16) {
    return dateTime.substring(11, 16);
  }
  return '00:00';
}

/** 从今天起偏移 n 天后的 "YYYY-MM-DD" */
export function shiftDay(n: number): string {
  const d: Date = new Date();
  d.setDate(d.getDate() + n);
  return dateToISO(d);
}

/** 指定日期偏移 n 天 */
export function addDays(iso: string, n: number): string {
  const d: Date = isoToDate(iso);
  d.setDate(d.getDate() + n);
  return dateToISO(d);
}

/** 某年某月的天数(契约 §6:月末溢出取当月最后一天) */
export function lastDayOfMonth(year: number, month1to12: number): number {
  return new Date(year, month1to12, 0).getDate();
}

/**
 * 月份偏移,日期溢出时取当月最后一天(契约 §6 monthly 规则)。
 * 例:1 月 31 日 + 1 个月 → 2 月 28/29 日。
 */
export function addMonthsClamped(iso: string, months: number): string {
  const d: Date = isoToDate(iso);
  const day: number = d.getDate();
  const targetMonthIndex: number = d.getMonth() + months;
  const year: number = d.getFullYear() + Math.floor(targetMonthIndex / 12);
  const monthIndex: number = ((targetMonthIndex % 12) + 12) % 12;
  const lastDay: number = lastDayOfMonth(year, monthIndex + 1);
  const newDay: number = day > lastDay ? lastDay : day;
  return year.toString() + '-' + pad2(monthIndex + 1) + '-' + pad2(newDay);
}

/** 年份偏移,2 月 29 日溢出时取 2 月 28 日(契约 §6 yearly 规则) */
export function addYearsClamped(iso: string, years: number): string {
  const d: Date = isoToDate(iso);
  const year: number = d.getFullYear() + years;
  const month: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const lastDay: number = lastDayOfMonth(year, month);
  const newDay: number = day > lastDay ? lastDay : day;
  return year.toString() + '-' + pad2(month) + '-' + pad2(newDay);
}

/** 两个 "YYYY-MM-DD" 之间的天数差(to - from) */
export function daysBetween(fromISO: string, toISO: string): number {
  const a: Date = isoToDate(fromISO);
  const b: Date = isoToDate(toISO);
  const ms: number = b.getTime() - a.getTime();
  return Math.round(ms / 86400000);
}

/** 星期几:0=周日 … 6=周六 */
export function weekdayIndex(iso: string): number {
  return isoToDate(iso).getDay();
}

/** 中文星期简称:"一"…"日" */
export function weekdayCn(iso: string): string {
  return CN_WEEKDAYS[weekdayIndex(iso)];
}

/** "M月D日" */
export function fmtMonthDay(iso: string): string {
  const d: Date = isoToDate(iso);
  return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
}

/** 相对日期的短文案:今天 / 明天 / 后天 / 昨天 / M月D日 */
export function fmtShortDate(iso: string): string {
  const t: string = todayISO();
  if (iso === t) {
    return '今天';
  }
  if (iso === shiftDay(1)) {
    return '明天';
  }
  if (iso === shiftDay(2)) {
    return '后天';
  }
  if (iso === shiftDay(-1)) {
    return '昨天';
  }
  return fmtMonthDay(iso);
}

/** 分组标题:"今天 · 周四" / "10月11日 · 周日" / "2027年1月3日 · 周日" */
export function fmtDayLabel(iso: string): string {
  const t: string = todayISO();
  const week: string = weekdayCn(iso);
  if (iso === t) {
    return '今天 · 周' + week;
  }
  if (iso === shiftDay(1)) {
    return '明天 · 周' + week;
  }
  if (iso === shiftDay(2)) {
    return '后天 · 周' + week;
  }
  if (iso === shiftDay(-1)) {
    return '昨天 · 周' + week;
  }
  const d: Date = isoToDate(iso);
  const sameYear: boolean = d.getFullYear() === new Date().getFullYear();
  const head: string = sameYear ? fmtMonthDay(iso) : d.getFullYear().toString() + '年' + fmtMonthDay(iso);
  return head + ' · 周' + week;
}

/** "YYYY-MM-DD" → "M/D"(紧凑展示) */
export function fmtMonthSlashDay(iso: string): string {
  const d: Date = isoToDate(iso);
  return (d.getMonth() + 1).toString() + '/' + d.getDate().toString();
}

/** epoch millis → "YYYY-MM-DD"(本地) */
export function millisToISO(ms: number): string {
  return dateToISO(new Date(ms));
}

/** epoch millis → "HH:mm"(本地) */
export function millisToHM(ms: number): string {
  const d: Date = new Date(ms);
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/** epoch millis → "YYYY-MM-DDTHH:mm" */
export function millisToLocalDateTime(ms: number): string {
  const d: Date = new Date(ms);
  return dateToISO(d) + 'T' + pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/** "YYYY-MM-DDTHH:mm" → epoch millis(本地) */
export function localDateTimeToMillis(dt: string): number {
  const dateISO: string = datePartOf(dt);
  const hm: string = timePartOf(dt);
  const d: Date = isoToDate(dateISO);
  const hmParts: string[] = hm.split(':');
  const h: number = hmParts.length > 0 ? parseInt(hmParts[0], 10) : 0;
  const mi: number = hmParts.length > 1 ? parseInt(hmParts[1], 10) : 0;
  d.setHours(h, mi, 0, 0);
  return d.getTime();
}

/** 提醒文案:"今天只显示时刻",其它日期显示 "明天 09:30" */
export function fmtReminder(reminder: string): string {
  const day: string = datePartOf(reminder);
  const hm: string = timePartOf(reminder);
  if (day === todayISO()) {
    return hm;
  }
  return fmtShortDate(day) + ' ' + hm;
}

/** 是否早于今天(用于逾期判断,契约 §4) */
export function isBeforeToday(iso: string | null): boolean {
  if (iso === null) {
    return false;
  }
  return iso < todayISO();
}

/** 是否不晚于今天(契约 §4 今天清单:`date <= today`) */
export function isOnOrBeforeToday(iso: string | null): boolean {
  if (iso === null) {
    return false;
  }
  return iso <= todayISO();
}

/** 判断 "YYYY-MM-DD" 是否形如合法日期 */
export function isValidISODate(iso: string): boolean {
  if (iso.length !== 10) {
    return false;
  }
  const parts: string[] = iso.split('-');
  if (parts.length !== 3) {
    return false;
  }
  const y: number = parseInt(parts[0], 10);
  const m: number = parseInt(parts[1], 10);
  const d: number = parseInt(parts[2], 10);
  if (isNaN(y) || isNaN(m) || isNaN(d)) {
    return false;
  }
  if (m < 1 || m > 12 || d < 1) {
    return false;
  }
  return d <= lastDayOfMonth(y, m);
}

/** 判断 "YYYY-MM-DDTHH:mm" 是否合法 */
export function isValidISODateTime(dt: string): boolean {
  if (dt.length !== 16 || dt.charAt(10) !== 'T') {
    return false;
  }
  if (!isValidISODate(datePartOf(dt))) {
    return false;
  }
  const hm: string[] = timePartOf(dt).split(':');
  if (hm.length !== 2) {
    return false;
  }
  const h: number = parseInt(hm[0], 10);
  const mi: number = parseInt(hm[1], 10);
  if (isNaN(h) || isNaN(mi)) {
    return false;
  }
  return h >= 0 && h <= 23 && mi >= 0 && mi <= 59;
}
