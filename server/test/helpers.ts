/**
 * 测试辅助:默认使用**内存仓储**;`makePgApp()` 可换成真实执行 SQL 的 PgRepository。
 */
import type { FastifyInstance } from 'fastify';
import type { AddressInfo } from 'node:net';
import { randomUUID } from 'node:crypto';
import { buildApp, BuiltApp } from '../src/app';
import { AppConfig, loadConfig } from '../src/config';
import { Todo } from '../src/domain/model';
import { MemoryRepository } from '../src/repo/memory';
import type { Repository } from '../src/repo/types';

export interface TestContext {
  app: FastifyInstance;
  repo: Repository;
  config: AppConfig;
  built: BuiltApp;
  close(): Promise<void>;
}

export function baseConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  const config = loadConfig({
    NODE_ENV: 'test',
    JWT_SECRET: 'ordo-unit-test-secret',
    TZ_OFFSET_MINUTES: '0',
    RATE_LIMIT_ENABLED: 'false',
    LOG_LEVEL: 'silent'
  });
  return { ...config, ...overrides };
}

export async function makeApp(overrides: Partial<AppConfig> = {}): Promise<TestContext> {
  const config = baseConfig(overrides);
  const repo = new MemoryRepository();
  await repo.init();
  const built = await buildApp(config, repo, 'memory', { logger: false });
  await built.app.ready();
  return {
    app: built.app,
    repo,
    config,
    built,
    async close() {
      built.deps.reminders.stop();
      built.deps.purger.stop();
      built.deps.realtime.closeAll();
      await built.app.close();
      await repo.close();
    }
  };
}

/* ============================================================================
 * 真实 HTTP + WS 服务夹具(端到端协议测试用)
 * ==========================================================================*/

export interface ServerContext extends TestContext {
  /** http://127.0.0.1:<随机端口> */
  baseUrl: string;
  /** ws://127.0.0.1:<随机端口>/v1/ws */
  wsUrl: string;
  port: number;
  /** 收集起来的结构化日志行(仅在传 logSink 时可用) */
  logs: string[];
}

export interface ServerOptions {
  app?: Partial<AppConfig>;
  storage?: 'postgres' | 'memory';
  /** 采集 pino 输出的内存流;不传则关闭日志 */
  logSink?: boolean;
  logLevel?: string;
  /** 复用外部仓储(例如 PgRepository + pg-mem) */
  repo?: Repository;
  degraded?: boolean;
}

/**
 * 在**一个进程内**起真实 HTTP + WebSocket 服务(随机端口),
 * 供端到端协议测试使用;结束后必须 await close() 释放端口。
 */
export async function makeServer(options: ServerOptions = {}): Promise<ServerContext> {
  const config = baseConfig(options.app);
  const repo = options.repo ?? new MemoryRepository();
  if (!options.repo) await repo.init();

  const logs: string[] = [];
  const sink = options.logSink
    ? {
        write(line: string) {
          logs.push(line);
          return true;
        }
      }
    : undefined;

  const built = await buildApp(config, repo, options.storage ?? 'memory', {
    logger: options.logSink === true,
    logLevel: options.logLevel ?? 'info',
    logDestination: sink as unknown as NodeJS.WritableStream,
    degraded: options.degraded === true
  });
  await built.app.ready();
  await built.app.listen({ host: '127.0.0.1', port: 0 });
  const address = built.app.server.address() as AddressInfo;
  const baseUrl = `http://127.0.0.1:${address.port}`;

  return {
    app: built.app,
    repo,
    config,
    built,
    baseUrl,
    port: address.port,
    wsUrl: `ws://127.0.0.1:${address.port}/v1/ws`,
    logs,
    async close() {
      built.deps.reminders.stop();
      built.deps.purger.stop();
      built.deps.realtime.closeAll();
      await built.app.close();
      await repo.close();
    }
  };
}

export interface HttpResult<T = any> {
  status: number;
  headers: Headers;
  body: T;
  text: string;
}

/** 真实 HTTP 调用(走 socket,不经过 app.inject) */
export async function http<T = any>(
  baseUrl: string,
  method: string,
  path: string,
  options: { body?: unknown; token?: string; deviceId?: string; headers?: Record<string, string> } = {}
): Promise<HttpResult<T>> {
  const hasBody = options.body !== undefined;
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      // 只在真的带 body 时声明 content-type:空 body + application/json 会被
      // Fastify 判为非法 JSON(400),这不是我们要测的行为
      ...(hasBody ? { 'content-type': 'application/json' } : {}),
      'x-ordo-schema': '1',
      ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
      ...(options.deviceId ? { 'x-ordo-device': options.deviceId } : {}),
      ...options.headers
    },
    body: hasBody ? JSON.stringify(options.body) : undefined
  });
  const text = await res.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: res.status, headers: res.headers, body: body as T, text };
}

let emailSeq = 0;
export function uniqueEmail(prefix = 'user'): string {
  emailSeq += 1;
  return `${prefix}${emailSeq}.${Math.random().toString(36).slice(2, 8)}@example.com`;
}

export interface RegisteredUser {
  email: string;
  password: string;
  userId: string;
  deviceId: string;
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export async function registerUser(
  app: FastifyInstance,
  options: { email?: string; password?: string; deviceId?: string } = {}
): Promise<RegisteredUser> {
  const email = options.email ?? uniqueEmail();
  const password = options.password ?? 'password123';
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { email, password, deviceName: '测试设备', platform: 'cli', deviceId: options.deviceId }
  });
  if (res.statusCode !== 201) throw new Error(`注册失败(${res.statusCode}):${res.body}`);
  const body = res.json() as {
    user: { id: string };
    device: { id: string };
    accessToken: string;
    refreshToken: string;
    expiresIn: number;
  };
  return {
    email,
    password,
    userId: body.user.id,
    deviceId: body.device.id,
    accessToken: body.accessToken,
    refreshToken: body.refreshToken,
    expiresIn: body.expiresIn
  };
}

export function authHeaders(token: string, deviceId?: string): Record<string, string> {
  const headers: Record<string, string> = { authorization: `Bearer ${token}`, 'x-ordo-schema': '1' };
  if (deviceId) headers['x-ordo-device'] = deviceId;
  return headers;
}

/** 生成符合契约 §2.4 的完整 todo payload(显式传 undefined 的字段不会覆盖默认值) */
export function makeTodo(overrides: Partial<Todo> = {}): Todo {
  const base: Todo = {
    id: randomUUID(),
    title: '交季度报告',
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
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000,
    completedAt: null,
    deleted: false
  };
  const defined = Object.fromEntries(Object.entries(overrides).filter(([, v]) => v !== undefined));
  return { ...base, ...(defined as Partial<Todo>) };
}

export function newId(): string {
  return randomUUID();
}

let opSeq = 0;
export function nextOpId(prefix = 'op'): string {
  opSeq += 1;
  return `${prefix}_${Date.now().toString(36)}_${opSeq}_${Math.random().toString(36).slice(2, 8)}`;
}

export interface OpInput {
  opId: string;
  deviceId?: string | null;
  entity: string;
  entityId: string;
  type: 'upsert' | 'delete';
  payload: unknown;
  clientTs: number;
}

export function makeOp(partial: Partial<OpInput> & { entity: string; entityId: string; payload: unknown }): OpInput {
  return {
    opId: partial.opId ?? nextOpId(),
    deviceId: partial.deviceId ?? null,
    entity: partial.entity,
    entityId: partial.entityId,
    type: partial.type ?? 'upsert',
    payload: partial.payload,
    clientTs: partial.clientTs ?? Date.now()
  };
}

export async function push(
  app: FastifyInstance,
  token: string,
  deviceId: string,
  ops: OpInput[],
  sinceSeq: number | null = null
): Promise<{ statusCode: number; body: any }> {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/sync/push',
    headers: authHeaders(token, deviceId),
    payload: { deviceId, sinceSeq, ops }
  });
  return { statusCode: res.statusCode, body: res.statusCode < 400 ? res.json() : res.json() };
}

export async function snapshot(app: FastifyInstance, token: string): Promise<any> {
  const res = await app.inject({ method: 'GET', url: '/v1/sync/snapshot', headers: authHeaders(token) });
  if (res.statusCode !== 200) throw new Error(`snapshot 失败:${res.body}`);
  return res.json();
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** 等待条件成立(用于 WS 消息断言) */
export async function waitFor(condition: () => boolean, timeoutMs = 6000, stepMs = 50): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await sleep(stepMs);
  }
  return condition();
}

/* ============================================================================
 * Prometheus 文本解析(测试断言用)
 * ==========================================================================*/

export interface MetricSample {
  name: string;
  labels: Record<string, string>;
  value: number;
}

/**
 * 解析 Prometheus 文本展示格式。
 * 之所以不用正则:`ordo_http_requests_total` 这类指标有多条带不同 label 的样本,
 * 必须能求和/按 label 查,单条正则很容易误判。
 */
export function parsePrometheusText(text: string): MetricSample[] {
  const out: MetricSample[] = [];
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(-?[\d.eE+-]+)$/.exec(line);
    if (!match) continue;
    out.push({ name: match[1], labels: match[2] ? parseLabels(match[2]) : {}, value: Number(match[3]) });
  }
  return out;
}

function parseLabels(raw: string): Record<string, string> {
  const labels: Record<string, string> = {};
  const body = raw.slice(1, -1);
  const re = /([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(body)) !== null) {
    labels[match[1]] = match[2].replace(/\\(.)/g, '$1');
  }
  return labels;
}

/** 取某指标所有样本值之和(无样本返回 0) */
export function metricSum(samples: MetricSample[], name: string): number {
  return samples.filter((s) => s.name === name).reduce((sum, s) => sum + s.value, 0);
}

/** 取某指标在指定 label 条件下的值(取第一条匹配) */
export function metricValue(
  samples: MetricSample[],
  name: string,
  labels: Record<string, string> = {}
): number | null {
  const keys = Object.keys(labels);
  const hit = samples.find(
    (s) => s.name === name && keys.every((k) => s.labels[k] === labels[k])
  );
  return hit ? hit.value : null;
}
