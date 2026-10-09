/**
 * 可观测性与运维测试:
 *  1. `GET /metrics` —— Prometheus 文本格式与必需指标(ops 速率 / WS 连接数 /
 *     提醒投递数 / 仓储降级状态 / 限流命中数)
 *  2. 结构化日志(JSON 行)与**脱敏**:token / 口令 / 备注正文绝不出现
 *  3. 墓碑清理定时任务:独立周期、日志、指标、错误不抛出
 */
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { WebSocket } from 'ws';
import { baseConfig, http, makeServer, makeTodo, metricSum, metricValue, nextOpId, parsePrometheusText, sleep, type ServerContext } from './helpers';
import { METRIC, Metrics, createMetrics } from '../src/observability/metrics';
import { redactUrl } from '../src/observability/logging';
import { TombstonePurger } from '../src/services/tombstone-purger';
import { MemoryRepository } from '../src/repo/memory';
import type { Repository } from '../src/repo/types';

/* ============================================================================
 * 1. Metrics 注册表本身
 * ==========================================================================*/

describe('Metrics 注册表与 Prometheus 文本格式', () => {
  it('计数器累加、label 分组、仪表盘覆盖', () => {
    const m = new Metrics();
    m.registerCounter('a_total', 'help a');
    m.registerGauge('b', 'help b');
    m.inc('a_total');
    m.inc('a_total', {}, 4);
    m.inc('a_total', { reason: 'stale' });
    m.set('b', 7);
    assert.equal(m.value('a_total'), 5);
    assert.equal(m.value('a_total', { reason: 'stale' }), 1);
    assert.equal(m.value('b'), 7);
  });

  it('未注册的指标写入会抛错(防止打错字静默丢指标)', () => {
    const m = new Metrics();
    assert.throws(() => m.inc('nope_total'), /未注册的计数器/);
    assert.throws(() => m.set('nope', 1), /未注册的仪表盘/);
  });

  it('render() 输出合法的 HELP/TYPE/样本行,且转义 label', () => {
    const m = new Metrics();
    // Prometheus 文本里 HELP 中的反斜杠要转义、换行要转成 \n;
    // 注意"双引号在 # HELP 行里不需要转义"(它只在 label 值里需要)
    m.registerCounter('x_total', 'help with "quotes" and \\backslash\nsecond line');
    m.inc('x_total', { path: '/a"b\\c' });
    const text = m.render();
    const lines = text.split('\n');

    assert.equal(lines[0], '# HELP x_total help with "quotes" and \\\\backslash\\nsecond line');
    assert.equal(lines[1], '# TYPE x_total counter');
    assert.equal(lines[2], 'x_total{path="/a\\"b\\\\c"} 1');
    assert.match(text, /ordo_uptime_seconds \d/);

    // 关键不变量:HELP 里的换行必须被转义,不能让一条注释裂成两行
    for (const line of text.trimEnd().split('\n')) {
      assert.ok(line.startsWith('#') || /^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^}]*\})? -?[\d.eE+-]+$/.test(line), `非法行:${line}`);
    }

    // 标签值必须能被解析器原样还原
    const samples = parsePrometheusText(text);
    assert.equal(metricValue(samples, 'x_total', { path: '/a"b\\c' }), 1, 'label 转义必须可逆');
  });

  it('无样本的指标也会输出 0,便于 Prometheus 侧看到指标存在', () => {
    const m = createMetrics({ storage: 'memory' });
    const text = m.render();
    assert.match(text, /ordo_sync_ops_pushed_total 0/);
    assert.match(text, /ordo_reminders_delivered_total 0/);
    assert.match(text, /ordo_rate_limited_total 0/);
  });

  it('仓储降级状态与类型标签', () => {
    const normal = createMetrics({ storage: 'postgres', degraded: false });
    assert.match(normal.render(), /ordo_storage_degraded 0/);
    assert.match(normal.render(), /ordo_storage_info\{storage="postgres"\} 1/);

    const degraded = createMetrics({ storage: 'memory', degraded: true });
    assert.match(degraded.render(), /ordo_storage_degraded 1/);
    assert.match(degraded.render(), /ordo_storage_info\{storage="memory"\} 1/);
  });

  it('WS 连接数走实时 collector(不是累计值)', () => {
    let connections = 0;
    const m = createMetrics({ storage: 'memory', wsConnections: () => connections });
    assert.match(m.render(), /ordo_ws_connections 0/);
    connections = 3;
    assert.match(m.render(), /ordo_ws_connections 3/);
  });

  it('redactUrl 去掉查询串(WS 的 ?token= 不能进日志)', () => {
    assert.equal(redactUrl('/v1/ws?token=super-secret'), '/v1/ws');
    assert.equal(redactUrl('/v1/sync/pull?sinceSeq=1&limit=2'), '/v1/sync/pull');
    assert.equal(redactUrl('/v1/health'), '/v1/health');
    assert.equal(redactUrl(undefined), '');
  });
});

/* ============================================================================
 * 2. /metrics 端到端 + 日志脱敏(真实 HTTP + WS)
 * ==========================================================================*/

describe('可观测性端到端:/metrics 与日志脱敏', () => {
  let server: ServerContext;
  const SECRET_PASSWORD = 'S3cret-Password-Do-Not-Log';
  const SECRET_NOTE = 'CONFIDENTIAL-NOTE-BODY-正文-DO-NOT-LOG';
  const email = `obs_${Date.now()}@example.com`;
  let token = '';
  let deviceId = '';

  before(async () => {
    server = await makeServer({
      app: { tzOffsetMinutes: 0, reminderScanMs: 50 },
      logSink: true,
      logLevel: 'info'
    });

    const reg = await http(server.baseUrl, 'POST', '/v1/auth/register', {
      body: { email, password: SECRET_PASSWORD, deviceName: 'OBS', platform: 'cli', deviceId: 'obs-device' }
    });
    assert.equal(reg.status, 201, reg.text);
    token = reg.body.accessToken;
    deviceId = reg.body.device.id;

    // 带"机密备注"的 push —— 备注正文绝不能出现在日志里
    const todo = makeTodo({ title: '带机密备注的待办', note: SECRET_NOTE, tags: ['obs'] });
    const pushed = await http(server.baseUrl, 'POST', '/v1/sync/push', {
      token,
      body: {
        deviceId,
        sinceSeq: null,
        ops: [{ opId: nextOpId('obs'), deviceId, entity: 'todo', entityId: todo.id, type: 'upsert', payload: todo, clientTs: Date.now() }]
      }
    });
    assert.equal(pushed.status, 200, pushed.text);

    // 触发各类错误路径,确保它们也不会泄漏
    await http(server.baseUrl, 'POST', '/v1/auth/login', { body: { email, password: SECRET_PASSWORD } });
    await http(server.baseUrl, 'POST', '/v1/auth/login', { body: { email, password: 'wrong-password-value' } });
    await http(server.baseUrl, 'GET', '/v1/sync/snapshot'); // 401
    await http(server.baseUrl, 'GET', '/v1/sync/pull?sinceSeq=0&limit=10', { token }); // 200

    // WS 握手把 access token 放在查询串里 —— 最容易泄漏的一条路径
    const ws = new WebSocket(`${server.wsUrl}?token=${encodeURIComponent(token)}`);
    await new Promise<void>((resolve) => {
      ws.once('open', () => resolve());
      ws.once('error', () => resolve());
      setTimeout(resolve, 3000);
    });
    await sleep(200);
    ws.close();
    await sleep(200);
  });

  after(async () => {
    await server.close();
  });

  it('GET /metrics 返回 Prometheus 文本(正确 content-type)', async () => {
    const res = await http(server.baseUrl, 'GET', '/metrics');
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type') ?? '', /text\/plain; version=0\.0\.4/);
    assert.match(res.text, /# TYPE ordo_sync_ops_pushed_total counter/);

    // /v1/metrics 是同一份指标(排除随时间和请求数变化的项:uptime 与 http_requests)
    const alias = await http(server.baseUrl, 'GET', '/v1/metrics');
    assert.equal(alias.status, 200);
    const stable = (text: string): string =>
      text
        .split('\n')
        .filter((l) => !l.startsWith('ordo_uptime_seconds') && !l.startsWith('ordo_http_requests_total'))
        .join('\n');
    assert.equal(stable(alias.text), stable(res.text));
  });

  it('必需指标齐全:ops 速率 / WS 连接数 / 提醒投递 / 仓储降级 / 限流命中', async () => {
    const res = await http(server.baseUrl, 'GET', '/metrics');
    for (const name of [
      'ordo_sync_ops_pushed_total',
      'ordo_sync_ops_rejected_total',
      'ordo_sync_push_requests_total',
      'ordo_sync_pull_requests_total',
      'ordo_sync_pull_ops_total',
      'ordo_sync_seq_gap_total',
      'ordo_sync_op_too_large_total',
      'ordo_ws_connections',
      'ordo_ws_connections_opened_total',
      'ordo_ws_connections_closed_total',
      'ordo_ws_connections_rejected_total',
      'ordo_ws_messages_sent_total',
      'ordo_reminders_delivered_total',
      'ordo_reminder_scans_total',
      'ordo_reminders_pending',
      'ordo_tombstones_purged_total',
      'ordo_tombstone_purge_runs_total',
      'ordo_rate_limited_total',
      'ordo_rate_limit_checks_total',
      'ordo_http_requests_total',
      'ordo_storage_degraded',
      'ordo_storage_info',
      'ordo_uptime_seconds'
    ]) {
      assert.match(res.text, new RegExp(`# (HELP|TYPE) ${name}\\b`), `缺少指标 ${name}`);
    }

    // 文本本身必须能被解析器完整解析(PromQL 抓取的前提)
    const samples = parsePrometheusText(res.text);
    assert.ok(samples.length >= 23, `应解析出至少 23 条样本,实际 ${samples.length}`);
  });

  it('指标真实反映了刚发生的流量', async () => {
    const res = await http(server.baseUrl, 'GET', '/metrics');
    const samples = parsePrometheusText(res.text);
    assert.ok(metricSum(samples, 'ordo_sync_ops_pushed_total') >= 1, '至少应记录 1 个 push 的 op');
    assert.ok(metricSum(samples, 'ordo_http_requests_total') >= 4, '应记录 HTTP 请求数');
    assert.ok(metricSum(samples, 'ordo_ws_connections_opened_total') >= 1, '应记录 WS 连接建立');
    assert.ok(metricSum(samples, 'ordo_ws_messages_sent_total') >= 1, '应记录 WS 下发(hello)');
    assert.equal(metricValue(samples, 'ordo_http_requests_total', { status: '401' }), 1, '应记录 401 状态码分桶');
    assert.equal(metricValue(samples, 'ordo_storage_info', { storage: 'memory' }), 1);
    assert.equal(metricValue(samples, 'ordo_storage_degraded'), 0);

    // 未鉴权的 WS 连接被拒 → rejected 计数
    const badWs = new WebSocket(server.wsUrl);
    await new Promise<void>((resolve) => {
      badWs.once('close', () => resolve());
      badWs.once('error', () => resolve());
      setTimeout(resolve, 2000);
    });
    const after2 = await http(server.baseUrl, 'GET', '/metrics');
    const samples2 = parsePrometheusText(after2.text);
    assert.equal(
      metricValue(samples2, 'ordo_ws_connections_rejected_total', { reason: 'AUTH_REQUIRED' }),
      1,
      '未鉴权 WS 连接应计入 rejected'
    );
  });

  it('结构化日志是 JSON 行,且绝不包含 token / 口令 / 备注正文', async () => {
    assert.ok(server.logs.length > 0, '应采集到日志');

    const raw = server.logs.join('\n');
    // 1) 每条都是合法 JSON 对象(JSON 行格式)
    let jsonLines = 0;
    for (const line of server.logs) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      assert.equal(typeof parsed.level, 'number', `日志行缺少 level:${trimmed.slice(0, 120)}`);
      assert.equal(typeof parsed.time, 'number', `日志行缺少 time:${trimmed.slice(0, 120)}`);
      jsonLines += 1;
    }
    assert.ok(jsonLines > 0, '应至少有 1 条 JSON 日志行');

    // 2) 脱敏断言:秘密一个都不能出现
    assert.equal(raw.includes(SECRET_PASSWORD), false, '口令绝不能出现在日志里');
    assert.equal(raw.includes(SECRET_NOTE), false, '备注正文绝不能出现在日志里');
    assert.equal(raw.includes('CONFIDENTIAL-NOTE-BODY'), false, '备注正文绝不能出现在日志里');
    assert.equal(raw.includes(token), false, 'access token 绝不能出现在日志里(含 WS 查询串)');
    assert.equal(raw.includes('wrong-password-value'), false, '错误口令也不能出现在日志里');
    assert.equal(raw.includes('?token='), false, 'WS 握手 URL 的查询串必须被剥离');

    // 3) 请求体与请求头整体不进日志
    assert.equal(raw.includes('refreshToken'), false, 'refreshToken 字段不应出现在日志里');
    assert.equal(raw.includes('authorization'), false, 'authorization 头不应出现在日志里');
  });

  it('日志脱敏:即便有人把秘密塞进 URL 查询串也会被剥掉', async () => {
    const before = server.logs.length;
    await http(server.baseUrl, 'GET', `/v1/health?token=${encodeURIComponent(token)}&note=LEAKY-NOTE`);
    await sleep(150);
    const added = server.logs.slice(before).join('\n');
    assert.equal(added.includes(token), false, '查询串里的 token 必须被剥离');
    assert.equal(added.includes('LEAKY-NOTE'), false, '查询串里的备注必须被剥离');
    assert.match(added + server.logs.join('\n'), /"url":"\/v1\/health"/, '日志里的 url 应为不含查询串的 pathname');
  });
});

/* ============================================================================
 * 3. 墓碑清理定时任务
 * ==========================================================================*/

/** 记录调用的假仓储(只实现 purgeTombstones) */
class FakeRepo {
  calls: number[] = [];
  result = 0;
  fail: Error | null = null;
  async purgeTombstones(olderThanMs: number): Promise<number> {
    this.calls.push(olderThanMs);
    if (this.fail) throw this.fail;
    return this.result;
  }
}

describe('墓碑清理定时任务', () => {
  const TTL = 30 * 24 * 3600_000;

  it('配置:默认周期 5 分钟;可用 TOMBSTONE_PURGE_INTERVAL_MS / TOMBSTONE_TTL_MS 覆盖', () => {
    const def = baseConfig();
    assert.equal(def.tombstonePurgeIntervalMs, 5 * 60_000);
    assert.equal(def.tombstoneTtlMs, TTL);

    const custom = baseConfig({ tombstonePurgeIntervalMs: 1000, tombstoneTtlMs: 1000 });
    assert.equal(custom.tombstonePurgeIntervalMs, 1000);
    assert.equal(custom.tombstoneTtlMs, 1000);
  });

  it('runOnce 用 now - ttl 作为阈值调用仓储,并记录日志与指标', async () => {
    const repo = new FakeRepo();
    repo.result = 4;
    const metrics = createMetrics({ storage: 'memory' });
    const logs: Array<{ obj: Record<string, unknown>; msg?: string }> = [];
    const now = 1_900_000_000_000;
    const purger = new TombstonePurger(repo as unknown as Repository, baseConfig(), {
      info: (obj, msg) => logs.push({ obj, msg }),
      warn: (obj, msg) => logs.push({ obj, msg })
    }, metrics, () => now);

    const result = await purger.runOnce();
    assert.deepEqual(repo.calls, [now - TTL], '阈值必须是 now - TTL');
    assert.equal(result.purged, 4);
    assert.equal(metrics.value(METRIC.TOMBSTONES_PURGED), 4);
    assert.equal(metrics.value(METRIC.TOMBSTONE_PURGE_RUNS, { result: 'ok' }), 1);

    const entry = logs.find((l) => l.obj.event === 'tombstone_purge');
    assert.ok(entry, '应输出结构化日志(带 event 字段)');
    assert.equal(entry!.obj.purged, 4);
    assert.equal(entry!.obj.ttlMs, TTL);
    assert.equal(typeof entry!.obj.durationMs, 'number');
    assert.match(String(entry!.msg), /已清理 4 条过期墓碑/);
  });

  it('仓储报错时不抛出,只记 warn + 指标,下一轮可继续', async () => {
    const repo = new FakeRepo();
    repo.fail = new Error('数据库暂时不可用');
    const metrics = createMetrics({ storage: 'memory' });
    const warns: Record<string, unknown>[] = [];
    const purger = new TombstonePurger(
      repo as unknown as Repository,
      baseConfig(),
      { info: () => undefined, warn: (obj) => warns.push(obj) },
      metrics
    );

    const result = await purger.runOnce(); // 不得抛出
    assert.equal(result.purged, 0);
    assert.equal(metrics.value(METRIC.TOMBSTONE_PURGE_ERRORS), 1);
    assert.equal(metrics.value(METRIC.TOMBSTONE_PURGE_RUNS, { result: 'error' }), 1);
    assert.equal(warns[0]?.event, 'tombstone_purge_failed');
    assert.match(String(warns[0]?.error), /数据库暂时不可用/);

    // 恢复后下一轮正常
    repo.fail = null;
    repo.result = 2;
    const second = await purger.runOnce();
    assert.equal(second.purged, 2);
    assert.equal(purger.runCount, 2);
  });

  it('start/stop:按配置周期自动触发;interval<=0 时不启动', async () => {
    const repo = new FakeRepo();
    const purger = new TombstonePurger(repo as unknown as Repository, baseConfig({ tombstonePurgeIntervalMs: 40 }));

    purger.start();
    assert.equal(purger.started, true);
    await sleep(150);
    purger.stop();
    assert.equal(purger.started, false);
    const callsAfterStop = repo.calls.length;
    assert.ok(callsAfterStop >= 2, `周期 40ms 应在 150ms 内跑多轮,实际 ${callsAfterStop}`);
    await sleep(100);
    assert.equal(repo.calls.length, callsAfterStop, 'stop() 后不应再触发');

    const disabled = new TombstonePurger(repo as unknown as Repository, baseConfig({ tombstonePurgeIntervalMs: 0 }));
    disabled.start();
    assert.equal(disabled.started, false, 'interval<=0 不应启动定时器');
    disabled.stop();
  });

  it('push 路径不再顺带清理墓碑,清理只由定时任务完成', async () => {
    const repo = new MemoryRepository();
    await repo.init();
    const user = 'u-tombstone';
    // 直接写一条"很久以前"的墓碑(超过 30 天 TTL)
    const ancient = Date.now() - 40 * 24 * 3600_000;
    await repo.putEntity({
      userId: user,
      entity: 'todo',
      entityId: 'old-tombstone',
      payload: { id: 'old-tombstone', deleted: true, updatedAt: ancient } as never,
      updatedAt: ancient,
      deleted: true,
      serverSeq: 0
    });

    // push 一万次也不会清理它(旧实现是 push 路径节流触发)
    const config = baseConfig();
    const { SyncService } = await import('../src/services/sync');
    const sync = new SyncService(repo, config);
    await sync.push(user, 'dev', null, []);
    assert.ok(await repo.getEntity(user, 'todo', 'old-tombstone'), 'push 不应清理墓碑');

    // 定时任务手动跑一轮 → 被清理,并记录指标
    const metrics = createMetrics({ storage: 'memory' });
    const purger = new TombstonePurger(repo, config, undefined, metrics);
    const result = await purger.runOnce();
    assert.equal(result.purged, 1);
    assert.equal(await repo.getEntity(user, 'todo', 'old-tombstone'), null);
    assert.equal(metrics.value(METRIC.TOMBSTONES_PURGED), 1);

    await repo.close();
  });

  it('/metrics 暴露清理任务的累计值与轮次', async () => {
    const repo = new MemoryRepository();
    await repo.init();
    const metrics = createMetrics({ storage: 'memory' });
    const purger = new TombstonePurger(repo, baseConfig(), undefined, metrics);
    await purger.runOnce();
    const text = metrics.render();
    assert.match(text, /ordo_tombstones_purged_total 0/);
    assert.match(text, /ordo_tombstone_purge_runs_total\{result="ok"\} 1/);
    await repo.close();
  });
});
