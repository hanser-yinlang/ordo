//
//  InteractionStateTests.swift
//  OrdoTests
//
//  UI 规范 §5.2 / §5.3 / §5.4 的**纯状态机**用例:
//    · 长按拖拽:400ms 阈值、6pt 点击容差、松手是否写库、取消路径;
//    · 刷新控件:连续旋转(同步中)、成功 1.4s 归位、失败常驻、1.4s 防抖;
//    · 快加号集群:长按阈值与菜单动效常量(与 §5.2 表格逐条对应)。
//
//  ⚠️ 本机(Windows)没有 macOS/Swift 工具链,这些用例**无法运行**;
//     请在 macOS 上执行 `bash apps/ios/tools/verify_ios.sh`。
//

import CoreGraphics
import XCTest
// 模块名两条构建路径不同:Xcode 工程(PRODUCT_NAME=Ordo)是 `Ordo`,SwiftPM 是 `OrdoKit`。
#if canImport(OrdoKit)
@testable import OrdoKit
#else
@testable import Ordo
#endif

// MARK: - 长按拖拽(UI 规范 §5.4)

final class OrdoLongPressDragStateTests: XCTestCase {

    private let origin = OrdoDragPoint(x: 100, y: 100)

    /// 规范的三个关键数字:长按 400ms、点击容差 6pt、抬起 scale 1.02。
    func testSpecConstants() {
        XCTAssertEqual(OrdoLongPressDragState.longPressDuration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(OrdoLongPressDragState.clickSlop, 6, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.liftScale, 1.02, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.liftShadowRadius, 12, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.draggedOpacity, 0.55, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.othersShiftDuration, 0.12, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.dropDuration, 0.16, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.insertionLineHeight, 2, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Drag.insertionDotSize, 4, accuracy: 0.0001)
    }

    /// 按下 → 400ms 到点 → 进入拖拽。
    func testLongPressEntersDragging() {
        var state = OrdoLongPressDragState()
        XCTAssertTrue(state.press(at: origin))
        XCTAssertEqual(state.phase, .pressing)
        XCTAssertEqual(state.longPressFired(), .beganDragging)
        XCTAssertEqual(state.phase, .dragging)
        // 只进入一次
        XCTAssertEqual(state.longPressFired(), .none)
        XCTAssertEqual(state.release(), .ended)
        XCTAssertEqual(state.phase, .idle)
    }

    /// 移动 < 6pt 之后抬手 = 点击(不能抢走「打开详情」)。
    func testSmallMovementIsClick() {
        var state = OrdoLongPressDragState()
        _ = state.press(at: origin)
        let shouldCancelTimer = state.move(to: OrdoDragPoint(x: origin.x + 3, y: origin.y + 4))
        XCTAssertFalse(shouldCancelTimer, "5pt 位移仍在点击容差内")
        XCTAssertEqual(state.release(), .click)
    }

    /// 移动 ≥ 6pt 之后抬手 = 什么都不做(用户其实在滚动列表)。
    func testMovementBeyondSlopIsNotClick() {
        var state = OrdoLongPressDragState()
        _ = state.press(at: origin)
        let shouldCancelTimer = state.move(to: OrdoDragPoint(x: origin.x + 6, y: origin.y))
        XCTAssertTrue(shouldCancelTimer, "越界后要取消长按计时")
        XCTAssertEqual(state.longPressFired(), .none, "已经滚动就不该进入拖拽")
        XCTAssertEqual(state.release(), .none)
    }

    /// 400ms 后即使没移动也进入拖拽;此时抬手走「松手」分支(位置未变则不写库)。
    func testLongPressThenReleaseWithoutMoveDoesNotClick() {
        var state = OrdoLongPressDragState()
        _ = state.press(at: origin)
        XCTAssertEqual(state.longPressFired(), .beganDragging)
        XCTAssertEqual(state.release(), .ended)
        XCTAssertFalse(OrdoLongPressDragState.shouldCommit(sourceId: "a", targetId: "a"))
    }

    /// 取消路径:拖拽中取消 → `.cancelled`(行回原位、不写库);未进入拖拽时是空操作。
    func testCancelPaths() {
        var dragging = OrdoLongPressDragState()
        _ = dragging.press(at: origin)
        XCTAssertEqual(dragging.cancel(), .none, "还没抬起时取消不产生拖拽事件")
        XCTAssertEqual(dragging.phase, .idle)

        _ = dragging.press(at: origin)
        XCTAssertEqual(dragging.longPressFired(), .beganDragging)
        XCTAssertEqual(dragging.cancel(), .cancelled)
        XCTAssertEqual(dragging.phase, .idle)
    }

    /// 落点判定:目标为空或就是自己 → 不写库(规范 §5.4「位置未变则不写库」)。
    func testCommitRules() {
        XCTAssertTrue(OrdoLongPressDragState.shouldCommit(sourceId: "a", targetId: "b"))
        XCTAssertFalse(OrdoLongPressDragState.shouldCommit(sourceId: "a", targetId: "a"))
        XCTAssertFalse(OrdoLongPressDragState.shouldCommit(sourceId: "a", targetId: nil))
    }

    /// 拖拽中继续移动不改变阶段(也不会再触发一次进入)。
    func testMoveDuringDraggingKeepsPhase() {
        var state = OrdoLongPressDragState()
        _ = state.press(at: origin)
        _ = state.longPressFired()
        let shouldCancel = state.move(to: OrdoDragPoint(x: 40, y: 300))
        XCTAssertFalse(shouldCancel)
        XCTAssertEqual(state.phase, .dragging)
        XCTAssertEqual(state.current, OrdoDragPoint(x: 40, y: 300))
    }

    /// 拖拽结束后状态被复位,下一次按下仍是全新的手势。
    func testStateResetsAfterRelease() {
        var state = OrdoLongPressDragState()
        _ = state.press(at: origin)
        _ = state.longPressFired()
        _ = state.move(to: OrdoDragPoint(x: 20, y: 20))
        XCTAssertEqual(state.release(), .ended)
        XCTAssertNil(state.start)
        XCTAssertNil(state.current)
        XCTAssertFalse(state.didExceedSlop)
        XCTAssertTrue(state.press(at: OrdoDragPoint(x: 1, y: 1)))
    }

    /// 「点击打开详情」必须避开行内控件(复选框 / 行尾按钮组):
    /// `simultaneousGesture` 会把落在控件上的触摸一并送进来,不排除就会一次点击触发两个动作。
    func testControlLocationExcludesRowControls() {
        let frames: [String: CGRect] = [
            TodoRowView.checkboxFrameId("t1"): CGRect(x: 12, y: 100, width: 20, height: 20),
            TodoRowView.actionsFrameId("t1"): CGRect(x: 600, y: 100, width: 90, height: 28)
        ]
        // 复选框
        XCTAssertTrue(TodoRowView.isControlLocation(CGPoint(x: 20, y: 110), todoId: "t1", frames: frames))
        // 行尾按钮组
        XCTAssertTrue(TodoRowView.isControlLocation(CGPoint(x: 640, y: 114), todoId: "t1", frames: frames))
        // 标题区域 → 打开详情
        XCTAssertFalse(TodoRowView.isControlLocation(CGPoint(x: 300, y: 110), todoId: "t1", frames: frames))
        // 其它行的控件不影响这一行
        XCTAssertFalse(TodoRowView.isControlLocation(CGPoint(x: 20, y: 110), todoId: "t2", frames: frames))
    }
}

// MARK: - 刷新控件(UI 规范 §5.3)

@MainActor
final class OrdoRefreshControlTests: XCTestCase {

    private let start: Int64 = 1_759_900_000_000

    private func makeControl() -> (OrdoRefreshControl, OrdoFixedClock) {
        let clock = OrdoFixedClock(millis: start)
        return (OrdoRefreshControl(clock: clock), clock)
    }

    /// 规范数字:每圈 900ms;成功色 320ms;1.4s 归位;1.4s 防抖。
    func testSpecConstants() {
        XCTAssertEqual(OrdoMotion.Refresh.turnDuration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Refresh.successFlash, 0.32, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Refresh.resetDelay, 1.4, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Refresh.debounce, 1.4, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.Refresh.iconSize, 28, accuracy: 0.0001)
    }

    /// 同步中:图标连续旋转 + 文字「同步中…」,且按钮禁用(不可重复触发)。
    func testSyncingState() {
        let (control, _) = makeControl()
        XCTAssertEqual(control.phase, .idle)
        XCTAssertEqual(control.label, "已同步")
        XCTAssertTrue(control.canTrigger())

        XCTAssertTrue(control.begin())
        XCTAssertEqual(control.phase, .syncing)
        XCTAssertTrue(control.isSpinning)
        XCTAssertEqual(control.label, "同步中…")
        XCTAssertEqual(control.iconTint, .active)
        XCTAssertFalse(control.canTrigger())
        XCTAssertFalse(control.begin(), "同步中不能再次触发")
    }

    /// 成功:短暂 success 态 + 「已同步」,1.4s 后回到常态;期间保持禁用。
    func testSuccessThenSettle() {
        let (control, clock) = makeControl()
        _ = control.begin()
        control.finish(.synced)
        XCTAssertEqual(control.phase, .success)
        XCTAssertFalse(control.isSpinning)
        XCTAssertEqual(control.label, "已同步")
        XCTAssertEqual(control.iconTint, .success)
        XCTAssertFalse(control.canTrigger(), "结束后 1.4s 内防抖")

        control.settle()
        XCTAssertEqual(control.phase, .success, "还没到 1.4s,不应归位")

        clock.advance(by: 1_400)
        control.settle()
        XCTAssertEqual(control.phase, .idle)
        XCTAssertTrue(control.canTrigger())
    }

    /// 失败:常驻「同步失败,点击重试」+ danger 色;防抖过后仍可重试,但文案不消失。
    func testFailureIsSticky() {
        let (control, clock) = makeControl()
        _ = control.begin()
        control.finish(.failed("网络不可用"))
        XCTAssertEqual(control.phase, .failed("网络不可用"))
        XCTAssertEqual(control.label, "同步失败,点击重试")
        XCTAssertEqual(control.iconTint, .danger)
        XCTAssertEqual(control.lastFailureReason, "网络不可用")
        XCTAssertFalse(control.canTrigger())

        clock.advance(by: 1_400)
        XCTAssertTrue(control.canTrigger(), "防抖结束后必须能重试")

        control.settle()
        XCTAssertEqual(control.phase, .failed("网络不可用"), "失败态常驻,直到重试")
        XCTAssertTrue(control.begin(), "重试应被受理")
        XCTAssertEqual(control.phase, .syncing)
    }

    /// 同步协调器的状态 → 刷新结果(离线 / 还没连上云端都按失败表达)。
    func testOutcomeMapping() {
        XCTAssertEqual(OrdoRefreshOutcome.from(status: .idle), .synced)
        XCTAssertEqual(OrdoRefreshOutcome.from(status: .offline), .failed("网络不可用"))
        XCTAssertEqual(OrdoRefreshOutcome.from(status: .localOnly), .failed("尚未连接云端"))
        XCTAssertEqual(OrdoRefreshOutcome.from(status: .failed("x")), .failed("x"))
        XCTAssertEqual(OrdoRefreshOutcome.from(status: nil), .failed("同步未启用"))
    }

    /// 后台同步(状态自己变成 syncing)也要有可见反馈,且不受防抖限制。
    func testBackgroundSyncMirrors() {
        let (control, _) = makeControl()
        _ = control.begin()
        control.finish(.synced)
        XCTAssertFalse(control.canTrigger())

        control.markSyncing()
        XCTAssertEqual(control.phase, .syncing)
        XCTAssertTrue(control.isSpinning)
    }

    /// 会话/环境重建时复位,避免残留失败文案。
    func testReset() {
        let (control, _) = makeControl()
        _ = control.begin()
        control.finish(.failed("尚未连接云端"))
        control.reset()
        XCTAssertEqual(control.phase, .idle)
        XCTAssertNil(control.lastFailureReason)
        XCTAssertTrue(control.canTrigger())
    }

    /// 无障碍标签把真实原因读出来(错误不只靠颜色)。
    func testAccessibilityLabelCarriesReason() {
        let (control, _) = makeControl()
        _ = control.begin()
        control.finish(.failed("网络不可用"))
        XCTAssertTrue(control.accessibilityLabel.contains("网络不可用"))
        XCTAssertTrue(control.accessibilityLabel.contains("点击重试"))
    }
}

// MARK: - 快加号集群(UI 规范 §5.2)

final class OrdoQuickAddSpecTests: XCTestCase {

    /// §5.2 表格里的数字:直径 56、长按 400ms、按压 0.96、保持 1.06、旋转 45°、
    /// 面板 180ms / 收起 140ms、逐项错位 40ms、上移 6px。
    func testQuickAddSpecConstants() {
        XCTAssertEqual(OrdoSpacing.quickAddDiameter, 56, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.holdDuration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.pressScale, 0.96, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.pressDuration, 0.09, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.holdScale, 1.06, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.expandedRotation, 45, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.menuInitialScale, 0.9, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.menuInDuration, 0.18, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.menuOutDuration, 0.14, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.itemStagger, 0.04, accuracy: 0.0001)
        XCTAssertEqual(OrdoMotion.QuickAdd.itemOffset, 6, accuracy: 0.0001)
    }

    /// 长按 400ms 与拖拽共用同一个阈值(§5.2 与 §5.4 不许出现两个数字)。
    func testLongPressThresholdIsShared() {
        XCTAssertEqual(OrdoMotion.QuickAdd.holdDuration, OrdoMotion.Drag.longPressDuration, accuracy: 0.0001)
        // 快加号用同一个 6pt 容差判断「用户其实在滚动」
        XCTAssertEqual(OrdoMotion.Drag.clickSlop, 6, accuracy: 0.0001)
    }

    /// 动效令牌不得为负(避免误写)。登录页已随 v1.3 移除,这里只校验仍在使用的令牌。
    func testMotionTokensAreSane() {
        XCTAssertGreaterThan(OrdoMotion.base, 0)
        XCTAssertGreaterThan(OrdoMotion.fast, 0)
        XCTAssertGreaterThan(OrdoMotion.slow, 0)
        XCTAssertGreaterThan(OrdoMotion.QuickAdd.menuMinWidth, 0)
        XCTAssertGreaterThan(OrdoMotion.QuickAdd.menuItemHeight, 0)
        XCTAssertGreaterThan(OrdoSpacing.minTouchTarget, 0)
        XCTAssertGreaterThan(OrdoRadius.quickAddMenu, 0)
        XCTAssertGreaterThan(OrdoRadius.quickAddItem, 0)
    }
}
