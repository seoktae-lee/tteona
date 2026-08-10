#!/bin/bash
# 2026-08-10 장소 사진 정확도 개선 배포
#  - WAS: server.js — /api/places/tour-photo 후보 선별 기준 강화
#    · 예전엔 "결과 중 가장 가까운 것"을 무조건 골랐다. 거리 상한이 없어서
#      키워드만 스친 수백 km 밖 관광지도 후보가 그것뿐이면 그대로 뽑혔다.
#    · 이제 이름이 스치지도 않으면 탈락, 정확 일치라도 20km 밖이면 탈락,
#      부분 일치는 1.5km 안쪽만 인정. 못 고르면 404 → 앱이 Google Places로 폴백.
#  - **기존 캐시 비우기가 이 배포의 핵심 절반이다.** place_photos에 30일짜리
#    양성 캐시로 박혀 있는 옛 오답을 지우지 않으면 로직만 고쳐도 화면은 그대로다.
#  - nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
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
[ "$HEALTH" = "200" ] || { echo "  ✗ health 실패"; exit 1; }
[ "$WS" = "101" ] || { echo "  ✗ WS 핸드셰이크 실패 (nginx /ws/ 블록 확인)"; exit 1; }

echo "▶ [5/6] 옛 사진 캐시 비우기 (tour 소스만)..."
# PG는 별도 호스트(10.30.10.170)에 있고 WAS에 postgres 계정이 없다.
# psql 대신 앱과 같은 접속 정보를 쓰는 일회용 스크립트를 올려 실행하고 지운다.
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/scripts/purge-place-photo-cache.js" \
  $WAS_HOST:/home/ubuntu/tteona-api/purge-place-photo-cache.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node purge-place-photo-cache.js; rm -f purge-place-photo-cache.js"

echo "▶ [6/6] 실제 장소로 검증..."
echo "  (인증이 필요한 엔드포인트라 앱에서 확인한다 — 아래는 서버 로그 관찰용)"
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 logs tteona-api --nostream --lines 20 | grep -i tourphoto || echo '  TourPhoto 오류 로그 없음(정상)'"

echo ""
echo "✅ 배포 완료. 앱에서 확인할 것:"
echo "   · 기존에 엉뚱한 사진이 뜨던 장소 → 올바른 사진 또는 사진 없음"
echo "   · 사진이 사라진 장소가 많다면 LIMIT_KM(20 / 1.5km)을 완화 검토"
