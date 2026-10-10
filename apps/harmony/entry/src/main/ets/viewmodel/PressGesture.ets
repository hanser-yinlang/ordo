/**
 * Ordo · 长按手势与拖拽排序(04-UI规范 §5.2 快加号长按 400ms、§5.4 长按拖拽)
 *
 * 规范原文要点(§5.4):
 *  - 按下计时 **400ms**;移动 **< 6px 视为点击**,不进入拖拽(避免抢走"打开详情")
 *  - 进入拖拽:行抬起 scale 1.02 + 12dp 投影
 *  - 松手:落库 + 行回落;位置未变则不写库
 *  - 取消:拖回原位 / 返回键 → 行回原位,不写库
 *
 * 为什么单独抽一层:ArkUI 的 `draggable/onDragStart` 由系统在**它自己**的长按阈值上触发,
 * 端上无法保证 400ms、也无法保证 6px 的判定;而且系统拖拽一旦进入就没有"拖回原位不写库"的
 * 精确语义。这里把手势判定做成**纯状态机**,由触摸事件驱动,阈值与规范逐字一致,并且可在
 * 本机宿主机上真跑用例(见 _qa/node-harness 的 PressGesture.test)。
 */

/** 长按阈值(ms):快加号展开菜单与行拖拽共用同一个阈值(§5.2 / §5.4) */
export const LONG_PRESS_MS: number = 400;
/** 位移阈值(vp):按下后位移 < 6 视为点击,不进入拖拽 */
export const MOVE_SLOP: number = 6;

/**
 * 手势阶段:
 *  - idle      未按下
 *  - pressing  已按下,尚未到 400ms
 *  - armed     已到 400ms(快加号此刻展开菜单;行此刻"抬起")
 *  - dragging  长按后位移 ≥ 6,进入拖拽
 *  - cancelled 长按判定前位移 ≥ 6(交还给点击/滚动)
 */
export type PressPhase = 'idle' | 'pressing' | 'armed' | 'dragging' | 'cancelled';

/** 一次手势的判定结果 */
export type PressOutcome = 'none' | 'tap' | 'longPress' | 'dragCommit' | 'dragCancel';

export class PressTracker {
  private phase: PressPhase = 'idle';
  private downX: number = 0;
  private downY: number = 0;
  private lastY: number = 0;
  private downAt: number = 0;
  private moved: number = 0;
  /** 本次手势是否已经触发过长按(供"长按后不要再当点击处理"使用) */
  private fired: boolean = false;

  /** 按下:开始计时 */
  begin(x: number, y: number, now: number): void {
    this.phase = 'pressing';
    this.downX = x;
    this.downY = y;
    this.lastY = y;
    this.downAt = now;
    this.moved = 0;
    this.fired = false;
  }

  /**
   * 计时器到点(UI 在 400ms 后调用)。
   * 只有在"已按下且位移仍 < 6"时才进入 armed;返回是否刚刚进入。
   */
  hold(now: number): boolean {
    if (this.phase !== 'pressing') {
      return false;
    }
    if (now - this.downAt < LONG_PRESS_MS) {
      return false;
    }
    this.phase = 'armed';
    this.fired = true;
    return true;
  }

  /** 移动:更新位移并推进阶段 */
  move(x: number, y: number): PressPhase {
    if (this.phase !== 'pressing' && this.phase !== 'armed' && this.phase !== 'dragging') {
      return this.phase;
    }
    this.lastY = y;
    this.moved = distance(this.downX, this.downY, x, y);
    if (this.moved >= MOVE_SLOP) {
      if (this.phase === 'pressing') {
        // 长按判定前就移动了 → 这是点击/滚动,不进入拖拽(§5.4「移动 <6px 视为点击」)
        this.phase = 'cancelled';
      } else {
        this.phase = 'dragging';
      }
    }
    return this.phase;
  }

  /**
   * 抬起:给出判定。
   *  - pressing → tap(未到 400ms 就松手 = 普通点击)
   *  - armed    → tap(长按后**未移动**仍视为点击:§5.4 明说 <6px 不进入拖拽;
   *                    快加号那种"按下即出菜单"的交互走 hold() 的回调,不看这里)
   *  - dragging → dragCommit(真的拖了,由调用方决定落库)
   *  - cancelled→ none
   */
  end(): PressOutcome {
    const p: PressPhase = this.phase;
    this.phase = 'idle';
    if (p === 'dragging') {
      return 'dragCommit';
    }
    if (p === 'pressing' || p === 'armed') {
      return 'tap';
    }
    return 'none';
  }

  /** 取消(返回键 / 拖出窗口 / 拖回原位):不写库 */
  cancel(): PressOutcome {
    const wasDragging: boolean = this.phase === 'dragging' || this.phase === 'armed';
    this.phase = 'idle';
    return wasDragging ? 'dragCancel' : 'none';
  }

  getPhase(): PressPhase {
    return this.phase;
  }

  /**
   * 按下时刻(ms)。UI 用它来**精确定时**:
   * `setTimeout` 早触发几毫秒时 hold() 会如实回答"还没到 400ms",所以定时器回调里
   * 传的是 `downTime() + LONG_PRESS_MS`(见 QuickAddFab.armLongPress)。
   */
  downTime(): number {
    return this.downAt;
  }

  /** 已产生的位移(vp) */
  movedDistance(): number {
    return this.moved;
  }

  /** 相对按下点的纵向位移(vp,正数向下)。拖拽排序按它换算落点下标 */
  dy(): number {
    return this.lastY - this.downY;
  }

  /** 本次手势是否已经触发过长按(用于抑制随后的 onClick) */
  longPressFired(): boolean {
    return this.fired;
  }

  /** 读取并清除"长按已触发"标记 */
  consumeLongPress(): boolean {
    const v: boolean = this.fired;
    this.fired = false;
    return v;
  }

  isDragging(): boolean {
    return this.phase === 'dragging';
  }
}

/** 两点距离 */
function distance(x0: number, y0: number, x1: number, y1: number): number {
  const dx: number = x1 - x0;
  const dy: number = y1 - y0;
  return Math.sqrt(dx * dx + dy * dy);
}

/**
 * 四舍五入到整数,且**远离零方向**取半。
 * 不能用 `Math.round`:它对 -0.5 返回 -0(即"向上拖要过半行、向下拖只要够半行"),
 * 同一个手势在上下两个方向的手感会不一致。
 */
function roundHalfAwayFromZero(v: number): number {
  if (v >= 0) {
    return Math.floor(v + 0.5);
  }
  return Math.ceil(v - 0.5);
}

/**
 * 拖拽中的目标下标:按"行的纵向跨度"换算,并夹在 [0, count-1]。
 * 纯函数,便于用例覆盖边界(顶部/底部越界、半行取整、上下对称)。
 */
export function dragTargetIndex(startIndex: number, dy: number, rowExtent: number, count: number): number {
  if (count <= 0) {
    return 0;
  }
  const extent: number = rowExtent <= 0 ? 1 : rowExtent;
  // 过半行才算跨一行,避免"轻微抖动就换位";上下对称
  const steps: number = roundHalfAwayFromZero(dy / extent);
  let target: number = startIndex + steps;
  if (target < 0) {
    target = 0;
  }
  if (target > count - 1) {
    target = count - 1;
  }
  return target;
}

/**
 * 把 id 移动到 targetIndex,返回新的完整序列。
 *  - id 不在序列里 → null(不写库)
 *  - 位置没有变化 → null(§5.4「位置未变则不写库」)
 */
export function moveIdToIndex(ids: string[], id: string, targetIndex: number): string[] | null {
  const from: number = ids.indexOf(id);
  if (from < 0) {
    return null;
  }
  let to: number = targetIndex;
  if (to < 0) {
    to = 0;
  }
  if (to > ids.length - 1) {
    to = ids.length - 1;
  }
  if (to === from) {
    return null;
  }
  const out: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    const cur: string = ids[i];
    if (cur === id) {
      continue;
    }
    out.push(cur);
  }
  out.splice(to, 0, id);
  return out;
}
