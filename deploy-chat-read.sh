#!/bin/bash
# 2026-07-17 카톡식 채팅 읽음 카운트(안읽음 숫자) 배포
#  - WAS: server.js — room_reads 테이블(기동 시 자동 생성), WS 'read' 프로토콜,
#    히스토리 응답에 멤버별 읽음 커서(reads) 포함, 탈퇴·방나가기 시 커서 정리
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
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 10"

echo "▶ [4/4] 배포 검증..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
# WS 핸드셰이크 — nginx /ws/ 블록 유실 사고 재발 감지 (101이어야 정상, 404면 블록 누락)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
echo "  /api/health → $HEALTH (기대 200)"
echo "  /ws/location 핸드셰이크 → $WS (기대 101)"
if [ "$HEALTH" = "200" ] && [ "$WS" = "101" ]; then
  echo "✅ 배포 완료 — room_reads 테이블은 기동 시 자동 생성됨 (pm2 로그에 migration error 없는지 확인)"
else
  echo "❌ 검증 실패"
  exit 1
fi
