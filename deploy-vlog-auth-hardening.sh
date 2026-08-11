#!/bin/bash
# 2026-08-11 브이로그 인증 구멍 차단 배포
#
#  완화 모드(AUTH_ENFORCE=false)는 토큰을 안 보내던 구버전 앱을 끊지 않으려 열어둔 문인데,
#  브이로그 쪽에서는 그 문이 검사 자체를 없애고 있었다:
#    · req.isGuest가 토큰 해독 성공 경로에서만 채워져 → 토큰이 없으면 게스트 한도 검사가 통째로 스킵
#    · userId가 클라이언트 본문 값으로 떨어져 신원을 스스로 적어 낼 수 있었음
#    · requireJobOwner가 `if (!req.uid) return next()`라 잡 id(순번)만 알면 남의 것에 접근
#    · /uploads/vlog 파일 서빙도 `if (req.uid)`로 감싸져 있어 토큰 없이 부르면 완성본이 그대로 내려감
#
#  → 브이로그 4개 라우트 + 파일 서빙에만 requireUser를 강제한다. 전역 AUTH_ENFORCE는 건드리지 않는다.
#    구버전 앱은 401을 받고 로컬 합성으로 물러난다(결과물은 여전히 손에 들어감).
#    iOS(APIAuth)·안드로이드(ApiClient 인터셉터) 모두 tteona.kr 요청에 토큰을 붙이는 것을 확인했다.
#
#  + /api/health에 anonymousHits(토큰 없이 들어온 요청 수)를 노출한다 —
#    0이 충분히 오래 유지되면 전역 AUTH_ENFORCE=true로 닫을 근거가 된다.
#
#  nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "▶ [1/6] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"

echo "▶ [2/6] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [3/6] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3"

echo "▶ [4/6] 기존 기능 회귀 확인 (health · WS · 공개 탐색)..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
EXPLORE=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/api/public/explore?limit=1")
BGM=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/vlog/bgm)
echo "  /api/health            → $HEALTH   (기대 200)"
echo "  /ws/location 핸드셰이크 → $WS   (기대 101)"
echo "  /api/public/explore    → $EXPLORE   (기대 200 — 무인증 공개 API는 그대로여야 한다)"
echo "  /api/vlog/bgm          → $BGM   (기대 200 — BGM 목록도 무인증 유지)"
[ "$HEALTH" = "200" ] || { echo "  ✗ health 실패"; exit 1; }
[ "$WS" = "101" ]     || { echo "  ✗ WS 핸드셰이크 실패 (nginx /ws/ 블록 확인)"; exit 1; }
[ "$EXPLORE" = "200" ] || { echo "  ✗ 공개 탐색 API가 막혔다 — 과잉 차단"; exit 1; }
[ "$BGM" = "200" ]    || { echo "  ✗ BGM 목록이 막혔다 — 과잉 차단"; exit 1; }

echo "▶ [5/6] 구멍이 실제로 닫혔는지 확인 (토큰 없이 호출)..."
JOBS=$(curl -s -o /dev/null -w "%{http_code}" -X POST https://tteona.kr/api/vlog/jobs \
  -H "Content-Type: application/json" \
  -d '{"userId":"probe-no-token","places":[{"order":1,"placeName":"probe"}]}')
JOBGET=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/vlog/jobs/1)
FILE=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/uploads/vlog/1/vlog.mp4)
echo "  POST /api/vlog/jobs      → $JOBS   (기대 401 — 예전엔 통과해 잡이 만들어졌다)"
echo "  GET  /api/vlog/jobs/1    → $JOBGET   (기대 401 — 예전엔 소유자 검증 없이 통과)"
echo "  GET  /uploads/vlog/1/... → $FILE   (기대 401 — 예전엔 완성본이 그대로 내려갔다)"
[ "$JOBS" = "401" ]   || { echo "  ✗ 잡 생성이 여전히 무인증 통과"; exit 1; }
[ "$JOBGET" = "401" ] || { echo "  ✗ 잡 조회가 여전히 무인증 통과"; exit 1; }
[ "$FILE" = "401" ]   || { echo "  ✗ 완성본 파일이 여전히 무인증 통과"; exit 1; }

echo "▶ [6/6] 방 공유 토큰 경로가 살아 있는지 확인..."
# 채팅방에 공유된 완성본은 ?st=토큰으로 방 멤버가 무인증 재생한다 — 이 길까지 막으면 안 된다.
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/scripts/probe-share-token.js" \
  $WAS_HOST:/home/ubuntu/tteona-api/_probe.js >/dev/null
PROBE=$(ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node _probe.js 2>/dev/null; rm -f _probe.js")
echo "$PROBE"

SHARE_LINE=$(echo "$PROBE" | grep -o "SHARE [0-9]* [0-9a-f]*" || true)
if [ -n "$SHARE_LINE" ]; then
  SID=$(echo "$SHARE_LINE" | awk '{print $2}')
  STOK=$(echo "$SHARE_LINE" | awk '{print $3}')
  SC=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/uploads/vlog/$SID/vlog.mp4?st=$STOK")
  echo "  공유 토큰 재생 (job $SID) → $SC   (기대 200 또는 404 — 401/403이면 회귀)"
  case "$SC" in 401|403) echo "  ✗ 방 공유 경로가 막혔다"; exit 1;; esac
else
  echo "  공유 토큰이 붙은 잡이 없어 이 경로는 확인 생략"
fi

echo ""
echo "✅ 배포 완료."
echo "   · 며칠 뒤 curl -s https://tteona.kr/api/health | jq .anonymousHits 로"
echo "     토큰 없이 들어오는 요청이 남아 있는지 확인 → 0이면 AUTH_ENFORCE=true 검토"
