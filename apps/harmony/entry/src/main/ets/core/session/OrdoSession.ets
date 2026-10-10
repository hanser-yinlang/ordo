/**
 * Ordo · 登录会话(契约 §7.6,鸿蒙移植版)
 *
 * 与共享核心 Kotlin `com.ordo.core.sync.OrdoSession` / `OrdoSessionStore` **逐字段、逐语义对齐**:
 *  - 字段:`userId / email? / isGuest / accessToken / refreshToken / expiresAt`
 *  - 方法:`isExpired(now)`、`displayName()`(无邮箱 → 「游客」)
 *  - 存储:kv 键 `ordo.session`,值为本结构的 JSON
 *  - 目录:`userDataDirName(userId)` 把所有非 `[A-Za-z0-9_-]` 的字符替换成 `_`,防路径穿越(§7.6.3 硬约束)
 *
 * 本文件**不依赖 ArkUI / @ohos**:宿主要求它是纯逻辑,才能被 `_qa/build-harness.py` 拉到 Node 上真跑。
 * kv 直接复用 `OrdoStore`(与 Kotlin 版的 `OrdoStorage` 同一个角色),各端只需保证传进来的是
 * **该 userId 专属目录**里的那个实例(见 §7.6.3)。
 */

import { OrdoStore } from '../storage/OrdoStore.ets';

/**
 * 本地保存的登录态(契约 §7.6.1)。
 * `email === null` 表示游客账号(没有邮箱口令),`isGuest` 单独标记,二者都要一致。
 */
export interface OrdoSession {
  userId: string;
  email: string | null;
  isGuest: boolean;
  accessToken: string;
  refreshToken: string;
  /** 过期时刻(epoch millis);0 表示服务端未给过期时间 → 按「未过期」处理,由 401 兜底 */
  expiresAt: number;
}

/** 由登录/注册/游客响应构造会话所需的输入(AuthResult / AuthUser 的结构子集) */
export interface SessionAuthUser {
  id: string;
  email?: string;
  isGuest?: boolean;
}

export interface SessionAuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export interface SessionAuthResponse {
  user: SessionAuthUser;
  tokens: SessionAuthTokens;
}

/** 目录名里允许出现的字符:字母 / 数字 / `-` / `_`(与 Kotlin 版同一条规则) */
function isSafeDirChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  const digit: boolean = code >= 48 && code <= 57;
  const upper: boolean = code >= 65 && code <= 90;
  const lower: boolean = code >= 97 && code <= 122;
  return digit || upper || lower || ch === '-' || ch === '_';
}

export class OrdoSessionHelper {
  /** 契约 §7.6.1:会话存于 `kv["ordo.session"]` */
  static readonly KEY_SESSION: string = 'ordo.session';

  /** 过期判定:`expiresAt = 0` 视为未知,按未过期处理(与 Kotlin 版一致) */
  static isExpired(s: OrdoSession, nowMillis: number): boolean {
    return s.expiresAt > 0 && nowMillis >= s.expiresAt;
  }

  /** 展示名:正式账号用邮箱,游客(或邮箱为空)用「游客」 */
  static displayName(s: OrdoSession): string {
    const mail: string | null = s.email;
    if (mail !== null && mail.length > 0) {
      return mail;
    }
    return '游客';
  }

  /** 由登录响应构造会话;`nowMillis` 用于把 `expiresIn`(秒)换算成绝对过期时刻 */
  static from(response: SessionAuthResponse, nowMillis: number): OrdoSession {
    const user: SessionAuthUser = response.user;
    const rawMail: string | undefined = user.email;
    const mail: string | null = rawMail === undefined || rawMail === null || rawMail.length === 0 ? null : rawMail;
    const expiresIn: number = response.tokens.expiresIn;
    const s: OrdoSession = {
      userId: user.id,
      email: mail,
      isGuest: user.isGuest === true,
      accessToken: response.tokens.accessToken,
      refreshToken: response.tokens.refreshToken,
      expiresAt: expiresIn > 0 ? nowMillis + expiresIn * 1000 : 0
    };
    return s;
  }

  /**
   * 本地数据目录名(契约 §7.6.3):每个账号一个子目录,防止两个账号共用同一份数据。
   * userId 由服务端生成(uuid),直接当目录名是安全的;这里再做一次防御性清洗:
   *  - 只保留 `[A-Za-z0-9_-]`,其余(含 `.` `/` `\` 与空格)一律替换成 `_` → 不可能构造出 `..`
   *  - 清洗后为空(例如 userId 全是非法字符)时退化为 `_`,绝不返回空串 —— 空串意味着"根目录",
   *    那会让所有账号共用同一份数据,正是硬约束禁止的情形。
   */
  static userDataDirName(userId: string): string {
    let out: string = '';
    for (let i = 0; i < userId.length; i++) {
      const ch: string = userId.charAt(i);
      out += isSafeDirChar(ch) ? ch : '_';
    }
    return out.length === 0 ? '_' : out;
  }
}

/**
 * 会话的本地读写(与 Kotlin `OrdoSessionStore` 同接口)。
 * 传入的 storage 必须是「应用级」的那一个:会话要先于账号目录被读出来,否则无法确定用哪个目录。
 */
export class OrdoSessionStore {
  private storage: OrdoStore;

  constructor(storage: OrdoStore) {
    this.storage = storage;
  }

  async load(): Promise<OrdoSession | null> {
    const raw: string | null = await this.storage.getKv(OrdoSessionHelper.KEY_SESSION);
    if (raw === null || raw.trim().length === 0) {
      return null;
    }
    let parsed: OrdoSession | null = null;
    try {
      const obj: OrdoSession = JSON.parse(raw) as OrdoSession;
      if (obj === null || obj === undefined) {
        return null;
      }
      if (obj.userId === undefined || obj.userId === null || obj.userId.length === 0) {
        // 没有 userId 就没有"按用户隔离"的落点,宁可当作未登录,也不能退化成共用目录
        return null;
      }
      const email: string | null = obj.email === undefined ? null : obj.email;
      const s: OrdoSession = {
        userId: obj.userId,
        email: email === null || email.length === 0 ? null : email,
        isGuest: obj.isGuest === true,
        accessToken: obj.accessToken === undefined ? '' : obj.accessToken,
        refreshToken: obj.refreshToken === undefined ? '' : obj.refreshToken,
        expiresAt: obj.expiresAt === undefined ? 0 : obj.expiresAt
      };
      parsed = s;
    } catch (e) {
      // 损坏的会话视为未登录:启动流程不能因为一段坏 JSON 崩掉
      return null;
    }
    return parsed;
  }

  async save(session: OrdoSession): Promise<void> {
    await this.storage.setKv(OrdoSessionHelper.KEY_SESSION, JSON.stringify(session));
  }

  /** 退出登录:只清会话,目录与目录内的数据一律保留(契约 §7.6.3) */
  async clear(): Promise<void> {
    await this.storage.removeKv(OrdoSessionHelper.KEY_SESSION);
  }
}
