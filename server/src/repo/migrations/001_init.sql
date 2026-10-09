-- Ordo 服务端初始表结构 —— 契约 §8(存储与迁移)
-- 迁移版本:001 · schemaVersion = 1

create table if not exists users (
  id            uuid primary key,
  email         text        not null unique,
  password_hash text        not null,
  password_algo text        not null default 'argon2id',
  created_at    bigint      not null
);

create table if not exists devices (
  -- deviceId 是**客户端生成的不透明短串**(契约 §7.2 示例 `"deviceId":"dev_7f3a..."`),不是 uuid。
  -- 早期版本这里写成 uuid,导致契约形态的 deviceId 在注册时直接 500
  -- (`invalid input syntax for type uuid: "dev_..."`)—— 在真实 PostgreSQL 上冒烟时暴露,已修正。
  -- 现在与 ops.device_id(text)、refresh_tokens.device_id(text)保持一致。
  id           text   primary key,
  user_id      uuid   not null references users (id) on delete cascade,
  name         text   not null,
  platform     text   not null,
  created_at   bigint not null,
  last_seen_at bigint not null
);
create index if not exists devices_user_idx on devices (user_id);

-- refresh token:仅存 SHA-256 哈希(契约 §9)
create table if not exists refresh_tokens (
  token_hash  text primary key,
  user_id     uuid   not null references users (id) on delete cascade,
  device_id   text   null references devices (id) on delete set null,
  created_at  bigint not null,
  expires_at  bigint not null,
  revoked_at  bigint null,
  replaced_by text   null
);
create index if not exists refresh_tokens_user_idx on refresh_tokens (user_id);

-- 实体表:所有实体(todo/project/area/heading/tag)共用,payload 为完整快照
create table if not exists entities (
  user_id    uuid    not null references users (id) on delete cascade,
  entity     text    not null,
  entity_id  text    not null,
  payload    jsonb   not null,
  updated_at bigint  not null,
  deleted    boolean not null default false,
  server_seq bigint  not null default 0,
  primary key (user_id, entity, entity_id)
);
create index if not exists entities_user_seq_idx on entities (user_id, server_seq);

-- op 日志:server_seq 单调递增(bigserial),op_id 幂等键
create table if not exists ops (
  server_seq bigserial primary key,
  user_id    uuid   not null references users (id) on delete cascade,
  op_id      text   not null,
  device_id  text   null,
  entity     text   not null,
  entity_id  text   not null,
  type       text   not null,
  payload    jsonb  null,
  client_ts  bigint not null,
  created_at bigint not null,
  unique (user_id, op_id)
);
create index if not exists ops_user_seq_idx on ops (user_id, server_seq);

-- Fastlane:提醒独立索引,后台每 1 秒扫描未来 60 秒到期(契约 §7.5)
create table if not exists reminders (
  id         text primary key,
  user_id    uuid    not null references users (id) on delete cascade,
  todo_id    text    not null,
  at         bigint  not null,
  title      text    not null,
  fired      boolean not null default false,
  updated_at bigint  not null,
  unique (user_id, todo_id)
);
create index if not exists reminders_due_idx on reminders (user_id, at) where fired = false;

-- 迁移版本表
create table if not exists schema_migrations (
  version    int primary key,
  applied_at bigint not null
);
