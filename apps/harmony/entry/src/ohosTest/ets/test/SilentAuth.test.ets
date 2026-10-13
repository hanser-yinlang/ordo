/**
 * Ordo · 静默匿名会话用例(`viewmodel/SilentAuth.ets`)
 *
 * 产品决策(v1.4)不再需要登录:启动即主界面,会话在后台静默建立。这里钉住四件事:
 *  1. 启动分支:无会话 → `create`;有会话且未过期 → `use`;有会话但过期 → `refresh`;
 *  2. **目录标识(契约 §7.6.6)**:本机稳定 id,钉住后永不随会话重建而变;
 *     升级路径沿用老版本按 userId 建的目录名;形态 `local-<16hex>`,同 seed 同结果;
 *  3. 退避节奏:2s、4s、8s…上限 60s,且"建会话中"不许并发重试、"退避未到"不许重试;
 *  4. 状态机文案与重置。
 */

import { describe, expect, it } from '@ohos/hypium';
import {
  ANON_BACKOFF_BASE_MS,
  ANON_BACKOFF_MAX_MS,
  LOCAL_ACCOUNT_ID_PREFIX,
  SessionStartupPlan,
  SilentAuthMachine,
  SilentAuthPhase,
  anonBackoffMs,
  hasPinnedAccountDir,
  newLocalAccountId,
  planAccountDirId,
  planStartup,
  seedHex16
} from '../../../main/ets/viewmodel/SilentAuth.ets';

export default function silentAuthTest() {
  describe('SilentAuth', () => {

    it('startup_plan_covers_use_refresh_create', 0, () => {
      // 无会话 → 静默建匿名;有会话未过期 → 直接用;有会话但 accessToken 过期 → 先 refresh
      expect(planStartup(false, false)).assertEqual('create');
      expect(planStartup(false, true)).assertEqual('create');
      expect(planStartup(true, false)).assertEqual('use');
      expect(planStartup(true, true)).assertEqual('refresh');
      const kinds: SessionStartupPlan[] = [planStartup(true, false), planStartup(true, true), planStartup(false, false)];
      expect(kinds.indexOf('use') >= 0).assertTrue();
      expect(kinds.indexOf('refresh') >= 0).assertTrue();
      expect(kinds.indexOf('create') >= 0).assertTrue();
    });

    it('account_dir_id_is_pinned_and_never_follows_the_session', 0, () => {
      // 契约 §7.6.6:目录标识 = 本机稳定账号标识,不是服务端 userId
      // 1) 已钉住 → 无论会话怎么变都返回同一个
      expect(planAccountDirId('local-abcdef0123456789', 'server-user-1')).assertEqual('local-abcdef0123456789');
      expect(planAccountDirId('local-abcdef0123456789', 'server-user-2')).assertEqual('local-abcdef0123456789');
      expect(planAccountDirId('local-abcdef0123456789', '')).assertEqual('local-abcdef0123456789');
      // 2) 没钉住但有老会话(升级路径)→ 沿用老版本按 userId 建的目录名,不做迁移
      expect(planAccountDirId('', 'server-user-1')).assertEqual('server-user-1');
      expect(planAccountDirId('', 'user/with:bad*chars')).assertEqual('user_with_bad_chars');
      // 3) 都没有 → 空串,由调用方生成新的本机 id
      expect(planAccountDirId('', '')).assertEqual('');
      expect(hasPinnedAccountDir('local-x')).assertTrue();
      expect(hasPinnedAccountDir('')).assertFalse();
    });

    it('new_local_account_id_is_stable_and_well_formed', 0, () => {
      // 形态 local-<16hex>,同 seed 同结果、不同 seed 不同结果
      const id1: string = newLocalAccountId('device-abc:1791616373285');
      const id2: string = newLocalAccountId('device-abc:1791616373285');
      const id3: string = newLocalAccountId('device-abc:1791616373286');
      expect(id1).assertEqual(id2);
      expect(id1.length).assertEqual(LOCAL_ACCOUNT_ID_PREFIX.length + 16);
      expect(id1.indexOf(LOCAL_ACCOUNT_ID_PREFIX)).assertEqual(0);
      expect(id1 === id3).assertFalse();
      expect(seedHex16('abc').length).assertEqual(16);
      expect(seedHex16('').length).assertEqual(16);
      const hex: string = id1.substring(LOCAL_ACCOUNT_ID_PREFIX.length);
      for (let i = 0; i < hex.length; i++) {
        const ch: string = hex.charAt(i);
        const ok: boolean = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
        expect(ok).assertTrue();
      }
    });

    it('backoff_is_exponential_and_capped', 0, () => {
      // 2s → 4s → 8s → 16s → 32s → 60s(封顶),且第 0/负数次也安全
      expect(ANON_BACKOFF_BASE_MS).assertEqual(2000);
      expect(ANON_BACKOFF_MAX_MS).assertEqual(60000);
      expect(anonBackoffMs(0)).assertEqual(2000);
      expect(anonBackoffMs(1)).assertEqual(2000);
      expect(anonBackoffMs(2)).assertEqual(4000);
      expect(anonBackoffMs(3)).assertEqual(8000);
      expect(anonBackoffMs(4)).assertEqual(16000);
      expect(anonBackoffMs(5)).assertEqual(32000);
      expect(anonBackoffMs(6)).assertEqual(60000);
      expect(anonBackoffMs(20)).assertEqual(60000);
    });

    it('machine_starts_ready_and_can_retry_immediately', 0, () => {
      const m: SilentAuthMachine = new SilentAuthMachine();
      expect(m.getPhase()).assertEqual('ready');
      expect(m.attemptsMade()).assertEqual(0);
      expect(m.canRetry(0)).assertTrue();
      expect(m.remainingMs(0)).assertEqual(0);
      expect(m.label()).assertEqual('已就绪');
    });

    it('creating_blocks_concurrent_attempts', 0, () => {
      // 建会话中:不许再发一次(避免并发建出多个匿名账号)
      const m: SilentAuthMachine = new SilentAuthMachine();
      m.begin(1000);
      expect(m.getPhase()).assertEqual('creating');
      expect(m.canRetry(1000)).assertFalse();
      expect(m.canRetry(999999)).assertFalse();
      expect(m.remainingMs(1000)).assertEqual(0);
      expect(m.label()).assertEqual('正在建立同步会话…');
    });

    it('failure_schedules_backoff_and_marks_offline', 0, () => {
      // 失败:累加次数 + 排下一次;退避未到不许重试,到点才可以
      const m: SilentAuthMachine = new SilentAuthMachine();
      m.begin(0);
      const wait1: number = m.fail(0);
      expect(wait1).assertEqual(2000);
      const p: SilentAuthPhase = m.getPhase();
      expect(p).assertEqual('waiting');
      expect(m.attemptsMade()).assertEqual(1);
      expect(m.canRetry(1999)).assertFalse();
      expect(m.remainingMs(1999)).assertEqual(1);
      expect(m.canRetry(2000)).assertTrue();
      expect(m.remainingMs(2000)).assertEqual(0);
      expect(m.label()).assertEqual('离线可用 · 稍后自动重连');

      // 第二次失败等待翻倍
      m.begin(2000);
      expect(m.fail(2000)).assertEqual(4000);
      expect(m.attemptsMade()).assertEqual(2);
      expect(m.canRetry(5999)).assertFalse();
      expect(m.canRetry(6000)).assertTrue();
    });

    it('success_clears_backoff_and_attempts', 0, () => {
      const m: SilentAuthMachine = new SilentAuthMachine();
      m.begin(0);
      m.fail(0);
      m.fail(2000);
      expect(m.attemptsMade()).assertEqual(2);
      m.succeed();
      expect(m.getPhase()).assertEqual('ready');
      expect(m.attemptsMade()).assertEqual(0);
      expect(m.canRetry(0)).assertTrue();
      expect(m.label()).assertEqual('已就绪');
    });

    it('reset_returns_to_steady_state', 0, () => {
      // 401 静默重建前会 reset 一次:状态回到稳态,后面照样能立刻重试
      const m: SilentAuthMachine = new SilentAuthMachine();
      m.begin(0);
      m.fail(0);
      m.reset();
      expect(m.getPhase()).assertEqual('ready');
      expect(m.attemptsMade()).assertEqual(0);
      expect(m.canRetry(0)).assertTrue();
    });
  });
}
