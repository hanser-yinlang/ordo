/**
 * Ordo · 中文自然语言解析(NLP v1)
 * 契约来源:docs/03-数据模型与同步协议.md §5
 *
 * 输入示例:`明天 18:00 交季度报告 #重要`
 * 输出:`{ cleanTitle, when, date, reminder, tags }`(契约原文字段名)
 *
 * 冲突优先级(契约 §5):绝对日期 > 相对月 > 相对周 > 相对天 > 关键词(今晚 > 今天/明天…) > 时间
 * 时段换算(契约 §5):上午/早上 保持;中午 → 12 点;下午/傍晚/晚上/夜里 → +12(仅当 <12);凌晨 12 点 → 0 点
 *
 * 说明:`today` 一律显式传入(便于单元测试固定"今天"),UI 层用 parseNaturalNow() 取系统日期。
 */

import { When } from '../model/Entities.ets';
import { addDays, addMonthsClamped, isValidISODate, pad2, todayISO, weekdayIndex } from '../util/DateUtil.ets';

/** 契约 §5 输出结构 */
export interface ParsedInput {
  cleanTitle: string;
  when: When | null;
  date: string | null;
  reminder: string | null;
  tags: string[];
}

/** 内部:命中的日期信息 */
interface DateHit {
  when: When;
  date: string | null;
  matched: string;
}

/** 内部:命中的时间信息 */
interface TimeHit {
  /** "HH:mm" */
  hm: string;
  matched: string;
  /** 需要一并从标题移除的时段修饰词(如"晚上") */
  modifier: string;
}

const TAG_RE: RegExp = /#[^\s#，。、；;:：]+/g;

/** 判断是否中文字符(用于"天/周/月"等单位识别后的边界处理) */
function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

/** 从字符串中移除所有出现过的片段 */
function cutAll(text: string, cuts: string[]): string {
  let out: string = text;
  for (let i = 0; i < cuts.length; i++) {
    const c: string = cuts[i];
    if (c.length === 0) {
      continue;
    }
    out = out.split(c).join(' ');
  }
  return out;
}

/** 清理标题:压缩空白 + 去掉首尾标点(契约 §5「清理」) */
function cleanTitleOf(text: string): string {
  let out: string = text.split('\t').join(' ');
  while (out.indexOf('  ') >= 0) {
    out = out.split('  ').join(' ');
  }
  out = out.trim();
  const headPunct: string = '，。、；;:：,.-—·';
  while (out.length > 0 && headPunct.indexOf(out.charAt(0)) >= 0) {
    out = out.substring(1).trim();
  }
  while (out.length > 0 && headPunct.indexOf(out.charAt(out.length - 1)) >= 0) {
    out = out.substring(0, out.length - 1).trim();
  }
  return out;
}

/** 主入口:解析(显式传入今天,便于测试) */
export function parseNatural(input: string, today: string): ParsedInput {
  const cuts: string[] = [];
  const tags: string[] = [];
  let text: string = input === null || input === undefined ? '' : input;

  /* ---------- 1) 标签(契约 §5「标签」) ---------- */
  const tagHits: RegExpMatchArray | null = text.match(TAG_RE);
  if (tagHits !== null) {
    for (let i = 0; i < tagHits.length; i++) {
      const raw: string = tagHits[i];
      const name: string = raw.substring(1);
      if (name.length > 0 && tags.indexOf(name) < 0) {
        tags.push(name);
      }
      cuts.push(raw);
    }
  }

  /* ---------- 2) 日期(按优先级) ---------- */
  const hit: DateHit | null = matchDate(text, today);
  if (hit !== null) {
    cuts.push(hit.matched);
    // 修饰词(如"下下周"整体已被 matched 覆盖,无需额外处理)
  }

  /* ---------- 3) 时间 ---------- */
  const timeHit: TimeHit | null = matchTime(text);
  if (timeHit !== null) {
    cuts.push(timeHit.matched);
    if (timeHit.modifier.length > 0) {
      cuts.push(timeHit.modifier);
    }
  }

  /* ---------- 4) 组装结果 ---------- */
  let when: When | null = null;
  let date: string | null = null;
  if (hit !== null) {
    when = hit.when;
    date = hit.date;
  }

  let reminder: string | null = null;
  if (timeHit !== null) {
    const reminderDate: string = date !== null ? date : today;
    reminder = reminderDate + 'T' + timeHit.hm;
    if (when === null) {
      // 契约 §5:无日期信息时 when=today
      when = 'today';
    }
  }

  const result: ParsedInput = {
    cleanTitle: cleanTitleOf(cutAll(text, cuts)),
    when: when,
    date: date,
    reminder: reminder,
    tags: tags
  };
  return result;
}

/** UI 便捷入口:以系统当前日期为基准 */
export function parseNaturalNow(input: string): ParsedInput {
  return parseNatural(input, todayISO());
}

/* --------------------------------------------------------------- 日期匹配 */

function matchDate(text: string, today: string): DateHit | null {
  let m: RegExpMatchArray | null = null;

  /* 优先级 1:绝对日期 ------------------------------------------------ */
  // 2026-10-09 / 2026/10/9 / 2026.10.9
  m = text.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  if (m !== null) {
    const iso: string = m[1] + '-' + pad2(parseInt(m[2], 10)) + '-' + pad2(parseInt(m[3], 10));
    if (isValidISODate(iso)) {
      return makeDateHit(iso, m[0]);
    }
  }
  // 10月9日 / 10月9号
  m = text.match(/(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]/);
  if (m !== null) {
    const month: number = parseInt(m[1], 10);
    const day: number = parseInt(m[2], 10);
    const year: number = yearForMonthDay(month, day, today);
    const iso: string = year.toString() + '-' + pad2(month) + '-' + pad2(day);
    if (isValidISODate(iso)) {
      return makeDateHit(iso, m[0]);
    }
  }
  // 10/9(不与时间 18:00 冲突,分隔符不同)
  m = text.match(/(?:^|[^\d])(\d{1,2})\/(\d{1,2})(?![\d])/);
  if (m !== null) {
    const month: number = parseInt(m[1], 10);
    const day: number = parseInt(m[2], 10);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      const year: number = yearForMonthDay(month, day, today);
      const iso: string = year.toString() + '-' + pad2(month) + '-' + pad2(day);
      if (isValidISODate(iso)) {
        return makeDateHit(iso, m[0].replace(/^[^\d]/, ''));
      }
    }
  }

  /* 优先级 2:相对月 ------------------------------------------------ */
  m = text.match(/(\d{1,2})\s*个?\s*月\s*(?:之?后|以后|后)/);
  if (m !== null) {
    return makeDateHit(addMonthsClamped(today, parseInt(m[1], 10)), m[0]);
  }

  /* 优先级 3:相对周 ------------------------------------------------ */
  m = text.match(/(\d{1,2})\s*(?:个)?\s*(?:周|星期|礼拜)\s*(?:之?后|以后|后)/);
  if (m !== null) {
    return makeDateHit(addDays(today, parseInt(m[1], 10) * 7), m[0]);
  }

  /* 优先级 4:相对天 ------------------------------------------------ */
  m = text.match(/(\d{1,3})\s*天\s*(?:之?后|以后|后)/);
  if (m !== null) {
    return makeDateHit(addDays(today, parseInt(m[1], 10)), m[0]);
  }

  /* 优先级 5:关键词(今晚 > 今天/明天…) ----------------------------- */
  // 注意顺序:「今天晚上」必须先于「今天」判定
  m = text.match(/今[天日]晚上?|今晚(?:晚些时候|稍后)?/);
  if (m !== null) {
    const evening: DateHit = { when: 'evening', date: null, matched: m[0] };
    return evening;
  }
  m = text.match(/大后天/);
  if (m !== null) {
    return makeDateHit(addDays(today, 3), m[0]);
  }
  m = text.match(/后天/);
  if (m !== null) {
    return makeDateHit(addDays(today, 2), m[0]);
  }
  m = text.match(/明天|明日/);
  if (m !== null) {
    return makeDateHit(addDays(today, 1), m[0]);
  }
  m = text.match(/今天|今日/);
  if (m !== null) {
    const todayHit: DateHit = { when: 'today', date: null, matched: m[0] };
    return todayHit;
  }
  // 周末:最近的周六
  m = text.match(/(?:这个|本)?(?:周|星期|礼拜)末/);
  if (m !== null) {
    return makeDateHit(nearestSaturday(today), m[0]);
  }
  // 暂缓
  m = text.match(/将来某天|某天|有空再说/);
  if (m !== null) {
    const somedayHit: DateHit = { when: 'someday', date: null, matched: m[0] };
    return somedayHit;
  }
  // 下下周X / 下下周X
  m = text.match(/(下{1,3})(?:周|星期|礼拜)([一二三四五六日天])/);
  if (m !== null) {
    const weeks: number = m[1].length + 1; // "下"=下周偏移1;"下下"=2
    return makeDateHit(nextWeekday(today, m[2], weeks), m[0]);
  }
  // 下周 / 下个星期(不带星期几)→ 下周一
  m = text.match(/(下周|下个?星期|下个?礼拜)(?![一二三四五六日天])/);
  if (m !== null) {
    return makeDateHit(nextWeekday(today, '一', 1), m[0]);
  }
  // 这周X / 本周X / 周X / 星期X / 礼拜X
  m = text.match(/(?:这|本)?(?:周|星期|礼拜)([一二三四五六日天])/);
  if (m !== null) {
    return makeDateHit(thisOrNextWeekday(today, m[1]), m[0]);
  }

  return null;
}

function makeDateHit(iso: string, matched: string): DateHit {
  const hit: DateHit = { when: 'date', date: iso, matched: matched };
  return hit;
}

/** M月D日:若今年该日期已过,则取明年(与 UI 直觉一致) */
function yearForMonthDay(month: number, day: number, today: string): number {
  const year: number = parseInt(today.substring(0, 4), 10);
  const iso: string = year.toString() + '-' + pad2(month) + '-' + pad2(day);
  if (iso < today) {
    return year + 1;
  }
  return year;
}

/** 最近的周六(今天就是周六则取今天之后的周六之外,按契约"最近的周六") */
function nearestSaturday(today: string): string {
  const cur: number = weekdayIndex(today); // 0=周日 … 6=周六
  let delta: number = (6 - cur + 7) % 7;
  if (delta === 0) {
    delta = 7; // 今天已是周六 → 取下一个周六
  }
  return addDays(today, delta);
}

/** 本周内未过则本周,否则下周(契约 §5「星期」) */
function thisOrNextWeekday(today: string, cn: string): string {
  const map: Map<string, number> = new Map<string, number>();
  map.set('一', 1);
  map.set('二', 2);
  map.set('三', 3);
  map.set('四', 4);
  map.set('五', 5);
  map.set('六', 6);
  map.set('日', 0);
  map.set('天', 0);
  const target: number = map.has(cn) ? (map.get(cn) as number) : 1;
  const cur: number = weekdayIndex(today);
  let delta: number = (target - cur + 7) % 7;
  if (delta === 0) {
    delta = 7; // 就是今天 → 取下周同一天(避免"周五"在周五当天变成今天)
  }
  return addDays(today, delta);
}

/** 带"下"的周偏移:weekOffset=1 表示下周 */
function nextWeekday(today: string, cn: string, weekOffset: number): string {
  const map: Map<string, number> = new Map<string, number>();
  map.set('一', 1);
  map.set('二', 2);
  map.set('三', 3);
  map.set('四', 4);
  map.set('五', 5);
  map.set('六', 6);
  map.set('日', 0);
  map.set('天', 0);
  const target: number = map.has(cn) ? (map.get(cn) as number) : 1;
  const cur: number = weekdayIndex(today);
  let delta: number = (target - cur + 7) % 7;
  // 本周内该天已过(或就是今天)则顺延一周,再叠加 weekOffset-1
  if (delta === 0) {
    delta = 7;
  }
  delta += (weekOffset - 1) * 7;
  return addDays(today, delta);
}

/* --------------------------------------------------------------- 时间匹配 */

function matchTime(text: string): TimeHit | null {
  let m: RegExpMatchArray | null = null;
  let hour: number = -1;
  let minute: number = 0;
  let matched: string = '';

  // 18:00 / 18:00:00(只取前两位)
  m = text.match(/(\d{1,2})\s*[:：]\s*(\d{1,2})/);
  if (m !== null) {
    hour = parseInt(m[1], 10);
    minute = parseInt(m[2], 10);
    matched = m[0];
  }
  if (hour < 0) {
    // 18点半 / 18点30分 / 18点
    m = text.match(/(\d{1,2})\s*[点時时]\s*(半|\d{1,2}\s*分?)?/);
    if (m !== null) {
      hour = parseInt(m[1], 10);
      const tail: string | undefined = m[2];
      if (tail !== undefined && tail.length > 0) {
        if (tail.indexOf('半') >= 0) {
          minute = 30;
        } else {
          minute = parseInt(tail, 10);
        }
      }
      matched = m[0];
    }
  }
  if (hour < 0) {
    // 8pm / 8 pm / 8am
    m = text.match(/(\d{1,2})\s*(am|pm|AM|PM)/);
    if (m !== null) {
      const base: number = parseInt(m[1], 10) % 12;
      const isPm: boolean = m[2].toLowerCase() === 'pm';
      hour = isPm ? base + 12 : base;
      minute = 0;
      matched = m[0];
    }
  }
  if (hour < 0) {
    return null;
  }
  if (hour > 23) {
    hour = hour % 24;
  }
  if (minute > 59) {
    minute = 59;
  }

  // 时段修饰词:紧邻时间片段之前
  const at: number = text.indexOf(matched);
  let modifier: string = '';
  if (at > 0) {
    const pre: string = text.substring(Math.max(0, at - 3), at);
    m = pre.match(/(凌晨|早上|上午|中午|下午|傍晚|晚上|夜里|夜晚)$/);
    if (m !== null) {
      modifier = m[1];
    }
  }
  if (modifier.length > 0) {
    if (modifier === '中午') {
      if (hour < 12) {
        hour = 12;
      }
    } else if (modifier === '下午' || modifier === '傍晚' || modifier === '晚上' || modifier === '夜里' || modifier === '夜晚') {
      if (hour < 12) {
        hour = hour + 12;
      }
    } else if (modifier === '凌晨') {
      if (hour === 12) {
        hour = 0;
      }
    }
    // 上午 / 早上:保持
  }

  const hit: TimeHit = { hm: pad2(hour) + ':' + pad2(minute), matched: matched, modifier: modifier };
  return hit;
}

/* --------------------------------------------------------------- 其他工具 */

/** 判断字符串里是否含任何日期/时间写法(UI 用于提示"已识别") */
export function hasTemporalHint(input: string, today: string): boolean {
  const p: ParsedInput = parseNatural(input, today);
  return p.when !== null || p.reminder !== null;
}

/** 解析结果是否为空(无日期、无时间、无标签) */
export function isPlainTitle(input: string, today: string): boolean {
  const p: ParsedInput = parseNatural(input, today);
  return p.when === null && p.reminder === null && p.tags.length === 0;
}

/** 数字字符判定(导出供测试覆盖边界) */
export function isNumericChar(ch: string): boolean {
  return isDigit(ch);
}
