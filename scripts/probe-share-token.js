// 방 공유 토큰이 붙은 최신 잡 하나를 찾아 알려준다.
// 인증 강화 후에도 "방 멤버 무인증 재생" 경로가 살아 있는지 확인하는 데 쓴다.
require('dotenv').config();
const { Pool } = require('pg');
const pool = new Pool({
  host: process.env.PG_HOST || '10.30.10.170', port: 5432,
  user: process.env.PG_USER || 'tteona', password: process.env.PG_PASSWORD,
  database: process.env.PG_DB || 'tteona_db', connectionTimeoutMillis: 5000,
});
(async () => {
  const r = await pool.query(
    `SELECT id, options->>'shareToken' AS tok
       FROM vlog_jobs
      WHERE options->>'shareToken' IS NOT NULL
      ORDER BY id DESC LIMIT 1`
  );
  if (r.rows.length === 0) console.log('  NOSHARE');
  else console.log(`  SHARE ${r.rows[0].id} ${r.rows[0].tok}`);
  await pool.end();
})().catch(e => { console.error('  조회 실패:', e.message); process.exit(1); });
