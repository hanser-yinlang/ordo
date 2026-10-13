/**
 * Ordo · 本地工作区标识(v1.5:纯本地,不再有任何网络/会话)
 *
 * 背景:登录与云同步都被产品移除,应用变成**纯本地**应用。但"数据放在哪个目录"这件事仍然需要一个
 * **稳定的本机标识**(契约 §7.6.6):目录标识 = 本机稳定账号标识,首次运行生成并持久化
 * (kv `ordo.localAccountId`),此后永不改变。
 *
 * 为什么不能临时生成:标识一旦变,本地库就换了一个文件,用户会看到"数据没了"。
 * 因此这里只做三件事:读/钉住标识、生成新标识、把标识清洗成安全的目录名。
 *
 * 本文件不依赖 ArkUI / @kit,可被宿主机直接执行(见 LocalWorkspace.test.ets)。
 */

/** 本机稳定目录标识前缀(契约 §7.6.6:形态自定,这里用 `local-<16hex>`) */
export const LOCAL_ACCOUNT_ID_PREFIX: string = 'local-';

/**
 * 钉住本地目录标识(契约 §7.6.6)。
 * @param storedId kv `ordo.localAccountId` 里已钉住的值('' = 还没有)
 * @returns 该用的目录标识;返回 '' 表示需要新生成一个(`newLocalAccountId`)
 */
export function planAccountDirId(storedId: string): string {
  return storedId.length > 0 ? sanitizeDirId(storedId) : '';
}

/** 目录标识是否已经钉住 */
export function hasPinnedAccountDir(dirId: string): boolean {
  return dirId.length > 0;
}

/**
 * 生成一个**本机稳定**目录标识:`local-<16hex>`。
 * 由 `seed` 决定(建议 `deviceId + ':' + 时间戳`),同 seed 同结果,便于用例断言。
 */
export function newLocalAccountId(seed: string): string {
  return LOCAL_ACCOUNT_ID_PREFIX + seedHex16(seed);
}

/**
 * 标识 → 安全目录名:只保留 `[A-Za-z0-9_-]`,其余(含 `.` `/` `\` 空格)替换成 `_`;
 * 清洗后为空则退化为 `_`(**绝不返回空串** —— 空串等于库落在父目录里)。
 */
export function sanitizeDirId(id: string): string {
  let out: string = '';
  for (let i = 0; i < id.length; i++) {
    const ch: string = id.charAt(i);
    const ok: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
      || (ch >= '0' && ch <= '9') || ch === '_' || ch === '-';
    out = out + (ok ? ch : '_');
  }
  return out.length > 0 ? out : '_';
}

/** FNV-1a 32 位哈希(两次不同偏移拼成 16 个 hex 字符)—— 只为"稳定且够分散",不做安全用途 */
function fnv1a(text: string, offset: number): number {
  let h: number = offset;
  for (let i = 0; i < text.length; i++) {
    h = h ^ text.charCodeAt(i);
    // h * 16777619:用移位加法避免超出安全整数
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h >>> 0;
}

function toHex8(value: number): string {
  let s: string = (value >>> 0).toString(16);
  while (s.length < 8) {
    s = '0' + s;
  }
  return s;
}

/** seed → 16 个 hex 字符 */
export function seedHex16(seed: string): string {
  const a: number = fnv1a(seed, 0x811c9dc5);
  const b: number = fnv1a(seed + '#ordo', 0x01000193);
  return toHex8(a) + toHex8(b);
}
