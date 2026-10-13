/**
 * Ordo · 本地工作区标识用例(`viewmodel/LocalWorkspace.ets`,契约 §7.6.6)
 *
 * v1.5 是**纯本地**应用(没有登录、没有云同步),但"数据放哪个目录"仍需要一个稳定的本机标识:
 *  1. 已钉住 → 原样沿用(此后永不改变);
 *  2. 没钉住 → 由调用方用 `newLocalAccountId(seed)` 生成 `local-<16hex>`;
 *  3. 标识落地前必须清洗成安全目录名(只留 `[A-Za-z0-9_-]`,空串退化为 `_`)。
 */

import { describe, expect, it } from '@ohos/hypium';
import {
  LOCAL_ACCOUNT_ID_PREFIX,
  hasPinnedAccountDir,
  newLocalAccountId,
  planAccountDirId,
  sanitizeDirId,
  seedHex16
} from '../../../main/ets/viewmodel/LocalWorkspace.ets';

export default function localWorkspaceTest() {
  describe('LocalWorkspace', () => {

    it('pinned_id_is_reused_and_never_regenerated', 0, () => {
      // 契约 §7.6.6:钉住之后无论发生什么(重启/升级)都用同一个目录标识
      expect(planAccountDirId('local-805e05692b26ba14')).assertEqual('local-805e05692b26ba14');
      expect(planAccountDirId('local-805e05692b26ba14')).assertEqual(planAccountDirId('local-805e05692b26ba14'));
      // 老的(升级前)目录名也照原样沿用 —— 不迁移、不改名
      expect(planAccountDirId('afa8672f-aa76-4466-8ba9-9d1a5790dbce')).assertEqual('afa8672f-aa76-4466-8ba9-9d1a5790dbce');
      // 没有 → 空串,由调用方生成新标识
      expect(planAccountDirId('')).assertEqual('');
      expect(hasPinnedAccountDir('local-x')).assertTrue();
      expect(hasPinnedAccountDir('')).assertFalse();
    });

    it('new_id_is_stable_well_formed_and_local_prefixed', 0, () => {
      const a: string = newLocalAccountId('device-abc:1791616373285');
      const b: string = newLocalAccountId('device-abc:1791616373285');
      const c: string = newLocalAccountId('device-abc:1791616373286');
      // 同 seed 同结果(重启后如果 kv 丢了也能复现同一 id);不同 seed 不同 id
      expect(a).assertEqual(b);
      expect(a === c).assertFalse();
      // 形态 local-<16hex>
      expect(a.length).assertEqual(LOCAL_ACCOUNT_ID_PREFIX.length + 16);
      expect(a.indexOf(LOCAL_ACCOUNT_ID_PREFIX)).assertEqual(0);
      expect(seedHex16('abc').length).assertEqual(16);
      expect(seedHex16('').length).assertEqual(16);
      const hex: string = a.substring(LOCAL_ACCOUNT_ID_PREFIX.length);
      for (let i = 0; i < hex.length; i++) {
        const ch: string = hex.charAt(i);
        const ok: boolean = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
        expect(ok).assertTrue();
      }
    });

    it('dir_id_is_sanitized_before_touching_the_filesystem', 0, () => {
      // 只允许 [A-Za-z0-9_-],其余一律换成 _(含路径分隔符与 ..)
      expect(sanitizeDirId('a1b2-c3_d4')).assertEqual('a1b2-c3_d4');
      expect(sanitizeDirId('../etc//passwd')).assertEqual('___etc__passwd');
      expect(sanitizeDirId('..')).assertEqual('__');
      expect(sanitizeDirId('..\\..\\x y')).assertEqual('______x_y');
      // 绝不返回空串(空串 = 库落到父目录 = 所有工作区共用)
      expect(sanitizeDirId('').length > 0).assertTrue();
      expect(sanitizeDirId('///')).assertEqual('___');
      expect(sanitizeDirId('')).assertEqual('_');
    });

    it('sanitized_ids_of_different_seeds_stay_distinct', 0, () => {
      const a: string = sanitizeDirId(newLocalAccountId('dev-1'));
      const b: string = sanitizeDirId(newLocalAccountId('dev-2'));
      expect(a === b).assertFalse();
      expect(a.indexOf('local-')).assertEqual(0);
      expect(b.indexOf('local-')).assertEqual(0);
    });
  });
}
