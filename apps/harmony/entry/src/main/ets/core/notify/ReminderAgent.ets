/**
 * Ordo · 到点提醒(系统级)
 * 契约来源:docs/03-数据模型与同步协议.md §2.4(reminder 字段)、§7.5(Fastlane 提醒推送);
 *          docs/04-UI设计规范.md §7(鸿蒙端后台提醒 = reminderAgentManager)
 *
 * 设计:
 *  - 本地提醒由系统代理(reminderAgentManager)负责,即使 App 未运行也能弹出通知
 *  - 每个待办最多一个提醒;notificationId 由待办 id 派生,便于幂等取消
 *  - Fastlane(WS reminder 消息)到达时用 refreshFromTodo 重新校准本地提醒时间
 *  - 不打印待办标题到日志(契约 §9:不打印备注正文;标题亦按最小化原则处理)
 */

import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Todo } from '../model/Entities.ets';
import { datePartOf, nowLocalDateTime, timePartOf } from '../util/DateUtil.ets';

/** 已发布的提醒句柄 */
export interface ScheduledReminder {
  todoId: string;
  systemId: number;
  at: string;
}

export class ReminderAgent {
  /** 待办 id → 系统提醒 id(稳定映射,保证重复发布时覆盖同一条) */
  static notificationIdOf(todoId: string): number {
    let hash: number = 0;
    for (let i = 0; i < todoId.length; i++) {
      hash = (hash * 31 + todoId.charCodeAt(i)) % 100000000;
    }
    return 100000 + (hash < 0 ? -hash : hash) % 1000000;
  }

  /** 把 "YYYY-MM-DDTHH:mm" 拆成系统需要的日期时间结构 */
  private static buildDateTime(at: string): reminderAgentManager.LocalDateTime {
    const dateISO: string = datePartOf(at);
    const hm: string = timePartOf(at);
    const y: number = parseInt(dateISO.substring(0, 4), 10);
    const m: number = parseInt(dateISO.substring(5, 7), 10);
    const d: number = parseInt(dateISO.substring(8, 10), 10);
    const hour: number = parseInt(hm.substring(0, 2), 10);
    const minute: number = parseInt(hm.substring(3, 5), 10);
    const dt: reminderAgentManager.LocalDateTime = {
      year: y,
      month: m,
      day: d,
      hour: hour,
      minute: minute,
      second: 0
    };
    return dt;
  }

  /** 提醒时间是否已过期(过期不再发布,避免发布后立刻弹出) */
  static isPast(at: string): boolean {
    return at < nowLocalDateTime();
  }

  /**
   * 为一条待办发布提醒。
   * @returns 系统提醒 id;若该待办没有提醒或时间已过,返回 -1
   */
  static async schedule(todo: Todo): Promise<number> {
    const at: string | null = todo.reminder;
    if (at === null) {
      return -1;
    }
    if (ReminderAgent.isPast(at)) {
      return -1;
    }
    const request: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: ReminderAgent.buildDateTime(at),
      title: '序 · ' + todo.title,
      content: '到点了,该做这件事了',
      notificationId: ReminderAgent.notificationIdOf(todo.id),
      snoozeTimes: 0,
      ringDuration: 5,
      actionButton: [
        {
          title: '知道了',
          type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
        }
      ],
      wantAgent: {
        pkgName: 'com.ordo.app',
        abilityName: 'EntryAbility',
        uri: 'ordo://todo/' + todo.id
      }
    };
    try {
      const id: number = await reminderAgentManager.publishReminder(request);
      return id;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      console.error('[ReminderAgent] 发布提醒失败, code=' + (err === null ? 'unknown' : err.code.toString()));
      return -1;
    }
  }

  /** 取消一条待办的提醒(幂等) */
  static async cancel(todoId: string): Promise<void> {
    const id: number = ReminderAgent.notificationIdOf(todoId);
    try {
      await reminderAgentManager.cancelReminder(id);
    } catch (e) {
      // 提醒不存在时系统会报错,这里按幂等处理
    }
  }

  /** 取消全部提醒(退出登录 / 清空数据) */
  static async cancelAll(): Promise<void> {
    try {
      const list: reminderAgentManager.ReminderRequest[] = await reminderAgentManager.getValidReminders();
      for (let i = 0; i < list.length; i++) {
        const item: reminderAgentManager.ReminderRequest = list[i];
        const notificationId: number = item.notificationId === undefined ? -1 : item.notificationId;
        if (notificationId >= 0) {
          try {
            await reminderAgentManager.cancelReminder(notificationId);
          } catch (e) {
            // 单条取消失败不影响其它
          }
        }
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      console.error('[ReminderAgent] 读取提醒列表失败, code=' + (err === null ? 'unknown' : err.code.toString()));
    }
  }

  /** 待办变更后重新校准(先取消再按需发布) */
  static async refresh(todo: Todo): Promise<number> {
    await ReminderAgent.cancel(todo.id);
    if (todo.status !== 'open' || todo.deleted) {
      return -1;
    }
    return await ReminderAgent.schedule(todo);
  }

  /** 批量校准(启动时调用:把本地库里所有未完成待办的提醒重新登记) */
  static async syncAll(todos: Todo[]): Promise<number> {
    let count: number = 0;
    await ReminderAgent.cancelAll();
    for (let i = 0; i < todos.length; i++) {
      const t: Todo = todos[i];
      if (t.status !== 'open' || t.deleted || t.reminder === null) {
        continue;
      }
      const id: number = await ReminderAgent.schedule(t);
      if (id >= 0) {
        count++;
      }
    }
    return count;
  }
}
