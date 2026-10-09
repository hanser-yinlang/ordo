/**
 * Ordo · 派生清单用例(契约 §4 逐条覆盖)
 * 固定 today = 2026-10-08;窗口 = 2026-10-09 ~ 2026-10-22(明天起 14 天)
 */

import { describe, expect, it } from '@ohos/hypium';
import { ChecklistItem, Heading, Todo, When } from '../../../main/ets/core/model/Entities.ets';
import {
  DayGroup,
  HeadingGroup,
  LogbookGroup,
  SidebarCounts,
  UPCOMING_WINDOW_DAYS,
  anytime,
  canCompleteProject,
  inbox,
  isOverdue,
  logbook,
  projectGroups,
  projectProgress,
  search,
  sidebarCounts,
  someday,
  tagTodos,
  today,
  tonight,
  upcoming,
  upcomingWindow
} from '../../../main/ets/core/query/ListQuery.ets';

import { makeHeading, makeTodo, TodoOverrides } from './Fixtures.ets';

const TODAY: string = '2026-10-08';
const WINDOW: string[] = upcomingWindow(TODAY);

/** 构造契约 §2.4 的完整待办(统一走 Fixtures 的显式字段合并) */
function mk(id: string, title: string, when: When, opts?: TodoOverrides): Todo {
  return makeTodo(id, title, when, opts);
}

function headingFixture(id: string, projectId: string, name: string, order: number): Heading {
  return makeHeading(id, projectId, name, order);
}

export default function listQueryTest() {
  describe('ListQuery', () => {

    it('inbox_only_open_inbox_items', 0, () => {
      const list: Todo[] = [
        mk('1', 'a', 'inbox'),
        mk('2', 'b', 'today'),
        mk('3', 'c', 'inbox', { status: 'done' }),
        mk('4', 'd', 'inbox', { deleted: true })
      ];
      expect(inbox(list).length).assertEqual(1);
      expect(inbox(list)[0].id).assertEqual('1');
    });

    it('today_covers_when_date_and_deadline', 0, () => {
      const list: Todo[] = [
        mk('1', 'today', 'today'),
        mk('2', 'evening', 'evening'),
        mk('3', 'overdue date', 'date', { date: '2026-10-01' }),
        mk('4', 'future date', 'date', { date: '2026-10-20' }),
        mk('5', 'deadline today', 'anytime', { deadline: TODAY }),
        mk('6', 'deadline future', 'anytime', { deadline: '2026-10-30' }),
        mk('7', 'done', 'today', { status: 'done' })
      ];
      const ids: string[] = today(list, TODAY).map((t: Todo): string => t.id);
      expect(ids.length).assertEqual(4);
      expect(ids.indexOf('1') >= 0).assertTrue();
      expect(ids.indexOf('2') >= 0).assertTrue();
      expect(ids.indexOf('3') >= 0).assertTrue();
      expect(ids.indexOf('5') >= 0).assertTrue();
      expect(ids.indexOf('4') < 0).assertTrue();
    });

    it('tonight_is_subset_of_today', 0, () => {
      const list: Todo[] = [
        mk('1', 'a', 'today'),
        mk('2', 'b', 'evening'),
        mk('3', 'c', 'evening', { status: 'done' })
      ];
      expect(tonight(list, TODAY).length).assertEqual(1);
      expect(tonight(list, TODAY)[0].id).assertEqual('2');
    });

    it('overdue_flag', 0, () => {
      expect(isOverdue(mk('1', 'a', 'today', { deadline: '2026-10-01' }), TODAY)).assertTrue();
      expect(isOverdue(mk('2', 'b', 'today', { deadline: TODAY }), TODAY)).assertFalse();
      expect(isOverdue(mk('3', 'c', 'today', { deadline: '2026-10-01', status: 'done' }), TODAY)).assertFalse();
    });

    it('upcoming_window_and_overflow', 0, () => {
      expect(WINDOW.length).assertEqual(UPCOMING_WINDOW_DAYS);
      expect(WINDOW[0]).assertEqual('2026-10-09');
      expect(WINDOW[WINDOW.length - 1]).assertEqual('2026-10-22');

      const list: Todo[] = [
        mk('1', 'in window', 'date', { date: '2026-10-12' }),
        mk('2', 'today not upcoming', 'date', { date: TODAY }),
        mk('3', 'overflow', 'date', { date: '2026-11-20' }),
        mk('4', 'deadline in window', 'anytime', { deadline: '2026-10-10' })
      ];
      const groups: DayGroup[] = upcoming(list, TODAY, WINDOW);
      const flat: string[] = [];
      for (let i = 0; i < groups.length; i++) {
        for (let k = 0; k < groups[i].todos.length; k++) {
          flat.push(groups[i].todos[k].id);
        }
      }
      expect(flat.indexOf('1') >= 0).assertTrue();
      expect(flat.indexOf('4') >= 0).assertTrue();
      expect(flat.indexOf('2') < 0).assertTrue();
      expect(flat.indexOf('3') >= 0).assertTrue();
      // 最后一个分组是"更晚"
      expect(groups[groups.length - 1].overflow).assertTrue();
      expect(groups[groups.length - 1].label).assertEqual('更晚');
    });

    it('upcoming_includes_repeat_next_occurrence', 0, () => {
      const list: Todo[] = [
        mk('1', 'weekly from past', 'date', {
          date: '2026-09-24',
          repeat: { freq: 'weekly', interval: 1, mode: 'fixed' }
        })
      ];
      const groups: DayGroup[] = upcoming(list, TODAY, WINDOW);
      expect(groups.length).assertEqual(1);
      // 2026-09-24 + 3 周 = 2026-10-15
      expect(groups[0].date).assertEqual('2026-10-15');
    });

    it('anytime_and_someday', 0, () => {
      const list: Todo[] = [
        mk('1', 'a', 'anytime'),
        mk('2', 'b', 'someday'),
        mk('3', 'c', 'anytime', { deleted: true })
      ];
      expect(anytime(list).length).assertEqual(1);
      expect(someday(list).length).assertEqual(1);
      expect(someday(list)[0].id).assertEqual('2');
    });

    it('logbook_groups_desc_by_completion', 0, () => {
      const day1: number = new Date(2026, 9, 6, 10, 0, 0).getTime();
      const day2: number = new Date(2026, 9, 7, 10, 0, 0).getTime();
      const list: Todo[] = [
        mk('1', 'a', 'anytime', { status: 'done', completedAt: day1 }),
        mk('2', 'b', 'anytime', { status: 'canceled', completedAt: day2 }),
        mk('3', 'c', 'anytime')
      ];
      const groups: LogbookGroup[] = logbook(list);
      expect(groups.length).assertEqual(2);
      expect(groups[0].date).assertEqual('2026-10-07'); // 倒序:最近的在前
      expect(groups[1].date).assertEqual('2026-10-06');
    });

    it('project_groups_heading_order_and_loose_last', 0, () => {
      const headings: Heading[] = [
        headingFixture('h2', 'p1', '开发', 1),
        headingFixture('h1', 'p1', '设计', 0)
      ];
      const list: Todo[] = [
        mk('1', 'under dev', 'anytime', { projectId: 'p1', headingId: 'h2', order: 1 }),
        mk('2', 'under design', 'anytime', { projectId: 'p1', headingId: 'h1', order: 2 }),
        mk('3', 'loose', 'anytime', { projectId: 'p1', order: 3 }),
        mk('4', 'other project', 'anytime', { projectId: 'p2', order: 4 }),
        mk('5', 'done one', 'anytime', { projectId: 'p1', status: 'done' })
      ];
      const groups: HeadingGroup[] = projectGroups(list, headings, 'p1');
      expect(groups.length).assertEqual(3);
      expect(groups[0].name).assertEqual('设计'); // order=0 在前
      expect(groups[1].name).assertEqual('开发');
      expect(groups[2].headingId === null).assertTrue(); // 无标题分组永远最后
      expect(groups[2].todos[0].id).assertEqual('3');
    });

    it('project_groups_skip_archived_heading_but_keep_todos', 0, () => {
      const h: Heading = headingFixture('h1', 'p1', '已归档', 0);
      h.archived = true;
      const list: Todo[] = [mk('1', 'a', 'anytime', { projectId: 'p1', headingId: 'h1' })];
      const groups: HeadingGroup[] = projectGroups(list, [h], 'p1');
      expect(groups.length).assertEqual(1);
      expect(groups[0].headingId === null).assertTrue();
      expect(groups[0].todos.length).assertEqual(1);
    });

    it('tag_view_only_open_toggle', 0, () => {
      const list: Todo[] = [
        mk('1', 'a', 'anytime', { tags: ['重要'] }),
        mk('2', 'b', 'anytime', { tags: ['重要'], status: 'done' })
      ];
      expect(tagTodos(list, '重要', true).length).assertEqual(1);
      expect(tagTodos(list, '重要', false).length).assertEqual(2);
    });

    it('search_open_first_then_updated_desc', 0, () => {
      const list: Todo[] = [
        mk('1', '报告 A', 'anytime', { status: 'done', updatedAt: 5000 }),
        mk('2', '报告 B', 'anytime', { updatedAt: 1000 }),
        mk('3', '报告 C', 'anytime', { updatedAt: 3000 }),
        mk('4', '无关', 'anytime')
      ];
      const out: Todo[] = search(list, '报告');
      expect(out.length).assertEqual(3);
      expect(out[0].id).assertEqual('3'); // 未完成优先,updatedAt 倒序
      expect(out[1].id).assertEqual('2');
      expect(out[2].id).assertEqual('1'); // 已完成排最后
    });

    it('search_case_insensitive_and_note', 0, () => {
      const list: Todo[] = [mk('1', 'Report', 'anytime', { note: '包含 API 说明' })];
      expect(search(list, 'report').length).assertEqual(1);
      expect(search(list, 'api').length).assertEqual(1);
    });

    it('project_progress_and_empty', 0, () => {
      const list: Todo[] = [
        mk('1', 'a', 'anytime', { projectId: 'p1', status: 'done' }),
        mk('2', 'b', 'anytime', { projectId: 'p1' }),
        mk('3', 'c', 'anytime', { projectId: 'p1', status: 'canceled' })
      ];
      expect(projectProgress(list, 'p1')).assertEqual(2 / 3);
      expect(projectProgress(list, 'p2')).assertEqual(0);
    });

    it('can_complete_project_requires_all_done_and_headings_archived', 0, () => {
      const openTodo: Todo[] = [mk('1', 'a', 'anytime', { projectId: 'p1' })];
      const doneTodo: Todo[] = [mk('1', 'a', 'anytime', { projectId: 'p1', status: 'done' })];
      const h: Heading = headingFixture('h1', 'p1', '阶段一', 0);

      expect(canCompleteProject(openTodo, [], 'p1')).assertFalse();
      expect(canCompleteProject(doneTodo, [h], 'p1')).assertFalse(); // 标题未归档
      const archived: Heading = headingFixture('h1', 'p1', '阶段一', 0);
      archived.archived = true;
      expect(canCompleteProject(doneTodo, [archived], 'p1')).assertTrue();
    });

    it('sidebar_counts', 0, () => {
      const list: Todo[] = [
        mk('1', 'a', 'inbox'),
        mk('2', 'b', 'today'),
        mk('3', 'c', 'anytime'),
        mk('4', 'd', 'someday'),
        mk('5', 'e', 'date', { date: '2026-10-12' }),
        mk('6', 'f', 'anytime', { status: 'done', completedAt: 1000 })
      ];
      const counts: SidebarCounts = sidebarCounts(list, TODAY, WINDOW);
      expect(counts.inbox).assertEqual(1);
      expect(counts.today).assertEqual(1);
      expect(counts.anytime).assertEqual(1);
      expect(counts.someday).assertEqual(1);
      expect(counts.upcoming).assertEqual(1);
      expect(counts.logbook).assertEqual(1);
    });

    it('checklist_items_are_embedded_not_synced_separately', 0, () => {
      const items: ChecklistItem[] = [{ id: 'c1', title: '订机票', done: false }];
      const t: Todo = mk('1', '出行', 'anytime', { checklist: items });
      expect(t.checklist.length).assertEqual(1);
      expect(t.checklist[0].title).assertEqual('订机票');
    });
  });
}
