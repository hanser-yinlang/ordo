/**
 * 实时通道连接管理 —— 契约 §7.5。
 * 负责:hello/ops/reminder/ping 下发,按 userId 广播,支持排除发起设备,心跳。
 */
export interface RealtimeMessage {
  type: string;
  [key: string]: unknown;
}

export interface RealtimeClient {
  id: string;
  userId: string;
  deviceId: string | null;
  lastAck: number;
  send(payload: unknown): void;
  close(code?: number, reason?: string): void;
}

export class RealtimeService {
  private clients = new Map<string, RealtimeClient>();
  private heartbeat: NodeJS.Timeout | null = null;

  add(client: RealtimeClient): void {
    this.clients.set(client.id, client);
  }

  remove(id: string): void {
    this.clients.delete(id);
  }

  get(id: string): RealtimeClient | undefined {
    return this.clients.get(id);
  }

  countForUser(userId: string): number {
    let count = 0;
    for (const c of this.clients.values()) if (c.userId === userId) count += 1;
    return count;
  }

  totalConnections(): number {
    return this.clients.size;
  }

  /** 广播给某用户的所有连接;excludeDeviceId 用于跳过发起本次变更的设备 */
  sendToUser(userId: string, message: RealtimeMessage, excludeDeviceId?: string | null): number {
    let sent = 0;
    for (const client of this.clients.values()) {
      if (client.userId !== userId) continue;
      if (excludeDeviceId && client.deviceId === excludeDeviceId) continue;
      try {
        client.send(message);
        sent += 1;
      } catch {
        this.clients.delete(client.id);
      }
    }
    return sent;
  }

  sendOps(userId: string, serverSeq: number, ops: unknown[], excludeDeviceId?: string | null): number {
    if (ops.length === 0) return 0;
    return this.sendToUser(userId, { type: 'ops', serverSeq, ops }, excludeDeviceId);
  }

  /** Fastlane:提醒独立通道,不等待批量合并 */
  sendReminder(userId: string, reminder: { todoId: string; title: string; at: string }): number {
    return this.sendToUser(userId, {
      type: 'reminder',
      todoId: reminder.todoId,
      title: reminder.title,
      at: reminder.at
    });
  }

  broadcastPing(t: number): number {
    return this.broadcast({ type: 'ping', t });
  }

  private broadcast(message: RealtimeMessage): number {
    let sent = 0;
    for (const client of this.clients.values()) {
      try {
        client.send(message);
        sent += 1;
      } catch {
        this.clients.delete(client.id);
      }
    }
    return sent;
  }

  startHeartbeat(intervalMs = 30_000): void {
    this.stopHeartbeat();
    this.heartbeat = setInterval(() => {
      this.broadcast({ type: 'ping', t: Date.now() });
    }, intervalMs);
    // 不阻止进程退出(测试里尤其重要)
    this.heartbeat.unref?.();
  }

  stopHeartbeat(): void {
    if (this.heartbeat) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
  }

  /** 关闭所有连接(优雅停机) */
  closeAll(code = 1001, reason = 'server shutdown'): void {
    for (const client of this.clients.values()) {
      try {
        client.close(code, reason);
      } catch {
        /* 忽略 */
      }
    }
    this.clients.clear();
    this.stopHeartbeat();
  }
}
