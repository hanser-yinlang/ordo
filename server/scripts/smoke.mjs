/**
 * 端到端冒烟脚本(不依赖测试框架):
 *   node scripts/smoke.mjs [baseUrl]
 * 验证:健康检查 → 注册 → push(带提醒)→ WS hello/ops/reminder → pull → snapshot
 * 需要服务已在运行(默认 http://127.0.0.1:8080)。
 */
import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';

const BASE = process.argv[2] ?? 'http://127.0.0.1:8080';
const WS_BASE = BASE.replace(/^http/, 'ws');
const results = [];
const ok = (name, detail = '') => results.push(`  ✔ ${name}${detail ? ` — ${detail}` : ''}`);
const fail = (name, detail) => {
  results.push(`  ✖ ${name} — ${detail}`);
  process.exitCode = 1;
};

async function api(method, path, body, token) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      'x-ordo-schema': '1',
      ...(token ? { authorization: `Bearer ${token}` } : {})
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

const health = await api('GET', '/v1/health');
if (health.status === 200 && health.body.status === 'ok') ok('GET /v1/health', `storage=${health.body.storage}`);
else fail('GET /v1/health', JSON.stringify(health));

const email = `smoke_${Date.now()}@example.com`;
const reg = await api('POST', '/v1/auth/register', {
  email,
  password: 'password123',
  deviceName: 'smoke',
  platform: 'cli',
  deviceId: `dev_smoke_${randomUUID().slice(0, 8)}`
});
if (reg.status === 201) ok('POST /v1/auth/register', `device=${reg.body.device.id}`);
else fail('POST /v1/auth/register', JSON.stringify(reg));

const token = reg.body.accessToken;
const deviceId = reg.body.device.id;

/* WS 连接 + 等待 hello */
const wsMessages = [];
const ws = new WebSocket(`${WS_BASE}/v1/ws?token=${encodeURIComponent(token)}`);
ws.on('message', (raw) => wsMessages.push(JSON.parse(raw.toString())));
await new Promise((resolve) => ws.on('open', resolve));
ws.send(JSON.stringify({ type: 'subscribe', deviceId: 'dev_smoke_other' }));
await new Promise((r) => setTimeout(r, 400));
wsMessages.some((m) => m.type === 'hello') ? ok('WS hello', `serverSeq=${wsMessages.find((m) => m.type === 'hello').serverSeq}`) : fail('WS hello', '未收到');

/* push 一条带提醒的待办(提醒 = 当前本地分钟,扫描窗口内立即命中) */
const nowLocal = new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 16); // 服务端默认 UTC+8
const todo = {
  id: randomUUID(),
  title: '冒烟:交季度报告',
  note: '',
  when: 'today',
  date: null,
  reminder: nowLocal,
  deadline: null,
  tags: ['重要'],
  checklist: [{ id: 'c1', title: '导出数据', done: false }],
  projectId: null,
  areaId: null,
  headingId: null,
  repeat: null,
  order: 0,
  status: 'open',
  createdAt: Date.now(),
  updatedAt: Date.now(),
  completedAt: null,
  deleted: false
};
const push = await api(
  'POST',
  '/v1/sync/push',
  {
    deviceId,
    sinceSeq: 0,
    ops: [{ opId: `smoke_${randomUUID()}`, deviceId, entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo, clientTs: Date.now() }]
  },
  token
);
push.status === 200 && push.body.accepted[0]?.applied
  ? ok('POST /v1/sync/push', `serverSeq=${push.body.serverSeq}`)
  : fail('POST /v1/sync/push', JSON.stringify(push));

/* 幂等复推 */
const again = await api(
  'POST',
  '/v1/sync/push',
  {
    deviceId,
    sinceSeq: push.body.serverSeq,
    ops: [{ opId: `smoke_${randomUUID()}`, deviceId, entity: 'todo', entityId: todo.id, type: 'upsert', payload: { ...todo }, clientTs: Date.now() - 5000 }]
  },
  token
);
again.body.rejected[0]?.reason === 'stale'
  ? ok('LWW:更旧的 clientTs 被拒', 'reason=stale')
  : fail('LWW', JSON.stringify(again.body));

/* 等待 Fastlane 提醒 */
const t0 = Date.now();
let reminder;
while (Date.now() - t0 < 8000) {
  reminder = wsMessages.find((m) => m.type === 'reminder');
  if (reminder) break;
  await new Promise((r) => setTimeout(r, 200));
}
reminder ? ok('WS reminder(Fastlane)', `at=${reminder.at} title=${reminder.title}`) : fail('WS reminder', '8 秒内未收到');

wsMessages.some((m) => m.type === 'ops') ? ok('WS ops 广播') : fail('WS ops 广播', '未收到');

const pull = await api('GET', `/v1/sync/pull?sinceSeq=0&limit=10`, undefined, token);
pull.status === 200 && pull.body.ops.length >= 1 ? ok('GET /v1/sync/pull', `ops=${pull.body.ops.length}`) : fail('pull', JSON.stringify(pull));

const snap = await api('GET', '/v1/sync/snapshot', undefined, token);
snap.status === 200 && snap.body.todos.length >= 1 ? ok('GET /v1/sync/snapshot', `todos=${snap.body.todos.length}`) : fail('snapshot', JSON.stringify(snap));

const denied = await api('GET', '/v1/sync/snapshot');
denied.status === 401 && denied.body.error.code === 'AUTH_REQUIRED' ? ok('未鉴权访问被拒', '401 AUTH_REQUIRED') : fail('未鉴权访问', JSON.stringify(denied));

ws.close();
console.log(`\n冒烟结果(${BASE}):`);
console.log(results.join('\n'));
console.log(process.exitCode ? '\n存在失败项' : '\n全部通过');
