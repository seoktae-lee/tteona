#!/bin/bash
# 게스트 브이로그 한도를 **잠깐** 0으로 내려, 서버 403 거절 경로를 실제로 밟아보는 테스트 도구.
#
#  왜 필요한가: 앱에는 기기 카운트 게이트가 먼저 있어서, 평소엔 서버까지 가지도 않는다.
#  그래서 "403을 받았을 때 로컬 합성으로 새지 않는가"라는 이번 수정의 핵심을 확인할 수 없다.
#  한도를 0으로 두면 게스트의 **첫** 시도부터 403이 떨어져 그 경로만 정확히 관찰된다.
#
#  저장소의 server.js는 건드리지 않는다 — 임시 사본을 만들어 올린다.
#  (한도 0이 실수로 커밋·재배포되면 게스트가 브이로그를 아예 못 만든다)
#
#  사용법:  ./deploy-guest-limit-test.sh on    # 한도 0 (테스트 시작)
#           ./deploy-guest-limit-test.sh off   # 한도 1 (원상복구)
set -e

MODE="${1:-}"
case "$MODE" in
  on|off) ;;
  *) echo "사용법: $0 on|off"; exit 1;;
esac

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)/server.js"

if [ "$MODE" = "on" ]; then
  LIMIT=0; LABEL="테스트 모드 — 게스트 첫 시도부터 403"
else
  LIMIT=1; LABEL="정상 — 게스트 첫 브이로그 1개 허용"
fi

echo "▶ [1/4] 임시 사본 생성 (한도 $LIMIT)..."
sed "s/^const GUEST_VLOG_LIMIT = 1;/const GUEST_VLOG_LIMIT = $LIMIT;/" \
  "$SCRIPT_DIR/server.js" > "$TMP"
grep -n "GUEST_VLOG_LIMIT = " "$TMP"
node --check "$TMP"

echo "▶ [2/4] 업로드 + 재시작..."
scp -i "$WAS_KEY" -P $PORT "$TMP" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api >/dev/null && sleep 3 && grep -n 'GUEST_VLOG_LIMIT = ' server.js"

echo "▶ [3/4] 서버 상태 확인..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
echo "  /api/health → $HEALTH (기대 200) · /ws/location → $WS (기대 101)"
[ "$HEALTH" = "200" ] || { echo "  ✗ health 실패"; exit 1; }
[ "$WS" = "101" ]     || { echo "  ✗ WS 실패"; exit 1; }

echo "▶ [4/4] 현재 설정: $LABEL"
rm -f "$TMP"
if [ "$MODE" = "on" ]; then
  echo ""
  echo "⚠️  테스트가 끝나면 반드시 되돌릴 것:  ./deploy-guest-limit-test.sh off"
fi
