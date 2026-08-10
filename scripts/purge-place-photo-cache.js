// place_photos의 TourAPI 캐시를 비운다.
//
// tour-photo의 후보 선별 기준을 고쳐도, 이미 30일짜리 양성 캐시로 박혀 있는 옛 오답은
// 그대로 서빙된다 — 로직 수정과 이 삭제는 한 세트다.
// 접속 정보는 server.js와 같은 값을 쓴다(.env + 동일 기본값).
require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PG_HOST || '10.30.10.170',
  port: 5432,
  user: process.env.PG_USER || 'tteona',
  password: process.env.PG_PASSWORD,
  database: process.env.PG_DB || 'tteona_db',
  connectionTimeoutMillis: 5000,
});

(async () => {
  const before = await pool.query("SELECT count(*)::int AS n FROM place_photos WHERE source = 'tour'");
  const del = await pool.query("DELETE FROM place_photos WHERE source = 'tour'");
  const after = await pool.query("SELECT count(*)::int AS n FROM place_photos");
  console.log(`  tour 캐시 ${before.rows[0].n}건 → 삭제 ${del.rowCount}건 / 남은 전체 ${after.rows[0].n}건`);
  await pool.end();
})().catch((e) => {
  console.error('  ✗ 캐시 삭제 실패:', e.message);
  process.exit(1);
});
