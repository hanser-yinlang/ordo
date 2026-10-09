/**
 * Ordo · ID 生成
 * 契约来源:docs/03-数据模型与同步协议.md §7.2(opId 为 ULID,幂等键)
 *
 * 说明:核心层不引入系统能力(便于 ohosTest 直接运行),因此随机源使用 Math.random。
 * opId 需要"全局唯一 + 时间有序",此处实现 ULID 的 26 字符 Crockford Base32 形式。
 */

const CROCKFORD: string = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * 生成 26 字符 ULID:前 10 字符为 48 位毫秒时间戳,后 16 字符为 80 位随机数。
 * 例:01JABCDEFGHJKMNPQRSTVWXYZ0
 */
export function newOpId(): string {
  const time: number = Date.now();
  let head: string = '';
  let t: number = time;
  for (let i = 0; i < 10; i++) {
    const idx: number = t % 32;
    head = CROCKFORD.charAt(idx) + head;
    t = Math.floor(t / 32);
  }
  let tail: string = '';
  for (let i = 0; i < 16; i++) {
    const idx: number = Math.floor(Math.random() * 32);
    tail += CROCKFORD.charAt(idx);
  }
  return head + tail;
}

/** 生成 32 位十六进制实体 id(等价 UUID v4 的字符串形式,去掉连字符) */
export function newId(): string {
  let out: string = '';
  for (let i = 0; i < 32; i++) {
    const v: number = Math.floor(Math.random() * 16);
    out += v.toString(16);
  }
  return out;
}

/** 带前缀的实体 id,便于日志与调试辨认 */
export function newIdWithPrefix(prefix: string): string {
  return prefix + '_' + newId().substring(0, 20);
}

/** 设备 id:安装时生成一次并写入 kv.deviceId(契约 §7.4 X-Ordo-Device) */
export function newDeviceId(): string {
  return 'dev_' + newId().substring(0, 20);
}

/** 当前毫秒时间戳(统一入口,便于测试替换) */
export function nowMillis(): number {
  return Date.now();
}

/** 生成本地清单项 id */
export function newChecklistItemId(): string {
  return 'ck_' + newId().substring(0, 16);
}
