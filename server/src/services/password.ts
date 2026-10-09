/**
 * 口令哈希 —— 契约 §9:口令用 argon2id(默认)哈希,最小长度 8,禁止明文与日志落库。
 *
 * 降级策略(已在 .npmrc / pnpm-workspace.yaml 说明):
 *   argon2 是**可选原生依赖**(optionalDependencies)。若目标平台没有预编译产物、
 *   require('argon2') 抛错,则自动降级为 node:crypto 的 scrypt(N=16384, r=8, p=1, 32 字节)。
 *   两种算法都会把算法标识写进哈希串,因此可以混存,并可在登录成功后按需重哈希升级。
 */
import { createHash, randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(scryptCallback) as (
  password: string | Buffer,
  salt: Buffer,
  keylen: number,
  options: { N: number; r: number; p: number }
) => Promise<Buffer>;

const SCRYPT_PARAMS = { N: 16384, r: 8, p: 1, keylen: 32 };
const SALT_BYTES = 16;

export type PasswordAlgo = 'argon2id' | 'scrypt';

export interface PasswordHasher {
  readonly algo: PasswordAlgo;
  hash(password: string): Promise<string>;
  verify(stored: string, password: string): Promise<boolean>;
}

type Argon2Like = {
  hash(password: string, options?: Record<string, unknown>): Promise<string>;
  verify(hash: string, password: string): Promise<boolean>;
};

let argon2Cache: Argon2Like | null | undefined;

/** 探测 argon2 是否可用(cache 结果,避免重复 require) */
export function loadArgon2(): Argon2Like | null {
  if (argon2Cache !== undefined) return argon2Cache;
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require('argon2') as Argon2Like;
    argon2Cache = typeof mod?.hash === 'function' ? mod : null;
  } catch {
    argon2Cache = null;
  }
  return argon2Cache;
}

export function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

async function scryptHash(password: string): Promise<string> {
  const salt = randomBytes(SALT_BYTES);
  const { N, r, p, keylen } = SCRYPT_PARAMS;
  const derived = await scrypt(password, salt, keylen, { N, r, p });
  return `scrypt$${N}$${r}$${p}$${salt.toString('base64')}$${derived.toString('base64')}`;
}

async function scryptVerify(stored: string, password: string): Promise<boolean> {
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const N = Number(parts[1]);
  const r = Number(parts[2]);
  const p = Number(parts[3]);
  const salt = Buffer.from(parts[4], 'base64');
  const expected = Buffer.from(parts[5], 'base64');
  const derived = await scrypt(password, salt, expected.length, { N, r, p });
  return derived.length === expected.length && timingSafeEqual(derived, expected);
}

export interface HasherOptions {
  /** 强制算法;默认 auto(argon2 可用则用,否则 scrypt) */
  force?: PasswordAlgo;
}

export function createPasswordHasher(options: HasherOptions = {}): PasswordHasher {
  const argon2 = options.force === 'scrypt' ? null : loadArgon2();
  const algo: PasswordAlgo = argon2 ? 'argon2id' : 'scrypt';

  return {
    algo,
    async hash(password: string): Promise<string> {
      if (argon2) {
        // argon2id 默认参数(内存 19 MiB, 2 轮, 并行度 1)符合 OWASP 建议
        return argon2.hash(password, { type: 2 /* argon2id */, memoryCost: 19456, timeCost: 2, parallelism: 1 });
      }
      return scryptHash(password);
    },
    async verify(stored: string, password: string): Promise<boolean> {
      if (!stored) return false;
      if (stored.startsWith('$argon2')) {
        if (!argon2) return false; // 换了算法又装不上 argon2 时无法校验(部署时需保证一致性)
        try {
          return await argon2.verify(stored, password);
        } catch {
          return false;
        }
      }
      if (stored.startsWith('scrypt$')) return scryptVerify(stored, password);
      return false;
    }
  };
}

/** 口令强度校验(契约 §9:最小长度 8) */
export function validatePasswordStrength(password: string): string | null {
  if (typeof password !== 'string' || password.length < 8) return '口令至少 8 个字符';
  if (password.length > 200) return '口令过长(最多 200 字符)';
  return null;
}
