/**
 * Ordo · 重复规则用例(契约 §2.7 + §6)
 * 重点:fixed/afterCompletion 基准日不同;月末溢出取当月最后一天;2/29 → 2/28。
 */

import { describe, expect, it } from '@ohos/hypium';
import { ChecklistItem, RepeatRule, Todo, When } from '../../../main/ets/core/model/Entities.ets';
import {
  RepeatCompletion,
  advanceOccurrence,
  completeWithRepeat,
  firstOccurrenceOnOrAfter,
  repeatBaseDate,
  repeatLabel,
  sanitizeRepeatRule
} from '../../../main/ets/core/repeat/RepeatEngine.ets';
import { addMonthsClamped, addYearsClamped } from '../../../main/ets/core/util/DateUtil.ets';

import { makeRule, makeTodo, TodoOverrides } from './Fixtures.ets';

const TODAY: string = '2026-10-08';

function rule(freq: 'daily' | 'weekly' | 'monthly' | 'yearly', interval: number, mode: 'fixed' | 'afterCompletion'): RepeatRule {
  return makeRule(freq, interval, mode);
}

function mk(id: string, when: When, opts?: TodoOverrides): Todo {
  return makeTodo(id, 't', when, opts);
}

export default function repeatEngineTest() {
  describe('RepeatEngine', () => {

    it('advance_daily_weekly', 0, () => {
      expect(advanceOccurrence(rule('daily', 1, 'fixed'), '2026-10-08', 1)).assertEqual('2026-10-09');
      expect(advanceOccurrence(rule('daily', 3, 'fixed'), '2026-10-08', 1)).assertEqual('2026-10-11');
      expect(advanceOccurrence(rule('weekly', 1, 'fixed'), '2026-10-08', 2)).assertEqual('2026-10-22');
      expect(advanceOccurrence(rule('weekly', 2, 'fixed'), '2026-10-08', 1)).assertEqual('2026-10-22');
    });

    it('advance_monthly_clamps_to_last_day', 0, () => {
      // 契约 §6:月份 + interval,日期溢出取当月最后一天
      expect(advanceOccurrence(rule('monthly', 1, 'fixed'), '2026-01-31', 1)).assertEqual('2026-02-28');
      expect(advanceOccurrence(rule('monthly', 1, 'fixed'), '2026-08-31', 1)).assertEqual('2026-09-30');
      expect(advanceOccurrence(rule('monthly', 1, 'fixed'), '2026-03-15', 1)).assertEqual('2026-04-15');
      // 关键:第 n 次始终从 base 递推,不会漂移
      expect(advanceOccurrence(rule('monthly', 1, 'fixed'), '2026-01-31', 2)).assertEqual('2026-03-31');
    });

    it('advance_yearly_clamps_feb29', 0, () => {
      expect(advanceOccurrence(rule('yearly', 1, 'fixed'), '2024-02-29', 1)).assertEqual('2025-02-28');
      expect(advanceOccurrence(rule('yearly', 1, 'fixed'), '2026-10-08', 1)).assertEqual('2027-10-08');
    });

    it('date_util_clamp_helpers', 0, () => {
      expect(addMonthsClamped('2026-01-31', 1)).assertEqual('2026-02-28');
      expect(addMonthsClamped('2026-12-15', 1)).assertEqual('2027-01-15');
      expect(addYearsClamped('2024-02-29', 1)).assertEqual('2025-02-28');
    });

    it('base_date_depends_on_mode', 0, () => {
      const fixed: Todo = mk('1', 'date', { date: '2026-10-01', repeat: rule('weekly', 1, 'fixed') });
      expect(repeatBaseDate(fixed, TODAY)).assertEqual('2026-10-01');

      const after: Todo = mk('2', 'date', { date: '2026-10-01', repeat: rule('weekly', 1, 'afterCompletion') });
      expect(repeatBaseDate(after, TODAY)).assertEqual(TODAY);
    });

    it('base_date_falls_back_to_reminder_then_today', 0, () => {
      const byReminder: Todo = mk('1', 'anytime', {
        reminder: '2026-10-05T09:00',
        repeat: rule('daily', 1, 'fixed')
      });
      expect(repeatBaseDate(byReminder, TODAY)).assertEqual('2026-10-05');

      const none: Todo = mk('2', 'anytime', { repeat: rule('daily', 1, 'fixed') });
      expect(repeatBaseDate(none, TODAY)).assertEqual(TODAY);
    });

    it('first_occurrence_on_or_after', 0, () => {
      const r: RepeatRule = rule('weekly', 1, 'fixed');
      expect(firstOccurrenceOnOrAfter(r, '2026-09-24', TODAY)).assertEqual('2026-10-15');
      // base 已在未来 → 直接返回第一次推进
      expect(firstOccurrenceOnOrAfter(r, '2026-10-20', TODAY)).assertEqual('2026-10-27');
    });

    it('complete_with_repeat_creates_next_instance', 0, () => {
      const checklist: ChecklistItem[] = [
        { id: 'c1', title: '第一步', done: true },
        { id: 'c2', title: '第二步', done: false }
      ];
      const t: Todo = mk('t1', 'date', {
        title: '每周复盘',
        date: '2026-10-08',
        repeat: rule('weekly', 1, 'fixed'),
        checklist: checklist,
        reminder: '2026-10-08T18:00'
      } as TodoOverrides);
      const result: RepeatCompletion = completeWithRepeat(t, 1759900000000, TODAY);

      // 原实例:done + completedAt + 保留 repeat
      expect(result.completed.status).assertEqual('done');
      expect(result.completed.completedAt).assertEqual(1759900000000);
      expect(result.completed.repeat === null).assertFalse();

      // 新实例:新 id、open、checklist 重置、日期 +7 天、提醒顺延
      const next: Todo | null = result.next;
      expect(next === null).assertFalse();
      const nx: Todo = next as Todo;
      expect(nx.id === 't1').assertFalse();
      expect(nx.status).assertEqual('open');
      expect(nx.completedAt === null).assertTrue();
      expect(nx.date).assertEqual('2026-10-15');
      expect(nx.when).assertEqual('date');
      expect(nx.checklist.length).assertEqual(2);
      expect(nx.checklist[0].done).assertFalse();
      expect(nx.checklist[1].done).assertFalse();
      expect(nx.reminder).assertEqual('2026-10-15T18:00');
    });

    it('complete_without_repeat_returns_null_next', 0, () => {
      const t: Todo = mk('t1', 'today', { title: '一次性任务' } as TodoOverrides);
      const result: RepeatCompletion = completeWithRepeat(t, 1759900000000, TODAY);
      expect(result.completed.status).assertEqual('done');
      expect(result.next === null).assertTrue();
    });

    it('after_completion_mode_uses_today', 0, () => {
      const t: Todo = mk('t1', 'date', {
        date: '2026-09-01',
        repeat: rule('monthly', 1, 'afterCompletion')
      });
      const result: RepeatCompletion = completeWithRepeat(t, 1759900000000, TODAY);
      const nx: Todo = result.next as Todo;
      expect(nx.date).assertEqual('2026-11-08'); // TODAY + 1 个月
    });

    it('sanitize_and_label', 0, () => {
      expect(sanitizeRepeatRule(null) === null).assertTrue();
      expect(sanitizeRepeatRule(rule('daily', 0, 'fixed')) === null).assertTrue();
      expect(sanitizeRepeatRule(rule('daily', 1, 'fixed')) === null).assertFalse();
      expect(repeatLabel(rule('daily', 1, 'fixed'))).assertEqual('每天');
      expect(repeatLabel(rule('weekly', 2, 'fixed'))).assertEqual('每 2 周');
      expect(repeatLabel(rule('monthly', 1, 'afterCompletion'))).assertEqual('每个月 · 完成后');
      expect(repeatLabel(null)).assertEqual('');
    });
  });
}
