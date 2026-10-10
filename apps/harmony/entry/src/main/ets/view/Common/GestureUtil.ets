/**
 * Ordo · 手势事件小工具(04 §5.2 快加号长按 / §5.4 长按拖拽共用)
 *
 * 取当前触点。抬指 / 取消时 `touches` 可能为空,此时用 `changedTouches` 兜底 ——
 * 少了这一层,"抬起"事件会读到 undefined 并在启动路径上崩掉。
 */

export function touchOf(event: TouchEvent): TouchObject {
  if (event.touches.length > 0) {
    return event.touches[0];
  }
  return event.changedTouches[0];
}
