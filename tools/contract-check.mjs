#!/usr/bin/env node
/**
 * Ordo 契约一致性检查(Contract Conformance Check)
 *
 * 用法:node tools/contract-check.mjs
 *
 * 作用:把 docs/03(数据模型与同步协议)与 docs/04(UI 设计规范)中的关键约定,
 * 按"该端是否应当自己实现"的适用性矩阵,逐条在源码里检索,输出一致性矩阵。
 *
 * 设计原则:
 *  - iOS / Windows / Android 消费 KMP 共享核心,业务枚举、NLP、实体字段由核心提供,
 *    因此这些项在这些端标为 "–"(不适用),只在鸿蒙(独立实现)与核心自身检查。
 *  - 匹配与引号无关:同时兼容 "inbox" / 'inbox' / `inbox`。
 *  - 它不能替代编译与单元测试,只用于发现"某端漏了某个枚举值/错误码/设计令牌"这类漂移。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const PLATFORMS = [
  { key: 'core', label: '共享核心', dir: 'shared/core/src' },
  { key: 'server', label: '后端', dir: 'server/src' },
  { key: 'android', label: 'Android', dir: 'apps/android' },
  { key: 'ios', label: 'iOS', dir: 'apps/ios' },
  { key: 'harmony', label: '鸿蒙', dir: 'apps/harmony' },
  { key: 'windows', label: 'Windows', dir: 'apps/windows' }
];

/**
 * 适用性矩阵:每个检查组在哪些端"应当自己实现"。
 * core = 共享核心负责;iOS/Windows/Android 消费核心,故多数业务组不适用。
 */
const APPLIES = {
  'field': ['core', 'server', 'android', 'harmony'],          // 实体字段:核心定义;Android/鸿蒙各自映射到本地库;后端存储
  'enum': ['core', 'server', 'harmony'],                       // 枚举 wire 值:核心定义;鸿蒙独立实现;后端要校验
  'route': ['core', 'android', 'ios', 'harmony', 'windows'],  // 路由:每端 UI 自己的导航
  'nlp': ['core', 'harmony'],                                  // 中文 NLP:核心实现;iOS/Windows/Android 复用;鸿蒙重写
  'api': ['core', 'server', 'android', 'ios', 'harmony', 'windows'], // 网络:每端都要实现客户端;核心定义 DTO
  'store': ['core', 'server', 'android', 'harmony', 'windows'],// 本地/远端存储;iOS 用 SwiftData 亦实现,故也纳入
  'sec': ['core', 'server', 'android', 'ios', 'harmony', 'windows'],
  'ui': ['android', 'ios', 'harmony', 'windows']               // 设计令牌:仅客户端
};
// iOS 的本地存储同样要实现 outbox/tombstone/kv,故单独补回
APPLIES.store.push('ios');

/** 逐检查项的适用端覆盖(优先于组矩阵):核心不实现 HTTP/深链,后端不实现深链 */
const ONLY = {
  'api:endpoints': ['server', 'android', 'ios', 'harmony', 'windows'],
  'api:ws': ['server', 'android', 'ios', 'harmony', 'windows'],
  'api:errors': ['server', 'android', 'ios', 'harmony', 'windows'],
  'sec:deeplink': ['android', 'ios', 'harmony', 'windows'],
  // §7.6:会话键名是客户端概念(服务端不存它);guest/upgrade 的 URL 路径在客户端,核心只有接口名
  'session:key': ['core', 'android', 'ios', 'harmony', 'windows'],
  // §7.6.5 邮箱验证码:契约 v1.4(§7.6.6)已把登录从客户端移除,接口只在**服务端**保留,
  // 因此这几项只对服务端适用;客户端只保留 guest/refresh(见 session:guest / sec:tokens)。
  'session:emailcode': ['server'],
  'session:emaillogin': ['server'],
  // 只有服务端持有验证码表与 HMAC 逻辑(§7.6.5 安全条款)
  'session:codehash': ['server'],
  'session:retryafter': ['server']
};

const SKIP_DIRS = new Set(['node_modules', 'build', '.gradle', '.git', 'dist', 'oh_modules', 'Pods', '.idea', 'schemas']);
const TEXT_EXT = new Set(['.kt', '.kts', '.swift', '.ets', '.ts', '.tsx', '.js', '.mjs', '.json', '.json5', '.xml', '.plist', '.md', '.java', '.yaml', '.yml']);

function readAll(dir) {
  const abs = path.join(ROOT, dir);
  if (!fs.existsSync(abs)) return null;
  const chunks = [];
  let files = 0;
  const walk = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        walk(path.join(current, entry.name));
      } else {
        if (!TEXT_EXT.has(path.extname(entry.name).toLowerCase())) continue;
        try {
          chunks.push(fs.readFileSync(path.join(current, entry.name), 'utf8'));
          files++;
        } catch { /* 忽略 */ }
      }
    }
  };
  walk(abs);
  // 归一化:去掉引号与反引号,使 "inbox" / 'inbox' / `inbox` 等价
  const text = chunks.join('\n').replace(/["'`]/g, '');
  return { text, files };
}

const CHECKS = [
  // anyOf: true 表示"列表内任一命中即通过"(用于同一字段的多种命名风格)
  { id: 'field:reminder', desc: '待办字段 reminder(提醒)', needles: ['reminder'] },
  { id: 'field:deadline', desc: '待办字段 deadline(截止)', needles: ['deadline'] },
  { id: 'field:checklist', desc: '待办字段 checklist(清单)', needles: ['checklist'] },
  { id: 'field:headingId', desc: '待办字段 headingId(标题归属)', needles: ['headingId', 'heading_id'], anyOf: true },
  { id: 'field:completedAt', desc: '字段 completedAt(完成时间)', needles: ['completedAt', 'completed_at'], anyOf: true },
  { id: 'field:updatedAt', desc: '字段 updatedAt(版本戳)', needles: ['updatedAt', 'updated_at'], anyOf: true },
  { id: 'field:deleted', desc: '字段 deleted(软删除)', needles: ['deleted'] },

  { id: 'enum:when', desc: 'when 取值 inbox/today/evening/anytime/someday/date', needles: ['inbox', 'today', 'evening', 'anytime', 'someday', 'date'] },
  { id: 'enum:status', desc: 'status 取值 open/done/canceled', needles: ['open', 'done', 'canceled'] },
  { id: 'enum:repeatFreq', desc: '重复频率 daily/weekly/monthly/yearly', needles: ['daily', 'weekly', 'monthly', 'yearly'] },
  { id: 'enum:repeatMode', desc: '重复模式 fixed/afterCompletion', needles: ['fixed', 'afterCompletion'] },

  { id: 'route:lists', desc: '六个内置清单路由', needles: ['inbox', 'today', 'upcoming', 'anytime', 'someday', 'logbook'] },
  { id: 'route:scopes', desc: '项目/区域/标签/搜索路由', needles: ['project', 'area', 'tag', 'search'] },

  { id: 'nlp:relative', desc: '中文相对日期词(明天/后天/今天/今晚)', needles: ['明天', '后天', '今天', '今晚'] },
  { id: 'nlp:weekday', desc: '中文星期/相对周', needles: ['星期', '周'] },
  { id: 'nlp:time', desc: '时间解析(点/半/时段)', needles: ['半', '下午', '晚上'] },
  { id: 'nlp:tag', desc: '#标签解析', needles: ['tags'] },

  // v1.4(§7.6.6):客户端不再实现 register/login/email-code,只用 guest + refresh ——
  // 故这里改用 /v1/auth/guest 作为"每端都要有的鉴权端点";login/refresh 由服务端单独覆盖。
  { id: 'api:endpoints', desc: 'HTTP 端点', needles: ['/v1/sync/push', '/v1/sync/pull', '/v1/sync/snapshot', '/v1/auth/guest'] },
  { id: 'api:ws', desc: 'WebSocket 实时通道', needles: ['/v1/ws'] },
  { id: 'api:errors', desc: '错误码', needles: ['VALIDATION_FAILED', 'AUTH_REQUIRED', 'AUTH_TOKEN_EXPIRED', 'RATE_LIMITED'] },
  { id: 'api:fastlane', desc: '快车道提醒推送', needles: ['reminder'] },

  { id: 'store:outbox', desc: 'outbox 出站队列', needles: ['outbox'] },
  { id: 'store:tombstone', desc: '墓碑表/集合', needles: ['tombstone'] },
  { id: 'store:kv', desc: 'kv(deviceId / serverSeq)', needles: ['lastServerSeq', 'serverSeq', 'server_seq', 'deviceId', 'device_id'], anyOf: true },

  { id: 'sec:tokens', desc: 'access/refresh 令牌', needles: ['accessToken', 'refreshToken'] },
  { id: 'sec:deeplink', desc: 'ordo:// 深链', needles: ['ordo://'] },

  // —— 契约 §7.6 账号/会话/游客(v1.2)—— 五端一致的地基,漏一个就会出现"某端登录后数据串号"
  // 说明:会话键名是客户端概念(服务端不存它);guest/upgrade 在核心只有接口名、URL 路径在客户端,故用 anyOf。
  { id: 'session:key', desc: '§7.6.3 会话键名 ordo.session', needles: ['ordo.session'] },
  { id: 'session:guest', desc: '§7.6.2 游客登录(guest)', needles: ['guest'], anyOf: true },
  { id: 'session:upgrade', desc: '§7.6.2 游客升级(upgrade)', needles: ['upgrade'], anyOf: true },
  { id: 'session:isguest', desc: '§7.6.1 游客标记 isGuest', needles: ['isGuest', 'is_guest'], anyOf: true },
  { id: 'session:userdir', desc: '§7.6.3 本地数据按 userId 分目录', needles: ['userId'], anyOf: true },

  // —— 契约 §7.6.5 邮箱验证码登录(v1.3)——
  { id: 'session:emailcode', desc: '§7.6.5 请求验证码 /v1/auth/email/code', needles: ['/v1/auth/email/code'] },
  { id: 'session:emaillogin', desc: '§7.6.5 验证码登录 /v1/auth/email/login', needles: ['/v1/auth/email/login'] },
  { id: 'session:codehash', desc: '§7.6.5 验证码只存哈希(HMAC + email_codes)', needles: ['email_codes', 'createHmac'] },
  { id: 'session:retryafter', desc: '§7.6.5 retryAfter(60s 倒计时依据)', needles: ['retryAfter', 'retry_after'], anyOf: true },

  // 颜色只比对 6 位十六进制,兼容 Web 的 #5B5BD6 与 Kotlin 的 0xFF5B5BD6、ArkTS 的 '#5B5BD6'
  { id: 'ui:accent', desc: '强调色 #5B5BD6 / #7C7CF0', needles: ['5B5BD6', '7C7CF0'] },
  { id: 'ui:canvas', desc: '画布色 #FBFAF7 / #141416', needles: ['FBFAF7', '141416'] },
  { id: 'ui:state', desc: '状态色 逾期/今晚/成功', needles: ['E5533D', 'D98324', '2FA36B'] },
  { id: 'ui:dark', desc: '深色模式支持', needles: ['dark'] }
];

const sources = {};
for (const p of PLATFORMS) sources[p.key] = readAll(p.dir);

const results = [];
for (const check of CHECKS) {
  const group = check.id.split(':')[0];
  const applicable = ONLY[check.id] || APPLIES[group] || PLATFORMS.map((p) => p.key);
  const row = { id: check.id, desc: check.desc, cells: {} };
  for (const p of PLATFORMS) {
    const src = sources[p.key];
    if (!applicable.includes(p.key)) { row.cells[p.key] = 'n/a'; continue; }
    if (!src) { row.cells[p.key] = 'not-built'; continue; }
    const hits = check.needles.filter((n) => src.text.includes(n.replace(/["'`]/g, '')));
    const ok = check.anyOf ? hits.length > 0 : hits.length === check.needles.length;
    row.cells[p.key] = ok ? 'ok' : `缺 ${hits.length}/${check.needles.length}`;
  }
  results.push(row);
}

// ---------------------------------------------------------------- 输出
const cols = PLATFORMS.map((p) => p.key);
const width = { id: 17, desc: 36, cell: 11 };
const pad = (s, n) => {
  const str = String(s);
  const visual = [...str].reduce((acc, ch) => acc + (ch.charCodeAt(0) > 0x2e80 ? 2 : 1), 0);
  return str + ' '.repeat(Math.max(0, n - visual));
};

console.log('\nOrdo 契约一致性检查(依据 docs/03 与 docs/04)\n');
console.log(pad('检查项', width.id) + pad('说明', width.desc) + cols.map((c) => pad(c, width.cell)).join(''));
console.log('-'.repeat(width.id + width.desc + cols.length * width.cell));
let problems = 0;
const pending = [];
for (const row of results) {
  const cells = cols.map((c) => {
    const v = row.cells[c];
    if (v !== 'ok' && v !== 'n/a') { problems++; pending.push(`${row.id} @ ${c} (${v})`); }
    return pad(v === 'ok' ? '✓' : v === 'n/a' ? '–' : v, width.cell);
  });
  console.log(pad(row.id, width.id) + pad(row.desc, width.desc) + cells.join(''));
}
console.log('-'.repeat(width.id + width.desc + cols.length * width.cell));
console.log('\n扫描文件数:' + PLATFORMS.map((p) => `${p.key}=${sources[p.key] ? sources[p.key].files : 0}`).join('  '));
if (pending.length === 0) {
  console.log('\n结论:所有适用项通过 ✓');
} else {
  console.log(`\n结论:${pending.length} 处待确认:`);
  pending.forEach((x) => console.log('  · ' + x));
  console.log('\n说明:未建成的工作流会整列显示 not-built;真正的漂移看具体缺失项。');
}
console.log('');
process.exit(pending.length === 0 ? 0 : 1);
