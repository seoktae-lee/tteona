#!/bin/bash
# 2026-07-25 브이로그 장소 자막 서체·크기 선택 배포
#  - WAS: server.js — job options.font/fontScale 수용 → drawtext에 반영
#         assets/fonts/에 선택 가능한 서체 4종 추가 (고운바탕은 기존)
#  - nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE=/home/ubuntu/tteona-api
FONTS=(Pretendard-Bold.otf NanumPenScript-Regular.ttf Jua-Regular.ttf BlackHanSans-Regular.ttf BMKkubulimTTF.ttf HSGooltokki.ttf)

echo "▶ [1/6] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"

echo "▶ [2/6] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp $REMOTE/server.js $REMOTE/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [3/6] WAS: 서체 4종 업로드..."
for f in "${FONTS[@]}"; do
  scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/assets/fonts/$f" "$WAS_HOST:$REMOTE/assets/fonts/$f"
done
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST "ls -1 $REMOTE/assets/fonts/"

echo "▶ [4/6] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" "$WAS_HOST:$REMOTE/server.js"
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd $REMOTE && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [5/6] 기본 검증 (health + WS 핸드셰이크 + bgm)..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
BGM=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/vlog/bgm)
echo "  /api/health → $HEALTH (기대 200)"
echo "  /ws/location → $WS (기대 101)"
echo "  /api/vlog/bgm → $BGM (기대 200)"
[ "$HEALTH" = "200" ] && [ "$WS" = "101" ] || { echo "❌ 기본 검증 실패"; exit 1; }

echo "▶ [6/6] 브이로그 파이프라인 스모크 (기존 기능 회귀 확인)..."
"$SCRIPT_DIR/smoke-test-vlog.sh"

echo "✅ 배포 완료 — 서체 선택(font/fontScale)이 반영된다. 기본값(gowun/medium)은 기존 동작과 동일."
