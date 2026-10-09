-- 迁移 002:把 deviceId 相关列从 uuid 统一为 text
--
-- 背景(契约 §7.2 / §7.4):
--   deviceId 是**客户端生成的不透明短串**,契约示例为 `"deviceId":"dev_7f3a..."`,
--   并通过 `X-Ordo-Device: <deviceId>` 传递。四端实现确实都生成 `dev_<opaque>`:
--     * iOS             `newDeviceId()`            -> "dev_" + uuid(去连字符)前 10 位
--     * Harmony         `newIdWithPrefix('dev')`   -> "dev_" + 16 进制 20 位
--     * Android/Windows 共享核心 `OrdoEngine`       -> "dev_" + ULID 后 10 位小写
--   而 001 早期版本把 `devices.id` / `refresh_tokens.device_id` 定义成 uuid,
--   于是**任何按契约实现的客户端**在 register/login/push 时都会拿到
--   500 `invalid input syntax for type uuid: "dev_..."`(22P02)。
--   `ops.device_id` 本来就是 text,三张表类型不一致。
--
-- 本迁移把三列统一为 text。对**全新库**是 no-op(001 已改为 text);
-- 对**已经跑过旧版 001 的库**执行实际的类型变更。整体幂等,可重复执行。
--
-- ⚠️ 顺序很关键:devices.id 被 refresh_tokens.device_id 的外键引用,
--    PostgreSQL 不允许直接改变被引用列的类型
--    (`foreign key constraint ... cannot be implemented`)。
--    因此必须:① 删外键 → ② 先改引用列 refresh_tokens.device_id → ③ 再改被引用列 devices.id
--    → ④ 重建外键。整个迁移包在**一个 DO 块**里,保证原子性(失败则全部回滚)。

do $$
declare
  fk_name          text;
  fk_delete_action "char";
  devices_id_type  text;
  rt_device_type   text;
  ops_device_type  text;
begin
  -- 读取当前状态
  select data_type into devices_id_type
  from information_schema.columns
  where table_schema = 'public' and table_name = 'devices' and column_name = 'id';

  select data_type into rt_device_type
  from information_schema.columns
  where table_schema = 'public' and table_name = 'refresh_tokens' and column_name = 'device_id';

  select data_type into ops_device_type
  from information_schema.columns
  where table_schema = 'public' and table_name = 'ops' and column_name = 'device_id';

  -- 已经是目标形状(全新库走 001 后就是这种):什么都不做
  if devices_id_type = 'text' and rt_device_type = 'text' and coalesce(ops_device_type, 'text') = 'text' then
    return;
  end if;

  -- ① 找到 refresh_tokens → devices 的外键并记录其删除行为,然后删掉
  select c.conname, c.confdeltype
    into fk_name, fk_delete_action
  from pg_constraint c
  where c.conrelid = 'refresh_tokens'::regclass
    and c.contype = 'f'
    and c.confrelid = 'devices'::regclass
  limit 1;

  if fk_name is not null then
    execute format('alter table refresh_tokens drop constraint %I', fk_name);
  end if;

  -- ② 先改引用列(refresh_tokens.device_id),此时已无外键约束
  if rt_device_type is not null and rt_device_type <> 'text' then
    alter table refresh_tokens alter column device_id type text;
  end if;

  -- ③ 再改被引用列(devices.id)
  if devices_id_type is not null and devices_id_type <> 'text' then
    alter table devices alter column id type text;
  end if;

  -- ④ 按 text 重建外键,保留原有的 ON DELETE 行为(001 用的是 on delete set null)
  if fk_name is not null then
    execute format(
      'alter table refresh_tokens add constraint %I foreign key (device_id) references devices (id) on delete %s',
      fk_name,
      case fk_delete_action
        when 'c' then 'cascade'
        when 'n' then 'set null'
        when 'd' then 'set default'
        else 'no action'
      end
    );
  end if;

  -- ⑤ ops.device_id 无外键,只需类型一致
  if ops_device_type is not null and ops_device_type <> 'text' then
    alter table ops alter column device_id type text;
  end if;
end $$;

-- 自检:三列必须都是 text(仍不是就报错,让本次迁移整体回滚)
do $$
declare
  bad int;
begin
  select count(*) into bad
  from information_schema.columns
  where table_schema = 'public'
    and (
      (table_name = 'devices' and column_name = 'id' and data_type <> 'text')
      or (table_name = 'refresh_tokens' and column_name = 'device_id' and data_type <> 'text')
      or (table_name = 'ops' and column_name = 'device_id' and data_type <> 'text')
    );

  if bad > 0 then
    raise exception 'deviceId 相关列仍不是 text(% 处不匹配)', bad;
  end if;
end $$;
