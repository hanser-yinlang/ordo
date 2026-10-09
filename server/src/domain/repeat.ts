/**
 * 重复规则引擎 —— 契约 §6。
 *
 * 完成一个 repeat != null 的待办时:
 *  1. 原实例:status=done、completedAt=now、repeat 保留
 *  2. 生成新实例:复制全部字段,id 重新生成,status=open、completedAt=null、checklist[].done=false、createdAt=now
 *  3. 新 date:
 *     - mode=fixed            → base = 原 date ?? 原 reminder 的日期 ?? 今天
 *     - mode=afterCompletion  → base = 今天
 *     - daily → +interval 天;weekly → +7×interval 天;monthly → 月份 +interval(溢出取当月最后一天);yearly → 年份 +interval
 *
 * 说明:服务端默认**不**代生成新实例(见 config.serverSideRepeat),
 *      本地优先架构下由客户端完成;本模块作为四端共享的参考实现与一致性测试对象。
 */
import { Todo } from './model';
import { addDaysISO, addMonthsISO, addYearsISO } from './time';

export interface RepeatContext {
  /** 今天(配置时区)YYYY-MM-DD */
  today: string;
  nowMs: number;
  /** 新实例 id 生成器(默认由调用方注入 uuid) */
  newId: () => string;
}

/** 按 §6 计算下一次发生日期;repeat 为空返回 null */
export function nextOccurrenceDate(
  todo: Pick<Todo, 'repeat' | 'date' | 'reminder'>,
  today: string
): string | null {
  const rule = todo.repeat;
  if (!rule) return null;

  const reminderDate = todo.reminder ? todo.reminder.slice(0, 10) : null;
  const base =
    rule.mode === 'afterCompletion' ? today : todo.date ?? reminderDate ?? today;

  const interval = rule.interval && rule.interval > 0 ? rule.interval : 1;
  switch (rule.freq) {
    case 'daily':
      return addDaysISO(base, interval);
    case 'weekly':
      return addDaysISO(base, 7 * interval);
    case 'monthly':
      return addMonthsISO(base, interval);
    case 'yearly':
      return addYearsISO(base, interval);
    default:
      return null;
  }
}

/**
 * 完成一个重复待办:返回「已完成的原实例」与「新生成的实例」。
 * 调用方负责把两者写入本地库与 outbox(契约 §7.1)。
 */
export function completeRepeatingTodo(todo: Todo, ctx: RepeatContext): { current: Todo; next: Todo | null } {
  const current: Todo = { ...todo, status: 'done', completedAt: ctx.nowMs };

  if (!todo.repeat) return { current, next: null };

  const nextDate = nextOccurrenceDate(todo, ctx.today);
  const next: Todo = {
    ...todo,
    id: ctx.newId(),
    date: nextDate,
    status: 'open',
    completedAt: null,
    createdAt: ctx.nowMs,
    checklist: todo.checklist.map((c) => ({ ...c, done: false }))
  };
  // 新实例的 reminder 若存在,日期部分必须与新 date 对齐(§3)
  if (next.reminder) {
    const targetDate = nextDate ?? ctx.today;
    next.reminder = `${targetDate}T${next.reminder.slice(11, 16)}`;
  }
  return { current, next };
}
