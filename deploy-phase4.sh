#!/bin/bash
# Phase 4: 코스 공유 OG 링크 배포 스크립트
set -e

WAS_KEY="$HOME/Downloads/에어론 펨키/aeron-was-key.pem"
WEB_KEY="$HOME/Downloads/에어론 펨키/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
