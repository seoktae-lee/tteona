// .env 파일이 있으면 로드 (dotenv 미설치 시 무시 — pm2/systemd 환경변수로도 동작)
try { require('dotenv').config(); } catch {}

const http    = require('http');
const express = require('express');
const cors    = require('cors');
const helmet  = require('helmet');
const morgan  = require('morgan');
const { Pool } = require('pg');
const apn  = require('@parse/node-apn');
const cron = require('node-cron');
const WebSocket = require('ws');
const multer = require('multer');
const sharp  = require('sharp');
const path   = require('path');
const fs     = require('fs');
const { randomUUID } = require('crypto');
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getAuth } = require('firebase-admin/auth');

const serviceAccount = require('./firebase-service-account.json');
initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();

// ─── 필수 환경변수 (하드코딩 금지 — 미설정 시 기동 실패) ─────────────────────────
// .env.example 참고. 기존에 소스에 박혀 있던 값들은 git 이력에 남아 있으므로
// 반드시 새 값으로 로테이션한 뒤 환경변수로만 주입할 것.
function requiredEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`[Config] 필수 환경변수 ${name} 이(가) 설정되지 않았습니다. 서버를 시작할 수 없습니다.`);
    process.exit(1);
  }
  return v;
}

const PG_PASSWORD    = requiredEnv('PG_PASSWORD');
const ADMIN_PASSWORD = requiredEnv('ADMIN_PASSWORD');
const ADMIN_TOKEN    = requiredEnv('ADMIN_TOKEN');

// 인증 강제 여부 — 기본 true. 구버전 앱(토큰 미전송)이 남아 있는 전환 기간에만
// AUTH_ENFORCE=false로 완화 운영 (완화 모드에서도 토큰이 오면 검증·활용한다).
const AUTH_ENFORCE = process.env.AUTH_ENFORCE !== 'false';

const pgPool = new Pool({
  host: process.env.PG_HOST || '10.30.10.170',
  port: 5432,
  user: process.env.PG_USER || 'tteona',
  password: PG_PASSWORD,
  database: process.env.PG_DB || 'tteona_db',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});
pgPool.on('error', (err) => console.error('PostgreSQL pool error:', err));

// ─── Firebase ID 토큰 인증 미들웨어 ──────────────────────────────────────────
// 성공 시 req.uid에 검증된 Firebase uid가 들어간다. 클라이언트가 보내는
// body.userId는 신뢰하지 않고 req.uid를 우선 사용한다.

async function verifyBearer(req) {
  const header = req.headers['authorization'] || '';
  if (!header.startsWith('Bearer ')) return null;
  try {
    const decoded = await getAuth().verifyIdToken(header.slice(7));
    return decoded.uid;
  } catch {
    return undefined; // 토큰이 왔는데 무효 — 완화 모드에서도 거부
  }
}

async function requireAuth(req, res, next) {
  const uid = await verifyBearer(req);
  if (uid === undefined) return res.status(401).json({ error: 'invalid token' });
  if (uid === null && AUTH_ENFORCE) return res.status(401).json({ error: 'auth required' });
  req.uid = uid; // 완화 모드에서 토큰 미전송이면 null
  next();
}

// ─── APNs Provider ────────────────────────────────────────────────────────────

const apnProvider = new apn.Provider({
  token: {
    key:    process.env.APNS_KEY_PATH || '/home/ubuntu/tteona-api/keys/AuthKey_Z255DQRVA2.p8',
    keyId:  process.env.APNS_KEY_ID   || 'Z255DQRVA2',
    teamId: process.env.APNS_TEAM_ID  || 'M576JMA5A7',
  },
  production: true,
});

const BUNDLE_ID = 'com.seoktaedev.tteona';

async function sendPush({ userId, title, body, data = {} }) {
  try {
    const result = await pgPool.query(
      'SELECT token FROM device_tokens WHERE user_id = $1',
      [userId]
    );
    if (result.rows.length === 0) return { skipped: true, reason: 'no token' };

    const token = result.rows[0].token;
    const note = new apn.Notification();
    note.expiry = Math.floor(Date.now() / 1000) + 3600;
    note.badge  = 1;
    note.sound  = 'default';
    note.alert  = { title, body };
    note.payload = data;
    note.topic   = BUNDLE_ID;

    const res = await apnProvider.send(note, token);
    if (res.failed.length > 0) {
      console.error('[APNs] failed:', JSON.stringify(res.failed));
      return { ok: false, error: res.failed[0].response };
    }
    return { ok: true };
  } catch (err) {
    console.error('[APNs] sendPush error:', err.message);
    return { ok: false, error: err.message };
  }
}

const app = express();
const PORT = 3000;

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({ origin: ['https://tteona.kr', 'https://www.tteona.kr'] }));
app.use(morgan('combined'));
app.use(express.json());

// ─── 썸네일 업로드 설정 ────────────────────────────────────────────────────────

const THUMB_DIR = path.join(__dirname, 'uploads', 'thumbnails');
const AVATAR_DIR = path.join(__dirname, 'uploads', 'avatars');
fs.mkdirSync(THUMB_DIR, { recursive: true });
fs.mkdirSync(AVATAR_DIR, { recursive: true });

// Vlog 완성본은 본인만 다운로드 가능 — jobId가 순번이라 추측 가능하므로 소유자 검증
// (썸네일·아바타는 공개 프로필/공유 페이지에서 쓰이므로 그대로 공개)
app.use('/uploads/vlog', requireAuth, async (req, res, next) => {
  const m = req.path.match(/^\/(\d+)\//);
  if (!m) return res.status(404).json({ error: 'not found' });
  if (req.uid) {
    try {
      const r = await pgPool.query('SELECT user_id FROM vlog_jobs WHERE id = $1', [m[1]]);
      if (r.rows.length === 0 || r.rows[0].user_id !== req.uid) {
        return res.status(403).json({ error: 'forbidden' });
      }
    } catch (err) {
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
  next();
});

app.use('/uploads', express.static(path.join(__dirname, 'uploads'), {
  maxAge: '30d',
  immutable: false,
}));
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 }, // 10MB
  fileFilter: (req, file, cb) => {
    if (file.mimetype.startsWith('image/')) cb(null, true);
    else cb(new Error('이미지 파일만 업로드 가능합니다.'));
  },
});

// ─── Health / API root ───────────────────────────────────────────────────────

app.get('/health', (req, res) => {
  res.json({ status: 'ok', server: 'tteona-api', time: new Date().toISOString() });
});

app.get('/api', (req, res) => {
  res.json({ message: 'tteona API server v1.0' });
});

// ─── JSON API ────────────────────────────────────────────────────────────────

// GET /api/courses/recommend — 동적 라우트(:courseId)보다 먼저 등록해야 함
app.get('/api/courses/recommend', requireAuth, async (req, res) => {
  const { lat, lng, tag } = req.query;
  const userId = req.uid || req.query.userId; // 검증된 uid 우선
  const limit = Math.max(1, Math.min(50, parseInt(req.query.limit) || 20));
  const userLat = parseFloat(lat);
  const userLng = parseFloat(lng);

  const latR = isNaN(userLat) ? 'x' : (Math.round(userLat * 10) / 10).toFixed(1);
  const lngR = isNaN(userLng) ? 'x' : (Math.round(userLng * 10) / 10).toFixed(1);
  const cacheKey = `rec:${userId || 'anon'}:${latR}:${lngR}:${tag || 'any'}:${limit}`;

  try {
    const cached = await pgPool.query(
      'SELECT result FROM recommendation_cache WHERE cache_key = $1 AND expires_at > NOW()',
      [cacheKey]
    );
    if (cached.rows.length > 0) {
      return res.json(JSON.parse(cached.rows[0].result));
    }

    const coursesSnap = await db.collection('courses').limit(500).get();
    let courses = coursesSnap.docs.map(d => ({ courseId: d.id, ...d.data() }));

    if (userId) {
      courses = courses.filter(c => c.authorId !== userId);
    }

    const now = Date.now();
    const season = currentSeason();  // 서버 타임존(Asia/Seoul) 기준 현재 계절

    const scored = courses.map(c => {
      let score = 0;

      // 인기도 (0–40점)
      score += Math.min((c.likeCount || 0) * 4, 40);

      // 신선도 (0–25점): 50일 선형 감쇠
      const createdMs = c.createdAt?._seconds ? c.createdAt._seconds * 1000 : now;
      const ageDays = (now - createdMs) / 86400000;
      score += Math.max(0, 25 - ageDays * 0.5);

      // 지역 인접 (0–25점): 대표 장소 기준
      if (!isNaN(userLat) && !isNaN(userLng) && c.places?.length > 0) {
        const p = mainPlaceOf(c);
        if (p && p.latitude && p.longitude) {
          const dist = haversineKm(userLat, userLng, p.latitude, p.longitude);
          if (dist < 10)       score += 25;
          else if (dist < 50)  score += 15;
          else if (dist < 200) score += 5;
        }
      }

      // 태그 선호 (0–10점)
      if (tag && c.tag === tag) score += 10;

      // 시즌 매칭 (0–18점): 코스명·장소명에 현재 계절 키워드 포함 시
      const haystack = (c.courseName || '') + ' ' + (c.places || []).map(p => p.placeName || '').join(' ');
      if (season.words.some(w => haystack.includes(w))) score += 18;

      return { courseId: c.courseId, score };
    });

    scored.sort((a, b) => b.score - a.score);
    const result = {
      courseIds: scored.slice(0, limit).map(s => s.courseId),
      season: season.name,
    };

    await pgPool.query(
      `INSERT INTO recommendation_cache (cache_key, result, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '5 minutes')
       ON CONFLICT (cache_key) DO UPDATE SET result = $2, expires_at = NOW() + INTERVAL '5 minutes'`,
      [cacheKey, JSON.stringify(result)]
    );

    res.json(result);
  } catch (err) {
    console.error('[Recommend] error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 코스 썸네일 (WAS 로컬 저장 + PostgreSQL) ─────────────────────────────────

// 전체 썸네일 맵 조회 — 탐색 그리드가 코스 목록에 병합해서 사용
// (동적 :courseId 라우트보다 먼저 등록)
app.get('/api/courses/thumbnails', requireAuth, async (req, res) => {
  try {
    const result = await pgPool.query('SELECT course_id, url FROM course_thumbnails');
    const map = {};
    result.rows.forEach(r => { map[r.course_id] = r.url; });
    res.json(map);
  } catch (err) {
    console.error('[Thumbnails] fetch error:', err);
    res.status(500).json({ error: err.message });
  }
});

// 단일 코스 썸네일 조회
app.get('/api/courses/:courseId/thumbnail', requireAuth, async (req, res) => {
  try {
    const result = await pgPool.query(
      'SELECT url FROM course_thumbnails WHERE course_id = $1',
      [req.params.courseId]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'no thumbnail' });
    res.json({ url: result.rows[0].url });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 썸네일 업로드 — multipart/form-data, 필드명 "image" (코스 작성자만 가능)
app.post('/api/courses/:courseId/thumbnail', requireAuth, upload.single('image'), async (req, res) => {
  const { courseId } = req.params;
  if (!req.file) return res.status(400).json({ error: 'image file required' });

  try {
    if (req.uid) {
      const courseDoc = await db.collection('courses').doc(courseId).get();
      if (!courseDoc.exists || courseDoc.data().authorId !== req.uid) {
        return res.status(403).json({ error: 'not course author' });
      }
    }
    const filename = `${courseId}.jpg`;
    const filepath = path.join(THUMB_DIR, filename);

    // 정사각형 크롭 + 최대 1080px, JPEG 품질 82
    await sharp(req.file.buffer)
      .rotate()
      .resize(1080, 1080, { fit: 'cover', position: 'centre' })
      .jpeg({ quality: 82 })
      .toFile(filepath);

    const url = `https://tteona.kr/uploads/thumbnails/${filename}`;
    await pgPool.query(
      `INSERT INTO course_thumbnails (course_id, url, uploaded_at)
       VALUES ($1, $2, NOW())
       ON CONFLICT (course_id) DO UPDATE SET url = EXCLUDED.url, uploaded_at = NOW()`,
      [courseId, url]
    );

    res.json({ ok: true, url });
  } catch (err) {
    console.error('[Thumbnails] upload error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 프로필 이미지 (WAS 로컬 저장 + PostgreSQL) ───────────────────────────────

// 프로필 이미지 업로드 — multipart/form-data, 필드명 "image" (본인만 가능)
app.post('/api/users/:uid/avatar', requireAuth, upload.single('image'), async (req, res) => {
  const { uid } = req.params;
  if (!req.file) return res.status(400).json({ error: 'image file required' });
  if (req.uid && req.uid !== uid) return res.status(403).json({ error: 'not your account' });

  try {
    const filename = `${uid}.jpg`;
    const filepath = path.join(AVATAR_DIR, filename);

    // 정사각형 크롭 + 최대 512px, JPEG 품질 82
    await sharp(req.file.buffer)
      .rotate()
      .resize(512, 512, { fit: 'cover', position: 'centre' })
      .jpeg({ quality: 82 })
      .toFile(filepath);

    // 파일명이 고정이라 캐시 무효화용 버전 쿼리 추가
    const url = `https://tteona.kr/uploads/avatars/${filename}?v=${Date.now()}`;
    await pgPool.query(
      `INSERT INTO user_avatars (user_id, url, uploaded_at)
       VALUES ($1, $2, NOW())
       ON CONFLICT (user_id) DO UPDATE SET url = EXCLUDED.url, uploaded_at = NOW()`,
      [uid, url]
    );
    await db.collection('users').doc(uid).set({ profileImageUrl: url }, { merge: true });

    res.json({ ok: true, url });
  } catch (err) {
    console.error('[Avatar] upload error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 대중교통 경로 (ODsay) ─────────────────────────────────────────────────────

// 외부 API 키 — env 미설정 시 해당 기능만 폴백(추정치)으로 동작
const ODSAY_KEY = process.env.ODSAY_KEY || '';
const KAKAO_REST_KEY = process.env.KAKAO_REST_KEY || '';

// 두 지점 간 대중교통 소요시간/거리 (실패 시 도보 추정 폴백)
async function odsayLeg(sLat, sLng, eLat, eLng) {
  const url = `https://api.odsay.com/v1/api/searchPubTransPathT`
    + `?SX=${sLng}&SY=${sLat}&EX=${eLng}&EY=${eLat}`
    + `&apiKey=${encodeURIComponent(ODSAY_KEY)}&output=json`;
  try {
    if (!ODSAY_KEY) throw new Error('ODSAY_KEY not set');
    const r = await fetch(url);
    const j = await r.json();
    const info = j?.result?.path?.[0]?.info;
    if (info) {
      return { distanceMeters: (info.totalDistance || 0), travelTimeSec: (info.totalTime || 0) * 60 };
    }
  } catch (e) {
    console.error('[ODsay] leg error:', e.message);
  }
  // 폴백: 직선거리 + 도보 4.5km/h
  const d = haversineKm(sLat, sLng, eLat, eLng) * 1000;
  return { distanceMeters: d, travelTimeSec: d / (4500 / 3600) };
}

// POST /api/courses/transit-route  body: { places: [{lat,lng}, ...] }
app.post('/api/courses/transit-route', requireAuth, async (req, res) => {
  const places = Array.isArray(req.body?.places) ? req.body.places : [];
  if (places.length < 2) return res.status(400).json({ error: 'need >= 2 places' });

  const cacheKey = 'transit:' + places
    .map(p => `${(+p.lat).toFixed(3)},${(+p.lng).toFixed(3)}`).join('|');

  try {
    const cached = await pgPool.query(
      'SELECT result FROM recommendation_cache WHERE cache_key = $1 AND expires_at > NOW()',
      [cacheKey]
    );
    if (cached.rows.length > 0) return res.json(JSON.parse(cached.rows[0].result));

    let totalDistance = 0, totalTime = 0;
    for (let i = 0; i < places.length - 1; i++) {
      const a = places[i], b = places[i + 1];
      const leg = await odsayLeg(+a.lat, +a.lng, +b.lat, +b.lng);
      totalDistance += leg.distanceMeters;
      totalTime += leg.travelTimeSec;
    }

    const result = { distanceMeters: totalDistance, travelTimeSec: totalTime };
    await pgPool.query(
      `INSERT INTO recommendation_cache (cache_key, result, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '1 day')
       ON CONFLICT (cache_key) DO UPDATE SET result = $2, expires_at = NOW() + INTERVAL '1 day'`,
      [cacheKey, JSON.stringify(result)]
    );
    res.json(result);
  } catch (err) {
    console.error('[Transit] error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/courses/:courseId', requireAuth, async (req, res) => {
  try {
    const doc = await db.collection('courses').doc(req.params.courseId).get();
    if (!doc.exists) return res.status(404).json({ error: 'Course not found' });
    res.json({ id: doc.id, ...doc.data() });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── 사용자 통계 ──────────────────────────────────────────────────────────────

// 이벤트 적재 — iOS가 코스 생성/장소 방문/좋아요/공유 시 호출 (user_stats·daily_stats 축적)
app.post('/api/stats/event', requireAuth, async (req, res) => {
  const { type } = req.body;
  const userId = req.uid || req.body.userId; // 검증된 uid 우선 — 타인 통계 조작 방지
  const COLS = {
    course_created: 'courses_created',
    place_visited:  'places_visited',
    course_liked:   'courses_liked',
    course_shared:  'courses_shared',
  };
  const col = COLS[type];
  if (!userId || !col) return res.status(400).json({ error: 'userId and valid type required' });

  try {
    await pgPool.query(`
      INSERT INTO user_stats (user_id, stat_date, ${col}, last_active)
      VALUES ($1, CURRENT_DATE, 1, NOW())
      ON CONFLICT (user_id, stat_date)
      DO UPDATE SET ${col} = user_stats.${col} + 1, last_active = NOW()
    `, [userId]);

    if (type === 'course_created') {
      await pgPool.query(`
        INSERT INTO daily_stats (stat_date, courses_created)
        VALUES (CURRENT_DATE, 1)
        ON CONFLICT (stat_date)
        DO UPDATE SET courses_created = daily_stats.courses_created + 1, updated_at = NOW()
      `);
    }
    res.json({ ok: true });
  } catch (err) {
    console.error('[Stats] event error:', err);
    res.status(500).json({ error: err.message });
  }
});

// 개인 누적 여행 통계 (본인 것만 조회 가능)
app.get('/api/users/:uid/stats', requireAuth, async (req, res) => {
  const uid = req.params.uid;
  if (req.uid && req.uid !== uid) return res.status(403).json({ error: 'not your account' });
  try {
    const [coursesSnap, roomsCount, pg] = await Promise.all([
      db.collection('courses').where('authorId', '==', uid).get(),
      db.collection('rooms').where('memberIds', 'array-contains', uid).count().get(),
      pgPool.query(
        `SELECT COALESCE(SUM(places_visited),0) AS visited,
                COUNT(DISTINCT stat_date)        AS active_days
         FROM user_stats WHERE user_id = $1`, [uid]),
    ]);

    let likesReceived = 0, placesInCourses = 0;
    coursesSnap.docs.forEach(d => {
      const c = d.data();
      likesReceived   += c.likeCount || 0;
      placesInCourses += (c.places || []).length;
    });

    res.json({
      coursesCreated:  coursesSnap.size,
      placesInCourses,
      likesReceived,
      groups:          roomsCount.data().count,
      placesVisited:   Number(pg.rows[0].visited),
      activeDays:      Number(pg.rows[0].active_days),
    });
  } catch (err) {
    console.error('[Stats] user stats error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 크리에이터 랭킹 ──────────────────────────────────────────────────────────

// 이번 주 인기 크리에이터 TOP 10 (좋아요 합계 → 코스 수 순, 10분 캐시)
app.get('/api/creators/ranking', requireAuth, async (req, res) => {
  const cacheKey = 'creators:weekly';
  try {
    const cached = await pgPool.query(
      'SELECT result FROM recommendation_cache WHERE cache_key = $1 AND expires_at > NOW()',
      [cacheKey]
    );
    if (cached.rows.length > 0) return res.json(JSON.parse(cached.rows[0].result));

    const coursesSnap = await db.collection('courses').limit(500).get();
    const byAuthor = new Map();
    coursesSnap.docs.forEach(d => {
      const c = d.data();
      if (!c.authorId) return;
      const cur = byAuthor.get(c.authorId) || { likes: 0, courses: 0 };
      cur.likes   += c.likeCount || 0;
      cur.courses += 1;
      byAuthor.set(c.authorId, cur);
    });

    const top = [...byAuthor.entries()]
      .sort((a, b) => (b[1].likes - a[1].likes) || (b[1].courses - a[1].courses))
      .slice(0, 10);

    const ranking = await Promise.all(top.map(async ([uid, s], i) => {
      const u = await db.collection('users').doc(uid).get();
      const ud = u.exists ? u.data() : {};
      return {
        rank: i + 1,
        userId: uid,
        nickname: ud.nickname || '여행자',
        isVerified: ud.isVerified === true,
        profileImageUrl: ud.profileImageUrl || null,
        likes: s.likes,
        courses: s.courses,
      };
    }));

    const result = { ranking };
    await pgPool.query(
      `INSERT INTO recommendation_cache (cache_key, result, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '10 minutes')
       ON CONFLICT (cache_key) DO UPDATE SET result = $2, expires_at = NOW() + INTERVAL '10 minutes'`,
      [cacheKey, JSON.stringify(result)]
    );
    res.json(result);
  } catch (err) {
    console.error('[Creators] ranking error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 콘텐츠 자동 모더레이션 ───────────────────────────────────────────────────

const BANNED_WORDS = [
  '시발', '씨발', 'ㅅㅂ', 'ㅆㅂ', '병신', 'ㅂㅅ', '지랄', 'ㅈㄹ', '개새끼', '새끼',
  '좆', '존나', 'ㅈㄴ', '니미', '엠창', '느금', '꺼져', '닥쳐',
  '섹스', '야동', '포르노', '자위', '보지', '자지', '딸딸이',
  '도박', '토토', '카지노', '바카라', '섹파', '조건만남', '출장샵', '오피',
  'fuck', 'shit', 'bitch', 'porn', 'sex',
];

function normalizeForModeration(text) {
  return String(text).toLowerCase().replace(/[\s\.\,\-\_\!\?\*\@\#\$\%\^\&\(\)\[\]0-9]/g, '');
}

// 금칙어 포함 여부 (WS 채팅·닉네임 검사에서 재사용)
function findBannedWord(text) {
  const normalized = normalizeForModeration(text);
  return BANNED_WORDS.find(w => normalized.includes(normalizeForModeration(w))) || null;
}

// POST /api/moderate  body: { text }  →  { ok, blocked, matched? }
app.post('/api/moderate', requireAuth, (req, res) => {
  const text = req.body?.text;
  if (typeof text !== 'string') return res.status(400).json({ error: 'text required' });

  const normalized = normalizeForModeration(text);
  const matched = BANNED_WORDS.find(w => normalized.includes(normalizeForModeration(w)));

  res.json({ ok: true, blocked: !!matched, ...(matched ? { matched } : {}) });
});

// ─── Push 알림 API ───────────────────────────────────────────────────────────

// iOS 앱이 로그인 시 APNs device token 등록 — 본인 토큰만 등록 가능
app.post('/api/push/register', requireAuth, async (req, res) => {
  const { token } = req.body;
  const userId = req.uid || req.body.userId; // 검증된 uid 우선 — 타인 토큰 탈취 방지
  if (!userId || !token) return res.status(400).json({ error: 'userId and token required' });

  try {
    await pgPool.query(`
      INSERT INTO device_tokens (user_id, token, updated_at)
      VALUES ($1, $2, NOW())
      ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token, updated_at = NOW()
    `, [userId, token]);
    res.json({ ok: true });
  } catch (err) {
    console.error('push register error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// 발신자 닉네임 — 사칭 방지를 위해 body 값 대신 Firestore users 문서에서 조회
async function nicknameOf(uid, fallback) {
  if (!uid) return fallback || '여행자';
  try {
    const doc = await db.collection('users').doc(uid).get();
    return (doc.exists && doc.data().nickname) || fallback || '여행자';
  } catch {
    return fallback || '여행자';
  }
}

// 코스 좋아요 알림 — 코스 작성자에게 발송
app.post('/api/push/course-liked', requireAuth, async (req, res) => {
  const { courseOwnerId, likerNickname, courseName } = req.body;
  if (!courseOwnerId || !likerNickname) return res.status(400).json({ error: 'missing fields' });
  if (req.uid === courseOwnerId) return res.json({ skipped: true, reason: 'self' });

  const nickname = await nicknameOf(req.uid, likerNickname);
  const result = await sendPush({
    userId: courseOwnerId,
    title:  '코스에 좋아요가 달렸어요 ❤️',
    body:   `${nickname}님이 "${courseName}" 코스를 좋아합니다`,
    data:   { type: 'course_liked', courseName },
  });
  res.json(result);
});

// 코스 따라가기 알림 — 코스 작성자에게 발송
app.post('/api/push/course-followed', requireAuth, async (req, res) => {
  const { courseOwnerId, followerNickname, courseName } = req.body;
  if (!courseOwnerId || !followerNickname) return res.status(400).json({ error: 'missing fields' });
  if (req.uid === courseOwnerId) return res.json({ skipped: true, reason: 'self' });

  const nickname = await nicknameOf(req.uid, followerNickname);
  const result = await sendPush({
    userId: courseOwnerId,
    title:  '누군가 내 코스를 따라가고 있어요 🗺️',
    body:   `${nickname}님이 "${courseName}" 코스 여행을 시작했어요`,
    data:   { type: 'course_followed', courseName },
  });
  res.json(result);
});

// ─── 주간 활동 리포트 Cron (매주 월요일 오전 9시) ──────────────────────────

cron.schedule('0 9 * * 1', async () => {
  console.log('[Cron] 주간 활동 리포트 발송 시작');
  try {
    const lastMonday = new Date();
    lastMonday.setDate(lastMonday.getDate() - 7);
    const dateStr = lastMonday.toISOString().split('T')[0];

    const users = await pgPool.query(`
      SELECT user_id,
             SUM(courses_created) AS courses,
             SUM(places_visited)  AS places
      FROM user_stats
      WHERE stat_date >= $1
      GROUP BY user_id
      HAVING SUM(courses_created) > 0 OR SUM(places_visited) > 0
    `, [dateStr]);

    let sent = 0;
    for (const row of users.rows) {
      const body = [
        row.courses > 0 ? `코스 ${row.courses}개 만들었고` : null,
        row.places  > 0 ? `장소 ${row.places}곳 방문했어요` : null,
      ].filter(Boolean).join(', ');

      await sendPush({
        userId: row.user_id,
        title:  '이번 주 여행 리포트 📊',
        body:   `지난 7일간 ${body}!`,
        data:   { type: 'weekly_report' },
      });
      sent++;
    }
    console.log(`[Cron] 주간 리포트 완료 — ${sent}명 발송`);
  } catch (err) {
    console.error('[Cron] 주간 리포트 오류:', err.message);
  }
}, { timezone: 'Asia/Seoul' });

// ─── Places 캐시 API ─────────────────────────────────────────────────────────
// iOS가 Google Places API 결과를 PostgreSQL에 저장/조회
// 장소 이름 기반 캐시 키 (PlaceDetailService.cacheKey 로직과 동일)

app.get('/api/places/cache', requireAuth, async (req, res) => {
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

app.post('/api/places/cache', requireAuth, async (req, res) => {
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

// ─── 장소 대표 사진 (한국관광공사 TourAPI, PostgreSQL 캐싱) ────────────────────
// iOS가 좌표와 함께 장소명을 넘기면 좌표가 가장 가까운 관광공사 콘텐츠의
// 큐레이션 대표 이미지를 반환. 사진 없으면 404 → iOS가 Google Places로 폴백.

const TOUR_API_KEY = process.env.TOUR_API_KEY || '';

// contenttypeid → 사람이 읽는 카테고리
const TOUR_CONTENT_TYPE = {
  '12': '관광지', '14': '문화시설', '15': '축제·공연',
  '25': '여행코스', '28': '레포츠', '32': '숙박', '38': '쇼핑', '39': '음식점',
};

// 장소명 + 좌표(약 1km 버킷)로 캐시 키 생성 — 동명이소 구분
function tourPlaceKey(name, lat, lng) {
  const n = (name || '').trim();
  const latR = isNaN(lat) ? 'x' : lat.toFixed(2);
  const lngR = isNaN(lng) ? 'x' : lng.toFixed(2);
  return `${n}|${latR}|${lngR}`;
}

app.get('/api/places/tour-photo', requireAuth, async (req, res) => {
  const name = (req.query.name || '').trim();
  if (!name) return res.status(400).json({ error: 'name required' });
  const lat = parseFloat(req.query.lat);
  const lng = parseFloat(req.query.lng);
  const key = tourPlaceKey(name, lat, lng);

  try {
    // 1) 캐시 조회 (음성 캐시 포함 — url null이어도 유효기간 내면 404 즉답)
    const cached = await pgPool.query(
      'SELECT url, category FROM place_photos WHERE place_key = $1 AND expires_at > NOW()',
      [key]
    );
    if (cached.rows.length > 0) {
      const row = cached.rows[0];
      if (!row.url) return res.status(404).json({ error: 'no photo (cached)' });
      return res.json({ url: row.url, category: row.category, source: 'tour', cached: true });
    }

    // 2) TourAPI 키워드 검색
    const url = 'https://apis.data.go.kr/B551011/KorService2/searchKeyword2'
      + `?serviceKey=${encodeURIComponent(TOUR_API_KEY)}`
      + '&numOfRows=20&pageNo=1&MobileOS=IOS&MobileApp=tteona&_type=json'
      + `&keyword=${encodeURIComponent(name)}`;

    let items = [];
    try {
      if (!TOUR_API_KEY) throw new Error('TOUR_API_KEY not set');
      const r = await fetch(url);
      const j = await r.json();
      const raw = j?.response?.body?.items?.item;
      items = Array.isArray(raw) ? raw : (raw ? [raw] : []);
    } catch (e) {
      console.error('[TourPhoto] fetch error:', e.message);
    }

    // 사진 있는 항목만
    const withImage = items.filter(it => it.firstimage && it.firstimage.trim());

    // 대표 이미지로 적합한 콘텐츠 타입 우선순위 (낮을수록 우선)
    // 관광지·문화시설·숙박·음식점(실제 장소) > 축제·여행코스(행사/묶음)
    const typeRank = { '12': 0, '14': 1, '32': 2, '39': 2, '38': 3, '28': 3, '25': 8, '15': 9 };
    const norm = s => (s || '').replace(/\s+/g, '').toLowerCase();
    const target = norm(name);

    let picked = null;
    if (withImage.length > 0) {
      // 1) 이름 정확 일치 항목이 있으면 그 안에서만 선택 (별빛야행 같은 파생 콘텐츠 배제)
      const exact = withImage.filter(it => norm(it.title) === target);
      const pool = exact.length > 0 ? exact : withImage;

      picked = pool
        .map(it => ({
          it,
          // 좌표 없으면 거리 0, 있으면 0.5km 단위로 버킷화해 근접 동률은 타입으로 판정
          distBucket: (!isNaN(lat) && !isNaN(lng))
            ? Math.round(haversineKm(lat, lng, parseFloat(it.mapy), parseFloat(it.mapx)) * 2)
            : 0,
          typeRank: typeRank[it.contenttypeid] ?? 5,
        }))
        .sort((a, b) => (a.distBucket - b.distBucket) || (a.typeRank - b.typeRank))[0].it;
    }

    // 3) 결과 캐싱 (양성 30일 / 음성 7일)
    if (picked) {
      const category = TOUR_CONTENT_TYPE[picked.contenttypeid] || null;
      await pgPool.query(
        `INSERT INTO place_photos (place_key, url, category, source, expires_at)
         VALUES ($1, $2, $3, 'tour', NOW() + INTERVAL '30 days')
         ON CONFLICT (place_key) DO UPDATE SET
           url = EXCLUDED.url, category = EXCLUDED.category,
           fetched_at = NOW(), expires_at = EXCLUDED.expires_at`,
        [key, picked.firstimage.trim(), category]
      );
      return res.json({ url: picked.firstimage.trim(), category, source: 'tour', cached: false });
    } else {
      await pgPool.query(
        `INSERT INTO place_photos (place_key, url, category, source, expires_at)
         VALUES ($1, NULL, NULL, 'tour', NOW() + INTERVAL '7 days')
         ON CONFLICT (place_key) DO UPDATE SET
           url = NULL, category = NULL, fetched_at = NOW(), expires_at = EXCLUDED.expires_at`,
        [key]
      );
      return res.status(404).json({ error: 'no photo' });
    }
  } catch (err) {
    console.error('[TourPhoto] error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 통합 경로 (지역 분기: 한국 자동차=카카오모빌리티, 그 외=추정) ───────────────

function isKorea(lat, lng) {
  return lat >= 33 && lat <= 39.5 && lng >= 124 && lng <= 132;
}

// 카카오모빌리티 자동차 한 구간 (실패 시 null)
async function kakaoCarLeg(sLat, sLng, eLat, eLng) {
  const url = `https://apis-navi.kakaomobility.com/v1/directions`
    + `?origin=${sLng},${sLat}&destination=${eLng},${eLat}`;
  try {
    if (!KAKAO_REST_KEY) return null;
    const r = await fetch(url, { headers: { Authorization: `KakaoAK ${KAKAO_REST_KEY}` } });
    const j = await r.json();
    const route = j?.routes?.[0];
    if (route && route.result_code === 0 && route.summary) {
      return { distanceMeters: route.summary.distance, travelTimeSec: route.summary.duration };
    }
  } catch (e) {
    console.error('[Route] kakao leg error:', e.message);
  }
  return null;
}

// POST /api/route  body: { places: [{lat,lng}, ...], mode: 'car'|'walk' }
app.post('/api/route', requireAuth, async (req, res) => {
  const places = Array.isArray(req.body?.places) ? req.body.places : [];
  const mode = req.body?.mode === 'walk' ? 'walk' : 'car';
  if (places.length < 2) return res.json({ distanceMeters: 0, travelTimeSec: 0, source: 'none' });

  const cacheKey = `route:${mode}:` + places
    .map(p => `${Number(p.lat).toFixed(4)},${Number(p.lng).toFixed(4)}`).join(';');

  try {
    const cached = await pgPool.query(
      'SELECT result FROM recommendation_cache WHERE cache_key = $1 AND expires_at > NOW()',
      [cacheKey]
    );
    if (cached.rows.length > 0) return res.json(JSON.parse(cached.rows[0].result));

    const first = places[0];
    const useKakao = mode === 'car' && isKorea(Number(first.lat), Number(first.lng));
    const walkSpeed = 4500 / 3600;   // 4.5km/h
    const carSpeed  = 40000 / 3600;  // 40km/h(도심 평균)

    let totalDist = 0, totalTime = 0;
    let source = useKakao ? 'kakao' : 'estimate';

    for (let i = 0; i < places.length - 1; i++) {
      const a = places[i], b = places[i + 1];
      let leg = null;
      if (useKakao) leg = await kakaoCarLeg(Number(a.lat), Number(a.lng), Number(b.lat), Number(b.lng));
      if (leg) {
        totalDist += leg.distanceMeters;
        totalTime += leg.travelTimeSec;
      } else {
        // 폴백: 직선거리 × 평균속도
        const d = haversineKm(Number(a.lat), Number(a.lng), Number(b.lat), Number(b.lng)) * 1000;
        totalDist += d;
        totalTime += d / (mode === 'walk' ? walkSpeed : carSpeed);
        source = 'estimate';
      }
    }

    const result = {
      distanceMeters: Math.round(totalDist),
      travelTimeSec:  Math.round(totalTime),
      source,
    };
    await pgPool.query(
      `INSERT INTO recommendation_cache (cache_key, result, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '1 day')
       ON CONFLICT (cache_key) DO UPDATE SET result = $2, expires_at = NOW() + INTERVAL '1 day'`,
      [cacheKey, JSON.stringify(result)]
    );
    res.json(result);
  } catch (err) {
    console.error('[Route] error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 서버 사이드 Vlog 생성 (FFmpeg) ───────────────────────────────────────────
// 흐름: 잡 생성(uploading) → 클립 업로드 → start(pending) → 워커가 합성(processing)
//       → 완성(completed, output_url) → APNs 푸시. 실패 시 failed + error_msg.

const { spawn } = require('child_process');

const VLOG_DIR = path.join(__dirname, 'uploads', 'vlog');
fs.mkdirSync(VLOG_DIR, { recursive: true });
const VLOG_FONT = path.join(__dirname, 'assets', 'fonts', 'GowunBatang-Regular.ttf');

// 클립 업로드용 multer — 영상은 크므로 디스크에 바로 저장 (개당 최대 300MB)
const vlogUpload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => {
      const jobId = parseInt(req.params.jobId);
      if (isNaN(jobId)) return cb(new Error('invalid jobId'));
      const dir = path.join(VLOG_DIR, String(jobId), 'clips');
      fs.mkdirSync(dir, { recursive: true });
      cb(null, dir);
    },
    filename: (req, file, cb) => {
      const order = parseInt(req.query.order);
      cb(null, `${isNaN(order) ? Date.now() : order}.mp4`);
    },
  }),
  limits: { fileSize: 300 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    if (file.mimetype.startsWith('video/') || file.mimetype === 'application/octet-stream') cb(null, true);
    else cb(new Error('영상 파일만 업로드 가능합니다.'));
  },
});

// 잡 생성 — body: { userId, courseId?, courseName?, tag?, formats?: ['reels'|'youtube'|'insta'],
//                   bgm?: 'auto'|'none'|'mood/파일명',
//                   places: [{order, placeName, shotAt?}] }  (shotAt: 클립 촬영시각 표시 문자열)
app.post('/api/vlog/jobs', requireAuth, async (req, res) => {
  const { courseId, courseName, tag, formats, bgm, places, watermark, priority } = req.body || {};
  const userId = req.uid || req.body?.userId; // 검증된 uid 우선
  if (!userId || !Array.isArray(places) || places.length === 0) {
    return res.status(400).json({ error: 'userId and places required' });
  }
  try {
    const wanted = Array.isArray(formats)
      ? formats.filter(f => ['reels', 'youtube', 'insta'].includes(f)) : [];
    const r = await pgPool.query(
      `INSERT INTO vlog_jobs (user_id, course_id, course_name, status, clips, options)
       VALUES ($1, $2, $3, 'uploading', $4, $5) RETURNING id`,
      [userId, courseId || 'free', courseName || '나의 오늘',
       JSON.stringify(places),
       JSON.stringify({ tag: tag || null, formats: wanted,
                        bgm: typeof bgm === 'string' ? bgm.slice(0, 200) : null,
                        watermark: watermark !== false,
                        priority: priority === true })]
    );
    res.json({ jobId: r.rows[0].id });
  } catch (err) {
    console.error('[Vlog] create error:', err);
    res.status(500).json({ error: err.message });
  }
});

// 잡 소유자 검증 미들웨어 — 다른 유저의 잡에 클립 주입/조회 방지
async function requireJobOwner(req, res, next) {
  const id = parseInt(req.params.jobId);
  if (isNaN(id)) return res.status(400).json({ error: 'invalid jobId' });
  if (!req.uid) return next(); // 완화 모드(구버전 앱) 통과
  try {
    const r = await pgPool.query('SELECT user_id FROM vlog_jobs WHERE id = $1', [id]);
    if (r.rows.length === 0) return res.status(404).json({ error: 'job not found' });
    if (r.rows[0].user_id !== req.uid) return res.status(403).json({ error: 'not your job' });
    next();
  } catch (err) {
    res.status(500).json({ error: 'Internal server error' });
  }
}

// 클립 업로드 — multipart 필드 "clip", 쿼리 ?order=N (장소 순번)
app.post('/api/vlog/jobs/:jobId/clips', requireAuth, requireJobOwner, vlogUpload.single('clip'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'clip file required' });
  res.json({ ok: true, size: req.file.size });
});

// 업로드 완료 → 처리 큐 투입
app.post('/api/vlog/jobs/:jobId/start', requireAuth, requireJobOwner, async (req, res) => {
  const id = parseInt(req.params.jobId);
  try {
    const r = await pgPool.query(
      `UPDATE vlog_jobs SET status = 'pending' WHERE id = $1 AND status = 'uploading' RETURNING id`,
      [id]
    );
    if (r.rowCount === 0) return res.status(404).json({ error: 'job not found or not uploading' });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 상태 조회 — iOS 진행률 폴링용 (altUrl = 반대 방향 멀티포맷 버전)
app.get('/api/vlog/jobs/:jobId', requireAuth, requireJobOwner, async (req, res) => {
  try {
    const r = await pgPool.query(
      'SELECT status, progress, output_url, error_msg, options FROM vlog_jobs WHERE id = $1',
      [parseInt(req.params.jobId)]
    );
    if (r.rows.length === 0) return res.status(404).json({ error: 'job not found' });
    const j = r.rows[0];
    const opts = typeof j.options === 'object' && j.options !== null ? j.options : {};
    res.json({
      status: j.status, progress: j.progress,
      outputUrl: j.output_url,
      outputs: opts.outputs || [],   // [{format:'reels'|'youtube'|'insta', url}]
      errorMsg: j.error_msg,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── FFmpeg 실행 헬퍼 ──

function runFF(args, timeoutMs = 10 * 60 * 1000) {
  return new Promise((resolve, reject) => {
    const p = spawn('ffmpeg', ['-hide_banner', '-y', ...args]);
    let err = '';
    p.stderr.on('data', d => { err += d; if (err.length > 20000) err = err.slice(-10000); });
    const to = setTimeout(() => { p.kill('SIGKILL'); reject(new Error('ffmpeg timeout')); }, timeoutMs);
    p.on('close', code => {
      clearTimeout(to);
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg exit ${code}: ${err.slice(-800)}`));
    });
  });
}

function probeVideo(file) {
  return new Promise((resolve, reject) => {
    const p = spawn('ffprobe', ['-v', 'error', '-print_format', 'json', '-show_streams', '-show_format', file]);
    let out = '';
    p.stdout.on('data', d => out += d);
    p.on('close', code => {
      if (code !== 0) return reject(new Error('ffprobe failed'));
      try {
        const j = JSON.parse(out);
        const v = (j.streams || []).find(s => s.codec_type === 'video');
        const a = (j.streams || []).find(s => s.codec_type === 'audio');
        if (!v) return reject(new Error('no video stream'));
        // 아이폰 회전 메타데이터를 반영한 "표시" 크기 계산
        let rot = 0;
        const sd = (v.side_data_list || []).find(s => s.rotation != null);
        if (sd) rot = Math.abs(sd.rotation);
        else if (v.tags && v.tags.rotate) rot = Math.abs(parseInt(v.tags.rotate) || 0);
        const swap = rot === 90 || rot === 270;
        resolve({
          width: swap ? v.height : v.width,
          height: swap ? v.width : v.height,
          duration: parseFloat(j.format?.duration || v.duration || 0),
          hasAudio: !!a,
        });
      } catch (e) { reject(e); }
    });
  });
}

// drawtext 이스케이프 지옥을 피하기 위해 텍스트는 파일로 전달
function writeTextFile(dir, name, text) {
  const f = path.join(dir, name);
  fs.writeFileSync(f, text, 'utf8');
  return f;
}

// ── 합성 파이프라인: 선택한 포맷별로 원본 클립에서 독립 합성 ──
// 각 포맷(릴스 9:16 / 유튜브 16:9 / 인스타 1:1)마다:
//   타이틀 카드 2초(파스텔 주황 #FFB587 + tteona 로고 + 날짜 — 첫 프레임이 곧 썸네일)
//   → 클립 정규화(같은 방향·1:1은 꽉 차게 크롭, 반대 방향만 블러 패딩) + 자막·페이드
//   → concat → BGM 믹스.
// 완성본을 다시 늘리고 줄이는 2차 변환이 없어 원본 화질이 유지된다.
const VLOG_LOGO = path.join(__dirname, 'assets', 'tteona-logo.png');
const FORMAT_SPECS = { reels: [1080, 1920], youtube: [1920, 1080], insta: [1080, 1080] };

async function composeVlog(job) {
  const jobDir = path.join(VLOG_DIR, String(job.id));
  const clipsDir = path.join(jobDir, 'clips');
  const workDir = path.join(jobDir, 'work');
  fs.mkdirSync(workDir, { recursive: true });

  const places = (Array.isArray(job.clips) ? job.clips : JSON.parse(job.clips || '[]'))
    .slice().sort((a, b) => (a.order || 0) - (b.order || 0));
  const clips = places
    .map(p => ({ ...p, file: path.join(clipsDir, `${p.order}.mp4`) }))
    .filter(c => fs.existsSync(c.file));
  if (clips.length === 0) throw new Error('업로드된 클립이 없습니다');

  const setProgress = n =>
    pgPool.query('UPDATE vlog_jobs SET progress = $2 WHERE id = $1', [job.id, n]).catch(() => {});

  // 전체 클립을 프로브해 다수 방향으로 기본 포맷 결정 (회전 메타 반영된 표시 크기 기준)
  for (const c of clips) c.info = await probeVideo(c.file);
  const portraitCount = clips.filter(c => c.info.height >= c.info.width).length;
  const portrait = portraitCount * 2 >= clips.length;
  const mainFormat = portrait ? 'reels' : 'youtube';

  const opts = typeof job.options === 'object' && job.options !== null
    ? job.options : JSON.parse(job.options || '{}');
  const formats = [mainFormat,
    ...(opts.formats || []).filter(f => f !== mainFormat && FORMAT_SPECS[f])];
  // 워터마크: 기본 적용, plus 유저만 opts.watermark === false로 제거
  const watermark = opts.watermark !== false && fs.existsSync(VLOG_LOGO);
  await setProgress(4);

  const enc = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '21', '-pix_fmt', 'yuv420p',
               '-r', '30', '-c:a', 'aac', '-ar', '44100', '-ac', '2'];
  const bgm = pickBgm(job);

  // 진행률 4→92를 포맷×(타이틀+클립+믹스) 단계로 배분
  const totalSteps = formats.length * (clips.length + 2);
  let step = 0;
  const tick = () => { step++; return setProgress(4 + Math.round(88 * step / totalSteps)); };

  const now = new Date();
  const titleTxt = writeTextFile(workDir, 'title.txt',
    `${now.getFullYear()}년 ${now.getMonth() + 1}월 ${now.getDate()}일`);

  const outputs = [];
  for (const fmt of formats) {
    const [W, H] = FORMAT_SPECS[fmt];
    const fmtDir = path.join(workDir, fmt);
    fs.mkdirSync(fmtDir, { recursive: true });
    const segments = [];

    // 1) 타이틀 카드 (2초) — 파스텔 주황 + 로고 + 날짜. 첫 프레임이 앨범 썸네일이 된다.
    const titleOut = path.join(fmtDir, 'seg_000.mp4');
    const dateSize = Math.round(Math.min(W, H) * 0.048);
    if (fs.existsSync(VLOG_LOGO)) {
      const logoW = Math.round(Math.min(W, H) * 0.44);
      await runFF([
        '-f', 'lavfi', '-i', `color=c=0xFFB587:s=${W}x${H}:d=2:r=30`,
        '-i', VLOG_LOGO,
        '-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100',
        '-t', '2',
        '-filter_complex',
        `[1:v]scale=${logoW}:-1[logo];` +
        `[0:v][logo]overlay=(W-w)/2:(H-h)/2-${Math.round(H * 0.045)},` +
        `drawtext=fontfile=${VLOG_FONT}:textfile=${titleTxt}:fontcolor=white:fontsize=${dateSize}:x=(w-text_w)/2:y=h*0.565,` +
        'fade=t=out:st=1.7:d=0.3[v]',
        '-map', '[v]', '-map', '2:a', ...enc, titleOut,
      ]);
    } else {
      // 로고 파일이 없으면 기존 텍스트 카드 폴백
      const titleVf = [
        `drawtext=fontfile=${VLOG_FONT}:textfile=${titleTxt}:fontcolor=white:fontsize=${Math.round(H * 0.075)}:x=(w-text_w)/2:y=(h-text_h)/2`,
        `drawtext=fontfile=${VLOG_FONT}:text=tteona:fontcolor=white@0.75:fontsize=${Math.round(H * 0.045)}:x=(w-text_w)/2:y=h*0.87`,
        'fade=t=out:st=1.7:d=0.3',
      ].join(',');
      await runFF([
        '-f', 'lavfi', '-i', `color=c=0xFFB587:s=${W}x${H}:d=2:r=30`,
        '-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100',
        '-t', '2', '-vf', titleVf, ...enc, titleOut,
      ]);
    }
    segments.push(titleOut);
    await tick();

    // 2) 클립별 정규화 + 자막(장소명·촬영시각, 화면 중앙, 2.5초 표시 후 사라짐) + 페이드
    //    맞춤 방식: 1:1이거나 클립 방향 == 포맷 방향 → 꽉 차게 크롭 (여백 없음)
    //              반대 방향(세로 클립 → 가로 포맷 등)  → 블러 배경 패딩 (내용 보존)
    for (let i = 0; i < clips.length; i++) {
      const c = clips[i];
      const info = c.info;
      const segOut = path.join(fmtDir, `seg_${String(i + 1).padStart(3, '0')}.mp4`);
      const subTxt = writeTextFile(workDir, `sub_${i}.txt`, c.placeName || '');
      const isLast = i === clips.length - 1;
      const D = Math.max(info.duration, 0.8);

      // 자막 표시: 클립 시작 후 최대 2.5초, 페이드 인/아웃 0.4초 (알파 커브)
      const show = Math.min(2.5, D).toFixed(2);
      const fadeOutStart = Math.max(0.4, Math.min(2.5, D) - 0.4).toFixed(2);
      const alpha = `'if(lt(t,0.4),t/0.4,if(lt(t,${fadeOutStart}),1,if(lt(t,${show}),(${show}-t)/0.4,0)))'`;
      const placeSize = Math.round(Math.min(W, H) * 0.042);
      const dateSize2 = Math.round(placeSize * 0.62);
      const shadow = 'shadowcolor=black@0.35:shadowx=2:shadowy=2';

      const clipPortrait = info.height >= info.width;
      const fmtPortrait = H > W;
      const cover = fmt === 'insta' || clipPortrait === fmtPortrait;

      // 크롭(cover) 또는 블러 패딩(contain) 후 공통 오버레이 체인
      const fitChain = cover
        ? `scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},setsar=1`
        : `split=2[bga][fga];` +
          `[bga]scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},boxblur=20:3[bgb];` +
          `[fga]scale=${W}:${H}:force_original_aspect_ratio=decrease[fgs];` +
          `[bgb][fgs]overlay=(W-w)/2:(H-h)/2,setsar=1`;

      const overlays = [
        // 장소명 — 오렌지(#FF6B35), 화면 세로 중앙 바로 위
        `drawtext=fontfile=${VLOG_FONT}:textfile=${subTxt}:fontcolor=0xFF6B35:fontsize=${placeSize}:x=(w-text_w)/2:y=(h/2)-${Math.round(placeSize * 1.3)}:${shadow}:alpha=${alpha}`,
      ];
      // 촬영 시각 — 흰색, 장소명 아래 (iOS가 shotAt 전달 시)
      if (c.shotAt) {
        const dateTxt = writeTextFile(workDir, `date_${i}.txt`, String(c.shotAt));
        overlays.push(`drawtext=fontfile=${VLOG_FONT}:textfile=${dateTxt}:fontcolor=white:fontsize=${dateSize2}:x=(w-text_w)/2:y=(h/2)+${Math.round(dateSize2 * 0.3)}:${shadow}:alpha=${alpha}`);
      }
      const fades = ['fade=t=in:st=0:d=0.4'];
      if (!isLast) fades.push(`fade=t=out:st=${Math.max(0, D - 0.4).toFixed(2)}:d=0.4`);

      let af = 'afade=t=in:st=0:d=0.4';
      if (!isLast) af += `,afade=t=out:st=${Math.max(0, D - 0.4).toFixed(2)}:d=0.4`;

      const args = ['-i', c.file];
      if (!info.hasAudio) {
        args.push('-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100', '-shortest');
      }
      if (watermark) {
        // 우측 상단 tteona 로고 워터마크 — 페이드 전에 얹어 클립과 함께 페이드된다
        const wmIdx = info.hasAudio ? 1 : 2;
        const wmW = Math.round(Math.min(W, H) * 0.20);
        const wmM = Math.round(Math.min(W, H) * 0.035);
        args.push('-i', VLOG_LOGO, '-filter_complex',
          `[0:v]${fitChain},${overlays.join(',')}[base];` +
          `[${wmIdx}:v]scale=${wmW}:-1,format=rgba,colorchannelmixer=aa=0.55[wm];` +
          `[base][wm]overlay=W-w-${wmM}:${wmM},${fades.join(',')}[v]`,
          '-map', '[v]', '-map', info.hasAudio ? '0:a' : '1:a');
      } else if (cover) {
        args.push('-vf', [fitChain, ...overlays, ...fades].join(','));
      } else {
        args.push('-filter_complex', `[0:v]${fitChain},${[...overlays, ...fades].join(',')}[v]`,
                  '-map', '[v]', '-map', info.hasAudio ? '0:a' : '1:a');
      }
      args.push('-af', af, ...enc, segOut);
      await runFF(args, 15 * 60 * 1000);
      segments.push(segOut);
      await tick();
    }

    // 3) concat — 세그먼트가 전부 동일 인코딩이라 재인코딩 없이 이어붙임
    const listFile = writeTextFile(fmtDir, 'list.txt', segments.map(s => `file '${s}'`).join('\n'));
    const rawFile = path.join(fmtDir, 'raw.mp4');
    await runFF(['-f', 'concat', '-safe', '0', '-i', listFile, '-c', 'copy', '-movflags', '+faststart', rawFile]);

    // 4) BGM 믹스 — 원음 유지 + BGM 30% 볼륨, 끝 1.5초 페이드아웃
    //    (영상 스트림은 -c copy라 재인코딩 없음 → 빠름)
    const outFile = path.join(jobDir, fmt === mainFormat ? 'vlog.mp4' : `vlog_${fmt}.mp4`);
    if (bgm) {
      const total = (await probeVideo(rawFile)).duration;
      const fadeStart = Math.max(0, total - 1.5).toFixed(2);
      await runFF([
        '-i', rawFile, '-stream_loop', '-1', '-i', bgm,
        '-filter_complex',
        `[1:a]volume=0.30[bg];[0:a][bg]amix=inputs=2:duration=first:dropout_transition=3:normalize=0[mx];[mx]afade=t=out:st=${fadeStart}:d=1.5[a]`,
        '-map', '0:v', '-map', '[a]',
        '-c:v', 'copy', '-c:a', 'aac', '-ar', '44100', '-ac', '2',
        '-movflags', '+faststart', outFile,
      ]);
    } else {
      fs.copyFileSync(rawFile, outFile);
    }
    outputs.push({
      format: fmt,
      url: `https://tteona.kr/uploads/vlog/${job.id}/${path.basename(outFile)}`,
    });
    await tick();
    console.log(`[Vlog] job ${job.id} 포맷 ${fmt} 완성${bgm ? ` (BGM: ${path.basename(bgm)})` : ''}`);
  }

  await pgPool.query(
    `UPDATE vlog_jobs SET options = options || $2 WHERE id = $1`,
    [job.id, JSON.stringify({ outputs })]
  );
  await setProgress(97);

  // 중간 산출물 정리 (원본 클립은 보존 — 추후 오래된 잡 정리 크론에서 일괄 삭제)
  try { fs.rmSync(workDir, { recursive: true, force: true }); } catch {}

  return `https://tteona.kr/uploads/vlog/${job.id}/vlog.mp4`;
}

// BGM 선택 — 유저 지정(options.bgm = "mood/파일명") > 'none'(무음) > 태그별 랜덤(auto)
const BGM_DIR = path.join(__dirname, 'assets', 'bgm');
const BGM_TAG_DIR = { '커플': 'couple', '친구': 'friends', '가족': 'family', '혼자': 'solo' };
const BGM_EXT = /\.(mp3|m4a|aac|wav)$/i;

function pickBgm(job) {
  try {
    const opts = typeof job.options === 'object' && job.options !== null
      ? job.options : JSON.parse(job.options || '{}');
    if (opts.bgm === 'none') return null;
    if (opts.bgm && opts.bgm !== 'auto') {
      // 경로 탈출 방지 후 지정 트랙 사용, 없으면 자동 선택으로 폴백
      const f = path.normalize(path.join(BGM_DIR, opts.bgm));
      if (f.startsWith(BGM_DIR + path.sep) && fs.existsSync(f)) return f;
    }
    const preferred = BGM_TAG_DIR[opts.tag];
    const dirs = [];
    if (preferred) dirs.push(path.join(BGM_DIR, preferred));
    dirs.push(...Object.values(BGM_TAG_DIR).map(d => path.join(BGM_DIR, d)));
    for (const d of dirs) {
      if (!fs.existsSync(d)) continue;
      const files = fs.readdirSync(d).filter(f => BGM_EXT.test(f));
      if (files.length) return path.join(d, files[Math.floor(Math.random() * files.length)]);
    }
  } catch {}
  return null;
}

// BGM 목록 — iOS BGM 선택 화면용. [{id, name, mood, url}]
app.get('/api/vlog/bgm', (req, res) => {
  const moodLabel = { couple: '커플', friends: '친구', family: '가족', solo: '혼자' };
  const tracks = [];
  for (const [dir, label] of Object.entries(moodLabel)) {
    const d = path.join(BGM_DIR, dir);
    if (!fs.existsSync(d)) continue;
    for (const f of fs.readdirSync(d).filter(f => BGM_EXT.test(f)).sort()) {
      // 파일명 정리: "{작곡자}-{제목}-{숫자ID}.mp3" → "제목" (Title Case)
      let base = path.basename(f, path.extname(f)).replace(/-\d+$/, '');
      const parts = base.split('-');
      if (parts.length >= 2) parts.shift();   // 작곡자 접두어 제거
      const name = parts.join(' ').replace(/[_]+/g, ' ').trim()
        .replace(/\b\w/g, ch => ch.toUpperCase());
      tracks.push({
        id: `${dir}/${f}`,
        name: name || base,
        mood: label,
        url: `https://tteona.kr/api/vlog/bgm/${dir}/${encodeURIComponent(f)}`,
      });
    }
  }
  res.json({ tracks });
});

// BGM 미리듣기 스트리밍 (sendFile이 Range 요청 지원 → AVPlayer 재생 가능)
app.get('/api/vlog/bgm/:mood/:file', (req, res) => {
  const f = path.normalize(path.join(BGM_DIR, req.params.mood, req.params.file));
  if (!f.startsWith(BGM_DIR + path.sep) || !fs.existsSync(f) || !BGM_EXT.test(f)) {
    return res.status(404).json({ error: 'track not found' });
  }
  res.sendFile(f);
});

// ── 워커: 5초마다 pending 잡 1개 처리 (동시 1개 — 8코어를 한 잡에 집중) ──
let vlogBusy = false;
setInterval(async () => {
  if (vlogBusy) return;
  let job;
  try {
    const r = await pgPool.query(`
      UPDATE vlog_jobs SET status = 'processing', started_at = NOW(), progress = 1
      WHERE id = (SELECT id FROM vlog_jobs WHERE status = 'pending'
                  ORDER BY COALESCE((options->>'priority')::boolean, false) DESC, created_at LIMIT 1)
      RETURNING *`);
    if (r.rows.length === 0) return;
    job = r.rows[0];
  } catch { return; }

  vlogBusy = true;
  console.log(`[Vlog] job ${job.id} 합성 시작 (user=${job.user_id})`);
  try {
    const url = await composeVlog(job);
    await pgPool.query(
      `UPDATE vlog_jobs SET status = 'completed', progress = 100, output_url = $2, completed_at = NOW() WHERE id = $1`,
      [job.id, url]
    );
    console.log(`[Vlog] job ${job.id} 완성 → ${url}`);
    sendPush({
      userId: job.user_id,
      title: '🎬 Vlog 완성!',
      body: `${job.course_name || '나의 오늘'} 영상이 완성됐어요. 앱에서 확인해보세요!`,
      data: { type: 'vlog_done', jobId: String(job.id) },
    }).catch(() => {});
  } catch (err) {
    console.error(`[Vlog] job ${job.id} 실패:`, err.message);
    await pgPool.query(
      `UPDATE vlog_jobs SET status = 'failed', error_msg = $2 WHERE id = $1`,
      [job.id, String(err.message).slice(0, 500)]
    ).catch(() => {});
  } finally {
    vlogBusy = false;
  }
}, 5000);

// ─── 그룹 방 참여/나가기 (서버 경유) ──────────────────────────────────────────
// Firestore rules를 "멤버만 읽기"로 잠그기 위해 초대코드 조회·참여를 Admin SDK로 처리.
// 나가기도 서버에서 처리 — 마지막 멤버가 방을 정리할 때 다른 멤버의 피드/문서 삭제가
// 클라이언트 권한으로는 불가능해 "방을 못 나가는" 문제가 있었다.

app.post('/api/rooms/join', requireAuth, async (req, res) => {
  const uid = req.uid || req.body?.userId;
  const code = String(req.body?.inviteCode || '').trim().toUpperCase();
  if (!uid) return res.status(401).json({ error: 'auth required' });
  if (code.length < 4) return res.status(400).json({ error: 'invalid code' });

  try {
    const snap = await db.collection('rooms').where('inviteCode', '==', code).limit(1).get();
    if (snap.empty) return res.status(404).json({ error: 'room not found' });

    const doc = snap.docs[0];
    const room = doc.data();
    const memberIds = room.memberIds || [];

    if (!memberIds.includes(uid)) {
      const nickname = await nicknameOf(uid, req.body?.nickname);
      await doc.ref.update({ memberIds: FieldValue.arrayUnion(uid) });
      await doc.ref.collection('members').doc(uid).set({
        userId: uid, nickname, joinedAt: FieldValue.serverTimestamp(),
      });
      memberIds.push(uid);
      roomInfoCache.delete(doc.id); // 멤버십 캐시 즉시 갱신
    }

    res.json({
      roomId: doc.id,
      name: room.name || '그룹',
      inviteCode: room.inviteCode || code,
      creatorId: room.creatorId || '',
      memberIds,
    });
  } catch (err) {
    console.error('[Rooms] join error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post('/api/rooms/:roomId/leave', requireAuth, async (req, res) => {
  const uid = req.uid || req.body?.userId;
  if (!uid) return res.status(401).json({ error: 'auth required' });
  const roomId = req.params.roomId;

  try {
    const ref = db.collection('rooms').doc(roomId);
    const doc = await ref.get();
    if (!doc.exists) return res.json({ ok: true, deleted: false });

    const memberIds = doc.data().memberIds || [];
    if (!memberIds.includes(uid)) return res.json({ ok: true, deleted: false });

    if (memberIds.length <= 1) {
      // 마지막 멤버 → 하위 컬렉션(members/locations/feed/comments) 포함 방 전체 삭제
      await db.recursiveDelete(ref);
      roomInfoCache.delete(roomId);
      return res.json({ ok: true, deleted: true });
    }

    await ref.update({ memberIds: FieldValue.arrayRemove(uid) });
    await ref.collection('members').doc(uid).delete().catch(() => {});
    await ref.collection('locations').doc(uid).delete().catch(() => {});
    roomInfoCache.delete(roomId);
    res.json({ ok: true, deleted: false });
  } catch (err) {
    console.error('[Rooms] leave error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── 회원탈퇴: WAS 측 개인정보 삭제 ───────────────────────────────────────────
// iOS deleteAccount가 Cloud Function(deleteMyAccount) 호출 전에 부른다.
// (Auth 계정이 지워지기 전, 토큰이 유효할 때 실행되어야 함)
app.post('/api/users/me/purge', requireAuth, async (req, res) => {
  const uid = req.uid || req.body?.userId;
  if (!uid) return res.status(400).json({ error: 'auth required' });
  try {
    await pgPool.query('DELETE FROM device_tokens WHERE user_id = $1', [uid]).catch(() => {});
    await pgPool.query('DELETE FROM user_stats WHERE user_id = $1', [uid]).catch(() => {});
    await pgPool.query('DELETE FROM user_avatars WHERE user_id = $1', [uid]).catch(() => {});
    // 채팅 본문은 대화 맥락 유지를 위해 남기되 닉네임은 익명화
    await pgPool.query(
      `UPDATE room_messages SET nickname = '탈퇴한 사용자' WHERE user_id = $1`, [uid]
    ).catch(() => {});
    try { fs.rmSync(path.join(AVATAR_DIR, `${uid}.jpg`), { force: true }); } catch {}
    // Vlog 잡 파일 + 레코드 삭제
    const jobs = await pgPool.query('SELECT id FROM vlog_jobs WHERE user_id = $1', [uid]).catch(() => ({ rows: [] }));
    for (const j of jobs.rows) {
      try { fs.rmSync(path.join(VLOG_DIR, String(j.id)), { recursive: true, force: true }); } catch {}
    }
    await pgPool.query('DELETE FROM vlog_jobs WHERE user_id = $1', [uid]).catch(() => {});
    res.json({ ok: true });
  } catch (err) {
    console.error('[Purge] error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── 그룹 채팅 기록 ───────────────────────────────────────────────────────────
// 최근 메시지 조회 (오래된 → 최신 순으로 반환). WebSocket 접속 전 히스토리 로드용.
// 방 멤버만 조회 가능 — 사적 대화 유출 방지.
app.get('/api/rooms/:roomId/messages', requireAuth, async (req, res) => {
  const { roomId } = req.params;
  const limit = Math.min(parseInt(req.query.limit) || 50, 200);
  const before = req.query.before; // ISO 타임스탬프 — 페이지네이션(더 이전 메시지)
  try {
    if (req.uid) {
      const info = await getRoomInfo(roomId, { refreshIfMissing: req.uid });
      if (!info || !info.memberIds.includes(req.uid)) {
        return res.status(403).json({ error: 'not a room member' });
      }
    }
    const params = [roomId, limit];
    let where = 'room_id = $1';
    if (before) { params.splice(1, 0, before); where += ' AND created_at < $2'; }
    const result = await pgPool.query(
      `SELECT id, message_id, user_id, nickname, text, reply_to_nickname, reply_to_text, created_at
       FROM room_messages WHERE ${where}
       ORDER BY created_at DESC LIMIT $${params.length}`,
      params
    );
    const rows = result.rows.reverse();

    // 반응 병합
    const ids = rows.map(r => r.message_id).filter(Boolean);
    if (ids.length > 0) {
      const rx = await pgPool.query(
        'SELECT message_id, emoji, user_id FROM room_message_reactions WHERE message_id = ANY($1)',
        [ids]
      );
      const byMsg = {};
      rx.rows.forEach(r => {
        (byMsg[r.message_id] = byMsg[r.message_id] || []).push({ emoji: r.emoji, userId: r.user_id });
      });
      rows.forEach(r => { r.reactions = byMsg[r.message_id] || []; });
    }
    res.json({ messages: rows });
  } catch (err) {
    console.error('[RoomMessages] error:', err);
    res.status(500).json({ error: err.message });
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

    // 웹 미리보기 지도용 좌표 (스크립트 주입 방지: JSON 직렬화 후 < 이스케이프)
    const placesCoords = places
      .filter(p => typeof p.latitude === 'number' && typeof p.longitude === 'number')
      .map(p => ({ name: p.placeName || '', lat: p.latitude, lng: p.longitude }));

    res.send(courseHtml({ courseId, courseName, ogDescription, placeNames, placeCount, placesCoords }));
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

function courseHtml({ courseId, courseName, ogDescription, placeNames, placeCount, placesCoords = [] }) {
  const ogTitle = `${courseName} — 떠나 코스`;
  const ogUrl   = `https://tteona.kr/course/${courseId}`;
  const ogImage = 'https://tteona.kr/og-image.png';
  const coordsJson = JSON.stringify(placesCoords).replace(/</g, '\\u003c');
  const hasMap = placesCoords.length >= 1;

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
  ${hasMap ? '<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">' : ''}

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

    /* ── 미리보기 지도 ── */
    .map-section {
      padding: 28px 24px 0;
      position: relative;
      z-index: 2;
    }
    .map-eyebrow {
      font-size: 10px;
      font-weight: 700;
      color: rgba(255,255,255,0.25);
      letter-spacing: 2px;
      text-transform: uppercase;
      margin-bottom: 14px;
    }
    #course-map {
      width: 100%;
      height: 280px;
      border-radius: 18px;
      border: 1px solid rgba(255,255,255,0.08);
      background: #0d1a20;
    }
    .map-pin-icon {
      width: 26px; height: 26px; border-radius: 50%;
      background: #FF6B35; color: #fff;
      font-size: 12px; font-weight: 700;
      display: flex; align-items: center; justify-content: center;
      border: 2px solid #fff;
      box-shadow: 0 2px 8px rgba(0,0,0,0.45);
      font-family: 'Noto Sans KR', sans-serif;
    }
    .leaflet-container { font-family: 'Noto Sans KR', sans-serif; }
    .leaflet-control-attribution { background: rgba(0,0,0,0.4) !important; color: rgba(255,255,255,0.4) !important; font-size: 9px !important; }
    .leaflet-control-attribution a { color: rgba(255,255,255,0.55) !important; }

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

  <!-- 코스 동선 미리보기 지도 -->
  ${hasMap ? `
  <div class="map-section">
    <div class="map-eyebrow">MAP PREVIEW</div>
    <div id="course-map"></div>
  </div>` : ''}

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
      // courseId를 JSON 직렬화로 안전하게 삽입 (스크립트 주입 방지)
      window.location.href = 'tteona://course?id=' + encodeURIComponent(${JSON.stringify(String(courseId)).replace(/</g, '\\u003c')});
      setTimeout(function() {
        document.getElementById('storeBtn').click();
      }, 2500);
    }
  </script>
  ${hasMap ? `
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    (function () {
      var coords = ${coordsJson};
      var map = L.map('course-map', {
        zoomControl: false,
        scrollWheelZoom: false,
        dragging: !L.Browser.mobile,
        tap: false,
        attributionControl: true
      });
      L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
        attribution: '&copy; OpenStreetMap &copy; CARTO',
        maxZoom: 19
      }).addTo(map);

      var latlngs = coords.map(function (c) { return [c.lat, c.lng]; });

      if (latlngs.length >= 2) {
        L.polyline(latlngs, {
          color: '#FF6B35', weight: 4, opacity: 0.9,
          lineCap: 'round', lineJoin: 'round'
        }).addTo(map);
      }

      coords.forEach(function (c, i) {
        L.marker([c.lat, c.lng], {
          icon: L.divIcon({
            className: '',
            html: '<div class="map-pin-icon">' + (i + 1) + '</div>',
            iconSize: [26, 26],
            iconAnchor: [13, 13]
          })
        }).addTo(map).bindPopup(
          '<b>' + (i + 1) + '. ' + c.name.replace(/</g, '&lt;') + '</b>',
          { closeButton: false }
        );
      });

      if (latlngs.length === 1) {
        map.setView(latlngs[0], 15);
      } else {
        map.fitBounds(L.latLngBounds(latlngs), { padding: [34, 34] });
      }
    })();
  </script>` : ''}
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

// ─── Admin API ───────────────────────────────────────────────────────────────

// ADMIN_PASSWORD / ADMIN_TOKEN 은 파일 상단에서 환경변수 필수로 로드됨

function adminAuth(req, res, next) {
  const auth = req.headers['authorization'] || '';
  if (auth === `Bearer ${ADMIN_TOKEN}`) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

// 로그인 브루트포스 방어 — IP당 15분에 5회
const adminLoginAttempts = new Map(); // ip → { count, resetAt }
app.post('/api/admin/login', (req, res) => {
  const ip = req.ip || 'unknown';
  const now = Date.now();
  const entry = adminLoginAttempts.get(ip);
  if (entry && now < entry.resetAt && entry.count >= 5) {
    return res.status(429).json({ error: '시도 횟수를 초과했습니다. 잠시 후 다시 시도해주세요.' });
  }
  const { password } = req.body;
  if (password === ADMIN_PASSWORD) {
    adminLoginAttempts.delete(ip);
    return res.json({ token: ADMIN_TOKEN });
  }
  if (!entry || now >= entry.resetAt) {
    adminLoginAttempts.set(ip, { count: 1, resetAt: now + 15 * 60 * 1000 });
  } else {
    entry.count += 1;
  }
  res.status(401).json({ error: '비밀번호가 틀렸습니다' });
});

app.get('/api/admin/stats', adminAuth, async (req, res) => {
  try {
    const weekAgo = Timestamp.fromMillis(Date.now() - 7 * 86400000);
    const [usersSnap, newUsersSnap, coursesSnap, reportsSnap, pgStats, activeStats, cacheStats] = await Promise.all([
      db.collection('users').count().get(),
      // 신규 가입: users 문서 createdAt 기준 (daily_stats.new_users는 적재 로직이 없어 항상 0이었음)
      db.collection('users').where('createdAt', '>=', weekAgo).count().get(),
      db.collection('courses').count().get(),
      db.collection('reports').where('processed', '!=', true).count().get(),
      pgPool.query(`
        SELECT COALESCE(SUM(courses_created),0) AS courses_7d
        FROM daily_stats
        WHERE stat_date >= CURRENT_DATE - INTERVAL '7 days'
      `),
      // 활성 유저: 최근 7일 user_stats에 이벤트가 있는 고유 유저 수
      pgPool.query(`
        SELECT COUNT(DISTINCT user_id) AS active_users_7d
        FROM user_stats
        WHERE stat_date >= CURRENT_DATE - INTERVAL '7 days'
      `),
      pgPool.query('SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE expires_at > NOW()) AS valid FROM places_cache'),
    ]);

    res.json({
      totalUsers:       usersSnap.data().count,
      totalCourses:     coursesSnap.data().count,
      pendingReports:   reportsSnap.data().count,
      newUsers7d:       newUsersSnap.data().count,
      activeUsers7d:    Number(activeStats.rows[0].active_users_7d),
      coursesCreated7d: Number(pgStats.rows[0].courses_7d),
      placesCacheTotal: Number(cacheStats.rows[0].total),
      placesCacheValid: Number(cacheStats.rows[0].valid),
    });
  } catch (err) {
    console.error('admin stats error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/admin/reports', adminAuth, async (req, res) => {
  try {
    const snap = await db.collection('reports')
      .orderBy('createdAt', 'desc')
      .limit(50)
      .get();
    const reports = snap.docs.map(d => ({ id: d.id, ...d.data(), createdAt: d.data().createdAt?.toDate() }));
    res.json(reports);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.delete('/api/admin/courses/:courseId', adminAuth, async (req, res) => {
  try {
    await db.collection('courses').doc(req.params.courseId).delete();
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/admin/reports/:reportId/resolve', adminAuth, async (req, res) => {
  try {
    await db.collection('reports').doc(req.params.reportId).update({ processed: true });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/admin/users', adminAuth, async (req, res) => {
  try {
    const { search } = req.query;
    let query = db.collection('users').orderBy('createdAt', 'desc').limit(30);
    const snap = await query.get();
    let users = snap.docs.map(d => ({ uid: d.id, ...d.data(), createdAt: d.data().createdAt?.toDate() }));
    if (search) {
      const q = search.toLowerCase();
      users = users.filter(u =>
        (u.nickname || '').toLowerCase().includes(q) ||
        (u.email || '').toLowerCase().includes(q)
      );
    }
    res.json(users);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/admin/users/:uid/block', adminAuth, async (req, res) => {
  try {
    await db.collection('users').doc(req.params.uid).update({ isBlocked: true });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/admin/users/:uid/unblock', adminAuth, async (req, res) => {
  try {
    await db.collection('users').doc(req.params.uid).update({ isBlocked: false });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── Haversine ────────────────────────────────────────────────────────────────

// 현재 계절 + 계절 키워드 (서버 타임존 Asia/Seoul 기준)
function currentSeason() {
  const m = new Date().getMonth() + 1; // 1–12
  if (m >= 3 && m <= 5)  return { name: '봄',   words: ['벚꽃', '꽃', '봄', '유채', '튤립', '꽃놀이', '봄나들이'] };
  if (m >= 6 && m <= 8)  return { name: '여름', words: ['해변', '바다', '해수욕', '계곡', '물놀이', '수영', '워터', '섬', '피서'] };
  if (m >= 9 && m <= 11) return { name: '가을', words: ['단풍', '억새', '가을', '코스모스', '국화', '낙엽'] };
  return { name: '겨울', words: ['야경', '눈', '스키', '온천', '겨울', '일루미네이션', '조명', '불빛', '눈꽃'] };
}

function haversineKm(lat1, lng1, lat2, lng2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// 대표 장소 — iOS Course.mainPlace 로직과 동일 (지정 order 우선, 아니면 경유지 후순위 자동 선택)
function isTransitLikePlace(name) {
  if (typeof name !== 'string') return false;
  if (name.endsWith('역')) return true;
  return ['주차장', '터미널', '정류장', '환승센터', '휴게소', '톨게이트', '공영주차'].some(k => name.includes(k));
}
function mainPlaceOf(course) {
  const places = course.places || [];
  if (places.length === 0) return null;
  if (course.mainPlaceOrder != null) {
    const p = places.find(pl => pl.order === course.mainPlaceOrder);
    if (p) return p;
  }
  return places.find(pl => !isTransitLikePlace(pl.placeName)) || places[0];
}

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

// ─── 그룹 채팅 오프라인 푸시 ───────────────────────────────────────────────────

// 방 정보(이름 + 멤버) 캐시 — 메시지마다 Firestore 조회 방지 (5분 TTL)
const roomInfoCache = new Map(); // roomId → { name, memberIds, at }

// refreshIfMissing: 해당 uid가 캐시에 없으면 캐시를 무시하고 새로 조회
// (방금 초대코드로 참여한 멤버가 5분 캐시 때문에 거부되는 것 방지)
async function getRoomInfo(roomId, { refreshIfMissing } = {}) {
  const c = roomInfoCache.get(roomId);
  if (c && Date.now() - c.at < 5 * 60 * 1000) {
    if (!refreshIfMissing || c.memberIds.includes(refreshIfMissing)) return c;
  }
  const doc = await db.collection('rooms').doc(roomId).get();
  if (!doc.exists) return null;
  const d = doc.data();
  const info = { name: d.name || '그룹', memberIds: d.memberIds || [], at: Date.now() };
  roomInfoCache.set(roomId, info);
  return info;
}

// 발신자·접속중 멤버를 제외한 나머지에게만 채팅 푸시
async function pushChatToOfflineMembers(roomId, senderId, senderNick, text, connectedSet) {
  try {
    const info = await getRoomInfo(roomId);
    if (!info) return;
    const targets = info.memberIds.filter(id => id !== senderId && !connectedSet.has(id));
    for (const id of targets) {
      sendPush({
        userId: id,
        title:  info.name,
        body:   `${senderNick}: ${text}`,
        data:   { type: 'chat', roomId, senderUserId: senderId },
      }).catch(() => {});
    }
  } catch (e) {
    console.error('[WS chat push] error:', e.message);
  }
}

// ─── WebSocket 실시간 위치 공유 ───────────────────────────────────────────────

const httpServer = http.createServer(app);
const wss = new WebSocket.Server({ server: httpServer, path: '/ws/location' });

// roomId → Set<WebSocket>
const wsRooms = new Map();

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }

    if (msg.type === 'join') {
      // Firebase ID 토큰 검증 + 방 멤버십 확인 후에만 입장
      // (위치·채팅이 실시간으로 흐르는 방이므로 도청/사칭 차단이 필수)
      (async () => {
        let uid = null;
        if (msg.idToken) {
          try {
            uid = (await getAuth().verifyIdToken(String(msg.idToken))).uid;
          } catch {
            ws.send(JSON.stringify({ type: 'auth_error', reason: 'invalid token' }));
            return ws.close(4001, 'invalid token');
          }
        } else if (AUTH_ENFORCE) {
          ws.send(JSON.stringify({ type: 'auth_error', reason: 'auth required' }));
          return ws.close(4001, 'auth required');
        }

        const effectiveUid = uid || msg.userId; // 완화 모드(구버전 앱)만 msg.userId 허용
        if (uid) {
          const info = await getRoomInfo(msg.roomId, { refreshIfMissing: uid }).catch(() => null);
          if (!info || !info.memberIds.includes(uid)) {
            ws.send(JSON.stringify({ type: 'auth_error', reason: 'not a room member' }));
            return ws.close(4003, 'not a room member');
          }
        }

        ws.roomId   = msg.roomId;
        ws.userId   = effectiveUid;
        ws.nickname = uid ? await nicknameOf(uid, msg.nickname) : (msg.nickname || '');
        if (!wsRooms.has(msg.roomId)) wsRooms.set(msg.roomId, new Set());
        wsRooms.get(msg.roomId).add(ws);
        ws.send(JSON.stringify({ type: 'joined', roomId: msg.roomId }));
        console.log(`[WS] ${effectiveUid} joined room ${msg.roomId}`);
      })().catch(e => console.error('[WS join] error:', e.message));
    }

    if (msg.type === 'location' && ws.roomId) {
      const payload = JSON.stringify({
        type:      'location',
        userId:    ws.userId,
        nickname:  ws.nickname,
        latitude:  msg.latitude,
        longitude: msg.longitude,
        ts:        Date.now(),
      });
      const room = wsRooms.get(ws.roomId);
      if (room) {
        room.forEach(client => {
          if (client !== ws && client.readyState === WebSocket.OPEN) {
            client.send(payload);
          }
        });
      }
    }

    // 그룹 실시간 채팅 — PostgreSQL 저장 후 방 전체에 브로드캐스트
    if (msg.type === 'chat' && ws.roomId) {
      const text = (msg.text || '').toString().slice(0, 2000).trim();
      if (!text) return;
      const clientMsgId = msg.clientMsgId || null;  // 발신자 중복 제거용

      // 금칙어 검사 — 댓글/코스명과 동일 기준. 차단 시 발신자에게만 알리고 전파하지 않음
      if (findBannedWord(text)) {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'chat_blocked', clientMsgId }));
        }
        return;
      }
      const messageId = randomUUID();  // 반응·답장 기준이 되는 안정적 고유 ID
      // 답장(인용) 정보 — 상대 메시지 꾹 눌러 답장 시
      const replyToNickname = msg.replyToNickname ? String(msg.replyToNickname).slice(0, 60) : null;
      const replyToText     = msg.replyToText ? String(msg.replyToText).slice(0, 200) : null;
      const createdAt = new Date();

      // 저장 (fire-and-forget, 실패해도 브로드캐스트는 진행)
      pgPool.query(
        `INSERT INTO room_messages (message_id, room_id, user_id, nickname, text, reply_to_nickname, reply_to_text, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
        [messageId, ws.roomId, ws.userId, ws.nickname, text, replyToNickname, replyToText, createdAt]
      ).catch(e => console.error('[WS chat] persist error:', e.message));

      const payload = JSON.stringify({
        type:            'chat',
        messageId,
        roomId:          ws.roomId,
        userId:          ws.userId,
        nickname:        ws.nickname,
        text,
        replyToNickname,
        replyToText,
        clientMsgId,
        ts:              createdAt.getTime(),
      });
      const room = wsRooms.get(ws.roomId);
      const connected = new Set();
      if (room) {
        room.forEach(client => {
          // 발신자 포함 전원에게 전송 (발신자는 clientMsgId로 낙관적 메시지 확정)
          if (client.readyState === WebSocket.OPEN) client.send(payload);
          if (client.userId) connected.add(client.userId);
        });
      }
      // 접속 안 한 멤버에게만 APNs 푸시 (카톡처럼 "닉네임: 메시지")
      pushChatToOfflineMembers(ws.roomId, ws.userId, ws.nickname, text, connected);
    }

    // 이모지 반응 토글 — 있으면 제거, 없으면 추가 후 방 전체에 브로드캐스트
    if (msg.type === 'reaction' && ws.roomId) {
      const messageId = String(msg.messageId || '');
      const emoji = String(msg.emoji || '').slice(0, 8);
      if (!messageId || !emoji) return;
      const roomId = ws.roomId, userId = ws.userId;
      (async () => {
        try {
          const del = await pgPool.query(
            'DELETE FROM room_message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3',
            [messageId, userId, emoji]
          );
          let added = false;
          if (del.rowCount === 0) {
            await pgPool.query(
              `INSERT INTO room_message_reactions (message_id, user_id, emoji)
               VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
              [messageId, userId, emoji]
            );
            added = true;
          }
          const payload = JSON.stringify({ type: 'reaction', messageId, emoji, userId, added });
          const room = wsRooms.get(roomId);
          if (room) room.forEach(c => { if (c.readyState === WebSocket.OPEN) c.send(payload); });
        } catch (e) {
          console.error('[WS reaction] error:', e.message);
        }
      })();
    }

    if (msg.type === 'leave') wsLeaveRoom(ws);
  });

  ws.on('close', () => wsLeaveRoom(ws));
  ws.on('error', () => wsLeaveRoom(ws));
});

function wsLeaveRoom(ws) {
  if (!ws.roomId) return;
  const room = wsRooms.get(ws.roomId);
  if (room) {
    room.delete(ws);
    const leftMsg = JSON.stringify({ type: 'left', userId: ws.userId });
    room.forEach(client => {
      if (client.readyState === WebSocket.OPEN) client.send(leftMsg);
    });
    if (room.size === 0) wsRooms.delete(ws.roomId);
  }
  console.log(`[WS] ${ws.userId} left room ${ws.roomId}`);
  ws.roomId = null;
}

// 30초마다 끊긴 연결 정리
setInterval(() => {
  wss.clients.forEach(ws => {
    if (!ws.isAlive) { ws.terminate(); return; }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

httpServer.listen(PORT, () => {
  console.log(`tteona API server running on port ${PORT}`);
  console.log('Firebase Admin SDK initialized ✅');
  console.log('WebSocket server ready at /ws/location ✅');
});
