#!/bin/bash
# 2026-07-17 브이로그 완성 → 채팅방 자동 공유 배포
#  - WAS: server.js —
#    · vlog_jobs.options에 shareRoomIds + shareToken(128bit) 저장
#    · /uploads/vlog에 ?st=공유토큰 접근 허용 (소유자 경로는 기존 그대로)
#    · 워커 완성 시 shareVlogToRooms: 멤버십 재확인 → room_messages(kind='vlog') 삽입
#      → WS 브로드캐스트 + 오프라인 멤버 푸시, ffmpeg 썸네일(share_thumb.jpg)
#    · room_messages에 kind/attachment_url/thumb_url 컬럼 자동 추가(기동 시)
#  - nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "▶ [1/5] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"

echo "▶ [2/5] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [3/5] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 10"

echo "▶ [4/5] 기본 검증 (health + WS 핸드셰이크)..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
echo "  /api/health → $HEALTH (기대 200)"
echo "  /ws/location 핸드셰이크 → $WS (기대 101)"
[ "$HEALTH" = "200" ] && [ "$WS" = "101" ] || { echo "❌ 기본 검증 실패"; exit 1; }

# 채팅 히스토리 SELECT에 새 컬럼(kind 등)이 들어갔다 — 컬럼 마이그레이션이 실패했다면
# 여기서 500이 난다 (200=완화모드 빈 목록, 401/403=인증 강제 — 둘 다 라우트 정상)
MSGS=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/api/rooms/deploy-probe/messages?limit=1")
echo "  /api/rooms/:id/messages → $MSGS (기대 200/401/403 — 500이면 컬럼 마이그레이션 실패)"
case "$MSGS" in 200|401|403) ;; *) echo "❌ 채팅 히스토리 검증 실패"; exit 1;; esac

echo "▶ [5/5] 브이로그 파이프라인 스모크 (기존 기능 회귀 확인)..."
"$SCRIPT_DIR/smoke-test-vlog.sh"

echo "✅ 배포 완료 — room_messages 첨부 컬럼은 기동 시 자동 추가 (pm2 로그에 ChatAttachment 에러 없는지 확인)"
