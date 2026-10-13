/**
 * Ordo · 本地合并类型(纯本地,v1.5)
 *
 * 原来这些类型放在 `core/sync/SyncTypes.ets` 里(和同步协议类型混在一起)。云同步整体移除后,
 * 本地引擎仍然需要"把一条 op 应用到本地实体"的结果类型(§7.3 的 LWW / 标签并集 / 清单合并 /
 * 墓碑 / 空标题视为删除),所以把它们单独留在这里,不再依赖任何同步/网络模块。
 */

import { EntityKind, Op, OpType, Tombstone } from '../model/Entities.ets';

/** 契约 §7.3 合并判定结果 */
export type ApplyOutcome = 'applied' | 'stale' | 'ignored' | 'tombstoned' | 'invalid';

export interface ApplyResult {
  outcome: ApplyOutcome;
  entity: EntityKind;
  entityId: string;
  /** 人类可读原因,便于日志与测试断言(不打印备注正文与令牌,契约 §9) */
  reason: string;
}

export function applyResult(outcome: ApplyOutcome, entity: EntityKind, entityId: string, reason: string): ApplyResult {
  const r: ApplyResult = { outcome: outcome, entity: entity, entityId: entityId, reason: reason };
  return r;
}

/**
 * 本地引擎的快照/待办读取入口(v1.5 只服务本地:导出/导入、演示数据、重置)。
 * 云同步引擎已被移除,这里不再有"推送给服务端"的语义。
 */
export interface LocalEnginePort {
  /** 取本地全量快照(JSON) */
  exportSnapshot(): string;
  /** 全量快照覆盖导入(用于"恢复示例数据"等本地操作) */
  applySnapshot(json: string): Promise<boolean>;
  /** 本地待处理 op(仅本地记账/诊断) */
  takePendingOps(limit: number): Op[];
  /** 清空已处理的 op */
  confirmPushed(opIds: string[]): void;
  /** 本地墓碑集合(契约 §7.3.5) */
  listTombstones(): Tombstone[];
  /** 生成一条 upsert op(本地记账用) */
  buildOp(entity: EntityKind, entityId: string, type: OpType): Op | null;
}
