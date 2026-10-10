/**
 * Ordo · 会话与游客用例(`core/session/OrdoSession.ets`)
 *
 * 契约来源:docs/03-数据模型与同步协议.md §7.6(账号、会话与游客)。
 * 与共享核心 Kotlin `SessionTest` **逐条对齐**(同一批断言,鸿蒙侧同样要过):
 *  1. 会话在 kv 里往返(expiresIn 秒 → 绝对毫秒);
 *  2. 游客:无邮箱 + isGuest=true + displayName() = 「游客」;
 *  3. 正式账号 displayName() = 邮箱;
 *  4. 过期判定以绝对时刻为准;expiresAt = 0 表示未知,按未过期处理;
 *  5. clear() 只清会话,不动其它 kv;
 *  6. 损坏的会话视为未登录,不能让启动崩掉;
 *  7. 目录名清洗(§7.6.3 硬约束):可疑字符全替换、不残留点号、不同用户必落到不同目录。
 */

import { describe, expect, it } from '@ohos/hypium';
import { MemoryOrdoStore } from '../../../main/ets/core/storage/MemoryStore.ets';
import {
  OrdoSession,
  OrdoSessionHelper,
  OrdoSessionStore,
  SessionAuthResponse,
  SessionAuthTokens,
  SessionAuthUser
} from '../../../main/ets/core/session/OrdoSession.ets';

const NOW: number = 1700000000000;

function authResponse(userId: string, email: string, isGuest: boolean, expiresIn: number): SessionAuthResponse {
  const user: SessionAuthUser = { id: userId, email: email, isGuest: isGuest };
  const tokens: SessionAuthTokens = {
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    expiresIn: expiresIn
  };
  const response: SessionAuthResponse = { user: user, tokens: tokens };
  return response;
}

export default function sessionTest() {
  describe('OrdoSession', () => {

    it('session_round_trip_through_storage', 0, async (done: Function): Promise<void> => {
      const storage: MemoryOrdoStore = new MemoryOrdoStore();
      await storage.init();
      const store: OrdoSessionStore = new OrdoSessionStore(storage);
      const empty: OrdoSession | null = await store.load();
      expect(empty === null).assertTrue();

      await store.save(OrdoSessionHelper.from(authResponse('u-1', 'a@b.c', false, 3600), NOW));
      const loaded: OrdoSession | null = await store.load();
      expect(loaded === null).assertFalse();
      const s: OrdoSession = loaded as OrdoSession;
      expect(s.userId).assertEqual('u-1');
      expect(s.email).assertEqual('a@b.c');
      expect(s.isGuest).assertFalse();
      expect(s.accessToken).assertEqual('access-1');
      // expiresIn 秒要换算成绝对毫秒
      expect(s.expiresAt).assertEqual(NOW + 3600000);
      expect(OrdoSessionHelper.isExpired(s, NOW + 3599000)).assertFalse();
      expect(OrdoSessionHelper.isExpired(s, NOW + 3600000)).assertTrue();
      done();
    });

    it('guest_session_has_no_email_and_display_name_is_guest', 0, async (done: Function): Promise<void> => {
      const storage: MemoryOrdoStore = new MemoryOrdoStore();
      await storage.init();
      const store: OrdoSessionStore = new OrdoSessionStore(storage);
      await store.save(OrdoSessionHelper.from(authResponse('u-guest', '', true, 1800), NOW));
      const s: OrdoSession | null = await store.load();
      expect(s === null).assertFalse();
      const guest: OrdoSession = s as OrdoSession;
      expect(guest.isGuest).assertTrue();
      // 空邮箱要归一化成 null
      expect(guest.email === null).assertTrue();
      expect(OrdoSessionHelper.displayName(guest)).assertEqual('游客');
      done();
    });

    it('formal_account_display_name_is_email', 0, () => {
      const s: OrdoSession = OrdoSessionHelper.from(authResponse('u-2', 'me@ordo.app', false, 60), NOW);
      expect(OrdoSessionHelper.displayName(s)).assertEqual('me@ordo.app');
      expect(s.email).assertEqual('me@ordo.app');
      expect(s.isGuest).assertFalse();
    });

    it('expiry_is_unknown_when_server_gives_no_expires_in', 0, () => {
      // expiresIn = 0 → expiresAt = 0 → 按未过期处理,由服务端 401 兜底
      const s: OrdoSession = OrdoSessionHelper.from(authResponse('u-3', 'x@y.z', false, 0), NOW);
      expect(s.expiresAt).assertEqual(0);
      expect(OrdoSessionHelper.isExpired(s, NOW + 100000000)).assertFalse();
    });

    it('clear_removes_session_only', 0, async (done: Function): Promise<void> => {
      const storage: MemoryOrdoStore = new MemoryOrdoStore();
      await storage.init();
      const store: OrdoSessionStore = new OrdoSessionStore(storage);
      await store.save(OrdoSessionHelper.from(authResponse('u-4', 'a@b.c', false, 60), NOW));
      await storage.setKv('deviceId', 'dev_keepme');
      await store.clear();
      const after: OrdoSession | null = await store.load();
      expect(after === null).assertTrue();
      // 设备标识不属于会话,退出登录不能把它清掉
      expect(await storage.getKv('deviceId')).assertEqual('dev_keepme');
      done();
    });

    it('corrupt_session_degrades_to_null_instead_of_crashing', 0, async (done: Function): Promise<void> => {
      const storage: MemoryOrdoStore = new MemoryOrdoStore();
      await storage.init();
      await storage.setKv(OrdoSessionHelper.KEY_SESSION, '{not-json');
      const loaded: OrdoSession | null = await new OrdoSessionStore(storage).load();
      expect(loaded === null).assertTrue();
      done();
    });

    it('session_without_user_id_is_treated_as_logged_out', 0, async (done: Function): Promise<void> => {
      // 没有 userId 就没有"按用户隔离"的落点;宁可当未登录,也不能退化成共用目录
      const storage: MemoryOrdoStore = new MemoryOrdoStore();
      await storage.init();
      await storage.setKv(OrdoSessionHelper.KEY_SESSION, '{"userId":"","accessToken":"t","refreshToken":"r","expiresAt":0}');
      const loaded: OrdoSession | null = await new OrdoSessionStore(storage).load();
      expect(loaded === null).assertTrue();
      done();
    });

    it('user_data_dir_name_is_safe_and_per_user', 0, () => {
      expect(OrdoSessionHelper.userDataDirName('a1b2-c3_d4')).assertEqual('a1b2-c3_d4');
      // `.` `.` `/` 三个字符各替换成一个 `_`,不可能构造出 `..`
      expect(OrdoSessionHelper.userDataDirName('../etc//passwd')).assertEqual('___etc__passwd');
      expect(OrdoSessionHelper.userDataDirName('..').indexOf('.')).assertEqual(-1);
      expect(OrdoSessionHelper.userDataDirName('..').length > 0).assertTrue();
      // 反斜杠与空格同样被替换(Windows 风格路径穿越也挡掉)
      expect(OrdoSessionHelper.userDataDirName('..\\..\\x y')).assertEqual('______x_y');
      // 不同用户必须落到不同目录(契约 §7.6.3 硬约束)
      expect(OrdoSessionHelper.userDataDirName('u-1') === OrdoSessionHelper.userDataDirName('u-2')).assertFalse();
      // 清洗后为空也要退化成一个真实目录名,绝不能返回空串(= 根目录,所有人共用)
      expect(OrdoSessionHelper.userDataDirName('').length > 0).assertTrue();
      expect(OrdoSessionHelper.userDataDirName('///')).assertEqual('___');
    });

    it('two_users_never_share_one_store', 0, async (done: Function): Promise<void> => {
      // 每个账号一份 storage:数据天然隔离,互不可见(内存实现等价于"两个 userId 目录")
      const a: MemoryOrdoStore = new MemoryOrdoStore(undefined, OrdoSessionHelper.userDataDirName('u-A'), false);
      const b: MemoryOrdoStore = new MemoryOrdoStore(undefined, OrdoSessionHelper.userDataDirName('u-B'), false);
      await a.init();
      await b.init();
      await a.setKv('marker', 'A');
      const leaked: string | null = await b.getKv('marker');
      expect(leaked === null).assertTrue();
      expect(a.pathText().indexOf('u-A') > 0).assertTrue();
      expect(b.pathText().indexOf('u-B') > 0).assertTrue();
      expect(a.pathText() === b.pathText()).assertFalse();
      done();
    });
  });
}
