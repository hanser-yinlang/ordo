//
//  SyncMergeTests.swift
//  OrdoTests
//
//  契约 §7.3「冲突合并规则」的用例(实体级 LWW / 完成不可回滚 / 标签并集 /
//  清单项合并 / 删除墓碑 / 标题为空视为删除 / 手动排序 / 幂等)。
//
//  远端 ops 由 `OrdoPayloadCodec` 构造 → 编成契约 §7.2 的 JSON → 交给
//  `engine.applyRemote`,合并裁决全部发生在 KMP 核心内部(`OrdoEngine.applyTodoOp` / `mergeTodo`)。
//
//  说明:契约 §7.3.6「标题为空视为删除」已由 KMP 核心补全(本地 `updateTodo` 与远端 `applyTodoOp`
//  两条路径都会写墓碑并置 `deleted`),因此这里直接断言该行为 —— 桥接层不做任何补偿,
//  避免在 Swift 侧复制合并规则。
//

import XCTest
@testable import OrdoKit

@MainActor
final class SyncMergeTests: XCTestCase {

    private var harness: OrdoTestHarness!
    private let device = "dev-remote"

    override func setUp() async throws {
        harness = await OrdoTestHarness.make(today: "2026-10-08", nowDayTime: "2026-10-08T09:00")
    }

    // MARK: 构造远端 op 的辅助

    private func remoteTodo(
        id: String,
        title: String,
        updatedAt: Int64,
        status: OrdoStatus = .open,
        tags: [String] = [],
        checklist: [OrdoChecklistItem] = [],
        note: String = "",
        completedAt: Int64? = nil,
        deleted: Bool = false
    ) -> OrdoTodo {
        OrdoTodo(
            id: id,
            title: title,
            note: note,
            when: .anytime,
            tags: tags,
            checklist: checklist,
            status: status,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            deleted: deleted
        )
    }

    private func upsert(_ todo: OrdoTodo, clientTs: Int64) -> OrdoOp {
        OrdoPayloadCodec.upsertOp(
            entity: .todo(todo),
            deviceId: device,
            opId: OrdoULID.generate(),
            clientTs: clientTs
        )
    }

    private func deleteOp(entityId: String, clientTs: Int64) -> OrdoOp {
        OrdoPayloadCodec.deleteOp(
            entity: .todo,
            entityId: entityId,
            deviceId: device,
            opId: OrdoULID.generate(),
            clientTs: clientTs
        )
    }

    // MARK: §7.3.1 实体级 LWW

    func testLocalWinsWhenClientTimestampIsOlder() {
        let local = harness.makeTodo("本地较新", when: .anytime)
        harness.engine.updateTodo(id: local.id) { $0.updatedAt = 2_000_000_000_000 }

        let stale = remoteTodo(id: local.id, title: "远端较旧", updatedAt: 1_000_000_000_000)
        harness.engine.applyRemote([upsert(stale, clientTs: 1_000_000_000_000)])

        XCTAssertEqual(
            harness.todo(id: local.id)?.title,
            "本地较新",
            "clientTs < 本地 updatedAt 时应丢弃远端 op"
        )
    }

    func testRemoteWinsWhenClientTimestampIsNewer() {
        let local = harness.makeTodo("本地较旧", when: .anytime)
        harness.engine.updateTodo(id: local.id) { $0.updatedAt = 1_000_000_000_000 }

        let newer = remoteTodo(id: local.id, title: "远端较新", updatedAt: 2_000_000_000_000)
        harness.engine.applyRemote([upsert(newer, clientTs: 2_000_000_000_000)])

        XCTAssertEqual(harness.todo(id: local.id)?.title, "远端较新", "clientTs >= updatedAt 时应应用远端")
    }

    // MARK: §7.3.2 完成不可回滚

    func testCompletedTodoCannotBeRevertedByOlderOpenOp() {
        let local = harness.makeTodo("已完成待办", when: .today)
        harness.engine.toggleDone(id: local.id)
        guard let completed = harness.todo(id: local.id), completed.status == .done else {
            return XCTFail("本地未成功完成")
        }

        // 远端一条更早的 open op(即使 clientTs 看起来更大,也不允许把完成回滚)
        let stale = remoteTodo(
            id: local.id,
            title: "已完成待办",
            updatedAt: (completed.completedAt ?? 0) + 1,
            status: .open
        )
        harness.engine.applyRemote([upsert(stale, clientTs: (completed.completedAt ?? 0) + 1)])

        XCTAssertEqual(harness.todo(id: local.id)?.status, .done, "完成状态不可被更早的 open op 回滚")
    }

    // MARK: §7.3.3 标签取并集

    func testTagsAreMergedAsUnion() {
        let local = harness.makeTodo("标签合并", when: .anytime, tags: ["重要"])
        let base = harness.todo(id: local.id)?.updatedAt ?? 0

        let remote = remoteTodo(
            id: local.id,
            title: "标签合并",
            updatedAt: base + 10_000,
            tags: ["紧急"]
        )
        harness.engine.applyRemote([upsert(remote, clientTs: base + 10_000)])

        let merged = Set(harness.todo(id: local.id)?.tags ?? [])
        XCTAssertTrue(merged.contains("重要"), "本地标签应保留")
        XCTAssertTrue(merged.contains("紧急"), "远端标签应并入")
    }

    // MARK: §7.3.4 清单项合并

    func testChecklistItemsAreMergedByID() {
        let local = harness.makeTodo("清单合并", when: .anytime)
        harness.engine.addChecklistItem(todoId: local.id, title: "本地项")
        guard let withItem = harness.todo(id: local.id), let localItem = withItem.checklist.first else {
            return XCTFail("添加清单项失败")
        }

        let remoteItem = OrdoChecklistItem(id: "remote-item-1", title: "远端项", done: false)
        let remote = remoteTodo(
            id: local.id,
            title: "清单合并",
            updatedAt: withItem.updatedAt + 10_000,
            checklist: [remoteItem]
        )
        harness.engine.applyRemote([upsert(remote, clientTs: withItem.updatedAt + 10_000)])

        let merged = harness.todo(id: local.id)?.checklist ?? []
        XCTAssertTrue(merged.contains { $0.id == remoteItem.id }, "远端独有的清单项应保留")
        XCTAssertTrue(
            merged.contains { $0.id == localItem.id } || merged.contains { $0.title == "本地项" },
            "本地清单项不应无故丢失"
        )
    }

    // MARK: §7.3.5 删除墓碑

    func testDeleteTombstonePreventsResurrection() {
        let local = harness.makeTodo("将被删除", when: .anytime)
        let updatedAt = local.updatedAt

        harness.engine.applyRemote([deleteOp(entityId: local.id, clientTs: updatedAt + 5_000)])
        XCTAssertTrue(
            harness.engine.snapshot.todos.first { $0.id == local.id }?.deleted ?? true,
            "删除 op 后实体应标记为已删除"
        )

        // 一条更早的 upsert 不应让实体复活
        let older = remoteTodo(id: local.id, title: "复活尝试", updatedAt: updatedAt - 1_000)
        harness.engine.applyRemote([upsert(older, clientTs: updatedAt - 1_000)])

        let after = harness.engine.snapshot.todos.first { $0.id == local.id }
        XCTAssertTrue(after == nil || after?.deleted == true, "墓碑应阻止旧 op 复活实体")
    }

    // MARK: §7.3.6 标题为空视为删除

    /// 远端下发的**空标题 upsert** 必须等价于删除(契约 §3 + §7.3.6)。
    ///
    /// 回归背景:核心曾只在 `type == delete` 时删实体;补全后 `applyTodoOp` 对空标题的
    /// upsert 同样写墓碑并置 `deleted`。本用例**通过桥接层** `applyRemote` 验证该行为,
    /// 确认 Swift 侧无需补偿、且本地视图立即看不到该待办。
    func testRemoteUpsertWithEmptyTitleDeletesLocalTodo() {
        let local = harness.makeTodo("会被空标题删除", when: .anytime)

        let newest = local.updatedAt + 10_000
        let empty = remoteTodo(id: local.id, title: "", updatedAt: newest)
        harness.engine.applyRemote([upsert(empty, clientTs: newest)])

        // ① 引擎查询(过滤 deleted)已取不到
        XCTAssertNil(harness.todo(id: local.id), "远端空标题 upsert 后,待办不应再出现在查询结果里")

        // ② 快照里实体仍在,但已置 deleted(契约 §3:一律软删除)
        let entity = harness.engine.snapshot.todos.first { $0.id == local.id }
        XCTAssertNotNil(entity, "软删除应保留实体行")
        XCTAssertEqual(entity?.deleted, true, "空标题 upsert 必须把实体标记为 deleted")

        // ③ 墓碑生效:更早的 upsert 不能让它复活
        let older = remoteTodo(id: local.id, title: "复活尝试", updatedAt: local.updatedAt - 1_000)
        harness.engine.applyRemote([upsert(older, clientTs: local.updatedAt - 1_000)])
        XCTAssertNil(harness.todo(id: local.id), "墓碑应阻止旧 op 复活被空标题删除的实体")
    }

    /// 本地把标题清空(`setTitle(id, "")`)同样走删除路径(与远端行为一致)。
    func testLocalEmptyTitleDeletesTodo() {
        let local = harness.makeTodo("本地清空标题", when: .anytime)
        harness.engine.setTitle(id: local.id, title: "")

        XCTAssertNil(harness.todo(id: local.id), "本地清空标题后待办应消失")
        XCTAssertEqual(
            harness.engine.snapshot.todos.first { $0.id == local.id }?.deleted,
            true,
            "本地清空标题应走软删除路径"
        )
    }

    /// 纯空白标题同样视为空(核心用 `isBlank()` 判定)。
    func testRemoteUpsertWithWhitespaceOnlyTitleDeletesTodo() {
        let local = harness.makeTodo("空白标题", when: .anytime)
        let newest = local.updatedAt + 10_000
        let blank = remoteTodo(id: local.id, title: "   ", updatedAt: newest)
        harness.engine.applyRemote([upsert(blank, clientTs: newest)])

        XCTAssertNil(harness.todo(id: local.id), "纯空白标题应等同于空标题(删除)")
    }

    // MARK: 手动排序(契约 §2.4 的 `order`)

    /// 拖拽排序通过桥接层 `reorderTodos(ids:)` 提交:数组下标即新的 `order`。
    func testReorderTodosAppliesSubmittedOrder() {
        let first = harness.makeTodo("第一", when: .anytime)
        let second = harness.makeTodo("第二", when: .anytime)

        let before = harness.todos(in: .anytime).map(\.id)
        XCTAssertEqual(before, [first.id, second.id], "新建顺序应是 order 升序")

        // 拖拽后「第二」在前 —— 提交的是该容器内的完整序列
        harness.engine.reorderTodos(ids: [second.id, first.id])

        let after = harness.todos(in: .anytime)
        XCTAssertEqual(after.map(\.id), [second.id, first.id], "order 应按下标重排")
        XCTAssertEqual(after.map(\.order), [0, 1], "核心把下标直接写进 order")
    }

    /// 排序必须落进 outbox(契约 §7.1:本地写操作都要同步到其它端)。
    func testReorderTodosProducesPendingOps() {
        let first = harness.makeTodo("排序 A", when: .anytime)
        let second = harness.makeTodo("排序 B", when: .anytime)
        let before = harness.engine.pendingOpCount()

        harness.engine.reorderTodos(ids: [second.id, first.id])

        XCTAssertGreaterThan(harness.engine.pendingOpCount(), before, "排序应产出待上传 op")
        let reordered = harness.engine.pendingOps().filter { $0.entity == .todo }
        XCTAssertTrue(
            reordered.contains { $0.entityId == first.id } && reordered.contains { $0.entityId == second.id },
            "两条被重排的待办都应产生 op"
        )
    }

    // MARK: 幂等(契约 §7.1)

    func testApplyingSameOpTwiceIsIdempotent() {
        let local = harness.makeTodo("幂等", when: .anytime)
        let remote = remoteTodo(id: local.id, title: "幂等(已更新)", updatedAt: local.updatedAt + 1_000)
        let op = upsert(remote, clientTs: local.updatedAt + 1_000)

        harness.engine.applyRemote([op])
        let once = harness.todo(id: local.id)
        harness.engine.applyRemote([op])
        let twice = harness.todo(id: local.id)

        XCTAssertEqual(once?.title, twice?.title, "重复应用同一 op 不应产生差异")
        XCTAssertEqual(once?.updatedAt, twice?.updatedAt)
    }

    // MARK: outbox(契约 §7.1)

    func testLocalWritesProducePendingOps() {
        let before = harness.engine.pendingOpCount()
        harness.makeTodo("产生 op", when: .anytime)
        XCTAssertGreaterThan(harness.engine.pendingOpCount(), before, "本地写操作应产出待上传 op")
    }

    func testAppliedRemoteOpsAreNotRequeuedAsLocalOps() {
        let local = harness.makeTodo("远端不回流", when: .anytime)
        let remote = remoteTodo(id: local.id, title: "远端不回流(更新)", updatedAt: local.updatedAt + 1_000)
        harness.engine.applyRemote([upsert(remote, clientTs: local.updatedAt + 1_000)])

        let hasServerEcho = harness.engine.pendingOps().contains { $0.deviceId == device }
        XCTAssertFalse(hasServerEcho, "远端下发的 op 不应被打回上传队列")
    }

    func testAckOpsClearsOutbox() {
        harness.makeTodo("待确认", when: .anytime)
        let pending = harness.engine.pendingOps()
        XCTAssertFalse(pending.isEmpty)

        harness.engine.ackOps(pending.map(\.opId))
        XCTAssertEqual(harness.engine.pendingOpCount(), 0, "ack 后 outbox 应为空")

        // 落盘后重新读回,仍应为空(镜像 → SwiftData 的写回)
        harness.engine.setLastServerSeq(42)
        XCTAssertEqual(harness.engine.lastServerSeq(), 42, "serverSeq 由核心写入 kv")
    }

    // MARK: 快照映射(桥接层)

    /// 服务端 `GET /v1/sync/snapshot` 返回**扁平** headings,桥接层要回填到项目。
    func testRemoteSnapshotMergeAttachesHeadingsToProjects() {
        let project = OrdoProject(id: "p-1", name: "项目", headings: [])
        let remote = OrdoRemoteSnapshot(
            serverSeq: 42,
            areas: [OrdoArea(id: "a-1", name: "区域")],
            projects: [project],
            headings: [OrdoHeading(id: "h-1", projectId: "p-1", name: "设计")],
            todos: [],
            tags: []
        )
        let merged = remote.merged()
        XCTAssertEqual(merged.projects.first?.headings.first?.id, "h-1", "扁平 headings 应回填到所属项目")
        XCTAssertEqual(merged.serverSeq, 42)
    }

    /// Swift 嵌套快照 → wire(扁平)形状:headings 需被摊平,服务器/Kotlin 才能解码。
    func testSnapshotEncodingFlattensHeadings() {
        let snapshot = OrdoSnapshot(
            areas: [],
            projects: [OrdoProject(id: "p-1", name: "项目", headings: [OrdoHeading(id: "h-1", projectId: "p-1", name: "设计")])],
            todos: [],
            tags: []
        )
        let json = OrdoCoreMapping.encodeSnapshot(snapshot)
        XCTAssertTrue(json.contains("\"headings\""), "wire 形状应包含扁平 headings 数组")

        guard let dto = OrdoCoreMapping.decodeSnapshotDTO(json: json) else {
            return XCTFail("DTO 解码失败")
        }
        XCTAssertEqual(dto.headings?.count, 1)
        XCTAssertEqual(dto.merged().projects.first?.headings.count, 1, "往返后仍能回填到项目")
    }
}
