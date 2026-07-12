#!/bin/bash
# 2026-07-12 방 대표 이미지 라우트 배포
#  - WAS: server.js — POST /api/rooms/:roomId/image (512px 리샘플 + rooms.imageUrl 갱신)
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
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [4/4] 배포 검증..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
ROUTE=$(curl -s -o /dev/null -w "%{http_code}" -X POST https://tteona.kr/api/rooms/proberoom/image)
echo "  /api/health → $HEALTH (기대 200)"
# 완화 인증 모드에서는 파일 누락 400, 강제 모드에서는 401 — 둘 다 라우트 존재 증거 (배포 전 404)
echo "  /api/rooms/:id/image (무인증 POST) → $ROUTE (기대 400 또는 401 — 배포 전 404)"
[ "$HEALTH" = "200" ] && { [ "$ROUTE" = "400" ] || [ "$ROUTE" = "401" ]; } && echo "✅ 배포 완료" || { echo "❌ 검증 실패"; exit 1; }
