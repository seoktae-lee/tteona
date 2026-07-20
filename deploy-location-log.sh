#!/bin/bash
# 2026-07-20 위치정보 이용·제공 사실 확인자료 기록 (위치정보법 제16조② / LBS 약관 제5조)
#  - WAS: server.js — location_access_logs 테이블(기동 시 자동 생성), 동행 위치공유 제공사실을
#    WS 연결당 1회 적재, 6개월 경과분 자동 파기(기동 시 + 하루 1회)
#  - nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "▶ [1/4] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"

echo "▶ [2/4] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [3/4] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 12"

echo "▶ [4/4] 배포 검증..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
echo "  /api/health → $HEALTH (기대 200)"
echo "  /ws/location 핸드셰이크 → $WS (기대 101)"
if [ "$HEALTH" = "200" ] && [ "$WS" = "101" ]; then
  echo "✅ 배포 완료 — location_access_logs 테이블은 기동 시 자동 생성됨 (pm2 로그에 LocationLog migration error 없는지 확인)"
else
  echo "❌ 검증 실패 — server.js.bak-* 로 롤백 가능"
  exit 1
fi
