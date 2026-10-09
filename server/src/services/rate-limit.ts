/**
 * 内存令牌桶限流 —— 契约 §7.4「写接口 ≤ 10 req/s(超限 RATE_LIMITED)」。
 * 单实例内存实现;多实例部署时应换成 Redis 等共享存储(见 docs/DEPLOY.md)。
 */

export interface RateLimitDecision {
  allowed: boolean;
  /** 剩余令牌(向下取整) */
  remaining: number;
  /** 建议的重试等待秒数 */
  retryAfterSec: number;
}

interface Bucket {
  tokens: number;
  updatedAt: number;
}

export class TokenBucketLimiter {
  private buckets = new Map<string, Bucket>();

  constructor(
    private capacity: number,
    private refillPerSec: number,
    private now: () => number = Date.now
  ) {}

  tryConsume(key: string, cost = 1): RateLimitDecision {
    const t = this.now();
    const bucket = this.buckets.get(key) ?? { tokens: this.capacity, updatedAt: t };
    const elapsedSec = Math.max(0, (t - bucket.updatedAt) / 1000);
    const refilled = Math.min(this.capacity, bucket.tokens + elapsedSec * this.refillPerSec);

    if (refilled >= cost) {
      bucket.tokens = refilled - cost;
      bucket.updatedAt = t;
      this.buckets.set(key, bucket);
      return { allowed: true, remaining: Math.floor(bucket.tokens), retryAfterSec: 0 };
    }

    bucket.tokens = refilled;
    bucket.updatedAt = t;
    this.buckets.set(key, bucket);
    const missing = cost - refilled;
    // refillPerSec = 0 表示「不补充」(用于确定性测试)
    const retryAfterSec = this.refillPerSec > 0 ? Math.max(1, Math.ceil(missing / this.refillPerSec)) : 60;
    return { allowed: false, remaining: 0, retryAfterSec };
  }

  /** 释放长时间不活跃的桶,避免内存无限增长 */
  sweep(idleMs = 10 * 60_000): number {
    const t = this.now();
    let removed = 0;
    for (const [key, bucket] of [...this.buckets.entries()]) {
      if (t - bucket.updatedAt > idleMs) {
        this.buckets.delete(key);
        removed += 1;
      }
    }
    return removed;
  }

  reset(): void {
    this.buckets.clear();
  }
}
