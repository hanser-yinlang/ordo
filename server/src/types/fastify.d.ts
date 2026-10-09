import type { AccessIdentity } from '../services/auth';

declare module 'fastify' {
  interface FastifyRequest {
    /** 由 requireAuth 前置钩子写入 */
    auth?: AccessIdentity;
  }
}

export {};
