const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const { Pool } = require('pg');
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const serviceAccount = require('./firebase-service-account.json');
initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();

const pgPool = new Pool({
  host: process.env.PG_HOST || '10.30.10.170',
  port: 5432,
  user: process.env.PG_USER || 'tteona',
  password: process.env.PG_PASSWORD || 'tteona2026!Secure',
  database: process.env.PG_DB || 'tteona_db',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});
pgPool.on('error', (err) => console.error('PostgreSQL pool error:', err));

const app = express();
const PORT = 3000;

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({ origin: ['https://tteona.kr', 'https://www.tteona.kr'] }));
app.use(morgan('combined'));
app.use(express.json());

// ─── Health / API root ───────────────────────────────────────────────────────

app.get('/health', (req, res) => {
  res.json({ status: 'ok', server: 'tteona-api', time: new Date().toISOString() });
});

app.get('/api', (req, res) => {
  res.json({ message: 'tteona API server v1.0' });
});

// ─── JSON API ────────────────────────────────────────────────────────────────

app.get('/api/courses/:courseId', async (req, res) => {
  try {
    const doc = await db.collection('courses').doc(req.params.courseId).get();
    if (!doc.exists) return res.status(404).json({ error: 'Course not found' });
    res.json({ id: doc.id, ...doc.data() });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── Places 캐시 API ─────────────────────────────────────────────────────────
// iOS가 Google Places API 결과를 PostgreSQL에 저장/조회
// 장소 이름 기반 캐시 키 (PlaceDetailService.cacheKey 로직과 동일)

app.get('/api/places/cache', async (req, res) => {
  const key = req.query.key;
  if (!key) return res.status(400).json({ error: 'key required' });

  try {
    const result = await pgPool.query(
      'SELECT payload FROM places_cache WHERE place_id = $1 AND expires_at > NOW()',
      [key]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'cache miss' });
    res.json({ source: 'postgres', ...result.rows[0].payload });
  } catch (err) {
    console.error('Places cache GET error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post('/api/places/cache', async (req, res) => {
  const { cacheKey, photos, rating, reviewCount, reviews } = req.body;
  if (!cacheKey) return res.status(400).json({ error: 'cacheKey required' });

  try {
    const payload = JSON.stringify({ photos: photos || [], rating, reviewCount: reviewCount || 0, reviews: reviews || [] });
    await pgPool.query(`
      INSERT INTO places_cache (place_id, rating, user_ratings, payload, expires_at)
      VALUES ($1, $2, $3, $4, NOW() + INTERVAL '30 days')
      ON CONFLICT (place_id) DO UPDATE SET
        rating = EXCLUDED.rating,
        user_ratings = EXCLUDED.user_ratings,
        payload = EXCLUDED.payload,
        fetched_at = NOW(),
        expires_at = NOW() + INTERVAL '30 days'
    `, [cacheKey, rating ?? null, reviewCount ?? 0, payload]);

    res.json({ ok: true });
  } catch (err) {
    console.error('Places cache POST error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── 코스 공유 OG 링크 ────────────────────────────────────────────────────────
// iOS 앱: /course?id=UUID (쿼리 파라미터)
// 직접 링크: /course/UUID (경로 파라미터) — 두 형식 모두 지원

app.get('/course', (req, res) => {
  const courseId = req.query.id;
  if (!courseId) return res.status(400).send('<h1>잘못된 요청입니다</h1>');
  return fetchAndRenderCourse(courseId, res);
});

app.get('/course/:courseId', (req, res) => {
  return fetchAndRenderCourse(req.params.courseId, res);
});

async function fetchAndRenderCourse(courseId, res) {

  try {
    const doc = await db.collection('courses').doc(courseId).get();

    if (!doc.exists) {
      return res.status(404).send(courseNotFoundHtml());
    }

    const data = doc.data();
    const courseName = data.courseName || '떠나 코스';
    const places = (data.places || [])
      .sort((a, b) => (a.order || 0) - (b.order || 0));
    const placeNames = places.map(p => p.placeName).filter(Boolean);
    const placeCount = placeNames.length;

    const ogDescription =
      placeCount > 0
        ? `장소 ${placeCount}곳 · ${placeNames.slice(0, 3).join(', ')}${placeCount > 3 ? ' 외' : ''}`
        : '떠나 앱에서 이 코스를 만나보세요';

    res.send(courseHtml({ courseId, courseName, ogDescription, placeNames, placeCount }));
  } catch (err) {
    console.error(err);
    res.status(500).send('<h1>오류가 발생했습니다</h1>');
  }
}

// ─── HTML 생성 헬퍼 ──────────────────────────────────────────────────────────

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

function courseHtml({ courseId, courseName, ogDescription, placeNames, placeCount }) {
  const ogTitle = `${courseName} — 떠나 코스`;
  const ogUrl   = `https://tteona.kr/course/${courseId}`;
  const ogImage = 'https://tteona.kr/og-image.png';

  const stopsHtml = placeNames.map((name, i) => {
    const side = i % 2 === 0 ? 'left' : 'right';
    return `
      <div class="stop ${side}">
        ${side === 'left'
          ? `<div class="stop-text"><span class="stop-name">${escapeHtml(name)}</span></div>
             <div class="stop-circle">${i + 1}</div>
             <div class="stop-spacer"></div>`
          : `<div class="stop-spacer"></div>
             <div class="stop-circle">${i + 1}</div>
             <div class="stop-text"><span class="stop-name">${escapeHtml(name)}</span></div>`
        }
      </div>`;
  }).join('');

  return `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(courseName)} — tteona</title>

  <meta property="og:type"        content="website">
  <meta property="og:title"       content="${escapeHtml(ogTitle)}">
  <meta property="og:description" content="${escapeHtml(ogDescription)}">
  <meta property="og:image"       content="${ogImage}">
  <meta property="og:url"         content="${ogUrl}">
  <meta name="twitter:card"        content="summary_large_image">
  <meta name="twitter:title"       content="${escapeHtml(ogTitle)}">
  <meta name="twitter:description" content="${escapeHtml(ogDescription)}">
  <meta name="twitter:image"       content="${ogImage}">

  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Fredoka:wght@600&family=Noto+Sans+KR:wght@400;600;700;900&display=swap" rel="stylesheet">

  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }

    html, body {
      min-height: 100%;
      background: #160F14;
    }

    body {
      font-family: 'Noto Sans KR', -apple-system, sans-serif;
      max-width: 480px;
      margin: 0 auto;
      position: relative;
      overflow-x: hidden;
    }

    /* ── 배경 글로우 ── */
    .glow-top {
      position: fixed;
      top: -120px;
      left: 50%;
      transform: translateX(-50%);
      width: 500px;
      height: 500px;
      background: radial-gradient(circle, rgba(255,107,53,0.10) 0%, transparent 65%);
      pointer-events: none;
      z-index: 0;
    }

    /* ── 헤더 ── */
    .header {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 24px 24px 0;
      position: relative;
      z-index: 2;
    }

    .header-icon {
      width: 26px;
      height: 26px;
      object-fit: contain;
    }

    .header-wordmark {
      font-family: 'Fredoka', cursive;
      font-weight: 600;
      font-size: 22px;
      color: #FF6B35;
      letter-spacing: 0.5px;
      line-height: 1;
    }

    /* ── 캐릭터 + 코스명 히어로 ── */
    .hero {
      position: relative;
      z-index: 2;
      padding: 20px 24px 0;
      display: flex;
      align-items: flex-end;
      gap: 16px;
    }

    .hero-char {
      width: 110px;
      height: 110px;
      object-fit: contain;
      flex-shrink: 0;
      filter: drop-shadow(0 4px 20px rgba(255,107,53,0.25));
    }

    .hero-text {
      flex: 1;
      padding-bottom: 8px;
    }

    .course-eyebrow {
      font-size: 10px;
      font-weight: 700;
      color: #FF6B35;
      letter-spacing: 2px;
      text-transform: uppercase;
      margin-bottom: 6px;
      opacity: 0.9;
    }

    .course-title {
      font-size: 26px;
      font-weight: 900;
      color: #fff;
      letter-spacing: -0.5px;
      line-height: 1.2;
    }

    /* ── 장소 배지 ── */
    .badge-row {
      padding: 16px 24px 0;
      position: relative;
      z-index: 2;
    }

    .place-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      background: rgba(255,107,53,0.12);
      border: 1px solid rgba(255,107,53,0.28);
      color: #FF9A6C;
      font-size: 12px;
      font-weight: 700;
      padding: 5px 14px;
      border-radius: 20px;
    }

    /* ── 구분선 ── */
    .sep {
      margin: 28px 24px 0;
      height: 1px;
      background: rgba(255,255,255,0.06);
      position: relative;
      z-index: 2;
    }

    /* ── 경로 맵 ── */
    .route-section {
      padding: 28px 0 20px;
      position: relative;
      z-index: 2;
    }

    .route-eyebrow {
      font-size: 10px;
      font-weight: 700;
      color: rgba(255,255,255,0.25);
      letter-spacing: 2px;
      text-transform: uppercase;
      padding: 0 24px;
      margin-bottom: 20px;
    }

    /* 중앙 점선 */
    .route-map {
      position: relative;
    }

    .route-map::before {
      content: '';
      position: absolute;
      left: 50%;
      top: 15px;
      bottom: 15px;
      width: 1.5px;
      transform: translateX(-50%);
      background: repeating-linear-gradient(
        to bottom,
        rgba(255,107,53,0.5) 0, rgba(255,107,53,0.5) 5px,
        transparent 5px, transparent 10px
      );
      z-index: 0;
    }

    .stop {
      display: flex;
      align-items: center;
      min-height: 58px;
      position: relative;
      z-index: 1;
    }

    .stop-text {
      flex: 1;
      padding: 0 16px;
    }

    .stop.left .stop-text { text-align: right; padding-left: 24px; padding-right: 16px; }
    .stop.right .stop-text { text-align: left; padding-right: 24px; padding-left: 16px; }

    .stop-spacer { flex: 1; }

    .stop-circle {
      width: 30px;
      height: 30px;
      border-radius: 50%;
      background: #FF6B35;
      color: #fff;
      font-size: 12px;
      font-weight: 700;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      box-shadow: 0 0 0 4px rgba(255,107,53,0.15), 0 0 16px rgba(255,107,53,0.3);
    }

    .stop-name {
      font-size: 13px;
      font-weight: 600;
      color: rgba(255,255,255,0.85);
      line-height: 1.35;
    }

    /* ── 하단 장식 (캐릭터 그림자) ── */
    .char-bg {
      position: fixed;
      bottom: 130px;
      right: -30px;
      width: 140px;
      opacity: 0.06;
      pointer-events: none;
      z-index: 0;
      transform: scaleX(-1);
    }

    /* ── CTA ── */
    .cta {
      padding: 28px 24px 52px;
      display: flex;
      flex-direction: column;
      gap: 12px;
      position: relative;
      z-index: 2;
    }

    .open-btn {
      width: 100%;
      padding: 17px;
      border-radius: 14px;
      background: #FF6B35;
      color: #fff;
      font-size: 17px;
      font-weight: 700;
      border: none;
      cursor: pointer;
      font-family: inherit;
      box-shadow: 0 8px 28px rgba(255,107,53,0.38);
      transition: opacity 0.15s;
    }

    .open-btn:active { opacity: 0.85; }

    .store-btn {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      padding: 15px;
      border-radius: 14px;
      background: transparent;
      border: 1px solid rgba(255,255,255,0.15);
      color: rgba(255,255,255,0.6);
      text-decoration: none;
      font-size: 15px;
      font-weight: 600;
    }

    .store-btn svg { width: 16px; height: 16px; fill: rgba(255,255,255,0.6); flex-shrink: 0; }
  </style>
</head>
<body>
  <div class="glow-top"></div>

  <!-- 헤더 -->
  <div class="header">
    <span class="header-wordmark">tteona</span>
  </div>

  <!-- 히어로 -->
  <div class="hero">
    <img class="hero-char" src="/tteoni-travel.png" alt="">
    <div class="hero-text">
      <div class="course-eyebrow">COURSE SHARE</div>
      <h1 class="course-title">${escapeHtml(courseName)}</h1>
    </div>
  </div>

  <!-- 장소 배지 -->
  <div class="badge-row">
    <div class="place-badge">
      <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#FF9A6C" stroke-width="2.5" stroke-linecap="round">
        <path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/>
        <circle cx="12" cy="10" r="3"/>
      </svg>
      장소 ${placeCount}곳
    </div>
  </div>

  <div class="sep"></div>

  <!-- 경로 맵 -->
  ${stopsHtml ? `
  <div class="route-section">
    <div class="route-eyebrow">ROUTE</div>
    <div class="route-map">
      ${stopsHtml}
    </div>
  </div>
  <div class="sep"></div>` : ''}

  <!-- CTA -->
  <div class="cta">
    <button class="open-btn" onclick="openApp()">떠나 앱에서 열기</button>
    <a class="store-btn" id="storeBtn" href="https://apps.apple.com/kr/app/%EB%96%A0%EB%82%98/id6767218543">
      <svg viewBox="0 0 814 1000" xmlns="http://www.w3.org/2000/svg">
        <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76 0-103.7 40.8-165.9 40.8s-105-37.5-155.5-127.4C46 790.7 0 663.5 0 541.8c0-207.8 134.9-317.9 267.9-317.9 75.3 0 137.9 49.2 184.2 49.2 44.4 0 114.5-52.1 201.5-52.1zM568.5 81.4C588.5 55.4 602.8 19.9 602.8 0c0-1.9-.1-3.8-.3-5.7-30.5 1.1-67.1 20.4-89.3 47.9-17.9 21.3-35.5 57.2-35.5 87.2 0 2 .3 4 .5 4.7 2 .3 4.1.5 6.1.5 28.3 0 63.2-18.8 84.2-53.2z"/>
      </svg>
      App Store에서 다운로드
    </a>
  </div>

  <img class="char-bg" src="/tteoni-travel.png" alt="">

  <script>
    function openApp() {
      window.location.href = 'tteona://course?id=${courseId}';
      setTimeout(function() {
        document.getElementById('storeBtn').click();
      }, 2500);
    }
  </script>
</body>
</html>`;
}

function courseNotFoundHtml() {
  return `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>떠나 — 코스를 찾을 수 없어요</title>
  <meta property="og:title" content="떠나 — 코스를 찾을 수 없어요">
  <meta property="og:image" content="https://tteona.kr/og-image.png">
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+KR:wght@400;700;900&display=swap');
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Noto Sans KR', -apple-system, sans-serif;
      min-height: 100vh;
      background: url('/tteona-character.png') center center / cover no-repeat fixed;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-end;
      padding-bottom: 60px;
    }
    .bottom {
      width: 100%; max-width: 400px;
      display: flex; flex-direction: column; align-items: center;
      padding: 0 28px; text-align: center; gap: 8px;
    }
    .app-title { font-size: 42px; font-weight: 900; color: #FF6B35; letter-spacing: -1px; }
    .msg { font-size: 16px; color: #555; margin-top: 4px; }
    .store-btn {
      display: flex; align-items: center; justify-content: center; gap: 10px;
      background: #1a1a1a; color: #fff; text-decoration: none;
      padding: 17px 32px; border-radius: 18px; font-size: 16px;
      font-weight: 700; width: 100%; margin-top: 20px;
    }
    .store-btn svg { width: 20px; height: 20px; fill: white; }
  </style>
</head>
<body>
  <div class="bottom">
    <div class="app-title">떠나</div>
    <div class="msg">코스를 찾을 수 없어요</div>
    <a class="store-btn" href="https://apps.apple.com/kr/app/%EB%96%A0%EB%82%98/id6767218543">
      <svg viewBox="0 0 814 1000" xmlns="http://www.w3.org/2000/svg">
        <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76 0-103.7 40.8-165.9 40.8s-105-37.5-155.5-127.4C46 790.7 0 663.5 0 541.8c0-207.8 134.9-317.9 267.9-317.9 75.3 0 137.9 49.2 184.2 49.2 44.4 0 114.5-52.1 201.5-52.1zM568.5 81.4C588.5 55.4 602.8 19.9 602.8 0c0-1.9-.1-3.8-.3-5.7-30.5 1.1-67.1 20.4-89.3 47.9-17.9 21.3-35.5 57.2-35.5 87.2 0 2 .3 4 .5 4.7 2 .3 4.1.5 6.1.5 28.3 0 63.2-18.8 84.2-53.2z"/>
      </svg>
      App Store에서 다운로드
    </a>
  </div>
</body>
</html>`;
}

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

app.listen(PORT, () => {
  console.log(`tteona API server running on port ${PORT}`);
  console.log('Firebase Admin SDK initialized ✅');
});
