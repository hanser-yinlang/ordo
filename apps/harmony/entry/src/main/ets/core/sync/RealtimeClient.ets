/**
 * Ordo · WebSocket 实时通道
 * 契约来源:docs/03-数据模型与同步协议.md §7.5(WebSocket 消息 + Fastlane)
 *
 * 行为:
 *  - 连接:ws(s)://…/v1/ws?token=<accessToken>,连上立刻 subscribe
 *  - 收:hello(记录 serverSeq)/ ops(回调 + 自动 ack)/ reminder(Fastlane)/ ping(回 pong)
 *  - 心跳:每 25s 发 ping,10s 内无任何消息判定断线
 *  - 重连:指数退避 1s → 30s(带 ±20% 抖动),连上后归零;disconnect() 后不再重连
 *  - 日志纪律:不打印 token 与备注正文(契约 §9)
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Op } from '../model/Entities.ets';
import { RealtimePolicy, WsReminder } from './SyncTypes.ets';

export interface RealtimeCallbacks {
  onOps(ops: Op[], serverSeq: number): void;
  onReminder(r: WsReminder): void;
  onStateChange(connected: boolean): void;
}

/** 空实现:构造 RealtimeClient 时先占位,随后用 setCallbacks 注入真正的桥 */
export class NoopRealtimeCallbacks implements RealtimeCallbacks {
  onOps(ops: Op[], serverSeq: number): void {
  }

  onReminder(r: WsReminder): void {
  }

  onStateChange(connected: boolean): void {
  }
}

export class RealtimeClient {
  private wsUrl: string;
  private deviceId: string;
  private tokenProvider: () => string | null;
  private callbacks: RealtimeCallbacks;
  private socket: webSocket.WebSocket | null;
  private connected: boolean;
  private manualClose: boolean;
  private attempt: number;
  private heartbeatTimer: number;
  private timeoutTimer: number;
  private lastMessageAt: number;
  private hasToken: boolean;

  constructor(wsUrl: string, deviceId: string, tokenProvider: () => string | null, callbacks: RealtimeCallbacks) {
    this.wsUrl = wsUrl;
    this.deviceId = deviceId;
    this.tokenProvider = tokenProvider;
    this.callbacks = callbacks;
    this.socket = null;
    this.connected = false;
    this.manualClose = false;
    this.attempt = 0;
    this.heartbeatTimer = -1;
    this.timeoutTimer = -1;
    this.lastMessageAt = 0;
    this.hasToken = false;
  }

  isConnected(): boolean {
    return this.connected;
  }

  /** 注入回调桥(SyncEngine 就绪后调用,解决循环构造) */
  setCallbacks(cb: RealtimeCallbacks): void {
    this.callbacks = cb;
  }

  /**
   * 更换服务端地址(设置页改服务器地址时调用)。
   * 地址变化才重连:先断开旧连接,再按新地址建立;地址相同时什么都不做。
   */
  setUrl(wsUrl: string): void {
    if (wsUrl === this.wsUrl) {
      return;
    }
    const wasActive: boolean = this.hasToken;
    this.disconnect();
    this.wsUrl = wsUrl;
    if (wasActive) {
      this.manualClose = false;
      this.attempt = 0;
      this.connect();
    }
  }

  /** 建立连接(幂等:已连或有令牌缺失时直接返回) */
  connect(): void {
    const token: string | null = this.tokenProvider();
    if (token === null || token.length === 0) {
      this.hasToken = false;
      return;
    }
    this.hasToken = true;
    if (this.connected) {
      return;
    }
    this.manualClose = false;
    const url: string = this.wsUrl + '?token=' + token;
    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.socket = socket;

    socket.on('open', (err: BusinessError, value: Object): void => {
      if (err !== null && err !== undefined) {
        this.scheduleReconnect();
        return;
      }
      this.connected = true;
      this.attempt = 0;
      this.lastMessageAt = Date.now();
      this.callbacks.onStateChange(true);
      this.sendRaw('{"type":"subscribe","deviceId":"' + this.deviceId + '"}');
      this.startHeartbeat();
    });

    socket.on('message', (err: BusinessError, value: Object): void => {
      if (err !== null && err !== undefined) {
        return;
      }
      this.lastMessageAt = Date.now();
      const text: string = typeof value === 'string' ? value as string : '';
      if (text.length === 0) {
        return;
      }
      this.dispatch(text);
    });

    socket.on('close', (err: BusinessError, value: Object): void => {
      this.connected = false;
      this.stopTimers();
      this.callbacks.onStateChange(false);
      if (!this.manualClose) {
        this.scheduleReconnect();
      }
    });

    // 'error' 事件的回调类型是 ErrorCallback(单参数),传两个参数会匹配不上重载
    socket.on('error', (err: BusinessError): void => {
      this.connected = false;
      this.stopTimers();
      this.callbacks.onStateChange(false);
      if (!this.manualClose) {
        this.scheduleReconnect();
      }
    });

    socket.connect(url, (err: BusinessError, ok: Object): void => {
      if (err !== null && err !== undefined) {
        this.scheduleReconnect();
      }
    });
  }

  disconnect(): void {
    this.manualClose = true;
    this.stopTimers();
    const socket: webSocket.WebSocket | null = this.socket;
    if (socket !== null) {
      socket.close((err: BusinessError, ok: Object): void => {
        // 主动关闭,忽略错误
      });
    }
    this.socket = null;
    if (this.connected) {
      this.connected = false;
      this.callbacks.onStateChange(false);
    }
  }

  ack(serverSeq: number): void {
    this.sendRaw('{"type":"ack","serverSeq":' + serverSeq.toString() + '}');
  }

  /* ------------------------------------------------------------ 消息分派 */

  private dispatch(text: string): void {
    let record: Record<string, Object> | null = null;
    try {
      record = JSON.parse(text) as Record<string, Object>;
    } catch (e) {
      return; // 非法 JSON 直接忽略
    }
    if (record === null) {
      return;
    }
    const typeValue: Object = record['type'];
    const type: string = typeof typeValue === 'string' ? typeValue as string : '';
    if (type === 'hello') {
      // 记录服务端游标;真正的 seq 落地由 SyncEngine 负责
      return;
    }
    if (type === 'ops') {
      const seqValue: Object = record['serverSeq'];
      const seq: number = typeof seqValue === 'number' ? seqValue as number : 0;
      const opsValue: Object = record['ops'];
      const ops: Op[] = opsValue === null || opsValue === undefined ? [] : opsValue as Op[];
      this.callbacks.onOps(ops, seq);
      this.ack(seq);
      return;
    }
    if (type === 'reminder') {
      const todoIdValue: Object = record['todoId'];
      const titleValue: Object = record['title'];
      const atValue: Object = record['at'];
      const r: WsReminder = {
        type: 'reminder',
        todoId: typeof todoIdValue === 'string' ? todoIdValue as string : '',
        title: typeof titleValue === 'string' ? titleValue as string : '',
        at: typeof atValue === 'string' ? atValue as string : ''
      };
      this.callbacks.onReminder(r);
      return;
    }
    if (type === 'ping') {
      this.sendRaw('{"type":"pong"}');
      return;
    }
    // 未知类型忽略(前向兼容)
  }

  private sendRaw(text: string): void {
    const socket: webSocket.WebSocket | null = this.socket;
    if (socket === null || !this.connected) {
      return;
    }
    socket.send(text, (err: BusinessError, ok: Object): void => {
      // 发送失败交给心跳超时逻辑处理
    });
  }

  /* ------------------------------------------------------------ 心跳/重连 */

  private startHeartbeat(): void {
    this.stopTimers();
    this.heartbeatTimer = setInterval((): void => {
      this.sendRaw('{"type":"ping","t":' + Date.now().toString() + '}');
    }, RealtimePolicy.HEARTBEAT_MS);
    this.timeoutTimer = setInterval((): void => {
      const idle: number = Date.now() - this.lastMessageAt;
      if (idle > RealtimePolicy.HEARTBEAT_TIMEOUT_MS) {
        this.forceReconnect();
      }
    }, RealtimePolicy.HEARTBEAT_TIMEOUT_MS);
  }

  private stopTimers(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    if (this.timeoutTimer >= 0) {
      clearInterval(this.timeoutTimer);
      this.timeoutTimer = -1;
    }
  }

  private forceReconnect(): void {
    const socket: webSocket.WebSocket | null = this.socket;
    if (socket !== null) {
      socket.close((err: BusinessError, ok: Object): void => {
        // 超时主动断开
      });
    }
    this.connected = false;
    this.stopTimers();
    this.callbacks.onStateChange(false);
    if (!this.manualClose) {
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.manualClose || !this.hasToken) {
      return;
    }
    const delay: number = RealtimePolicy.backoffDelay(this.attempt);
    this.attempt = this.attempt + 1;
    setTimeout((): void => {
      if (!this.manualClose) {
        this.connect();
      }
    }, delay);
  }

  /** 令牌更新后重新建立连接(登录/刷新后调用) */
  reconnectWithFreshToken(): void {
    this.disconnect();
    this.manualClose = false;
    this.attempt = 0;
    this.connect();
  }
}
