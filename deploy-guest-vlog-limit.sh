#!/bin/bash
# 2026-08-03 게스트(익명) 브이로그 1회 제한 배포
#  - WAS: server.js —
#    · verifyBearer가 토큰에서 익명 여부(sign_in_provider)를 함께 판정해 req.isGuest에 담는다.
#      클라이언트가 보내는 값을 믿으면 "나 회원이야" 한 줄로 무제한 무료 렌더가 뚫린다.
#    · /api/vlog/jobs — 게스트가 completed 잡을 이미 1개 가지고 있으면 403 guest_limit.
#      **완성된 것만** 센다. 실패한 시도로 체험이 소진되면 아무것도 못 받고 가입을 요구받는다.
#  - 앱에도 같은 제한이 있다(기기 단위). 통신이 끊기면 로컬 합성으로 떨어지므로
#    서버만 막으면 비행기 모드가 우회로가 된다 — 두 겹이 모두 필요하다.
#  - nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="https://tteona.kr/api/vlog"

echo "▶ [1/6] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"

echo "▶ [2/6] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [3/6] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 10"

echo "▶ [4/6] 기본 검증 (health + WS 핸드셰이크)..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
echo "  /api/health → $HEALTH (기대 200)"
echo "  /ws/location 핸드셰이크 → $WS (기대 101)"
[ "$HEALTH" = "200" ] && [ "$WS" = "101" ] || { echo "❌ 기본 검증 실패"; exit 1; }

echo "▶ [5/6] 기존 경로 회귀 스모크 (옵션 미지정 = 기본 자막)..."
"$SCRIPT_DIR/smoke-test-vlog.sh"

# 기본 경로만 통과하면 새 분기는 한 번도 실행되지 않은 채 배포된다.
# 표시항목·색·캡션을 모두 바꾼 잡을 실제로 렌더해 drawtext 체인이 성립하는지 확인한다.
echo "▶ [6/6] 기존 사용자 회귀 확인 — 무인증 잡 생성이 여전히 통과하는가..."
# 게스트 제한은 '토큰이 있고 그게 익명일 때'만 걸린다. 토큰 없는 구버전 앱까지 막으면
# 기존 사용자가 브이로그를 못 만든다 — 이 요청이 통과해야 정상이다.
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST "$BASE/jobs" \
  -H 'Content-Type: application/json' \
  -d '{"userId":"deploy-smoke-guard","courseName":"__smoke_guard__","tag":"커플","bgm":"auto",
       "places":[{"order":0,"placeName":"smoke"}]}')
echo "  무인증 잡 생성 → HTTP $CODE (기대 200 — 구버전 앱 호환)"
[ "$CODE" = "200" ] || { echo "❌ 기존 경로가 막혔다"; exit 1; }

echo
echo "✅ 배포 완료 — 게스트 1회 제한 적용"
echo "   ※ 익명 토큰으로 두 번째 잡을 요청하면 403 guest_limit 이 떨어진다"
echo "   ※ 실기기 확인: 게스트로 브이로그 1개 완성 → 다시 시도 시 회원가입 안내 화면"
exit 0
