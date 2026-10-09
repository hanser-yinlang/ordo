package com.ordo.core.seed

import com.ordo.core.model.Area
import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.ChecklistItem
import com.ordo.core.model.Heading
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Project
import com.ordo.core.model.RepeatFreq
import com.ordo.core.model.RepeatMode
import com.ordo.core.model.RepeatRule
import com.ordo.core.model.Status
import com.ordo.core.model.Tag
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.util.OrdoDate

/**
 * 演示数据(与 Web 原型同规模):4 区域 / 5 项目 / 3 标题 / 7 标签 / 30+ 待办 / 3 日历事件。
 * 首次启动时写入本地库,便于验收各清单、清单项、重复、提醒、逾期与日志簿。
 */
object SeedData {

    const val DEVICE_SEED_KEY = "ordo.seeded"

    fun events(today: String = OrdoDate.todayISO()): List<CalendarEvent> = listOf(
        CalendarEvent("ev-1", "产品评审会", "${today}T10:00", "${today}T11:00", "工作"),
        CalendarEvent("ev-2", "与设计师 1:1", "${today}T14:30", "${today}T15:00", "工作"),
        CalendarEvent("ev-3", "健身", "${today}T19:00", "${today}T20:00", "个人")
    )

    /** @param now 当前 epoch 毫秒(用于 createdAt/updatedAt/completedAt);@param today 本地今天 */
    fun demo(now: Long, today: String): OrdoSnapshot {
        val d = { days: Int -> OrdoDate.plusDays(today, days) }
        val hour = 3_600_000L

        val areas = listOf(
            Area("a-work", "工作", "#5B5BD6", 0, updatedAt = now),
            Area("a-life", "个人生活", "#2FA36B", 1, updatedAt = now),
            Area("a-health", "健康", "#E5533D", 2, updatedAt = now),
            Area("a-study", "学习", "#D98324", 3, updatedAt = now)
        )

        val projects = listOf(
            Project(
                "p-launch", "Q4 产品发布", "a-work",
                note = "目标:12 月初完成 4.0 正式版发布。\n# 关键节点\n- 设计冻结:11/20\n- 灰度发布:11/28",
                When.ANYTIME, order = 0, createdAt = now, updatedAt = now
            ),
            Project("p-web", "网站改版", "a-work", note = "官网信息架构重构。", order = 1, createdAt = now, updatedAt = now),
            Project("p-move", "搬家准备", "a-life", note = "月底前搬完,优先处理大件家具与水电网过户。", order = 2, createdAt = now, updatedAt = now),
            Project("p-read", "读书计划", "a-study", note = "每两周读完一本。", order = 3, createdAt = now, updatedAt = now),
            Project("p-run", "马拉松训练", "a-health", note = "目标:半马 1 小时 55 分。", order = 4, createdAt = now, updatedAt = now)
        )

        val headings = listOf(
            Heading("h-design", "p-launch", "设计", 0, updatedAt = now),
            Heading("h-dev", "p-launch", "开发", 1, updatedAt = now),
            Heading("h-release", "p-launch", "上线", 2, updatedAt = now)
        )

        val tags = listOf(
            Tag("tag-1", "重要", "#E5533D", now),
            Tag("tag-2", "紧急", "#D98324", now),
            Tag("tag-3", "电话", "#2FA36B", now),
            Tag("tag-4", "外出", "#5B5BD6", now),
            Tag("tag-5", "家里", "#8E8E93", now),
            Tag("tag-6", "阅读", "#7C7CF0", now),
            Tag("tag-7", "深度工作", "#1C1B19", now)
        )

        val todos = mutableListOf<Todo>()
        var seq = 0
        fun todo(
            title: String,
            `when`: When = When.ANYTIME,
            date: String? = null,
            reminder: String? = null,
            deadline: String? = null,
            tags: List<String> = emptyList(),
            checklist: List<ChecklistItem> = emptyList(),
            projectId: String? = null,
            areaId: String? = null,
            headingId: String? = null,
            repeat: RepeatRule? = null,
            note: String = "",
            status: Status = Status.OPEN,
            completedAt: Long? = null
        ) {
            seq += 1
            todos.add(
                Todo(
                    id = "seed-t" + seq.toString().padStart(2, '0'),
                    title = title, note = note,
                    `when` = `when`, date = date, reminder = reminder, deadline = deadline,
                    tags = tags, checklist = checklist,
                    projectId = projectId, areaId = areaId, headingId = headingId,
                    repeat = repeat, order = seq,
                    status = status, createdAt = now - seq * hour, updatedAt = now - seq * hour,
                    completedAt = completedAt
                )
            )
        }

        // —— 今天 ——
        todo("整理本周产品评审纪要", When.TODAY, projectId = "p-launch", headingId = "h-dev", tags = listOf("深度工作"), note = "重点记录 **接口联调** 的结论。")
        todo("回复张伟关于接口联调的邮件", When.TODAY, reminder = "${today}T11:00", tags = listOf("紧急", "深度工作"))
        todo("写周报并同步给团队", When.TODAY, projectId = "p-launch", headingId = "h-dev")
        todo("预约牙医洗牙", When.TODAY, reminder = "${today}T15:00", tags = listOf("电话"))
        todo("提交报销单", When.TODAY, deadline = d(-1), reminder = "${d(-1)}T17:00", tags = listOf("紧急"), note = "上月的差旅发票,截止日期已经过了。")
        todo(
            "每周复盘与计划", When.TODAY, tags = listOf("深度工作"),
            repeat = RepeatRule(RepeatFreq.WEEKLY, 1, RepeatMode.FIXED)
        )

        // —— 今晚 ——
        todo("读《设计心理学》第 3 章", When.EVENING, projectId = "p-read", tags = listOf("阅读"))
        todo("复盘今天的面试记录", When.EVENING, projectId = "p-launch", headingId = "h-dev")

        // —— 收件箱 ——
        todo("了解竞品 X 的定价策略", When.INBOX, tags = listOf("深度工作"))
        todo("给妈妈挑生日礼物", When.INBOX, tags = listOf("外出"))
        todo("研究一下看板视图的交互方式", When.INBOX)

        // —— 计划 ——
        todo("准备产品评审会材料", When.DATE, date = d(1), reminder = "${d(1)}T09:30", projectId = "p-launch", headingId = "h-dev", tags = listOf("重要"))
        todo("与设计师确认图标规范", When.DATE, date = d(1), projectId = "p-launch", headingId = "h-design", tags = listOf("重要"))
        todo("输出灰度发布检查清单", When.DATE, date = d(2), projectId = "p-launch", headingId = "h-release")
        todo("提交季报数据", When.DATE, date = d(3), deadline = d(5), tags = listOf("重要", "深度工作"), note = "数据源:`finance/q3.csv`")
        todo("预约搬家公司上门估价", When.DATE, date = d(4), deadline = d(6), projectId = "p-move", tags = listOf("电话"))
        todo("团建活动报名", When.DATE, date = d(6), tags = listOf("外出"))
        todo("交房租", When.DATE, date = d(5), repeat = RepeatRule(RepeatFreq.MONTHLY, 1, RepeatMode.FIXED))
        todo("整理书单并下单", When.DATE, date = d(11), projectId = "p-read")

        // —— 随时 ——
        todo("给网站改版写内容清单", When.ANYTIME, projectId = "p-web")
        todo("整理云盘里的旧照片", When.ANYTIME, tags = listOf("家里"))
        todo("把跑步鞋换成新的一双", When.ANYTIME, projectId = "p-run")
        todo("补充家庭药箱", When.ANYTIME, tags = listOf("家里"), checklist = listOf(
            ChecklistItem("ck-1", "创可贴", true),
            ChecklistItem("ck-2", "退烧药", false),
            ChecklistItem("ck-3", "体温计", false)
        ))
        todo("研究下一台笔记本的配置", When.ANYTIME)

        // —— 某天 ——
        todo("学一门乐器", When.SOMEDAY)
        todo("去北海道看雪", When.SOMEDAY, tags = listOf("外出"))
        todo("把家里的书整理成电子目录", When.SOMEDAY, tags = listOf("家里"))

        // —— 搬家项目的清单 ——
        todo("联系搬家公司比价", When.ANYTIME, projectId = "p-move", checklist = listOf(
            ChecklistItem("ck-4", "蓝犀牛", true),
            ChecklistItem("ck-5", "货拉拉", false),
            ChecklistItem("ck-6", "自如搬家", false)
        ))
        todo("水电网过户", When.ANYTIME, projectId = "p-move", tags = listOf("电话"))
        todo("打包厨房用品", When.DATE, date = d(8), projectId = "p-move", tags = listOf("家里"))

        // —— 训练计划 ——
        todo("周二间歇跑 8×400m", When.ANYTIME, projectId = "p-run", repeat = RepeatRule(RepeatFreq.WEEKLY, 1, RepeatMode.FIXED))
        todo("周日长距离 15km", When.ANYTIME, projectId = "p-run")

        // —— 日志簿(已完成) ——
        todo("完成 4.0 需求评审", When.ANYTIME, projectId = "p-launch", headingId = "h-design", status = Status.DONE, completedAt = now - 26 * hour)
        todo("备份手机照片", When.ANYTIME, status = Status.DONE, completedAt = now - 30 * hour)
        todo("预约体检", When.ANYTIME, tags = listOf("电话"), status = Status.DONE, completedAt = now - 50 * hour)
        todo("整理上周会议纪要", When.ANYTIME, projectId = "p-launch", status = Status.DONE, completedAt = now - 74 * hour)
        todo("退订不用的会员", When.ANYTIME, status = Status.CANCELED, completedAt = now - 80 * hour)

        return OrdoSnapshot(
            schemaVersion = com.ordo.core.model.ORDO_SCHEMA_VERSION,
            serverSeq = 0,
            areas = areas,
            projects = projects,
            headings = headings,
            todos = todos,
            tags = tags
        )
    }
}
