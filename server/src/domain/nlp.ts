/**
 * 中文自然语言解析规范 NLP v1 —— 契约 §5。
 *
 * 输入示例:`明天 18:00 交季度报告 #重要`
 * 输出:`{ cleanTitle, when, date, reminder, tags }`
 *
 * 冲突优先级:绝对日期 > 相对月 > 相对周 > 相对天 > 关键词(今晚 > 今天/明天…) > 时间
 * 时段换算:上午/早上 保持;中午 → 12 点;下午/傍晚/晚上/夜里 → +12(仅当 <12);凌晨 12 点 → 0 点
 */
import { When } from './model';
import { addDaysISO, addMonthsISO, localParts, pad2, todayISO } from './time';

export interface NlpOptions {
  nowMs: number;
  tzOffsetMinutes: number;
}

export interface NlpResult {
  cleanTitle: string;
  when: When | null;
  date: string | null;
  /** 解析出的提醒(YYYY-MM-DDTHH:mm);无时间信息时为 null */
  reminder: string | null;
  tags: string[];
}

const WEEKDAY_MAP: Record<string, number> = { 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 日: 0, 天: 0 };
const TIME_MODIFIERS = ['凌晨', '早上', '上午', '中午', '下午', '傍晚', '晚上', '夜里', '夜晚'];

export function parseChineseNlp(input: string, opts: NlpOptions): NlpResult {
  const text = String(input ?? '');
  const today = todayISO(opts.nowMs, opts.tzOffsetMinutes);
  const dow = localParts(opts.nowMs, opts.tzOffsetMinutes).dow;

  const cuts: string[] = [];
  const tags: string[] = [];
  let when: When | null = null;
  let date: string | null = null;
  let time: string | null = null;

  let work = text;

  // ---- 标签:#重要(可多个) ----
  work = work.replace(/#([^\s#]+)/g, (m, name: string) => {
    tags.push(name);
    cuts.push(m);
    return m;
  });

  const cut = (s: string | undefined | null) => {
    if (s) cuts.push(s);
  };

  /**
   * 星期换算(§5):「本周内未过则本周,否则下周;带『下』按指定周偏移」。
   * 以**周一为一周之始**计算,这样「下周三」= 下周的周三,「下下周三」= 下下周的周三。
   */
  const weekdayISO = (target: number, weekOffset: number): string => {
    const mondayIndex = (dow + 6) % 7; // 周一=0 … 周日=6
    const weekStart = addDaysISO(today, -mondayIndex);
    const targetIndex = (target + 6) % 7; // 周一=0 … 周日=6
    let candidate = addDaysISO(weekStart, weekOffset * 7 + targetIndex);
    if (weekOffset === 0 && candidate < today) candidate = addDaysISO(candidate, 7);
    return candidate;
  };

  // 按优先级依次尝试,命中即停止(§5 冲突优先级)
  let m: RegExpMatchArray | null;

  // 1) 绝对日期:2026-10-09
  if ((m = work.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/))) {
    date = `${m[1]}-${pad2(Number(m[2]))}-${pad2(Number(m[3]))}`;
    when = 'date';
    cut(m[0]);
  }
  // 1) 绝对日期:10月9日 / 10月9号
  else if ((m = work.match(/(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]/))) {
    const y = Number(today.slice(0, 4));
    const candidate = `${y}-${pad2(Number(m[1]))}-${pad2(Number(m[2]))}`;
    date = candidate < today ? `${y + 1}-${pad2(Number(m[1]))}-${pad2(Number(m[2]))}` : candidate;
    when = 'date';
    cut(m[0]);
  }
  // 1) 绝对日期:10/9(排除 18:00 这类时间,以及 2026/10/9 已被上面吃掉的情况)
  else if ((m = work.match(/(?:^|[^\d:])(\d{1,2})[/](\d{1,2})(?![\d:])/))) {
    const y = Number(today.slice(0, 4));
    const candidate = `${y}-${pad2(Number(m[1]))}-${pad2(Number(m[2]))}`;
    date = candidate < today ? `${y + 1}-${pad2(Number(m[1]))}-${pad2(Number(m[2]))}` : candidate;
    when = 'date';
    cut(m[0].replace(/^[^\d]/, ''));
  }
  // 2) 相对月:N个月后
  else if ((m = work.match(/(\d{1,2})\s*个?\s*月\s*(?:之?后|以后)/))) {
    date = addMonthsISO(today, Number(m[1]));
    when = 'date';
    cut(m[0]);
  }
  // 3) 相对周:N周后 / N个星期后
  else if ((m = work.match(/(\d{1,2})\s*个?\s*(?:周|星期|礼拜)\s*(?:之?后|以后)/))) {
    date = addDaysISO(today, Number(m[1]) * 7);
    when = 'date';
    cut(m[0]);
  }
  // 3) 星期:下下周三 / 下周五 / 周五(本周内未过则本周,否则下周)
  else if ((m = work.match(/(下+)?\s*(?:周|星期|礼拜)\s*([一二三四五六日天])/))) {
    const weekOffset = m[1] ? m[1].length : 0;
    date = weekdayISO(WEEKDAY_MAP[m[2]] ?? 1, weekOffset);
    when = 'date';
    cut(m[0]);
  }
  // 4) 相对天:N天后
  else if ((m = work.match(/(\d{1,3})\s*天\s*(?:之?后|以后)/))) {
    date = addDaysISO(today, Number(m[1]));
    when = 'date';
    cut(m[0]);
  }
  // 5) 关键词:今晚 > 今天 > 明天 > 后天 > 大后天 > 周末 > 某天
  else if ((m = work.match(/(今天晚上|今晚|今夜晚些时候)/))) {
    when = 'evening';
    cut(m[0]);
  } else if ((m = work.match(/(今天|今日)/))) {
    when = 'today';
    cut(m[0]);
  } else if ((m = work.match(/(明天|明日)/))) {
    date = addDaysISO(today, 1);
    when = 'date';
    cut(m[0]);
  } else if ((m = work.match(/大后天/))) {
    date = addDaysISO(today, 3);
    when = 'date';
    cut(m[0]);
  } else if ((m = work.match(/后天/))) {
    date = addDaysISO(today, 2);
    when = 'date';
    cut(m[0]);
  } else if ((m = work.match(/(这个周末|本周末|周末)/))) {
    // 「最近的周六」(当天即周六时取当天)
    date = addDaysISO(today, (6 - dow + 7) % 7);
    when = 'date';
    cut(m[0]);
  } else if ((m = work.match(/(将来某天|某天|有空再说)/))) {
    when = 'someday';
    cut(m[0]);
  }

  // 6) 时间:18:00 / 18点 / 18点半 / 下午3点半 / 晚上8点 / 8pm
  let matched = '';
  let hour: number | null = null;
  let minute = 0;
  if ((m = work.match(/\d{1,2}\s*[:：]\s*\d{2}/))) {
    const parts = m[0].split(/[:：]/);
    hour = Number(parts[0]);
    minute = Number(parts[1]);
    matched = m[0];
  } else if ((m = work.match(/\d{1,2}\s*[点時时]\s*(?:半|\d{1,2}\s*分?)?/))) {
    const half = /\d{1,2}\s*[点時时]\s*半/.test(m[0]);
    const mins = /(\d{1,2})\s*分/.exec(m[0]);
    hour = Number(/(\d{1,2})/.exec(m[0])?.[1] ?? '0');
    minute = half ? 30 : mins ? Number(mins[1]) : 0;
    matched = m[0];
  } else if ((m = work.match(/\d{1,2}\s*(?:am|pm)/i))) {
    hour = Number(/(\d{1,2})/.exec(m[0])?.[1] ?? '0') % 12;
    minute = 0;
    if (/pm/i.test(m[0])) hour += 12;
    matched = m[0];
  }

  if (matched && hour !== null) {
    cut(matched);
    // 时段修饰词紧邻时间之前
    const at = work.indexOf(matched);
    const pre = at > 0 ? work.slice(Math.max(0, at - 4), at) : '';
    let modifier: string | null = null;
    for (const mod of TIME_MODIFIERS) {
      if (pre.endsWith(mod)) {
        modifier = mod;
        break;
      }
    }
    if (modifier) {
      cut(modifier);
      if (['下午', '傍晚', '晚上', '夜里', '夜晚'].includes(modifier) && hour < 12) hour += 12;
      else if (modifier === '中午') hour = hour < 12 ? 12 : hour;
      else if (modifier === '凌晨' && hour === 12) hour = 0;
    }
    time = `${pad2(Math.min(23, hour))}:${pad2(Math.min(59, minute))}`;
  }

  // 7) 清理标题
  let clean = work;
  for (const c of cuts) {
    if (!c) continue;
    clean = clean.split(c).join(' ');
  }
  clean = clean
    .replace(/\s{2,}/g, ' ')
    .replace(/^[\s,，、。:：;；\-—]+|[\s,，、。:：;；\-—]+$/g, '')
    .trim();

  // 8) 时间存在但没有任何日期信息 → 归入今天(§5)
  if (time && when === null) when = 'today';

  const reminder = time ? `${date ?? today}T${time}` : null;

  return { cleanTitle: clean, when, date, reminder, tags };
}
