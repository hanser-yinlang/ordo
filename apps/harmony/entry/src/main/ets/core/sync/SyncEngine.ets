/**
 * Ordo · 同步引擎
 * 契约来源:docs/03-数据模型与同步协议.md §7.1(本地优先 + outbox + serverSeq)、
 *   §7.3(合并规则由 OrdoEngine.applyRemoteOp 实现)、§7.4(HTTP 流程)、§7.5(实时通道)、§7.5 Fastlane
 *
 * 流程(syncNow):
 *   1. phase = syncing
 *   2. 取 outbox 中最多 500 条(MAX_PUSH_OPS)
 *   3. push(ops, lastServerSeq) → 确认 accepted、保留 rejected
 *   4. 应用 push 捎带返回的 ops
 *   5. 循环 pull 直到 hasMore = false,应用每条 op 后再推进 lastServerSeq(**先落地后推进,保证崩溃可重放**)
 *   6. phase = idle / offline / error / authRequired
 * SEQ_GAP:serverSeq 与本地游标不连续时重新拉全量快照,再继续拉增量。
 */

import { MAX_PULL_LIMIT, MAX_PUSH_OPS, Op, Snapshot } from '../model/Entities.ets';
import { OrdoStore } from '../storage/OrdoStore.ets';
import { nowMillis } from '../util/Ids.ets';
import { PullResult, PushResult, SyncApi } from './SyncApi.ets';
import {
  ApplyResult,
  ERR_AUTH_REQUIRED,
  ERR_AUTH_TOKEN_EXPIRED,
  ERR_NETWORK,
  ERR_SYNC_SEQ_GAP,
  OpSink,
  OpSource,
  OrdoApiError,
  SyncPhase,
  SyncStatus,
  WsReminder,
  errorText,
  idleStatus
} from './SyncTypes.ets';
import { RealtimeCallbacks, RealtimeClient } from './RealtimeClient.ets';

export type StatusListener = (s: SyncStatus) => void;

/**
 * 实时回调桥(用类实现接口,而不是对象字面量,以符合 ArkTS 的强类型要求)
 */
class RealtimeBridge implements RealtimeCallbacks {
  private engine: SyncEngine;

  constructor(engine: SyncEngine) {
    this.engine = engine;
  }

  onOps(ops: Op[], serverSeq: number): void {
    this.engine.handleRealtimeOps(ops, serverSeq);
  }

  onReminder(r: WsReminder): void {
    this.engine.handleRealtimeReminder(r);
  }

  onStateChange(connected: boolean): void {
    this.engine.handleRealtimeState(connected);
  }
}

/** 拉取页大小(契约 §7.4:pull limit ≤ 1000) */
const PULL_PAGE: number = 200;
/** 单次 syncNow 最多拉取的页数,避免弱网下长时间占用 */
const MAX_PULL_PAGES: number = 20;

export class SyncEngine {
  private api: SyncApi;
  private ws: RealtimeClient;
  private source: OpSource;
  private sink: OpSink;
  private store: OrdoStore;
  private status: SyncStatus;
  private listener: StatusListener | null;
  private reminderHandler: ((r: WsReminder) => void) | null;
  private running: boolean;
  private busy: boolean;

  constructor(api: SyncApi, ws: RealtimeClient, source: OpSource, sink: OpSink, store: OrdoStore) {
    this.api = api;
    this.ws = ws;
    this.source = source;
    this.sink = sink;
    this.store = store;
    this.status = idleStatus();
    this.listener = null;
    this.reminderHandler = null;
    this.running = false;
    this.busy = false;
  }

  setListener(l: StatusListener): void {
    this.listener = l;
    this.publish();
  }

  onReminder(cb: (r: WsReminder) => void): void {
    this.reminderHandler = cb;
  }

  getStatus(): SyncStatus {
    return this.status;
  }

  private publish(): void {
    const l: StatusListener | null = this.listener;
    if (l === null) {
      return;
    }
    const copy: SyncStatus = {
      phase: this.status.phase,
      lastServerSeq: this.status.lastServerSeq,
      pendingCount: this.status.pendingCount,
      lastErrorCode: this.status.lastErrorCode,
      lastErrorText: this.status.lastErrorText,
      lastSyncAt: this.status.lastSyncAt,
      realtimeConnected: this.status.realtimeConnected
    };
    l(copy);
  }

  private setPhase(phase: SyncPhase): void {
    this.status.phase = phase;
    this.publish();
  }

  private setError(code: string): void {
    this.status.lastErrorCode = code;
    this.status.lastErrorText = errorText(code);
  }

  private clearError(): void {
    this.status.lastErrorCode = null;
    this.status.lastErrorText = null;
  }

  /** 刷新待推送数量(状态栏展示) */
  private async refreshPending(): Promise<void> {
    try {
      const n: number = await this.store.outboxCount();
      this.status.pendingCount = n;
    } catch (e) {
      // 存储异常时保持上一个值
    }
  }

  /* ============================================================ 生命周期 */

  /** 启动:恢复令牌与游标,建立实时通道 */
  async start(): Promise<void> {
    this.running = true;
    const seqText: string | null = await this.store.getKv('lastServerSeq');
    this.status.lastServerSeq = seqText === null ? 0 : parseInt(seqText, 10);
    if (isNaN(this.status.lastServerSeq)) {
      this.status.lastServerSeq = 0;
    }
    const access: string | null = await this.store.getKv('accessToken');
    const refresh: string | null = await this.store.getKv('refreshToken');
    if (access !== null && refresh !== null && access.length > 0) {
      this.api.setTokens({ accessToken: access, refreshToken: refresh, expiresIn: 0 });
    }
    await this.refreshPending();
    this.publish();

    if (this.api.hasToken()) {
      this.ws.connect();
      this.setPhase('idle');
    } else {
      this.status.realtimeConnected = false;
      this.publish();
    }
  }

  stop(): void {
    this.running = false;
    this.ws.disconnect();
    this.status.realtimeConnected = false;
    this.setPhase('idle');
  }

  /**
   * 服务端地址变更后重新握手:按新地址重连实时通道,再做一次增量同步探活。
   * SyncApi/RealtimeClient 的地址已经由调用方换好,这里只负责重连与同步,
   * 失败不抛出(地址写错时 UI 通过 syncStatus.lastErrorText 提示)。
   */
  async restart(): Promise<void> {
    this.running = true;
    if (this.api.hasToken()) {
      this.ws.reconnectWithFreshToken();
    } else {
      this.ws.disconnect();
    }
    await this.syncNow();
  }

  /** 登录/刷新令牌后重新接入实时通道 */
  onTokensUpdated(): void {
    this.ws.reconnectWithFreshToken();
  }

  /* ============================================================== 主流程 */

  /** 写操作后调用:入队并尽快同步(本地优先,失败不影响 UI) */
  async enqueueAndSync(): Promise<void> {
    await this.refreshPending();
    if (!this.api.hasToken()) {
      this.publish();
      return;
    }
    await this.syncNow();
  }

  async syncNow(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.api.hasToken()) {
      this.setPhase('authRequired');
      this.setError(ERR_AUTH_REQUIRED);
      await this.refreshPending();
      return;
    }
    this.busy = true;
    this.setPhase('syncing');
    this.clearError();
    try {
      await this.pushOnce();
      await this.pullAll();
      this.status.lastSyncAt = nowMillis();
      this.status.lastServerSeq = this.source.getLastServerSeq();
      await this.refreshPending();
      this.setPhase('idle');
    } catch (e) {
      const err: OrdoApiError = e as OrdoApiError;
      const code: string = err !== null && err.code !== undefined ? err.code : ERR_NETWORK;
      this.setError(code);
      if (code === ERR_AUTH_REQUIRED || code === ERR_AUTH_TOKEN_EXPIRED) {
        this.setPhase('authRequired');
      } else if (code === ERR_NETWORK) {
        this.setPhase('offline');
      } else {
        this.setPhase('error');
      }
      await this.refreshPending();
    } finally {
      this.busy = false;
    }
  }

  /** 推送一次(契约 §7.4:单次 ≤ 500 ops) */
  private async pushOnce(): Promise<void> {
    const ops: Op[] = this.source.takePendingOps(MAX_PUSH_OPS);
    if (ops.length === 0) {
      return;
    }
    const result: PushResult = await this.api.push(ops, this.source.getLastServerSeq());
    if (result.accepted.length > 0) {
      this.source.confirmPushed(result.accepted);
    }
    // 超限的 op 留在 outbox 并标注(不静默丢弃)
    if (result.droppedOversize.length > 0) {
      console.error('[SyncEngine] 超限 op 未上传:' + result.droppedOversize.length.toString() + ' 条');
    }
    if (result.rejected.length > 0) {
      console.error('[SyncEngine] 被拒绝 op:' + result.rejected.length.toString() + ' 条');
    }
    this.applyBatch(result.ops);
    this.source.setLastServerSeq(result.serverSeq);
    this.status.lastServerSeq = result.serverSeq;
  }

  /** 循环拉取直到 hasMore = false */
  private async pullAll(): Promise<void> {
    let pages: number = 0;
    let hasMore: boolean = true;
    while (hasMore && pages < MAX_PULL_PAGES) {
      const localSeq: number = this.source.getLastServerSeq();
      const page: PullResult = await this.api.pull(localSeq, PULL_PAGE);
      //契约 §7.4:SEQ_GAP 检测 —— 服务端游标跳变大于返回条数说明中间有缺口
      const gap: number = page.serverSeq - localSeq;
      if (page.ops.length > 0 && gap > page.ops.length) {
        this.setError(ERR_SYNC_SEQ_GAP);
        await this.resyncSnapshot();
        pages++;
        hasMore = true;
        continue;
      }
      this.applyBatch(page.ops);
      // 先落地再推进游标:崩溃后可重放而不丢 op
      this.source.setLastServerSeq(page.serverSeq);
      this.status.lastServerSeq = page.serverSeq;
      hasMore = page.hasMore;
      pages++;
    }
  }

  /** 全量快照重拉(首次同步 / SEQ_GAP / 服务端重建) */
  async resyncSnapshot(): Promise<void> {
    const snap: Snapshot = await this.api.snapshot();
    const json: string = JSON.stringify(snap);
    // OrdoEngine.applySnapshot 会覆盖本地实体并推进 lastServerSeq
    await this.sink.applySnapshot(json);
    this.status.lastServerSeq = this.source.getLastServerSeq();
  }

  private applyBatch(ops: Op[]): void {
    if (ops === null || ops === undefined) {
      return;
    }
    for (let i = 0; i < ops.length; i++) {
      const op: Op = ops[i];
      const result: ApplyResult = this.sink.applyRemoteOp(op);
      if (result.outcome === 'invalid') {
        console.error('[SyncEngine] op 无法应用:' + result.entity + '/' + result.reason);
      }
    }
  }

  /* ============================================================ 实时回调 */

  /** 组装实时通道回调(注入给 RealtimeClient) */
  buildRealtimeCallbacks(): RealtimeCallbacks {
    const bridge: RealtimeCallbacks = new RealtimeBridge(this);
    return bridge;
  }

  /** 收到实时下发的 ops:先落地,再推进游标 */
  handleRealtimeOps(ops: Op[], serverSeq: number): void {
    this.applyBatch(ops);
    this.source.setLastServerSeq(serverSeq);
    this.status.lastServerSeq = serverSeq;
    this.refreshPending();
    this.publish();
  }

  /** 收到 Fastlane 提醒推送 */
  handleRealtimeReminder(r: WsReminder): void {
    const handler: ((r: WsReminder) => void) | null = this.reminderHandler;
    if (handler !== null) {
      handler(r);
    }
  }

  /** 实时通道连接状态变化 */
  handleRealtimeState(connected: boolean): void {
    this.status.realtimeConnected = connected;
    this.publish();
  }

  /** 拉取上限(供 UI 显示或测试引用) */
  static pullLimit(): number {
    return MAX_PULL_LIMIT;
  }
}
