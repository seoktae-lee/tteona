#!/bin/bash
# 2026-07-26 코스 공유 페이지(/course/:id) 파비콘
#  - WAS: server.js — courseHtml() / courseNotFoundHtml() 템플릿 <head>에 link 4종 추가
#
# /course* 는 nginx가 WAS로 프록시하므로 정적 파일 배포로는 반영되지 않는다.
# WEB은 건드리지 않는다 — 아이콘 파일은 이미 /var/www/tteona.kr 에 배포돼 있다.
set -euo pipefail

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
REMOTE=/home/ubuntu/tteona-api
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "▶ [0/5] 로컬 검사..."
node --check "$SCRIPT_DIR/server.js"
n=$(grep -c 'favicon.ico?v=2' "$SCRIPT_DIR/server.js")
[ "$n" = "2" ] || { echo "  ✗ 템플릿 2곳이어야 하는데 ${n}곳"; exit 1; }
echo "  문법 OK · 템플릿 2곳 확인"

echo "▶ [1/5] WAS: server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT "$WAS_HOST" \
  "cp $REMOTE/server.js $REMOTE/server.js.bak-$STAMP && ls -la $REMOTE/server.js.bak-$STAMP"

echo "▶ [2/5] WAS: 업로드 + 문법 검사..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" "$WAS_HOST":$REMOTE/server.js
ssh -i "$WAS_KEY" -p $PORT "$WAS_HOST" "cd $REMOTE && node --check server.js && echo '  원격 문법 OK'"

echo "▶ [3/5] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT "$WAS_HOST" \
  "cd $REMOTE && pm2 restart tteona-api && sleep 4 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [4/5] 기존 기능 회귀 검사..."
fail=0
for u in "https://tteona.kr/api/public/explore?sort=latest&limit=1" \
         "https://tteona.kr/course/probe"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  echo "  $code  $u"
done
ws=$(curl -s -o /dev/null -w "%{http_code}" -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
     https://tteona.kr/ws/location)
echo "  $ws  /ws/location  (101이어야 정상 — 채팅·위치공유)"
[ "$ws" = "101" ] || fail=1
api=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/api/public/explore?sort=latest&limit=1")
[ "$api" = "200" ] || fail=1

echo "▶ [5/5] 코스 페이지 파비콘 반영 확인..."
n=$(curl -s "https://tteona.kr/course/probe" | grep -c 'favicon.ico?v=2' || true)
echo "  link ${n}건  /course/probe (찾을 수 없어요 템플릿)"
[ "$n" -ge 1 ] || fail=1

if [ $fail -ne 0 ]; then
  echo "❌ 검증 실패 — 롤백:"
  echo "   ssh -i \"\$WAS_KEY\" -p $PORT $WAS_HOST \"cp $REMOTE/server.js.bak-$STAMP $REMOTE/server.js && pm2 restart tteona-api\""
  exit 1
fi
echo "✅ 배포 완료 — 롤백본: $REMOTE/server.js.bak-$STAMP"
