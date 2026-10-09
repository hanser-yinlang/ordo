import { Client } from 'pg';
const url = process.env.DATABASE_URL;
if (!url) {
  console.error('DATABASE_URL is required, e.g. postgres://user:pass@127.0.0.1:55432/ordo');
  process.exit(2);
}
const c = new Client({ connectionString: url });
await c.connect();
const v = await c.query('select version() as v');
console.log(v.rows[0].v.split(',')[0]);
const t = await c.query(`select count(*)::int as n from information_schema.tables where table_schema = 'public'`);
console.log('public 表数量 =', t.rows[0].n, '(0 = 干净,可直接 pnpm migrate)');
const d = await c.query(`select datname from pg_database where datistemplate = false order by datname`);
console.log('数据库:', d.rows.map((r) => r.datname).join(', '));
await c.end();
