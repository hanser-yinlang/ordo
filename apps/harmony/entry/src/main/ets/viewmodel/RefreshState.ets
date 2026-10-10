/**
 * Ordo · 刷新控件状态机(04-UI规范 §5.3「刷新控件(必须有可见效果)」)
 *
 * 规范:
 *  | 阶段   | 表现 |
 *  |---|---|
 *  | 同步中 | 图标**连续旋转**(每圈 900ms,linear,持续到结束)+ 文字「同步中…」 |
 *  | 成功   | 图标停转并短暂转 success 色(320ms)+ 文字「已同步」,1.4s 后回到常态 |
 *  | 失败   | 图标转 danger 色 + 文字「同步失败,点击重试」(常驻,直到重试) |
 *  | 同步进行中按钮禁用;结束后 1.4s 内保持禁用(防抖) |
 *
 * 抽成纯状态机的原因:`SyncEngine` 只暴露 SyncPhase(idle/syncing/offline/error/authRequired),
 * 而 UI 需要的是"转不转、什么颜色、什么文案、能不能点、什么时候回落"。这些判定含时间量
 * (900ms 一圈 / 1.4s 回落 / 1.4s 防抖),放在组件里既测不了也容易写错。
 * 本文件不依赖 ArkUI,可被宿主机直接执行(见 _qa/node-harness 的 RefreshState.test)。
 */

import { SyncPhase } from '../core/sync/SyncTypes.ets';

/** 控件自身的四态(idle = 常态) */
export type RefreshPhase = 'idle' | 'syncing' | 'success' | 'failed';

/** 文案色调:'normal' | 'success' | 'danger'(对应令牌 textSecondary / stateSuccess / stateDanger) */
export type RefreshTone = 'normal' | 'success' | 'danger';

/** 成功态/防抖保持时长(§5.3:1.4s) */
export const REFRESH_HOLD_MS: number = 1400;
/** 旋转一圈的时长(§5.3:900ms linear) */
export const REFRESH_SPIN_MS: number = 900;

export class RefreshMachine {
  private phase: RefreshPhase = 'idle';
  /** 成功态保持到该时刻 */
  private holdUntil: number = 0;
  /** 禁止点击到该时刻(同步中 / 成功后的防抖窗口) */
  private lockUntil: number = 0;

  /** 当前状态 */
  getPhase(): RefreshPhase {
    return this.phase;
  }

  /** 同步引擎状态 → 控件状态 */
  applySyncPhase(phase: SyncPhase, now: number): void {
    if (phase === 'syncing') {
      this.phase = 'syncing';
      this.lockUntil = 0;
      return;
    }
    if (phase === 'idle') {
      // 只有"刚从同步中回来"才算一次成功;启动时的初始 idle 不该冒充成功
      if (this.phase === 'syncing') {
        this.phase = 'success';
        this.holdUntil = now + REFRESH_HOLD_MS;
        this.lockUntil = now + REFRESH_HOLD_MS;
      }
      return;
    }
    // offline / error / authRequired:失败态**常驻**,直到用户重试
    this.phase = 'failed';
    this.lockUntil = 0;
    this.holdUntil = 0;
  }

  /** 用户点击刷新:立刻进入"同步中"(视觉反馈不等网络往返) */
  beginManual(now: number): void {
    this.phase = 'syncing';
    this.holdUntil = 0;
    this.lockUntil = 0;
  }

  /** 回到常态(退出登录 / 会话失效时调用,避免把上一个账号的"已同步"留在界面上) */
  reset(): void {
    this.phase = 'idle';
    this.holdUntil = 0;
    this.lockUntil = 0;
  }

  /** 时间推进:成功态到期回落常态。返回状态是否发生变化(变了 UI 才需要 bump) */
  tick(now: number): boolean {
    if (this.phase === 'success' && now >= this.holdUntil) {
      this.phase = 'idle';
      return true;
    }
    return false;
  }

  /** 是否可以点击(同步中禁用;成功态后 1.4s 内防抖禁用) */
  canTap(now: number): boolean {
    if (this.phase === 'syncing') {
      return false;
    }
    return now >= this.lockUntil;
  }

  /** 是否连续旋转(§5.3:同步中持续旋转直到结束) */
  isSpinning(): boolean {
    return this.phase === 'syncing';
  }

  /** 状态栏文案 */
  label(): string {
    if (this.phase === 'syncing') {
      return '同步中…';
    }
    if (this.phase === 'failed') {
      return '同步失败,点击重试';
    }
    return '已同步';
  }

  /** 图标/文字色调 */
  tone(): RefreshTone {
    if (this.phase === 'success') {
      return 'success';
    }
    if (this.phase === 'failed') {
      return 'danger';
    }
    return 'normal';
  }

  /** 无障碍朗读(§8:不仅靠颜色传达状态) */
  accessibilityText(): string {
    if (this.phase === 'syncing') {
      return '正在同步,请稍候';
    }
    if (this.phase === 'failed') {
      return '同步失败,点击重试';
    }
    return '已同步,点击可立即刷新';
  }
}
