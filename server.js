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
const { randomUUID, createHash, randomBytes, timingSafeEqual } = require('crypto');
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getAuth } = require('firebase-admin/auth');
const { getMessaging } = require('firebase-admin/messaging');

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

// 기동 시 device_tokens 스키마 보정 — Android(FCM) 지원을 위해 platform 컬럼 추가,
// 유니크 키는 (user_id, platform) → token 으로 전환.
//
// (user_id, platform) 유니크는 두 가지를 동시에 깨뜨렸다:
//  1) 한 유저가 기기 2대를 쓰면 나중에 등록한 기기만 푸시를 받는다.
//  2) 한 기기에서 A가 로그아웃하고 B가 로그인하면 같은 토큰이 두 user_id에 묶여,
//     A에게 갈 알림이 B의 화면에 뜬다(실제로 운영 DB에 이런 토큰이 있었다).
// 토큰은 기기당 하나이므로 token을 유니크로 두면 두 문제가 함께 사라진다.
async function ensurePushSchema() {
  await pgPool.query(
    `ALTER TABLE device_tokens ADD COLUMN IF NOT EXISTS platform TEXT NOT NULL DEFAULT 'ios'`
  );
  // 알림 문구는 수신자의 앱 언어로 쓴다 — 기기가 등록 시 알려준다.
  await pgPool.query(
    `ALTER TABLE device_tokens ADD COLUMN IF NOT EXISTS lang TEXT NOT NULL DEFAULT 'ko'`
  );
  await pgPool.query(`ALTER TABLE device_tokens DROP CONSTRAINT IF EXISTS device_tokens_pkey`);
  await pgPool.query(`ALTER TABLE device_tokens DROP CONSTRAINT IF EXISTS device_tokens_user_id_key`);

  // 유니크 인덱스를 걸기 전에 같은 토큰의 낡은 행을 정리한다(최신 updated_at만 남김).
  await pgPool.query(`
    DELETE FROM device_tokens a
     USING device_tokens b
     WHERE a.token = b.token
       AND (a.updated_at < b.updated_at
            OR (a.updated_at = b.updated_at AND a.ctid < b.ctid))
  `);
  await pgPool.query(
    `CREATE UNIQUE INDEX IF NOT EXISTS device_tokens_token_idx ON device_tokens (token)`
  );
  await pgPool.query(`DROP INDEX IF EXISTS device_tokens_user_platform_idx`);
}
ensurePushSchema().catch(err => console.error('[Push] schema migration error:', err.message));

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

// ─── 푸시 문구 (수신자 언어 기준) ─────────────────────────────────────────────
// 알림은 "보내는 사람"이 아니라 "받는 사람"의 언어로 쓰여야 한다.
// device_tokens.lang에 기기 언어를 저장해 두고, 발송 직전에 문구를 고른다.
const PUSH_LANGS = new Set(['ko', 'en', 'ja']);
const pushLang = (lang) => (PUSH_LANGS.has(lang) ? lang : 'ko');

const PUSH_TEXT = {
  courseLiked: {
    ko: (p) => ({ title: '코스에 좋아요가 달렸어요 ❤️', body: `${p.nickname}님이 "${p.courseName}" 코스를 좋아합니다` }),
    en: (p) => ({ title: 'Someone liked your course ❤️', body: `${p.nickname} liked your course "${p.courseName}"` }),
    ja: (p) => ({ title: 'コースにいいねがつきました ❤️', body: `${p.nickname}さんがコース「${p.courseName}」にいいねしました` }),
  },
  courseFollowed: {
    ko: (p) => ({ title: '누군가 내 코스를 따라가고 있어요 🗺️', body: `${p.nickname}님이 "${p.courseName}" 코스 여행을 시작했어요` }),
    en: (p) => ({ title: 'Someone is following your course 🗺️', body: `${p.nickname} started traveling your course "${p.courseName}"` }),
    ja: (p) => ({ title: '誰かがあなたのコースをたどっています 🗺️', body: `${p.nickname}さんがコース「${p.courseName}」の旅を始めました` }),
  },
  // 한쪽만 0인 경우가 흔하다(코스만 만들고 여행은 안 감). 두 항목을 단순히 이어붙이면
  // "코스 3개 만들었고!"처럼 어미가 끊기므로 언어별로 문장을 완성해서 고른다.
  weeklyReport: {
    ko: (p) => ({
      title: '이번 주 여행 리포트 📊',
      body: `지난 7일간 ${
        p.courses > 0 && p.places > 0 ? `코스 ${p.courses}개 만들었고, 장소 ${p.places}곳 방문했어요`
        : p.courses > 0               ? `코스 ${p.courses}개 만들었어요`
        :                               `장소 ${p.places}곳 방문했어요`}!`,
    }),
    en: (p) => {
      const c = `created ${p.courses} course${p.courses > 1 ? 's' : ''}`;
      const v = `visited ${p.places} place${p.places > 1 ? 's' : ''}`;
      return {
        title: 'Your weekly travel report 📊',
        body: `In the last 7 days you ${
          p.courses > 0 && p.places > 0 ? `${c} and ${v}` : p.courses > 0 ? c : v}!`,
      };
    },
    ja: (p) => ({
      title: '今週の旅レポート 📊',
      body: `この7日間で${
        p.courses > 0 && p.places > 0 ? `コースを${p.courses}件作成し、${p.places}か所を訪れました`
        : p.courses > 0               ? `コースを${p.courses}件作成しました`
        :                               `${p.places}か所を訪れました`}！`,
    }),
  },
  vlogDone: {
    ko: (p) => ({ title: '🎬 Vlog 완성!', body: `${p.courseName || '나의 오늘'} 영상이 완성됐어요. 앱에서 확인해보세요!` }),
    en: (p) => ({ title: '🎬 Your Vlog is ready!', body: `Your "${p.courseName || 'My Day'}" video is ready. Check it out in the app!` }),
    ja: (p) => ({ title: '🎬 Vlog 完成！', body: `「${p.courseName || '私の今日'}」の動画が完成しました。アプリで確認してみてください！` }),
  },
};

/// PUSH_TEXT 항목을 sendPush가 쓰는 (lang) => {title, body} 형태로 바꾼다.
const localized = (key, params) => (lang) => PUSH_TEXT[key][pushLang(lang)](params);
/// 채팅처럼 언어와 무관한 문구(방 이름·발신자 닉네임)는 그대로 흘려보낸다.
const literal = (title, body) => () => ({ title, body });

// ─── APNs Provider ────────────────────────────────────────────────────────────

// APNs 토큰은 발급된 환경에서만 유효하다. Xcode로 설치한 빌드는 sandbox 토큰을,
// TestFlight/App Store 빌드는 production 토큰을 받는다. production으로만 보내던 탓에
// 개발 빌드의 토큰은 전부 400 BadDeviceToken으로 떨어졌다(운영 로그에서 확인).
// 두 환경을 모두 열어두고, production이 BadDeviceToken을 주면 sandbox로 재시도한다.
const apnCredentials = {
  token: {
    key:    process.env.APNS_KEY_PATH || '/home/ubuntu/tteona-api/keys/AuthKey_Z255DQRVA2.p8',
    keyId:  process.env.APNS_KEY_ID   || 'Z255DQRVA2',
    teamId: process.env.APNS_TEAM_ID  || 'M576JMA5A7',
  },
};
const apnProduction = new apn.Provider({ ...apnCredentials, production: true });
const apnSandbox    = new apn.Provider({ ...apnCredentials, production: false });

const BUNDLE_ID = 'com.seoktaedev.tteona';

// 토큰 → 마지막으로 성공한 환경. 개발 기기가 매번 production을 헛치는 왕복을 줄인다.
// 프로세스 메모리라 재시작하면 비지만, 첫 발송 한 번만 재시도하면 다시 채워진다.
const apnsEnvHint = new Map();

/// 한 기기에 알림 1건 전송. 성공하면 { ok: true }, 토큰이 죽었으면 { dead: true }.
async function sendApns(token, note) {
  const order = apnsEnvHint.get(token) === 'sandbox'
    ? [['sandbox', apnSandbox], ['production', apnProduction]]
    : [['production', apnProduction], ['sandbox', apnSandbox]];

  let lastReason = null;
  for (const [env, provider] of order) {
    const res = await provider.send(note, token);
    if (res.sent.length > 0) {
      apnsEnvHint.set(token, env);
      return { ok: true };
    }
    lastReason = res.failed[0]?.response?.reason || res.failed[0]?.error?.message || 'unknown';
    // 다른 환경에서는 살아있을 수 있는 토큰 — 남은 환경으로 계속 시도한다.
    if (lastReason !== 'BadDeviceToken') break;
  }

  apnsEnvHint.delete(token);
  // 두 환경 모두 거절 = 이 토큰은 어디서도 유효하지 않다. Unregistered는 앱 삭제.
  const dead = lastReason === 'BadDeviceToken' || lastReason === 'Unregistered';
  return { ok: false, dead, error: lastReason };
}

/// iOS 배지는 절대값만 실을 수 있다 — APNs에 증분 개념이 없다. 그래서 안 읽은 알림 수를
/// userPrivate/{uid}.badgeCount에 누적해 두고 발송할 때 그 값을 싣는다.
/// 앱이 포그라운드로 올라오면 클라이언트가 0으로 되돌린다.
/// WAS와 Cloud Functions가 같은 문서를 증가시키므로 두 경로의 알림이 함께 세어진다.
async function bumpBadge(userId) {
  try {
    const ref = db.collection('userPrivate').doc(userId);
    await ref.set({ badgeCount: FieldValue.increment(1) }, { merge: true });
    const n = (await ref.get()).data()?.badgeCount;
    return Number.isInteger(n) && n > 0 ? n : 1;
  } catch (err) {
    // 배지는 부가 정보다 — 세는 데 실패했다고 알림 자체를 포기하지 않는다.
    console.error('[Push] badge bump error:', err.message);
    return 1;
  }
}

/// message: (lang) => ({ title, body }) — 기기마다 등록된 언어로 문구를 만든다.
/// 한 유저가 한국어 폰과 영어 폰을 함께 쓰면 각 기기가 제 언어로 받는다.
async function sendPush({ userId, message, data = {} }) {
  try {
    const result = await pgPool.query(
      'SELECT token, platform, lang FROM device_tokens WHERE user_id = $1',
      [userId]
    );
    if (result.rows.length === 0) return { skipped: true, reason: 'no token' };

    // 배지는 iOS에만 의미가 있다 — 안드로이드 전용 유저의 카운터를 헛되이 올리지 않는다.
    const hasIOS = result.rows.some(row => row.platform !== 'android');
    const badge = hasIOS ? await bumpBadge(userId) : 0;

    let ok = false;
    let lastError = null;
    for (const row of result.rows) {
      const { title, body } = message(row.lang);
      if (row.platform === 'android') {
        // Android — FCM (data 값은 문자열만 허용)
        try {
          const fcmData = {};
          for (const [k, v] of Object.entries(data)) fcmData[k] = String(v);
          await getMessaging().send({
            token: row.token,
            notification: { title, body },
            data: fcmData,
            android: { priority: 'high' },
          });
          ok = true;
        } catch (err) {
          lastError = err.message;
          console.error('[FCM] sendPush error:', err.message);
          // 무효 토큰 정리 — 앱 삭제/토큰 로테이션
          if (String(err.code || '').includes('registration-token-not-registered')) {
            pgPool.query(
              'DELETE FROM device_tokens WHERE user_id = $1 AND token = $2',
              [userId, row.token]
            ).catch(() => {});
          }
        }
      } else {
        // iOS — APNs
        const note = new apn.Notification();
        note.expiry = Math.floor(Date.now() / 1000) + 3600;
        note.badge  = badge;   // 고정 1이 아니라 실제 안 읽은 알림 수
        note.sound  = 'default';
        note.alert  = { title, body };
        note.payload = data;
        note.topic   = BUNDLE_ID;
        note.pushType = 'alert';

        const res = await sendApns(row.token, note);
        if (res.ok) {
          ok = true;
        } else {
          lastError = res.error;
          console.error(`[APNs] failed (${res.error}) user=${userId}`);
          // 죽은 토큰 정리 — Android와 달리 그동안 쌓이기만 했다.
          if (res.dead) {
            pgPool.query('DELETE FROM device_tokens WHERE token = $1', [row.token]).catch(() => {});
          }
        }
      }
    }
    return ok ? { ok: true } : { ok: false, error: lastError };
  } catch (err) {
    console.error('[Push] sendPush error:', err.message);
    return { ok: false, error: err.message };
  }
}

const app = express();
const PORT = 3000;

// Nginx 리버스 프록시 1홉 뒤에서 동작 — X-Forwarded-For의 실제 클라이언트 IP를
// req.ip로 신뢰. 미설정 시 req.ip가 항상 프록시 내부 IP로 잡혀
// IP 기반 레이트리밋(관리자 로그인 등)이 전체 사용자에게 뭉뚱그려 적용된다.
app.set('trust proxy', 1);

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({ origin: ['https://tteona.kr', 'https://www.tteona.kr'] }));
app.use(morgan('combined'));
app.use(express.json());

// ─── 썸네일 업로드 설정 ────────────────────────────────────────────────────────

const THUMB_DIR = path.join(__dirname, 'uploads', 'thumbnails');
const AVATAR_DIR = path.join(__dirname, 'uploads', 'avatars');
const ROOM_IMG_DIR = path.join(__dirname, 'uploads', 'rooms');
fs.mkdirSync(THUMB_DIR, { recursive: true });
fs.mkdirSync(AVATAR_DIR, { recursive: true });
fs.mkdirSync(ROOM_IMG_DIR, { recursive: true });

// Vlog 완성본은 본인만 다운로드 가능 — jobId가 순번이라 추측 가능하므로 소유자 검증
// (썸네일·아바타는 공개 프로필/공유 페이지에서 쓰이므로 그대로 공개)
// 예외: 채팅방에 공유된 완성본은 ?st=공유토큰(128bit 랜덤)으로 방 멤버가 무인증 재생.
// 토큰은 방 멤버에게만 전달되는 채팅 메시지에 실리므로 사실상 멤버 한정 링크다.
app.use('/uploads/vlog', async (req, res, next) => {
  const m = req.path.match(/^\/(\d+)\//);
  if (!m) return res.status(404).json({ error: 'not found' });

  const st = typeof req.query.st === 'string' ? req.query.st : null;
  if (st) {
    try {
      const r = await pgPool.query(
        `SELECT options->>'shareToken' AS tok FROM vlog_jobs WHERE id = $1`, [m[1]]
      );
      const tok = r.rows[0]?.tok;
      if (tok && tok.length === st.length &&
          timingSafeEqual(Buffer.from(tok), Buffer.from(st))) {
        return next();
      }
    } catch { /* 아래 403 */ }
    return res.status(403).json({ error: 'forbidden' });
  }

  // 기존 소유자 경로 — 변경 없음
  requireAuth(req, res, async () => {
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
});

app.use('/uploads', express.static(path.join(__dirname, 'uploads'), {
  maxAge: '30d',
  immutable: false,
}));

// ─── 인메모리 레이트리밋 팩토리 ────────────────────────────────────────────────
// 외부 의존성 없이 IP(또는 uid) 단위 버킷으로 요청량 제한. PM2 단일 프로세스 전제.
// 고비용 라우트(Vlog 합성·업로드·푸시·캐시쓰기)에 붙여 인증 계정 1개로 서버
// 자원을 고갈시키는 남용을 차단한다. (trust proxy 설정으로 req.ip는 실제 클라이언트 IP)
function rateLimit({ windowMs, max, key, message }) {
  const hits = new Map(); // bucketKey → { count, resetAt }
  const timer = setInterval(() => {
    const now = Date.now();
    for (const [k, v] of hits) if (now >= v.resetAt) hits.delete(k);
  }, windowMs);
  if (typeof timer.unref === 'function') timer.unref(); // 종료 시 프로세스 붙잡지 않도록
  return (req, res, next) => {
    const now = Date.now();
    const bucket = (key ? key(req) : req.ip) || 'unknown';
    let entry = hits.get(bucket);
    if (!entry || now >= entry.resetAt) {
      entry = { count: 0, resetAt: now + windowMs };
      hits.set(bucket, entry);
    }
    entry.count++;
    if (entry.count > max) {
      const retryAfter = Math.ceil((entry.resetAt - now) / 1000);
      res.set('Retry-After', String(retryAfter));
      return res.status(429).json({ error: message || 'too many requests', retryAfter });
    }
    next();
  };
}

// 인증된 uid 우선, 없으면 IP로 버킷팅 (완화 모드/구버전 앱 대비)
const byUidOrIp = (req) => req.uid || req.ip || 'unknown';

// 라우트별 리미터 — 고비용 순으로 타이트하게
const vlogJobLimiter  = rateLimit({ windowMs: 10 * 60 * 1000, max: 15,  key: byUidOrIp, message: 'Vlog 생성 요청이 너무 많습니다. 잠시 후 다시 시도해주세요.' });
const uploadLimiter   = rateLimit({ windowMs: 60 * 1000,      max: 60,  key: byUidOrIp });
const pushLimiter     = rateLimit({ windowMs: 60 * 1000,      max: 30,  key: byUidOrIp });
const cacheWriteLimiter = rateLimit({ windowMs: 60 * 1000,    max: 120, key: byUidOrIp });
const translateLimiter  = rateLimit({ windowMs: 60 * 1000,    max: 60,  key: byUidOrIp });
// 전역 안전망 — 폴링(잡 상태 조회 등)을 감안해 넉넉하게, 순수 폭주만 차단
const globalApiLimiter = rateLimit({ windowMs: 60 * 1000, max: 600, key: byUidOrIp });
app.use('/api/', globalApiLimiter);
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

// 운영 모니터링 — nginx가 /api/만 WAS로 프록시하므로 외부에서 닿는 헬스체크는 이 경로.
// 디스크 여유·Vlog 대기열 상태를 함께 반환해 "터지기 전에" 보이게 한다.
app.get('/api/health', async (req, res) => {
  const out = { status: 'ok', server: 'tteona-api', time: new Date().toISOString() };
  try {
    out.diskFreeMB = await diskFreeMB(VLOG_DIR);
    if (out.diskFreeMB < 5120) out.status = 'warn';
  } catch { out.diskFreeMB = null; }
  try {
    const q = await pgPool.query(`
      SELECT
        COUNT(*) FILTER (WHERE status = 'pending')::int    AS pending,
        COUNT(*) FILTER (WHERE status = 'processing')::int AS processing,
        COALESCE(EXTRACT(EPOCH FROM NOW() - MIN(created_at) FILTER (WHERE status = 'pending')), 0)::int AS oldest_pending_sec
      FROM vlog_jobs`);
    out.vlog = {
      pending: q.rows[0].pending,
      processing: q.rows[0].processing,
      oldestPendingSec: q.rows[0].oldest_pending_sec,
    };
    if (out.vlog.pending >= 5 || out.vlog.oldestPendingSec > 1800) out.status = 'warn';
  } catch { out.vlog = null; }
  res.json(out);
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
app.post('/api/courses/:courseId/thumbnail', requireAuth, uploadLimiter, upload.single('image'), async (req, res) => {
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

    // 파일명이 courseId로 고정이라 재업로드 시 URL이 동일 → 정적 캐시(30d)에 옛 이미지가 남는다.
    // 아바타와 동일하게 버전 쿼리를 붙여 캐시 무효화 (fetchAllThumbnails 쓰는 탐색탭·프로필에 자동 전파)
    const url = `https://tteona.kr/uploads/thumbnails/${filename}?v=${Date.now()}`;
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
app.post('/api/users/:uid/avatar', requireAuth, uploadLimiter, upload.single('image'), async (req, res) => {
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

// ─── 방 대표 이미지 (WAS 로컬 저장 + Firestore rooms.imageUrl) ─────────────────

// 방 대표 이미지 업로드 — multipart/form-data, 필드명 "image" (방 멤버만 가능).
// 전 멤버 공통으로 보이는 이미지라 Firestore rooms 문서에 저장하며,
// 클라이언트의 rooms 스냅샷 리스너가 즉시 반영한다.
app.post('/api/rooms/:roomId/image', requireAuth, uploadLimiter, upload.single('image'), async (req, res) => {
  const { roomId } = req.params;
  if (!req.file) return res.status(400).json({ error: 'image file required' });

  try {
    const roomRef = db.collection('rooms').doc(roomId);
    const snap = await roomRef.get();
    if (!snap.exists) return res.status(404).json({ error: 'room not found' });
    const memberIds = snap.data().memberIds || [];
    if (req.uid && !memberIds.includes(req.uid)) {
      return res.status(403).json({ error: 'not a member of this room' });
    }

    const filename = `${roomId}.jpg`;
    const filepath = path.join(ROOM_IMG_DIR, filename);

    // 정사각형 크롭 + 최대 512px, JPEG 품질 82 (아바타와 동일 정책)
    await sharp(req.file.buffer)
      .rotate()
      .resize(512, 512, { fit: 'cover', position: 'centre' })
      .jpeg({ quality: 82 })
      .toFile(filepath);

    // 파일명이 roomId 고정이라 캐시 무효화용 버전 쿼리 추가
    const url = `https://tteona.kr/uploads/rooms/${filename}?v=${Date.now()}`;
    await roomRef.set({ imageUrl: url }, { merge: true });

    res.json({ ok: true, url });
  } catch (err) {
    console.error('[RoomImage] upload error:', err);
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

// 이번 주 인기 크리에이터 TOP 10 (좋아요 합계 → 코스 수 순, 2분 캐시)
// 캐시가 10분일 땐 탐색탭을 당겨 새로고침해도 순위·좋아요가 그대로라 "반영이 안 된다"는
// 인상을 줬다. Firestore 읽기 500건 × 시간당 30회 수준이라 2분으로 줄여도 비용은 미미하다.
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
       VALUES ($1, $2, NOW() + INTERVAL '2 minutes')
       ON CONFLICT (cache_key) DO UPDATE SET result = $2, expires_at = NOW() + INTERVAL '2 minutes'`,
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

// 앱이 로그인 시 device token 등록 — 본인 토큰만 등록 가능
// iOS는 APNs 토큰(platform 생략 = 'ios'), Android는 FCM 토큰(platform = 'android')
app.post('/api/push/register', requireAuth, pushLimiter, async (req, res) => {
  const { token } = req.body;
  const platform = req.body.platform === 'android' ? 'android' : 'ios';
  const lang = pushLang(String(req.body.lang || 'ko').toLowerCase());
  const userId = req.uid || req.body.userId; // 검증된 uid 우선 — 타인 토큰 탈취 방지
  if (!userId || !token) return res.status(400).json({ error: 'userId and token required' });

  try {
    // 토큰이 유니크 — 같은 기기를 다른 계정이 쓰면 소유자만 바뀐다(이전 계정 알림이 새 계정 기기로 가지 않도록).
    // 앱에서 언어를 바꾸면 같은 토큰으로 다시 등록되어 lang만 갱신된다.
    await pgPool.query(`
      INSERT INTO device_tokens (user_id, token, platform, lang, updated_at)
      VALUES ($1, $2, $3, $4, NOW())
      ON CONFLICT (token) DO UPDATE
        SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform,
            lang = EXCLUDED.lang, updated_at = NOW()
    `, [userId, token, platform, lang]);
    res.json({ ok: true });
  } catch (err) {
    console.error('push register error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// 로그아웃 시 이 기기의 토큰만 해제 — 본인 소유 행만 지운다.
app.post('/api/push/unregister', requireAuth, pushLimiter, async (req, res) => {
  const { token } = req.body;
  if (!token) return res.status(400).json({ error: 'token required' });

  try {
    await pgPool.query(
      'DELETE FROM device_tokens WHERE token = $1 AND user_id = $2',
      [token, req.uid]
    );
    res.json({ ok: true });
  } catch (err) {
    console.error('push unregister error:', err);
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
app.post('/api/push/course-liked', requireAuth, pushLimiter, async (req, res) => {
  const { courseOwnerId, likerNickname, courseName, courseId } = req.body;
  if (!courseOwnerId || !likerNickname) return res.status(400).json({ error: 'missing fields' });
  if (req.uid === courseOwnerId) return res.json({ skipped: true, reason: 'self' });

  const nickname = await nicknameOf(req.uid, likerNickname);
  const result = await sendPush({
    userId:  courseOwnerId,
    message: localized('courseLiked', { nickname, courseName }),
    // courseId가 있어야 알림을 탭했을 때 해당 코스 상세로 열 수 있다.
    data:    { type: 'course_liked', courseName, courseId: courseId || '' },
  });
  res.json(result);
});

// 코스 따라가기 알림 — 코스 작성자에게 발송
app.post('/api/push/course-followed', requireAuth, pushLimiter, async (req, res) => {
  const { courseOwnerId, followerNickname, courseName, courseId } = req.body;
  if (!courseOwnerId || !followerNickname) return res.status(400).json({ error: 'missing fields' });
  if (req.uid === courseOwnerId) return res.json({ skipped: true, reason: 'self' });

  const nickname = await nicknameOf(req.uid, followerNickname);
  const result = await sendPush({
    userId:  courseOwnerId,
    message: localized('courseFollowed', { nickname, courseName }),
    data:    { type: 'course_followed', courseName, courseId: courseId || '' },
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
      await sendPush({
        userId:  row.user_id,
        message: localized('weeklyReport', { courses: Number(row.courses), places: Number(row.places) }),
        data:    { type: 'weekly_report' },
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

app.post('/api/places/cache', requireAuth, cacheWriteLimiter, async (req, res) => {
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

// ─── 번역 프록시 (Google Cloud Translation v2, PostgreSQL 영구 캐시) ──────────
// 코스 제목·장소명 같은 UGC는 정적 번역이 불가능하다. 원문→대상언어 결과를 영구 캐시하므로
// 같은 제목의 두 번째 조회부터는 과금이 없다(제목은 사실상 불변).
// GOOGLE_TRANSLATE_KEY가 없으면 원문을 그대로 돌려준다 — 키 발급 전에도 앱은 정상 동작한다.

const GOOGLE_TRANSLATE_KEY = process.env.GOOGLE_TRANSLATE_KEY || '';
const TRANSLATE_TARGETS   = new Set(['en', 'ja', 'ko']);
const TRANSLATE_MAX_TEXTS = 50;   // 탐색탭 한 화면 분량 + 여유
const TRANSLATE_MAX_CHARS = 500;  // 코스 제목 길이 상한 — 번역 API 남용 방지

async function ensureTranslationSchema() {
  await pgPool.query(`
    CREATE TABLE IF NOT EXISTS translation_cache (
      source_hash     TEXT        NOT NULL,
      target_lang     TEXT        NOT NULL,
      source_text     TEXT        NOT NULL,
      translated_text TEXT        NOT NULL,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (source_hash, target_lang)
    )
  `);
}
ensureTranslationSchema().catch(err => console.error('[Translate] schema migration error:', err.message));

const textHash = (t) => createHash('sha256').update(t, 'utf8').digest('hex');

// Translation v2는 format:'text'로 요청해도 결과에 HTML 엔티티를 남긴다 ("김밥 & 라면" → "&amp;").
function decodeHtmlEntities(str) {
  return str.replace(/&(amp|lt|gt|quot|apos);|&#(\d+);|&#x([0-9a-fA-F]+);/g,
    (match, named, dec, hex) => {
      if (dec) return String.fromCodePoint(parseInt(dec, 10));
      if (hex) return String.fromCodePoint(parseInt(hex, 16));
      return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[named] ?? match;
    });
}

async function googleTranslate(texts, target) {
  const url = `https://translation.googleapis.com/language/translate/v2?key=${encodeURIComponent(GOOGLE_TRANSLATE_KEY)}`;
  const r = await fetch(url, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ q: texts, target, format: 'text' }),
  });
  if (!r.ok) {
    // 상태코드만으론 원인을 못 찾는다 — 실제로 403의 정체는 "API 키 IP 제한"이었고,
    // NAT 송신 IP가 두 개(.4/.5)라 그중 하나만 허용돼 요청의 절반이 조용히 실패했다.
    const detail = await r.json().catch(() => null);
    const reason = detail?.error?.message || '(본문 없음)';
    throw new Error(`Translation API ${r.status}: ${reason}`);
  }
  const out = (await r.json())?.data?.translations;
  if (!Array.isArray(out) || out.length !== texts.length) throw new Error('unexpected response shape');
  return out.map(t => decodeHtmlEntities(t.translatedText || ''));
}

app.post('/api/translate', requireAuth, translateLimiter, async (req, res) => {
  const target = String(req.body?.target || '').toLowerCase();
  const texts  = req.body?.texts;

  if (!TRANSLATE_TARGETS.has(target))  return res.status(400).json({ error: 'invalid target' });
  if (!Array.isArray(texts) || texts.length === 0) return res.status(400).json({ error: 'texts required' });
  if (texts.length > TRANSLATE_MAX_TEXTS) return res.status(400).json({ error: 'too many texts' });
  if (!texts.every(t => typeof t === 'string' && t.length <= TRANSLATE_MAX_CHARS)) {
    return res.status(400).json({ error: 'invalid text' });
  }

  if (!GOOGLE_TRANSLATE_KEY) return res.json({ translations: texts, translated: false });

  try {
    // 같은 제목이 여러 번 들어와도 조회·번역은 1회만
    const unique = [...new Set(texts.filter(t => t.trim()))];
    const bySource = new Map(); // 원문 → 번역문

    if (unique.length > 0) {
      const cached = await pgPool.query(
        `SELECT source_text, translated_text FROM translation_cache
          WHERE target_lang = $1 AND source_hash = ANY($2::text[])`,
        [target, unique.map(textHash)]
      );
      for (const row of cached.rows) bySource.set(row.source_text, row.translated_text);

      const missing = unique.filter(t => !bySource.has(t));
      if (missing.length > 0) {
        const fresh = await googleTranslate(missing, target);
        // 빈 번역문은 캐시하지 않는다 — 영구 캐시라 한 번 들어가면 제목이 계속 빈칸으로 보인다.
        const fetched = missing
          .map((t, i) => [t, fresh[i]])
          .filter(([, translated]) => translated.trim().length > 0);
        for (const [t, translated] of fetched) bySource.set(t, translated);

        // 캐시 적재 실패는 응답을 막지 않는다 — 다음 요청에서 다시 시도된다.
        if (fetched.length > 0) {
          try {
            const params = [];
            const rows = fetched.map(([t, translated], i) => {
              params.push(textHash(t), target, t, translated);
              return `($${i * 4 + 1}, $${i * 4 + 2}, $${i * 4 + 3}, $${i * 4 + 4})`;
            });
            await pgPool.query(
              `INSERT INTO translation_cache (source_hash, target_lang, source_text, translated_text)
               VALUES ${rows.join(', ')}
               ON CONFLICT (source_hash, target_lang) DO NOTHING`,
              params
            );
          } catch (err) {
            console.error('[Translate] cache write error:', err.message);
          }
        }
      }
    }

    res.json({ translations: texts.map(t => bySource.get(t) ?? t), translated: true });
  } catch (err) {
    // 번역 실패 시 원문 반환 — 화면이 비는 것보다 한국어라도 보이는 편이 낫다.
    console.error('[Translate] error:', err.message);
    res.json({ translations: texts, translated: false });
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

// 유저가 고를 수 있는 자막 서체 — 키는 앱과 공유(job options.font). 파일 없으면 기본(고운바탕) 폴백.
const VLOG_FONT_FILES = {
  gowun:        'GowunBatang-Regular.ttf',
  pretendard:   'Pretendard-Bold.otf',
  nanumpen:     'NanumPenScript-Regular.ttf',
  jua:          'Jua-Regular.ttf',
  blackhansans: 'BlackHanSans-Regular.ttf',
  kkubulim:     'BMKkubulimTTF.ttf',
  gooltokki:    'HSGooltokki.ttf',
};
function resolveVlogFont(key) {
  const file = VLOG_FONT_FILES[key];
  if (file) {
    const p = path.join(__dirname, 'assets', 'fonts', file);
    if (fs.existsSync(p)) return p;
  }
  return VLOG_FONT;
}
// 자막 크기 배율 — 앱과 공유(job options.fontScale). 기본(medium)은 기존 동작과 동일.
const VLOG_FONT_SCALE = { small: 1.0, medium: 1.28, large: 1.64 };

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
app.post('/api/vlog/jobs', requireAuth, vlogJobLimiter, async (req, res) => {
  const { courseId, courseName, tag, formats, bgm, places, watermark, priority, shareRoomIds, font, fontScale } = req.body || {};
  const userId = req.uid || req.body?.userId; // 검증된 uid 우선
  if (!userId || !Array.isArray(places) || places.length === 0) {
    return res.status(400).json({ error: 'userId and places required' });
  }
  try {
    // 디스크 가드 — 공간이 없으면 업로드·합성이 중간에 깨져 더 나쁜 실패가 된다.
    // 503으로 정직하게 거절하면 클라이언트는 재시도 후 로컬 폴백으로라도 결과를 보장한다.
    const free = await diskFreeMB(VLOG_DIR).catch(() => -1);
    if (free >= 0 && free < 2048) {
      console.error(`[Vlog] ⚠️ 디스크 여유 ${free}MB — 잡 생성 거절`);
      return res.status(503).json({ error: '서버 저장 공간이 부족합니다. 잠시 후 다시 시도해주세요.' });
    }
    const wanted = Array.isArray(formats)
      ? formats.filter(f => ['reels', 'youtube', 'insta'].includes(f)) : [];
    // 완성 시 자동 공유할 방 — 세션 시작 때 고른 방들. 토큰은 방 멤버의 무인증 재생용
    // (jobId가 순번이라 URL 추측이 가능하므로, 토큰 없인 소유자 외 접근 불가 원칙 유지)
    const shareRooms = Array.isArray(shareRoomIds)
      ? [...new Set(shareRoomIds.filter(r => typeof r === 'string' && r.length > 0 && r.length <= 64))].slice(0, 10)
      : [];
    const r = await pgPool.query(
      `INSERT INTO vlog_jobs (user_id, course_id, course_name, status, clips, options)
       VALUES ($1, $2, $3, 'uploading', $4, $5) RETURNING id`,
      [userId, courseId || 'free', courseName || '나의 오늘',
       JSON.stringify(places),
       JSON.stringify({ tag: tag || null, formats: wanted,
                        bgm: typeof bgm === 'string' ? bgm.slice(0, 200) : null,
                        watermark: watermark !== false,
                        priority: priority === true,
                        // 자막 서체·크기 — 미지정/미지원 값은 렌더 시 기본(고운바탕·medium)으로 폴백
                        font: VLOG_FONT_FILES[font] ? font : null,
                        fontScale: VLOG_FONT_SCALE[fontScale] ? fontScale : null,
                        shareRoomIds: shareRooms,
                        shareToken: shareRooms.length > 0 ? randomBytes(16).toString('hex') : null })]
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
app.post('/api/vlog/jobs/:jobId/clips', requireAuth, uploadLimiter, requireJobOwner, vlogUpload.single('clip'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'clip file required' });
  // 무결성 검증 — 전송 중 잘린 파일이 그대로 합성에 들어가면 잡 전체가 이상한 결과물로
  // 완성돼 버린다(실패보다 나쁨). 저장 직후 ffprobe로 실제 재생 가능한 영상인지 확인하고,
  // 깨졌으면 지우고 400 → 클라이언트 재시도(retrying)가 온전한 파일로 다시 올린다.
  try {
    await probeVideo(req.file.path);
  } catch {
    try { fs.unlinkSync(req.file.path); } catch {}
    console.warn(`[Vlog] job ${req.params.jobId} 클립 ${req.query.order} 손상 업로드 거절`);
    return res.status(400).json({ error: 'corrupt clip — retry upload' });
  }
  // size는 클라이언트가 로컬 원본과 대조해 바이트 단위 완전성까지 확인하는 용도
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

// 디스크 여유 공간(MB) — fs.statfs는 Node 버전을 타므로 POSIX df로 확인
function diskFreeMB(dir) {
  return new Promise((resolve, reject) => {
    const p = spawn('df', ['-Pk', dir]);
    let out = '';
    p.stdout.on('data', d => out += d);
    p.on('close', code => {
      if (code !== 0) return reject(new Error('df failed'));
      const cols = out.trim().split('\n').pop().split(/\s+/);
      const availKB = parseInt(cols[3], 10);
      if (isNaN(availKB)) return reject(new Error('df parse failed'));
      resolve(Math.floor(availKB / 1024));
    });
  });
}

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

// 동시 실행 제한 map — 클립 인코딩을 여러 코어에서 병렬 처리해 합성 시간을 단축한다.
async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, worker));
  return results;
}
// 클립 인코딩 동시 개수 — 8코어 서버에서 ffmpeg들이 파이프라인 갭(spawn·필터 초기화·I/O)을
// 서로 메우며 순차 대비 크게 빨라진다. 과도한 오버서브스크립션은 피해 3으로 고정.
const CLIP_CONCURRENCY = 3;

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
  // 유저가 고른 자막 서체·크기 (미지정이면 기본 고운바탕·medium)
  const subFont = resolveVlogFont(opts.font);
  const fontScale = VLOG_FONT_SCALE[opts.fontScale] || 1.0;
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
    const clipSegs = await mapLimit(clips, CLIP_CONCURRENCY, async (c, i) => {
      const info = c.info;
      const segOut = path.join(fmtDir, `seg_${String(i + 1).padStart(3, '0')}.mp4`);
      const subTxt = writeTextFile(workDir, `sub_${i}.txt`, c.placeName || '');
      const isLast = i === clips.length - 1;
      const D = Math.max(info.duration, 0.8);

      // 자막 표시: 클립 시작 후 최대 2.5초, 페이드 인/아웃 0.4초 (알파 커브)
      const show = Math.min(2.5, D).toFixed(2);
      const fadeOutStart = Math.max(0.4, Math.min(2.5, D) - 0.4).toFixed(2);
      const alpha = `'if(lt(t,0.4),t/0.4,if(lt(t,${fadeOutStart}),1,if(lt(t,${show}),(${show}-t)/0.4,0)))'`;
      const placeSize = Math.round(Math.min(W, H) * 0.042 * fontScale);
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
        // 장소명 — 오렌지(#FF6B35), 화면 세로 중앙 바로 위 (유저 선택 서체)
        `drawtext=fontfile=${subFont}:textfile=${subTxt}:fontcolor=0xFF6B35:fontsize=${placeSize}:x=(w-text_w)/2:y=(h/2)-${Math.round(placeSize * 1.3)}:${shadow}:alpha=${alpha}`,
      ];
      // 촬영 시각 — 흰색, 장소명 아래 (iOS가 shotAt 전달 시)
      if (c.shotAt) {
        const dateTxt = writeTextFile(workDir, `date_${i}.txt`, String(c.shotAt));
        overlays.push(`drawtext=fontfile=${subFont}:textfile=${dateTxt}:fontcolor=white:fontsize=${dateSize2}:x=(w-text_w)/2:y=(h/2)+${Math.round(dateSize2 * 0.3)}:${shadow}:alpha=${alpha}`);
      }
      const fades = ['fade=t=in:st=0:d=0.4'];
      if (!isLast) fades.push(`fade=t=out:st=${Math.max(0, D - 0.4).toFixed(2)}:d=0.4`);

      let af = 'afade=t=in:st=0:d=0.4';
      if (!isLast) af += `,afade=t=out:st=${Math.max(0, D - 0.4).toFixed(2)}:d=0.4`;

      const args = ['-i', c.file];
      if (!info.hasAudio) {
        // 무음 클립(마이크 권한 거부 등)에 무음 트랙을 붙인다. 길이는 '-t'(입력 옵션)로
        // 클립과 똑같이 잘라 둔다 — 예전엔 '-shortest'를 여기 뒀는데, 뒤에 워터마크 '-i'가
        // 오면 ffmpeg가 이를 그 입력의 옵션으로 해석해("cannot be applied to input file")
        // 잡 전체가 exit 234로 실패했다. 무한 길이인 anullsrc를 입력 단계에서 끊는 편이 안전하다.
        args.push('-f', 'lavfi', '-t', Math.max(info.duration, 0.1).toFixed(3),
                  '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100');
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
      await tick();
      return segOut;
    });
    segments.push(...clipSegs);

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
      // 원음(apad)을 영상 전체 길이로 패딩해 amix=first의 기준 길이를 영상 길이로 고정한다.
      // 그렇지 않으면 클립 오디오가 영상보다 조금 짧을 때(흔함) amix가 먼저 끝나
      // 영상 끝부분에 BGM이 빠지는 문제가 간헐적으로 발생한다.
      await runFF([
        '-i', rawFile, '-stream_loop', '-1', '-i', bgm,
        '-filter_complex',
        `[0:a]apad=whole_dur=${total.toFixed(3)}[va];[1:a]volume=0.30[bg];[va][bg]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[mx];[mx]afade=t=out:st=${fadeStart}:d=1.5[a]`,
        '-map', '0:v', '-map', '[a]',
        '-t', total.toFixed(3),
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

// 재시작 복구 — 합성 도중 프로세스가 죽으면(배포 pm2 restart 포함) 잡이 processing에
// 영구 고착되고 유저는 "이어받기"를 눌러도 영원히 완성을 못 받는다. 워커가 이 프로세스
// 하나뿐이므로 부팅 시점의 processing은 전부 중단된 잡 → pending으로 되돌려 재합성한다.
pgPool.query(`UPDATE vlog_jobs SET status = 'pending', progress = 0 WHERE status = 'processing'`)
  .then(r => { if (r.rowCount > 0) console.log(`[Vlog] 재시작 복구: 중단된 잡 ${r.rowCount}건 → pending 재투입`); })
  .catch(err => console.error('[Vlog] 재시작 복구 실패:', err.message));

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
  // 대기열이 쌓이면 유저 체감 대기시간이 렌더링 시간의 배수로 늘어난다 — 임계 전에 로그로 감지
  try {
    const q = await pgPool.query(`SELECT COUNT(*)::int AS n FROM vlog_jobs WHERE status = 'pending'`);
    if (q.rows[0].n >= 3) console.warn(`[Vlog] ⚠️ 대기열 ${q.rows[0].n}건 — 동시 1워커 한계 접근 중`);
  } catch {}
  console.log(`[Vlog] job ${job.id} 합성 시작 (user=${job.user_id})`);
  try {
    const url = await composeVlog(job);
    await pgPool.query(
      `UPDATE vlog_jobs SET status = 'completed', progress = 100, output_url = $2, completed_at = NOW() WHERE id = $1`,
      [job.id, url]
    );
    console.log(`[Vlog] job ${job.id} 완성 → ${url}`);
    sendPush({
      userId:  job.user_id,
      message: localized('vlogDone', { courseName: job.course_name }),
      // url이 있어야 알림을 탭했을 때 완성본을 바로 재생할 수 있다.
      data:    { type: 'vlog_done', jobId: String(job.id), url },
    }).catch(() => {});
    // 세션 시작 때 고른 채팅방에 완성본 자동 공유 (부가 기능 — 실패해도 완성엔 무관)
    shareVlogToRooms(job, url).catch(e => console.error(`[VlogShare] job ${job.id} error:`, e.message));
  } catch (err) {
    console.error(`[Vlog] job ${job.id} 실패:`, err.message);
    // 일시 오류(디스크 순간 부족·프로세스 신호 등)로 유저가 곧장 열화본(로컬 폴백)을
    // 받는 일이 없도록 한 번은 자동 재시도한다. 입력 자체가 없는 잡은 재시도 무의미.
    const opts = typeof job.options === 'object' && job.options !== null
      ? job.options : (() => { try { return JSON.parse(job.options || '{}'); } catch { return {}; } })();
    const retriable = (opts.retryCount | 0) < 1 && !String(err.message).includes('클립이 없습니다');
    if (retriable) {
      console.log(`[Vlog] job ${job.id} 자동 재시도 1회 예약`);
      await pgPool.query(
        `UPDATE vlog_jobs SET status = 'pending', progress = 0, options = options || '{"retryCount":1}' WHERE id = $1`,
        [job.id]
      ).catch(() => {});
    } else {
      await pgPool.query(
        `UPDATE vlog_jobs SET status = 'failed', error_msg = $2 WHERE id = $1`,
        [job.id, String(err.message).slice(0, 500)]
      ).catch(() => {});
    }
  } finally {
    vlogBusy = false;
  }
}, 5000);

// ── Vlog 디스크 정리: 부팅 30초 후 + 6시간마다 ──
// 원본 클립·완성본이 영구 누적되면 50GB 디스크가 차는 순간 모든 유저의 합성이 실패한다.
// 보존 정책: 완성 7일(유저는 완성 직후 다운로드 — 서버 보관은 재다운로드 여유분),
//           실패 3일(에러 조사 여유), 시작 안 된 잡(uploading) 24시간(클라 이어받기 TTL과 동일),
//           스모크 테스트 잡 1시간. 파일만 지우고 DB 행은 남긴다(통계·에러 추적) — 스모크 행만 삭제.
async function cleanupVlogs() {
  try {
    const r = await pgPool.query(`
      SELECT id, status, user_id FROM vlog_jobs WHERE
        (status = 'completed' AND completed_at < NOW() - INTERVAL '7 days')
        OR (status = 'failed' AND created_at < NOW() - INTERVAL '3 days')
        OR (status = 'uploading' AND created_at < NOW() - INTERVAL '24 hours')
        OR (user_id = 'deploy-smoke' AND created_at < NOW() - INTERVAL '1 hour')`);
    let removed = 0;
    for (const row of r.rows) {
      const dir = path.join(VLOG_DIR, String(row.id));
      if (fs.existsSync(dir)) {
        try { fs.rmSync(dir, { recursive: true, force: true }); removed++; } catch {}
      }
      if (row.user_id === 'deploy-smoke') {
        await pgPool.query(`DELETE FROM vlog_jobs WHERE id = $1`, [row.id]).catch(() => {});
      } else if (row.status === 'uploading') {
        // 만료 처리 — 워커가 집어가거나 클라가 이어받는 일이 없도록 상태를 확정한다
        await pgPool.query(
          `UPDATE vlog_jobs SET status = 'failed', error_msg = '만료: 24시간 내 시작되지 않음' WHERE id = $1`,
          [row.id]
        ).catch(() => {});
      }
    }
    const free = await diskFreeMB(VLOG_DIR).catch(() => -1);
    if (removed > 0 || (free >= 0 && free < 5120)) {
      console.log(`[Vlog] 정리: 잡 폴더 ${removed}개 삭제, 디스크 여유 ${free >= 0 ? free + 'MB' : '측정 실패'}`);
    }
    if (free >= 0 && free < 5120) console.warn(`[Vlog] ⚠️ 디스크 여유 ${free}MB — 5GB 미만, 정리 정책 점검 필요`);
  } catch (err) {
    console.error('[Vlog] 정리 크론 실패:', err.message);
  }
}
setTimeout(cleanupVlogs, 30 * 1000);
setInterval(cleanupVlogs, 6 * 60 * 60 * 1000);

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
      await pgPool.query('DELETE FROM room_reads WHERE room_id = $1', [roomId]).catch(() => {});
      return res.json({ ok: true, deleted: true });
    }

    await ref.update({ memberIds: FieldValue.arrayRemove(uid) });
    await ref.collection('members').doc(uid).delete().catch(() => {});
    await ref.collection('locations').doc(uid).delete().catch(() => {});
    await pgPool.query('DELETE FROM room_reads WHERE room_id = $1 AND user_id = $2', [roomId, uid]).catch(() => {});
    roomInfoCache.delete(roomId);
    res.json({ ok: true, deleted: false });
  } catch (err) {
    console.error('[Rooms] leave error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ─── 안읽음 방 계산 (서버 집계) ───────────────────────────────────────────────
// 클라이언트가 방×멤버 수만큼 Firestore를 팬아웃하던 것을 서버 1회 호출로 대체한다.
// 각 방의 최신 피드 시각과 내 lastReadAt을 비교해 안읽음 방 roomId 집합을 돌려준다.
app.get('/api/rooms/unread', requireAuth, async (req, res) => {
  const uid = req.uid;
  if (!uid) return res.status(401).json({ error: 'auth required' });
  try {
    const roomsSnap = await db.collection('rooms')
      .where('memberIds', 'array-contains', uid).get();

    const unread = [];
    await Promise.all(roomsSnap.docs.map(async (roomDoc) => {
      try {
        // 방 전체에서 가장 최신 피드 1개 (createdAt desc)
        const latestSnap = await roomDoc.ref.collection('feed')
          .orderBy('createdAt', 'desc').limit(1).get();
        if (latestSnap.empty) return;
        const latest = latestSnap.docs[0].data().createdAt; // Firestore Timestamp
        if (!latest || typeof latest.toMillis !== 'function') return;

        const memberDoc = await roomDoc.ref.collection('members').doc(uid).get();
        const lastReadAt = memberDoc.data()?.lastReadAt;

        if (!lastReadAt || typeof lastReadAt.toMillis !== 'function') {
          unread.push(roomDoc.id); // 읽은 기록이 없는데 피드가 있으면 안읽음
        } else if (latest.toMillis() > lastReadAt.toMillis()) {
          unread.push(roomDoc.id);
        }
      } catch { /* 개별 방 실패는 무시하고 나머지 계속 */ }
    }));

    res.json({ unreadRoomIds: unread });
  } catch (err) {
    console.error('[Rooms] unread error:', err);
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
    await pgPool.query('DELETE FROM room_reads WHERE user_id = $1', [uid]).catch(() => {});
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
      `SELECT id, message_id, user_id, nickname, text, reply_to_nickname, reply_to_text, created_at,
              kind, attachment_url, thumb_url
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

    // 멤버별 읽음 커서 — 클라이언트가 메시지별 안읽음 수를 계산하는 데 쓴다
    const reads = await pgPool.query(
      'SELECT user_id, last_read_at FROM room_reads WHERE room_id = $1', [roomId]
    );
    res.json({ messages: rows, reads: reads.rows });
  } catch (err) {
    console.error('[RoomMessages] error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── 공개 탐색 API — 미니 웹앱 tteona.kr/explore 전용 ─────────────────────────
// 앱 미설치 방문자(카톡 공유 유입·안드로이드)가 로그인 없이 코스를 열람하는 경로.
// 응답은 화이트리스트 필드만 노출하고, 5분 인메모리 캐시로 Firestore 읽기를 억제.
// 코스 상세는 기존 공개 페이지 /course/{id}가 담당하므로 목록만 제공한다.
const publicExploreLimiter = rateLimit({ windowMs: 60 * 1000, max: 60, key: (req) => req.ip || 'unknown' });
const exploreCache = new Map(); // cacheKey → { data, expiresAt }

app.get('/api/public/explore', publicExploreLimiter, async (req, res) => {
  const sort = ['recommend', 'latest', 'popular'].includes(req.query.sort) ? req.query.sort : 'recommend';
  const limit = Math.max(1, Math.min(60, parseInt(req.query.limit) || 48));
  const lat = parseFloat(req.query.lat);
  const lng = parseFloat(req.query.lng);
  // 좌표는 소수 1자리(≈11km)로 반올림해 캐시 키 폭발 방지 — 추천 근접 점수엔 충분한 해상도
  const latR = isNaN(lat) ? 'x' : (Math.round(lat * 10) / 10).toFixed(1);
  const lngR = isNaN(lng) ? 'x' : (Math.round(lng * 10) / 10).toFixed(1);
  const cacheKey = `${sort}:${latR}:${lngR}:${limit}`;

  const hit = exploreCache.get(cacheKey);
  if (hit && Date.now() < hit.expiresAt) return res.json(hit.data);

  try {
    const [coursesSnap, thumbRows] = await Promise.all([
      db.collection('courses').limit(500).get(),
      pgPool.query('SELECT course_id, url FROM course_thumbnails'),
    ]);
    const thumbs = {};
    thumbRows.rows.forEach(r => { thumbs[r.course_id] = r.url; });

    const now = Date.now();
    const season = currentSeason();

    const courses = coursesSnap.docs.map(d => {
      const c = { ...d.data(), courseId: d.id };
      const createdMs = c.createdAt?._seconds ? c.createdAt._seconds * 1000 : 0;

      // 추천 점수 — /api/courses/recommend와 동일 가중치(인기40 + 신선25 + 근접25 + 시즌18)
      let score = Math.min((c.likeCount || 0) * 4, 40);
      const ageDays = (now - (createdMs || now)) / 86400000;
      score += Math.max(0, 25 - ageDays * 0.5);
      const mp = mainPlaceOf(c);
      if (!isNaN(lat) && !isNaN(lng) && mp && mp.latitude && mp.longitude) {
        const dist = haversineKm(lat, lng, mp.latitude, mp.longitude);
        if (dist < 10)       score += 25;
        else if (dist < 50)  score += 15;
        else if (dist < 200) score += 5;
      }
      const haystack = (c.courseName || '') + ' ' + (c.places || []).map(p => p.placeName || '').join(' ');
      if (season.words.some(w => haystack.includes(w))) score += 18;

      // 표시용 장소명 — 연속 중복(같은 곳 여러 클립) 접기, iOS displayPlaces와 동일 규칙
      const names = [];
      const sorted = [...(c.places || [])].sort((a, b) => (a.order || 0) - (b.order || 0));
      for (const p of sorted) {
        if (p.placeName && p.placeName !== names[names.length - 1]) names.push(p.placeName);
      }

      return {
        courseId: c.courseId,
        courseName: c.courseName || '떠나 코스',
        region: c.region || '',
        tag: c.tag || '',
        likeCount: c.likeCount || 0,
        placeCount: names.length,
        placeNames: names.slice(0, 3),
        thumbnailUrl: thumbs[c.courseId] || null,
        createdAt: createdMs,
        _score: score,
      };
    });

    if (sort === 'latest')       courses.sort((a, b) => b.createdAt - a.createdAt);
    else if (sort === 'popular') courses.sort((a, b) => (b.likeCount - a.likeCount) || (b.createdAt - a.createdAt));
    else                         courses.sort((a, b) => b._score - a._score);

    const data = {
      season: season.name,
      courses: courses.slice(0, limit).map(({ _score, ...rest }) => rest),
    };
    exploreCache.set(cacheKey, { data, expiresAt: now + 5 * 60 * 1000 });
    if (exploreCache.size > 200) {
      for (const [k, v] of exploreCache) if (Date.now() >= v.expiresAt) exploreCache.delete(k);
    }
    res.json(data);
  } catch (err) {
    console.error('[PublicExplore] error:', err);
    res.status(500).json({ error: 'explore failed' });
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

// ADMIN_PASSWORD 는 파일 상단에서 환경변수 필수로 로드됨.
// 세션: 로그인마다 무작위 토큰 발급, 24시간 만료. 서버 재시작 시 전원 로그아웃(재로그인으로 충분).
// 토큰 전달: 브라우저는 httpOnly 쿠키(admin_session)로만 받아 JS가 못 읽는다(XSS로 탈취 불가).
//           curl/배포 스크립트는 Authorization: Bearer 헤더도 계속 허용한다.
const ADMIN_SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const adminSessions = new Map(); // token → expiresAt
const ADMIN_COOKIE = 'admin_session';
// path를 /api/admin으로 좁히고 SameSite=Strict로 CSRF를 차단, HTTPS 전용(secure).
const ADMIN_COOKIE_OPTS = { httpOnly: true, secure: true, sameSite: 'strict', path: '/api/admin' };

// req.headers.cookie 수동 파싱 (cookie-parser 의존성 없이). 값은 URL 디코드.
function parseCookies(req) {
  const out = {};
  const raw = req.headers.cookie;
  if (!raw) return out;
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    if (!k || (k in out)) continue;
    try { out[k] = decodeURIComponent(part.slice(i + 1).trim()); }
    catch { out[k] = part.slice(i + 1).trim(); }
  }
  return out;
}

// 토큰 소스: Authorization 헤더 우선(스크립트), 없으면 httpOnly 쿠키(브라우저)
function adminTokenFrom(req) {
  const auth = req.headers['authorization'] || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7);
  return parseCookies(req)[ADMIN_COOKIE] || '';
}

function adminAuth(req, res, next) {
  const token = adminTokenFrom(req);
  const expiresAt = token ? adminSessions.get(token) : undefined;
  if (expiresAt && Date.now() < expiresAt) return next();
  if (expiresAt) adminSessions.delete(token);
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
  const pwBuf = Buffer.from(String(password ?? ''));
  const answerBuf = Buffer.from(ADMIN_PASSWORD);
  if (pwBuf.length === answerBuf.length && timingSafeEqual(pwBuf, answerBuf)) {
    adminLoginAttempts.delete(ip);
    const token = randomBytes(32).toString('hex');
    adminSessions.set(token, now + ADMIN_SESSION_TTL_MS);
    // 브라우저용: httpOnly 쿠키. 응답 body의 token은 curl/배포 스크립트 전용(브라우저 JS는 무시).
    res.cookie(ADMIN_COOKIE, token, { ...ADMIN_COOKIE_OPTS, maxAge: ADMIN_SESSION_TTL_MS });
    return res.json({ ok: true, token });
  }
  if (!entry || now >= entry.resetAt) {
    adminLoginAttempts.set(ip, { count: 1, resetAt: now + 15 * 60 * 1000 });
  } else {
    entry.count += 1;
  }
  res.status(401).json({ error: '비밀번호가 틀렸습니다' });
});

// 로그아웃 — 서버 측 세션 즉시 무효화 + 쿠키 제거
app.post('/api/admin/logout', (req, res) => {
  const token = adminTokenFrom(req);
  if (token) adminSessions.delete(token);
  res.clearCookie(ADMIN_COOKIE, ADMIN_COOKIE_OPTS);
  res.json({ ok: true });
});

// 세션 확인 — 프론트가 페이지 로드 시 로그인 상태를 판별한다(쿠키는 JS가 못 읽으므로).
app.get('/api/admin/session', adminAuth, (req, res) => res.json({ ok: true }));

// 만료 엔트리 주기 청소 — adminSessions·adminLoginAttempts 무한 성장 방지
setInterval(() => {
  const now = Date.now();
  for (const [token, expiresAt] of adminSessions) {
    if (now >= expiresAt) adminSessions.delete(token);
  }
  for (const [ip, entry] of adminLoginAttempts) {
    if (now >= entry.resetAt) adminLoginAttempts.delete(ip);
  }
}, 15 * 60 * 1000).unref();

app.get('/api/admin/stats', adminAuth, async (req, res) => {
  try {
    const weekAgo = Timestamp.fromMillis(Date.now() - 7 * 86400000);
    const [usersSnap, newUsersSnap, coursesSnap, reportsSnap, pgStats, activeStats, cacheStats, vlogQueue, diskFree] = await Promise.all([
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
      pgPool.query(`
        SELECT COUNT(*) FILTER (WHERE status = 'pending')::int    AS pending,
               COUNT(*) FILTER (WHERE status = 'processing')::int AS processing
        FROM vlog_jobs
      `),
      diskFreeMB(VLOG_DIR).catch(() => null),
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
      // 시스템 상태 — 시스템 탭에서 표시
      system: {
        uptimeSec:      Math.floor(process.uptime()),
        memoryRssMB:    Math.round(process.memoryUsage().rss / 1048576),
        diskFreeMB:     diskFree,
        vlogPending:    vlogQueue.rows[0].pending,
        vlogProcessing: vlogQueue.rows[0].processing,
        adminSessions:  adminSessions.size,
      },
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

    // email은 공개 users 문서에서 제거됐으므로(PII), 표시·검색용으로 Auth에서 보강한다.
    if (users.length > 0) {
      const authRes = await getAuth().getUsers(users.map(u => ({ uid: u.uid }))).catch(() => ({ users: [] }));
      const emailByUid = {};
      (authRes.users || []).forEach(u => { emailByUid[u.uid] = u.email || ''; });
      users.forEach(u => { u.email = emailByUid[u.uid] || u.email || ''; });
    }

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

// ─── [일회성] 기존 users 문서의 email 필드 일괄 삭제 (PII 정리) ─────────────────
// 앱은 더 이상 email을 users에 쓰지 않지만, 과거 문서엔 남아 있어 아무 로그인 유저나
// 읽을 수 있었다. 관리자 인증으로 한 번 실행해 전량 정리한다.
app.post('/api/admin/migrate/purge-emails', adminAuth, async (req, res) => {
  try {
    let purged = 0, scanned = 0, last = null;
    for (;;) {
      let q = db.collection('users').orderBy('__name__').limit(300);
      if (last) q = q.startAfter(last);
      const snap = await q.get();
      if (snap.empty) break;
      const batch = db.batch();
      let n = 0;
      for (const doc of snap.docs) {
        scanned++;
        if (doc.data().email !== undefined) { batch.update(doc.ref, { email: FieldValue.delete() }); n++; }
      }
      if (n > 0) { await batch.commit(); purged += n; }
      last = snap.docs[snap.docs.length - 1];
      if (snap.size < 300) break;
    }
    res.json({ ok: true, scanned, purged });
  } catch (err) {
    console.error('[Migrate purge-emails] error:', err);
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

// 인증마크 부여/해제 — body: { verified: bool, label?: string }
// Firebase 콘솔에서 users 문서를 직접 고치던 작업을 대시보드로 옮긴 것.
// label은 뱃지 옆에 붙는 크리에이터 표기("developer", "여행작가" 등), 비우면 제거된다.
app.post('/api/admin/users/:uid/verify', adminAuth, async (req, res) => {
  const { verified, label } = req.body || {};
  if (typeof verified !== 'boolean') {
    return res.status(400).json({ error: 'verified(boolean) required' });
  }
  try {
    const ref = db.collection('users').doc(req.params.uid);
    if (!(await ref.get()).exists) return res.status(404).json({ error: 'user not found' });

    const trimmed = typeof label === 'string' ? label.trim().slice(0, 30) : '';
    await ref.update({
      isVerified: verified,
      // 인증 해제 시 라벨도 함께 지운다 — 뱃지 없이 라벨만 남는 상태를 만들지 않는다
      creatorLabel: verified && trimmed ? trimmed : FieldValue.delete(),
    });
    console.log(`[Admin] verify ${req.params.uid} → ${verified}${trimmed ? ` (${trimmed})` : ''}`);
    res.json({ ok: true, isVerified: verified, creatorLabel: verified ? trimmed : null });
  } catch (err) {
    console.error('admin verify error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ─── Admin Analytics ──────────────────────────────────────────────────────────
// 대시보드 상세 지표. users/courses 전수 스캔은 select()로 필요한 필드만 받고
// 5분 메모리 캐시를 둔다 — 대시보드 자동 새로고침이 Firestore 읽기 비용을 키우지 않도록.

const analyticsCache = new Map(); // key → { at, data }
async function cachedAnalytics(key, ttlMs, loader) {
  const hit = analyticsCache.get(key);
  if (hit && Date.now() - hit.at < ttlMs) return hit.data;
  const data = await loader();
  analyticsCache.set(key, { at: Date.now(), data });
  return data;
}

// KST 기준 YYYY-MM-DD (서버 TZ와 무관하게 고정)
function kstDateKey(d) {
  return new Date(d.getTime() + 9 * 3600000).toISOString().slice(0, 10);
}

function scanAllUsers() {
  return cachedAnalytics('users-scan', 5 * 60 * 1000, async () => {
    const snap = await db.collection('users')
      .select('createdAt', 'isBlocked', 'isVerified').get();
    return snap.docs.map(d => {
      const x = d.data();
      return {
        createdAt:  x.createdAt?.toDate?.() || null,
        isBlocked:  x.isBlocked === true,
        isVerified: x.isVerified === true,
      };
    });
  });
}

// 언어 분포 — 기기 언어는 userPrivate.lang에 저장된다(FCM 토큰 등록 시).
// 푸시 미등록 유저는 잡히지 않으므로 'unknown'으로 집계된다.
function scanUserLangs() {
  return cachedAnalytics('user-langs-scan', 5 * 60 * 1000, async () => {
    const snap = await db.collection('userPrivate').select('lang').get();
    const dist = new Map();
    snap.docs.forEach(d => {
      const lang = typeof d.data().lang === 'string' ? d.data().lang.slice(0, 8) : null;
      if (lang) dist.set(lang, (dist.get(lang) || 0) + 1);
    });
    return dist;
  });
}

function scanAllCourses() {
  return cachedAnalytics('courses-scan', 5 * 60 * 1000, async () => {
    const snap = await db.collection('courses')
      .select('courseName', 'tag', 'region', 'likeCount', 'authorId', 'createdAt').get();
    return snap.docs.map(d => {
      const x = d.data();
      return {
        id:         d.id,
        courseName: x.courseName || '',
        tag:        typeof x.tag === 'string' ? x.tag : '기타',
        region:     typeof x.region === 'string' && x.region ? x.region : '미상',
        likeCount:  Number(x.likeCount) || 0,
        authorId:   x.authorId || '',
        createdAt:  x.createdAt?.toDate?.() || null,
      };
    });
  });
}

// TOP 유저·인기 코스에 닉네임을 붙인다 (uid → nickname, 실패는 빈 문자열)
async function nicknamesByUid(uids) {
  const unique = [...new Set(uids.filter(Boolean))];
  if (!unique.length) return {};
  const refs = unique.map(uid => db.collection('users').doc(uid));
  const docs = await db.getAll(...refs, { fieldMask: ['nickname'] }).catch(() => []);
  const out = {};
  docs.forEach(d => { if (d.exists) out[d.id] = d.data().nickname || ''; });
  return out;
}

// 성장 지표 — 일별/월별 가입 추이, 누적, 언어(국가 추정) 분포
app.get('/api/admin/analytics/growth', adminAuth, async (req, res) => {
  try {
    const days = Math.max(7, Math.min(365, parseInt(req.query.days) || 30));
    const [users, langScan] = await Promise.all([scanAllUsers(), scanUserLangs()]);

    const byDay = new Map(), byMonth = new Map();
    const langDist = new Map(langScan);
    let blocked = 0, verified = 0, dated = 0;
    for (const u of users) {
      if (u.isBlocked) blocked++;
      if (u.isVerified) verified++;
      if (!u.createdAt) continue;
      dated++;
      const k = kstDateKey(u.createdAt);
      byDay.set(k, (byDay.get(k) || 0) + 1);
      byMonth.set(k.slice(0, 7), (byMonth.get(k.slice(0, 7)) || 0) + 1);
    }

    // 최근 N일 일별 + 누적 (윈도 이전 가입자·createdAt 없는 유저는 base에 깔린다)
    const now = Date.now();
    const dailyKeys = [];
    for (let i = days - 1; i >= 0; i--) dailyKeys.push(kstDateKey(new Date(now - i * 86400000)));
    let cumulative = users.length - dated;
    for (const [k, v] of byDay) if (k < dailyKeys[0]) cumulative += v;
    const daily = dailyKeys.map(k => {
      const count = byDay.get(k) || 0;
      cumulative += count;
      return { date: k, count, cumulative };
    });

    // 푸시 미등록(언어 미수집) 유저 — 탈퇴 잔여 userPrivate 문서가 있으면 음수가 될 수 있어 0으로 클램프
    const langKnown = [...langDist.values()].reduce((s, v) => s + v, 0);
    if (users.length - langKnown > 0) langDist.set('unknown', users.length - langKnown);

    res.json({
      totalUsers:    users.length,
      blockedUsers:  blocked,
      verifiedUsers: verified,
      newToday:      byDay.get(dailyKeys[dailyKeys.length - 1]) || 0,
      newThisMonth:  byMonth.get(kstDateKey(new Date()).slice(0, 7)) || 0,
      daily,
      monthly: [...byMonth.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))
        .map(([month, count]) => ({ month, count })),
      langDist: [...langDist.entries()].map(([lang, count]) => ({ lang, count }))
        .sort((a, b) => b.count - a.count),
    });
  } catch (err) {
    console.error('admin analytics/growth error:', err);
    res.status(500).json({ error: err.message });
  }
});

// 활동 지표 — DAU 추이, WAU/MAU, Stickiness, 주간 재방문율, 활발한 유저 TOP10
app.get('/api/admin/analytics/activity', adminAuth, async (req, res) => {
  try {
    const days = Math.max(7, Math.min(180, parseInt(req.query.days) || 30));
    const [dailyQ, kpiQ, retQ, topQ] = await Promise.all([
      pgPool.query(`
        SELECT stat_date::text AS date,
               COUNT(DISTINCT user_id)::int                    AS dau,
               COALESCE(SUM(courses_created), 0)::int          AS courses,
               COALESCE(SUM(places_visited), 0)::int           AS visited,
               COALESCE(SUM(courses_liked), 0)::int            AS likes,
               COALESCE(SUM(courses_shared), 0)::int           AS shares
        FROM user_stats
        WHERE stat_date >= CURRENT_DATE - ($1 - 1) * INTERVAL '1 day'
        GROUP BY stat_date ORDER BY stat_date
      `, [days]),
      pgPool.query(`
        SELECT COUNT(DISTINCT user_id) FILTER (WHERE stat_date = CURRENT_DATE)::int      AS dau_today,
               COUNT(DISTINCT user_id) FILTER (WHERE stat_date = CURRENT_DATE - 1)::int  AS dau_yesterday,
               COUNT(DISTINCT user_id) FILTER (WHERE stat_date >= CURRENT_DATE - 6)::int AS wau,
               COUNT(DISTINCT user_id)::int                                              AS mau
        FROM user_stats
        WHERE stat_date >= CURRENT_DATE - 29
      `),
      pgPool.query(`
        WITH prev AS (SELECT DISTINCT user_id FROM user_stats
                      WHERE stat_date >= CURRENT_DATE - 13 AND stat_date < CURRENT_DATE - 6),
             cur  AS (SELECT DISTINCT user_id FROM user_stats
                      WHERE stat_date >= CURRENT_DATE - 6)
        SELECT (SELECT COUNT(*) FROM prev)::int                                AS prev_cnt,
               (SELECT COUNT(*) FROM prev p JOIN cur c USING (user_id))::int   AS returned
      `),
      pgPool.query(`
        SELECT user_id,
               COALESCE(SUM(COALESCE(courses_created,0) + COALESCE(places_visited,0)
                          + COALESCE(courses_liked,0) + COALESCE(courses_shared,0)), 0)::int AS events,
               COUNT(DISTINCT stat_date)::int AS active_days,
               MAX(last_active)               AS last_active
        FROM user_stats
        WHERE stat_date >= CURRENT_DATE - 29
        GROUP BY user_id ORDER BY events DESC, active_days DESC LIMIT 10
      `),
    ]);

    const nick = await nicknamesByUid(topQ.rows.map(r => r.user_id));
    const k = kpiQ.rows[0], ret = retQ.rows[0];
    res.json({
      dauToday:     k.dau_today,
      dauYesterday: k.dau_yesterday,
      wau:          k.wau,
      mau:          k.mau,
      stickiness:   k.mau > 0 ? Math.round(k.dau_today / k.mau * 100) : 0,
      weeklyReturnRate: ret.prev_cnt > 0 ? Math.round(ret.returned / ret.prev_cnt * 100) : null,
      daily: dailyQ.rows,
      topUsers: topQ.rows.map(r => ({
        userId: r.user_id, nickname: nick[r.user_id] || '',
        events: r.events, activeDays: r.active_days, lastActive: r.last_active,
      })),
    });
  } catch (err) {
    console.error('admin analytics/activity error:', err);
    res.status(500).json({ error: err.message });
  }
});

// 콘텐츠 지표 — 코스(태그·지역·인기), 그룹 방, 채팅, 브이로그, 푸시 기기, 캐시
app.get('/api/admin/analytics/content', adminAuth, async (req, res) => {
  try {
    const days = Math.max(7, Math.min(180, parseInt(req.query.days) || 30));
    const [courses, roomsSnap, msgQ, vlogQ, pushQ, pushLangQ, cacheQ] = await Promise.all([
      scanAllCourses(),
      db.collection('rooms').count().get(),
      pgPool.query(`
        SELECT COUNT(*)::int AS total,
               COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days')::int AS last7d
        FROM room_messages
      `),
      pgPool.query(`
        SELECT COUNT(*)::int AS total,
               COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days')::int  AS last7d,
               COUNT(*) FILTER (WHERE status = 'completed')::int                     AS completed,
               COUNT(*) FILTER (WHERE status = 'failed')::int                        AS failed,
               COUNT(*) FILTER (WHERE status = 'pending')::int                       AS pending,
               COUNT(*) FILTER (WHERE status = 'processing')::int                    AS processing,
               COUNT(*) FILTER (WHERE status = 'uploading')::int                     AS uploading,
               COALESCE(EXTRACT(EPOCH FROM AVG(completed_at - started_at)
                 FILTER (WHERE status = 'completed' AND started_at IS NOT NULL)), 0)::int AS avg_render_sec
        FROM vlog_jobs
      `),
      pgPool.query(`
        SELECT COUNT(*)::int AS total,
               COUNT(*) FILTER (WHERE platform = 'ios')::int     AS ios,
               COUNT(*) FILTER (WHERE platform = 'android')::int AS android
        FROM device_tokens
      `),
      pgPool.query(`SELECT lang, COUNT(*)::int AS count FROM device_tokens GROUP BY lang ORDER BY count DESC`),
      pgPool.query(`
        SELECT (SELECT COUNT(*) FROM places_cache)::int                          AS places_total,
               (SELECT COUNT(*) FROM places_cache WHERE expires_at > NOW())::int AS places_valid,
               (SELECT COUNT(*) FROM place_photos)::int                          AS photos,
               (SELECT COUNT(*) FROM translation_cache)::int                     AS translations,
               (SELECT COUNT(*) FROM recommendation_cache)::int                  AS recommendations,
               (SELECT COUNT(*) FROM course_thumbnails)::int                     AS thumbnails
      `),
    ]);

    // 코스 집계 — 일별 생성(최근 N일), 태그·지역 분포, 인기 TOP10
    const now = Date.now();
    const dailyKeys = [];
    for (let i = days - 1; i >= 0; i--) dailyKeys.push(kstDateKey(new Date(now - i * 86400000)));
    const byDay = new Map(), byTag = new Map(), byRegion = new Map();
    for (const c of courses) {
      byTag.set(c.tag, (byTag.get(c.tag) || 0) + 1);
      byRegion.set(c.region, (byRegion.get(c.region) || 0) + 1);
      if (c.createdAt) {
        const k = kstDateKey(c.createdAt);
        byDay.set(k, (byDay.get(k) || 0) + 1);
      }
    }
    const topLiked = [...courses].sort((a, b) => b.likeCount - a.likeCount).slice(0, 10);
    const nick = await nicknamesByUid(topLiked.map(c => c.authorId));

    const v = vlogQ.rows[0];
    res.json({
      courses: {
        total: courses.length,
        daily: dailyKeys.map(k => ({ date: k, count: byDay.get(k) || 0 })),
        byTag: [...byTag.entries()].map(([tag, count]) => ({ tag, count }))
          .sort((a, b) => b.count - a.count),
        byRegion: [...byRegion.entries()].map(([region, count]) => ({ region, count }))
          .sort((a, b) => b.count - a.count).slice(0, 10),
        topLiked: topLiked.map(c => ({
          id: c.id, courseName: c.courseName, region: c.region, tag: c.tag,
          likeCount: c.likeCount, authorNickname: nick[c.authorId] || '',
        })),
      },
      rooms:    { total: roomsSnap.data().count },
      messages: { total: msgQ.rows[0].total, last7d: msgQ.rows[0].last7d },
      vlogs: {
        total: v.total, last7d: v.last7d, avgRenderSec: v.avg_render_sec,
        byStatus: { completed: v.completed, failed: v.failed, pending: v.pending,
                    processing: v.processing, uploading: v.uploading },
      },
      push: {
        total: pushQ.rows[0].total, ios: pushQ.rows[0].ios, android: pushQ.rows[0].android,
        byLang: pushLangQ.rows,
      },
      caches: {
        placesTotal:     cacheQ.rows[0].places_total,
        placesValid:     cacheQ.rows[0].places_valid,
        photos:          cacheQ.rows[0].photos,
        translations:    cacheQ.rows[0].translations,
        recommendations: cacheQ.rows[0].recommendations,
        thumbnails:      cacheQ.rows[0].thumbnails,
      },
    });
  } catch (err) {
    console.error('admin analytics/content error:', err);
    res.status(500).json({ error: err.message });
  }
});

// PRO 구독 지표 — RevenueCat Metrics Overview (환경변수 미설정 시 configured:false)
// REVENUECAT_API_KEY: v2 secret key (sk_...), REVENUECAT_PROJECT_ID: RC 콘솔 프로젝트 ID
const REVENUECAT_API_KEY   = process.env.REVENUECAT_API_KEY || '';
const REVENUECAT_PROJECT_ID = process.env.REVENUECAT_PROJECT_ID || '';

app.get('/api/admin/analytics/subscription', adminAuth, async (req, res) => {
  if (!REVENUECAT_API_KEY || !REVENUECAT_PROJECT_ID) return res.json({ configured: false });
  try {
    const data = await cachedAnalytics('revenuecat-overview', 10 * 60 * 1000, async () => {
      const r = await fetch(
        `https://api.revenuecat.com/v2/projects/${encodeURIComponent(REVENUECAT_PROJECT_ID)}/metrics/overview`,
        { headers: { Authorization: `Bearer ${REVENUECAT_API_KEY}` } }
      );
      if (!r.ok) throw new Error(`RevenueCat API ${r.status}`);
      const body = await r.json();
      return { metrics: body.metrics || [], fetchedAt: new Date().toISOString() };
    });
    res.json({ configured: true, ...data });
  } catch (err) {
    console.error('admin analytics/subscription error:', err);
    res.status(502).json({ configured: true, error: err.message });
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
        userId:  id,
        // 방 이름과 발신자 닉네임은 번역 대상이 아니다 — 언어와 무관하게 그대로.
        message: literal(info.name, `${senderNick}: ${text}`),
        data:    { type: 'chat', roomId, senderUserId: senderId },
      }).catch(() => {});
    }
  } catch (e) {
    console.error('[WS chat push] error:', e.message);
  }
}

// ─── 브이로그 완성 → 채팅방 자동 공유 ─────────────────────────────────────────
// 세션 시작 때 고른 방(options.shareRoomIds)에 완성본을 비디오 메시지(kind='vlog')로 올린다.
// 완성 푸시·다운로드와 독립적인 부가 기능 — 여기서 실패해도 잡 완성에는 영향이 없다.
async function shareVlogToRooms(job, url) {
  const opts = (typeof job.options === 'object' && job.options !== null)
    ? job.options : (() => { try { return JSON.parse(job.options || '{}'); } catch { return {}; } })();
  const roomIds = Array.isArray(opts.shareRoomIds) ? [...new Set(opts.shareRoomIds)] : [];
  const token = opts.shareToken;
  if (roomIds.length === 0 || !token) return;

  // 썸네일 추출 (1초 지점 1프레임, 480px) — 실패해도 공유는 진행, 클라가 플레이스홀더 표시
  const jobDir = path.join(VLOG_DIR, String(job.id));
  const mainFile = path.join(jobDir, decodeURIComponent(path.basename(new URL(url).pathname)));
  const thumbFile = path.join(jobDir, 'share_thumb.jpg');
  let thumbUrl = null;
  try {
    await runFF(['-ss', '1', '-i', mainFile, '-frames:v', '1', '-vf', 'scale=480:-2', thumbFile], 60 * 1000);
    if (fs.existsSync(thumbFile)) {
      thumbUrl = `https://tteona.kr/uploads/vlog/${job.id}/share_thumb.jpg?st=${token}`;
    }
  } catch (e) {
    console.warn(`[VlogShare] job ${job.id} 썸네일 추출 실패: ${e.message}`);
  }

  const nickname = await nicknameOf(job.user_id, null);
  const attachmentUrl = `${url}?st=${token}`;
  const text = `🎬 ${job.course_name || '나의 오늘'}`;   // 구버전 앱은 이 텍스트를 그대로 표시(폴백)

  for (const roomId of roomIds) {
    try {
      // 완성까지 수십 분 걸릴 수 있다 — 그 사이 방을 나갔거나 방이 삭제됐으면 공유하지 않는다
      const info = await getRoomInfo(roomId, { refreshIfMissing: job.user_id }).catch(() => null);
      if (!info || !info.memberIds.includes(job.user_id)) {
        console.log(`[VlogShare] job ${job.id} → room ${roomId} 건너뜀 (멤버 아님/방 없음)`);
        continue;
      }

      const messageId = randomUUID();
      const createdAt = new Date();
      await pgPool.query(
        `INSERT INTO room_messages (message_id, room_id, user_id, nickname, text, created_at, kind, attachment_url, thumb_url)
         VALUES ($1, $2, $3, $4, $5, $6, 'vlog', $7, $8)`,
        [messageId, roomId, job.user_id, nickname, text, createdAt, attachmentUrl, thumbUrl]
      );
      const payload = JSON.stringify({
        type: 'chat', messageId, roomId, userId: job.user_id, nickname, text,
        kind: 'vlog', attachmentUrl, thumbUrl, ts: createdAt.getTime(),
      });
      const room = wsRooms.get(roomId);
      const connected = new Set();
      if (room) {
        room.forEach(client => {
          if (client.readyState === WebSocket.OPEN) client.send(payload);
          if (client.userId) connected.add(client.userId);
        });
      }
      // 방을 안 보고 있는 멤버에게는 채팅 푸시 ("닉네임: 🎬 코스명")
      pushChatToOfflineMembers(roomId, job.user_id, nickname, text, connected);
      console.log(`[VlogShare] job ${job.id} → room ${roomId} 공유 완료`);
    } catch (e) {
      console.error(`[VlogShare] job ${job.id} → room ${roomId} 실패:`, e.message);
    }
  }
}

// ─── WebSocket 실시간 위치 공유 ───────────────────────────────────────────────

const httpServer = http.createServer(app);
const wss = new WebSocket.Server({ server: httpServer, path: '/ws/location' });

// roomId → Set<WebSocket>
const wsRooms = new Map();

// 채팅 읽음 커서 (카톡식 안읽음 카운트) — 멤버별 "이 방에서 마지막으로 읽은 시각" 하나만
// 유지한다. 메시지별 안읽음 수는 클라이언트가 "커서가 메시지 시각보다 이전인 멤버 수
// (발신자 제외)"로 계산하므로 메시지×멤버 단위 저장이 필요 없다.
async function ensureChatReadSchema() {
  await pgPool.query(`
    CREATE TABLE IF NOT EXISTS room_reads (
      room_id      TEXT        NOT NULL,
      user_id      TEXT        NOT NULL,
      last_read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (room_id, user_id)
    )
  `);
}
ensureChatReadSchema().catch(err => console.error('[ChatRead] schema migration error:', err.message));

// 채팅 첨부 컬럼 (브이로그 공유) — kind='text'(기본)|'vlog'. 추가 컬럼이라 구버전과 호환:
// 구버전 서버 INSERT는 kind 기본값으로 채워지고, 구버전 앱은 text 폴백("🎬 코스명")을 그대로 표시한다.
async function ensureChatAttachmentSchema() {
  await pgPool.query(`ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'text'`);
  await pgPool.query(`ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS attachment_url TEXT`);
  await pgPool.query(`ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS thumb_url TEXT`);
}
ensureChatAttachmentSchema().catch(err => console.error('[ChatAttachment] schema migration error:', err.message));

// 위치정보 이용·제공 사실 확인자료 (위치정보법 제16조② / 위치기반서비스 이용약관 제5조).
// 개별 좌표가 아니라 "언제·누가·어떤 목적으로·누구에게 위치를 제공/이용했는지"의 사실을 기록한다.
// 동행 위치공유는 연결(세션)당 1회만 적재해 좌표 폭주를 막고, 보유기간 6개월 경과분은 자동 파기한다.
async function ensureLocationLogSchema() {
  await pgPool.query(`
    CREATE TABLE IF NOT EXISTS location_access_logs (
      id         BIGSERIAL   PRIMARY KEY,
      user_id    TEXT        NOT NULL,
      action     TEXT        NOT NULL,       -- 'provide' | 'use'
      purpose    TEXT        NOT NULL,       -- 예: '동행 위치공유'
      recipient  TEXT,                       -- 예: 'group:{roomId}'
      room_id    TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  await pgPool.query(`CREATE INDEX IF NOT EXISTS idx_lal_user_time ON location_access_logs (user_id, created_at DESC)`);
}

// 확인자료 보유기간: 6개월(약관 제5조). 하루 1회 만료분 파기.
async function purgeOldLocationLogs() {
  try {
    const r = await pgPool.query(`DELETE FROM location_access_logs WHERE created_at < NOW() - INTERVAL '6 months'`);
    if (r.rowCount) console.log(`[LocationLog] purged ${r.rowCount} expired rows`);
  } catch (e) { console.error('[LocationLog] purge error:', e.message); }
}

// 스키마 생성이 끝난 뒤에 첫 파기를 돌린다 (테이블 생성 전에 DELETE가 먼저 실행되는 레이스 방지).
ensureLocationLogSchema()
  .then(() => purgeOldLocationLogs())
  .catch(err => console.error('[LocationLog] schema migration error:', err.message));
setInterval(purgeOldLocationLogs, 24 * 60 * 60 * 1000).unref?.();

function logLocationAccess({ userId, action, purpose, recipient, roomId }) {
  if (!userId) return;
  pgPool.query(
    `INSERT INTO location_access_logs (user_id, action, purpose, recipient, room_id) VALUES ($1, $2, $3, $4, $5)`,
    [String(userId), action, purpose, recipient || null, roomId || null],
  ).catch(e => console.error('[LocationLog] insert error:', e.message));
}

// 채팅 재전송 중복 제거: clientMsgId → { messageId, ts }.
// 폰이 서버 에코를 놓쳐 12초 뒤 재전송하면 같은 clientMsgId가 다시 온다. 그때 DB에 또
// 넣지 않고 발신자에게 확정 에코만 다시 보내, 방에 같은 메시지가 두 번 저장되는 것을 막는다.
const recentChatMsgIds = new Map();
setInterval(() => {
  const cutoff = Date.now() - 120000; // 2분(클라 타임아웃 12s + 재연결 여유)보다 넉넉히
  for (const [k, v] of recentChatMsgIds) if (v.ts < cutoff) recentChatMsgIds.delete(k);
}, 60000).unref?.();

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
      // 위치정보 제공 사실 기록 — 이 연결에서 처음 위치를 보낼 때 1회만(좌표 폭주 방지)
      if (!ws.locLogged) {
        ws.locLogged = true;
        logLocationAccess({
          userId:    ws.userId,
          action:    'provide',
          purpose:   '동행 위치공유',
          recipient: 'group:' + ws.roomId,
          roomId:    ws.roomId,
        });
      }
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

      // 재전송 중복: 같은 clientMsgId가 최근에 처리됐으면 DB에 다시 넣지 않고
      // 발신자에게 확정 에코만 다시 보낸다(놓친 에코 복구, 방 중복 저장 방지).
      if (clientMsgId) {
        const seen = recentChatMsgIds.get(clientMsgId);
        if (seen) {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
              type: 'chat', messageId: seen.messageId, roomId: ws.roomId,
              userId: ws.userId, nickname: ws.nickname, text,
              replyToNickname: msg.replyToNickname ? String(msg.replyToNickname).slice(0, 200) : null,
              replyToText: msg.replyToText ? String(msg.replyToText).slice(0, 200) : null,
              clientMsgId, ts: seen.ts,
            }));
          }
          return;
        }
      }

      // 금칙어 검사 — 댓글/코스명과 동일 기준. 차단 시 발신자에게만 알리고 전파하지 않음
      if (findBannedWord(text)) {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'chat_blocked', clientMsgId }));
        }
        return;
      }
      const messageId = randomUUID();  // 반응·답장 기준이 되는 안정적 고유 ID
      if (clientMsgId) recentChatMsgIds.set(clientMsgId, { messageId, ts: Date.now() });
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

    // 읽음 커서 갱신 — 방을 보고 있는 멤버가 보낸다(입장 직후·새 메시지 수신 시).
    // 커서를 서버 시각으로 올리고 방 전체에 브로드캐스트하면 각 클라이언트가
    // 메시지별 안읽음 수를 다시 계산해 숫자를 깎는다.
    if (msg.type === 'read' && ws.roomId && ws.userId) {
      const now = new Date();
      pgPool.query(
        `INSERT INTO room_reads (room_id, user_id, last_read_at) VALUES ($1, $2, $3)
         ON CONFLICT (room_id, user_id)
         DO UPDATE SET last_read_at = GREATEST(room_reads.last_read_at, EXCLUDED.last_read_at)`,
        [ws.roomId, ws.userId, now]
      ).catch(e => console.error('[WS read] persist error:', e.message));
      const payload = JSON.stringify({ type: 'read', userId: ws.userId, ts: now.getTime() });
      const room = wsRooms.get(ws.roomId);
      if (room) room.forEach(c => { if (c.readyState === WebSocket.OPEN) c.send(payload); });
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
