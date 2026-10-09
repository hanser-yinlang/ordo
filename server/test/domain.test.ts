/**
 * 领域层契约测试 —— §3 不变量 / §4 派生清单 / §5 NLP / §6 重复规则
 * (四端共享的参考实现,服务端保证与契约逐条一致)
 */
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { buildEntitySet, listInbox, listLogbook, listToday, listUpcoming, projectProgress, searchTodos } from '../src/domain/lists';
import { normalizeTodo } from '../src/domain/normalize';
import { parseChineseNlp } from '../src/domain/nlp';
import { completeRepeatingTodo, nextOccurrenceDate } from '../src/domain/repeat';
import { Area, Heading, Project, Tag, Todo } from '../src/domain/model';
import { addDaysISO } from '../src/domain/time';

/* 固定「现在」:2026-10-08 12:00 (UTC+8,周四) */
const NOW_MS = Date.UTC(2026, 9, 8, 4, 0, 0);
const TZ = 480;
const TODAY = '2026-10-08';

function todo(overrides: Partial<Todo> = {}): Todo {
  return {
    id: 't1',
    title: '测试',
    note: '',
    when: 'inbox',
    date: null,
    reminder: null,
    deadline: null,
    tags: [],
    checklist: [],
    projectId: null,
    areaId: null,
    headingId: null,
    repeat: null,
    order: 0,
    status: 'open',
    createdAt: NOW_MS,
    updatedAt: NOW_MS,
    completedAt: null,
    deleted: false,
    ...overrides
  };
}

describe('§5 中文自然语言解析', () => {
  const parse = (text: string) => parseChineseNlp(text, { nowMs: NOW_MS, tzOffsetMinutes: TZ });

  it('「明天 18:00 交季度报告 #重要」', () => {
    const r = parse('明天 18:00 交季度报告 #重要');
    assert.equal(r.cleanTitle, '交季度报告');
    assert.equal(r.when, 'date');
    assert.equal(r.date, '2026-10-09');
    assert.equal(r.reminder, '2026-10-09T18:00');
    assert.deepEqual(r.tags, ['重要']);
  });

  it('「晚上8点 给妈妈打电话」→ 时段换算 +12 且归入今天', () => {
    const r = parse('晚上8点 给妈妈打电话');
    assert.equal(r.cleanTitle, '给妈妈打电话');
    assert.equal(r.when, 'today');
    assert.equal(r.reminder, '2026-10-08T20:00');
  });

  it('「下午3点半」→ 15:30', () => {
    const r = parse('下午3点半 开会');
    assert.equal(r.cleanTitle, '开会');
    assert.equal(r.reminder, '2026-10-08T15:30');
  });

  it('星期:本周内未过取本周,带「下」按周偏移', () => {
    assert.equal(parse('周五 交报告').date, '2026-10-09');
    assert.equal(parse('下周五 交报告').date, '2026-10-16');
    assert.equal(parse('下下周三 交报告').date, '2026-10-21');
  });

  it('相对天 / 相对周 / 相对月 / 绝对日期', () => {
    assert.equal(parse('3天后 复盘').date, '2026-10-11');
    assert.equal(parse('2周后 体检').date, '2026-10-22');
    assert.equal(parse('1个月后 续费').date, '2026-11-08');
    assert.equal(parse('10月9日 出差').date, '2026-10-09');
    assert.equal(parse('2026-12-01 结项').date, '2026-12-01');
  });

  it('关键词:今晚 / 今天 / 某天 / 周末', () => {
    assert.equal(parse('今晚 读书').when, 'evening');
    assert.equal(parse('今天 写周报').when, 'today');
    assert.equal(parse('某天 学吉他').when, 'someday');
    assert.equal(parse('周末 爬山').date, '2026-10-10');
  });

  it('冲突优先级:绝对日期 > 关键词', () => {
    const r = parse('明天 10月20日 交材料');
    assert.equal(r.date, '2026-10-20');
  });
});

describe('§6 重复规则引擎', () => {
  it('fixed:基于原 date 递推', () => {
    assert.equal(nextOccurrenceDate({ repeat: { freq: 'daily', interval: 1, mode: 'fixed' }, date: '2026-10-08', reminder: null }, TODAY), '2026-10-09');
    assert.equal(nextOccurrenceDate({ repeat: { freq: 'weekly', interval: 2, mode: 'fixed' }, date: '2026-10-08', reminder: null }, TODAY), '2026-10-22');
    assert.equal(nextOccurrenceDate({ repeat: { freq: 'yearly', interval: 1, mode: 'fixed' }, date: '2026-10-08', reminder: null }, TODAY), '2027-10-08');
  });

  it('monthly:日期溢出取当月最后一天', () => {
    assert.equal(nextOccurrenceDate({ repeat: { freq: 'monthly', interval: 1, mode: 'fixed' }, date: '2026-01-31', reminder: null }, TODAY), '2026-02-28');
  });

  it('afterCompletion:基于实际完成日递推', () => {
    assert.equal(
      nextOccurrenceDate({ repeat: { freq: 'weekly', interval: 1, mode: 'afterCompletion' }, date: '2026-01-01', reminder: null }, TODAY),
      '2026-10-15'
    );
  });

  it('fixed 且无 date 时回退到 reminder 的日期', () => {
    assert.equal(
      nextOccurrenceDate({ repeat: { freq: 'daily', interval: 3, mode: 'fixed' }, date: null, reminder: '2026-10-05T09:00' }, TODAY),
      '2026-10-08'
    );
  });

  it('完成重复待办会生成新实例:status/checklist 重置、id 重新生成', () => {
    const original = todo({
      id: 'rep-1',
      when: 'date',
      date: '2026-10-01',
      repeat: { freq: 'weekly', interval: 1, mode: 'fixed' },
      checklist: [{ id: 'c1', title: '步骤', done: true }]
    });
    const { current, next } = completeRepeatingTodo(original, {
      today: TODAY,
      nowMs: NOW_MS,
      newId: () => 'rep-2'
    });
    assert.equal(current.status, 'done');
    assert.equal(current.completedAt, NOW_MS);
    assert.ok(current.repeat, '原实例保留 repeat 供日志簿展示');
    assert.equal(next?.id, 'rep-2');
    assert.equal(next?.status, 'open');
    assert.equal(next?.completedAt, null);
    assert.equal(next?.date, '2026-10-08');
    assert.equal(next?.checklist[0].done, false);
  });

  it('非重复待办不生成新实例', () => {
    const { next } = completeRepeatingTodo(todo({ repeat: null }), { today: TODAY, nowMs: NOW_MS, newId: () => 'x' });
    assert.equal(next, null);
  });
});

describe('§3 字段默认值与不变量', () => {
  const ctx = { nowMs: NOW_MS, tzOffsetMinutes: TZ };

  it('未指定 when 且无项目 → inbox;指定项目 → anytime', () => {
    const a = normalizeTodo(todo({ when: 'inbox' }), { ...ctx, raw: { title: 'x' } });
    assert.equal(a.when, 'inbox');
    const b = normalizeTodo(todo({ when: 'inbox', projectId: 'p1' }), { ...ctx, raw: { title: 'x', projectId: 'p1' } });
    assert.equal(b.when, 'anytime');
  });

  it('when=date 时 date 为空补今天;非 date 时 date 强制为 null', () => {
    assert.equal(normalizeTodo(todo({ when: 'date', date: null }), { ...ctx, raw: { when: 'date' } }).date, TODAY);
    assert.equal(normalizeTodo(todo({ when: 'today', date: '2026-01-01' }), ctx).date, null);
  });

  it('设置提醒且 when ∈ {inbox,anytime,someday} → 自动改为 today 并对齐日期', () => {
    const t = normalizeTodo(todo({ when: 'anytime', reminder: '2020-01-01T09:30' }), ctx);
    assert.equal(t.when, 'today');
    assert.equal(t.reminder, `${TODAY}T09:30`);
  });

  it('标题为空视为删除(由 sync 层落墓碑)', () => {
    const t = normalizeTodo(todo({ title: '   ' }), ctx);
    assert.equal(t.title.trim(), '');
  });
});

describe('§4 派生清单', () => {
  const areas: Area[] = [{ id: 'a1', name: '工作', color: '#5B5BD6', order: 0, archived: false, deleted: false }];
  const headings: Heading[] = [
    { id: 'h1', projectId: 'p1', name: '设计', order: 0, archived: false, collapsed: false }
  ];
  const projects: Project[] = [
    {
      id: 'p1',
      areaId: 'a1',
      name: 'Q4 发布',
      note: '',
      when: 'anytime',
      date: null,
      deadline: null,
      tags: [],
      order: 0,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: NOW_MS,
      updatedAt: NOW_MS,
      deleted: false
    }
  ];
  const tags: Tag[] = [{ id: 'tag1', name: '重要', color: '#FF6B5A', updatedAt: NOW_MS }];

  const set = buildEntitySet(
    areas,
    projects,
    headings,
    [
      todo({ id: 'i1', title: '收件箱里的', when: 'inbox' }),
      todo({ id: 'y1', title: '今天做', when: 'today' }),
      todo({ id: 'y2', title: '今晚做', when: 'evening' }),
      todo({ id: 'y3', title: '逾期截止', when: 'anytime', deadline: addDaysISO(TODAY, -1) }),
      todo({ id: 'u1', title: '明天的', when: 'date', date: addDaysISO(TODAY, 1), projectId: 'p1', headingId: 'h1' }),
      todo({ id: 'u2', title: '很远以后', when: 'date', date: addDaysISO(TODAY, 60) }),
      todo({ id: 'd1', title: '已完成', when: 'today', status: 'done', completedAt: NOW_MS }),
      todo({ id: 's1', title: '某天的', when: 'someday' }),
      todo({ id: 'x1', title: '被删除', when: 'today', deleted: true })
    ],
    tags
  );

  it('收件箱:open 且 when=inbox,排除已删除', () => {
    assert.deepEqual(listInbox(set).map((t) => t.id), ['i1']);
  });

  it('今天:含 today/evening/到期的 date/到期的截止,并给出今晚分区与逾期', () => {
    const { items, evening, overdue } = listToday(set, TODAY);
    const ids = items.map((t) => t.id);
    assert.ok(ids.includes('y1'));
    assert.ok(ids.includes('y3'), '截止日期已过 → 进入今天');
    assert.equal(ids.includes('y2'), false, '今晚单列,不混在主体列表');
    assert.deepEqual(evening.map((t) => t.id), ['y2']);
    assert.deepEqual(overdue.map((t) => t.id), ['y3']);
    assert.equal(ids.includes('x1'), false, '已删除不进任何清单');
    assert.equal(ids.includes('d1'), false, '已完成不进今天');
  });

  it('计划:窗口为明天起 14 天,超出归入「更晚」', () => {
    const { start, end, groups, later } = listUpcoming(set, TODAY);
    assert.equal(start, addDaysISO(TODAY, 1));
    assert.equal(end, addDaysISO(TODAY, 14));
    assert.deepEqual(groups.find((g) => g.date === addDaysISO(TODAY, 1))?.todos.map((t) => t.id), ['u1']);
    assert.deepEqual(later.map((t) => t.id), ['u2']);
  });

  it('日志簿与项目进度', () => {
    assert.deepEqual(listLogbook(set).flatMap((g) => g.todos.map((t) => t.id)), ['d1']);
    // p1 下有 1 个 open(u1),0 个 done → 0
    assert.equal(projectProgress(set, 'p1'), 0);
  });

  it('搜索:标题包含关键词,未完成优先', () => {
    assert.deepEqual(searchTodos(set, '今天').map((t) => t.id), ['y1']);
    assert.deepEqual(searchTodos(set, '不存在的关键词'), []);
  });
});
