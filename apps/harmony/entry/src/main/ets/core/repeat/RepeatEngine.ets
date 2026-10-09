/**
 * Ordo · 重复规则引擎
 * 契约来源:docs/03-数据模型与同步协议.md §2.7(RepeatRule)、§6(重复规则引擎)
 *
 * §6 规则:
 *  1. 原实例:status=done、completedAt=now、repeat 保留(日志簿展示"曾重复")
 *  2. 新实例:复制全部字段,id 重新生成,status=open、completedAt=null、checklist[].done=false、createdAt=now
 *  3. 新 date:
 *     - mode=fixed          → base = 原 date ?? 原 reminder 的日期 ?? 今天
 *     - mode=afterCompletion → base = 今天
 *     - daily → base + interval 天;weekly → +7×interval 天;
 *       monthly → 月份 + interval(溢出取当月最后一天);yearly → 年份 + interval
 *
 * 设计要点:第 n 次发生**始终从 base 递推**(而不是在上一次结果上继续加),
 * 这样 "1 月 31 日 + 每月" 不会漂移成 2/28 → 3/28,而是稳定的 2/28 → 3/31。
 */

import { ChecklistItem, RepeatFreq, RepeatMode, RepeatRule, Todo, cloneTodo } from '../model/Entities.ets';
import { addDays, addMonthsClamped, addYearsClamped, datePartOf } from '../util/DateUtil.ets';
import { newChecklistItemId, newId } from '../util/Ids.ets';

/** 推进一次(第 n 次发生,n 从 1 开始) */
export function advanceOccurrence(rule: RepeatRule, baseDate: string, n: number): string {
  const step: number = n * (rule.interval > 0 ? rule.interval : 1);
  if (rule.freq === 'daily') {
    return addDays(baseDate, step);
  }
  if (rule.freq === 'weekly') {
    return addDays(baseDate, step * 7);
  }
  if (rule.freq === 'monthly') {
    return addMonthsClamped(baseDate, step);
  }
  return addYearsClamped(baseDate, step);
}

/**
 * 计算下一次发生的日期(§6 第 3 条),base 已由调用方按 mode 决定。
 * 契约未包含"每隔 N 天"之外的复杂规则,故只推进一次。
 */
export function nextOccurrenceDate(rule: RepeatRule, baseDate: string): string {
  return advanceOccurrence(rule, baseDate, 1);
}

/** 取重复规则的基准日(§6:fixed 用原 date ?? reminder 日期 ?? 今天;afterCompletion 用今天) */
export function repeatBaseDate(t: Todo, today: string): string {
  if (t.repeat !== null && t.repeat.mode === 'afterCompletion') {
    return today;
  }
  if (t.date !== null) {
    return t.date;
  }
  if (t.reminder !== null) {
    return datePartOf(t.reminder);
  }
  return today;
}

/**
 * 在 [fromISO, ∞) 区间内找到第一个发生日(用于「计划」清单展示重复待办的下一次)。
 * 最多向前推进 400 次,防止脏数据造成死循环。
 */
export function firstOccurrenceOnOrAfter(rule: RepeatRule, baseDate: string, fromISO: string): string {
  let n: number = 1;
  let d: string = advanceOccurrence(rule, baseDate, n);
  while (d < fromISO && n < 400) {
    n++;
    d = advanceOccurrence(rule, baseDate, n);
  }
  return d;
}

/** 某条待办的下一次发生日(不重复则返回 null) */
export function nextOccurrenceForTodo(t: Todo, today: string): string | null {
  if (t.repeat === null) {
    return null;
  }
  const base: string = repeatBaseDate(t, today);
  return firstOccurrenceOnOrAfter(t.repeat, base, today);
}

/* ---------------------------------------------------------------- 完成流程 */

/** §6 完成结果:原实例(已置 done)+ 新实例(未开启则为 null) */
export interface RepeatCompletion {
  completed: Todo;
  next: Todo | null;
}

/** 把清单项全部重置为未完成,并生成新的清单项 id(避免两端 id 冲突) */
function resetChecklistForNewInstance(list: ChecklistItem[]): ChecklistItem[] {
  const out: ChecklistItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const c: ChecklistItem = { id: newChecklistItemId(), title: list[i].title, done: false };
    out.push(c);
  }
  return out;
}

/**
 * 完成一条待办并处理重复(§6)。
 * @param t      原待办(不会被就地修改,返回的是副本)
 * @param now    epoch millis,作为 completedAt / createdAt
 * @param today  今天的 "YYYY-MM-DD"(显式传入以便测试)
 */
export function completeWithRepeat(t: Todo, now: number, today: string): RepeatCompletion {
  const completed: Todo = cloneTodo(t);
  completed.status = 'done';
  completed.completedAt = now;
  completed.updatedAt = now;
  // repeat 保留:日志簿展示"曾重复"
  if (t.repeat === null) {
    const none: RepeatCompletion = { completed: completed, next: null };
    return none;
  }

  const base: string = repeatBaseDate(t, today);
  const nextDate: string = nextOccurrenceDate(t.repeat, base);

  const next: Todo = cloneTodo(t);
  next.id = newId();
  next.status = 'open';
  next.completedAt = null;
  next.createdAt = now;
  next.updatedAt = now;
  next.checklist = resetChecklistForNewInstance(t.checklist);
  next.date = nextDate;
  next.when = 'date';
  // 提醒随日期顺延(保持与 date 同日,契约 §3 reminder 日期对齐规则)
  if (t.reminder !== null) {
    next.reminder = nextDate + 'T' + t.reminder.substring(11, 16);
  }
  // 订单号排在原位置之后,避免视觉跳动
  next.order = t.order + 1;
  // 完成态清零
  next.deleted = false;

  const result: RepeatCompletion = { completed: completed, next: next };
  return result;
}

/* ---------------------------------------------------------------- 展示文案 */

export function repeatLabel(rule: RepeatRule | null): string {
  if (rule === null) {
    return '';
  }
  const interval: number = rule.interval > 1 ? rule.interval : 1;
  const body: string = interval > 1
    ? '每 ' + interval.toString() + ' ' + unitText(rule.freq)
    : '每' + unitText(rule.freq);
  const modeCn: string = rule.mode === 'afterCompletion' ? ' · 完成后' : '';
  return body + modeCn;
}

function unitText(freq: RepeatFreq): string {
  if (freq === 'daily') {
    return '天';
  }
  if (freq === 'weekly') {
    return '周';
  }
  if (freq === 'monthly') {
    return '个月';
  }
  return '年';
}

/** 默认重复规则(排期面板"重复"菜单用) */
export function makeRepeatRule(freq: RepeatFreq, mode: RepeatMode): RepeatRule {
  const r: RepeatRule = { freq: freq, interval: 1, mode: mode };
  return r;
}

/** 校验:interval 必须 ≥1;非法规则返回 null */
export function sanitizeRepeatRule(rule: RepeatRule | null): RepeatRule | null {
  if (rule === null) {
    return null;
  }
  if (rule.interval < 1) {
    return null;
  }
  const ok: RepeatRule = { freq: rule.freq, interval: rule.interval, mode: rule.mode };
  return ok;
}
