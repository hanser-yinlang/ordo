/**
 * WebSocket 实时通道 —— 契约 §7.5
 *   WS /v1/ws?token=<accessToken>
 *   服务端 → 客户端:hello / ops / reminder / ping
 *   客户端 → 服务端:subscribe / ack / pong(另兼容 ping)
 */
import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import type { WebSocket } from 'ws';
import { AppError, errors } from '../domain/errors';
import { METRIC } from '../observability/metrics';
import { RealtimeClient } from '../services/realtime';
import { RouteDeps } from '../routes/deps';

const WS_CLOSE_UNAUTHORIZED = 4401;

interface IncomingWsMessage {
  type?: string;
  deviceId?: unknown;
  serverSeq?: unknown;
}

export function registerWsRoute(app: FastifyInstance, deps: RouteDeps): void {
  app.get('/v1/ws', { websocket: true }, (socket: WebSocket, req) => {
    const url = new URL(req.url, 'http://localhost');
    const token = url.searchParams.get('token');

    let identity: { userId: string; deviceId: string | null };
    try {
      if (!token) throw errors.authRequired('缺少 token 查询参数');
      identity = deps.auth.verifyAccess(token);
    } catch (err) {
      const appErr = err instanceof AppError ? err : errors.authRequired('令牌无效');
      deps.metrics.inc(METRIC.WS_REJECTED, { reason: appErr.code });
      safeSend(socket, { type: 'error', error: { code: appErr.code, message: appErr.message, details: {} } });
      socket.close(WS_CLOSE_UNAUTHORIZED, 'unauthorized');
      return;
    }

    const clientId = randomUUID();
    const client: RealtimeClient = {
      id: clientId,
      userId: identity.userId,
      deviceId: identity.deviceId,
      lastAck: 0,
      send(payload: unknown) {
        const type =
          typeof payload === 'object' && payload !== null && typeof (payload as { type?: unknown }).type === 'string'
            ? ((payload as { type: string }).type)
            : 'unknown';
        if (safeSend(socket, payload)) deps.metrics.inc(METRIC.WS_SENT, { type });
      },
      close(code = 1000, reason = 'closed') {
        try {
          socket.close(code, reason);
        } catch {
          /* 已关闭 */
        }
      }
    };

    deps.realtime.add(client);
    deps.metrics.inc(METRIC.WS_OPENED);

    // hello:带上当前 serverSeq,客户端据此决定是否需要补拉
    void deps.repo
      .latestSeq(identity.userId)
      .then((serverSeq) => client.send({ type: 'hello', serverSeq, serverTime: Date.now() }))
      .catch(() => client.send({ type: 'hello', serverSeq: 0, serverTime: Date.now() }));

    socket.on('message', (raw: Buffer | string) => {
      let msg: IncomingWsMessage;
      try {
        msg = JSON.parse(raw.toString()) as IncomingWsMessage;
      } catch {
        client.send({ type: 'error', error: { code: 'VALIDATION_FAILED', message: '消息不是合法 JSON', details: {} } });
        return;
      }

      switch (msg.type) {
        case 'subscribe':
          // 订阅即绑定 deviceId(用于跳过变更发起设备)
          if (typeof msg.deviceId === 'string' && msg.deviceId !== '') client.deviceId = msg.deviceId;
          break;
        case 'ack':
          if (typeof msg.serverSeq === 'number' && Number.isFinite(msg.serverSeq)) client.lastAck = msg.serverSeq;
          break;
        case 'pong':
          break;
        case 'ping':
          client.send({ type: 'pong' });
          break;
        default:
          client.send({
            type: 'error',
            error: { code: 'VALIDATION_FAILED', message: `未知消息类型:${String(msg.type)}`, details: {} }
          });
      }
    });

    const cleanup = (): void => {
      if (deps.realtime.get(clientId)) {
        deps.realtime.remove(clientId);
        deps.metrics.inc(METRIC.WS_CLOSED);
      }
    };
    socket.on('close', cleanup);
    socket.on('error', cleanup);
  });
}

function safeSend(socket: WebSocket, payload: unknown): boolean {
  try {
    if (socket.readyState === 1 /* OPEN */) {
      socket.send(JSON.stringify(payload));
      return true;
    }
  } catch {
    /* 连接已断开 */
  }
  return false;
}
