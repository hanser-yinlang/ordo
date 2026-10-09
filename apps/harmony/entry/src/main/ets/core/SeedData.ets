/**
 * Ordo · 内置示例数据(简体中文)
 * 契约来源:docs/03-数据模型与同步协议.md §2/§3(所有字段必须满足默认值与不变量)
 *
 * 规模与 Web 原型(things-clone)对齐:4 区域 · 5 项目(含 3 个标题)· 7 标签 · 约 30 条待办
 * 其中包含:今天/今晚/收件箱/计划/随时/某天、清单项、重复待办、逾期截止、提醒、备注、日志簿记录。
 */

import {
  Area,
  CalendarEvent,
  ChecklistItem,
  Heading,
  OrdoState,
  Project,
  RepeatRule,
  Status,
  Tag,
  Todo,
  When
} from './model/Entities.ets';
import { addDays, localDateTimeToMillis } from './util/DateUtil.ets';

/** 待办种子描述(可选字段由构造函数补默认值) */
interface SeedTodo {
  id: string;
  title: string;
  when: When;
  date?: string;
  reminder?: string;
  deadline?: string;
  projectId?: string;
  areaId?: string;
  headingId?: string;
  tags?: string[];
  checklist?: string[][];
  note?: string;
  repeat?: RepeatRule;
  status?: Status;
  completedAt?: number;
  order: number;
}

/** 生成完整的待办对象(补齐契约 §2.4 的全部字段) */
function buildTodo(spec: SeedTodo, createdAt: number): Todo {
  const checklist: ChecklistItem[] = [];
  if (spec.checklist !== undefined) {
    for (let i = 0; i < spec.checklist.length; i++) {
      const pair: string[] = spec.checklist[i];
      const item: ChecklistItem = {
        id: spec.id + '_ck' + i.toString(),
        title: pair[0],
        done: pair.length > 1 && pair[1] === '1'
      };
      checklist.push(item);
    }
  }
  const status: Status = spec.status === undefined ? 'open' : spec.status;
  const t: Todo = {
    id: spec.id,
    title: spec.title,
    note: spec.note === undefined ? '' : spec.note,
    when: spec.when,
    date: spec.when === 'date' ? (spec.date === undefined ? null : spec.date) : null,
    reminder: spec.reminder === undefined ? null : spec.reminder,
    deadline: spec.deadline === undefined ? null : spec.deadline,
    tags: spec.tags === undefined ? [] : spec.tags,
    checklist: checklist,
    projectId: spec.projectId === undefined ? null : spec.projectId,
    areaId: spec.areaId === undefined ? null : spec.areaId,
    headingId: spec.headingId === undefined ? null : spec.headingId,
    repeat: spec.repeat === undefined ? null : spec.repeat,
    order: spec.order,
    status: status,
    createdAt: createdAt,
    updatedAt: createdAt,
    completedAt: spec.completedAt === undefined ? null : spec.completedAt,
    deleted: false
  };
  return t;
}

function heading(id: string, projectId: string, name: string, order: number, now: number): Heading {
  const h: Heading = {
    id: id,
    projectId: projectId,
    name: name,
    order: order,
    archived: false,
    collapsed: false,
    updatedAt: now
  };
  return h;
}

function dailyRule(): RepeatRule {
  const r: RepeatRule = { freq: 'daily', interval: 1, mode: 'fixed' };
  return r;
}

function weeklyRule(): RepeatRule {
  const r: RepeatRule = { freq: 'weekly', interval: 1, mode: 'fixed' };
  return r;
}

function monthlyRule(): RepeatRule {
  const r: RepeatRule = { freq: 'monthly', interval: 1, mode: 'fixed' };
  return r;
}

/**
 * 构建示例数据。
 * @param today 今天的 "YYYY-MM-DD"(显式传入,便于测试固定日期)
 */
export function buildSeedState(today: string): OrdoState {
  const now: number = localDateTimeToMillis(today + 'T09:00');
  const d: (n: number) => string = (n: number): string => addDays(today, n);

  /* ---------------------------------------------------------------- 区域 */
  const areas: Area[] = [
    { id: 'area_work', name: '工作', color: '#5B5BD6', order: 0, archived: false, updatedAt: now, deleted: false },
    { id: 'area_life', name: '个人生活', color: '#D98324', order: 1, archived: false, updatedAt: now, deleted: false },
    { id: 'area_health', name: '健康', color: '#2FA36B', order: 2, archived: false, updatedAt: now, deleted: false },
    { id: 'area_study', name: '学习', color: '#6B8AFD', order: 3, archived: false, updatedAt: now, deleted: false }
  ];

  /* ---------------------------------------------------------------- 项目 */
  const launchHeadings: Heading[] = [
    heading('hd_design', 'prj_launch', '设计', 0, now),
    heading('hd_dev', 'prj_launch', '开发', 1, now),
    heading('hd_release', 'prj_launch', '上线', 2, now)
  ];
  const projects: Project[] = [
    {
      id: 'prj_launch',
      areaId: 'area_work',
      name: 'Q4 产品发布',
      note: '目标:12 月初完成 4.0 正式版发布。\n# 关键节点\n- 设计冻结:11/20\n- 灰度发布:11/28',
      when: 'anytime',
      date: null,
      deadline: d(30),
      tags: ['重要'],
      headings: launchHeadings,
      order: 0,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: now,
      updatedAt: now,
      deleted: false
    },
    {
      id: 'prj_web',
      areaId: 'area_work',
      name: '网站改版',
      note: '首页信息层级重做,先出两版对比稿。',
      when: 'anytime',
      date: null,
      deadline: null,
      tags: [],
      headings: [],
      order: 1,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: now,
      updatedAt: now,
      deleted: false
    },
    {
      id: 'prj_move',
      areaId: 'area_life',
      name: '搬家准备',
      note: '月底前搬完,优先处理大件家具与水电网过户。',
      when: 'anytime',
      date: null,
      deadline: d(21),
      tags: [],
      headings: [],
      order: 2,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: now,
      updatedAt: now,
      deleted: false
    },
    {
      id: 'prj_read',
      areaId: 'area_study',
      name: '读书计划',
      note: '每两周读完一本,读不完就换更薄的。',
      when: 'anytime',
      date: null,
      deadline: null,
      tags: ['阅读'],
      headings: [],
      order: 3,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: now,
      updatedAt: now,
      deleted: false
    },
    {
      id: 'prj_run',
      areaId: 'area_health',
      name: '马拉松训练',
      note: '目标:半马 1 小时 55 分。',
      when: 'anytime',
      date: null,
      deadline: null,
      tags: [],
      headings: [],
      order: 4,
      status: 'open',
      completedAt: null,
      repeat: null,
      createdAt: now,
      updatedAt: now,
      deleted: false
    }
  ];

  /* ---------------------------------------------------------------- 标签 */
  const tags: Tag[] = [
    { id: 'tag_imp', name: '重要', color: '#E5533D', updatedAt: now },
    { id: 'tag_urgent', name: '紧急', color: '#D98324', updatedAt: now },
    { id: 'tag_call', name: '电话', color: '#2FA36B', updatedAt: now },
    { id: 'tag_out', name: '外出', color: '#5B5BD6', updatedAt: now },
    { id: 'tag_home', name: '家里', color: '#7A776F', updatedAt: now },
    { id: 'tag_read', name: '阅读', color: '#6B8AFD', updatedAt: now },
    { id: 'tag_deep', name: '深度工作', color: '#8E5BD6', updatedAt: now }
  ];

  /* ---------------------------------------------------------------- 待办 */
  const specs: SeedTodo[] = [
    /* 今天 */
    {
      id: 'td_01', title: '整理本周产品评审纪要', when: 'today', projectId: 'prj_launch', headingId: 'hd_dev',
      tags: ['深度工作'], note: '重点记录 **接口联调** 的结论。', order: 0
    },
    {
      id: 'td_02', title: '回复张伟关于接口联调的邮件', when: 'today', tags: ['紧急', '深度工作'],
      reminder: today + 'T11:00', order: 1
    },
    { id: 'td_03', title: '写周报并同步给团队', when: 'today', projectId: 'prj_launch', headingId: 'hd_dev', order: 2 },
    { id: 'td_04', title: '预约牙医洗牙', when: 'today', tags: ['电话'], reminder: today + 'T15:00', order: 3 },
    {
      id: 'td_05', title: '提交报销单', when: 'today', deadline: d(-1), tags: ['紧急'],
      note: '上月的差旅发票,截止日期已经过了。', order: 4
    },
    { id: 'td_06', title: '每周复盘与计划', when: 'today', tags: ['深度工作'], repeat: weeklyRule(), order: 5 },

    /* 今晚 */
    { id: 'td_07', title: '读《设计心理学》第 3 章', when: 'evening', projectId: 'prj_read', tags: ['阅读'], order: 6 },
    { id: 'td_08', title: '复盘今天的面试记录', when: 'evening', projectId: 'prj_launch', headingId: 'hd_dev', order: 7 },

    /* 收件箱 */
    { id: 'td_09', title: '了解竞品 X 的定价策略', when: 'inbox', tags: ['深度工作'], order: 8 },
    { id: 'td_10', title: '给妈妈挑生日礼物', when: 'inbox', tags: ['外出'], order: 9 },
    { id: 'td_11', title: '研究一下看板视图的交互方式', when: 'inbox', order: 10 },

    /* 计划(未来日期) */
    {
      id: 'td_12', title: '准备产品评审会材料', when: 'date', date: d(1), reminder: d(1) + 'T09:30',
      projectId: 'prj_launch', headingId: 'hd_dev', tags: ['重要'], order: 11
    },
    {
      id: 'td_13', title: '与设计师确认图标规范', when: 'date', date: d(1),
      projectId: 'prj_launch', headingId: 'hd_design', tags: ['重要'], order: 12
    },
    {
      id: 'td_14', title: '输出灰度发布检查清单', when: 'date', date: d(2),
      projectId: 'prj_launch', headingId: 'hd_release', order: 13
    },
    {
      id: 'td_15', title: '提交季报数据', when: 'date', date: d(3), deadline: d(5),
      tags: ['重要', '深度工作'], note: '数据源:`finance/q3.csv`', order: 14
    },
    {
      id: 'td_16', title: '预约搬家公司上门估价', when: 'date', date: d(4), deadline: d(6),
      projectId: 'prj_move', tags: ['电话'], order: 15
    },
    {
      id: 'td_17', title: '交房租', when: 'date', date: d(5), projectId: 'prj_move',
      repeat: monthlyRule(), tags: ['家里'], order: 16
    },
    { id: 'td_18', title: '团建活动报名', when: 'date', date: d(6), tags: ['外出'], order: 17 },
    {
      id: 'td_19', title: '整理书单并下单', when: 'date', date: d(11), projectId: 'prj_read',
      tags: ['阅读'], order: 18
    },
    { id: 'td_20', title: '预约体检', when: 'date', date: d(20), projectId: 'prj_run', order: 19 },

    /* 随时 */
    {
      id: 'td_21', title: '整理接口文档的目录结构', when: 'anytime', projectId: 'prj_launch',
      headingId: 'hd_dev', tags: ['深度工作'], order: 20,
      checklist: [['导出 OpenAPI', '1'], ['补充错误码', '0'], ['校对示例', '0']]
    },
    { id: 'td_22', title: '重写首页文案', when: 'anytime', projectId: 'prj_web', order: 21 },
    { id: 'td_23', title: '清理旧域名解析', when: 'anytime', projectId: 'prj_web', order: 22 },
    {
      id: 'td_24', title: '打包不常用的书', when: 'anytime', projectId: 'prj_move',
      checklist: [['装纸箱', '0'], ['贴标签', '0'], ['登记清单', '0']], order: 23
    },
    { id: 'td_25', title: '每周三次间歇跑', when: 'anytime', projectId: 'prj_run', repeat: dailyRule(), order: 24 },
    { id: 'td_26', title: '整理客厅的电源线', when: 'anytime', areaId: 'area_life', tags: ['家里'], order: 25 },

    /* 某天 */
    { id: 'td_27', title: '学做三道家常菜', when: 'someday', areaId: 'area_life', order: 26 },
    { id: 'td_28', title: '研究一下自建图床', when: 'someday', tags: ['深度工作'], order: 27 },
    { id: 'td_29', title: '报名半程马拉松', when: 'someday', projectId: 'prj_run', order: 28 },

    /* 日志簿(已完成/已取消) */
    {
      id: 'td_30', title: '备份手机照片', when: 'anytime', status: 'done',
      completedAt: localDateTimeToMillis(d(-1) + 'T21:30'), order: 29
    },
    {
      id: 'td_31', title: '确认会议室', when: 'anytime', projectId: 'prj_launch', headingId: 'hd_dev',
      status: 'done', completedAt: localDateTimeToMillis(d(-1) + 'T10:12'), order: 30
    },
    {
      id: 'td_32', title: '缴物业费', when: 'anytime', projectId: 'prj_move', tags: ['家里'],
      status: 'done', completedAt: localDateTimeToMillis(d(-2) + 'T16:40'), order: 31
    },
    {
      id: 'td_33', title: '读完《深度工作》', when: 'anytime', projectId: 'prj_read', tags: ['阅读'],
      status: 'done', completedAt: localDateTimeToMillis(d(-3) + 'T22:05'), order: 32
    },
    {
      id: 'td_34', title: '参加线下技术沙龙', when: 'anytime', tags: ['外出'],
      status: 'canceled', completedAt: localDateTimeToMillis(d(-4) + 'T19:00'), order: 33
    }
  ];

  const todos: Todo[] = [];
  for (let i = 0; i < specs.length; i++) {
    const t: Todo = buildTodo(specs[i], now - (specs.length - i) * 60000);
    todos.push(t);
  }

  /* ------------------------------------------------------------ 日历事件 */
  const events: CalendarEvent[] = [
    {
      id: 'ev_1', title: '产品评审会', start: localDateTimeToMillis(today + 'T10:00'),
      end: localDateTimeToMillis(today + 'T11:00'), calendar: '工作', allDay: false
    },
    {
      id: 'ev_2', title: '与设计师 1:1', start: localDateTimeToMillis(today + 'T14:30'),
      end: localDateTimeToMillis(today + 'T15:00'), calendar: '工作', allDay: false
    },
    {
      id: 'ev_3', title: '健身', start: localDateTimeToMillis(today + 'T19:00'),
      end: localDateTimeToMillis(today + 'T20:00'), calendar: '个人', allDay: false
    }
  ];

  const state: OrdoState = {
    areas: areas,
    projects: projects,
    todos: todos,
    tags: tags,
    events: events
  };
  return state;
}
