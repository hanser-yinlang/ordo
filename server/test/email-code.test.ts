/**
 * 邮箱验证码登录测试 —— 契约 §7.6.5 / §9(v1.3 新增「邮箱验证码登录」)
 *
 * 覆盖:
 *  - `POST /v1/auth/email/code` → 202 `{sent,expiresIn:300,retryAfter:60}`;开发回显 `devCode`
 *  - 库里**只存 HMAC-SHA256(pepper, email:code)**:非明文、非裸 SHA-256、与邮箱绑定
 *  - 限流:60s 内重复 → 429 `code_throttled`(带 retryAfterSec + Retry-After 头)、每小时 5、每天 10
 *  - 校验:错码 → 401 `code_invalid`;5 次错码 → 401 `code_attempts_exceeded`(作废);
 *    过期 → 401 `code_expired`;成功后再用同码 → 401 `code_invalid`(一次性消费)
 *  - 账号语义:未注册邮箱**自动建号**(is_guest=false、无口令 `otp$<random>`);
 *    已注册账号直接登录且**口令不变**;无口令账号口令登录被拒(`AUTH_INVALID_CREDENTIALS`)
 *  - `POST /v1/auth/email/login` 的响应与 register **完全同构**
 *  - **http 发信通道真发一次**:本地 stub HTTP 服务收报文(带 Bearer),用报文里的验证码登录;
 *    网关非 2xx → 500 `INTERNAL` + `details.reason='mail_failed'` 且不落库
 *  - 配置硬约束:生产 + `ORDO_DEV_ECHO_CODE=1` 拒绝启动、生产缺 pepper 拒绝启动、
 *    生产 console 通道的日志不含验证码
 *
 * 端口说明:stub 网关用 `127.0.0.1:0`(临时端口,与 test/helpers.ts 的 `makeServer` 一致),
 * 结束即关闭 —— 不占用 18080-18099 里的任何固定端口,也不会留下监听进程。
 */
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, describe, it } from 'node:test';
import { loadConfig } from '../src/config';
import { emailCodeHash } from '../src/services/auth';
import { createMailSender, type MailLogger } from '../src/services/mail';
import { sha256Hex } from '../src/services/password';
import {
  makeApp,
  makeOp,
  makeTodo,
  push,
  uniqueEmail,
  type TestContext
} from './helpers';

const CODE_RE = /^\d{6}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;

interface Injected {
  statusCode: number;
  body: string;
  json(): any;
  headers: Record<string, string | string[] | undefined>;
}

async function requestCode(app: TestContext['app'], email: unknown): Promise<Injected> {
  return (await app.inject({
    method: 'POST',
    url: '/v1/auth/email/code',
    payload: { email }
  })) as unknown as Injected;
}

async function emailLogin(
  app: TestContext['app'],
  payload: Record<string, unknown>
): Promise<Injected> {
  return (await app.inject({
    method: 'POST',
    url: '/v1/auth/email/login',
    payload
  })) as unknown as Injected;
}

/** 取一个"必然不等于真码"的 6 位数字 */
function wrongCodeFor(code: string): string {
  return code === '000000' ? '111111' : '000000';
}

/* ============================================================================
 * 1. 主流程(console 通道 + 开发回显,内存仓储)
 * ==========================================================================*/

describe('邮箱验证码登录(契约 §7.6.5)', () => {
  let ctx: TestContext;

  before(async () => {
    ctx = await makeApp();
  });

  after(async () => {
    await ctx.close();
  });

  /* ---------------- 请求验证码 ---------------- */

  describe('POST /v1/auth/email/code', () => {
    it('→ 202 {sent:true, expiresIn:300, retryAfter:60}(开发模式额外回显 devCode)', async () => {
      const email = uniqueEmail('code');
      const res = await requestCode(ctx.app, email);
      assert.equal(res.statusCode, 202, `应返回 202,实际 ${res.statusCode}:${res.body}`);

      const body = res.json();
      assert.equal(body.sent, true);
      assert.equal(body.expiresIn, 300, '契约 §7.6.5:有效期 5 分钟');
      assert.equal(body.retryAfter, 60, '契约 §7.6.5:同邮箱最小间隔 60 秒');
      assert.ok(CODE_RE.test(body.devCode), `开发模式应回显 6 位数字验证码,实际 ${body.devCode}`);

      // 落库一条:5 分钟有效、未消费、0 次尝试
      const row = await ctx.repo.latestEmailCode(email);
      assert.ok(row, '验证码必须落库');
      assert.equal(row!.email, email.toLowerCase(), '邮箱统一小写入库');
      assert.equal(row!.attempts, 0);
      assert.equal(row!.consumedAt, null, '刚发出的验证码不得是已消费状态');
      assert.equal(row!.expiresAt - row!.createdAt, 300_000, 'TTL 必须是 300 秒');
      assert.equal(await ctx.repo.countEmailCodesSince(email, 0), 1);
    });

    it('库里只存 HMAC-SHA256(pepper, email:code):非明文、非裸 SHA-256、与邮箱绑定', async () => {
      const email = uniqueEmail('hash');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const row = await ctx.repo.latestEmailCode(email);
      assert.ok(row);

      // 契约 §9 的正确定义:HMAC-SHA256(pepper, email + ':' + code)
      assert.equal(
        row!.codeHash,
        emailCodeHash(ctx.config.emailCode.pepper, email, code),
        '哈希必须等于 HMAC-SHA256(pepper, email:code)'
      );
      assert.match(row!.codeHash, HEX64_RE, '哈希是 64 位十六进制');

      // 三条"禁止"的负向断言:明文 / 裸 SHA-256 / 无 pepper 的 email:code 拼接都不允许
      assert.notEqual(row!.codeHash, code, '绝不允许明文落库');
      assert.notEqual(row!.codeHash, sha256Hex(code), '绝不允许裸 SHA-256(1e6 空间可离线爆破)');
      assert.notEqual(row!.codeHash, sha256Hex(`${email}:${code}`), '必须带 pepper,不能只是 email:code');
      // email 参与哈希:同一个码换个邮箱,哈希不同
      assert.notEqual(emailCodeHash(ctx.config.emailCode.pepper, 'other@example.com', code), row!.codeHash);
      // 明文的"码"只出现在响应里,且不是哈希的一部分
      assert.ok(!row!.codeHash.includes(code));
    });

    it('同一邮箱 60s 内重复请求 → 429 RATE_LIMITED + details.reason=code_throttled + Retry-After', async () => {
      const email = uniqueEmail('throttle');
      assert.equal((await requestCode(ctx.app, email)).statusCode, 202);

      const second = await requestCode(ctx.app, email);
      assert.equal(second.statusCode, 429, `60s 内重复请求必须 429,实际 ${second.statusCode}:${second.body}`);
      const err = second.json().error;
      assert.equal(err.code, 'RATE_LIMITED');
      assert.equal(err.details.reason, 'code_throttled', '必须给出可判定的 reason');
      const retryAfterSec = Number(err.details.retryAfterSec);
      assert.ok(retryAfterSec >= 1 && retryAfterSec <= 60, `retryAfterSec 应在 1..60,实际 ${retryAfterSec}`);
      assert.equal(second.headers['retry-after'], String(retryAfterSec), '同时给出标准 Retry-After 头');

      // 被限流的请求不得产生第二条验证码
      assert.equal(await ctx.repo.countEmailCodesSince(email, 0), 1);
    });

    it('每小时上限 5 条:窗口内已有 5 条 → 429 code_throttled', async () => {
      const email = uniqueEmail('hourly');
      const now = Date.now();
      // 直接种 5 条历史记录(最近一条在 2 分钟前 → 60s 间隔检查放行,小时窗口内恰好 5 条)
      for (let i = 0; i < 5; i += 1) {
        await ctx.repo.createEmailCode({
          id: randomUUID(),
          email,
          codeHash: 'deadbeef',
          attempts: 0,
          consumedAt: null,
          createdAt: now - 120_000 - i * 1000,
          expiresAt: now + 60_000
        });
      }
      const res = await requestCode(ctx.app, email);
      assert.equal(res.statusCode, 429, `每小时超限必须 429,实际 ${res.statusCode}:${res.body}`);
      assert.equal(res.json().error.code, 'RATE_LIMITED');
      assert.equal(res.json().error.details.reason, 'code_throttled');
      assert.equal(res.json().error.details.retryAfterSec, 3600, '小时窗口返回整个窗口长度作为保守上界');
      assert.equal(await ctx.repo.countEmailCodesSince(email, 0), 5, '被拒的请求不得落库');
    });

    it('每天上限 10 条:窗口内已有 10 条(但小时内只有 1 条)→ 429 code_throttled', async () => {
      const email = uniqueEmail('daily');
      const now = Date.now();
      for (let i = 0; i < 10; i += 1) {
        await ctx.repo.createEmailCode({
          id: randomUUID(),
          email,
          codeHash: 'deadbeef',
          attempts: 0,
          consumedAt: null,
          // i=0 → 5 分钟前(小时内);其余每 2.5 小时一条,全部落在 24 小时内
          createdAt: now - 300_000 - i * 9_000_000,
          expiresAt: now + 60_000
        });
      }
      assert.equal(await ctx.repo.countEmailCodesSince(email, now - 3_600_000), 1, '小时内只有 1 条');
      const res = await requestCode(ctx.app, email);
      assert.equal(res.statusCode, 429, `每天超限必须 429,实际 ${res.statusCode}:${res.body}`);
      assert.equal(res.json().error.details.reason, 'code_throttled');
      assert.equal(res.json().error.details.retryAfterSec, 86400, '天窗口返回整个窗口长度');
    });

    it('邮箱格式非法 / 缺字段 → 400 VALIDATION_FAILED(不是 429/401)', async () => {
      for (const payload of ['not-an-email', '', 'a@', '中文邮箱']) {
        const res = await requestCode(ctx.app, payload);
        assert.equal(res.statusCode, 400, `"${payload}" 必须 400,实际 ${res.statusCode}`);
        assert.equal(res.json().error.code, 'VALIDATION_FAILED');
      }
      const missing = await ctx.app.inject({ method: 'POST', url: '/v1/auth/email/code', payload: {} });
      assert.equal(missing.statusCode, 400);
      assert.equal(missing.json().error.code, 'VALIDATION_FAILED');
    });

    it('关闭回显(devEchoCode=false)时响应里没有 devCode 字段', async () => {
      const app = await makeApp({
        emailCode: { ...ctx.config.emailCode, devEchoCode: false }
      });
      try {
        const res = await requestCode(app.app, uniqueEmail('noecho'));
        assert.equal(res.statusCode, 202);
        assert.equal(res.json().devCode, undefined, '未开启回显时不得出现 devCode 字段');
        assert.deepEqual(Object.keys(res.json()).sort(), ['expiresIn', 'retryAfter', 'sent']);
      } finally {
        await app.close();
      }
    });
  });

  /* ---------------- 验证码登录 ---------------- */

  describe('POST /v1/auth/email/login', () => {
    it('未注册邮箱自动建号:响应与 register 完全同构,账号 is_guest=false 且无口令', async () => {
      const email = uniqueEmail('autocreate');
      const code = (await requestCode(ctx.app, email)).json().devCode;

      const login = await emailLogin(ctx.app, {
        email,
        code,
        deviceName: '验证码设备',
        platform: 'windows',
        deviceId: 'dev_email_autocreate'
      });
      assert.equal(login.statusCode, 200, `验证码登录应 200,实际 ${login.statusCode}:${login.body}`);
      const body = login.json();

      // 与 register 的响应做**同构**校验:外层键与 user 投影键集合都必须一致
      const reg = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/register',
        payload: { email: uniqueEmail('iso'), password: 'password123' }
      });
      assert.equal(reg.statusCode, 201);
      assert.deepEqual(
        Object.keys(body).sort(),
        Object.keys(reg.json()).sort(),
        'email/login 与 register 的响应结构必须一致(契约 §7.6.5)'
      );
      assert.deepEqual(Object.keys(body.user).sort(), Object.keys(reg.json().user).sort());
      assert.deepEqual(
        Object.keys(body.user).sort(),
        ['createdAt', 'email', 'id', 'isGuest'],
        'user 投影恒为 {id,email,isGuest,createdAt}'
      );

      assert.equal(body.user.isGuest, false, '自动建号必须是正式账号(is_guest=false)');
      assert.equal(body.user.email, email.toLowerCase(), 'email 是已验证邮箱');
      assert.equal(body.device.id, 'dev_email_autocreate');
      assert.equal(body.device.platform, 'windows');
      assert.equal(body.accessToken.split('.').length, 3, 'accessToken 应为 JWT');
      assert.ok(body.refreshToken.length >= 40, 'refreshToken 应为 256-bit 随机串');
      assert.equal(body.expiresIn, ctx.config.accessTtlSec);

      // 落库语义(契约 §7.6.5 账号语义硬约束 1)
      const row = await ctx.repo.findUserByEmail(email);
      assert.ok(row, '未注册邮箱必须被自动建号');
      assert.equal(row!.id, body.user.id);
      assert.equal(row!.isGuest, false);
      assert.equal(row!.passwordAlgo, 'none', "无口令账号:password_algo='none'");
      assert.match(row!.passwordHash, /^otp\$[0-9a-f]{64}$/, '占位哈希必须是 otp$<random>,绝不空/明文');
      assert.ok(!row!.passwordHash.includes(code), '占位哈希不得包含验证码');

      // 令牌是"真账号"的令牌:能正常 push(与 register 拿到的完全一致)
      const todo = makeTodo({ title: '验证码账号的待办', updatedAt: Date.now(), createdAt: Date.now() });
      const pushed = await push(ctx.app, body.accessToken, body.device.id, [
        makeOp({ entity: 'todo', entityId: todo.id, payload: todo })
      ]);
      assert.equal(pushed.statusCode, 200, `验证码账号必须能写数据:${JSON.stringify(pushed.body)}`);
      assert.equal(pushed.body.accepted[0]?.applied, true);
    });

    it('已注册的既有账号:直接登录、userId 不变、**口令不被修改**且仍可口令登录', async () => {
      const email = uniqueEmail('existing');
      const password = 'password123';
      const reg = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/register',
        payload: { email, password, deviceName: '原设备', platform: 'android' }
      });
      assert.equal(reg.statusCode, 201);
      const userId = reg.json().user.id;
      const before = await ctx.repo.findUserByEmail(email);

      const code = (await requestCode(ctx.app, email)).json().devCode;
      const login = await emailLogin(ctx.app, { email, code, deviceName: '新设备', platform: 'windows' });
      assert.equal(login.statusCode, 200, `既有账号验证码登录应成功:${login.body}`);
      assert.equal(login.json().user.id, userId, '契约 §7.6.5:已注册邮箱直接登录该账号(同一 userId)');
      assert.equal(login.json().user.isGuest, false);

      const after = await ctx.repo.findUserByEmail(email);
      assert.equal(after!.passwordHash, before!.passwordHash, '验证码登录绝不能修改既有口令');
      assert.equal(after!.passwordAlgo, before!.passwordAlgo, '口令算法也不能被改写');

      // 口令登录仍然可用,且还是同一个账号
      const pwLogin = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { email, password }
      });
      assert.equal(pwLogin.statusCode, 200, `验证码登录后口令登录必须仍然可用:${pwLogin.body}`);
      assert.equal(pwLogin.json().user.id, userId);
    });

    it('无口令账号(password_algo=none)不能用口令登录,且错误与"邮箱不存在"不可区分', async () => {
      const email = uniqueEmail('nopw');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      assert.equal((await emailLogin(ctx.app, { email, code })).statusCode, 200);
      assert.equal((await ctx.repo.findUserByEmail(email))!.passwordAlgo, 'none');

      const byPassword = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { email, password: 'password123' }
      });
      assert.equal(byPassword.statusCode, 401, '无口令账号必须拒绝口令登录');
      assert.equal(byPassword.json().error.code, 'AUTH_INVALID_CREDENTIALS');

      // 连占位哈希本身也不能当口令用
      const placeholder = (await ctx.repo.findUserByEmail(email))!.passwordHash;
      const withPlaceholder = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { email, password: placeholder }
      });
      assert.equal(withPlaceholder.statusCode, 401);

      // 与"邮箱根本不存在"的响应逐字相同 → 不泄漏"账号存在/无口令"这两件事
      const ghost = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { email: uniqueEmail('ghost'), password: 'password123' }
      });
      assert.equal(ghost.statusCode, 401);
      assert.deepEqual(byPassword.json().error, ghost.json().error, '两者必须完全不可区分');
    });

    it('验证码错误 → 401 AUTH_INVALID_CREDENTIALS + details.reason=code_invalid', async () => {
      const email = uniqueEmail('wrong');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const res = await emailLogin(ctx.app, { email, code: wrongCodeFor(code) });
      assert.equal(res.statusCode, 401);
      assert.equal(res.json().error.code, 'AUTH_INVALID_CREDENTIALS', '契约 §7.4 错误码冻结,不得新增');
      assert.equal(res.json().error.details.reason, 'code_invalid');

      // 记录了一次尝试;失败不建号
      assert.equal((await ctx.repo.latestEmailCode(email))!.attempts, 1);
      assert.equal(await ctx.repo.findUserByEmail(email), null);

      // 正确的码仍然可用(未达上限)
      const ok = await emailLogin(ctx.app, { email, code });
      assert.equal(ok.statusCode, 200);
    });

    it('同码连错 5 次 → 第 5 次 code_attempts_exceeded,之后连正确码也作废', async () => {
      const email = uniqueEmail('attempts');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const wrong = wrongCodeFor(code);

      for (let i = 1; i <= 4; i += 1) {
        const res = await emailLogin(ctx.app, { email, code: wrong });
        assert.equal(res.statusCode, 401);
        assert.equal(
          res.json().error.details.reason,
          'code_invalid',
          `第 ${i} 次错误应为 code_invalid,实际 ${res.json().error.details.reason}`
        );
      }
      const fifth = await emailLogin(ctx.app, { email, code: wrong });
      assert.equal(fifth.statusCode, 401);
      assert.equal(fifth.json().error.details.reason, 'code_attempts_exceeded', '达到 5 次即作废');
      assert.equal(fifth.json().error.code, 'AUTH_INVALID_CREDENTIALS');
      assert.equal((await ctx.repo.latestEmailCode(email))!.attempts, 5);

      // 作废后即使填对也不再放行,必须重新获取
      const correct = await emailLogin(ctx.app, { email, code });
      assert.equal(correct.statusCode, 401);
      assert.equal(correct.json().error.details.reason, 'code_attempts_exceeded');
      assert.equal(await ctx.repo.findUserByEmail(email), null, '全程失败不得建号');

      // 重新获取一条新码即可登录(直接种库:真实流程里新码的 created_at 必然晚于旧码,
      // 这里把新码放到 1 秒后以保证它是"最近一条";同时也跳过 60s 间隔限流)
      const freshCode = '135790';
      const now = Date.now();
      await ctx.repo.createEmailCode({
        id: randomUUID(),
        email,
        codeHash: emailCodeHash(ctx.config.emailCode.pepper, email, freshCode),
        attempts: 0,
        consumedAt: null,
        createdAt: now + 1000,
        expiresAt: now + 60_000
      });
      const relogin = await emailLogin(ctx.app, { email, code: freshCode });
      assert.equal(relogin.statusCode, 200, `重新获取验证码后应能登录:${relogin.body}`);
      assert.equal(relogin.json().user.isGuest, false);
    });

    it('验证码过期 → 401 details.reason=code_expired', async () => {
      const email = uniqueEmail('expired');
      const now = Date.now();
      const code = '424242';
      await ctx.repo.createEmailCode({
        id: randomUUID(),
        email,
        codeHash: emailCodeHash(ctx.config.emailCode.pepper, email, code),
        attempts: 0,
        consumedAt: null,
        createdAt: now - 400_000,
        expiresAt: now - 100_000
      });

      const res = await emailLogin(ctx.app, { email, code });
      assert.equal(res.statusCode, 401);
      assert.equal(res.json().error.code, 'AUTH_INVALID_CREDENTIALS');
      assert.equal(res.json().error.details.reason, 'code_expired', '过期与错码必须是不同的 reason');
      assert.equal((await ctx.repo.latestEmailCode(email))!.attempts, 0, '过期校验不应消耗尝试次数,也不建号');
      assert.equal(await ctx.repo.findUserByEmail(email), null);

      // 恰好没过期的边界(expiresAt > now)仍可登录
      const okEmail = uniqueEmail('fresh');
      const fresh = (await requestCode(ctx.app, okEmail)).json().devCode;
      assert.equal((await emailLogin(ctx.app, { email: okEmail, code: fresh })).statusCode, 200);
    });

    it('一次性消费:成功后同码复用失败(且不重复建号)', async () => {
      const email = uniqueEmail('once');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const first = await emailLogin(ctx.app, { email, code });
      assert.equal(first.statusCode, 200);
      const userId = first.json().user.id;

      const row = await ctx.repo.latestEmailCode(email);
      assert.ok(row!.consumedAt != null, '成功校验后必须立即置 consumed_at');

      const second = await emailLogin(ctx.app, { email, code });
      assert.equal(second.statusCode, 401, '同一验证码不可复用');
      assert.equal(second.json().error.details.reason, 'code_invalid');
      assert.equal((await ctx.repo.findUserByEmail(email))!.id, userId, '复用失败不得建出第二个账号');
    });

    it('没有验证码就直接登录 → 401 code_invalid(不泄漏"有没有人请求过")', async () => {
      const email = uniqueEmail('norequest');
      const res = await emailLogin(ctx.app, { email, code: '123456' });
      assert.equal(res.statusCode, 401);
      assert.equal(res.json().error.details.reason, 'code_invalid');
    });

    it('验证码不是 6 位数字 → 400 VALIDATION_FAILED(不是 401)', async () => {
      const email = uniqueEmail('badsyntax');
      await requestCode(ctx.app, email);
      for (const code of ['12345', '1234567', 'abcdef', '12 345', '']) {
        const res = await emailLogin(ctx.app, { email, code });
        assert.equal(res.statusCode, 400, `"${code}" 必须 400,实际 ${res.statusCode}`);
        assert.equal(res.json().error.code, 'VALIDATION_FAILED');
      }
      const badEmail = await emailLogin(ctx.app, { email: 'not-an-email', code: '123456' });
      assert.equal(badEmail.statusCode, 400);
      assert.equal(badEmail.json().error.code, 'VALIDATION_FAILED');
    });

    it('deviceName / platform 省略时与 register/login 一样有兜底默认值', async () => {
      const email = uniqueEmail('nodevice');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const res = await emailLogin(ctx.app, { email, code });
      assert.equal(res.statusCode, 200, `契约 §7.6.5 把设备字段列为可选:${res.body}`);
      assert.equal(res.json().device.name, '未命名设备');
      assert.equal(res.json().device.platform, 'unknown');
    });

    it('登录/刷新共用同一套令牌体系:验证码登录拿到的 refreshToken 可刷新', async () => {
      const email = uniqueEmail('refresh');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const login = await emailLogin(ctx.app, { email, code });
      assert.equal(login.statusCode, 200);

      const refreshed = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/refresh',
        payload: { refreshToken: login.json().refreshToken }
      });
      assert.equal(refreshed.statusCode, 200, `refresh 必须可用:${refreshed.body}`);
      assert.equal(refreshed.json().user.id, login.json().user.id);
      assert.equal(refreshed.json().user.email, email.toLowerCase());
      assert.equal(refreshed.json().user.isGuest, false);
    });
  });

  /* ---------------- 账号删除(契约 §9 级联)---------------- */

  describe('账号删除', () => {
    it('DELETE /v1/account 会连该邮箱的验证码一起清掉', async () => {
      const email = uniqueEmail('cascade');
      const code = (await requestCode(ctx.app, email)).json().devCode;
      const login = await emailLogin(ctx.app, { email, code });
      assert.equal(login.statusCode, 200);

      // 再往库里种一条**未消费**的验证码(等价于"用户又请求了一条还没用的码";
      // 直接种库是为了跳过 60s 间隔,把断言集中到"销号是否清码"上)
      const now = Date.now();
      await ctx.repo.createEmailCode({
        id: randomUUID(),
        email,
        codeHash: emailCodeHash(ctx.config.emailCode.pepper, email, '777777'),
        attempts: 0,
        consumedAt: null,
        createdAt: now,
        expiresAt: now + 60_000
      });
      assert.equal(await ctx.repo.countEmailCodesSince(email, 0), 2, '销号前库里有 2 条验证码');

      const del = await ctx.app.inject({
        method: 'DELETE',
        url: '/v1/account',
        headers: { authorization: `Bearer ${login.json().accessToken}` }
      });
      assert.equal(del.statusCode, 204);

      assert.equal(await ctx.repo.findUserByEmail(email), null);
      assert.equal(
        await ctx.repo.countEmailCodesSince(email, 0),
        0,
        '销号必须清掉该邮箱的验证码(否则旧码能把刚删的邮箱重新建号)'
      );
    });
  });
});

/* ============================================================================
 * 2. http 发信通道 —— 真的发一次(本地 stub HTTP 服务)
 * ==========================================================================*/

interface StubCall {
  method: string;
  url: string;
  authorization: string | undefined;
  contentType: string | undefined;
  body: { to?: string; subject?: string; text?: string };
}

interface MailStub {
  port: number;
  calls: StubCall[];
  /** 切到"网关故障"模式(返回 503) */
  fail(nextStatus: number | null): void;
  close(): Promise<void>;
}

async function startMailStub(): Promise<MailStub> {
  const calls: StubCall[] = [];
  let failStatus: number | null = null;

  const server: Server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks).toString('utf8');
    let body: StubCall['body'] = {};
    try {
      body = JSON.parse(raw) as StubCall['body'];
    } catch {
      /* 保留空对象,便于断言失败信息 */
    }
    calls.push({
      method: req.method ?? '',
      url: req.url ?? '',
      authorization: req.headers.authorization,
      contentType: req.headers['content-type'],
      body
    });

    if (failStatus !== null) {
      res.writeHead(failStatus, { 'content-type': 'application/json' });
      res.end('{"error":"gateway down"}');
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  });

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    port,
    calls,
    fail(nextStatus: number | null) {
      failStatus = nextStatus;
    },
    async close() {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  };
}

describe('http 发信通道(契约 §7.6.5)', () => {
  it('真的 POST {to,subject,text} 到网关(带 Bearer),并用报文里的验证码完成登录', async () => {
    const stub = await startMailStub();
    const ctx = await makeApp({
      mail: {
        transport: 'http',
        httpUrl: `http://127.0.0.1:${stub.port}/send`,
        httpToken: 'gw-token',
        httpTimeoutMs: 3000
      }
    });
    try {
      const email = uniqueEmail('http');
      const res = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/email/code',
        payload: { email }
      });
      assert.equal(res.statusCode, 202, `http 通道请求应 202,实际 ${res.statusCode}:${res.body}`);
      assert.equal(res.json().devCode, undefined, 'http 通道绝不回显 devCode(即使测试开了回显开关)');

      // 网关真的收到了报文
      assert.equal(stub.calls.length, 1, '必须真的发了一次 HTTP 请求');
      const call = stub.calls[0];
      assert.equal(call.method, 'POST');
      assert.equal(call.url, '/send');
      assert.equal(call.authorization, 'Bearer gw-token', '必须带 Authorization: Bearer <ORDO_MAIL_HTTP_TOKEN>');
      assert.match(call.contentType ?? '', /application\/json/);
      assert.equal(call.body.to, email);
      assert.match(call.body.subject ?? '', /Ordo/, '主题应表明是 Ordo 登录验证码');
      const code = /(\d{6})/.exec(call.body.text ?? '')?.[1];
      assert.ok(code && CODE_RE.test(code), `邮件正文里应有 6 位验证码,实际:${call.body.text}`);

      // 正文不含"该邮箱是否已注册"的差异信息
      assert.ok(!/注册|未注册|已存在/.test(call.body.text ?? ''), '邮件正文不得泄漏账号是否存在');

      // 库里存的仍是哈希(不是邮件正文里的明文)
      const row = await ctx.repo.latestEmailCode(email);
      assert.equal(row!.codeHash, emailCodeHash(ctx.config.emailCode.pepper, email, code!));
      assert.ok(!(call.body.text ?? '').includes(row!.codeHash));

      // 用真报文里的验证码完成端到端登录
      const login = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/email/login',
        payload: { email, code, deviceName: '网关设备', platform: 'harmony' }
      });
      assert.equal(login.statusCode, 200, `用网关投递的验证码应能登录:${login.body}`);
      assert.equal(login.json().user.email, email.toLowerCase());
      assert.equal(login.json().user.isGuest, false);
    } finally {
      await ctx.close();
      await stub.close();
    }
  });

  it('网关非 2xx → 500 INTERNAL + details.reason=mail_failed,且不落库、不占用限流额度', async () => {
    const stub = await startMailStub();
    stub.fail(503);
    const ctx = await makeApp({
      mail: {
        transport: 'http',
        httpUrl: `http://127.0.0.1:${stub.port}/send`,
        httpToken: null,
        httpTimeoutMs: 3000
      }
    });
    try {
      const email = uniqueEmail('mailfail');
      const res = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/email/code',
        payload: { email }
      });
      assert.equal(res.statusCode, 500, `发信失败必须 500,实际 ${res.statusCode}:${res.body}`);
      assert.equal(res.json().error.code, 'INTERNAL');
      assert.equal(res.json().error.details.reason, 'mail_failed');
      assert.equal(stub.calls.length, 1, '确实尝试过发信');
      assert.equal(stub.calls[0].authorization, undefined, '未配置 token 时不带 Authorization 头');

      // 发信失败:① 库里不留验证码 ② 不占用限流额度
      assert.equal(await ctx.repo.countEmailCodesSince(email, 0), 0, '发信失败不得在库里留下验证码');
      const listed = await ctx.repo.latestEmailCode(email);
      assert.equal(listed, null);

      // 网关恢复后,同一邮箱立刻可以再请求(没有被 60s 限流误伤)
      stub.fail(null);
      const retry = await ctx.app.inject({
        method: 'POST',
        url: '/v1/auth/email/code',
        payload: { email }
      });
      assert.equal(retry.statusCode, 202, `网关恢复后应立即放行:${retry.body}`);
      const code = /(\d{6})/.exec(stub.calls[1]?.body.text ?? '')?.[1];
      assert.ok(code);
      assert.equal(await ctx.repo.countEmailCodesSince(email, 0), 1);
    } finally {
      await ctx.close();
      await stub.close();
    }
  });
});

/* ============================================================================
 * 3. 配置硬约束(契约 §7.6.5 / §9)
 * ==========================================================================*/

describe('邮箱验证码配置(契约 §7.6.5 / §9)', () => {
  const prodBase = {
    NODE_ENV: 'production',
    JWT_SECRET: 'p'.repeat(32),
    ORDO_CODE_PEPPER: 'pepper-for-production'
  };

  it('默认值:TTL 300s / retryAfter 60s / 每小时 5 / 每天 10 / 尝试 5 次', () => {
    const config = loadConfig({ NODE_ENV: 'test' });
    assert.deepEqual(
      {
        ttlSec: config.emailCode.ttlSec,
        retryAfterSec: config.emailCode.retryAfterSec,
        maxPerHour: config.emailCode.maxPerHour,
        maxPerDay: config.emailCode.maxPerDay,
        maxAttempts: config.emailCode.maxAttempts
      },
      { ttlSec: 300, retryAfterSec: 60, maxPerHour: 5, maxPerDay: 10, maxAttempts: 5 }
    );
    assert.equal(config.mail.transport, 'console', '默认走 console 通道(本地开发)');
  });

  it('生产环境 + ORDO_DEV_ECHO_CODE=1 → 拒绝启动', () => {
    assert.throws(
      () => loadConfig({ ...prodBase, ORDO_DEV_ECHO_CODE: '1' }),
      /ORDO_DEV_ECHO_CODE/,
      '契约 §7.6.5:生产环境开启回显必须直接拒绝启动'
    );
  });

  it('生产环境缺 ORDO_CODE_PEPPER → 拒绝启动;开发环境回退 JWT_SECRET', () => {
    assert.throws(
      () => loadConfig({ NODE_ENV: 'production', JWT_SECRET: 'p'.repeat(32) }),
      /ORDO_CODE_PEPPER/,
      '契约 §9:生产必填 pepper'
    );
    const dev = loadConfig({ NODE_ENV: 'test', JWT_SECRET: 'dev-secret' });
    assert.equal(dev.emailCode.pepper, 'dev-secret', '开发/测试回退到 JWT_SECRET');
    const prod = loadConfig(prodBase);
    assert.equal(prod.emailCode.pepper, 'pepper-for-production');
  });

  it('ORDO_MAIL_TRANSPORT 取值校验:未知值 / http 缺 URL → 拒绝启动', () => {
    assert.throws(() => loadConfig({ ORDO_MAIL_TRANSPORT: 'smtp' }), /ORDO_MAIL_TRANSPORT/);
    assert.throws(
      () => loadConfig({ ORDO_MAIL_TRANSPORT: 'http' }),
      /ORDO_MAIL_HTTP_URL/,
      'http 通道没有网关地址 = 每次发信都失败,必须启动即拒绝'
    );
    const ok = loadConfig({
      ORDO_MAIL_TRANSPORT: 'http',
      ORDO_MAIL_HTTP_URL: 'https://mail.example.com/send',
      ORDO_MAIL_HTTP_TOKEN: 't'
    });
    assert.equal(ok.mail.transport, 'http');
    assert.equal(ok.mail.httpUrl, 'https://mail.example.com/send');
    assert.equal(ok.mail.httpToken, 't');
  });

  it('生产环境的 console 通道日志**不含验证码**(契约 §9)', async () => {
    const config = loadConfig(prodBase);
    assert.equal(config.mail.transport, 'console');

    const lines: string[] = [];
    const logger: MailLogger = {
      info: (obj, msg) => lines.push(`${msg} ${JSON.stringify(obj)}`),
      warn: (obj, msg) => lines.push(`${msg} ${JSON.stringify(obj)}`)
    };
    const sender = createMailSender(config, logger);
    await sender.send({ to: 'a@b.com', subject: 'Ordo 登录验证码', text: '您的 Ordo 登录验证码是 654321,5 分钟内有效。' });

    assert.equal(lines.length, 1, 'console 通道只写一条日志');
    assert.ok(!lines.join('').includes('654321'), '生产环境日志绝不允许出现验证码');
    assert.match(lines[0], /不会真的投递/, '应提示 console 通道不投递邮件');
  });
});
