#!/bin/bash
# Phase 4: 코스 공유 OG 링크 배포 스크립트
set -e

WAS_KEY="$HOME/Downloads/에어론 펨키/aeron-was-key.pem"
WEB_KEY="$HOME/Downloads/에어론 펨키/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── nginx conf 덮어쓰기 안전장치 ────────────────────────────────────────────
# 아래 scp+mv 는 라이브 conf를 저장소 사본으로 통째로 교체한다. 사본이 뒤처져 있으면
# 라이브에만 있는 블록(/ws/ 등)이 조용히 사라진다. 실제로 /ws/ 가 날아가 채팅·위치공유가
# 끊긴 사고가 있었다. nginx -t 는 이걸 못 잡는다 — 블록이 통째로 없어져도 "문법은 정상"이라
# 통과하기 때문이다. 그래서 덮어쓰기 전에 내용 손실 여부를 직접 비교한다.
nginx_overwrite_guard() {
  local live="$(mktemp)"
  ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" "sudo cat /etc/nginx/conf.d/tteona.conf" > "$live"
  [ -s "$live" ] || { echo "❌ 라이브 nginx conf를 읽지 못했다 — 중단"; rm -f "$live"; exit 1; }
  local lost
  lost=$(diff "$SCRIPT_DIR/tteona.nginx.conf" "$live" | grep '^>' || true)
  if [ -n "$lost" ]; then
    echo "❌ 덮어쓰면 라이브에만 있는 아래 설정이 사라진다:"
    echo "$lost" | sed 's/^/     /'
    echo ""
    echo "   저장소 사본이 라이브보다 뒤처져 있다. 먼저 동기화할 것:"
    echo "     ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo cat /etc/nginx/conf.d/tteona.conf\" > \"$SCRIPT_DIR/tteona.nginx.conf\""
    echo "   내용을 확인하고 커밋한 뒤 이 스크립트를 다시 실행할 것."
    rm -f "$live"; exit 1
  fi
  rm -f "$live"
  echo "  ✅ 손실되는 설정 없음 — 덮어쓰기 진행"
}
# ───────────────────────────────────────────────────────────────────────────

echo "▶ [1/4] WAS 서버에 server.js 업로드..."
scp -i "$WAS_KEY" -P $PORT \
  "$SCRIPT_DIR/server.js" \
  $WAS_HOST:/home/ubuntu/tteona-api/server.js

echo "▶ [1b] WEB 서버에 새 캐릭터 이미지 업로드..."
WEB_DIR=/Users/leeseoktae/Documents/tteona-web
scp -i "$WEB_KEY" -P $PORT \
  "$WEB_DIR/tteoni-travel.png" \
  "$WEB_DIR/tteoni-front.png" \
  $WEB_HOST:/var/www/tteona.kr/

echo "▶ [2/4] WAS PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 restart tteona-api && pm2 logs tteona-api --nostream --lines 6"

echo "▶ [3/4] WEB 서버에 Nginx 설정 업로드 후 리로드..."
nginx_overwrite_guard
scp -i "$WEB_KEY" -P $PORT \
  "$SCRIPT_DIR/tteona.nginx.conf" \
  $WEB_HOST:/tmp/tteona.conf

ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mv /tmp/tteona.conf /etc/nginx/conf.d/tteona.conf && sudo nginx -t && sudo nginx -s reload"

echo "▶ [4/4] 동작 테스트..."
sleep 2
COURSE_ID="47DF7E82-46C5-43DE-869C-CC388C1B0F00"

# 쿼리 파라미터 방식 (/course?id=UUID) — iOS 앱 공유 형식
HTTP1=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/course?id=$COURSE_ID")
OG1=$(curl -s "https://tteona.kr/course?id=$COURSE_ID" | grep 'og:title' | head -1)

# 경로 파라미터 방식 (/course/UUID)
HTTP2=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/course/$COURSE_ID")

echo "  /course?id=UUID  → HTTP $HTTP1 $([ "$HTTP1" = "200" ] && echo "✅" || echo "⚠️")"
echo "  OG title: $OG1"
echo "  /course/UUID     → HTTP $HTTP2 $([ "$HTTP2" = "200" ] && echo "✅" || echo "⚠️")"

echo ""
echo "✅ Phase 4 배포 완료!"
echo "앱 공유 형식 테스트: https://tteona.kr/course?id=$COURSE_ID"
