/**
 * Ordo · 中文自然语言解析用例(契约 §5 逐条覆盖)
 * 固定"今天"为 2026-10-08(周四),保证结果可复现。
 */

import { describe, expect, it } from '@ohos/hypium';
import { ParsedInput, parseNatural } from '../../../main/ets/core/nlp/NaturalDateParser.ets';

const TODAY: string = '2026-10-08'; // 周四

export default function naturalDateParserTest() {
  describe('NaturalDateParser', () => {

    it('parse_full_example_from_contract', 0, () => {
      // 契约 §5 原文示例:明天 18:00 交季度报告 #重要
      const p: ParsedInput = parseNatural('明天 18:00 交季度报告 #重要', TODAY);
      expect(p.cleanTitle).assertEqual('交季度报告');
      expect(p.when).assertEqual('date');
      expect(p.date).assertEqual('2026-10-09');
      expect(p.reminder).assertEqual('2026-10-09T18:00');
      expect(p.tags.length).assertEqual(1);
      expect(p.tags[0]).assertEqual('重要');
    });

    it('parse_today_and_tonight', 0, () => {
      const a: ParsedInput = parseNatural('今天 写周报', TODAY);
      expect(a.when).assertEqual('today');
      expect(a.cleanTitle).assertEqual('写周报');

      const b: ParsedInput = parseNatural('今天晚上 读书', TODAY);
      expect(b.when).assertEqual('evening');

      const c: ParsedInput = parseNatural('今晚 复盘', TODAY);
      expect(c.when).assertEqual('evening');
      expect(c.cleanTitle).assertEqual('复盘');
    });

    it('parse_relative_days', 0, () => {
      expect(parseNatural('明天 交报告', TODAY).date).assertEqual('2026-10-09');
      expect(parseNatural('后天 交报告', TODAY).date).assertEqual('2026-10-10');
      expect(parseNatural('大后天 交报告', TODAY).date).assertEqual('2026-10-11');
      const n: ParsedInput = parseNatural('3天后 交报告', TODAY);
      expect(n.when).assertEqual('date');
      expect(n.date).assertEqual('2026-10-11');
    });

    it('parse_relative_weeks_and_months', 0, () => {
      expect(parseNatural('2周后 复查', TODAY).date).assertEqual('2026-10-22');
      const m: ParsedInput = parseNatural('1个月后 续费', TODAY);
      expect(m.when).assertEqual('date');
      expect(m.date).assertEqual('2026-11-08');
    });

    it('parse_absolute_dates', 0, () => {
      expect(parseNatural('2026-12-01 交报告', TODAY).date).assertEqual('2026-12-01');
      expect(parseNatural('10月9日 交报告', TODAY).date).assertEqual('2026-10-09');
      expect(parseNatural('10月9号 交报告', TODAY).date).assertEqual('2026-10-09');
      expect(parseNatural('10/9 交报告', TODAY).date).assertEqual('2026-10-09');
    });

    it('parse_absolute_date_rolls_to_next_year', 0, () => {
      // 已过去的月日 → 明年(契约未规定,这里按 UI 直觉实现,用例固定行为)
      expect(parseNatural('1月5日 体检', TODAY).date).assertEqual('2027-01-05');
    });

    it('parse_weekday_this_or_next_week', 0, () => {
      // 2026-10-08 是周四 → 周五=10-09(本周未过)
      expect(parseNatural('周五 开会', TODAY).date).assertEqual('2026-10-09');
      // 周三已过 → 下周三 10-14
      expect(parseNatural('周三 开会', TODAY).date).assertEqual('2026-10-14');
      // 下周五 = 10-16
      expect(parseNatural('下周五 开会', TODAY).date).assertEqual('2026-10-16');
      // 下下周三 = 10-21
      expect(parseNatural('下下周三 开会', TODAY).date).assertEqual('2026-10-21');
      // 礼拜五 同周五
      expect(parseNatural('礼拜五 开会', TODAY).date).assertEqual('2026-10-09');
    });

    it('parse_weekend', 0, () => {
      // 最近的周六 = 2026-10-10
      expect(parseNatural('周末 大扫除', TODAY).date).assertEqual('2026-10-10');
      expect(parseNatural('本周末 露营', TODAY).date).assertEqual('2026-10-10');
      expect(parseNatural('这个周末 露营', TODAY).date).assertEqual('2026-10-10');
    });

    it('parse_someday', 0, () => {
      expect(parseNatural('某天 学吉他', TODAY).when).assertEqual('someday');
      expect(parseNatural('将来某天 学吉他', TODAY).when).assertEqual('someday');
      expect(parseNatural('有空再说 学吉他', TODAY).when).assertEqual('someday');
    });

    it('parse_time_variants', 0, () => {
      const a: ParsedInput = parseNatural('18:00 交报告', TODAY);
      expect(a.reminder).assertEqual('2026-10-08T18:00');
      expect(a.when).assertEqual('today'); // 契约 §5:无日期信息时 when=today

      expect(parseNatural('18点 交报告', TODAY).reminder).assertEqual('2026-10-08T18:00');
      expect(parseNatural('18点半 交报告', TODAY).reminder).assertEqual('2026-10-08T18:30');
      expect(parseNatural('8pm 交报告', TODAY).reminder).assertEqual('2026-10-08T20:00');
      expect(parseNatural('上午9点 交报告', TODAY).reminder).assertEqual('2026-10-08T09:00');
      expect(parseNatural('中午12点 吃饭', TODAY).reminder).assertEqual('2026-10-08T12:00');
      expect(parseNatural('下午3点半 开会', TODAY).reminder).assertEqual('2026-10-08T15:30');
      expect(parseNatural('晚上8点 打电话', TODAY).reminder).assertEqual('2026-10-08T20:00');
      expect(parseNatural('凌晨12点 值班', TODAY).reminder).assertEqual('2026-10-08T00:00');
    });

    it('parse_time_with_date', 0, () => {
      const p: ParsedInput = parseNatural('周五 晚上8点 聚餐', TODAY);
      expect(p.date).assertEqual('2026-10-09');
      expect(p.reminder).assertEqual('2026-10-09T20:00'); // 提醒日期取解析出的日期
      expect(p.cleanTitle).assertEqual('聚餐');
    });

    it('parse_multiple_tags', 0, () => {
      const p: ParsedInput = parseNatural('整理发票 #家里 #财务', TODAY);
      expect(p.tags.length).assertEqual(2);
      expect(p.tags[0]).assertEqual('家里');
      expect(p.tags[1]).assertEqual('财务');
      expect(p.cleanTitle).assertEqual('整理发票');
    });

    it('priority_absolute_over_keyword', 0, () => {
      // 绝对日期优先于关键词:同时出现时取绝对日期
      const p: ParsedInput = parseNatural('明天 10月20日 交报告', TODAY);
      expect(p.date).assertEqual('2026-10-20');
    });

    it('clean_title_trims_punctuation', 0, () => {
      const p: ParsedInput = parseNatural('明天,交报告。', TODAY);
      expect(p.cleanTitle).assertEqual('交报告');
    });
  });
}
